import Testing
import Foundation
@testable import Steward

@Suite struct SessionManagerTests {
    private func makeSettings() -> Settings {
        let s = Settings(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        s.projects = [Project(name: "a", path: "/tmp/a"), Project(name: "b", path: "/tmp/b")]
        s.currentProjectPath = "/tmp/a"
        return s
    }

    @Test func initialStateIsIdle() async {
        let m = SessionManager(settings: makeSettings(), transportFactory: { _, _ in FakeTransport() })
        #expect(await m.state == .idle)
    }

    @Test func waitsForClaudeInitAfterStart() async throws {
        let m = SessionManager(settings: makeSettings(), transportFactory: { _, _ in FakeTransport() })
        try await m.ensureStarted()
        #expect(await m.state == .starting)
    }

    /// 进程被拉起不等于 Claude 已经可用：只有收到其 system/init 事件后，
    /// 会话才能报告 running。否则主 UI 会把一个随时可能立即退出的进程伪装
    /// 成 Connected。
    @Test func sessionMustNotReportRunningBeforeInitEvent() async throws {
        let fake = FakeTransport()
        let m = SessionManager(settings: makeSettings(), transportFactory: { _, _ in fake })

        try await m.ensureStarted()
        #expect(await m.state != .running)

        fake.replay(Data((#"{"type":"system","subtype":"init","session_id":"session-1"}"# + "\n").utf8))
        for _ in 0..<200 where await m.state != .running {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(await m.state == .running)
    }

    @Test func repeatedEnsureStartedDoesNotSpawnTwice() async throws {
        var spawns = 0
        let m = SessionManager(settings: makeSettings(),
                               transportFactory: { _, _ in spawns += 1; return FakeTransport() })
        try await m.ensureStarted()
        try await m.ensureStarted()
        #expect(spawns == 1)
    }

    /// 切项目要先停掉旧会话，再换 cwd。sessionID 的保留由
    /// `切回之前的项目会用resume续接原sessionID` 单独钉住（spec §6.7）——
    /// 这里只断言 cwd 真的换了，不重复声称本用例没有检查的东西。
    @Test func switchingProjectStopsOldSessionAndChangesCwd() async throws {
        var cwds: [String] = []
        let s = makeSettings()
        let m = SessionManager(settings: s,
                               transportFactory: { _, cwd in cwds.append(cwd); return FakeTransport() })
        try await m.ensureStarted()
        try await m.switchProject("/tmp/b")
        try await m.ensureStarted()
        #expect(cwds == ["/tmp/a", "/tmp/b"])
        #expect(s.currentProjectPath == "/tmp/b")
    }

    /// 子进程死亡后不得自动重启——崩溃循环会刷爆 Telegram（spec §6.4）
    @Test func deadSubprocessBecomesDeadStateAndDoesNotAutoRestart() async throws {
        var spawns = 0
        let m = SessionManager(settings: makeSettings(),
                               transportFactory: { _, _ in spawns += 1; return FakeTransport() })
        try await m.ensureStarted()
        await m.handleExit(code: 1)
        #expect(await m.state == .dead(1))
        #expect(spawns == 1)
    }

    /// 首次进程若在 system/init 前就退出，该 UUID 从未成为一个可恢复的
    /// Claude 会话。把它持久化会使下一次启动带 --resume，然后 Claude 以
    /// “No conversation found” 退出 1，形成永久死循环。
    @Test func exitBeforeInitThenRestartMustStartFreshNotResume() async throws {
        var resumeFlags: [Bool] = []
        let m = SessionManager(settings: makeSettings(),
                               transportFactory: { args, _ in
                                   resumeFlags.append(args.contains("--resume"))
                                   return FakeTransport()
                               })
        try await m.ensureStarted()
        await m.handleExit(code: 1)
        try await m.ensureStarted()
        #expect(resumeFlags == [false, false])
    }

    /// 旧版本已可能留下一个从未由 Claude 建立的 UUID。只有 CLI 明确报告
    /// “No conversation found” 时，才清除它；任意 exit 1 都删除会误伤一个
    /// 因临时鉴权或网络错误退出的真实会话。
    @Test func cliRejectingMissingResumeSessionClearsThatProjectRecord() async throws {
        let settings = makeSettings()
        let staleID = UUID()
        settings.sessionIDsByProject["/tmp/a"] = staleID
        var launchArgs: [[String]] = []
        let manager = SessionManager(settings: settings,
                                     transportFactory: { args, _ in
                                         launchArgs.append(args)
                                         return FakeTransport()
                                     })

        try await manager.ensureStarted()
        await manager.handleExit(
            code: 1,
            standardError: "No conversation found with session ID: \(staleID.uuidString)")
        #expect(settings.sessionIDsByProject["/tmp/a"] == nil)

        try await manager.ensureStarted()
        #expect(launchArgs[0].contains("--resume"))
        #expect(launchArgs[1].contains("--session-id"))
    }

    /// spec §6.5：`lastSessionID` + `lastProjectPath` 落盘在 UserDefaults，
    /// app 重启后首条消息以 --resume 接续，而不是悄悄开一条全新会话、把
    /// 用户整段对话丢掉。用两个独立的 SessionManager 实例、共享同一个
    /// Settings（对应同一份 UserDefaults）来模拟"进程重启"：内存状态
    /// （旧版的 sessionID/hasRunBefore 字段）在重启后必然清零，只有真正
    /// 落盘的状态能穿越这条边界。
    @Test func firstMessageAfterRestartResumesSameSessionID() async throws {
        let s = makeSettings()

        var firstArgs: [String] = []
        let firstTransport = FakeTransport()
        let m1 = SessionManager(settings: s,
                                transportFactory: { args, _ in firstArgs = args; return firstTransport })
        try await m1.ensureStarted()
        #expect(!firstArgs.contains("--resume"))
        firstTransport.replay(Data((#"{"type":"system","subtype":"init","session_id":"session-1"}"# + "\n").utf8))
        for _ in 0..<200 where await m1.state != .running {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(await m1.state == .running)

        // 模拟 app 重启：全新的 SessionManager 实例，复用同一个 Settings。
        // 只有真正 init 过的会话才有资格在这里 resume。
        var secondArgs: [String] = []
        let m2 = SessionManager(settings: s,
                                transportFactory: { args, _ in secondArgs = args; return FakeTransport() })
        try await m2.ensureStarted()

        #expect(secondArgs.contains("--resume"))
        guard let i = firstArgs.firstIndex(of: "--session-id") else {
            Issue.record("首次启动应使用 --session-id，实际 \(firstArgs)")
            return
        }
        let originalID = firstArgs[i + 1]
        guard let j = secondArgs.firstIndex(of: "--resume") else {
            Issue.record("重启后应使用 --resume，实际 \(secondArgs)")
            return
        }
        #expect(secondArgs[j + 1] == originalID)
    }

    /// spec §6.7：项目切换要保留旧项目的 sessionID，供日后切回来时 resume。
    /// 切到 B 再切回 A，A 的第二次启动必须带着它第一次启动时用的那个 id，
    /// 而不是一个新 UUID——否则切一圈项目就把 A 的对话丢了。
    @Test func switchingBackToAProjectResumesItsOriginalSessionID() async throws {
        let s = makeSettings()
        var argsByCwd: [String: [String]] = [:]
        var transportsByCwd: [String: FakeTransport] = [:]
        let m = SessionManager(settings: s,
                               transportFactory: { args, cwd in
                                   argsByCwd[cwd] = args
                                   let transport = FakeTransport()
                                   transportsByCwd[cwd] = transport
                                   return transport
                               })

        try await m.ensureStarted()                    // A 首次启动
        let aFirstArgs = try #require(argsByCwd["/tmp/a"])
        guard let i = aFirstArgs.firstIndex(of: "--session-id") else {
            Issue.record("A 首次启动应使用 --session-id，实际 \(aFirstArgs)")
            return
        }
        let aID = aFirstArgs[i + 1]
        transportsByCwd["/tmp/a"]?.replay(Data((#"{"type":"system","subtype":"init","session_id":"session-a"}"# + "\n").utf8))
        for _ in 0..<200 where await m.state != .running {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(await m.state == .running)

        try await m.switchProject("/tmp/b")
        try await m.ensureStarted()                    // B 首次启动
        transportsByCwd["/tmp/b"]?.replay(Data((#"{"type":"system","subtype":"init","session_id":"session-b"}"# + "\n").utf8))
        for _ in 0..<200 where await m.state != .running {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(await m.state == .running)

        try await m.switchProject("/tmp/a")
        try await m.ensureStarted()                    // 切回 A，应 resume 原 id

        let aSecondArgs = try #require(argsByCwd["/tmp/a"])
        guard let j = aSecondArgs.firstIndex(of: "--resume") else {
            Issue.record("切回 A 应使用 --resume，实际 \(aSecondArgs)")
            return
        }
        #expect(aSecondArgs[j + 1] == aID)
    }

    @Test func sendAutoStartsWhenIdleAndWrites() async throws {
        let fake = FakeTransport()
        let m = SessionManager(settings: makeSettings(), transportFactory: { _, _ in fake })

        try await m.send("你好")
        #expect(await m.state == .starting)

        // send() 内部用 fire-and-forget Task 写入，轮询等它跑完，
        // 避免固定 sleep 造成的时间浪费或偶发 flaky。
        for _ in 0..<200 where fake.written.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(fake.written.count == 1)
    }

    @Test func explicitStopLeavesIdleStateAndTerminatedTransport() async throws {
        let fake = FakeTransport()
        let m = SessionManager(settings: makeSettings(), transportFactory: { _, _ in fake })

        try await m.ensureStarted()
        await m.stop()
        #expect(await m.state == .idle)

        for _ in 0..<200 where !fake.terminated {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(fake.terminated)
    }

    /// AppState 在断开连接时会使旧 manager 失效。之后旧 poll 中晚到的
    /// prompt 绝不能借由 `send()` 再次启动 Claude 子进程。
    @Test func deactivatedManagerIgnoresLateSendInsteadOfRestartingClaude() async throws {
        var spawns = 0
        let m = SessionManager(settings: makeSettings(), transportFactory: { _, _ in
            spawns += 1
            return FakeTransport()
        })

        await m.deactivate()
        try await m.send("late prompt")

        #expect(spawns == 0)
        #expect(await m.state == .idle)
    }

    /// 这条链路把 Claude 的回复送到用户手机上——如果它悄悄失效，用户发
    /// 消息后永远收不到回复，日志里也不会有任何异常（spec §6.4 相关：
    /// 事件转发是"用户能不能收到回应"这件事本身，不只是锦上添花）。
    @Test func underlyingSessionEventsAreForwardedToRegisteredEventSink() async throws {
        let fake = FakeTransport()
        let m = SessionManager(settings: makeSettings(), transportFactory: { _, _ in fake })

        var continuation: AsyncStream<StreamEvent>.Continuation!
        let forwarded = AsyncStream<StreamEvent> { continuation = $0 }
        await m.setEventSink { event in continuation.yield(event) }

        try await m.ensureStarted()

        let line = #"{"type":"result","result":"done","is_error":false}"#
        fake.replay(Data((line + "\n").utf8))

        var received: StreamEvent?
        for await event in forwarded {
            received = event
            break
        }

        guard case .result(let text, let isError) = received else {
            Issue.record("应收到转发的 .result 事件，实际 \(String(describing: received))")
            return
        }
        #expect(text == "done")
        #expect(isError == false)
    }
}

@Suite struct UIProjectSwitchTests {
    private func makeSettings() -> Settings {
        let s = Settings(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        s.projects = [Project(name: "a", path: "/tmp/a"), Project(name: "b", path: "/tmp/b")]
        s.currentProjectPath = "/tmp/a"
        return s
    }

    /// The UI used to assign `currentProjectPath` directly, which a live session
    /// ignores — `ensureStarted()` returns early while `.running`, so the row
    /// ticked over while every message still went to the old project. Switching
    /// must stop the running session, exactly as `/project` does.
    @Test func switchingWhileRunningStopsTheOldSession() async throws {
        var cwds: [String] = []
        let settings = makeSettings()
        let m = SessionManager(settings: settings,
                               transportFactory: { _, cwd in cwds.append(cwd); return FakeTransport() })
        try await m.ensureStarted()
        let started = await m.state
        #expect(started == .running || started == .starting)

        await m.switchProject("/tmp/b")
        let afterSwitch = await m.state
        #expect(afterSwitch == .idle, "old session must be stopped, not left running")
        #expect(settings.currentProjectPath == "/tmp/b")

        try await m.ensureStarted()
        #expect(cwds == ["/tmp/a", "/tmp/b"], "second launch must use the new project's cwd")
    }
}
