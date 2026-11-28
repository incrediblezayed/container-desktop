import Foundation

/// The filter field's text, as plain text or a regular expression (case-insensitive).
public struct LogMatcher: Sendable {
    let regex: NSRegularExpression?
    public let text: String

    /// Nil when there's nothing to filter by. Throws for an invalid pattern.
    public static func make(_ text: String, regex: Bool) throws -> LogMatcher? {
        guard !text.isEmpty else { return nil }
        guard regex else { return LogMatcher(regex: nil, text: text) }
        return LogMatcher(regex: try NSRegularExpression(pattern: text, options: [.caseInsensitive]), text: text)
    }

    public func matches(_ line: String) -> Bool {
        guard let regex else { return line.localizedCaseInsensitiveContains(text) }
        return regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// Character offsets of each match, for highlighting.
    public func ranges(in line: String) -> [Range<Int>] {
        var result: [Range<Int>] = []
        if let regex {
            for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) where match.range.length > 0 {
                guard let r = Range(match.range, in: line) else { continue }
                let start = line.distance(from: line.startIndex, to: r.lowerBound)
                result.append(start..<(start + line.distance(from: r.lowerBound, to: r.upperBound)))
            }
        } else {
            var from = line.startIndex
            while let r = line.range(of: text, options: .caseInsensitive, range: from..<line.endIndex) {
                let start = line.distance(from: line.startIndex, to: r.lowerBound)
                result.append(start..<(start + line.distance(from: r.lowerBound, to: r.upperBound)))
                from = r.upperBound
            }
        }
        return result
    }
}
