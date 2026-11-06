import Testing
import Foundation
@testable import Steward

/// 覆盖 `AppState` 里不依赖网络、不依赖子进程的纯逻辑：
///   - 未授权用户的消息被静默丢弃（spec §6.7）
///   - 有/无待决权限时 yes/no 的路由方向
///   - 一批 update 处理完之后的 ack 顺序，尤其是 highestUpdateID 补 ack
/// 网络（TelegramClient）、子进程（SessionManager/ProcessTransport）相关的
/// 编排逻辑不在此文件覆盖范围内——那需要真实/伪造的 I/O，交给集成验收。
@Suite struct AppStateDecideTests {
    private func update(userID: Int64 = 1, text: String) -> TelegramUpdate {
        TelegramUpdate(updateID: 1, chatID: 999, userID: userID, text: text)
    }

    @Test func unauthorisedUserIsSilentlyDropped() {
        let d = AppState.decide(update: update(userID: 42, text: "/status"),
                                allowedUserIDs: [1, 2, 3],
                                hasPendingPermission: false)
        #expect(d == .dropped)
    }

    /// 丢弃判定必须先于路由判定——不允许列表的用户即使发的是权限应答文本，
    /// 也该整体判定为丢弃，而不是先按 yes/no 语义路由。
    @Test func yesFromUnauthorisedUserIsDroppedNotTreatedAsPermissionAnswer() {
        let d = AppState.decide(update: update(userID: 42, text: "yes"),
                                allowedUserIDs: [1, 2, 3],
                                hasPendingPermission: true)
        #expect(d == .dropped)
    }

    @Test func authorisedUserIsRoutedNormally() {
        let d = AppState.decide(update: update(userID: 2, text: "/status"),
                                allowedUserIDs: [1, 2, 3],
                                hasPendingPermission: false)
        #expect(d == .command(.status))
    }

    @Test func withPendingPermissionYesRoutesToAllow() {
        let d = AppState.decide(update: update(text: "yes"),
                                allowedUserIDs: [1],
                                hasPendingPermission: true)
        #expect(d == .permission(.allow))
    }

    @Test func withPendingPermissionNoRoutesToDeny() {
        let d = AppState.decide(update: update(text: "no"),
                                allowedUserIDs: [1],
                                hasPendingPermission: true)
        #expect(d == .permission(.deny))
    }

    @Test func withoutPendingPermissionYesIsAPlainPrompt() {
        let d = AppState.decide(update: update(text: "yes"),
                                allowedUserIDs: [1],
                                hasPendingPermission: false)
        #expect(d == .prompt("yes"))
    }

    @Test func bangPrefixRoutesToShellEvenWithPendingPermission() {
        let d = AppState.decide(update: update(text: "!pwd"),
                                allowedUserIDs: [1],
                                hasPendingPermission: true)
        #expect(d == .shell("pwd"))
    }
}

/// fix round 1，finding 1 & 2：只测文案本身这个纯函数——是否真的送达
/// Telegram 依赖 `TelegramClient`（真实网络、非协议化），不可能在这个沙盒
/// 里不联网验证，也不该假装验证了。「超时/崩溃触发时确实调用了通知路径」
/// 这件事，由 `PermissionBridgeTests` 里对 `onTimeout` 回调的断言、以及
/// `SessionManagerTests` 里既有的 `.dead` 状态转换测试分别覆盖其各自能
/// 单测的那一半；两者拼起来才是 AppState 里 `sessionDidExit` /
/// `notifyPermissionTimedOut` 的完整行为，AppState 这一层本身没有可离线
/// 验证的编排逻辑可加。
@Suite struct AppStateNotificationTextTests {
    @Test func permissionTimeoutNoticeContainsRequiredWordingAndToolInfo() {
        let text = AppState.permissionTimeoutNotificationText(tool: "Bash", input: "rm -rf /")
        #expect(text.contains("Auto-denied after timeout"))
        #expect(text.contains("Bash"))
        #expect(text.contains("rm -rf /"))
    }

    @Test func sessionExitNoticeContainsExitCode() {
        let text = AppState.sessionExitNotificationText(code: 137)
        #expect(text.contains("137"))
        #expect(text.contains("exited"))
    }

    @Test func permissionRequestShowsReadableFieldsAndNumericShortcuts() {
        let text = AppState.permissionRequestNotificationText(
            tool: "Bash",
            input: [
                "command": "find /tmp -name \"IdleSleepController*\"",
                "description": "Find IdleSleepController related files",
            ])

        #expect(text.contains("Find IdleSleepController related files"))
        #expect(!text.contains("\\U"))
        #expect(text.contains("1 allow"))
        #expect(text.contains("0 deny"))
        #expect(text.contains("2 always allow"))
    }

    /// Task 15 小修：`sessions` 落地前那段窗口期收到 prompt 时不再被
    /// `sessions?.send(...)` 静默吞掉，而是回这条文案。
    @Test func startupWindowNoticeIsNonEmptyAndAsksUserToWait() {
        let text = AppState.startupPendingNotificationText
        #expect(!text.isEmpty)
        #expect(text.localizedCaseInsensitiveContains("starting") || text.localizedCaseInsensitiveContains("wait"))
    }
}

/// 首次启动时不能把「尚未填写 Token」伪装成普通的「未启动」：前者应把用户
/// 引导到连接配置 UI，后者才表示已配置但尚未连接。这条测试会在缺少该分支、
/// 或者把空白 Token 当作有效 Token 时失败。
@Suite struct AppStateConnectionConfigurationTests {
    @Test func emptyTokenRequiresConnectionSetupInUI() {
        #expect(AppState.initialConnectionState(forStoredToken: nil) == .needsConfiguration)
        #expect(AppState.initialConnectionState(forStoredToken: "   ") == .needsConfiguration)
    }

    @Test func showsStoppedWhenTokenSavedButNotStarted() {
        #expect(AppState.initialConnectionState(forStoredToken: "123456:bot-token") == .stopped)
    }

    @Test func storedConnectionTokenIsTrimmedBeforeConnecting() {
        #expect(AppState.connectionToken(from: "  stored-token  ") == "stored-token")
        #expect(AppState.connectionToken(from: "   ") == nil)
    }

    @Test func supersededConnectionAttemptCannotActivateResources() {
        let current = UUID()
        #expect(AppState.isCurrentConnectionAttempt(current, activeAttempt: current))
        #expect(!AppState.isCurrentConnectionAttempt(UUID(), activeAttempt: current))
    }

    /// 第二次 Connect 可能发生在第一次的异步启动任务尚未写入 `sessions` /
    /// `pollTask` 之时。这个窗口也必须视为已有连接，否则两次启动会各自建立
    /// Telegram poll，后者触发 Telegram 409 冲突。
    @Test func aSecondConnectCancelsAnInProgressStartupBeforeResourcesAreAssigned() {
        #expect(AppState.shouldStopBeforeStarting(
            current: .connecting,
            hasPollTask: false,
            hasSessionManager: false))
    }

    /// 被替换连接的 poll 即使晚到 409，也不能把新连接停掉。
    @Test func stalePollingConflictCannotFailTheReplacementConnection() {
        let activeAttempt = UUID()
        let staleAttempt = UUID()

        #expect(AppState.pollingConflictState(
            for: staleAttempt,
            activeAttempt: activeAttempt) == nil)
        #expect(AppState.pollingConflictState(
            for: activeAttempt,
            activeAttempt: activeAttempt) == .failure(
                "Telegram is in use elsewhere. Stop the other bot connection or remove its webhook, then Connect again."))
    }

    /// 已经开始处理的旧消息在异步操作恢复后，不能向新连接的 Telegram
    /// client 发送结果，或修改新连接的状态。
    @Test func staleMessageHandlerCannotApplySideEffectsToTheReplacementConnection() {
        let activeAttempt = UUID()
        #expect(!AppState.shouldApplyMessageSideEffects(
            for: UUID(), activeAttempt: activeAttempt))
        #expect(AppState.shouldApplyMessageSideEffects(
            for: activeAttempt, activeAttempt: activeAttempt))
    }
}

/// Telegram 长轮询可以在 Claude 已退出之后继续按退避策略重试，但其网络错误
/// 不能覆盖 Claude 的真实退出原因；否则 UI 会永远误报为 “Reconnecting…”。
@Suite struct AppStateConnectionStateTests {
    /// Claude 的 stream-json 在收到第一条用户消息前不会发出 init；此时
    /// Telegram 已经可用，不能继续误报为 "Reconnecting…"，更不能称为
    /// Connected。这个分支若被删掉，远端用户就无法知道需要先发一条消息。
    @Test func showsWaitingForInputWhenTelegramReadyAndClaudeIdle() {
        let state = AppState.connectionStateAfterPollingUpdate(
            current: .connecting,
            claudeSessionIsReady: false,
            telegramPollingIsLive: true)

        #expect(state == .waitingForClaudeInput)
    }

    @Test func claudeExitCodeSurvivesLaterTelegramPollFailure() {
        let exitFailure = ConnectionState.failure("Claude session exited (-1)")

        let state = AppState.connectionStateAfterPollingUpdate(
            current: exitFailure,
            claudeSessionIsReady: false,
            telegramPollingIsLive: false)

        #expect(state == exitFailure)
    }
}

@Suite struct IdleSleepControllerTests {
    @Test func only_acquires_an_activity_when_the_connection_is_real() {
        var beginCount = 0
        var endCount = 0
        let controller = IdleSleepController(
            beginActivity: {
                beginCount += 1
                return NSObject()
            },
            endActivity: { _ in endCount += 1 })

        controller.update(keepMacAwake: true, connectionState: .connecting)
        #expect(beginCount == 0)

        controller.update(keepMacAwake: true, connectionState: .connected)
        controller.update(keepMacAwake: true, connectionState: .connected)
        #expect(beginCount == 1)
        #expect(endCount == 0)
    }

    @Test func releases_activity_when_connection_leaves_connected() {
        let disconnectedStates: [ConnectionState] = [
            .connecting,
            .waitingForClaudeInput,
            .stopped,
            .unauthorized,
            .failure("Claude session exited (1)"),
            .needsConfiguration,
        ]

        for state in disconnectedStates {
            var endCount = 0
            let controller = IdleSleepController(
                beginActivity: { NSObject() },
                endActivity: { _ in endCount += 1 })

            controller.update(keepMacAwake: true, connectionState: .connected)
            controller.update(keepMacAwake: true, connectionState: state)
            #expect(endCount == 1)
        }
    }

    @Test func releases_activity_when_preference_turns_off() {
        var endCount = 0
        let controller = IdleSleepController(
            beginActivity: { NSObject() },
            endActivity: { _ in endCount += 1 })

        controller.update(keepMacAwake: true, connectionState: .connected)
        controller.update(keepMacAwake: false, connectionState: .connected)
        #expect(endCount == 1)
    }
}

@Suite struct AppStatePollBatchTests {
    @Test func eachUpdateIsAckedRightAfterItIsHandled() async {
        let updates = [
            TelegramUpdate(updateID: 10, chatID: 1, userID: 1, text: "a"),
            TelegramUpdate(updateID: 11, chatID: 1, userID: 1, text: "b"),
        ]
        let result = TelegramPollResult(updates: updates, highestUpdateID: 11)

        var handled: [Int64] = []
        var acked: [Int64] = []
        await AppState.processPollBatch(result,
            handle: { handled.append($0.updateID) },
            acknowledge: { acked.append($0) })

        #expect(handled == [10, 11])
        // 10, 11 各自处理完 ack 一次，随后再对 highestUpdateID(11) 补一次 ack。
        #expect(acked == [10, 11, 11])
    }

    /// 核心用例：批次末尾有一条解码失败的畸形 update，不会出现在 `updates`
    /// 里，但它的 update_id 仍被记在 `highestUpdateID`。必须对 highestUpdateID
    /// 也 ack 一次，否则下次轮询还会卡在同一批（spec 修正点 1）。
    @Test func malformedTrailingUpdateIsStillSkippedViaHighestUpdateID() async {
        let updates = [TelegramUpdate(updateID: 100, chatID: 1, userID: 1, text: "好的")]
        // 101 解码失败，不出现在 updates 里，但 highestUpdateID 记了它。
        let result = TelegramPollResult(updates: updates, highestUpdateID: 101)

        var acked: [Int64] = []
        await AppState.processPollBatch(result,
            handle: { _ in },
            acknowledge: { acked.append($0) })

        #expect(acked == [100, 101])
        #expect(acked.last == 101)   // offset 必须越过畸形条目，不能卡在 100
    }

    @Test func emptyBatchWithoutHighestUpdateIDDoesNotAck() async {
        let result = TelegramPollResult(updates: [], highestUpdateID: nil)
        var acked: [Int64] = []
        await AppState.processPollBatch(result,
            handle: { _ in },
            acknowledge: { acked.append($0) })
        #expect(acked.isEmpty)
    }

    @Test func offsetStillAdvancesViaHighestUpdateIDWhenAllDecodesFail() async {
        let result = TelegramPollResult(updates: [], highestUpdateID: 205)
        var acked: [Int64] = []
        await AppState.processPollBatch(result,
            handle: { _ in },
            acknowledge: { acked.append($0) })
        #expect(acked == [205])
    }
}
