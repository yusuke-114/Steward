import Foundation
import Network

/// 极小的 HTTP/1.1 服务，只服务一个 POST 端点，只监听 127.0.0.1。
/// 端口用 0 让系统分配，避免与别的程序撞车。
final class LocalHTTPServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "local-http")

    /// 收到请求体，返回响应体。
    var handler: ((Data) async -> Data)?

    func start() throws -> UInt16 {
        // 防止重复 start()：若不守卫，第二次调用会新建一个 NWListener 并覆盖
        // self.listener，第一个 listener 失去引用但仍在旧端口上继续 accept，
        // 变成一个没人管、占着端口的孤儿监听者。
        guard listener == nil else {
            throw NSError(domain: "LocalHTTPServer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "服务已在运行，不能重复 start()"])
        }

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let l = try NWListener(using: params)
        listener = l

        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: self?.queue ?? .main)
            self?.receive(on: conn, buffer: Data())
        }

        // requiredLocalEndpoint 里的 .any 只是"请求"，实际分配的端口要等
        // listener 进入 .ready 状态后才能从 l.port 读到；在那之前 l.port
        // 会一直是我们传入的占位值（rawValue 0），必须等状态回调，不能轮询它。
        let sem = DispatchSemaphore(value: 0)
        var startupError: Error?
        l.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed:
                sem.signal()
            default:
                break
            }
        }
        l.start(queue: queue)

        let waitResult = sem.wait(timeout: .now() + 5)
        guard waitResult == .success, l.state == .ready else {
            if case .failed(let err) = l.state { startupError = err }
            listener = nil
            l.cancel()
            throw startupError ?? NSError(domain: "LocalHTTPServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "端口分配失败"])
        }
        guard let port = l.port?.rawValue, port > 0 else {
            listener = nil
            l.cancel()
            throw NSError(domain: "LocalHTTPServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "端口分配失败"])
        }
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func receive(on conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isDone, _ in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }

            // 等 header 收全，再按 Content-Length 等 body 收全。
            // 对面（curl/hook.sh）是阻塞等我们的响应的；这个端点绝不能把一个
            // 连接晾在那儿不闻不问——任何判定为"不完整/不合法"的请求都必须
            // 立刻回一个终态响应（这里选 deny，与 hook.sh 的 fail-closed 原则
            // 一致）并关闭连接，而不是静默 return。
            guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if isDone {
                    self.respondMalformed(on: conn, reason: "请求头不完整（连接提前关闭）")
                } else {
                    self.receive(on: conn, buffer: buf)
                }
                return
            }
            let header = String(decoding: buf[..<headerEnd.lowerBound], as: UTF8.self)
            guard let length = Self.contentLength(from: header) else {
                // Content-Length 缺失或无法解析：不能把这当成"body 长度是 0"
                // 就把已收到的（可能截断的）字节直接交给 handler，必须当成
                // 畸形请求处理。
                self.respondMalformed(on: conn, reason: "Content-Length 缺失或无法解析")
                return
            }
            let body = buf[headerEnd.upperBound...]
            if body.count >= length {
                self.respond(on: conn, body: Data(body.prefix(length)))
                return
            }
            if isDone {
                // 连接已经被对面关闭，但 body 没收全——同样必须回一个终态响应，
                // 否则连接会被晾着，curl 只能干等到它自己的 --max-time。
                self.respondMalformed(on: conn, reason: "请求体不完整（连接提前关闭）")
                return
            }
            self.receive(on: conn, buffer: buf)
        }
    }

    private func respond(on conn: NWConnection, body: Data) {
        Task {
            let responseBody = await self.handler?(body) ?? Data()
            self.send(on: conn, body: responseBody)
        }
    }

    /// 请求本身不完整/不合法时的默认响应：直接给一个 deny 决定。
    /// 这个端点唯一的消费者是 hook.sh，拿到格式正确但内容是 deny 的响应，
    /// 远比拿到空响应或永远等不到响应安全——后者会让 hook.sh 一路等到
    /// curl 自己的 --max-time 才能拒绝，白白浪费掉留给 app 侧超时的余量。
    private func respondMalformed(on conn: NWConnection, reason: String) {
        let denyJSON = """
        {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",\
        "permissionDecisionReason":"本地HTTP端点拒绝了畸形请求：\(reason)"}}
        """
        send(on: conn, body: Data(denyJSON.utf8))
    }

    private func send(on conn: NWConnection, body: Data) {
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        conn.send(content: Data(head.utf8) + body,
                  completion: .contentProcessed { _ in conn.cancel() })
    }

    /// 返回 nil 表示缺失或无法解析——调用方必须把它当成畸形请求处理，
    /// 不能 fall back 成 0（0 会让任何已收到的字节被当成"完整 body"直接放行）。
    private static func contentLength(from header: String) -> Int? {
        for line in header.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
