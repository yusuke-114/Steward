import Foundation

enum SessionState: Equatable, Sendable {
    case idle
    case starting
    case running
    case dead(Int32)
}

/// 单会话持有者：起停、项目切换、崩溃后以 --resume 接续（spec §6.4、§6.5）。
///
/// 子进程死亡后**不**自动重启——崩溃循环会在用户不在电脑前时把 Telegram
/// 刷爆、且没人能介入。状态转为 `.dead(code)`，只有用户下一条消息触发的
/// `ensureStarted()` 才会以 `--resume` 重新拉起。
actor SessionManager {
    typealias TransportFactory = (_ args: [String], _ cwd: String) -> any ProcessTransport

    private let settings: Settings
    private let makeTransport: TransportFactory

    private(set) var state: SessionState = .idle
    private var session: ClaudeSession?
    /// `stop()` is also used by the remote `/stop` command, after which a
    /// later prompt is allowed to start the same manager again.  App-level
    /// disconnect is different: stale work from a superseded connection must
    /// never reactivate its old manager.
    private var acceptsNewWork = true
    /// 新会话的 id 在 Claude 发出 system/init 前不能落盘；进程若在此前
    /// 退出，这只是一次失败的启动尝试，绝不是一个可 --resume 的会话。
    private var pendingSessionID: UUID?
    private var pendingProjectPath: String?

    private var settingsPath = "/tmp/cli-ai-from-phone-settings.json"
    private var eventSink: (@Sendable (StreamEvent) -> Void)?
    private var stateSink: (@Sendable (SessionState) -> Void)?

    // actor 的属性不能从外部直接赋值，必须走方法（Task 13 组合根依赖这两个名字）
    func setSettingsPath(_ path: String) { settingsPath = path }
    func setEventSink(_ sink: @escaping @Sendable (StreamEvent) -> Void) { eventSink = sink }
    func setStateSink(_ sink: @escaping @Sendable (SessionState) -> Void) { stateSink = sink }

    init(settings: Settings, transportFactory: @escaping TransportFactory) {
        self.settings = settings
        self.makeTransport = transportFactory
    }

    func ensureStarted() throws {
        guard acceptsNewWork else { return }
        if case .running = state { return }
        if case .starting = state { return }
        guard let cwd = settings.currentProjectPath else {
            throw NSError(domain: "SessionManager", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "未选择项目"])
        }

        // 命中已确认会话时才 --resume。新 UUID 必须等 Claude 发出
        // system/init 后才能落盘；若启动失败，不能留下一个不存在、却会在
        // 下次被 --resume 的 UUID。
        let existingID = settings.sessionIDsByProject[cwd]
        let id = existingID ?? UUID()
        pendingSessionID = id
        pendingProjectPath = cwd

        let args = ClaudeLaunchArgs.build(sessionID: id,
                                          resume: existingID != nil,
                                          settingsPath: settingsPath,
                                          allowedTools: settings.allowedTools)
        let transport = makeTransport(args, cwd)
        let s = ClaudeSession(transport: transport)
        session = s
        setState(.starting)

        Task { [weak self] in
            for await event in await s.events() {
                await self?.forward(event, from: s)
            }
        }
    }

    private func forward(_ event: StreamEvent, from source: ClaudeSession) {
        // `stop()` 后旧 stdout 仍可能有迟到数据；它不能确认下一条会话。
        guard session === source else { return }
        if case .system(let subtype, _) = event, subtype == "init", state == .starting {
            if let id = pendingSessionID, let projectPath = pendingProjectPath {
                settings.sessionIDsByProject[projectPath] = id
            }
            pendingSessionID = nil
            pendingProjectPath = nil
            setState(.running)
        }
        eventSink?(event)
    }

    private func setState(_ newState: SessionState) {
        state = newState
        stateSink?(newState)
    }

    func send(_ text: String) throws {
        guard acceptsNewWork else { return }
        try ensureStarted()
        guard let s = session else { return }
        Task { try? await s.send(text) }
    }

    /// 不自动重启：崩溃循环时无人叫停，会把 Telegram 刷爆（spec §6.4）
    /// 仅在 CLI 明确说明 resume 目标不存在时移除持久化 id；其他退出原因
    /// （例如临时鉴权、网络或公司网关故障）绝不能丢掉一个可恢复的会话。
    @discardableResult
    func handleExit(code: Int32, standardError: String? = nil) -> Bool {
        let didDiscardMissingSession: Bool
        if state == .starting,
           standardError?.contains("No conversation found with session ID:") == true,
           let id = pendingSessionID,
           let projectPath = pendingProjectPath,
           settings.sessionIDsByProject[projectPath] == id {
            settings.sessionIDsByProject.removeValue(forKey: projectPath)
            didDiscardMissingSession = true
        } else {
            didDiscardMissingSession = false
        }
        session = nil
        pendingSessionID = nil
        pendingProjectPath = nil
        setState(.dead(code))
        return didDiscardMissingSession
    }

    func stop() {
        Task { [session] in await session?.stop() }
        session = nil
        pendingSessionID = nil
        pendingProjectPath = nil
        setState(.idle)
    }

    /// Permanently retires this manager when its owning AppState connection is
    /// replaced or stopped.  Unlike `stop()`, it makes late messages harmless.
    func deactivate() {
        acceptsNewWork = false
        stop()
    }

    /// 切项目：先停旧会话，再换 cwd（spec §6.7）。旧项目的 sessionID 不需要
    /// 在这里单独"保存"——它在 `ensureStarted()` 生成时就已经立刻写回了
    /// `settings.sessionIDsByProject`，所以此刻它已经在磁盘上了。之后如果
    /// 切回这个项目，`ensureStarted()` 会在 `sessionIDsByProject` 里命中
    /// 这个 id 并以 `--resume` 续接，而不是开一条新会话。
    func switchProject(_ path: String) {
        guard acceptsNewWork else { return }
        stop()
        settings.currentProjectPath = path
    }
}
