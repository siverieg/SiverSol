import Foundation

public enum BiomeCategory: String, Codable, Sendable {
    case normal, weather, rare, event, unknown
}

public struct BiomeInfo: Codable, Equatable, Sendable {
    public var key: BiomeKey
    public var display: String
    public var emoji: String
    /// Hex RGB, e.g. "#64FFD0".
    public var color: String
    public var category: BiomeCategory
    public var durationS: Int?
    public var durationSource: String?
    public var rarity: String?
    public var thumbnail: String?
    public var firstSeen: Date?
    public var assetId: Int64?
    /// The Living Sky palette (hex RGB): the sky by day, an accent, and the colour of what falls or drifts.
    public var skyTop: String?
    public var skyBottom: String?
    public var accent: String?
    public var particle: String?
    /// One of `SkyWeather`'s names.
    public var weather: String?
    /// 0 to 1: how much this biome takes over the time-of-day sky.
    public var skyBlend: Double?
    /// SF Symbol shown for this biome in the app. Biomes without one get a drawn glyph or a default.
    public var symbol: String?

    public init(key: BiomeKey, display: String, emoji: String, color: String, category: BiomeCategory,
                durationS: Int? = nil, durationSource: String? = nil, rarity: String? = nil,
                thumbnail: String? = nil, firstSeen: Date? = nil, assetId: Int64? = nil) {
        self.key = key; self.display = display; self.emoji = emoji; self.color = color; self.category = category
        self.durationS = durationS; self.durationSource = durationSource; self.rarity = rarity
        self.thumbnail = thumbnail; self.firstSeen = firstSeen; self.assetId = assetId
    }

    /// Discord embed color (decimal RGB).
    public var colorValue: Int { Int(color.dropFirst(color.hasPrefix("#") ? 1 : 0), radix: 16) ?? 0x99AAB5 }
    public var isRare: Bool { category == .rare }
}

/// Built-in `biomes.json` plus biomes learned at runtime. Thread-safe.
public final class BiomeCatalog: @unchecked Sendable {
    private struct File: Codable { var biomes: [BiomeInfo] }

    private let lock = NSLock()
    private var builtIn: [BiomeKey: BiomeInfo]
    private var learned: [BiomeKey: BiomeInfo] = [:]
    private let learnedURL: URL?

    public init(builtIn: [BiomeInfo], learnedURL: URL? = nil) {
        self.builtIn = Dictionary(builtIn.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        self.learnedURL = learnedURL
        if let learnedURL, let data = try? Data(contentsOf: learnedURL),
           let file = try? Self.decoder.decode(File.self, from: data) {
            learned = Dictionary(file.biomes.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// The catalog shipped inside SiverCore. `learnedURL` is where newly seen biomes are saved.
    public static func bundled(learnedURL: URL? = nil) throws -> BiomeCatalog {
        guard let url = Bundle.module.url(forResource: "biomes", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let file = try decoder.decode(File.self, from: Data(contentsOf: url))
        return BiomeCatalog(builtIn: file.biomes, learnedURL: learnedURL)
    }

    public static var defaultLearnedURL: URL { SiverSol.supportDirectory.appendingPathComponent("learned_biomes.json") }

    public func isKnown(_ key: BiomeKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return builtIn[key] != nil || learned[key] != nil
    }

    /// Catalog entry, or a neutral stand-in for a biome nobody has described yet.
    public func info(for key: BiomeKey) -> BiomeInfo {
        lock.lock(); defer { lock.unlock() }
        return builtIn[key] ?? learned[key] ?? Self.placeholder(key: key, raw: key.value, assetId: nil, at: nil)
    }

    public func isRare(_ key: BiomeKey) -> Bool { info(for: key).isRare }

    public var all: [BiomeInfo] {
        lock.lock(); defer { lock.unlock() }
        return (Array(builtIn.values) + Array(learned.values)).sorted { $0.key.value < $1.key.value }
    }

    public var learnedBiomes: [BiomeInfo] {
        lock.lock(); defer { lock.unlock() }
        return learned.values.sorted { $0.key.value < $1.key.value }
    }

    /// Record a biome we have never seen. Returns true only the first time.
    @discardableResult
    public func learn(_ biome: BiomeRef, at: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard builtIn[biome.key] == nil, learned[biome.key] == nil else { return false }
        learned[biome.key] = Self.placeholder(key: biome.key, raw: biome.raw, assetId: biome.assetId, at: at)
        if let learnedURL {
            let file = File(biomes: learned.values.sorted { $0.key.value < $1.key.value })
            if let data = try? Self.encoder.encode(file) {
                try? FileManager.default.createDirectory(at: learnedURL.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? data.write(to: learnedURL, options: .atomic)
            }
        }
        return true
    }

    static func placeholder(key: BiomeKey, raw: String, assetId: Int64?, at: Date?) -> BiomeInfo {
        BiomeInfo(key: key, display: raw.trimmingCharacters(in: .whitespaces).capitalized, emoji: "🆕",
                  color: "#99AAB5", category: .unknown, firstSeen: at, assetId: assetId)
    }

    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
}
