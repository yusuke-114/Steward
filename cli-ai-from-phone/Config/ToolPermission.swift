import Foundation

/// One entry in the Permissions checklist: a tool Claude Code can call
/// without asking, described in plain language, grouped by how much trust
/// enabling it requires.
///
/// This is deliberately *not* the full set of tools Claude Code knows about —
/// only the ones worth a dedicated checkbox. Anything else the user (or a
/// future Claude Code version) puts in `Settings.allowedTools` — a tool we
/// don't list here, or a scoped rule like `Bash(rake swiftformat)` — still
/// round-trips through the scoped-rules list (see SettingsView) instead of
/// being silently dropped.
struct ToolPermission: Identifiable {
    enum Risk {
        case safe
        case needsThought
        case dangerous
    }

    let name: String
    let summary: String
    let risk: Risk
    var id: String { name }

    /// Every allow-listed entry means the same thing: Claude may perform
    /// that action immediately, with no confirmation, including while the
    /// owner is away from this Mac. The per-tool summaries below describe
    /// what the action *is*; that consequence applies to all of them.
    static let known: [ToolPermission] = [
        ToolPermission(name: "Read", summary: "Read files.", risk: .safe),
        ToolPermission(name: "Grep", summary: "Search file contents.", risk: .safe),
        ToolPermission(name: "Glob", summary: "Search file names.", risk: .safe),
        ToolPermission(name: "TodoWrite", summary: "Track its own task list.", risk: .safe),
        ToolPermission(name: "Edit", summary: "Can modify existing files without asking you first.", risk: .needsThought),
        ToolPermission(name: "Write", summary: "Can create or overwrite files without asking you first.", risk: .needsThought),
        ToolPermission(name: "WebFetch", summary: "Can reach the internet without asking you first.", risk: .needsThought),
        ToolPermission(name: "Bash", summary: "Can run any shell command it chooses — including destructive ones — without asking you first, even while nobody is at the Mac.", risk: .dangerous),
    ]

    static let knownNames: Set<String> = Set(known.map(\.name))
}

extension Settings {
    /// Whether a known checklist tool (a bare name such as `"Read"`) is
    /// currently allow-listed.
    static func isKnownToolEnabled(_ tool: String, in allowedTools: [String]) -> Bool {
        allowedTools.contains(tool)
    }

    /// Turns one checklist entry on or off without disturbing any other
    /// entry already in the list — including entries this checklist does
    /// not recognise (scoped rules, or tool names from a newer Claude Code
    /// this app doesn't know about yet). Those are looked up and preserved
    /// by `otherEntries(in:)`; this function only ever adds or removes the
    /// single bare `tool` name it was asked about.
    static func settingKnownTool(_ tool: String, enabled: Bool, in allowedTools: [String]) -> [String] {
        if enabled {
            guard !allowedTools.contains(tool) else { return allowedTools }
            return allowedTools + [tool]
        } else {
            return allowedTools.filter { $0 != tool }
        }
    }

    /// Entries that are not one of the checklist's known bare tool names:
    /// scoped rules such as `Bash(rake swiftformat)`, and any bare tool name
    /// (present or future) the checklist doesn't have a row for. These are
    /// the entries the scoped-rules list edits directly, so nothing typed
    /// by hand or written by an older/newer version of this app is ever
    /// silently lost when the checklist toggles a known tool.
    static func otherEntries(in allowedTools: [String]) -> [String] {
        allowedTools.filter { !ToolPermission.knownNames.contains($0) }
    }

    /// Appends a scoped rule verbatim. Rules are passed through to
    /// `--allowedTools` exactly as typed — this app does not validate,
    /// normalise, or otherwise interpret them; matching is decided entirely
    /// by Claude Code.
    /// Why a string typed into the scoped-rule field must be refused, or nil if
    /// it is fine to add.
    ///
    /// A bare known tool name is not a narrower rule — it allows the whole tool,
    /// the same as ticking its checkbox, but skipping the confirmation that the
    /// checkbox requires. The field's own placeholder suggests "Bash(...)", so a
    /// user reaching for a scoped rule can submit just "Bash" and grant
    /// unattended arbitrary shell execution while believing they narrowed it.
    static func scopedRuleRejection(for rawRule: String) -> String? {
        let rule = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ToolPermission.knownNames.contains(rule) else { return nil }
        return "\"\(rule)\" allows the whole tool, not a narrower slice of it. "
             + "Use the checklist above to enable it — that path asks for confirmation first."
    }

    static func addingScopedRule(_ rule: String, to allowedTools: [String]) -> [String] {
        Settings.allowedTools(allowedTools, adding: rule)
    }

    /// Removes one entry from the scoped-rules list (or, in principle, any
    /// other list entry) verbatim, leaving every other entry — including
    /// checklist tools — untouched.
    static func removingEntry(_ entry: String, from allowedTools: [String]) -> [String] {
        allowedTools.filter { $0 != entry }
    }
}
