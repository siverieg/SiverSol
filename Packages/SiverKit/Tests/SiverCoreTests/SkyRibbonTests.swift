import XCTest
@testable import SiverCore

final class SkyRibbonTests: XCTestCase {
    private let end = Date(timeIntervalSince1970: 1_800_000_000)
    private let rare: (BiomeKey) -> Bool = { ["GLITCHED", "DREAMSPACE"].contains($0.value) }

    private func started(_ key: String, hoursAgo: Double) -> SiverEvent {
        .biomeStarted(BiomeStarted(id: "s-\(key)-\(hoursAgo)", biome: BiomeRef(raw: key), at: end.addingTimeInterval(-hoursAgo * 3600), observedStart: true, wasRunning: false, serverJobId: nil, previous: nil))
    }
    private func ended(_ key: String, hoursAgo: Double, startedHoursAgo: Double) -> SiverEvent {
        .biomeEnded(BiomeEnded(id: "e-\(key)-\(hoursAgo)", biome: BiomeRef(raw: key), startedAt: end.addingTimeInterval(-startedHoursAgo * 3600), at: end.addingTimeInterval(-hoursAgo * 3600),
                               startedEventId: "s", startObserved: true, reason: .sessionEnded, next: nil, serverJobId: nil))
    }

    func testSegmentsFollowTheBiomesAndAreClippedToTheDay() {
        let events = [started("NORMAL", hoursAgo: 30), started("RAINY", hoursAgo: 20), started("NORMAL", hoursAgo: 19.5), started("GLITCHED", hoursAgo: 2), started("NORMAL", hoursAgo: 1.9)]
        let ribbon = SkyRibbon.build(events: events, end: end, open: true, isRare: rare)
        XCTAssertEqual(ribbon.segments.map(\.biome.value), ["NORMAL", "RAINY", "NORMAL", "GLITCHED", "NORMAL"])
        XCTAssertEqual(ribbon.segments.first?.start, ribbon.start, "a biome that began before the window starts at the window's edge")
        XCTAssertEqual(ribbon.segments.first?.seconds ?? 0, 4 * 3600, accuracy: 0.5)
        XCTAssertEqual(ribbon.segments.last?.end, end, "while watching, the biome that is on reaches the right-hand edge")
        XCTAssertEqual(ribbon.watchedSeconds, 24 * 3600, accuracy: 0.5)
        XCTAssertEqual(ribbon.segments[3].rare, true)
    }

    func testAGapWhereNothingWasWatchedStaysEmpty() {
        let events = [started("NORMAL", hoursAgo: 10), ended("NORMAL", hoursAgo: 8, startedHoursAgo: 10), started("WINDY", hoursAgo: 3), started("NORMAL", hoursAgo: 2.9)]
        let ribbon = SkyRibbon.build(events: events, end: end, open: false, isRare: rare)
        XCTAssertEqual(ribbon.segments.count, 2, "the last biome is not drawn to the edge when SiverSol is not watching")
        XCTAssertNil(ribbon.segment(at: end.addingTimeInterval(-5 * 3600)), "nothing was watched five hours ago")
        XCTAssertEqual(ribbon.segment(at: end.addingTimeInterval(-9 * 3600))?.biome.value, "NORMAL")
        XCTAssertEqual(ribbon.segment(at: end.addingTimeInterval(-2.95 * 3600))?.biome.value, "WINDY")
    }

    func testMarkersForRaresRollsAndMerchants() {
        let events: [SiverEvent] = [
            started("NORMAL", hoursAgo: 5), started("GLITCHED", hoursAgo: 4), started("NORMAL", hoursAgo: 3.9),
            .auraRolled(AuraRolled(id: "r", name: "Symphony", at: end.addingTimeInterval(-3 * 3600))),
            .merchantArrived(MerchantArrived(id: "m", name: "Mari", at: end.addingTimeInterval(-2 * 3600))),
            .auraRolled(AuraRolled(id: "old", name: "Ruby", at: end.addingTimeInterval(-40 * 3600))),
        ]
        let ribbon = SkyRibbon.build(events: events, end: end, open: true, isRare: rare)
        XCTAssertEqual(ribbon.markers.map(\.kind), [.rareBiome, .roll, .merchant])
        XCTAssertEqual(ribbon.markers.map(\.title), ["GLITCHED", "Rolled Symphony", "Mari arrived"])
        XCTAssertEqual(ribbon.markers(near: end.addingTimeInterval(-3 * 3600 + 120), within: 600).first?.title, "Rolled Symphony")
        XCTAssertTrue(ribbon.markers(near: end.addingTimeInterval(-10 * 3600), within: 600).isEmpty)
    }

    func testScrubbingMapsBothWays() {
        let ribbon = SkyRibbon.build(events: [], end: end, open: false, isRare: rare)
        XCTAssertEqual(ribbon.fraction(end), 1)
        XCTAssertEqual(ribbon.fraction(ribbon.start), 0)
        XCTAssertEqual(ribbon.fraction(end.addingTimeInterval(-6 * 3600)), 0.75, accuracy: 0.0001)
        XCTAssertEqual(ribbon.date(at: 0.75), end.addingTimeInterval(-6 * 3600))
        XCTAssertEqual(ribbon.date(at: 7), end, "a pointer dragged off the end stays at now")
    }

    func testSessionWrap() {
        let start = end.addingTimeInterval(-5 * 3600)
        let events: [SiverEvent] = [
            started("NORMAL", hoursAgo: 5), started("RAINY", hoursAgo: 3), started("NORMAL", hoursAgo: 2.9),
            started("GLITCHED", hoursAgo: 1), started("NORMAL", hoursAgo: 0.95),
            .auraRolled(AuraRolled(id: "r1", name: "Starlight", at: end.addingTimeInterval(-4 * 3600))),
            .auraRolled(AuraRolled(id: "r2", name: "Abyssal Hunter", at: end.addingTimeInterval(-2 * 3600))),
            .merchantArrived(MerchantArrived(id: "m", name: "Mari", at: end.addingTimeInterval(-1.5 * 3600))),
            .auraRolled(AuraRolled(id: "before", name: "Ruby", at: end.addingTimeInterval(-9 * 3600))),
        ]
        let auras = AuraCatalog.bundled()
        let wrap = SessionWrap.build(events: events, start: start, end: end, isRare: rare, chance: { auras.chance(for: $0) }, macroRuns: 3)
        XCTAssertEqual(wrap.duration, 5 * 3600)
        XCTAssertEqual(wrap.watchedSeconds, 5 * 3600, accuracy: 0.5)
        XCTAssertEqual(wrap.rares, ["GLITCHED"])
        XCTAssertEqual(wrap.rolls, 2, "a roll from before the session is not counted")
        XCTAssertEqual(wrap.rarestRoll, "Abyssal Hunter")
        XCTAssertEqual(wrap.rarestRollChance, 400_000_000)
        XCTAssertEqual(wrap.longestNormalSeconds, 2 * 3600, accuracy: 0.5, "the opening two hours of NORMAL")
        XCTAssertEqual(wrap.merchants, 1)
        XCTAssertEqual(wrap.macroRuns, 3)
        XCTAssertEqual(wrap.signatureBiome, "GLITCHED")
        XCTAssertEqual(wrap.mix().first?.key, "NORMAL")
        XCTAssertEqual(wrap.mix().reduce(0) { $0 + $1.share }, 1, accuracy: 0.0001)
        XCTAssertEqual(wrap.biomeCounts["NORMAL"], 3)

        let quiet = SessionWrap.build(events: [started("NORMAL", hoursAgo: 1)], start: end.addingTimeInterval(-3600), end: end, isRare: rare, chance: { _ in nil })
        XCTAssertEqual(quiet.signatureBiome, "NORMAL")
        XCTAssertNil(quiet.rarestRoll)
    }

    func testMixGathersTheSmallRest() {
        var wrap = SessionWrap(start: end, end: end, watchedSeconds: 0, biomeSeconds: [:], biomeCounts: [:], rares: [], rolls: 0, rarestRoll: nil, rarestRollChance: nil,
                               longestNormalSeconds: 0, merchants: 0, macroRuns: 0)
        XCTAssertTrue(wrap.mix().isEmpty)
        wrap.biomeSeconds = ["NORMAL": 600, "RAINY": 100, "WINDY": 90, "SNOWY": 80, "HELL": 70, "NULL": 30, "HEAVEN": 30]
        let mix = wrap.mix(top: 5)
        XCTAssertEqual(mix.map(\.key), ["NORMAL", "RAINY", "WINDY", "SNOWY", "HELL", "OTHER"])
        XCTAssertEqual(mix.last?.share ?? 0, 0.06, accuracy: 0.0001)
    }
}
