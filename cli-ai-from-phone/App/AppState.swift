import Foundation
import Observation

enum ConnectionState: Equatable {
    /// 尚未配置 Bot Token；用户需要在设置窗口的连接卡片中完成配置。
    case needsConfiguration
    case stopped
    case connecting
    /// Telegram long-polling has succeeded, but Claude has not emitted its
    /// stream-json init event yet. This normally means it is waiting for the
    /// first remote prompt, not reconnecting.
    case waitingForClaudeInput
    case connected
    case unauthorized          // token 无效，唯一不重试的状态
    case failure(String)
}

/// 一次被静默丢弃的消息：不允许列表内的用户发来的消息不会得到任何回复
/// （回复本身就暴露了 bot 的存在，spec §6.7），但仍需要留痕供日后的日志
/// 窗口（Task 15+）展示——否则被拒绝的访问尝试完全没有可观测性。
struct DroppedMessage: Equatable, Identifiable {
    let id = UUID()
    let userID: Int64
    let text: String
    let date: Date
}

/// 组合根：Telegram 长轮询 / SessionManager / PermissionBridge /
/// LocalHTTPServer 全部在这里接起来。
///
/// **并发设计（fix round 1，finding 3）**：`chatID`、`telegram`、`sessions`、
/// `pollTask` 这几个字段会被两条并发路径同时读写——长轮询的 `pollTask`
/// 和 `LocalHTTPServer` 为每个 hook POST 起的连接 Task（经
/// `handlePermissionRequest`）。给它们分配一把独立的锁只是把问题挪个地方；
/// 这个类本来就是驱动 SwiftUI 菜单栏的 `@Observable` 状态源，把整个类
/// 钉在 `@MainActor` 上是唯一一处隔离域，读写自动串行化，且不需要额外
/// 记住“这个字段有没有锁保护”。
///
/// 代价：每次跨 actor 调用（TelegramClient / SessionManager / PermissionBridge
/// 都是独立 actor）都要经过一次 `await` 跳转，但这些调用本身就是 async 的——
/// 真正的阻塞点只有 `ShellRunner.run`，它自己已经把同步的 `Process` 调用甩到
/// `DispatchQueue.global()` 上、用 continuation 交回来，不会占住主 actor。
/// 长轮询 Task 和 HTTP handler 之间不会互相死锁：两边所有互相依赖的等待
/// （比如 `handlePermissionRequest` 挂在 `bridge.requestApproval` 上等待
/// 用户回复，而回复要靠长轮询 Task 收到 Telegram 消息后调用 `bridge.resolve`
/// 才能解除）都发生在 `await` 挂起点，MainActor 在挂起期间会被让出去执行
/// 别的 MainActor 隔离任务（也就是长轮询 Task），而不是被单个调用占死。
@MainActor
@Observable
final class AppState {
    let settings = Settings()
    /// 诊断日志的唯一写入方就是这个类；日志视图（Task 15+ 的第四个侧边栏
    /// 分区）直接读它。见 LogStore.swift 顶部注释里对 `@MainActor` 隔离
    /// 选择的说明。
    let log = LogStore()
    private(set) var claudeInstallation: ClaudeInstallation
    private(set) var pendingPermission: String?
    private(set) var droppedMessages: [DroppedMessage] = []

    private var telegram: TelegramClient?
    private var sessions: SessionManager?
    private let bridge = PermissionBridge()
    private let server = LocalHTTPServer()
    private let router = MessageRouter()
    private var chatID: Int64?
    private var pollTask: Task<Void, Never>?
    private var telegramPollingIsLive = false
    private var claudeSessionIsReady = false
    private let idleSleepController = IdleSleepController()
    /// 每次 Connect 都换代；旧进程晚到的 init/exit 事件不能污染新连接。
    private var activeConnectionAttempt = UUID()

    private(set) var connectionState: ConnectionState {
        didSet {
            idleSleepController.update(keepMacAwake: settings.keepMacAwake,
                                       connectionState: connectionState)
            // 单点日志覆盖所有连接状态迁移（含 .unauthorized 这个唯一不重试
            // 的状态），不需要在 start()/stop()/轮询循环里到处散落调用点。
            if oldValue != connectionState {
                log.info("connectionState: \(oldValue) → \(connectionState)")
            }
        }
    }

    init() {
        connectionState = Self.initialConnectionState(forStoredToken: settings.botToken)
        claudeInstallation = ClaudeLocator.detect(preferredPath: settings.claudePath)
        if case let .ready(path, _) = claudeInstallation {
            settings.claudePath = path
        }
    }

    /// A preference change must take effect immediately; connection state may
    /// stay `.connected` while the user changes this control in the UI.
    func keepMacAwakeDidChange() {
        idleSleepController.update(keepMacAwake: settings.keepMacAwake,
                                   connectionState: connectionState)
    }

    /// Token 从本地 UserDefaults 读取。未配置或全空白的值会进入
    /// `.needsConfiguration`，使菜单栏和设置窗口能准确提示用户完成 UI 配置。
    /// 该状态仅反映 UserDefaults 中的已保存值。
    nonisolated static func initialConnectionState(forStoredToken token: String?) -> ConnectionState {
        guard let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .needsConfiguration
        }
        return .stopped
    }

    func start() {
        log.info("connect requested")
        // 设置面板的超时值必须真正作用到 bridge：这个 actor 是在属性初始化时
        // 用默认值 300 构造的，不读 Settings。不推这一下，权限 tab 的步进器
        // 就是个摆设——用户调成 60s，实际仍等 300s。
        applyPermissionTimeout()

        let attempt = UUID()
        // “Connect” 是一次新的完整连接：先释放上一轮（可能已经失效）的
        // Telegram/Claude 资源，再同时建立新的轮询和当前项目会话。
        if Self.shouldStopBeforeStarting(current: connectionState,
                                         hasPollTask: pollTask != nil,
                                         hasSessionManager: sessions != nil) {
            stop()
        }
        activeConnectionAttempt = attempt
        guard let token = Self.connectionToken(from: settings.botToken) else {
            connectionState = .needsConfiguration
            return
        }
        refreshClaudeEnvironment()
        guard case let .ready(claudePath, _) = claudeInstallation else {
            connectionState = .stopped
            return
        }
        guard settings.currentProjectPath != nil else {
            connectionState = .failure("Choose a project before connecting")
            return
        }
        connectionState = .connecting
        telegramPollingIsLive = false
        claudeSessionIsReady = false
        do {
            let port = try server.start()

            // hook.sh 必须从 app bundle 里取，绝不能引用源码树路径——
            // 源码树在 TCC 保护目录下，运行期访问会触发隐私弹窗（本项目已
            // 为此吃过大亏）。bundle 里的资源也可能没有可执行位，显式补上。
            guard let hookPath = Bundle.main.path(forResource: "hook", ofType: "sh") else {
                connectionState = .stopped
                return
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                    ofItemAtPath: hookPath)
            let settingsPath = try HookSettings.writeTempSettings(hookPath: hookPath, port: port)

            server.handler = { [weak self] body in
                await self?.handlePermissionRequest(body) ?? Data()
            }

            let tg = TelegramClient(token: token)
            telegram = tg

            let mgr = SessionManager(settings: settings) { [weak self] args, cwd in
                let t = RealProcessTransport(
                    executable: claudePath,
                    arguments: args, cwd: cwd)
                // 必须接上，否则子进程死亡永远不会被察觉，会话会永远卡在
                // .running、用户的消息从此消失在黑洞里（spec §6.4）。
                //
                // `[weak self]` 单独声明在这一层（而不是复用外层 transportFactory
                // 闭包里已经弱化过的 `self`），并在进入 Task 后立刻 `guard let`
                // 转成不可变的强引用局部量、且显式标注 `@MainActor`——这是让
                // `t.onExit`（`@Sendable (ClaudeProcessExit) -> Void`）这个真正跨隔离域的
                // 闭包不再被诊断为"并发代码里引用了被捕获的 var"的标准写法，
                // 而不是仅仅让警告消失。
                t.onExit = { [weak self] exit in
                    Task { @MainActor in
                        guard let self else { return }
                        await self.sessionDidExit(code: exit.status,
                                                   standardError: exit.standardError,
                                                   attempt: attempt)
                    }
                }
                try? t.start()
                return t
            }

            // fix round 1，finding 4：settingsPath 的落地不能是“发一个不等
            // 结果的 Task，寄望它比任何触发 ensureStarted() 的路径先跑完”——
            // 之前那样写，`sessions` 在 setSettingsPath 完成前就已经能被外部
            // 拿到并调用 ensureStarted()，一旦竞态命中，claude 会带着 actor
            // 里那个占位路径 `/tmp/cli-ai-from-phone-settings.json` 启动，
            // 那个文件不含真实端口，hook 找不到端口，权限请求永远不会被拦截——
            // 这是安全性后果，不是外观上的小瑕疵。
            //
            // 改为由构造顺序保证：`sessions` 和 `startPolling()`（唯一两个
            // 能让 ensureStarted() 被间接触发的入口）都挪到这个 Task 内部、
            // `setSettingsPath` 完成之后才执行。在这之前 `self.sessions`
            // 就是 nil，任何消息处理路径都够不到 SessionManager，物理上不
            // 存在能抢在 setSettingsPath 前面启动会话的路径。
            Task { [weak self] in
                await mgr.setSettingsPath(settingsPath)
                await mgr.setStateSink { [weak self] state in
                    Task { @MainActor [weak self] in
                        self?.sessionStateDidChange(state, attempt: attempt)
                    }
                }
                guard let self else {
                    await mgr.stop()
                    return
                }
                guard Self.isCurrentConnectionAttempt(attempt, activeAttempt: self.activeConnectionAttempt) else {
                    await mgr.stop()
                    return
                }
                self.sessions = mgr
                do {
                    try await mgr.ensureStarted()
                } catch {
                    guard Self.isCurrentConnectionAttempt(attempt, activeAttempt: self.activeConnectionAttempt) else {
                        await mgr.stop()
                        return
                    }
                    self.connectionState = .failure(error.localizedDescription)
                    return
                }
                guard Self.isCurrentConnectionAttempt(attempt, activeAttempt: self.activeConnectionAttempt) else {
                    await mgr.stop()
                    return
                }
                self.startPolling(for: attempt)
            }

            Task { [weak self] in
                guard let self else { return }
                await self.bridge.setOnTimeoutHandler { [weak self] tool, input in
                    Task { @MainActor in
                        guard let self else { return }
                        await self.notifyPermissionTimedOut(tool: tool, input: input)
                    }
                }
            }
        } catch {
            connectionState = .failure(error.localizedDescription)
        }
    }

    func stop() {
        log.info("disconnect requested")
        // 先让旧 attempt 失效，再停止资源：Process 的 terminationHandler
        // 可以晚到，若不换代会把下一次 Connect 的状态打回 failure。
        activeConnectionAttempt = UUID()
        pollTask?.cancel()
        pollTask = nil
        server.stop()
        Task { [sessions] in await sessions?.deactivate() }
        sessions = nil
        telegram = nil
        telegramPollingIsLive = false
        claudeSessionIsReady = false
        connectionState = .stopped
    }

    /// 设置面板保存 token / 允许列表后调用。运行中的 TelegramClient 已经
    /// 捕获旧 token，因此保存后只停止旧连接；新的连接必须由侧边栏 Connect
    /// 显式发起，避免保存和 Connect 两条 UI 路径同时开始长轮询。
    func credentialsSaved() {
        stop()
    }

    /// 把 `Settings.permissionTimeout` 推给 `PermissionBridge`。
    func applyPermissionTimeout() {
        let seconds = settings.permissionTimeout
        Task { await bridge.setTimeout(seconds) }
    }

    /// 设置面板改动超时值后调用。不需要像 token 那样重启轮询——超时值不被
    /// 任何长生命周期对象在构造时捕获，推一次即可。
    /// Switch the working project from the UI.
    ///
    /// Must go through `SessionManager` rather than just assigning
    /// `settings.currentProjectPath`: a live session already holds its own cwd,
    /// and `ensureStarted()` returns early while `.running`, so a bare
    /// assignment changed only the label. The row would tick over while every
    /// message still went to the old project, with nothing on screen saying so.
    /// The Telegram `/project` command has always taken this path; this makes
    /// the two entry points agree.
    func switchProject(to path: String) {
        guard let sessions else {
            settings.currentProjectPath = path      // not connected yet
            return
        }
        log.info("project switch (UI) → \(path)")
        Task { await sessions.switchProject(path) }
    }

    /// Removing the project a live session is working in has the same problem:
    /// the session keeps running against a path that is no longer configured.
    func removeProject(path: String) {
        settings.projects.removeAll { $0.path == path }
        let next = settings.projects.first?.path
        guard let sessions else {
            settings.currentProjectPath = next
            return
        }
        log.info("project removed (UI): \(path)")
        Task {
            if let next {
                await sessions.switchProject(next)
            } else {
                await sessions.stop()
                await MainActor.run { self.settings.currentProjectPath = nil }
            }
        }
    }

    func permissionTimeoutDidChange() {
        applyPermissionTimeout()
    }

    nonisolated static func connectionToken(from candidate: String?) -> String? {
        guard let candidate else { return nil }
        let token = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    nonisolated static func isCurrentConnectionAttempt(_ attempt: UUID, activeAttempt: UUID) -> Bool {
        attempt == activeAttempt
    }

    /// A second Connect can arrive while the first start's asynchronous setup
    /// has not assigned `sessions` or `pollTask` yet.  The visible state is
    /// still the authoritative indication that those resources are in flight.
    nonisolated static func shouldStopBeforeStarting(
        current: ConnectionState,
        hasPollTask: Bool,
        hasSessionManager: Bool
    ) -> Bool {
        switch current {
        case .connecting, .waitingForClaudeInput, .connected:
            return true
        case .needsConfiguration, .stopped, .unauthorized, .failure:
            return hasPollTask || hasSessionManager
        }
    }

    /// A completed poll belongs to the connection attempt that started it.
    /// A superseded poll must not turn a replacement connection into failure.
    nonisolated static func pollingConflictState(
        for attempt: UUID,
        activeAttempt: UUID
    ) -> ConnectionState? {
        guard isCurrentConnectionAttempt(attempt, activeAttempt: activeAttempt) else {
            return nil
        }
        return .failure(
            "Telegram is in use elsewhere. Stop the other bot connection or remove its webhook, then Connect again.")
    }

    /// Message handling contains several suspension points.  Each one must
    /// re-check ownership before it changes state or sends through Telegram.
    nonisolated static func shouldApplyMessageSideEffects(
        for attempt: UUID,
        activeAttempt: UUID
    ) -> Bool {
        isCurrentConnectionAttempt(attempt, activeAttempt: activeAttempt)
    }

    /// Re-runs discovery so a newly installed, moved, or manually selected
    /// Claude binary becomes the one used by the next session.
    func refreshClaudeEnvironment() {
        claudeInstallation = ClaudeLocator.detect(preferredPath: settings.claudePath)
        if case let .ready(path, _) = claudeInstallation {
            settings.claudePath = path
        } else {
            settings.claudePath = nil
        }
    }

    // MARK: - 会话退出通知（fix round 1，finding 2）

    /// `RealProcessTransport.onExit` 的落点。先让 `SessionManager` 记录
    /// `.dead(code)`（不自动重启，spec §6.4 的既有行为不变），再告诉用户——
    /// 否则用户只会在下一条消息表现异常时才发现子进程早就死了，日志里也
    /// 没有任何异常可查。
    private func sessionDidExit(code: Int32, standardError: String, attempt: UUID) async {
        guard attempt == activeConnectionAttempt else { return }
        if code == 0 {
            log.info("claude subprocess exited (code 0)")
        } else {
            log.error("claude subprocess exited (code \(code))")
        }
        let discardedMissingSession = await sessions?.handleExit(code: code,
                                                                  standardError: standardError) ?? false
        if discardedMissingSession {
            connectionState = .failure("Saved Claude session was missing. Click Connect to start a new session.")
        }
        guard let chatID else { return }
        try? await telegram?.send(chatID: chatID, text: AppState.sessionExitNotificationText(code: code))
    }

    /// 抽成纯函数，方便在没有网络的情况下单测文案本身。
    nonisolated static func sessionExitNotificationText(code: Int32) -> String {
        "⚠️ Session process exited (code \(code)). Not restarted automatically — send a message to resume it."
    }

    /// 主状态只在两端都有实际运行证据时才进入 connected：Claude 已发出 init，
    /// 且 Telegram 的长轮询至少成功返回一次。Claude 等待首条消息时会单独显示，
    /// 任何一端失效都会立即离开 connected。
    private func sessionStateDidChange(_ state: SessionState, attempt: UUID) {
        guard attempt == activeConnectionAttempt else { return }
        switch state {
        case .running:
            claudeSessionIsReady = true
            // A user message may resume a session that previously exited.  The
            // new lifecycle event is the only path that is allowed to replace
            // that terminal error with an in-progress connection state.
            connectionState = .connecting
            refreshConnectionState()
        case .starting:
            claudeSessionIsReady = false
            connectionState = .connecting
        case .dead(let code):
            claudeSessionIsReady = false
            connectionState = .failure("Claude session exited (\(code))")
        case .idle:
            claudeSessionIsReady = false
            if case .stopped = connectionState { return }
            refreshConnectionState()
        }
    }

    private func refreshConnectionState() {
        connectionState = Self.connectionStateAfterPollingUpdate(
            current: connectionState,
            claudeSessionIsReady: claudeSessionIsReady,
            telegramPollingIsLive: telegramPollingIsLive)
    }

    /// Telegram polling may keep retrying after Claude exits.  That retry is
    /// not evidence that Claude restarted, so terminal states must survive a
    /// polling update until a new Claude lifecycle event explicitly replaces
    /// them.
    nonisolated static func connectionStateAfterPollingUpdate(
        current: ConnectionState,
        claudeSessionIsReady: Bool,
        telegramPollingIsLive: Bool
    ) -> ConnectionState {
        switch current {
        case .needsConfiguration, .stopped, .unauthorized, .failure:
            return current
        case .connecting, .waitingForClaudeInput, .connected:
            guard claudeSessionIsReady else {
                return telegramPollingIsLive ? .waitingForClaudeInput : .connecting
            }
            return telegramPollingIsLive ? .connected : .connecting
        }
    }

    // MARK: - 权限请求

    private func handlePermissionRequest(_ body: Data) async -> Data {
        let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let tool = obj?["tool_name"] as? String ?? "unknown tool"
        let rawInput = obj?["tool_input"] ?? [:]
        let input = AppState.permissionInputText(rawInput)

        log.info("permission requested: \(tool)")
        pendingPermission = "\(tool): \(input)"
        if let chatID {
            try? await telegram?.send(chatID: chatID,
                                      text: AppState.permissionRequestNotificationText(
                                        tool: tool, input: rawInput))
        }

        let decision = await bridge.requestApproval(tool: tool, input: input)
        pendingPermission = nil

        let verdict = decision == .deny ? "deny" : "allow"
        log.info("permission decision: \(verdict) for \(tool)")
        let json = """
        {"hookSpecificOutput":{"hookEventName":"PreToolUse",\
        "permissionDecision":"\(verdict)","permissionDecisionReason":"from Telegram"}}
        """
        return Data(json.utf8)
    }

    /// `PermissionBridge` 超时自动拒绝时的落点（fix round 1，finding 1）。
    /// 只有内部定时器触发的拒绝会走到这里——`resolve(_:)` 的显式应答路径
    /// 不会调用 `onTimeout`，所以这条通知和 `handle()` 里“已确认：…”那条
    /// 显式应答回执互斥，不会重复发送。
    private func notifyPermissionTimedOut(tool: String, input: String) async {
        // 这是 owner 最可能需要事后诊断的场景——权限请求在手机不在身边时
        // 超时自动拒绝——所以单独用 warn 级别、且措辞与「显式拒绝」的
        // "permission decision: deny" 那条日志区分开，不能被淹没在里面。
        log.warn("permission auto-denied (timeout): \(tool)")
        guard let chatID else { return }
        try? await telegram?.send(chatID: chatID,
                                  text: AppState.permissionTimeoutNotificationText(tool: tool, input: input))
    }

    /// 抽成纯函数，方便在没有网络的情况下单测文案本身；真正“恰好触发一次、
    /// 显式应答不触发”这件事由 `PermissionBridgeTests` 直接钉在 `onTimeout`
    /// 回调上。
    /// What `/project` with no argument answers, and what a failed switch
    /// appends. Marks the current one so the reply doubles as "where am I".
    private func projectListText() -> String {
        AppState.projectListText(projects: settings.projects,
                                 currentPath: settings.currentProjectPath)
    }

    nonisolated static func projectListText(projects: [Project], currentPath: String?) -> String {
        guard !projects.isEmpty else {
            return "No projects configured yet. Add one in Steward → Projects."
        }
        let lines = projects.map { p -> String in
            p.path == currentPath ? "▸ \(p.name)  (current)" : "  \(p.name)"
        }
        return (["Projects:"] + lines + ["", "Send /project <name> to switch."])
            .joined(separator: "\n")
    }

    nonisolated static func permissionTimeoutNotificationText(tool: String, input: String) -> String {
        "⏱️ Auto-denied after timeout: \(tool)\n\(input)"
    }

    /// `handle()` 丢弃分支写入 `LogStore` 的文案。抽成纯函数（而非内联在
    /// `handle()` 里），是为了能在不构造真实 `AppState`（那会触发
    /// `ClaudeLocator.detect` 对真实 shell 的探测，见 ClaudeLocator.swift）
    /// 的情况下，单独钉住这段文案确实包含 userID、且被写进了 `LogStore`——
    /// 见 `LogStoreDroppedMessageLoggingTests`。
    nonisolated static func droppedMessageLogLine(for message: DroppedMessage) -> String {
        "dropped: unauthorized user #\(message.userID) — \(message.text)"
    }

    /// Permission hook 的 input 是 JSON 对象。直接用 `String(describing:)` 会把
    /// 非 ASCII 文本显示成 `\\Uxxxx`，手机上无法判断真实意图；按字段展开
    /// 字符串值，嵌套对象则保留为格式化 JSON。
    nonisolated static func permissionRequestNotificationText(tool: String, input: Any) -> String {
        "🔐 Approval needed\n\n\(tool)\n\n\(permissionInputText(input))\n\nReply: 1 allow / 0 deny / 2 always allow"
    }

    nonisolated private static func permissionInputText(_ input: Any) -> String {
        if let object = input as? [String: Any] {
            return object.keys.sorted().map { key in
                "\(key):\n\(permissionValueText(object[key] ?? ""))"
            }.joined(separator: "\n\n")
        }
        return permissionValueText(input)
    }

    nonisolated private static func permissionValueText(_ value: Any) -> String {
        if let string = value as? String { return string }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value,
                                                      options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return text
    }

    /// `start()` 返回后、`sessions` 落地前那段窗口期收到 prompt 时回复的
    /// 文案。抽成常量（而不是散落的字面量）方便单测钉住，也方便 `handle()`
    /// 和未来任何别的地方引用同一份文案，不出现两处措辞漂移。
    nonisolated static let startupPendingNotificationText = "Starting up — please wait a moment."

    // MARK: - 长轮询

    private func startPolling(for attempt: UUID) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var retryAttempt = 0
            var hasCompletedInitialProbe = false
            while !Task.isCancelled {
                guard let self,
                      Self.isCurrentConnectionAttempt(attempt, activeAttempt: self.activeConnectionAttempt),
                      let tg = self.telegram else { return }
                do {
                    let result = try await tg.poll(timeout: TelegramClient.pollTimeout(
                        isInitialProbe: !hasCompletedInitialProbe))
                    guard Self.isCurrentConnectionAttempt(attempt, activeAttempt: self.activeConnectionAttempt) else {
                        return
                    }
                    retryAttempt = 0
                    hasCompletedInitialProbe = true
                    self.telegramPollingIsLive = true
                    self.refreshConnectionState()
                    // TelegramClient.poll() 返回的是 TelegramPollResult，不是裸数组
                    // （早期草稿假设是数组，编译都过不了）。处理完批次里每一条之后，
                    // 还要再对 highestUpdateID ack 一次——哪怕批次末尾有一条解码失败
                    // 的畸形 update，offset 也必须越过它，否则下一轮轮询会拿到同样
                    // 卡住的批次，整个 poll 循环看起来像是死掉了。
                    await AppState.processPollBatch(
                        result,
                        handle: { [weak self] update in
                            guard let self,
                                  Self.isCurrentConnectionAttempt(
                                    attempt, activeAttempt: self.activeConnectionAttempt) else { return }
                            await self.handle(update, attempt: attempt)
                        },
                        acknowledge: { await tg.acknowledge(upTo: $0) }
                    )
                } catch TelegramError.unauthorized {
                    guard Self.isCurrentConnectionAttempt(attempt, activeAttempt: self.activeConnectionAttempt) else {
                        return
                    }
                    self.telegramPollingIsLive = false
                    self.connectionState = .unauthorized
                    self.log.error("telegram poll: invalid token (401)")
                    return                                        // token 无效，重试无意义
                } catch TelegramError.pollingConflict {
                    // A 409 means Telegram is serving this bot to another
                    // getUpdates client (or a webhook), so retrying merely
                    // prolongs a half-connected state.  Tear down Claude too:
                    // without Telegram it cannot receive a remote command.
                    guard let failure = Self.pollingConflictState(
                        for: attempt, activeAttempt: self.activeConnectionAttempt) else { return }
                    self.stop()
                    self.connectionState = failure
                    self.log.error("telegram poll conflict (409)")
                    return
                } catch {
                    guard Self.isCurrentConnectionAttempt(attempt, activeAttempt: self.activeConnectionAttempt) else {
                        return
                    }
                    self.telegramPollingIsLive = false
                    self.refreshConnectionState()
                    let delay = TelegramClient.backoff(attempt: retryAttempt)
                    self.log.warn("telegram poll failed: \(error) — retry in \(delay)s")
                    try? await Task.sleep(for: .seconds(delay))
                    retryAttempt += 1
                }
            }
        }
    }

    /// 处理完一批 update 后的 ack 顺序，抽成纯逻辑、用闭包注入副作用，
    /// 好在没有网络的情况下单测：每条处理完立即 ack 一次（避免整批处理到
    /// 一半崩溃导致重复处理），处理完整批后再对 highestUpdateID 补一次 ack，
    /// 使 offset 越过批次里任何解码失败、因而不在 `updates` 里出现的尾部条目。
    /// 标 `nonisolated`：这是不碰任何实例状态的纯编排逻辑，不需要 MainActor，
    /// 测试也不必因此被迫在 MainActor 上跑。
    nonisolated static func processPollBatch(
        _ result: TelegramPollResult,
        handle: (TelegramUpdate) async -> Void,
        acknowledge: (Int64) async -> Void
    ) async {
        for u in result.updates {
            await handle(u)
            await acknowledge(u.updateID)
        }
        if let highest = result.highestUpdateID {
            await acknowledge(highest)
        }
    }

    /// 一条 update 的分发结果：抽成纯函数（不做任何 I/O），好在没有网络、
    /// 没有子进程的情况下单测未授权用户静默丢弃、以及有待决权限时 yes/no
    /// 的路由方向。`handle(_:)` 是这个函数唯一的调用方，避免出现两套判定
    /// 逻辑彼此漂移。
    enum RouteDecision: Equatable {
        case dropped
        case shell(String)
        case permission(PermissionDecision)
        case command(BotCommand)
        case prompt(String)
    }

    nonisolated static func decide(update: TelegramUpdate,
                                   allowedUserIDs: [Int64],
                                   hasPendingPermission: Bool,
                                   router: MessageRouter = MessageRouter()) -> RouteDecision {
        guard allowedUserIDs.contains(update.userID) else { return .dropped }
        switch router.route(update.text, hasPendingPermission: hasPendingPermission) {
        case .shell(let cmd):        return .shell(cmd)
        case .permission(let d):     return .permission(d)
        case .command(let c):        return .command(c)
        case .prompt(let t):         return .prompt(t)
        }
    }

    private func handle(_ update: TelegramUpdate, attempt: UUID) async {
        guard Self.shouldApplyMessageSideEffects(for: attempt, activeAttempt: activeConnectionAttempt) else {
            return
        }
        let hasPending = await bridge.pendingDescription != nil
        guard Self.shouldApplyMessageSideEffects(for: attempt, activeAttempt: activeConnectionAttempt) else {
            return
        }
        let decision = AppState.decide(update: update,
                                       allowedUserIDs: settings.allowedUserIDs,
                                       hasPendingPermission: hasPending,
                                       router: router)
        // 每一条入站消息（含被丢弃的）+ 它的路由结果，合在一行里，避免在
        // 每个 case 分支里重复记一遍"收到了什么"。
        log.info("recv #\(update.userID): \(update.text) → \(decision)")

        // 未授权用户静默丢弃，不作任何回复（spec §6.7）——回复本身就暴露了
        // bot 的存在。但仍记一笔，供日后的日志窗口展示：`return` 发生在
        // `chatID` 被赋值、以及本函数唯一的 `telegram?.send` 出口之前，
        // 物理上不存在从这一支走到发送回复的路径。
        guard decision != .dropped else {
            let dropped = DroppedMessage(userID: update.userID, text: update.text, date: Date())
            droppedMessages.append(dropped)
            log.warn(AppState.droppedMessageLogLine(for: dropped))
            return
        }
        chatID = update.chatID

        switch decision {
        case .dropped:
            return // 上面已处理，这里不可达

        case .shell(let cmd):
            let result = await ShellRunner.run(cmd, cwd: settings.currentProjectPath ?? NSHomeDirectory())
            guard Self.shouldApplyMessageSideEffects(for: attempt, activeAttempt: activeConnectionAttempt) else {
                return
            }
            log.info("shell exit \(result.exitCode): \(cmd)")
            try? await telegram?.send(chatID: update.chatID, text: result.text)

        case .permission(let d):
            await bridge.resolve(d)
            guard Self.shouldApplyMessageSideEffects(for: attempt, activeAttempt: activeConnectionAttempt) else {
                return
            }
            try? await telegram?.send(chatID: update.chatID, text: "Answered: \(d)")

        case .command(let cmd):
            await handleCommand(cmd, chatID: update.chatID, attempt: attempt)

        case .prompt(let text):
            // start() 返回之后、setSettingsPath 落地之前有一段窗口期，
            // `sessions` 一直是 nil（见 start() 里 fix round 1 finding 4
            // 的注释）。这段窗口期里直接 `sessions?.send(text)` 会把消息
            // 静默吞掉——用户发了消息、bot 毫无反应，看起来像卡死。
            // 改成显式告知，哪怕只是"稍等"也比石沉大海强。
            guard let sessions else {
                try? await telegram?.send(chatID: update.chatID,
                                          text: AppState.startupPendingNotificationText)
                return
            }
            await wireEventSink(chatID: update.chatID, attempt: attempt)
            guard Self.shouldApplyMessageSideEffects(for: attempt, activeAttempt: activeConnectionAttempt) else {
                return
            }
            // 回合进行中再发消息不打断也不丢弃，写进 stdin 排队（spec §6.7）
            if await sessions.state == .running {
                guard Self.shouldApplyMessageSideEffects(for: attempt, activeAttempt: activeConnectionAttempt) else {
                    return
                }
                try? await telegram?.send(chatID: update.chatID, text: "Queued.")
            }
            guard Self.shouldApplyMessageSideEffects(for: attempt, activeAttempt: activeConnectionAttempt) else {
                return
            }
            try? await sessions.send(text)
        }
    }

    private func wireEventSink(chatID: Int64, attempt: UUID) async {
        await sessions?.setEventSink { [weak self] event in
            guard case .result(let text, _) = event, let text, !text.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      Self.shouldApplyMessageSideEffects(
                        for: attempt, activeAttempt: self.activeConnectionAttempt) else { return }
                try? await self.telegram?.send(chatID: chatID, text: text)
            }
        }
    }

    private func handleCommand(_ cmd: BotCommand, chatID: Int64, attempt: UUID) async {
        guard Self.shouldApplyMessageSideEffects(for: attempt, activeAttempt: activeConnectionAttempt) else {
            return
        }
        switch cmd {
        case .stop:
            log.info("session stop command")
            await sessions?.stop()
            guard Self.shouldApplyMessageSideEffects(for: attempt, activeAttempt: activeConnectionAttempt) else {
                return
            }
            try? await telegram?.send(chatID: chatID, text: "Session stopped.")
        case .status:
            let s = await sessions?.state ?? .idle
            guard Self.shouldApplyMessageSideEffects(for: attempt, activeAttempt: activeConnectionAttempt) else {
                return
            }
            let p = settings.currentProject?.name ?? "none selected"
            try? await telegram?.send(chatID: chatID, text: "Project: \(p)\nSession: \(s)")
        case .help:
            try? await telegram?.send(chatID: chatID,
                text: "!command → shell\n/project → list projects\n/project <name> → switch project\n/stop /status\nanything else → Claude")
        case .listProjects:
            try? await telegram?.send(chatID: chatID, text: projectListText())

        case .project(let name):
            guard let p = settings.projects.first(where: { $0.name.lowercased() == name.lowercased() }) else {
                log.warn("project switch failed: unknown project \(name)")
                // Repeat the list rather than just rejecting: on a phone the user
                // has no other way to recall the names, and a bare rejection leaves
                // them guessing at spelling.
                try? await telegram?.send(
                    chatID: chatID,
                    text: "No such project: \(name)\n\n" + projectListText())
                return
            }
            log.info("project switch → \(p.name)")
            await sessions?.switchProject(p.path)
            guard Self.shouldApplyMessageSideEffects(for: attempt, activeAttempt: activeConnectionAttempt) else {
                return
            }
            try? await telegram?.send(chatID: chatID, text: "Switched to \(p.name)")
        }
    }
}
