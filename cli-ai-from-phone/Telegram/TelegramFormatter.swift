import Foundation

enum TelegramFormatter {
    /// 把文本切成不超过 limit 的片段。
    /// 跨片的 ``` 代码块会在前片补收尾、后片补开头，保证每片自身渲染正确。
    static func chunks(_ text: String, limit: Int = 4000) -> [String] {
        guard !text.isEmpty else { return [] }
        // 注意：这里不能像早期草稿那样 `guard text.count > limit else { return [text] }`
        // 直接短路返回。属性测试（见 TelegramFormatterTests）发现：如果原文本本身
        // 就带着未闭合的围栏（奇数个 ```）却整体不超过 limit，短路会把这个未配对的
        // ``` 原样返回，破坏“每片 ``` 数为偶数”的不变量。下面的通用算法对不超限的
        // 正常文本（无论是否含围栏）总是原样重建为单一分片，只有在文本本身围栏未
        // 配对时才会介入补齐——所以统一走一条路径，不再单独短路。

        // 补收尾 "\n```" 需要预留的字符数。
        let fenceOverhead = 4
        // 围栏标记本身的长度，视为不可再切的原子单元（见 appendMarkerLine）。
        let markerLen = 3

        var result: [String] = []
        var current = ""
        // current 可能只是重新打开的围栏前缀（例如 "```swift"），此时并无“真实内容”可供输出。
        // 用 isFresh 显式区分“current 为空/只有围栏前缀”与“current 已含真实内容”，
        // 不能像最初草稿那样只用 current.isEmpty 判断——那样会把非空的裸围栏前缀误判为“有内容”。
        var isFresh = true
        var openFenceLang: String?

        // budget(openAfter:) 是本轮修复的核心：预算必须按“这一行处理完之后”围栏是否
        // 仍处于打开状态来算，而不是按处理前的状态——处理前状态是过期信息，用它算出的
        // 预算在“这一行本身就是开栏行”时会算多（漏留收尾用的 4 个字符）。
        func budget(openAfter: Bool) -> Int {
            limit - (openAfter ? fenceOverhead : 0)
        }

        func currentBudget() -> Int {
            budget(openAfter: openFenceLang != nil)
        }

        func resetFresh() {
            current = openFenceLang.map { "```\($0)" } ?? ""
            isFresh = true
        }

        func flush() {
            guard !isFresh else { return }
            result.append(openFenceLang == nil ? current : current + "\n```")
            resetFresh()
        }

        func addToCurrent(_ s: Substring) {
            current = current.isEmpty ? String(s) : current + "\n" + s
            isFresh = false
        }

        // 普通行：动态按“当前剩余空间”硬切，硬切阈值不是固定值，而是每次都从
        // current 实际长度重新算——因为 current 长度会随 flush/reopen 变化。
        //
        // room 在“全新片”场景下恒 >= 1，这不是巧合：appendMarkerLine 只有在
        // sustainable(...) 成立时才会提交 openFenceLang，而 sustainable 恰好保证了
        // “重新打开围栏后的前缀 + 1 个字符的余量”不超过预算。因此这里不需要、也不应该
        // 用 max(1, ...) 强行钳制 room——那样会在 room 本该 <=0 的极端情形下超写、
        // 破坏“每片不超限”。真出现 room<=0（理论上不可达，留作防御）时选择放弃这一行
        // 剩余内容而不是超限。
        func appendLine(_ line: String) {
            var remaining = Substring(line)
            while true {
                let b = currentBudget()
                let sepCost = current.isEmpty ? 0 : 1
                if current.count + sepCost + remaining.count <= b {
                    addToCurrent(remaining)
                    return
                }
                if !isFresh {
                    // 当前片已有真实内容装不下这一行，先收尾当前片，换新片再试。
                    flush()
                    continue
                }
                // 已经是全新的片，仍装不下 —— 只能硬切。
                let room = b - current.count - sepCost
                guard room > 0 else {
                    // 防御性分支：按上面的论证不应到达。为避免死循环或超限，放弃剩余内容。
                    return
                }
                let cut = remaining.index(
                    remaining.startIndex,
                    offsetBy: min(room, remaining.count)
                )
                addToCurrent(remaining[remaining.startIndex..<cut])
                remaining = remaining[cut...]
                if remaining.isEmpty { return }
                flush()
            }
        }

        // 围栏行（以 ``` 开头）：``` 三个字符必须整体出现在同一片里，绝不能被硬切——
        // 否则某一片可能只留下 1、2 个反引号，或者只有收尾没有开头，破坏“每片
        // ``` 数量为偶数”的不变量。语言标签（如 "swift"）不受此约束，可以丢弃。
        //
        // 三级降级，从宽松到保守：
        //   1) 完整 "```lang"（或原始整行）放入现有片；放不下则 flush 后放入全新片。
        //   2) 仍放不下：退化为裸 "```"（丢弃语言标签/行尾多余字符），同样先试现有片、
        //      再试全新片。
        //   3) 连裸 "```" 都放不下全新片，或即使放得下也不足以支撑后续任何内容
        //      （见 sustainable(_:)）：说明 limit 太小，无法用围栏语义表示这一段。
        //      选择的退化策略是——整行丢弃、不切换围栏状态，宁可丢失这 3 个字符
        //      （或连同语言标签）也绝不超过 limit、也绝不产出奇数个 ``` 的片，
        //      也绝不让后续内容陷入“新片一开始就已经超预算”的死局。
        //      这一决策见 task-4-report.md 的详细说明。
        //
        // 预算统一用“这一行处理完之后”的围栏状态计算：开栏预留 4 字符，闭栏不预留
        // （因为闭栏后这一片如果被 flush，围栏已经用真实的 ``` 结束，不需要再补）。
        //
        // sustainable(lang)：只在“开栏”时才有意义。它保证一旦提交 openFenceLang，
        // 每次 resetFresh() 产出的重新打开前缀（"```" + lang）在预算里至少还留
        // 1 个字符给后续真实内容——否则每一个新片一开局就已经把预算用尽甚至用超，
        // appendLine 的硬切逻辑将永远无法为该行腾出哪怕 1 个字符的空间。
        func appendMarkerLine(_ line: String) {
            let willOpen = openFenceLang == nil
            let langTag = willOpen ? String(line.dropFirst(markerLen)) : ""
            let b = budget(openAfter: willOpen)
            let fullAtom = line
            let bareAtom = "```"

            func fits(_ atom: String) -> Bool {
                let sepCost = current.isEmpty ? 0 : 1
                return current.count + sepCost + atom.count <= b
            }
            func sustainable(_ lang: String) -> Bool {
                guard willOpen else { return true }
                return markerLen + lang.count + 1 + 1 <= b // 前缀 + 分隔符 + 至少 1 字符内容
            }

            if fits(fullAtom), sustainable(langTag) {
                addToCurrent(Substring(fullAtom))
                openFenceLang = willOpen ? langTag : nil
                return
            }
            if !isFresh {
                flush()
                if fits(fullAtom), sustainable(langTag) {
                    addToCurrent(Substring(fullAtom))
                    openFenceLang = willOpen ? langTag : nil
                    return
                }
            }
            if fullAtom != bareAtom, fits(bareAtom), sustainable("") {
                addToCurrent(Substring(bareAtom))
                openFenceLang = willOpen ? "" : nil
                return
            }
            // 三级：整行丢弃，不切换 openFenceLang。
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("```") {
                appendMarkerLine(line)
            } else {
                appendLine(line)
            }
        }
        flush()
        return result
    }
}
