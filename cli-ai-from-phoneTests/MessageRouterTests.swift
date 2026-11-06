import Testing
@testable import Steward

@Suite struct MessageRouterTests {
    let r = MessageRouter()

    @Test func bangPrefixRoutesToShell() {
        #expect(r.route("!ls -la", hasPendingPermission: false) == .shell("ls -la"))
    }

    @Test func slashPrefixRoutesToCommand() {
        #expect(r.route("/stop", hasPendingPermission: false) == .command(.stop))
        #expect(r.route("/project demoapp", hasPendingPermission: false) == .command(.project("demoapp")))
    }

    @Test func plainTextGoesToClaude() {
        #expect(r.route("帮我修一下崩溃", hasPendingPermission: false) == .prompt("帮我修一下崩溃"))
    }

    /// 核心用例：yes 的归属取决于有没有待决权限。旧版无法处理这个歧义。
    @Test func withPendingPermissionBothWordsAndDigitsAreAnswers() {
        #expect(r.route("yes", hasPendingPermission: true) == .permission(.allow))
        #expect(r.route("no", hasPendingPermission: true) == .permission(.deny))
        #expect(r.route("1", hasPendingPermission: true) == .permission(.allow))
        #expect(r.route("0", hasPendingPermission: true) == .permission(.deny))
        #expect(r.route("2", hasPendingPermission: true) == .permission(.allowAlways))
    }

    @Test func withoutPendingPermissionYesIsAPlainMessage() {
        #expect(r.route("yes", hasPendingPermission: false) == .prompt("yes"))
    }

    /// 手机输入场景，大小写不敏感
    @Test func commandsAreCaseInsensitive() {
        #expect(r.route("YES", hasPendingPermission: true) == .permission(.allow))
        #expect(r.route("/STOP", hasPendingPermission: false) == .command(.stop))
    }

    @Test func surroundingWhitespaceIsIgnored() {
        #expect(r.route("  !pwd  ", hasPendingPermission: false) == .shell("pwd"))
    }

    /// shell 优先级最高：即使有待决权限，! 开头仍走 shell
    @Test func shellPrefixOutranksPermissionAnswer() {
        #expect(r.route("!yes", hasPendingPermission: true) == .shell("yes"))
    }

    @Test func unknownSlashCommandIsTreatedAsPlainText() {
        #expect(r.route("/瞎写的", hasPendingPermission: false) == .prompt("/瞎写的"))
    }

    @Test func projectNameKeepsCaseWhileVerbIsCaseInsensitive() {
        #expect(r.route("/project DemoApp", hasPendingPermission: false)
                == .command(.project("DemoApp")))
        #expect(r.route("/PROJECT DemoApp", hasPendingPermission: false)
                == .command(.project("DemoApp")))
        #expect(r.route("/project demo-app-ios", hasPendingPermission: false)
                == .command(.project("demo-app-ios")))
    }
}

@Suite struct ProjectListingTests {
    let r = MessageRouter()

    /// A bare `/project` used to fail command parsing and fall through to
    /// `.prompt`, which sent the literal text "/project" to Claude. From a phone
    /// there is no other way to discover the configured names.
    @Test func bareProjectCommandListsInsteadOfBecomingAPrompt() {
        #expect(r.route("/project", hasPendingPermission: false) == .command(.listProjects))
        #expect(r.route("/project   ", hasPendingPermission: false) == .command(.listProjects))
        #expect(r.route("/PROJECT", hasPendingPermission: false) == .command(.listProjects))
    }

    @Test func projectCommandWithNameStillSwitches() {
        #expect(r.route("/project mg", hasPendingPermission: false) == .command(.project("mg")))
        #expect(r.route("/project  LineCase ", hasPendingPermission: false)
                == .command(.project("LineCase")))
    }
}

@Suite struct ProjectListTextTests {
    @Test func marksCurrentProjectAndTellsUserHowToSwitch() {
        let text = AppState.projectListText(
            projects: [Project(name: "mg", path: "/a"), Project(name: "api", path: "/b")],
            currentPath: "/b")
        #expect(text.contains("▸ api  (current)"))
        #expect(text.contains("  mg"))
        #expect(text.contains("/project <name>"))
    }

    @Test func emptyListSaysWhereToAddProjects() {
        let text = AppState.projectListText(projects: [], currentPath: nil)
        #expect(text.localizedCaseInsensitiveContains("no projects"))
        #expect(text.contains("Projects"))
    }
}
