import Foundation
import Observation

enum LogLevel: String, Equatable {
    case info, warn, error
}

struct LogEntry: Equatable, Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let message: String
}

/// 诊断日志的内存环形缓冲区，容量固定为 1000 条，超出后最旧的先被淘汰。
///
/// 刻意不写文件、不导出、不跨进程重启持久化——这是产品决定（owner 明确
/// 不想要），不是偷懒省掉的功能。这个视图只回答“刚才发生了什么”，不是
/// 审计日志；App 重启后清空是可接受的代价。
///
/// **隔离选择：`@MainActor`。** 唯一的写入方是 `AppState`，而 `AppState`
/// 自身已经整体钉在 `@MainActor` 上（见 AppState.swift 顶部注释：Telegram
/// 长轮询、SessionManager/PermissionBridge 的回调都会先跳回
/// `Task { @MainActor in ... }` 再落到 AppState 的方法体里）。这意味着
/// 到达这里的每一次 `log.info/warn/error(...)` 调用本来就已经在主 actor
/// 上，把 `LogStore` 也钉在 `@MainActor` 上，写入就是普通的同步方法调用，
/// 不需要额外的锁或 `await` 跳转；日志视图（SwiftUI，同样隐式在主 actor
/// 上跑）也能直接读 `entries`，不必跨隔离域。唯一的代价是测试里构造
/// `LogStore()` 需要 `await`（跨 actor 边界的实例化）——这与本项目里
/// `AppState()`/`SessionManager` 等已有的 actor 化组件一致，不是新增的
/// 摩擦。
@MainActor
@Observable
final class LogStore {
    static let capacity = 1000

    private(set) var entries: [LogEntry] = []

    func info(_ message: String) { append(.info, message) }
    func warn(_ message: String) { append(.warn, message) }
    func error(_ message: String) { append(.error, message) }

    func clear() {
        entries.removeAll()
    }

    private func append(_ level: LogLevel, _ message: String) {
        entries.append(LogEntry(timestamp: Date(), level: level,
                                message: TelegramClient.redactingToken(in: message)))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }
}
