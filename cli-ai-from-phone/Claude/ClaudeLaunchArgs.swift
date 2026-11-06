import Foundation

enum ClaudeLaunchArgs {
    /// 参数含义见 spec §3。--permission-prompts host 是让 hook 生效的前提。
    static func build(sessionID: UUID,
                      resume: Bool,
                      settingsPath: String,
                      allowedTools: [String]) -> [String] {
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            // 实测必需：缺了它 claude 报 "requires --verbose"，
            // 退出码 1，stdout 零字节
            "--verbose",
            "--permission-prompts", "host",
            "--settings", settingsPath,
        ]
        if resume {
            args += ["--resume", sessionID.uuidString]
        } else {
            args += ["--session-id", sessionID.uuidString]
        }
        if !allowedTools.isEmpty {
            args += ["--allowedTools"] + allowedTools
        }
        return args
    }
}
