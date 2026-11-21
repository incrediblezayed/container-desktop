import Foundation

/// Severity guessed from a log line's text, for colouring and the "errors only" filter.
public enum LogLevel: Int, Comparable, Sendable, CaseIterable {
    case trace, debug, info, warning, error

    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }

    /// Looks for a level the way people write them: `ERROR`, `[warn]`, `level=error`,
    /// `"level":"warn"`, `E1121`-style glog prefixes are ignored to avoid false positives.
    /// Returns nil when the line names no level.
    public static func detect(in text: String) -> LogLevel? {
        // Only the start of a line usually carries the level; scanning all of it would flag
        // messages that merely mention "error".
        let head = text.prefix(160)
        var best: LogLevel?
        var bestIndex = head.endIndex
        for (token, level) in tokens {
            var searchStart = head.startIndex
            while let range = head.range(of: token, options: [.caseInsensitive], range: searchStart..<head.endIndex) {
                if isBoundary(head, before: range.lowerBound), isBoundary(head, after: range.upperBound),
                   range.lowerBound < bestIndex {
                    best = level
                    bestIndex = range.lowerBound
                    break
                }
                searchStart = range.upperBound
            }
        }
        return best
    }

    private static let tokens: [(String, LogLevel)] = [
        ("fatal", .error), ("panic", .error), ("critical", .error), ("crit", .error),
        ("error", .error), ("err", .error), ("eror", .error),
        ("warning", .warning), ("warn", .warning), ("wrn", .warning),
        ("info", .info), ("inf", .info), ("notice", .info),
        ("debug", .debug), ("dbg", .debug), ("trace", .trace), ("trc", .trace),
        ("log", .info), // postgres: "LOG:  database system is ready"
    ]

    private static func isBoundary(_ s: Substring, before i: Substring.Index) -> Bool {
        guard i > s.startIndex else { return true }
        return !isWordCharacter(s[s.index(before: i)])
    }

    private static func isBoundary(_ s: Substring, after i: Substring.Index) -> Bool {
        guard i < s.endIndex else { return true }
        return !isWordCharacter(s[i])
    }

    private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
}

/// A terminal colour from an SGR escape sequence.
public enum ANSIColor: Hashable, Sendable {
    /// 0–7 normal, 8–15 bright.
    case palette(Int)
    /// 16–255 from the xterm 256-colour table.
    case extended(Int)
    case rgb(UInt8, UInt8, UInt8)
}

public struct ANSIStyle: Hashable, Sendable {
    public var foreground: ANSIColor?
    public var bold = false
    public var dim = false
    public var italic = false
    public var underline = false

    public init() {}
    public var isPlain: Bool { self == ANSIStyle() }
}

/// One line of container output with escape codes removed and their styling kept.
public struct LogLine: Identifiable, Hashable, Sendable {
    public struct Run: Hashable, Sendable {
        public var text: String
        public var style: ANSIStyle
    }

    public let id: Int
    /// The container (service) that wrote the line, when showing several at once.
    public let source: String?
    public let text: String
    public let runs: [Run]
    public let level: LogLevel?

    public init(id: Int, source: String? = nil, raw: String) {
        self.id = id
        self.source = source
        let runs = ANSIParser.parse(raw)
        self.runs = runs
        self.text = runs.map(\.text).joined()
        self.level = LogLevel.detect(in: text)
    }
}

public enum ANSIParser {
    /// Splits `raw` into styled runs. Handles SGR (`ESC[…m`); drops every other CSI
    /// sequence (cursor movement, erase) and OSC sequences such as terminal titles and links.
    public static func parse(_ raw: String) -> [LogLine.Run] {
        guard raw.contains("\u{1B}") else {
            return [LogLine.Run(text: raw.replacingOccurrences(of: "\r", with: ""), style: ANSIStyle())]
        }
        var runs: [LogLine.Run] = []
        var style = ANSIStyle()
        var current = ""
        let scalars = Array(raw.unicodeScalars)
        var i = 0

        func flush() {
            if !current.isEmpty { runs.append(LogLine.Run(text: current, style: style)); current = "" }
        }

        while i < scalars.count {
            let c = scalars[i]
            if c == "\u{1B}", i + 1 < scalars.count {
                let next = scalars[i + 1]
                if next == "[" {
                    // CSI: parameters, then a final byte in 0x40–0x7E.
                    var j = i + 2
                    var params = ""
                    while j < scalars.count, !(0x40...0x7E).contains(scalars[j].value) {
                        params.unicodeScalars.append(scalars[j]); j += 1
                    }
                    if j < scalars.count, scalars[j] == "m" {
                        flush()
                        apply(params, to: &style)
                    }
                    i = j + 1
                    continue
                }
                if next == "]" {
                    // OSC: ends with BEL or ESC \.
                    var j = i + 2
                    while j < scalars.count {
                        if scalars[j] == "\u{07}" { j += 1; break }
                        if scalars[j] == "\u{1B}", j + 1 < scalars.count, scalars[j + 1] == "\\" { j += 2; break }
                        j += 1
                    }
                    i = j
                    continue
                }
                i += 2 // other two-byte escape
                continue
            }
            if c != "\r" { current.unicodeScalars.append(c) }
            i += 1
        }
        flush()
        return runs.isEmpty ? [LogLine.Run(text: "", style: ANSIStyle())] : runs
    }

    static func apply(_ params: String, to style: inout ANSIStyle) {
        let codes = params.isEmpty ? [0] : params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var k = 0
        while k < codes.count {
            let code = codes[k]
            switch code {
            case 0: style = ANSIStyle()
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 30...37: style.foreground = .palette(code - 30)
            case 90...97: style.foreground = .palette(code - 90 + 8)
            case 39: style.foreground = nil
            case 38:
                if k + 2 < codes.count, codes[k + 1] == 5 {
                    let n = codes[k + 2]
                    style.foreground = n < 16 ? .palette(n) : .extended(min(n, 255))
                    k += 2
                } else if k + 4 < codes.count, codes[k + 1] == 2 {
                    style.foreground = .rgb(UInt8(clamping: codes[k + 2]), UInt8(clamping: codes[k + 3]), UInt8(clamping: codes[k + 4]))
                    k += 4
                }
            case 48:
                // Backgrounds are ignored, but their arguments must be skipped.
                if k + 1 < codes.count { k += codes[k + 1] == 5 ? 2 : (codes[k + 1] == 2 ? 4 : 0) }
            default: break
            }
            k += 1
        }
    }
}
