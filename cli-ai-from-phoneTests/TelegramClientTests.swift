import Testing
import Foundation
@testable import Steward

@Suite struct TelegramClientTests {
    @Test func parsesGetUpdatesResponse() throws {
        let json = """
        {"ok":true,"result":[
          {"update_id":100,"message":{"chat":{"id":555},"from":{"id":777},"text":"你好"}},
          {"update_id":101,"message":{"chat":{"id":555},"from":{"id":777},"text":"!ls"}}
        ]}
        """
        let updates = try TelegramClient.parseUpdates(Data(json.utf8))
        #expect(updates.count == 2)
        #expect(updates[0].updateID == 100)
        #expect(updates[0].chatID == 555)
        #expect(updates[0].userID == 777)
        #expect(updates[1].text == "!ls")
    }

    @Test func updatesWithoutTextAreSkipped() throws {
        let json = """
        {"ok":true,"result":[
          {"update_id":1,"message":{"chat":{"id":1},"from":{"id":2}}},
          {"update_id":2,"message":{"chat":{"id":1},"from":{"id":2},"text":"有文本"}}
        ]}
        """
        let updates = try TelegramClient.parseUpdates(Data(json.utf8))
        #expect(updates.count == 1)
        #expect(updates[0].text == "有文本")
    }

    @Test func status401ThrowsUnauthorizedNotGenericError() {
        // token 失效是唯一不该重试的情况，必须能与网络错误区分
        #expect(throws: TelegramError.unauthorized) {
            try TelegramClient.check(statusCode: 401)
        }
        #expect(throws: Never.self) {
            try TelegramClient.check(statusCode: 200)
        }
    }

    /// Telegram 的 409 表示另一个 long-polling 或 webhook 占用了这个 Bot。
    /// 这不是瞬时网络故障；若退化为通用 HTTP 错误，调用方会持续重试并让
    /// 连接 UI 在 Ready 与 Reconnecting 之间抖动。
    @Test func status409ThrowsPollingConflictNotGenericHTTPError() {
        #expect(throws: TelegramError.pollingConflict) {
            try TelegramClient.check(statusCode: 409)
        }
    }

    /// URLError 的描述会带上完整请求 URL，而 token 就在 URL 路径里。
    @Test func redactingTokenRemovesTokenFromErrorDescriptions() {
        let token = "123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw"
        let description = "Error Domain=NSURLErrorDomain Code=-1009 UserInfo={NSErrorFailingURLStringKey="
            + "https://api.telegram.org/bot\(token)/getUpdates?offset=0&timeout=50}"

        let redacted = TelegramClient.redactingToken(in: description)
        #expect(!redacted.contains(token))
        #expect(redacted.contains("https://api.telegram.org/bot<redacted>/getUpdates?offset=0"))

        // 不在 URL 里的 token 也要抹掉；格式不像 token 的 URL 路径段同样按 token 处理。
        #expect(TelegramClient.redactingToken(in: "token=\(token)") == "token=<redacted>")
        #expect(TelegramClient.redactingToken(in: "https://api.telegram.org/botabc/getMe")
                == "https://api.telegram.org/bot<redacted>/getMe")
    }

    @Test func redactingTokenLeavesOrdinaryTextUnchanged() {
        let text = "shell exit 0: echo bot 12:30 — retry in 4.0s, update 123456789"
        #expect(TelegramClient.redactingToken(in: text) == text)
    }

    @Test func verificationRequestsGetMeAndAcceptsSuccess() async throws {
        let client = TelegramClient(token: "new-token") { request in
            #expect(request.url?.absoluteString == "https://api.telegram.org/botnew-token/getMe")
            return (Data("{\"ok\":true}".utf8), HTTPURLResponse(
                url: URL(string: "https://example.invalid")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!)
        }

        try await client.verify()
    }

    @Test func verificationRejectsMalformedTokenWithoutStartingARequest() async {
        let client = TelegramClient(token: "%%%") { _ in
            Issue.record("A malformed token must fail before any HTTP request is made")
            return (Data(), HTTPURLResponse(
                url: URL(string: "https://example.invalid")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!)
        }

        await #expect(throws: TelegramError.invalidRequest) {
            try await client.verify()
        }
    }

    @Test func verificationRejectsAnInvalidTokenBeforeConnectionStarts() async {
        let client = TelegramClient(token: "expired-token") { _ in
            (Data("{\"ok\":false}".utf8), HTTPURLResponse(
                url: URL(string: "https://example.invalid")!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil)!)
        }

        await #expect(throws: TelegramError.unauthorized) {
            try await client.verify()
        }
    }

    @Test func backoffIsCappedAt60Seconds() {
        #expect(TelegramClient.backoff(attempt: 0) == 1)
        #expect(TelegramClient.backoff(attempt: 3) == 8)
        #expect(TelegramClient.backoff(attempt: 99) == 60)
    }

    /// 首次连接需要尽快证明 Bot Token 和 Telegram API 可用；若一开始就
    /// 用 25 秒长轮询，UI 会在没有新消息时无意义地卡住一整个 timeout。
    @Test func firstTelegramProbeDoesNotUseLongPolling() {
        #expect(TelegramClient.pollTimeout(isInitialProbe: true) == 0)
        #expect(TelegramClient.pollTimeout(isInitialProbe: false) == 25)
    }

    @Test func offsetIsOneGreaterThanHighestUpdateID() async {
        let c = TelegramClient(token: "fake")
        await c.acknowledge(upTo: 101)
        #expect(await c.nextOffset == 102)
    }

    @Test func oneTypeMismatchedElementDoesNotPoisonTheBatch() throws {
        // chat.id 类型不匹配（应为数字却是字符串）——只有这一条该被丢弃，
        // 前后两条结构完整的 update 必须照常返回，不能被这一条拖累整批失败。
        let json = """
        {"ok":true,"result":[
          {"update_id":100,"message":{"chat":{"id":555},"from":{"id":777},"text":"好的"}},
          {"update_id":101,"message":{"chat":{"id":"不是数字"},"from":{"id":777},"text":"坏消息"}},
          {"update_id":102,"message":{"chat":{"id":555},"from":{"id":777},"text":"仍然正常"}}
        ]}
        """
        let updates = try TelegramClient.parseUpdates(Data(json.utf8))
        #expect(updates.map(\.updateID) == [100, 102])
    }

    @Test func fullyMalformedBatchDoesNotThrow() throws {
        // 两条都有类型不匹配的必填字段：不应该抛出让调用方晾在那里，
        // 应该优雅地返回空数组。
        let json = """
        {"ok":true,"result":[
          {"update_id":200,"message":{"chat":{"id":"x"},"from":{"id":1},"text":"a"}},
          {"update_id":201,"message":{"chat":{"id":"y"},"from":{"id":1},"text":"b"}}
        ]}
        """
        let updates = try TelegramClient.parseUpdates(Data(json.utf8))
        #expect(updates.isEmpty)
    }

    @Test func undecodableHighestUpdateIsStillSkippedViaHighestUpdateID() throws {
        // 101 是这批里最大的 update_id，但它本身解码失败。如果只看 `updates`
        // 数组（里面只有 100），offset 永远推不到 102，下次轮询还会拿到同样
        // 卡住的批次。highestUpdateID 必须是 101，好让调用方能主动越过它。
        let json = """
        {"ok":true,"result":[
          {"update_id":100,"message":{"chat":{"id":555},"from":{"id":777},"text":"好的"}},
          {"update_id":101,"message":{"chat":{"id":"坏"},"from":{"id":777},"text":"坏消息"}}
        ]}
        """
        let result = try TelegramClient.parseUpdatesDetailed(Data(json.utf8))
        #expect(result.updates.map(\.updateID) == [100])
        #expect(result.highestUpdateID == 101)
    }

    @Test func unreadableUpdateIDCannotBeAckedIndividuallyButDoesNotThrow() throws {
        // update_id 字段本身类型不对：这一条既进不了 updates，也算不进
        // highestUpdateID——没有办法单独越过它。但函数本身不应该抛错，
        // 调用方仍能拿到空结果继续下一轮轮询（未来更高 id 的正常消息
        // 到来时，会顺带把 offset 带过这一条）。
        let json = """
        {"ok":true,"result":[
          {"update_id":"oops","message":{"chat":{"id":1},"from":{"id":1},"text":"a"}}
        ]}
        """
        let result = try TelegramClient.parseUpdatesDetailed(Data(json.utf8))
        #expect(result.updates.isEmpty)
        #expect(result.highestUpdateID == nil)
    }
}
