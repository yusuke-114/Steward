import AppKit
import SwiftUI

enum MainWindowSection: String, CaseIterable, Identifiable {
    case connection
    case projects
    case permissions
    case logs

    var id: Self { self }

    var title: String {
        switch self {
        case .connection: "Connection"
        case .projects: "Projects"
        case .permissions: "Permissions"
        case .logs: "Logs"
        }
    }

    var systemImage: String {
        switch self {
        case .connection: "network"
        case .projects: "folder"
        case .permissions: "lock"
        case .logs: "terminal"
        }
    }
}

struct MainWindowView: View {
    let app: AppState
    @Bindable var settings: Settings
    @State private var selectedSection: MainWindowSection? = .connection

    var body: some View {
        ZStack {
            StewardWindowGlassConfigurator()
                .frame(width: 0, height: 0)

            StewardWindowBackdrop()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            NavigationSplitView {
                sidebar
            } detail: {
                Group {
                    if (selectedSection ?? .connection) == .logs {
                        LogView(log: app.log)
                    } else {
                        SettingsView(app: app,
                                     settings: settings,
                                     section: selectedSection ?? .connection)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .preferredColorScheme(.dark)
    }

    /// A normal macOS sidebar margin — not the ~50pt of stacked, per-element
    /// padding this column used to accumulate (14pt outer content padding +
    /// a further 24pt on the title, while the nav rows only added 10pt on
    /// top of List's own inset). Title, subtitle, nav rows, and the
    /// connection control all hang off this single value now, so they share
    /// one leading edge instead of each deriving its own position from its
    /// own intrinsic width/padding.
    private static let sidebarContentInset: CGFloat = 16

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Steward")
                    .font(.title2.weight(.bold))
                Text("Claude Code from anywhere")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 28)
            .padding(.bottom, 18)

            // Hand-rolled rows instead of `List(.sidebar)`: that style applies
            // macOS's own leading inset, which `listRowInsets` does not fully
            // override, so the nav column ended up ~46pt to the right of the title. Drawing
            // the selection pill ourselves keeps every element — title, rows,
            // connection control — on the single leading edge defined by
            // `sidebarContentInset`.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(MainWindowSection.allCases) { section in
                    let isSelected = selectedSection == section
                    Button {
                        selectedSection = section
                    } label: {
                        Label(section.title, systemImage: section.systemImage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? Color.accentColor : Color.clear)
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            connectionControl
                .padding(.vertical, 18)
        }
        .padding(.horizontal, Self.sidebarContentInset)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(14)
        .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 280)
    }

    @ViewBuilder
    private var connectionControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(connectionStatusText, systemImage: connectionStatusIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(connectionStatusColor)

            switch app.connectionState {
            case .needsConfiguration:
                Button("Configure Connection") { selectedSection = .connection }
                    .buttonStyle(.glass)
            case .connected, .connecting, .waitingForClaudeInput:
                Button("Stop Connection") { app.stop() }
                .buttonStyle(.glass)
            case .stopped, .unauthorized, .failure:
                Button("Connect") { app.start() }
                    .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connectionStatusText: String {
        switch app.connectionState {
        case .needsConfiguration: "Connection setup required"
        case .stopped: "Disconnected"
        case .connecting: "Reconnecting…"
        case .waitingForClaudeInput: "Telegram ready — send a message to start Claude"
        case .connected: "Connected"
        case .unauthorized: "Invalid bot token"
        case .failure(let message): message
        }
    }

    private var connectionStatusIcon: String {
        switch app.connectionState {
        case .needsConfiguration: "exclamationmark.circle.fill"
        case .stopped: "circle"
        case .connecting: "arrow.triangle.2.circlepath"
        case .waitingForClaudeInput: "paperplane.circle.fill"
        case .connected: "checkmark.circle.fill"
        case .unauthorized: "xmark.octagon.fill"
        case .failure: "xmark.octagon.fill"
        }
    }

    private var connectionStatusColor: Color {
        switch app.connectionState {
        case .connected: .green
        case .needsConfiguration, .unauthorized: .orange
        case .failure: .red
        case .stopped, .connecting, .waitingForClaudeInput: .secondary
        }
    }
}

private struct StewardWindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let backdrop = NSVisualEffectView()
        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .followsWindowActiveState
        return backdrop
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct StewardWindowGlassConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
        }
    }
}
