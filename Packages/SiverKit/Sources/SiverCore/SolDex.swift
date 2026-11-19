import Foundation

/// The game's own tier names, in the order the game ranks them, with the special groups after.
public enum DexTier: String, CaseIterable, Codable, Sendable, Comparable {
    case basic = "Basic", epic = "Epic", unique = "Unique", legendary = "Legendary", mythic = "Mythic", exalted = "Exalted"
    case glorious = "Glorious", transcendent = "Transcendent", dimensional = "Dimensional"
    case challenged = "Challenged", event = "Event"
    /// Auras nobody can roll (developer-only and the like). Shown, but not counted towards completion.
    case unobtainable = "Unobtainable"
    case unknown = "Unknown"

    /// The catalog writes tiers as the wiki does ("Challenged+", "Glorious"); unknown words land in `unknown`.
    public init(catalog name: String?) {
        let cleaned = (name ?? "").trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "+")).lowercased()
        self = DexTier.allCases.first { $0.rawValue.lowercased() == cleaned } ?? .unknown
    }

    public var order: Int { DexTier.allCases.firstIndex(of: self) ?? 0 }
    public static func < (a: DexTier, b: DexTier) -> Bool { a.order < b.order }

    /// Counted towards "collected so far"?
    public var collectable: Bool { self != .unobtainable && self != .unknown }
}

/// How much a card shines. It climbs with the tier: matte, satin sheen, shimmer, holographic bands, glitter,
/// and an animated prismatic foil that follows the pointer for Glorious and up.
public enum FoilLevel: Int, CaseIterable, Sendable, Comparable {
    case matte = 0, satin, shimmer, holographic, glitter, prismatic

    public static func < (a: FoilLevel, b: FoilLevel) -> Bool { a.rawValue < b.rawValue }

    /// The foil for a tier. Event and Challenged auras span the whole range of odds, so theirs follows the odds.
    public static func of(tier: DexTier, chance: Int?) -> FoilLevel {
        switch tier {
        case .basic: return .matte
        case .epic: return .satin
        case .unique: return .shimmer
        case .legendary, .mythic: return .holographic
        case .exalted: return .glitter
        case .glorious, .transcendent, .dimensional: return .prismatic
        case .challenged, .event, .unobtainable, .unknown:
            guard let chance else { return tier == .unobtainable ? .glitter : .matte }
            switch chance {
            case ..<10_000: return .matte
            case ..<100_000: return .satin
            case ..<1_000_000: return .shimmer
            case ..<10_000_000: return .holographic
            case ..<100_000_000: return .glitter
            default: return .prismatic
            }
        }
    }

    public var name: String {
        switch self {
        case .matte: return "matte"
        case .satin: return "satin sheen"
        case .shimmer: return "shimmer"
        case .holographic: return "holographic bands"
        case .glitter: return "glitter"
        case .prismatic: return "prismatic"
        }
    }
}

/// One card in the Sol Dex: a catalog aura, and what this Mac has seen of it.
public struct DexCard: Equatable, Identifiable, Sendable {
    /// The catalog key (letters and digits of the name).
    public var id: String
    public var display: String
    public var tier: DexTier
    /// The tier exactly as the catalog writes it ("Challenged+").
    public var tierLabel: String
    public var chance: Int?
    public var nativeBiome: String?
    public var onlyIn: String?
    public var note: String?
    public var foil: FoilLevel

    // What was seen. All empty for an aura that has not turned up yet.
    public var firstSeen: Date?
    public var lastSeen: Date?
    /// Times it was rolled or newly equipped (the aura the game restores on join counts once, as "owned").
    public var count = 0
    /// The biome it first came in.
    public var biome: String?

    public var seen: Bool { firstSeen != nil }
    public var odds: String { chance.map { "1 in \(AuraCatalog.grouped($0))" } ?? "odds unknown" }
}

/// The collection: every catalog aura as a card, lit up by what the timeline has seen.
public struct SolDex: Equatable, Sendable {
    public var cards: [DexCard]

    public var seen: [DexCard] { cards.filter(\.seen) }
    /// Cards that count towards completion (everything a player can roll).
    public var collectable: [DexCard] { cards.filter { $0.tier.collectable } }
    public var collected: Int { collectable.filter(\.seen).count }
    public var completion: Double { collectable.isEmpty ? 0 : Double(collected) / Double(collectable.count) }

    /// The rarest aura seen so far (by odds), for the spotlight.
    public var rarest: DexCard? {
        seen.filter { $0.chance != nil }.max { ($0.chance ?? 0) != ($1.chance ?? 0) ? ($0.chance ?? 0) < ($1.chance ?? 0) : ($0.firstSeen ?? .distantPast) > ($1.firstSeen ?? .distantPast) }
    }

    /// Seen and total per tier, in tier order, for the completion meter.
    public var byTier: [(tier: DexTier, seen: Int, total: Int)] {
        DexTier.allCases.compactMap { tier in
            let all = cards.filter { $0.tier == tier }
            return all.isEmpty ? nil : (tier, all.filter(\.seen).count, all.count)
        }
    }

    /// Build the collection from the catalog and every recorded event.
    /// An aura the catalog does not know still gets a card (tier Unknown), so nothing rolled is ever lost.
    public static func build(catalog: AuraCatalog, events: [SiverEvent]) -> SolDex {
        struct Seen { var first: Date; var last: Date; var count: Int; var biome: String?; var name: String }
        var seen: [String: Seen] = [:]
        func note(_ name: String, at: Date, biome: String?, counts: Bool) {
            let key = AuraCatalog.key(name)
            guard !key.isEmpty else { return }
            if var s = seen[key] {
                if at < s.first { s.first = at; s.biome = biome ?? s.biome }
                s.last = max(s.last, at)
                if counts { s.count += 1 }
                seen[key] = s
            } else {
                seen[key] = Seen(first: at, last: at, count: 1, biome: biome, name: name)
            }
        }
        // A roll is followed by the equip line for the same aura; count that pair once.
        var lastRoll: [String: Date] = [:]
        for event in events.sorted(by: { $0.at < $1.at }) {
            switch event {
            case .auraRolled(let r):
                note(r.name, at: r.at, biome: r.biome?.key.value, counts: true)
                lastRoll[AuraCatalog.key(r.name)] = r.at
            case .auraEquipped(let e):
                let key = AuraCatalog.key(e.internalName)
                let afterRoll = lastRoll[key].map { e.at.timeIntervalSince($0) < 300 && e.at >= $0 } ?? false
                note(e.internalName, at: e.at, biome: e.biome?.key.value, counts: !e.initial && !afterRoll)
            default: break
            }
        }
        var cards: [DexCard] = catalog.entries.map { key, info in
            let tier = DexTier(catalog: info.tier)
            var card = DexCard(id: key, display: info.display, tier: tier, tierLabel: info.tier ?? "Unknown", chance: info.chance, nativeBiome: info.nativeBiome,
                               onlyIn: info.onlyIn, note: info.note, foil: FoilLevel.of(tier: tier, chance: info.chance))
            if let s = seen.removeValue(forKey: key) {
                card.firstSeen = s.first; card.lastSeen = s.last; card.count = s.count; card.biome = s.biome
            }
            return card
        }
        for (key, s) in seen {
            cards.append(DexCard(id: key, display: AuraName.display(s.name), tier: .unknown, tierLabel: "Not in the catalog", chance: nil, nativeBiome: nil, onlyIn: nil,
                                 note: nil, foil: .matte, firstSeen: s.first, lastSeen: s.last, count: s.count, biome: s.biome))
        }
        // Rarest first within a tier; cards with unknown odds last.
        cards.sort {
            if $0.tier != $1.tier { return $0.tier < $1.tier }
            let a = $0.chance ?? -1, b = $1.chance ?? -1
            return a != b ? a > b : $0.display.localizedCaseInsensitiveCompare($1.display) == .orderedAscending
        }
        return SolDex(cards: cards)
    }

    public static func == (a: SolDex, b: SolDex) -> Bool { a.cards == b.cards }

    /// A number from the card's name that never changes: it picks the emblem and the foil pattern for that aura.
    public static func seed(_ id: String) -> UInt32 {
        var h: UInt32 = 2166136261
        for b in id.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return h
    }
}
