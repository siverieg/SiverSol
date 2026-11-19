import Foundation

/// One stretch of one biome on the Sky Ribbon.
public struct RibbonSegment: Equatable, Identifiable, Sendable {
    public var id: String
    public var biome: BiomeKey
    public var start: Date
    public var end: Date
    public var rare: Bool
    public var seconds: TimeInterval { end.timeIntervalSince(start) }
}

/// Something worth a mark above the ribbon.
public struct RibbonMarker: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case rareBiome, roll, merchant }
    public var id: String
    public var kind: Kind
    public var at: Date
    public var title: String
    public var biome: BiomeKey?
}

/// The last day as a strip of biomes, like a weather radar's timeline. Pure data: the Dashboard draws it and
/// lets the pointer scrub along it.
public struct SkyRibbon: Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var segments: [RibbonSegment]
    public var markers: [RibbonMarker]

    public var seconds: TimeInterval { end.timeIntervalSince(start) }

    /// - Parameters:
    ///   - events: timeline events; anything outside the window is clipped or dropped.
    ///   - end: the right-hand edge (normally now).
    ///   - open: true while SiverSol is watching, so the biome that is on now reaches the right-hand edge.
    public static func build(events: [SiverEvent], end: Date, hours: Double = 24, open: Bool, isRare: (BiomeKey) -> Bool,
                             auraName: (String) -> String = { $0 }) -> SkyRibbon {
        let start = end.addingTimeInterval(-hours * 3600)
        var segments: [RibbonSegment] = []
        var markers: [RibbonMarker] = []
        var current: (id: String, biome: BiomeKey, at: Date)?

        func close(at: Date) {
            guard let c = current else { return }
            current = nil
            let s = max(c.at, start), e = min(at, end)
            guard e > s else { return }
            segments.append(RibbonSegment(id: c.id, biome: c.biome, start: s, end: e, rare: isRare(c.biome)))
        }

        for event in events.sorted(by: { $0.at < $1.at }) where event.at <= end {
            switch event {
            case .biomeStarted(let s):
                close(at: s.at)
                current = (s.id, s.biome.key, s.at)
                if isRare(s.biome.key), s.at >= start {
                    markers.append(RibbonMarker(id: s.id, kind: .rareBiome, at: s.at, title: s.biome.key.value, biome: s.biome.key))
                }
            case .biomeEnded(let e):
                // Only the biome that is open: an "ended" that belongs to something older changes nothing.
                if current?.biome == e.biome.key { close(at: e.at) }
            case .auraRolled(let r) where r.at >= start:
                markers.append(RibbonMarker(id: r.id, kind: .roll, at: r.at, title: "Rolled \(auraName(r.name))", biome: r.biome?.key))
            case .merchantArrived(let m) where m.at >= start:
                markers.append(RibbonMarker(id: m.id, kind: .merchant, at: m.at, title: "\(m.name) arrived", biome: m.biome?.key))
            default:
                break
            }
        }
        if open { close(at: end) }
        return SkyRibbon(start: start, end: end, segments: segments, markers: markers)
    }

    /// Where a moment sits along the ribbon, 0 (a day ago) to 1 (now).
    public func fraction(_ date: Date) -> Double {
        guard seconds > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / seconds))
    }

    public func date(at fraction: Double) -> Date {
        start.addingTimeInterval(min(1, max(0, fraction)) * seconds)
    }

    /// The biome that was on at a moment; nil where nothing was being watched.
    public func segment(at date: Date) -> RibbonSegment? {
        segments.first { $0.start <= date && date < $0.end }
    }

    /// Marks close to a moment, nearest first.
    public func markers(near date: Date, within: TimeInterval) -> [RibbonMarker] {
        markers.filter { abs($0.at.timeIntervalSince(date)) <= within }
            .sorted { abs($0.at.timeIntervalSince(date)) < abs($1.at.timeIntervalSince(date)) }
    }

    /// Seconds of the window during which a biome was known (the rest was not watched).
    public var watchedSeconds: TimeInterval { segments.reduce(0) { $0 + $1.seconds } }
}

/// The numbers on a Session Wrapped card.
public struct SessionWrap: Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var watchedSeconds: Double
    public var biomeSeconds: [String: Double]
    public var biomeCounts: [String: Int]
    /// Rare biomes caught, in the order they came (a biome that came twice is listed twice).
    public var rares: [String]
    public var rolls: Int
    public var rarestRoll: String?
    public var rarestRollChance: Int?
    public var longestNormalSeconds: Double
    public var merchants: Int
    public var macroRuns: Int

    public var duration: Double { end.timeIntervalSince(start) }

    /// The biome the card wears: the last rare one caught, else the weather that took the most time, else NORMAL.
    public var signatureBiome: String {
        if let r = rares.last { return r }
        return biomeSeconds.filter { $0.key != "NORMAL" }.max { $0.value < $1.value }?.key ?? "NORMAL"
    }

    /// The biome mix for the donut: the biggest shares first, the small rest gathered as "OTHER".
    public func mix(top: Int = 5) -> [(key: String, share: Double)] {
        let total = biomeSeconds.values.reduce(0, +)
        guard total > 0 else { return [] }
        let sorted = biomeSeconds.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var out = sorted.prefix(top).map { (key: $0.key, share: $0.value / total) }
        let rest = sorted.dropFirst(top).reduce(0) { $0 + $1.value }
        if rest > 0 { out.append((key: "OTHER", share: rest / total)) }
        return out
    }

    public static func build(events: [SiverEvent], start: Date, end: Date, isRare: (BiomeKey) -> Bool, chance: (String) -> Int?,
                             auraName: (String) -> String = { $0 }, macroRuns: Int = 0) -> SessionWrap {
        let hours = max(0.001, end.timeIntervalSince(start) / 3600)
        let ribbon = SkyRibbon.build(events: events, end: end, hours: hours, open: true, isRare: isRare, auraName: auraName)
        var seconds: [String: Double] = [:], counts: [String: Int] = [:]
        var longestNormal = 0.0
        for s in ribbon.segments {
            seconds[s.biome.value, default: 0] += s.seconds
            counts[s.biome.value, default: 0] += 1
            if s.biome.value == "NORMAL" { longestNormal = max(longestNormal, s.seconds) }
        }
        var rolls = 0, merchants = 0
        var best: (name: String, chance: Int?)?
        for event in events where event.at >= start && event.at <= end {
            switch event {
            case .auraRolled(let r):
                rolls += 1
                let c = chance(r.name)
                if best == nil || (c ?? 0) > (best?.chance ?? 0) { best = (auraName(r.name), c) }
            case .auraEquipped(let e) where !e.initial:
                let c = chance(e.internalName)
                if let c, c > (best?.chance ?? 0) { best = (auraName(e.internalName), c) }
            case .merchantArrived:
                merchants += 1
            default: break
            }
        }
        return SessionWrap(start: start, end: end, watchedSeconds: ribbon.watchedSeconds, biomeSeconds: seconds, biomeCounts: counts,
                           rares: ribbon.markers.filter { $0.kind == .rareBiome }.map(\.title), rolls: rolls, rarestRoll: best?.name, rarestRollChance: best?.chance,
                           longestNormalSeconds: longestNormal, merchants: merchants, macroRuns: macroRuns)
    }
}
