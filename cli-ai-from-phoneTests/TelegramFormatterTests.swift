import Testing
@testable import Steward

@Suite struct TelegramFormatterTests {
    @Test func shortTextIsReturnedUnchanged() {
        #expect(TelegramFormatter.chunks("你好") == ["你好"])
    }

    @Test func emptyTextReturnsEmptyArray() {
        #expect(TelegramFormatter.chunks("").isEmpty)
    }

    @Test func longTextIsSplitAndEveryChunkStaysUnderLimit() {
        let text = (1...500).map { "第 \($0) 行内容填充填充" }.joined(separator: "\n")
        let out = TelegramFormatter.chunks(text, limit: 200)
        #expect(out.count > 1)
        for c in out { #expect(c.count <= 200) }
    }

    @Test func splittingLosesNoContent() {
        let text = (1...100).map(String.init).joined(separator: "\n")
        let out = TelegramFormatter.chunks(text, limit: 50)
        #expect(out.joined(separator: "\n").replacingOccurrences(of: "\n", with: "")
                == text.replacingOccurrences(of: "\n", with: ""))
    }

    /// 核心用例：代码块跨片时，前片必须补上收尾 ```，后片必须补上开头 ```
    @Test func codeFencesStayBalancedAcrossChunks() {
        let code = (1...60).map { "let x\($0) = \($0)" }.joined(separator: "\n")
        let text = "看代码：\n```swift\n\(code)\n```"
        let out = TelegramFormatter.chunks(text, limit: 200)
        #expect(out.count > 1)
        for c in out {
            let fences = c.components(separatedBy: "```").count - 1
            #expect(fences % 2 == 0, "每一片的 ``` 数量必须是偶数，实际 \(fences)")
        }
        #expect(out[1].hasPrefix("```swift"))
    }

    @Test func oversizedSingleLineIsHardSplit() {
        let long = String(repeating: "x", count: 500)
        let out = TelegramFormatter.chunks(long, limit: 100)
        #expect(out.count == 5)
        for c in out { #expect(c.count <= 100) }
    }

    /// 回归用例：围栏内单行超长时硬切。此时 flush 后的新片起手就是非空的
    /// 重新打开的围栏前缀（如 "```swift"），若硬切阈值只按 limit-4 固定计算、
    /// 不考虑 current 已有长度，会算出超过 limit 的片段。
    @Test func oversizedLineInsideFenceIsHardSplitAndStaysBalancedAndUnderLimit() {
        let longLine = "let s = \"" + String(repeating: "y", count: 300) + "\""
        let text = "```swift\n\(longLine)\n```"
        let out = TelegramFormatter.chunks(text, limit: 100)
        #expect(out.count > 1)
        for c in out {
            #expect(c.count <= 100)
            let fences = c.components(separatedBy: "```").count - 1
            #expect(fences % 2 == 0, "每一片的 ``` 数量必须是偶数，实际 \(fences)")
        }
    }

    /// 回归用例（Finding 1，第二轮 code review 发现）：重新打开的围栏前缀
    /// （如 "```python"）本身就比预算大时，旧的“room<=0 就整段塞入”兜底
    /// 会直接无视 limit 倾泻剩余内容。
    @Test func oversizedFencePrefixMustNotExceedLimit() {
        let text = "```python\nlet x = 1\nlet y = 2\n```"
        let out = TelegramFormatter.chunks(text, limit: 12)
        #expect(!out.isEmpty)
        for c in out {
            #expect(c.count <= 12, "长度 \(c.count) 超过 limit=12：\(c)")
            let fences = c.components(separatedBy: "```").count - 1
            #expect(fences % 2 == 0, "每一片的 ``` 数量必须是偶数，实际 \(fences)")
        }
    }

    /// 回归用例（Finding 2，第二轮 code review 发现）：预算曾按“这一行处理前”的
    /// 围栏状态计算，而开合栏切换发生在处理之后，导致开栏行本身没有为收尾预留空间。
    @Test func budgetMustUsePostLineFenceState() {
        let text = "\n\n```js\n```js\n```"
        let out = TelegramFormatter.chunks(text, limit: 15)
        #expect(!out.isEmpty)
        for c in out {
            #expect(c.count <= 15, "长度 \(c.count) 超过 limit=15：\(c)")
            let fences = c.components(separatedBy: "```").count - 1
            #expect(fences % 2 == 0, "每一片的 ``` 数量必须是偶数，实际 \(fences)")
        }
    }

    // MARK: - 属性测试

    /// 确定性种子的伪随机数生成器（SplitMix64），保证失败可复现，而不是像
    /// SystemRandomNumberGenerator 那样每次运行结果不同、失败即消失。
    struct SeededRNG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// 随机生成一段可能包含围栏代码块（带/不带语言标签）、CJK 文本、
    /// ASCII 文本、以及远超 limit 的单行的文本。围栏标记只出现在行首
    /// （标准 Markdown 约定，也是 TelegramFormatter 识别围栏的方式），
    /// 不在行中间插入裸反引号——那是另一个不在本轮修复范围内、
    /// 依赖“```必须在行首”这个既有约定之外的问题。
    static func randomText(rng: inout SeededRNG, limit: Int) -> String {
        let cjkWords = ["你好", "测试", "围栏", "代码块", "中文文本填充", "手机", "渲染", "分片"]
        let asciiWords = ["let", "x", "=", "1", "func", "return", "guard", "swift", "if", "else"]
        let langTags = ["", "swift", "python", "js", "c++", "bash"]

        var lines: [String] = []
        let lineCount = Int.random(in: 0...25, using: &rng)
        var fenceOpen = false

        for _ in 0..<lineCount {
            let kind = Int.random(in: 0...9, using: &rng)
            switch kind {
            case 0:
                // 围栏标记行（开栏或闭栏，取决于当前状态）。
                if fenceOpen {
                    lines.append("```")
                    fenceOpen = false
                } else {
                    let lang = langTags.randomElement(using: &rng) ?? ""
                    lines.append("```\(lang)")
                    fenceOpen = true
                }
            case 1:
                // 远超 limit 的单行（含 CJK，测试硬切在多字节字符下的行为）。
                let n = Int.random(in: max(1, limit * 2)...max(2, limit * 5), using: &rng)
                let useCJK = Bool.random(using: &rng)
                lines.append(String(repeating: useCJK ? "字" : "x", count: n))
            case 2, 3:
                lines.append("")
            default:
                let wordCount = Int.random(in: 1...6, using: &rng)
                let pool = Bool.random(using: &rng) ? cjkWords : asciiWords
                lines.append((0..<wordCount).map { _ in pool.randomElement(using: &rng)! }
                    .joined(separator: " "))
            }
        }
        if fenceOpen { lines.append("```") } // 大多数用例保持围栏配对，另有专门用例测试未闭合的情况
        return lines.joined(separator: "\n")
    }

    @Test func bothInvariantsHoldAcrossRandomisedInputs() {
        // 必须覆盖的两个已知退化场景（见上面两个专门的回归用例），
        // 混入随机语料的固定种子集合中，保证属性测试本身也覆盖它们。
        let fixedCases: [(String, Int)] = [
            ("```python\nlet x = 1\nlet y = 2\n```", 12),
            ("\n\n```js\n```js\n```", 15),
        ]

        let smallLimits = [1, 2, 3, 5, 10, 15, 20]
        var rng = SeededRNG(seed: 0xC0FF_EE12_3456_789A)

        var cases: [(String, Int)] = fixedCases
        for limit in smallLimits {
            for _ in 0..<20 {
                cases.append((Self.randomText(rng: &rng, limit: limit), limit))
            }
        }
        let biggerLimits = [30, 50, 100, 200, 4000]
        for limit in biggerLimits {
            for _ in 0..<20 {
                cases.append((Self.randomText(rng: &rng, limit: limit), limit))
            }
        }
        // 未闭合围栏（文本在围栏内结束）单独补几例，覆盖 flush() 需要在
        // 文本结尾自行补齐收尾 ``` 的路径。
        for limit in [7, 12, 20, 200] {
            cases.append(("```swift\nlet a = 1\nlet b = 2", limit))
        }

        #expect(cases.count >= 200, "属性测试用例数应达到数百级别，实际 \(cases.count)")

        for (text, limit) in cases {
            let out = TelegramFormatter.chunks(text, limit: limit)
            for c in out {
                #expect(c.count <= limit,
                        "limit=\(limit) 下出现超限片段（长度 \(c.count)）：\(c.prefix(80))")
                let fences = c.components(separatedBy: "```").count - 1
                #expect(fences % 2 == 0,
                        "limit=\(limit) 下出现奇数个 ``` 的片段：\(c.prefix(80))")
            }
        }
    }
}
