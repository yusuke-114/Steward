import SwiftUI
import UniformTypeIdentifiers

/// The detail pane for the main window's Connection, Projects, and Permissions
/// sections. Saving a token updates local credentials; Connect starts Telegram.
struct SettingsView: View {
    let app: AppState
    @Bindable var settings: Settings
    let section: MainWindowSection

    @State private var token = ""
    @State private var userIDText: String = ""
    @State private var saveMessage: String?
    @State private var saveSucceeded = true
    @State private var isVerifyingToken = false
    @State private var newScopedRule: String = ""
    @State private var scopedRuleRejection: String?
    @State private var confirmingBashEnable = false

    var body: some View {
        Group {
            switch section {
            case .connection: connectionTab
            case .projects: projectsTab
            case .permissions: permissionTab
            // MainWindowView renders LogView directly for `.logs` and never
            // constructs a SettingsView with this section; kept only so the
            // switch above stays exhaustive as MainWindowSection grows.
            case .logs: EmptyView()
            }
        }
        .onAppear {
            token = settings.botToken ?? ""
            userIDText = settings.allowedUserIDs.map(String.init).joined(separator: ", ")
        }
    }

    private var connectionTab: some View {
        DetailPane {
            GlassEffectContainer(spacing: 16) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Service Connections")
                            .font(.title.weight(.bold))
                        Text("Connect Telegram to use Claude Code from your phone.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 12) {
                            Image(systemName: isConfigured ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(isConfigured ? .green : .orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Telegram Bot")
                                    .font(.headline)
                                Text(isConfigured ? "Saved locally" : "Setup required")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(isConfigured ? .green : .secondary)
                            }
                            Spacer()
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Bot Token")
                                .font(.subheadline.weight(.medium))
                            SecureField("Paste the token from @BotFather", text: $token)
                                .textFieldStyle(.roundedBorder)
                                .disabled(isVerifyingToken)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Allowed Telegram User IDs")
                                .font(.subheadline.weight(.medium))
                            TextField("One or more IDs, separated by commas", text: $userIDText)
                                .textFieldStyle(.roundedBorder)
                                .disabled(isVerifyingToken)
                            Text("Only these accounts can send commands to this Mac.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        Toggle(isOn: Binding(
                            get: { settings.keepMacAwake },
                            set: { enabled in
                                settings.keepMacAwake = enabled
                                app.keepMacAwakeDidChange()
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Keep Mac Awake")
                                    .font(.subheadline.weight(.medium))
                                Text("Prevents idle sleep only while the service is Connected. Uses more power and does not keep a shut-down or closed-lid Mac running.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)

                        HStack {
                            Button("Save") { save() }
                                .buttonStyle(.glass)
                                .disabled(isVerifyingToken || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if let saveMessage {
                                Label(saveMessage,
                                      systemImage: saveSucceeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                    .font(.caption)
                                    .foregroundStyle(saveSucceeded ? .green : .red)
                            }
                        }
                    }
                    .padding(20)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .glassEffect(.clear.interactive(), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                    claudeEnvironmentCard
                }
            }
        }
    }

    private var isConfigured: Bool {
        !(settings.botToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var claudeEnvironmentCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: claudeIsReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(claudeIsReady ? .green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Claude Code")
                        .font(.headline)
                    Text(claudeStatusText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(claudeIsReady ? .green : .secondary)
                }
                Spacer()
            }

            if case let .ready(path, version) = app.claudeInstallation {
                VStack(alignment: .leading, spacing: 4) {
                    Text(path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("Version \(version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Steward could not find a verified Claude Code binary.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Rescan") { app.refreshClaudeEnvironment() }
                    .buttonStyle(.glass)
                Button("Choose Binary…") { chooseClaudeBinary() }
                    .buttonStyle(.glass)
            }
        }
        .padding(20)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .glassEffect(.clear.interactive(), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var claudeIsReady: Bool {
        if case .ready = app.claudeInstallation { return true }
        return false
    }

    private var claudeStatusText: String {
        claudeIsReady ? "Ready to run Claude Code" : "Setup required"
    }

    /// Verifies the form token before persisting it. Connecting stays an
    /// explicit sidebar action, so this path never starts a poll itself.
    private func save() {
        let submittedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let submittedUserIDText = userIDText
        guard !isVerifyingToken, !submittedToken.isEmpty else { return }

        isVerifyingToken = true
        saveSucceeded = true
        saveMessage = "Verifying bot token…"
        Task {
            defer { isVerifyingToken = false }
            do {
                try await TelegramClient(token: submittedToken).verify()
                guard settings.saveConnectionCredentials(token: submittedToken, userIDText: submittedUserIDText) else {
                    return
                }
                saveSucceeded = true
                saveMessage = "Verified and saved. Use Connect in the sidebar."
                app.credentialsSaved()
            } catch TelegramError.unauthorized, TelegramError.invalidRequest, TelegramError.http(404) {
                // Telegram 对格式错误的 token 返回 404 而不是 401。
                saveSucceeded = false
                saveMessage = "Invalid bot token — saved token unchanged."
            } catch {
                saveSucceeded = false
                saveMessage = "Could not verify bot token: "
                    + TelegramClient.redactingToken(in: error.localizedDescription)
            }
        }
    }

    private func chooseClaudeBinary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the Claude Code executable"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.claudePath = url.path
        app.refreshClaudeEnvironment()
    }

    private var projectsTab: some View {
        DetailPane {
            VStack(alignment: .leading, spacing: 5) {
                Text("Projects")
                    .font(.title.weight(.bold))
                Text("Choose the local project Claude Code will work in.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 0) {
                if settings.projects.isEmpty {
                    Text("No projects added yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.projects) { p in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name)
                                .font(.subheadline.weight(.medium))
                            Text(p.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if p.path == settings.currentProjectPath {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .onTapGesture { app.switchProject(to: p.path) }
                    if p.id != settings.projects.last?.id {
                        Divider()
                    }
                }
            }
            .padding(20)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .glassEffect(.clear.interactive(), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            HStack {
                Button("Add Project…") { addProject() }
                    .buttonStyle(.glass)
                Button("Remove Selected") {
                    if let current = settings.currentProjectPath {
                        app.removeProject(path: current)
                    }
                }
                .buttonStyle(.glass)
                .disabled(settings.currentProjectPath == nil)
            }
        }
    }

    private var permissionTab: some View {
        DetailPane {
            VStack(alignment: .leading, spacing: 5) {
                Text("Permissions")
                    .font(.title.weight(.bold))
                Text("Every tool ticked below runs immediately, without asking you first — including while you're away from this Mac. Anything not allow-listed still asks for confirmation in Telegram.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            checklistCard
            scopedRulesCard
            timeoutCard
        }
    }

    // MARK: - Permissions: known-tool checklist

    private var checklistCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tool Checklist")
                .font(.headline)

            toolGroup(title: "Safe", subtitle: "Read-only or purely local — fine to leave on.", risk: .safe)
            Divider()
            toolGroup(title: "Needs Thought", subtitle: "Changes things without asking you first.", risk: .needsThought)
            Divider()
            bashRow
        }
        .padding(20)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .glassEffect(.clear.interactive(), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func toolGroup(title: String, subtitle: String, risk: ToolPermission.Risk) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(ToolPermission.known.filter { $0.risk == risk }) { tool in
                toolToggleRow(tool)
            }
        }
    }

    private func toolToggleRow(_ tool: ToolPermission) -> some View {
        Toggle(isOn: Binding(
            get: { Settings.isKnownToolEnabled(tool.name, in: settings.allowedTools) },
            set: { enabled in
                settings.allowedTools = Settings.settingKnownTool(tool.name, enabled: enabled, in: settings.allowedTools)
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name)
                    .font(.system(.body, design: .monospaced))
                Text(tool.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }

    /// `Bash` is not a one-click toggle: it is the single entry that turns
    /// this allow list into unattended arbitrary code execution, so turning
    /// it *on* requires an explicit confirmation step. Turning it back off
    /// needs no confirmation — that direction only removes capability.
    private var bashRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Dangerous")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
            }
            Toggle(isOn: Binding(
                get: { Settings.isKnownToolEnabled("Bash", in: settings.allowedTools) },
                set: { enabled in
                    if enabled {
                        confirmingBashEnable = true
                    } else {
                        settings.allowedTools = Settings.settingKnownTool("Bash", enabled: false, in: settings.allowedTools)
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bash")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                    Text(ToolPermission.known.first { $0.name == "Bash" }?.summary ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .tint(.red)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.red.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.red.opacity(0.4)))
        .confirmationDialog(
            "Let Claude run shell commands without asking you first?",
            isPresented: $confirmingBashEnable,
            titleVisibility: .visible
        ) {
            Button("Allow Bash Without Asking", role: .destructive) {
                settings.allowedTools = Settings.settingKnownTool("Bash", enabled: true, in: settings.allowedTools)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Once enabled, Claude can run any shell command it chooses — including ones that delete or overwrite files — without asking you first, even while nobody is at this Mac.")
        }
    }

    // MARK: - Permissions: scoped rules

    /// Everything the checklist doesn't have a dedicated row for: real scoped
    /// rules such as `Bash(rake swiftformat)`, and any bare tool name this
    /// checklist doesn't recognise (e.g. from a newer Claude Code or a
    /// hand-written entry). Both are edited the same way — as verbatim
    /// strings — so nothing here is ever silently dropped by the checklist.
    private var scopedRulesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Scoped Rules")
                    .font(.headline)
                Text("For narrower permissions, like Bash(rake swiftformat). We do not check or normalize these — they are passed to Claude Code exactly as written, and how a pattern like Bash(git status) vs. Bash(git *) matches is decided entirely by Claude Code, not by this app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                TextField("e.g. Bash(rake swiftformat)", text: $newScopedRule)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addScopedRule() }
                Button("Add") { addScopedRule() }
                    .buttonStyle(.glass)
                    .disabled(newScopedRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let scopedRuleRejection {
                Text(scopedRuleRejection)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            let others = Settings.otherEntries(in: settings.allowedTools)
            if others.isEmpty {
                Text("No scoped rules yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(others, id: \.self) { entry in
                        HStack {
                            Text(entry)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Button {
                                settings.allowedTools = Settings.removingEntry(entry, from: settings.allowedTools)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 6)
                        if entry != others.last {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(20)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .glassEffect(.clear.interactive(), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func addScopedRule() {
        let trimmed = newScopedRule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // A bare known tool name here is not a scoped rule — it allows the whole
        // tool, exactly as ticking its checkbox above would, but without the
        // confirmation that box requires. That matters most for Bash: this field
        // literally suggests "e.g. Bash(rake swiftformat)", so someone reaching
        // for a narrow rule can hit Return after typing just "Bash" and silently
        // grant unattended arbitrary shell execution while believing they scoped
        // it. Send them to the checklist instead of quietly widening permissions.
        if let rejection = Settings.scopedRuleRejection(for: trimmed) {
            scopedRuleRejection = rejection
            return
        }

        scopedRuleRejection = nil
        settings.allowedTools = Settings.addingScopedRule(trimmed, to: settings.allowedTools)
        newScopedRule = ""
    }

    // MARK: - Permissions: confirmation timeout

    private var timeoutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Confirmation Timeout")
                .font(.headline)

            // 上下界必须直接复用 Settings.permissionTimeoutRange（10...540），
            // 不能在这里另抄一份数字——`permissionTimeout` 的 didSet 会把越界
            // 输入夹回区间内（见 Settings.swift），但 Stepper 自己的 `in:`
            // 决定了用户能不能"拉到看起来生效、实际被模型悄悄改写"的值。
            // 540 这个上界本身是三层超时链条（PermissionBridge < curl
            // --max-time 570 < Claude hook timeout 600）里推出来的，链条的
            // 三个数字由 TimeoutChainInvariantTests 钉住，这里不重复也不
            // 另定义。
            Stepper("Confirmation timeout: \(Int(settings.permissionTimeout)) seconds",
                    value: $settings.permissionTimeout,
                    in: Settings.permissionTimeoutRange,
                    step: 10)
                // 光写进 UserDefaults 不够：PermissionBridge 在 AppState 属性
                // 初始化时就用默认值构造好了，不读 Settings。不推这一下，
                // 这个步进器不生效。
                .onChange(of: settings.permissionTimeout) { _, _ in
                    app.permissionTimeoutDidChange()
                }

            Text("How long Claude waits for a Telegram reply before auto-denying an action that isn't allow-listed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .glassEffect(.clear.interactive(), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.projects.append(Project(name: url.lastPathComponent, path: url.path))
        if settings.currentProjectPath == nil { settings.currentProjectPath = url.path }
    }
}

/// Shared chrome for every detail-pane tab (Connection/Projects/Permissions).
///
/// Before this existed, each tab built its own container by hand. The
/// Permissions tab used a bare `Form`/`VStack` with no shared alignment
/// context, so SwiftUI centred each child independently — the title, the
/// allow-list editor, and the timeout stepper each landed at a different
/// horizontal position, leaving a large empty gutter on the left.
///
/// `DetailPane` fixes that everywhere at once: one `VStack(alignment:
/// .leading)` so every child shares the same left edge, wrapped in a
/// `ScrollView` so overflowing content scrolls instead of clipping, and
/// capped at a sane reading width (with a trailing `Spacer` to keep it
/// pinned left) so it doesn't stretch edge-to-edge on a large display.
private struct DetailPane<Content: View>: View {
    @ViewBuilder let content: () -> Content

    private static var maxContentWidth: CGFloat { 720 }

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    content()
                }
                .frame(maxWidth: Self.maxContentWidth, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(24)
        }
    }
}
