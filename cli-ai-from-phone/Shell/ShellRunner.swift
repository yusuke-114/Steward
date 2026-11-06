import Foundation

enum ShellRunner {
    /// 一次 `!` 前缀命令的结果：回给 Telegram 的文本，加上退出码——后者是
    /// 日志窗口（Task 15+）需要展示的字段，文本本身不总是包含它（有输出时
    /// 原样透传 stdout/stderr，不另外拼退出码，避免污染命令的真实输出）。
    struct Output {
        let text: String
        let exitCode: Int32
    }

    /// 执行 `!` 前缀命令。合并 stdout 与 stderr，超时 60 秒。
    static func run(_ command: String, cwd: String) async -> Output {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                let pipe = Pipe()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-lc", command]
                p.currentDirectoryURL = URL(fileURLWithPath: cwd)
                p.standardOutput = pipe
                p.standardError = pipe
                do {
                    try p.run()
                } catch {
                    cont.resume(returning: Output(text: "启动失败：\(error.localizedDescription)", exitCode: -1))
                    return
                }

                // 60 秒超时：进程失控（如误跑进交互式命令等 stdin）不能把整个
                // 轮询循环拖死——用户在手机上会永远等不到任何回复。
                let deadline = DispatchTime.now() + 60
                while p.isRunning && DispatchTime.now() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if p.isRunning {
                    p.terminate()
                    cont.resume(returning: Output(text: "命令超时（60 秒），已终止", exitCode: -1))
                    return
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let out = String(decoding: data, as: UTF8.self)
                let code = p.terminationStatus
                cont.resume(returning: Output(
                    text: out.isEmpty ? "(无输出，退出码 \(code))" : out,
                    exitCode: code))
            }
        }
    }
}
