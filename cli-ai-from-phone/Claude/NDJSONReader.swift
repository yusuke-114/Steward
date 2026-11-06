import Foundation

/// 把子进程 stdout 的字节流切成一行一行。
///
/// 关键设计：在**字节**层面按 0x0A 切分，切完再解码 UTF-8。
/// 这样一个多字节字符被 chunk 边界劈开也不会出问题——
/// 半个字符只是留在 buffer 里等下一块，永远不会被单独解码。
struct NDJSONReader {
    private var buffer = Data()

    mutating func feed(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let idx = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<idx]
            if !line.isEmpty { lines.append(Data(line)) }
            // 用 Data(...) 重新起底，避免切片索引偏移累积
            buffer = Data(buffer[buffer.index(after: idx)...])
        }
        return lines
    }
}
