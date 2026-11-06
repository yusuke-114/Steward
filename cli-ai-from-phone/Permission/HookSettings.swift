import Foundation

enum HookSettings {
    /// 生成传给 claude --settings 的 JSON。
    ///
    /// 这里的 `timeout: 600` 是 Claude Code 对这个 hook 进程记的时钟，从进程
    /// 一启动就开始走。它是三层超时里最外层、最不能被绕过的一层，必须严格
    /// 大于 hook.sh 内部 `curl --max-time`（570）：
    ///   PermissionBridge 300s < curl --max-time 570s < 这里的 timeout 600s
    /// 若把这个值改得和 curl 的 --max-time 相等或更小，Claude 会在 hook.sh
    /// 的 deny() 还没来得及打印之前，就把整个 hook 进程 SIGTERM/SIGKILL 掉——
    /// 那是比"误拒"更坏的静默死亡（无输出、无退出码可言，整条 fail-closed
    /// 链条形同虚设）。三个数字中的任意一个都不能单独改动，改动前必须重新
    /// 核对这条不等式（spec §6.2；hook.sh 顶部注释里有同一条链的说明）。
    static func json(hookPath: String, port: UInt16) -> String {
        """
        {"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command",\
        "command":"MACBOT_PORT=\(port) \(hookPath)","timeout":600}]}]}}
        """
    }

    /// 写到临时文件，返回路径。claude --settings 接受文件路径。
    static func writeTempSettings(hookPath: String, port: UInt16) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-ai-from-phone-settings.json")
        try json(hookPath: hookPath, port: port).write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }
}
