import Testing
import Foundation
@testable import Steward

@Suite struct ClaudeLaunchArgsTests {
    let sid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    // Helper to verify flag→value adjacency in args array
    func expectFlagValue(_ args: [String], flag: String, value: String) {
        guard let i = args.firstIndex(of: flag) else {
            #expect(false, "缺少flag \(flag)")
            return
        }
        guard i + 1 < args.count else {
            #expect(false, "flag \(flag) 后没有值")
            return
        }
        #expect(args[i + 1] == value, "flag \(flag) 期望值 \(value) 但得到 \(args[i + 1])")
    }

    // Helper to verify flag is present (for bare flags like --verbose)
    func expectFlagPresent(_ args: [String], flag: String) {
        #expect(args.contains(flag), "缺少flag \(flag)")
    }

    @Test func newSessionUsesSessionID() {
        let a = ClaudeLaunchArgs.build(sessionID: sid, resume: false,
                                       settingsPath: "/tmp/s.json", allowedTools: [])
        #expect(a.contains("--session-id"))
        #expect(a.contains(sid.uuidString))
        #expect(!a.contains("--resume"))
    }

    @Test func revivedSessionUsesResume() {
        let a = ClaudeLaunchArgs.build(sessionID: sid, resume: true,
                                       settingsPath: "/tmp/s.json", allowedTools: [])
        #expect(a.contains("--resume"))
        #expect(!a.contains("--session-id"))
    }

    @Test func everyRequiredStreamingArgumentIsPresent() {
        let a = ClaudeLaunchArgs.build(sessionID: sid, resume: false,
                                       settingsPath: "/tmp/s.json", allowedTools: [])

        // Verify flag→value adjacency for all critical parameters
        expectFlagValue(a, flag: "--input-format", value: "stream-json")
        expectFlagValue(a, flag: "--output-format", value: "stream-json")
        expectFlagValue(a, flag: "--permission-prompts", value: "host")
        expectFlagValue(a, flag: "--settings", value: "/tmp/s.json")
        expectFlagValue(a, flag: "--session-id", value: sid.uuidString)
        expectFlagPresent(a, flag: "--verbose")
        expectFlagPresent(a, flag: "-p")
    }

    @Test func emptyAllowListOmitsTheFlag() {
        let a = ClaudeLaunchArgs.build(sessionID: sid, resume: false,
                                       settingsPath: "/tmp/s.json", allowedTools: [])
        #expect(!a.contains("--allowedTools"))
    }

    @Test func eachAllowedToolBecomesItsOwnArgument() {
        let a = ClaudeLaunchArgs.build(sessionID: sid, resume: false,
                                       settingsPath: "/tmp/s.json",
                                       allowedTools: ["Read", "Bash(git status)"])
        let i = try! #require(a.firstIndex(of: "--allowedTools"))
        #expect(a[i + 1] == "Read")
        #expect(a[i + 2] == "Bash(git status)")
    }
}
