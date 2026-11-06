import Foundation

/// 权限请求的中转站。
///
/// 串行化是产品要求而非实现偷懒：手机上同时出现三条「yes/no」时，
/// 用户回的 yes 指向不明。排队中的请求对应的 hook 本就阻塞着，无副作用。
actor PermissionBridge {
    struct Request {
        /// 必须有唯一身份。按 (tool, input) 比对是不够的：
        /// Claude 完全可能连续两次发出完全相同的调用（如两次 Bash(ls)），
        /// 此时第一个请求的超时定时器会误杀第二个请求。
        let id = UUID()
        let tool: String
        let input: String
        let continuation: CheckedContinuation<PermissionDecision, Never>
    }

    private var current: Request?
    private var queue: [Request] = []
    private var timeout: TimeInterval

    /// 超时自动拒绝（而非用户显式应答）触发时调用，带上被拒绝的 tool/input。
    /// 存在的唯一原因：`resolve(_:)` 的调用方（`handle()` 里的显式 yes/no 分支）
    /// 和内部超时定时器都会走到同一条“拒绝”路径，但只有超时这一支需要驱动
    /// Telegram 通知——spec §6.2 的验收项是「触发权限、不回答、等 5 分钟 →
    /// 收到『超时已自动拒绝』」，显式回答 no 不应该重复收到这条通知。
    /// 用回调而不是改变 `requestApproval`/`resolve` 的返回类型，是为了不动
    /// 这两个已经被外部（AppState、既有测试）依赖的公开签名。
    private var onTimeout: (@Sendable (_ tool: String, _ input: String) -> Void)?

    func setOnTimeoutHandler(_ handler: @escaping @Sendable (_ tool: String, _ input: String) -> Void) {
        onTimeout = handler
    }

    /// 三层超时链条里最短的一层的默认值。命名成常量（而不是散落在 `init`
    /// 默认参数里的字面量 300）是为了让 `TimeoutChainInvariantTests` 能直接
    /// 读到这个数字并跟 hook.sh 的 `curl --max-time`、HookSettings 的
    /// `timeout`、`Settings.permissionTimeoutRange.upperBound` 做自动化的
    /// 不等式校验，而不是只靠这几处文档注释人工保持同步——这条链已经被
    /// 单独改动某一环打破过三次，prose 已经证明不够。
    static let defaultTimeout: TimeInterval = 300

    /// - Parameter timeout: 超时自动拒绝的秒数。这是三层超时链条里最短的一层：
    ///     PermissionBridge 300s（这里） < hook.sh 里 curl --max-time 570s
    ///     < HookSettings.json 里 Claude 声明的 hook timeout 600s
    ///   必须严格保持这个大小关系，且中间要留出足够余量：
    ///   - 比 curl 的 --max-time 小，才能保证手机上没人应答时，deny 决定始终
    ///     由这里作出（可记日志、可解释），而不是 hook.sh 因网络挂起自己编一
    ///     个"离线或超时"；
    ///   - curl 的 --max-time 又必须比 Claude 声明的 hook timeout 小，否则
    ///     Claude 会在 hook.sh 打印 deny 之前就直接杀掉那个进程，连输出都没有。
    ///   三个数字任何一个被单独改动都可能打破这条链（spec §6.2；另两处见
    ///   hook.sh 顶部注释与 HookSettings.json 的文档注释；`TimeoutChainInvariantTests`
    ///   对这条链做了自动化校验）。
    init(timeout: TimeInterval = defaultTimeout) {
        self.timeout = timeout
    }

    /// 让设置面板里的超时值真正作用到这个 actor 上。
    ///
    /// 只影响此后**新**呈现的请求：已经在台上的那个请求，它的定时器在
    /// `present()` 里就已经排好，这里不追溯改写——否则用户把超时调短，
    /// 会把一个他正盯着看、还没到期的请求当场判成超时拒绝。
    /// 传入值由 `Settings` 的 didSet 夹在 `permissionTimeoutRange`（10...540）内，
    /// 该上界已由 `TimeoutChainInvariantTests` 钉在 curl 的 570 之下。
    func setTimeout(_ seconds: TimeInterval) {
        timeout = seconds
    }

    var pendingDescription: String? {
        current.map { "\($0.tool): \($0.input)" }
    }

    func requestApproval(tool: String, input: String) async -> PermissionDecision {
        await withCheckedContinuation { cont in
            let req = Request(tool: tool, input: input, continuation: cont)
            if current == nil {
                present(req)
            } else {
                queue.append(req)
            }
        }
    }

    /// 应答当前暴露的请求，并让队首顶上。这是显式应答路径（用户在 Telegram
    /// 上回了 yes/no/2），不触发 `onTimeout`。
    func resolve(_ decision: PermissionDecision) {
        resolve(decision, isTimeout: false)
    }

    private func resolve(_ decision: PermissionDecision, isTimeout: Bool) {
        guard let req = current else { return }     // 空操作，不崩
        current = nil
        req.continuation.resume(returning: decision)
        if isTimeout {
            onTimeout?(req.tool, req.input)
        }
        if !queue.isEmpty { present(queue.removeFirst()) }
    }

    private func present(_ req: Request) {
        current = req
        Task { [timeout] in
            try? await Task.sleep(for: .seconds(timeout))
            await self.timeoutIfStillPending(req)
        }
    }

    /// 只有当超时的确实是当时那个请求才拒绝，避免误杀后来者。
    /// 用 id 而非内容比对——内容相同的两个请求是不同的请求。
    private func timeoutIfStillPending(_ req: Request) {
        guard current?.id == req.id else { return }
        resolve(.deny, isTimeout: true)
    }
}
