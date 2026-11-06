import Foundation

struct TelegramUpdate: Equatable {
    let updateID: Int64
    let chatID: Int64
    let userID: Int64
    let text: String
}

enum TelegramError: Error, Equatable {
    case invalidRequest
    case unauthorized
    /// Telegram only permits one `getUpdates` consumer for a bot at a time.
    /// A 409 is therefore an ownership conflict, not a transient HTTP error.
    case pollingConflict
    case http(Int)
    /// 顶层信封本身不是预期形状（例如 "result" 缺失或不是数组）。
    /// 这与「某一条 update 解码失败」不同——那种情况被 parseUpdatesDetailed
    /// 逐条吸收，不会走到这里。这里代表调用方能看到、能重试的可见错误，
    /// 而不是静默卡住。
    case malformedResponse
}

typealias TelegramRequestExecutor = @Sendable (URLRequest) async throws -> (Data, URLResponse)

/// `parseUpdatesDetailed` / `poll` 的返回值。
///
/// `highestUpdateID` 是本批次里出现过的最大 update_id——即使某条 update 本身
/// 解码失败（必填字段类型不匹配等），只要它的 update_id 字段本身能读出来，
/// 依然计入。这是刻意选择的、比"逐条列出丢弃了哪些 id"更简单也更充分的设计：
/// `acknowledge(upTo:)` 语义本来就是取 max，只要调用方在处理完 `updates` 之后
/// 再对 `highestUpdateID` 调一次 acknowledge，就能保证 offset 越过批次里的每一条
/// （不论它是否成功解码），不需要逐条 id 的列表。
struct TelegramPollResult: Equatable {
    let updates: [TelegramUpdate]
    let highestUpdateID: Int64?
}

actor TelegramClient {
    private let token: String
    private let executeRequest: TelegramRequestExecutor
    private(set) var nextOffset: Int64 = 0

    init(token: String) {
        self.init(token: token, executeRequest: { request in
            try await URLSession.shared.data(for: request)
        })
    }

    init(token: String, executeRequest: @escaping TelegramRequestExecutor) {
        self.token = token
        self.executeRequest = executeRequest
    }

    /// Verifies the token before a new connection is allowed to replace a
    /// previously saved, working configuration.
    func verify() async throws {
        let allowedTokenCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ":_-"))
        guard !token.isEmpty,
              token.unicodeScalars.allSatisfy(allowedTokenCharacters.contains),
              let url = URL(string: "https://api.telegram.org/bot\(token)/getMe") else {
            throw TelegramError.invalidRequest
        }
        let (_, response) = try await executeRequest(URLRequest(url: url))
        try Self.check(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// offset 只在消息处理完成后推进，断线重连不丢消息（spec §6.6）
    func acknowledge(upTo updateID: Int64) {
        nextOffset = max(nextOffset, updateID + 1)
    }

    func poll(timeout: Int = 25) async throws -> TelegramPollResult {
        var c = URLComponents(string: "https://api.telegram.org/bot\(token)/getUpdates")!
        c.queryItems = [
            .init(name: "timeout", value: String(timeout)),
            .init(name: "offset", value: String(nextOffset)),
        ]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = TimeInterval(timeout + 10)

        let (data, response) = try await executeRequest(req)
        try Self.check(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        return try Self.parseUpdatesDetailed(data)
    }

    func send(chatID: Int64, text: String) async throws {
        for chunk in TelegramFormatter.chunks(text) {
            let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(
                withJSONObject: ["chat_id": chatID, "text": chunk])
            let (_, response) = try await executeRequest(req)
            try Self.check(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    // MARK: - 纯函数，供测试直接调用

    static func check(statusCode: Int) throws {
        if statusCode == 401 { throw TelegramError.unauthorized }
        if statusCode == 409 { throw TelegramError.pollingConflict }
        if !(200..<300).contains(statusCode) { throw TelegramError.http(statusCode) }
    }

    /// Bot API 把 token 放在 URL 路径里（`/bot<token>/method`），URLError
    /// 等错误的描述会带上完整 URL。写进日志或显示在 UI 之前先抹掉 token。
    static func redactingToken(in text: String) -> String {
        text
            .replacingOccurrences(of: #"(api\.telegram\.org/bot)[^/\s"']+"#,
                                  with: "$1<redacted>", options: .regularExpression)
            .replacingOccurrences(of: #"\b\d{5,}:[A-Za-z0-9_-]{30,}"#,
                                  with: "<redacted>", options: .regularExpression)
    }

    /// 指数退避，封顶 60 秒
    static func backoff(attempt: Int) -> TimeInterval {
        min(pow(2.0, Double(attempt)), 60)
    }

    /// 首次调用使用即时响应来确认 Telegram API/Token 可用；后续调用才进入
    /// 正常长轮询，避免连接 UI 因为没有新消息而无谓等待 25 秒。
    static func pollTimeout(isInitialProbe: Bool) -> Int {
        isInitialProbe ? 0 : 25
    }

    static func parseUpdates(_ data: Data) throws -> [TelegramUpdate] {
        try parseUpdatesDetailed(data).updates
    }

    /// 逐条解码而非整批一次性 decode：某一条 update 的必填字段类型不匹配
    /// （例如 chat.id 本该是数字却传来字符串）时，只丢弃这一条，不连累
    /// 其余结构完整的 update——否则一条坏消息会让整批（乃至下一次轮询，因为
    /// offset 没推进）永远解析失败，poll 循环看起来像是卡死了。
    ///
    /// 每条元素的 update_id 单独尝试读取（与该条其余部分是否解码成功无关），
    /// 汇总进 highestUpdateID，供调用方在必要时越过解码失败的那条 acknowledge。
    static func parseUpdatesDetailed(_ data: Data) throws -> TelegramPollResult {
        struct Message: Decodable {
            struct Chat: Decodable { let id: Int64 }
            struct From: Decodable { let id: Int64 }
            let chat: Chat
            let from: From?
            let text: String?
        }
        struct Update: Decodable {
            let update_id: Int64
            let message: Message?
        }

        guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawResult = top["result"] as? [[String: Any]]
        else {
            // 顶层信封本身不是预期形状：这是调用方能看见、能走正常错误/重试路径
            // 处理的失败，不是"静默卡住"，所以直接抛出。
            throw TelegramError.malformedResponse
        }

        var updates: [TelegramUpdate] = []
        var highestID: Int64?

        for rawUpdate in rawResult {
            // update_id 的可读性与这条其余部分是否能解码无关——即使这条整体
            // 解码失败，只要 update_id 本身读得出来，也要计入 highestID。
            if let idNumber = rawUpdate["update_id"] as? NSNumber {
                let id = idNumber.int64Value
                highestID = max(highestID ?? id, id)
            }

            guard let elementData = try? JSONSerialization.data(withJSONObject: rawUpdate),
                  let update = try? JSONDecoder().decode(Update.self, from: elementData)
            else {
                continue // 这一条解码失败：跳过，不连累其余条目
            }
            guard let m = update.message, let text = m.text, let from = m.from else { continue }
            updates.append(TelegramUpdate(updateID: update.update_id, chatID: m.chat.id,
                                          userID: from.id, text: text))
        }
        return TelegramPollResult(updates: updates, highestUpdateID: highestID)
    }
}
