import Foundation

protocol ProcessTransport: AnyObject, Sendable {
    var stdout: AsyncStream<Data> { get }
    func write(_ data: Data) throws
    func terminate()
}

/// `claude` 的退出码本身不足以区分“认证临时失败”和“请求恢复一个不存在的
/// 会话”。stderr 只在进程退出时交给组合根做该次启动的恢复判断，不持久化。
struct ClaudeProcessExit: Sendable {
    let status: Int32
    let standardError: String
}

/// 真实现：包一个 claude 子进程。
/// PATH 显式设置，不依赖 GUI app 继承到的环境——
/// 从 Finder 启动的 app 拿不到 shell 的 PATH，这是旧版硬编码 Cellar 路径的根因。
///
/// `start()` 有意不放进 `ProcessTransport` 协议：协议只描述 `ClaudeSession`
/// 实际消费的表面（读 stdout、写 stdin、terminate），这些是会话运行期间反复
/// 发生的操作，Fake 也天然能实现。而「启动」是子进程独有的一次性生命周期步骤，
/// Fake 没有对应物——它靠测试直接调用 `replay(_:)` 注入数据，不需要「启动」这个概念。
/// 把 start() 塞进协议只会逼 FakeTransport 提供一个空实现，没有实际意义。
/// 组合根（Task 13）本来就需要持有具体类型来完成进程配置，start() 留在那一层职责边界清楚。
final class RealProcessTransport: ProcessTransport, @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let continuation: AsyncStream<Data>.Continuation
    let stdout: AsyncStream<Data>

    var onExit: (@Sendable (ClaudeProcessExit) -> Void)?

    init(executable: String, arguments: [String], cwd: String) {
        var c: AsyncStream<Data>.Continuation!
        stdout = AsyncStream { c = $0 }
        continuation = c

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["HOME"] = home
        process.environment = env

        stdoutPipe.fileHandleForReading.readabilityHandler = { [continuation] handle in
            let data = handle.availableData
            if data.isEmpty {
                continuation.finish()
                handle.readabilityHandler = nil
            } else {
                continuation.yield(data)
            }
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.continuation.finish()
            let data = self.stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let standardError = String(decoding: data, as: UTF8.self)
            self.onExit?(ClaudeProcessExit(status: p.terminationStatus,
                                            standardError: standardError))
        }
    }

    func start() throws { try process.run() }

    func write(_ data: Data) throws {
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    func terminate() {
        if process.isRunning { process.terminate() }
        continuation.finish()
    }
}
