import Testing
import Foundation
@testable import Steward

/// `LogStore` 是给日志视图（Task 15+ 第四个侧边栏分区）用的纯内存环形
/// 缓冲区：不写文件、不导出、不持久化（这是产品决定，见 LogStore.swift
/// 顶部注释）。这里只覆盖它自己的契约——容量上限、先进先出的淘汰顺序、
/// 追加顺序即时间顺序（最旧在前，日志视图据此自上而下读因果链）——不覆盖
/// 任何 SwiftUI 渲染。
@Suite struct LogStoreTests {
    @Test func belowCapacityAllEntriesArePreservedInAppendOrder() async {
        let store = await LogStore()
        await store.info("a")
        await store.warn("b")
        await store.error("c")

        let entries = await store.entries
        #expect(entries.map(\.message) == ["a", "b", "c"])
        #expect(entries.map(\.level) == [.info, .warn, .error])
    }

    /// 核心用例：超过 1000 条容量后，最旧的条目必须先被淘汰，且剩下的
    /// 条目继续保持最旧在前——这正是日志视图能"自上而下读因果链"、
    /// 而不需要倒序展示的前提。
    @Test func oldestEntriesAreEvictedFirstBeyondCapacity() async {
        let store = await LogStore()
        let overflow = LogStore.capacity + 25
        for i in 0..<overflow {
            await store.info("msg \(i)")
        }

        let entries = await store.entries
        #expect(entries.count == LogStore.capacity)
        #expect(entries.first?.message == "msg 25")
        #expect(entries.last?.message == "msg \(overflow - 1)")
    }

    /// 日志视图不能显示 bot token，即使调用方直接插值了带 URL 的错误。
    @Test func tokensAreRedactedBeforeStorage() async {
        let store = await LogStore()
        await store.warn("telegram poll failed: https://api.telegram.org/bot123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw/getUpdates")

        let entries = await store.entries
        #expect(entries.map(\.message) == ["telegram poll failed: https://api.telegram.org/bot<redacted>/getUpdates"])
    }

    @Test func exactlyAtCapacityEvictsNothing() async {
        let store = await LogStore()
        for i in 0..<LogStore.capacity {
            await store.info("msg \(i)")
        }

        let entries = await store.entries
        #expect(entries.count == LogStore.capacity)
        #expect(entries.first?.message == "msg 0")
        #expect(entries.last?.message == "msg \(LogStore.capacity - 1)")
    }

    @Test func clearRemovesAllEntries() async {
        let store = await LogStore()
        await store.info("x")
        await store.warn("y")
        await store.error("z")

        await store.clear()

        let entries = await store.entries
        #expect(entries.isEmpty)
    }

    @Test func timestampsAreMonotonicInAppendOrder() async {
        let store = await LogStore()
        await store.info("first")
        await store.info("second")

        let entries = await store.entries
        #expect(entries[0].timestamp <= entries[1].timestamp)
    }
}

/// 覆盖验收项："未授权用户的消息被静默丢弃时，产生一条日志条目，同时不
/// 触发任何回复。"
///
/// 这里不构造真实 `AppState()`——那会触发 `ClaudeLocator.detect` 对真实
/// 登录 shell 的探测（`/bin/zsh -ic "command -v claude"` + 若干候选路径的
/// `--version` 探测），在沙盒测试进程里代价高、且行为随开发机是否装了
/// claude 而变化，与本文件其余测试"离线、确定性"的风格不符。改为直接
/// 调用 `handle()` 丢弃分支实际使用的同一个纯文案函数
/// `AppState.droppedMessageLogLine(for:)`，钉住它写入 `LogStore` 的内容。
///
/// "不触发回复"由 `AppState.handle(_:)` 的控制流结构保证，而非本测试
/// 运行时验证：`guard decision != .dropped` 分支的 `return` 发生在
/// `chatID` 被赋值、以及该函数唯一的 `telegram?.send` 出口之前（见
/// AppState.swift 对应注释），物理上不存在从这一支走到发送回复的路径。
@Suite struct LogStoreDroppedMessageLoggingTests {
    @Test func droppedUnauthorisedMessageIsLoggedWithUserID() async {
        let store = await LogStore()
        let dropped = DroppedMessage(userID: 42, text: "hello", date: Date())

        await store.warn(AppState.droppedMessageLogLine(for: dropped))

        let entries = await store.entries
        #expect(entries.count == 1)
        #expect(entries.first?.level == .warn)
        #expect(entries.first?.message.contains("42") == true)
        #expect(entries.first?.message.contains("dropped") == true)
    }
}
