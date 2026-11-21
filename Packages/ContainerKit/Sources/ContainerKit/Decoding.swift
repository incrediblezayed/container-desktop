import Foundation

/// Decoding helpers that keep the app working across `container` CLI releases.
///
/// The CLI's JSON is the contract we depend on, but it is not versioned. Every
/// model in ContainerKit therefore decodes only the fields it needs, treats them
/// as optional where possible, and tolerates type drift (for example an IP
/// address encoded as a string in one release and an object in another).
enum CLIJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                // Foundation's default (`deferredToDate`) encodes seconds since 2001.
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            let text = try container.decode(String.self)
            if let date = parseISO8601(text) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unrecognised date: \(text)")
        }
        return decoder
    }

    static func parseISO8601(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    /// The CLI prints one JSON document, but may emit log lines or warnings
    /// first. Find the first `[` or `{` that starts a valid document.
    static func extractDocument(from data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") { return Data(trimmed.utf8) }
        for line in trimmed.split(separator: "\n", omittingEmptySubsequences: true) {
            let candidate = line.trimmingCharacters(in: .whitespaces)
            if candidate.hasPrefix("[") || candidate.hasPrefix("{") {
                if let start = trimmed.range(of: candidate) {
                    return Data(trimmed[start.lowerBound...].utf8)
                }
            }
        }
        return Data(trimmed.utf8)
    }
}

/// A value that may arrive as a string, number, bool or object, rendered as text.
/// Used for address-like fields whose encoding lives in Apple's Containerization
/// package and may change shape between releases.
public struct LooseString: Codable, Sendable, Hashable, CustomStringConvertible {
    public let value: String
    public var description: String { value }

    public init(_ value: String) { self.value = value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int64.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            value = String(double)
        } else if let bool = try? container.decode(Bool.self) {
            value = String(bool)
        } else if let object = try? container.decode([String: LooseString].self) {
            // e.g. {"address": "192.168.64.2", "prefix": 24}
            if let address = object["address"]?.value {
                value = object["prefix"].map { "\(address)/\($0.value)" } ?? address
            } else {
                value = object.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            }
        } else {
            value = ""
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

extension KeyedDecodingContainer {
    /// Decode an optional value, swallowing type mismatches instead of failing the whole document.
    func lenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}
