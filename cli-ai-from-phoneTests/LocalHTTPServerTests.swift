import Testing
import Foundation
import Darwin
@testable import Steward

/// 用裸 BSD socket 发一个手工拼的 HTTP 请求，可选在写完之后半关闭写端
/// （模拟"对面提前关闭连接"），然后把服务端在 readTimeout 秒内回的所有字节
/// 读回来。用来测试 LocalHTTPServer 在畸形/被截断请求下的终态响应，
/// URLSession 做不出"声明的 Content-Length 比实际发送的字节数大"这种请求。
private func sendRawHTTPRequest(
    port: UInt16,
    raw: String,
    halfCloseAfterWrite: Bool,
    readTimeout: TimeInterval = 5
) throws -> Data {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket() 失败"])
    }
    defer { Darwin.close(fd) }

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")

    let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connectResult == 0 else {
        throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "connect() 失败"])
    }

    let bytes = Array(raw.utf8)
    bytes.withUnsafeBufferPointer { buf in
        _ = write(fd, buf.baseAddress, buf.count)
    }
    if halfCloseAfterWrite {
        shutdown(fd, SHUT_WR)
    }

    var tv = timeval(tv_sec: Int(readTimeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { break }
        result.append(contentsOf: buffer[0..<n])
    }
    return result
}

@Suite struct LocalHTTPServerTests {
    @Test func postRequestReturnsHandlerResult() async throws {
        let server = LocalHTTPServer()
        server.handler = { body in
            let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            let tool = obj?["tool_name"] as? String ?? "?"
            return Data(#"{"echo":"\#(tool)"}"#.utf8)
        }
        let port = try server.start()
        defer { server.stop() }
        #expect(port > 0)

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/permission")!)
        req.httpMethod = "POST"
        req.httpBody = Data(#"{"tool_name":"Bash"}"#.utf8)

        let (data, _) = try await URLSession.shared.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["echo"] as? String == "Bash")
    }

    @Test func generatedSettingsJSONContainsPreToolUseHook() throws {
        let json = HookSettings.json(hookPath: "/tmp/hook.sh", port: 1234)
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let hooks = obj?["hooks"] as? [String: Any]
        #expect(hooks?["PreToolUse"] != nil)
        #expect(json.contains("/tmp/hook.sh"))
    }

    // MARK: - Finding 4：重复 start() 必须报错，而不是新建一个孤儿 listener

    @Test func repeatedStartThrowsInsteadOfOrphaningAListener() throws {
        let server = LocalHTTPServer()
        _ = try server.start()
        defer { server.stop() }
        #expect(throws: (any Error).self) {
            _ = try server.start()
        }
    }

    // MARK: - Finding 3：请求不完整/畸形时必须回终态响应并关闭连接，不能晾着不管

    @Test func shortBodyWithEarlyCloseMustAnswerDenyNotHang() async throws {
        let server = LocalHTTPServer()
        server.handler = { _ in Data(#"{"echo":"不应该被调用"}"#.utf8) }
        let port = try server.start()
        defer { server.stop() }

        // 声明 Content-Length: 100，但只发 5 字节就 half-close 写端，
        // 模拟"连接被接受后提前中断"。旧实现在 isDone && body.count < length
        // 时什么也不做，这里必须能在 readTimeout 内收到一个终态响应。
        let raw = "POST /permission HTTP/1.1\r\nContent-Length: 100\r\nConnection: close\r\n\r\nshort"
        let responseData = try sendRawHTTPRequest(port: port, raw: raw, halfCloseAfterWrite: true)

        #expect(!responseData.isEmpty, "服务端必须回一个终态响应，不能把连接晾着")
        let text = String(decoding: responseData, as: UTF8.self)
        guard let bodyStart = text.range(of: "\r\n\r\n") else {
            Issue.record("响应没有 HTTP body：\(text)")
            return
        }
        let bodyText = String(text[bodyStart.upperBound...])
        let obj = try JSONSerialization.jsonObject(with: Data(bodyText.utf8)) as? [String: Any]
        let hookOutput = obj?["hookSpecificOutput"] as? [String: Any]
        #expect(hookOutput?["permissionDecision"] as? String == "deny")
    }

    @Test func missingOrUnparsableContentLengthMustAnswerDenyNotPassTruncatedBody() async throws {
        let server = LocalHTTPServer()
        var handlerCalled = false
        server.handler = { _ in
            handlerCalled = true
            return Data(#"{"echo":"不应该被调用"}"#.utf8)
        }
        let port = try server.start()
        defer { server.stop() }

        // 完整的请求头，但 Content-Length 是非法值（不是数字）——
        // 旧实现 `?? 0` 会把这当成"body 长度 0"直接放行给 handler。
        let raw = "POST /permission HTTP/1.1\r\nContent-Length: not-a-number\r\nConnection: close\r\n\r\nirrelevant-body"
        let responseData = try sendRawHTTPRequest(port: port, raw: raw, halfCloseAfterWrite: true)

        #expect(!responseData.isEmpty, "服务端必须回一个终态响应")
        let text = String(decoding: responseData, as: UTF8.self)
        guard let bodyStart = text.range(of: "\r\n\r\n") else {
            Issue.record("响应没有 HTTP body：\(text)")
            return
        }
        let bodyText = String(text[bodyStart.upperBound...])
        let obj = try JSONSerialization.jsonObject(with: Data(bodyText.utf8)) as? [String: Any]
        let hookOutput = obj?["hookSpecificOutput"] as? [String: Any]
        #expect(hookOutput?["permissionDecision"] as? String == "deny")
        #expect(!handlerCalled, "Content-Length 非法时不应该把请求交给业务 handler")
    }
}
