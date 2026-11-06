import Foundation

/// 单个会话。用 actor 是因为 stdin 写入与 stdout 读取分处不同线程，
/// 状态必须串行化——这正是旧版那堆 state_lock 想解决而没解决干净的问题。
actor ClaudeSession {
    private let transport: any ProcessTransport

    /// `events()` 是幂等的：第一次调用时创建流并启动唯一的消费 Task，
    /// 缓存下来；之后的调用返回同一个 AsyncStream 实例，不会再起第二个
    /// Task 去读 transport.stdout。
    ///
    /// 真正的契约：这条流只能被**恰好一个**消费者消费**恰好一次**。
    /// `AsyncStream` 不做广播——多个迭代器并发消费同一条流时，元素会在
    /// 它们之间被轮流分掉，而不是各自收到完整拷贝；对已经被消费掉的元素，
    /// 迟到的第二个消费者永远看不到，流耗尽后再迭代只会立即拿到结束信号、
    /// 一个事件都不会有。也就是说，对同一个返回值发起第二次 `for await`
    /// 只会悄悄丢事件或把事件拆散在两个消费者之间，不会报错、也不会重放。
    ///
    /// 缓存本身不是为了让多消费成为合法用法，而是防止更严重的问题：如果
    /// 每次调用都重新起一个 Task，多个 Task 会并发抢同一个
    /// `transport.stdout`，彼此偷走对方的字节块，直接破坏各自
    /// `NDJSONReader` 的半行缓冲状态——这比"诚实地只有一个消费者"要糟糕
    /// 得多。缓存把"重复调用 events()"这件事变成安全的（拿到同一个未被
    /// 破坏的流引用），但并不让"同时用两个 for-await 消费它"变得安全。
    /// 调用方必须自己保证只有一个消费者在跑；本类目前唯一的消费者是
    /// `SessionManager` 派发的那个任务。
    private var cachedStream: AsyncStream<StreamEvent>?

    init(transport: any ProcessTransport) {
        self.transport = transport
    }

    /// 把字节流转成事件流。无法解码的行被跳过而非中断整条流。
    func events() -> AsyncStream<StreamEvent> {
        if let cachedStream {
            return cachedStream
        }
        let stream = AsyncStream<StreamEvent> { continuation in
            Task { [transport] in
                var reader = NDJSONReader()
                for await chunk in transport.stdout {
                    for line in reader.feed(chunk) {
                        if let event = try? StreamEvent(jsonLine: line) {
                            continuation.yield(event)
                        }
                    }
                }
                continuation.finish()
            }
        }
        cachedStream = stream
        return stream
    }

    func send(_ text: String) throws {
        let payload: [String: Any] = [
            "type": "user",
            "message": ["role": "user",
                        "content": [["type": "text", "text": text]]],
        ]
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)   // 必须换行结尾，否则 claude 读不到这一行
        try transport.write(data)
    }

    func stop() {
        transport.terminate()
    }
}
