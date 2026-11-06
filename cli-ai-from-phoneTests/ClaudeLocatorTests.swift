import Testing
@testable import Steward

@Suite struct ClaudeLocatorTests {
    @Test func login_shell_result_is_detected_and_verified() {
        let installation = ClaudeLocator.detect(
            preferredPath: nil,
            shellOutput: "  /opt/homebrew/bin/claude\n",
            fallbackPaths: ["/Users/test/.local/bin/claude"],
            isExecutable: { $0 == "/opt/homebrew/bin/claude" },
            version: { _ in "2.1.278" }
        )

        #expect(installation == .ready(path: "/opt/homebrew/bin/claude", version: "2.1.278"))
    }

    @Test func interactive_shell_is_used_to_find_the_users_claude_command() {
        var receivedExecutable: String?
        var receivedArguments: [String]?

        let path = ClaudeLocator.shellClaudePath { executable, arguments in
            receivedExecutable = executable
            receivedArguments = arguments
            return "/Users/test/.nvm/versions/node/current/bin/claude"
        }

        #expect(path == "/Users/test/.nvm/versions/node/current/bin/claude")
        #expect(receivedExecutable == "/bin/zsh")
        #expect(receivedArguments == ["-ic", "command -v claude"])
    }

    @Test func shell_path_wins_over_a_stale_saved_path() {
        let installation = ClaudeLocator.detect(
            preferredPath: "/custom/claude",
            shellOutput: "/opt/homebrew/bin/claude",
            fallbackPaths: ["/Users/test/.local/bin/claude"],
            isExecutable: { $0 == "/custom/claude" || $0 == "/opt/homebrew/bin/claude" },
            version: { path in path == "/opt/homebrew/bin/claude" ? "2.2.0" : "2.1.220" }
        )

        #expect(installation == .ready(path: "/opt/homebrew/bin/claude", version: "2.2.0"))
    }

    @Test func an_unverified_binary_is_not_accepted() {
        let installation = ClaudeLocator.detect(
            preferredPath: nil,
            shellOutput: "/opt/homebrew/bin/claude",
            fallbackPaths: [],
            isExecutable: { $0 == "/opt/homebrew/bin/claude" },
            version: { _ in nil }
        )

        #expect(installation == .missing)
    }
}
