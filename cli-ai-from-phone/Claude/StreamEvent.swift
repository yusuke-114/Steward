import Foundation

struct ToolUse: Equatable {
    let id: String
    let name: String
}

enum StreamEvent: Equatable {
    case system(subtype: String?, sessionID: String)
    case assistant(text: String?, toolUses: [ToolUse])
    case toolResult(isError: Bool)
    case result(text: String?, isError: Bool)
    case unknown(type: String)
}

extension StreamEvent {
    /// 一个 content block。tool_use / text / tool_result 共用此结构，
    /// 各自用不到的字段为 nil；未声明的字段（如 input）被忽略，不会导致解码失败。
    private struct Block: Decodable {
        let type: String
        let text: String?
        let id: String?
        let name: String?
        let isError: Bool?

        enum CodingKeys: String, CodingKey {
            case type, text, id, name
            case isError = "is_error"
        }
    }

    private struct Message: Decodable {
        let content: [Block]?
    }

    private struct Raw: Decodable {
        let type: String
        let subtype: String?
        let sessionID: String?
        let isError: Bool?
        let result: String?
        let message: Message?

        enum CodingKeys: String, CodingKey {
            case type, subtype
            case sessionID = "session_id"
            case isError = "is_error"
            case result, message
        }
    }

    init(jsonLine: Data) throws {
        let raw = try JSONDecoder().decode(Raw.self, from: jsonLine)
        switch raw.type {
        case "system":
            // 实测一个会话里 system 出现多次：hook_started / hook_response
            // 抢在真正的 init 之前。消费方须靠 subtype 区分，不能假设只有一个。
            self = .system(subtype: raw.subtype, sessionID: raw.sessionID ?? "")

        case "assistant":
            let blocks = raw.message?.content ?? []
            let texts = blocks.filter { $0.type == "text" }.compactMap(\.text)
            let tools = blocks.filter { $0.type == "tool_use" }.compactMap { b -> ToolUse? in
                guard let id = b.id, let name = b.name else { return nil }
                return ToolUse(id: id, name: name)
            }
            let joined = texts.joined(separator: "\n\n")
            self = .assistant(text: joined.isEmpty ? nil : joined, toolUses: tools)

        case "user":
            // 实测：user 事件顶层没有 is_error（顶层 key 只有 message /
            // parent_tool_use_id / session_id / timestamp / tool_use_result /
            // type / uuid），真正的失败标志嵌在 message.content[].is_error。
            // 读顶层会让每个 tool_result 都报成成功。
            let resultBlocks = raw.message?.content ?? []
            self = .toolResult(isError: resultBlocks.contains {
                $0.type == "tool_result" && $0.isError == true
            })

        case "result":
            self = .result(text: raw.result, isError: raw.isError ?? false)

        default:
            self = .unknown(type: raw.type)
        }
    }
}
