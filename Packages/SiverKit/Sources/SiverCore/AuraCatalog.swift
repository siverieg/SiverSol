import Foundation

public struct AuraInfo: Codable, Equatable, Sendable {
    public var display: String
    public var tier: String?
    /// 1 in `chance`.
    public var chance: Int?
    public var nativeChance: Int?
    public var nativeBiome: String?
    public var onlyIn: String?
    public var note: String?
}

/// F5: internal aura name -> display name, rarity, native biome. Data: Sol's RNG Wiki (CC BY-SA), see auras.json.
public final class AuraCatalog: Sendable {
    private struct File: Codable { var auras: [String: AuraInfo] }
    private let auras: [String: AuraInfo]

    public init(auras: [String: AuraInfo]) { self.auras = auras }

    public static func bundled() -> AuraCatalog {
        guard let url = Bundle.module.url(forResource: "auras", withExtension: "json"),
              let file = try? JSONDecoder().decode(File.self, from: Data(contentsOf: url)) else { return AuraCatalog(auras: [:]) }
        return AuraCatalog(auras: file.auras)
    }

    public var count: Int { auras.count }

    /// Every entry with its key (the name reduced to letters and digits).
    public var entries: [(key: String, info: AuraInfo)] { auras.map { ($0.key, $0.value) } }

    /// Every aura in the catalog, rarest first (unknown odds last), then by name.
    public var all: [AuraInfo] {
        auras.values.sorted {
            let a = $0.chance ?? -1, b = $1.chance ?? -1
            return a != b ? a > b : $0.display.localizedCaseInsensitiveCompare($1.display) == .orderedAscending
        }
    }

    /// Lowercase letters and digits only, so `SeekerOfTheCrimsonMoon`, `:Flushed:_Pumpkinity` and the wiki's
    /// "Flushed : Pumpkinity" all land on the same key.
    public static func key(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    public func info(for internalName: String) -> AuraInfo? { auras[Self.key(internalName)] }

    /// Catalog name when known, else the internal name split into words.
    public func display(for internalName: String) -> String {
        info(for: internalName)?.display ?? AuraName.display(internalName)
    }

    /// 445000 -> "445,000". Done by hand so it never follows the Mac's regional number format.
    public static func grouped(_ n: Int) -> String {
        let digits = Array(String(abs(n)))
        var out = ""
        for (i, d) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(d)
        }
        return (n < 0 ? "-" : "") + out
    }

    /// "1 in 445,000 · Event", or "unknown" when the catalog has no entry.
    public func rarityText(for internalName: String) -> String {
        guard let info = info(for: internalName) else { return "unknown" }
        var parts: [String] = []
        if let c = info.chance { parts.append("1 in \(Self.grouped(c))") }
        if let t = info.tier { parts.append(t) }
        return parts.isEmpty ? "unknown" : parts.joined(separator: " · ")
    }

    private static func biomeKey(_ s: String) -> String { key(s) }

    /// The easier odds, when the current biome is this aura's native biome ("SAND STORM" matches the wiki's "SANDSTORM").
    public func nativeBoost(for internalName: String, in biome: BiomeKey?) -> String? {
        guard let biome, let info = info(for: internalName), let native = info.nativeBiome,
              Self.biomeKey(native) == Self.biomeKey(biome.value) else { return nil }
        return info.nativeChance.map { "native biome: 1 in \(Self.grouped($0)) here" } ?? "native biome"
    }

    /// Rarity for thresholds (proof shots). nil when unknown.
    public func chance(for internalName: String) -> Int? { info(for: internalName)?.chance }
}
