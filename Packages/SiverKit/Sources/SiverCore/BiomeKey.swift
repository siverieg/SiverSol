import Foundation

/// Normalized biome identifier: trimmed, uppercased, inner whitespace collapsed.
/// "Heaven", " heaven " and "HEAVEN" are the same key; "Sand  Storm" becomes "SAND STORM".
public struct BiomeKey: Hashable, Codable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let value: String

    public init(_ raw: String) { value = BiomeKey.normalize(raw) }
    public init(stringLiteral value: String) { self.init(value) }

    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }

    public var description: String { value }
    public var isEmpty: Bool { value.isEmpty }

    public static func normalize(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").uppercased()
    }
}

/// A biome as the game reported it: normalized key plus the original text and image id.
public struct BiomeRef: Codable, Equatable, Hashable, Sendable {
    public let key: BiomeKey
    /// `largeImage.hoverText` exactly as written in the log.
    public let raw: String
    public let assetId: Int64?

    public init(raw: String, assetId: Int64? = nil) {
        self.key = BiomeKey(raw); self.raw = raw; self.assetId = assetId
    }
}
