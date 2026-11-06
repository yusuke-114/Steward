import Testing
import Foundation
@testable import Steward

@Suite struct SettingsTests {
    @Test func bot_token_is_persisted_in_user_defaults() {
        let name = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let settings = Settings(defaults: defaults)
        settings.botToken = "telegram-token-123"

        #expect(Settings(defaults: defaults).botToken == "telegram-token-123")
    }

    @Test func savingConnectionCredentialsOverwritesAnExistingBotToken() {
        let name = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let settings = Settings(defaults: defaults)
        settings.botToken = "old-revoked-token"

        #expect(settings.saveConnectionCredentials(
            token: "  new-valid-token  ",
            userIDText: "8540549765") == true)

        let reloaded = Settings(defaults: defaults)
        #expect(reloaded.botToken == "new-valid-token")
        #expect(reloaded.allowedUserIDs == [8540549765])
    }

    @Test func keep_mac_awake_preference_is_persisted_in_user_defaults() {
        let name = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let settings = Settings(defaults: defaults)
        #expect(!settings.keepMacAwake)

        settings.keepMacAwake = true
        #expect(Settings(defaults: defaults).keepMacAwake)
    }

    @Test func projectListPersists() {
        let s = Settings(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        s.projects = [Project(name: "mg", path: "/tmp/mg")]
        s.currentProjectPath = "/tmp/mg"
        #expect(s.currentProject?.name == "mg")
    }

    @Test func permissionTimeoutMustBeLessThanHookTimeout() {
        let s = Settings(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        s.permissionTimeout = 9999          // 越界值应被夹回
        #expect(s.permissionTimeout < 600)
        // 必须严格小于 hook.sh 的 curl --max-time（570），且留有真实余量，
        // 不能只贴着 570 夹（spec §6.2 三层超时链条）。
        #expect(s.permissionTimeout < 570)
    }

    @Test func timeoutUpperBoundIsClampedWithMargin() {
        let name = "test-\(UUID())"
        let d = UserDefaults(suiteName: name)!
        let s = Settings(defaults: d)
        s.permissionTimeout = 9999
        // 记录下来的应该是被夹过的值，而不是原始越界输入 9999。
        #expect(s.permissionTimeout == 540)
        // UserDefaults 里持久化的也必须是夹后的值，不是 9999。
        #expect(d.object(forKey: "permissionTimeout") as? TimeInterval == 540)
    }

    @Test func timeoutLowerBoundIsAlsoClamped() {
        let s = Settings(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        s.permissionTimeout = -5
        #expect(s.permissionTimeout == 10)
    }

    @Test func timeoutWithinValidRangeIsKeptAsIs() {
        let s = Settings(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        s.permissionTimeout = 120
        #expect(s.permissionTimeout == 120)
    }

    @Test func defaultAllowListContainsOnlyIdempotentOperations() {
        let s = Settings(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        #expect(s.allowedTools.contains("Read"))
        #expect(s.allowedTools.contains("Grep"))
        // 写操作、删除操作、任意 shell 命令绝不能默认放行——
        // 权限桥存在的意义就是这些操作需要人来点头。
        #expect(!s.allowedTools.contains("Write"))
        #expect(!s.allowedTools.contains("Edit"))
        #expect(!s.allowedTools.contains("Bash"))
        #expect(!s.allowedTools.contains("NotebookEdit"))
        #expect(!s.allowedTools.contains("WebFetch"))
    }

    @Test func addingAllowedToolTrimsDeduplicatesAndIgnoresEmpty() {
        #expect(Settings.allowedTools(["Read"], adding: "  Bash  ") == ["Read", "Bash"])
        #expect(Settings.allowedTools(["Read"], adding: "Read") == ["Read"])
        #expect(Settings.allowedTools(["Read"], adding: "   ") == ["Read"])
    }

    // MARK: - Checklist ↔ allowedTools round-trip
    //
    // The Permissions checklist and the scoped-rules list are two views onto
    // the same `[String]` array. Toggling a known checklist tool must never
    // drop entries the checklist doesn't recognise — a scoped rule like
    // `Bash(rake swiftformat)`, or a bare tool name from a future Claude Code
    // this checklist has no row for.

    @Test func enablingKnownToolKeepsUnrecognisedEntriesIntact() {
        let start = ["Bash(rake swiftformat)", "SomeFutureTool"]
        let afterEnable = Settings.settingKnownTool("Read", enabled: true, in: start)
        #expect(afterEnable.contains("Read"))
        #expect(afterEnable.contains("Bash(rake swiftformat)"))
        #expect(afterEnable.contains("SomeFutureTool"))
    }

    @Test func disablingKnownToolKeepsUnrecognisedEntriesIntact() {
        let start = ["Read", "Bash(rake swiftformat)", "SomeFutureTool"]
        let afterDisable = Settings.settingKnownTool("Read", enabled: false, in: start)
        #expect(!afterDisable.contains("Read"))
        #expect(afterDisable.contains("Bash(rake swiftformat)"))
        #expect(afterDisable.contains("SomeFutureTool"))
    }

    @Test func repeatedToggleProducesNoDuplicatesOrAccidentalRemovals() {
        #expect(Settings.settingKnownTool("Read", enabled: true, in: ["Read"]) == ["Read"])
        #expect(Settings.settingKnownTool("Read", enabled: false, in: ["Grep"]) == ["Grep"])
    }

    @Test func addingOrRemovingScopedRuleLeavesCheckedToolsUntouched() {
        let start = ["Read", "TodoWrite"]
        let afterAdd = Settings.addingScopedRule("Bash(rake swiftformat)", to: start)
        #expect(afterAdd == ["Read", "TodoWrite", "Bash(rake swiftformat)"])

        let afterRemove = Settings.removingEntry("Bash(rake swiftformat)", from: afterAdd)
        #expect(afterRemove == ["Read", "TodoWrite"])
    }

    @Test func otherEntriesReturnsOnlyEntriesTheChecklistDoesNotKnow() {
        let mixed = ["Read", "Bash", "Bash(rake swiftformat)", "SomeFutureTool"]
        #expect(Settings.otherEntries(in: mixed) == ["Bash(rake swiftformat)", "SomeFutureTool"])
    }

    @Test func isKnownToolEnabledReflectsBareNamePresence() {
        #expect(Settings.isKnownToolEnabled("Read", in: ["Read", "Grep"]))
        #expect(!Settings.isKnownToolEnabled("Bash", in: ["Read", "Grep"]))
    }
}

@Suite struct ScopedRuleGateTests {
    /// The scoped-rule field must not become a way around the checklist's
    /// confirmation step. Typing a bare known tool name there would allow the
    /// whole tool — for Bash, that is unattended arbitrary shell execution.
    @Test func bareKnownToolNameIsRefusedInScopedRuleField() {
        for name in ToolPermission.knownNames {
            #expect(Settings.scopedRuleRejection(for: name) != nil,
                    "bare \(name) must be refused, it allows the whole tool")
        }
        #expect(Settings.scopedRuleRejection(for: "  Bash  ") != nil,
                "surrounding whitespace must not sneak a bare tool name through")
    }

    @Test func genuinelyScopedRulesAreAccepted() {
        for rule in ["Bash(rake swiftformat)", "Bash(git status)", "Edit(src/**)", "SomeFutureTool"] {
            #expect(Settings.scopedRuleRejection(for: rule) == nil,
                    "\(rule) is not a bare known tool name and must be accepted")
        }
    }
}
