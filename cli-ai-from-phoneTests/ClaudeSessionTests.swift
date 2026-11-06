import Testing
import Foundation
@testable import Steward

/// 从 fixture 逐块重放的假 transport，块边界故意切得很碎，
/// 以此同时压测 NDJSONReader 的半行处理。
final class FakeTransport: ProcessTransport, @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    private let backingStdout: AsyncStream<Data>
    private(set) var written: [Data] = []
    private(set) var terminated = false

    /// `transport.stdout` 每被读取一次算一次订阅——这正是
    /// `ClaudeSession.events()` 里每个消费 Task 启动 `for await chunk in
    /// transport.stdout` 时触发的那次访问。如果 events() 真的只起了一个
    /// Task（缓存生效），这个计数在整条测试里应恒为 1；如果哪天缓存被
    /// 悄悄去掉、每次调用 events() 都重新起一个 Task 读 transport.stdout，
    /// 这个数字就会跳到 2，测试才有牙齿去咬住这个回归——只看"stream2 耗尽
    /// 后不再出事件"不足以区分"真的复用同一条流"和"根本没人读 stream2 对
    /// 应的 Task、它自己在背后跟 stream1 的 Task 抢 transport.stdout"。
    private(set) var stdoutAccessCount = 0

    var stdout: AsyncStream<Data> {
        stdoutAccessCount += 1
        return backingStdout
    }

    init() {
        var c: AsyncStream<Data>.Continuation!
        backingStdout = AsyncStream { c = $0 }
        continuation = c
    }

    func replay(_ data: Data, chunkSize: Int = 7) {
        var i = data.startIndex
        while i < data.endIndex {
            let j = data.index(i, offsetBy: chunkSize, limitedBy: data.endIndex) ?? data.endIndex
            continuation.yield(Data(data[i..<j]))
            i = j
        }
        continuation.finish()
    }

    func write(_ data: Data) throws { written.append(data) }
    func terminate() { terminated = true }
}

@Suite struct ClaudeSessionTests {
    @Test func replayingFixtureYieldsFullEventSequence() async throws {
        let url = Bundle(for: BundleToken.self).url(forResource: "basic-turn", withExtension: "ndjson")
        let data = try Data(contentsOf: #require(url))

        let fake = FakeTransport()
        let session = ClaudeSession(transport: fake)
        let stream = await session.events()
        fake.replay(data)

        var events: [StreamEvent] = []
        for await e in stream { events.append(e) }

        #expect(!events.isEmpty)
        // 最后一个事件必须是 result——回合结束的明确信号
        guard case .result = events.last else {
            Issue.record("最后一个事件应为 .result，实际 \(String(describing: events.last))")
            return
        }
    }

    @Test func sendWritesValidStreamJSONUserMessage() async throws {
        let fake = FakeTransport()
        let session = ClaudeSession(transport: fake)
        try await session.send("你好")

        #expect(fake.written.count == 1)
        let line = try #require(fake.written.first)
        // 必须以换行结尾，否则 claude 读不到这一行
        #expect(line.last == 0x0A)

        let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any]
        #expect(obj?["type"] as? String == "user")
        let msg = obj?["message"] as? [String: Any]
        #expect(msg?["role"] as? String == "user")
    }

    @Test func stopTerminatesTransport() async {
        let fake = FakeTransport()
        let session = ClaudeSession(transport: fake)
        await session.stop()
        #expect(fake.terminated)
    }

    @Test func repeatedEventsCallsReturnSameStreamWithoutDuplicateDelivery() async throws {
        let url = Bundle(for: BundleToken.self).url(forResource: "basic-turn", withExtension: "ndjson")
        let data = try Data(contentsOf: #require(url))

        let fake = FakeTransport()
        let session = ClaudeSession(transport: fake)
        let stream1 = await session.events()
        let stream2 = await session.events()

        fake.replay(data)

        var events1: [StreamEvent] = []
        for await e in stream1 { events1.append(e) }
        #expect(!events1.isEmpty)

        // 若两次调用真的拿到同一条流，stream1 耗尽后 stream2 应该立即
        // 结束、一个事件都不再产出——证明底层只有一个消费者、事件没有
        // 被重复投递到两个引用上。
        var events2: [StreamEvent] = []
        for await e in stream2 { events2.append(e) }
        #expect(events2.isEmpty)

        // 上面两条断言本身不足以证明只有一个 Task 在读 transport.stdout：
        // 一个"第二次调用返回全新、已经 finish 的流"的错误实现也能让它们
        // 都通过，却完全没有缓存本该提供的保护（两个 Task 仍会抢占
        // transport.stdout，弄坏 NDJSONReader 的半行状态）。真正钉住
        // "只有一个消费者"这条性质的是订阅计数：不管调用 events() 几次，
        // transport.stdout 只应该被读取一次。
        #expect(fake.stdoutAccessCount == 1)
    }

    @Test func undecodableLineIsSkippedWithoutBreakingTheStream() async throws {
        let lines = [
            #"{"type":"system","subtype":"init","session_id":"abc-123"}"#,
            "this is not json at all {{{",
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}"#,
            #"{"type":"result","result":"done","is_error":false}"#,
        ]
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)

        let fake = FakeTransport()
        let session = ClaudeSession(transport: fake)
        let stream = await session.events()
        fake.replay(data)

        var events: [StreamEvent] = []
        for await e in stream { events.append(e) }

        // 畸形行被跳过，其余 3 行按顺序完整到达，流仍然正常结束（能被
        // for-await 耗尽而不是挂起）。
        #expect(events.count == 3)

        guard case .system(let subtype, let sessionID) = events[0] else {
            Issue.record("第一个事件应为 .system，实际 \(String(describing: events.first))")
            return
        }
        #expect(subtype == "init")
        #expect(sessionID == "abc-123")

        guard case .assistant(let text, _) = events[1] else {
            Issue.record("第二个事件应为 .assistant，实际 \(String(describing: events[1]))")
            return
        }
        #expect(text == "hi")

        guard case .result(let text, let isError) = events[2] else {
            Issue.record("第三个事件应为 .result，实际 \(String(describing: events[2]))")
            return
        }
        #expect(text == "done")
        #expect(isError == false)
    }
}
