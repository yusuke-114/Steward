import Testing
import Foundation
@testable import Steward

@Suite struct PermissionBridgeTests {

    /// 钉住"设置面板的超时值真的作用到 bridge"这条接线。
    /// 用默认值（300s）构造，再 setTimeout 到极短——若 setTimeout 没生效，
    /// 这条会等满 300 秒而不是毫秒级返回。
    @Test func setTimeoutTakesEffectUsingNewValueNotConstructionDefault() async {
        let bridge = PermissionBridge()          // 默认 300s
        await bridge.setTimeout(0.1)
        let start = Date()
        let d = await bridge.requestApproval(tool: "Bash", input: "rm -rf /")
        let elapsed = Date().timeIntervalSince(start)
        #expect(d == .deny)
        #expect(elapsed < 5, "应按 0.1s 超时，实得 \(elapsed)s —— setTimeout 未生效")
    }
    @Test func answeringAllowReturnsAllow() async {
        let bridge = PermissionBridge(timeout: 5)
        async let decision = bridge.requestApproval(tool: "Bash", input: "rm -rf build/")
        while await bridge.pendingDescription == nil { await Task.yield() }
        await bridge.resolve(.allow)
        #expect(await decision == .allow)
    }

    @Test func timeoutAutoDenies() async {
        let bridge = PermissionBridge(timeout: 0.1)
        let d = await bridge.requestApproval(tool: "Bash", input: "rm -rf /")
        #expect(d == .deny)          // 失败向拒绝倒
    }

    /// 核心用例：同时只能有一个请求暴露给用户，否则手机上 yes 指向不明
    @Test func concurrentRequestsAreStrictlySerialised() async {
        let bridge = PermissionBridge(timeout: 5)
        async let a = bridge.requestApproval(tool: "Bash", input: "第一个")
        async let b = bridge.requestApproval(tool: "Write", input: "第二个")

        while await bridge.pendingDescription == nil { await Task.yield() }
        let first = await bridge.pendingDescription
        #expect(first?.contains("第一个") == true)

        await bridge.resolve(.allow)
        // 第一个解决后，第二个才浮出水面
        while await bridge.pendingDescription?.contains("第二个") != true { await Task.yield() }
        await bridge.resolve(.deny)

        #expect(await a == .allow)
        #expect(await b == .deny)
    }

    @Test func resolveWithNothingPendingIsASafeNoOp() async {
        let bridge = PermissionBridge(timeout: 5)
        await bridge.resolve(.allow)          // 不得崩溃
        #expect(await bridge.pendingDescription == nil)
    }

    /// resolve 与超时竞速，覆盖 `current == nil` 这一分支：请求在超时触发前一刻
    /// 被应答，超时定时器随后醒来时 current 已是 nil，必须是空操作。
    /// 注意：本测试不覆盖「current 是另一个不同 id 的活跃请求」这一分支——
    /// 那个分支（也是 id 比对而非内容比对存在的真正原因）由
    /// `A的过期定时器不得误杀内容相同但id不同的活跃请求B` 单独覆盖。
    @Test func resolveRacingTimeoutMustNotKillFollowingRequest() async {
        let bridge = PermissionBridge(timeout: 0.05)
        async let a = bridge.requestApproval(tool: "Bash", input: "A")
        while await bridge.pendingDescription == nil { await Task.yield() }
        await bridge.resolve(.allow)
        #expect(await a == .allow)

        // 让 A 的超时定时器有机会醒来（此时 current 应为 nil，定时器必须是空操作）
        try? await Task.sleep(for: .seconds(0.2))

        // 队列此时应为空、无待决请求，且新请求能正常被处理（未被幽灵定时器污染）
        async let b = bridge.requestApproval(tool: "Bash", input: "B")
        while await bridge.pendingDescription == nil { await Task.yield() }
        #expect(await bridge.pendingDescription?.contains("B") == true)
        await bridge.resolve(.allowAlways)
        #expect(await b == .allowAlways)
    }

    /// 核心用例，覆盖 `timeoutIfStillPending` 的另一分支：A 的过期定时器醒来时，
    /// current 不是 nil，而是另一个 id 不同、但 tool/input 内容完全相同的活跃请求 B。
    /// 按 (tool, input) 比对无法区分 A、B——这正是当初要求按 id 比对而非内容比对的原因
    /// （Claude 可能连续发出两次完全相同的调用）。只有 id 比对才能让 B 幸免于难。
    @Test func staleTimerFromAMustNotKillLiveBWithSameContentButDifferentID() async {
        let bridge = PermissionBridge(timeout: 0.3)
        async let a = bridge.requestApproval(tool: "Bash", input: "ls")
        while await bridge.pendingDescription == nil { await Task.yield() }

        // 让 A 在台上停留一段时间（此时它的超时定时器已经在倒计时），
        // 为「A 的过期定时器触发时刻」与「B 自身超时时刻」之间留出安全窗口。
        try? await Task.sleep(for: .seconds(0.2))
        await bridge.resolve(.allow)
        #expect(await a == .allow)

        // B 与 A 的 tool、input 完全相同，故意让内容比对无法区分两者。
        async let b = bridge.requestApproval(tool: "Bash", input: "ls")
        while await bridge.pendingDescription == nil { await Task.yield() }

        // 此刻已越过 A 的 0.3s 超时窗口（A 的过期定时器该醒的都醒了），
        // 但远没到 B 自己的 0.3s 窗口（B 刚上台）——B 应仍然存活、未被误杀。
        try? await Task.sleep(for: .seconds(0.2))
        #expect(await bridge.pendingDescription != nil)

        await bridge.resolve(.allowAlways)
        #expect(await b == .allowAlways)   // 是我们给的答案，不是被 A 的幽灵定时器灌的 .deny
    }

    // MARK: - fix round 1，finding 1：onTimeout 只在超时路径触发

    /// 核心用例：超时自动拒绝必须驱动一次 `onTimeout` 回调（AppState 靠它
    /// 转发 Telegram「超时已自动拒绝」通知，spec §6.2）。带上正确的 tool/input，
    /// 好让通知里能说清是哪个请求被拒了。
    @Test func autoDenyOnTimeoutFiresOnTimeoutWithToolAndInput() async {
        let bridge = PermissionBridge(timeout: 0.05)
        var calls: [(tool: String, input: String)] = []
        await bridge.setOnTimeoutHandler { tool, input in calls.append((tool, input)) }

        let d = await bridge.requestApproval(tool: "Bash", input: "rm -rf /")
        #expect(d == .deny)

        for _ in 0..<200 where calls.isEmpty { await Task.yield() }
        #expect(calls.count == 1)
        #expect(calls.first?.tool == "Bash")
        #expect(calls.first?.input == "rm -rf /")
    }

    /// 核心用例：用户显式应答（哪怕答案也是 deny）不得触发 `onTimeout`——
    /// 否则用户明明回了 no，还会莫名其妙收到一条「超时已自动拒绝」，
    /// 造成重复/矛盾的通知。
    @Test func explicitAnswerDoesNotFireOnTimeout() async {
        let bridge = PermissionBridge(timeout: 5)
        var callCount = 0
        await bridge.setOnTimeoutHandler { _, _ in callCount += 1 }

        async let d = bridge.requestApproval(tool: "Bash", input: "ls")
        while await bridge.pendingDescription == nil { await Task.yield() }
        await bridge.resolve(.deny)   // 显式应答，不是超时

        #expect(await d == .deny)
        #expect(callCount == 0)
    }

    /// 超时发生在队列场景下：A 超时被拒绝、触发一次 onTimeout；随后 B 顶上、
    /// 被显式应答，不应再触发第二次。两件事都要成立，不能只挑一半验证。
    @Test func queuedATimesOutOnceWhileExplicitlyAnsweredBDoesNotFire() async {
        let bridge = PermissionBridge(timeout: 0.1)
        var calls: [(tool: String, input: String)] = []
        await bridge.setOnTimeoutHandler { tool, input in calls.append((tool, input)) }

        async let a = bridge.requestApproval(tool: "Bash", input: "A")
        async let b = bridge.requestApproval(tool: "Bash", input: "B")
        while await bridge.pendingDescription == nil { await Task.yield() }

        // 不应答 A，让它超时；B 应顶上。
        while await bridge.pendingDescription?.contains("B") != true { await Task.yield() }
        #expect(await a == .deny)

        await bridge.resolve(.allow)   // 显式应答 B
        #expect(await b == .allow)

        #expect(calls.count == 1)
        #expect(calls.first?.input == "A")
    }
}
