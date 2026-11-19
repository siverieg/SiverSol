import Foundation

/// A made-up day of events, the same every time. The design review, previews and tests use it so pictures and
/// examples never contain anything from a real session. Nothing here is ever sent to Discord.
public enum DemoDay {
    public static let auras = ["Rage", "Ruby", "Glacier", "Wind", "Diaheliotrope", "Starlight", "Poseidon", "Celestial", "Aquatic",
                               "Undead", "Lunar", "Solar", "Galaxy", "Bounded", "Twilight", "Chromatic", "Arcane", "Symphony", "Matrix", "Abyssal Hunter"]

    /// About a day of biomes ending at `end`, with a few rolls, merchants and one rare biome near the end.
    public static func events(endingAt end: Date, hours: Double = 24, session: String = "demo") -> [SiverEvent] {
        var out: [SiverEvent] = []
        var seed: UInt64 = 0x51CE_501D
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double((seed >> 33) % 10_000) / 10_000
        }
        let weather: [(String, Double)] = [("WINDY", 120), ("RAINY", 120), ("SNOWY", 120), ("SAND STORM", 650), ("HELL", 666),
                                          ("STARFALL", 600), ("HEAVEN", 240), ("CORRUPTION", 650), ("NULL", 99), ("PUMPKIN MOON", 147), ("GRAVEYARD", 150)]
        var t = end.addingTimeInterval(-hours * 3600)
        var n = 0
        func id(_ kind: String) -> String { n += 1; return "\(session)|\(Int(t.timeIntervalSince1970))|\(kind)|\(n)" }
        out.append(.serverJoined(ServerJoined(id: id("join"), jobId: "0d3m0000-0000-4000-8000-000000000000", placeId: SiverSol.solsRNGPlaceId, at: t)))
        var previous: BiomeKey?
        var rareDone = false
        while t < end {
            // NORMAL for a while, then one weather biome.
            for (name, length) in [("NORMAL", 240 + next() * 900), weather[Int(next() * Double(weather.count)) % weather.count]] {
                guard t < end else { break }
                var key = name, len = length
                if !rareDone, end.timeIntervalSince(t) < 3 * 3600, name != "NORMAL" { key = "GLITCHED"; len = 164; rareDone = true }
                let ref = BiomeRef(raw: key)
                let startId = id("bs")
                let start = t
                out.append(.biomeStarted(BiomeStarted(id: startId, biome: ref, at: start, observedStart: true, wasRunning: false, serverJobId: "0d3m0000", previous: previous)))
                if next() < 0.16 {
                    let at = start.addingTimeInterval(len * 0.4)
                    out.append(.auraRolled(AuraRolled(id: "\(session)|\(Int(at.timeIntervalSince1970))|roll|\(n)", name: auras[Int(next() * Double(auras.count)) % auras.count], at: at,
                                                      durationS: 8, biome: ref, biomeEventId: startId)))
                }
                if next() < 0.05 {
                    let at = start.addingTimeInterval(len * 0.6)
                    out.append(.merchantArrived(MerchantArrived(id: "\(session)|\(Int(at.timeIntervalSince1970))|m|\(n)", name: next() < 0.5 ? "Mari" : "Jester", at: at, biome: ref,
                                                                biomeEventId: startId, source: "log")))
                }
                t = t.addingTimeInterval(len)
                guard t < end else { break }
                out.append(.biomeEnded(BiomeEnded(id: id("be"), biome: ref, startedAt: start, at: t, startedEventId: startId, startObserved: true,
                                                  reason: .changed, next: nil, serverJobId: "0d3m0000")))
                previous = ref.key
            }
        }
        return out.sorted { $0.at < $1.at }
    }
}
