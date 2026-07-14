import Foundation

public enum LogTailParser {
    public static func lines(from data: Data, limit: Int) -> [String] {
        guard limit > 0 else { return [] }

        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }
        lines = lines.map { line in
            line.last == "\r" ? String(line.dropLast()) : line
        }
        return Array(lines.suffix(limit))
    }
}
