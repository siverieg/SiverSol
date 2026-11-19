import Foundation

/// What the Biome Island announces.
public enum IslandMode: String, Codable, CaseIterable, Sendable {
    /// The resting island stays by the notch (or under the menu bar) while SiverSol watches, and opens for rares.
    case always
    case raresOnly, everything, off

    /// What a Mac gets when the user never chose: Always Show.
    public static let standard = IslandMode.always
    public static let storageKey = "islandMode"

    public var label: String {
        switch self {
        case .always: return "Always show (resting)"
        case .raresOnly: return "Rares only"
        case .everything: return "Everything"
        case .off: return "Off"
        }
    }

    /// The mode for a stored value. Nothing stored means the user never chose, so they get the standard mode;
    /// anything they picked themselves is kept as it is.
    public static func resolve(stored: String?) -> IslandMode {
        guard let stored, let mode = IslandMode(rawValue: stored) else { return standard }
        return mode
    }
}

/// One thing for the Biome Island to show.
public struct IslandItem: Equatable, Identifiable, Sendable {
    /// `notice` is something about the Mac itself (the battery guard); it is shown in every mode but Off.
    public enum Kind: String, Sendable { case biome, roll, merchant, notice }

    /// The event's id, so the same event is never shown twice.
    public var id: String
    public var kind: Kind
    public var title: String
    public var detail: String
    /// The biome whose colours and weather the island wears.
    public var biome: BiomeKey?
    /// Rare items open the island up for longer; ordinary ones stay a small pill.
    public var rare: Bool
    public var at: Date

    public var seconds: TimeInterval { rare ? 6 : 3.5 }

    public init(id: String, kind: Kind, title: String, detail: String, biome: BiomeKey?, rare: Bool, at: Date) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail; self.biome = biome; self.rare = rare; self.at = at
    }

    /// The island item for an event, or nil for events the island does not announce
    /// (a biome ending, a biome that was already running when SiverSol started, joins and disconnects).
    public static func make(for event: SiverEvent, catalog: BiomeCatalog, auras: AuraCatalog, rareRollOneIn: Int = 1_000_000) -> IslandItem? {
        switch event {
        case .biomeStarted(let e):
            guard !e.wasRunning else { return nil }
            let info = catalog.info(for: e.biome.key)
            let detail = info.durationS.map { "about \(Self.short(TimeInterval($0)))" } ?? (info.isRare ? "rare biome" : "")
            return IslandItem(id: e.id, kind: .biome, title: e.biome.key.value, detail: detail, biome: e.biome.key, rare: info.isRare, at: e.at)
        case .auraRolled(let e):
            let info = auras.info(for: e.name)
            let rare = (info?.chance ?? 0) >= rareRollOneIn
            return IslandItem(id: e.id, kind: .roll, title: "Rolled \(info?.display ?? e.name)", detail: auras.rarityText(for: e.name) == "unknown" ? "" : auras.rarityText(for: e.name),
                              biome: e.biome?.key, rare: rare, at: e.at)
        case .merchantArrived(let e):
            return IslandItem(id: e.id, kind: .merchant, title: "\(e.name) arrived", detail: "merchant", biome: e.biome?.key, rare: false, at: e.at)
        default:
            return nil
        }
    }

    static func short(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s >= 3600 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        if s >= 60 { return s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m \(s % 60)s" }
        return "\(s)s"
    }
}

/// Decides what the Biome Island shows and for how long. Pure logic: the island view asks `tick` a few times a
/// second and draws whatever comes back.
///
/// The rules:
/// - `off` shows nothing; `raresOnly` and `always` announce rare biomes and rare rolls; `everything` announces all.
///   (`always` also keeps the resting island up between announcements; that part is `IslandRules`.)
/// - A rare item goes ahead of ordinary ones and cuts an ordinary one short.
/// - Only the newest ordinary biome waits: by the time an older one had its turn it would be old news.
/// - Ordinary items older than 20 seconds are dropped instead of shown late; rare ones wait up to two minutes.
/// - While the island is held back (Roblox is full screen and the user did not ask for it there), ordinary items
///   are dropped and rare ones wait.
public struct IslandQueue: Sendable {
    public var mode: IslandMode
    public private(set) var waiting: [IslandItem] = []
    public private(set) var showing: IslandItem?
    private var until: Date?
    private var seen: [String] = []

    public static let staleAfter: TimeInterval = 20
    public static let rareStaleAfter: TimeInterval = 120
    public static let capacity = 6

    public init(mode: IslandMode) { self.mode = mode }

    /// Is anything showing or waiting?
    public var isIdle: Bool { showing == nil && waiting.isEmpty }

    public mutating func offer(_ item: IslandItem, now: Date = Date()) {
        guard mode != .off, mode == .everything || item.rare || item.kind == .notice, !seen.contains(item.id) else { return }
        seen.append(item.id)
        if seen.count > 200 { seen.removeFirst(seen.count - 200) }
        if item.rare {
            // After the rare items already waiting, before everything ordinary.
            let index = waiting.firstIndex { !$0.rare } ?? waiting.count
            waiting.insert(item, at: index)
            if let showing, !showing.rare { until = now }
        } else {
            if item.kind == .biome { waiting.removeAll { $0.kind == .biome && !$0.rare } }
            waiting.append(item)
        }
        while waiting.count > Self.capacity {
            if let i = waiting.firstIndex(where: { !$0.rare }) { waiting.remove(at: i) } else { waiting.removeFirst() }
        }
    }

    /// What should be on the island at `now`. `suppressed` holds the island back.
    public mutating func tick(now: Date, suppressed: Bool = false) -> IslandItem? {
        if mode == .off { waiting = []; showing = nil; return nil }
        if suppressed {
            showing = nil
            until = nil
            waiting.removeAll { !$0.rare || now.timeIntervalSince($0.at) > Self.rareStaleAfter }
            return nil
        }
        if let showing, let until, now < until { return showing }
        showing = nil
        while !waiting.isEmpty {
            let next = waiting.removeFirst()
            if now.timeIntervalSince(next.at) > (next.rare ? Self.rareStaleAfter : Self.staleAfter) { continue }
            showing = next
            until = now.addingTimeInterval(next.seconds)
            return next
        }
        return nil
    }

    /// The user closed the island: whatever is showing goes away now.
    public mutating func dismiss(now: Date = Date()) { until = now }
}
