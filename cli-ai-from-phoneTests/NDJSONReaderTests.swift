import Testing
import Foundation
@testable import Steward

@Suite struct NDJSONReaderTests {
    @Test func multipleLinesInOneFeed() {
        var r = NDJSONReader()
        let out = r.feed(Data("a\nb\nc\n".utf8))
        #expect(out.map { String(decoding: $0, as: UTF8.self) } == ["a", "b", "c"])
    }

    @Test func partialLineIsBufferedUntilNewlineArrives() {
        var r = NDJSONReader()
        #expect(r.feed(Data("hel".utf8)).isEmpty)
        #expect(r.feed(Data("lo".utf8)).isEmpty)
        let out = r.feed(Data("\n".utf8))
        #expect(out.map { String(decoding: $0, as: UTF8.self) } == ["hello"])
    }

    /// 关键用例：按字节切分而非按字符，所以 UTF-8 多字节被劈开也不会乱码
    @Test func utf8MultibyteSplitAcrossChunks() {
        var r = NDJSONReader()
        let bytes = Array("你好\n".utf8)          // 你=3字节 好=3字节 \n=1字节
        #expect(r.feed(Data(bytes[0..<2])).isEmpty)   // 劈在「你」的中间
        let out = r.feed(Data(bytes[2...]))
        #expect(out.map { String(decoding: $0, as: UTF8.self) } == ["你好"])
    }

    @Test func emptyLinesAreDropped() {
        var r = NDJSONReader()
        let out = r.feed(Data("a\n\n\nb\n".utf8))
        #expect(out.count == 2)
    }

    @Test func trailingDataWithoutNewlineIsNotEmitted() {
        var r = NDJSONReader()
        let out = r.feed(Data("a\nb".utf8))
        #expect(out.map { String(decoding: $0, as: UTF8.self) } == ["a"])
    }
}
