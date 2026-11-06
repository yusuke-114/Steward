import Testing
import Foundation
@testable import Steward

@Suite struct StreamEventTests {
    @Test func decodesSystemInitEvent() throws {
        let line = #"{"type":"system","subtype":"init","session_id":"abc-123"}"#
        let e = try StreamEvent(jsonLine: Data(line.utf8))
        #expect(e == .system(subtype: "init", sessionID: "abc-123"))
    }

    @Test func decodesAssistantText() throws {
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"你好"}]}}"#
        let e = try StreamEvent(jsonLine: Data(line.utf8))
        #expect(e == .assistant(text: "你好", toolUses: []))
    }

    @Test func decodesToolUse() throws {
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#
        let e = try StreamEvent(jsonLine: Data(line.utf8))
        #expect(e == .assistant(text: nil, toolUses: [ToolUse(id: "t1", name: "Bash")]))
    }

    @Test func decodesTurnResult() throws {
        let line = #"{"type":"result","subtype":"success","is_error":false,"result":"做完了"}"#
        let e = try StreamEvent(jsonLine: Data(line.utf8))
        #expect(e == .result(text: "做完了", isError: false))
    }

    /// 未知事件类型不得崩溃——Claude Code 升级会引入新类型
    @Test func unknownTypeFallsBackToUnknown() throws {
        let line = #"{"type":"某种未来事件","payload":{"a":1}}"#
        let e = try StreamEvent(jsonLine: Data(line.utf8))
        #expect(e == .unknown(type: "某种未来事件"))
    }

    /// 实测出现过的未文档化类型，必须走 unknown 而非崩溃
    @Test func undocumentedRateLimitEventDoesNotCrash() throws {
        let line = #"{"type":"rate_limit_event","payload":{}}"#
        let e = try StreamEvent(jsonLine: Data(line.utf8))
        #expect(e == .unknown(type: "rate_limit_event"))
    }

    @Test func malformedJSONThrowsInsteadOfCrashing() {
        #expect(throws: (any Error).self) {
            try StreamEvent(jsonLine: Data("{不是 json".utf8))
        }
    }

    @Test func toolResultErrorFlagComesFromNestedContentNotTopLevel() throws {
        // user 事件没有顶层 is_error；只读顶层会让失败的工具调用被判成成功
        let ok = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","is_error":false}]}}"#
        #expect(try StreamEvent(jsonLine: Data(ok.utf8)) == .toolResult(isError: false))

        let failed = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","is_error":true}]}}"#
        #expect(try StreamEvent(jsonLine: Data(failed.utf8)) == .toolResult(isError: true))
    }

    private func decodeFixture(_ name: String) throws -> [StreamEvent] {
        let url = Bundle(for: BundleToken.self).url(forResource: name, withExtension: "ndjson")
        let data = try Data(contentsOf: #require(url))
        let lines = data.split(separator: 0x0A).filter { !$0.isEmpty }
        return try lines.map { try StreamEvent(jsonLine: Data($0)) }
    }

    @Test func everyLineOfRealFixtureDecodes() throws {
        let events = try decodeFixture("basic-turn")
        #expect(events.count >= 3)

        // 至少一个 system(init)：实测 basic-turn 里 system 出现 3 次
        // （hook_started / hook_response / init），必须能取出真正的 init。
        let hasInit = events.contains {
            if case .system(subtype: "init", sessionID: _) = $0 { return true }
            return false
        }
        #expect(hasInit)

        // 至少一个 assistant 带非空文本（"你好世界"）
        let hasAssistantText = events.contains {
            if case .assistant(text: .some(let t), toolUses: _) = $0 { return !t.isEmpty }
            return false
        }
        #expect(hasAssistantText)

        // 最后一个事件是 result（rate_limit_event 排在 result 之前，但仍需正确解码为 unknown）
        guard case .result = events.last else {
            Issue.record("basic-turn 最后一个事件应为 .result，实际是 \(String(describing: events.last))")
            return
        }
    }

    @Test func toolUseFixtureYieldsToolUsesAndToolResult() throws {
        let events = try decodeFixture("tool-use")

        let hasToolUse = events.contains {
            if case .assistant(text: _, toolUses: let uses) = $0 { return !uses.isEmpty }
            return false
        }
        #expect(hasToolUse)

        let hasToolResult = events.contains {
            if case .toolResult = $0 { return true }
            return false
        }
        #expect(hasToolResult)

        guard case .result = events.last else {
            Issue.record("tool-use 最后一个事件应为 .result，实际是 \(String(describing: events.last))")
            return
        }
    }
}
