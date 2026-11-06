import Testing
import Foundation
@testable import Steward

/// 钉住三层超时链条的不等式：
///     PermissionBridge.defaultTimeout < hook.sh 的 curl --max-time
///     < HookSettings 声明给 Claude 的 hook timeout
/// 以及 Settings.permissionTimeoutRange.upperBound < curl --max-time。
///
/// 这条链条已经在这个项目里被单独改动其中一环打破过三次——两处数字
/// （curl 的 `--max-time` 是 shell 脚本里的字面量，Claude 的 hook
/// timeout 是拼进一段 JSON 字符串的字面量）根本不是 Swift 常量，单独改动
/// 任何一处，编译期和大多数测试都不会报错。这里不再依赖四处文档注释人工
/// 保持同步，而是真的从磁盘读 hook.sh、真的调用 HookSettings.json(...)，
/// 用正则把两个非 Swift 字面量抠出来，跟 Swift 侧的
/// `PermissionBridge.defaultTimeout`、`Settings.permissionTimeoutRange`
/// 一起做数值比较。
@Suite struct TimeoutChainInvariantTests {
    /// 读 **bundle 里**的 hook.sh，而不是用 #filePath 去读源码树。
    ///
    /// 源码树在 ~/Desktop 下，那是 macOS 的 TCC 保护目录；测试宿主是一个
    /// ad-hoc 签名的 .app，没有稳定身份，从它里面读 Desktop 下的文件会触发
    /// 隐私授权弹窗——无头跑测试时那个弹窗永远不会被响应，整个测试进程就
    /// 永久挂住（本项目为此损失过数小时，详见 ledger）。
    /// bundle 里的这一份同时也正是随 app 分发、生产中真正被执行的那一份，
    /// 读它比读源码树更贴近要守护的事实。
    static func hookScriptURL() throws -> URL {
        let bundle = Bundle(for: BundleToken.self)
        if let url = bundle.url(forResource: "hook", withExtension: "sh") { return url }
        // 单元测试 bundle 里没有时，退回宿主 app bundle 的 Resources
        let hostResources = bundle.bundleURL
            .deletingLastPathComponent()   // PlugIns/
            .deletingLastPathComponent()   // Contents/
            .appendingPathComponent("Resources/hook.sh")
        return hostResources
    }

    static func firstIntMatch(_ pattern: String, in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[r])
    }

    @Test func threeLayerTimeoutChainAndSettingsCeilingAreStrictlyOrdered() throws {
        let hookScript = try String(contentsOf: Self.hookScriptURL(), encoding: .utf8)
        let curlMaxTime = try #require(
            Self.firstIntMatch(#"--max-time\s+(\d+)"#, in: hookScript),
            "在 hook.sh 里没找到 curl --max-time，正则或文件路径可能失效了"
        )

        let hookSettingsJSON = HookSettings.json(hookPath: "/tmp/hook.sh", port: 12345)
        let claudeHookTimeout = try #require(
            Self.firstIntMatch(#""timeout":(\d+)"#, in: hookSettingsJSON),
            "在 HookSettings.json(...) 的输出里没找到 timeout 字段，格式可能变了"
        )

        let bridgeDefault = PermissionBridge.defaultTimeout
        let settingsUpperBound = Settings.permissionTimeoutRange.upperBound

        let allFour = "PermissionBridge.defaultTimeout=\(bridgeDefault), " +
            "Settings.permissionTimeoutRange.upperBound=\(settingsUpperBound), " +
            "hook.sh curl --max-time=\(curlMaxTime), " +
            "HookSettings timeout=\(claudeHookTimeout)"

        #expect(
            bridgeDefault < Double(curlMaxTime),
            "链条断在 PermissionBridge.defaultTimeout < curl --max-time 这一环。\(allFour)"
        )
        #expect(
            Double(curlMaxTime) < Double(claudeHookTimeout),
            "链条断在 curl --max-time < HookSettings timeout 这一环。\(allFour)"
        )
        #expect(
            settingsUpperBound < Double(curlMaxTime),
            "链条断在 Settings.permissionTimeoutRange.upperBound < curl --max-time 这一环。\(allFour)"
        )
    }
}
