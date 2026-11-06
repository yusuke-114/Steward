import SwiftUI

/// Fourth sidebar section's detail pane. Read-only diagnostic trail: no
/// export, no file, no persistence (LogStore is explicitly scoped that way).
///
/// Chronological order is load-bearing, not a stylistic choice: the owner
/// reads this to reconstruct a causal chain ("message received → routed to
/// Claude → permission requested → timed out") while away from the Mac, and
/// that only reads correctly top-to-bottom. Newest-first would invert it.
struct LogView: View {
    let log: LogStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(log.entries) { entry in
                            row(for: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .onAppear { scrollToNewest(proxy) }
                .onChange(of: log.entries.count) { _, _ in scrollToNewest(proxy) }
            }
        }
        .padding(24)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Logs")
                    .font(.title.weight(.bold))
                Text("What happened while you were away from the Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Clear") { log.clear() }
                .buttonStyle(.glass)
        }
    }

    private func row(for entry: LogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(entry.level.rawValue.uppercased())
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .foregroundStyle(color(for: entry.level))
                .frame(width: 42, alignment: .leading)

            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .info: .secondary
        case .warn: .orange
        case .error: .red
        }
    }

    /// Auto-scrolls to the newest (bottom) entry both when new lines arrive
    /// and when the section is first opened — the owner chose oldest-at-top
    /// specifically so this always lands on the most recent event without
    /// requiring a manual scroll.
    private func scrollToNewest(_ proxy: ScrollViewProxy) {
        guard let last = log.entries.last else { return }
        withAnimation {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
