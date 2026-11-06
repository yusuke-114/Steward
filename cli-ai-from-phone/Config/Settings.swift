import Foundation
import Observation

struct Project: Codable, Equatable, Identifiable {
    let name: String
    let path: String
    var id: String { path }
}

@Observable
final class Settings {
    private let defaults: UserDefaults

    /// permissionTimeout 的合法区间。
    ///
    /// 这是三层超时链条（spec §6.2；同一条注释见 PermissionBridge.swift、
    /// hook.sh、HookSettings.swift）里最短的一层，必须严格小于 hook.sh 的
    /// `curl --max-time 570`：
    ///     Settings.permissionTimeout（这里，喂给 PermissionBridge）
    ///       < curl --max-time 570s
    ///       < HookSettings.json 里 Claude 声明的 hook timeout 600s
    /// 这条链已经在这个项目里被单独改动其中一环打破过三次，所以上界不是贴着
    /// 570 夹（那样用户在 UI 上一拉满就会撞破链条，且没有余量吸收 hook.sh
    /// 自身启动/stdin 读取/jq 校验的开销），而是复用 hook.sh 里
    /// "570 = 600 - 30" 同一条 30 秒安全余量的惯例，再减一次：
    /// 540 = 570 - 30。下界 10 秒只是防止把超时调到接近 0、瞬间自动拒绝、
    /// 用户还没来得及看到手机通知。
    static let permissionTimeoutRange: ClosedRange<TimeInterval> = 10...540

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        projects = Self.decode([Project].self, defaults, "projects") ?? []
        currentProjectPath = defaults.string(forKey: "currentProjectPath")
        sessionIDsByProject = Self.decode([String: UUID].self, defaults, "sessionIDsByProject") ?? [:]
        botToken = defaults.string(forKey: "botToken")
        allowedUserIDs = (defaults.array(forKey: "allowedUserIDs") as? [Int64]) ?? []
        allowedTools = (defaults.array(forKey: "allowedTools") as? [String])
            ?? ["Read", "Grep", "Glob", "TodoWrite"]     // 默认只放行幂等操作
        claudePath = defaults.string(forKey: "claudePath")
        keepMacAwake = defaults.bool(forKey: "keepMacAwake")
        let stored = defaults.object(forKey: "permissionTimeout") as? TimeInterval ?? 300
        permissionTimeout = Self.clampTimeout(stored)
    }

    var projects: [Project] { didSet { Self.encode(projects, defaults, "projects") } }
    var currentProjectPath: String? { didSet { defaults.set(currentProjectPath, forKey: "currentProjectPath") } }
    var botToken: String? { didSet { defaults.set(botToken, forKey: "botToken") } }
    var allowedUserIDs: [Int64] { didSet { defaults.set(allowedUserIDs, forKey: "allowedUserIDs") } }
    var allowedTools: [String] { didSet { defaults.set(allowedTools, forKey: "allowedTools") } }
    var claudePath: String? { didSet { defaults.set(claudePath, forKey: "claudePath") } }
    var keepMacAwake: Bool { didSet { defaults.set(keepMacAwake, forKey: "keepMacAwake") } }

    /// 项目路径 → 该项目最近一次 claude 会话的 sessionID。落盘在 UserDefaults
    /// 里（spec §6.5「`lastSessionID` + `lastProjectPath` 存 UserDefaults」，
    /// §6.7「项目切换先 stop() 当前会话并保留其 sessionID 供日后 resume」）。
    ///
    /// 用一个按项目路径索引的字典而不是一对单独的 `lastSessionID` +
    /// `lastProjectPath`，是因为两条 spec 条款其实是同一件事的两种触发
    /// 方式——「重启后接续」和「切项目再切回来后接续」——都归结为「给定一个
    /// 项目路径，找到它上一次的会话 id（如果有）」。拆成两个独立字段只能
    /// 表达"最近一个"项目，切换到第三个项目后再切回第一个就会丢 id；字典
    /// 天然按项目分桶，且只需要一条持久化路径，不会出现两套存储各自维护
    /// 一份状态、彼此漂移不一致的问题。
    ///
    /// `SessionManager` 是唯一的读写方：开新会话时若命中已有 entry 则用
    /// `--resume` 续接；新 UUID 必须等 Claude 发出 system/init、确认会话
    /// 已实际建立后才写回，避免为一次失败启动留下不可恢复的 UUID。
    var sessionIDsByProject: [String: UUID] {
        didSet { Self.encode(sessionIDsByProject, defaults, "sessionIDsByProject") }
    }

    /// 必须严格小于 hook.sh 的 `curl --max-time`（570），见上面
    /// `permissionTimeoutRange` 的文档注释（spec §6.2 三层超时链条）。
    ///
    /// 实现说明：`didSet` 里对 `permissionTimeout` 的自我赋值会再触发一次
    /// `didSet`（这是 Swift 属性观察者的标准行为，不是 bug）。这里之所以
    /// 保证不会无限递归，是因为 `clampTimeout` 是幂等的纯函数——对任意输入
    /// x，`clampTimeout(clampTimeout(x)) == clampTimeout(x)` 恒成立
    /// （min/max 夹到一个固定闭区间后，再夹一次是无操作）。所以递归最多
    /// 发生一层：第一次调用发现值越界，赋值为夹后的值并 return（跳过自己
    /// 的持久化）；第二次调用（由上一步的自我赋值触发）发现值已经在区间
    /// 内，落到 else 分支只做一次 `defaults.set`。最终内存里的属性值和
    /// UserDefaults 里持久化的值都是夹后的值，不是越界的原始输入——这一点
    /// 由 SettingsTests 里的「超时上界被夹回且留有余量」等用例钉住。
    /// 若未来有人修改 `clampTimeout` 使其不再幂等（例如换成非单调的量化
    /// 逻辑），这里就可能真的无限递归——修改前必须保住幂等性这条前提。
    var permissionTimeout: TimeInterval {
        didSet {
            let clamped = Self.clampTimeout(permissionTimeout)
            if clamped != permissionTimeout {
                permissionTimeout = clamped
            } else {
                defaults.set(permissionTimeout, forKey: "permissionTimeout")
            }
        }
    }

    var currentProject: Project? {
        projects.first { $0.path == currentProjectPath }
    }

    static func clampTimeout(_ value: TimeInterval) -> TimeInterval {
        min(max(value, permissionTimeoutRange.lowerBound), permissionTimeoutRange.upperBound)
    }

    /// Stores the complete Telegram connection form exactly as submitted by
    /// the Connection screen. Returns false when no token was supplied.
    @discardableResult
    func saveConnectionCredentials(token rawToken: String, userIDText: String) -> Bool {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return false }

        botToken = token
        allowedUserIDs = userIDText
            .split(separator: ",")
            .compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
        return true
    }

    /// Adds one allow-list entry in the form accepted by Claude Code.
    /// Whitespace-only and duplicate entries leave the existing list intact.
    static func allowedTools(_ current: [String], adding rawTool: String) -> [String] {
        let tool = rawTool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tool.isEmpty, !current.contains(tool) else { return current }
        return current + [tool]
    }

    private static func encode<T: Encodable>(_ v: T, _ d: UserDefaults, _ k: String) {
        d.set(try? JSONEncoder().encode(v), forKey: k)
    }
    private static func decode<T: Decodable>(_ t: T.Type, _ d: UserDefaults, _ k: String) -> T? {
        d.data(forKey: k).flatMap { try? JSONDecoder().decode(t, from: $0) }
    }
}
