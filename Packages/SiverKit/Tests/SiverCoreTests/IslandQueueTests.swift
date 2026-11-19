import XCTest
@testable import SiverCore

final class IslandQueueTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let catalog = try! BiomeCatalog.bundled()
    private let auras = AuraCatalog.bundled()

    private func biome(_ key: String, at offset: TimeInterval, rare: Bool = false) -> IslandItem {
        IslandItem(id: "\(key)-\(offset)", kind: .biome, title: key, detail: "", biome: BiomeKey(key), rare: rare, at: t0.addingTimeInterval(offset))
    }

    func testItemsFromEvents() {
        let started = SiverEvent.biomeStarted(BiomeStarted(id: "a", biome: BiomeRef(raw: "GLITCHED"), at: t0, observedStart: true, wasRunning: false, serverJobId: nil, previous: nil))
        let item = IslandItem.make(for: started, catalog: catalog, auras: auras)
        XCTAssertEqual(item?.title, "GLITCHED")
        XCTAssertEqual(item?.rare, true)
        XCTAssertEqual(item?.seconds, 6)

        let rainy = SiverEvent.biomeStarted(BiomeStarted(id: "b", biome: BiomeRef(raw: "Rainy"), at: t0, observedStart: true, wasRunning: false, serverJobId: nil, previous: nil))
        XCTAssertEqual(IslandItem.make(for: rainy, catalog: catalog, auras: auras)?.detail, "about 2m")
        XCTAssertEqual(IslandItem.make(for: rainy, catalog: catalog, auras: auras)?.rare, false)

        let already = SiverEvent.biomeStarted(BiomeStarted(id: "c", biome: BiomeRef(raw: "Rainy"), at: t0, observedStart: false, wasRunning: true, serverJobId: nil, previous: nil))
        XCTAssertNil(IslandItem.make(for: already, catalog: catalog, auras: auras), "a biome that was already running is not news")

        let ended = SiverEvent.biomeEnded(BiomeEnded(id: "d", biome: BiomeRef(raw: "Rainy"), startedAt: t0, at: t0, startedEventId: "b", startObserved: true, reason: .changed, next: nil, serverJobId: nil))
        XCTAssertNil(IslandItem.make(for: ended, catalog: catalog, auras: auras))

        let roll = SiverEvent.auraRolled(AuraRolled(id: "e", name: "Abyssal Hunter", at: t0))
        let rolled = IslandItem.make(for: roll, catalog: catalog, auras: auras)
        XCTAssertEqual(rolled?.title, "Rolled Abyssal Hunter")
        XCTAssertEqual(rolled?.rare, true, "1 in 400,000,000 is a rare roll")
        let common = SiverEvent.auraRolled(AuraRolled(id: "f", name: "Starlight", at: t0))
        XCTAssertEqual(IslandItem.make(for: common, catalog: catalog, auras: auras)?.rare, false)
    }

    func testOffShowsNothing() {
        var q = IslandQueue(mode: .off)
        q.offer(biome("GLITCHED", at: 0, rare: true), now: t0)
        XCTAssertNil(q.tick(now: t0))
    }

    func testRaresOnlyIgnoresOrdinaryBiomes() {
        var q = IslandQueue(mode: .raresOnly)
        q.offer(biome("RAINY", at: 0), now: t0)
        XCTAssertNil(q.tick(now: t0))
        q.offer(biome("GLITCHED", at: 1, rare: true), now: t0.addingTimeInterval(1))
        XCTAssertEqual(q.tick(now: t0.addingTimeInterval(1))?.title, "GLITCHED")
    }

    func testAnItemStaysForItsTimeThenTheNextOneShows() {
        var q = IslandQueue(mode: .everything)
        q.offer(biome("RAINY", at: 0), now: t0)
        q.offer(IslandItem(id: "m", kind: .merchant, title: "Mari arrived", detail: "", biome: nil, rare: false, at: t0), now: t0)
        XCTAssertEqual(q.tick(now: t0)?.title, "RAINY")
        XCTAssertEqual(q.tick(now: t0.addingTimeInterval(3))?.title, "RAINY")
        XCTAssertEqual(q.tick(now: t0.addingTimeInterval(3.6))?.title, "Mari arrived")
        XCTAssertNil(q.tick(now: t0.addingTimeInterval(8)))
    }

    func testOnlyTheNewestOrdinaryBiomeWaits() {
        var q = IslandQueue(mode: .everything)
        q.offer(biome("GLITCHED", at: 0, rare: true), now: t0)
        _ = q.tick(now: t0)
        q.offer(biome("RAINY", at: 1), now: t0)
        q.offer(biome("WINDY", at: 2), now: t0)
        q.offer(biome("SNOWY", at: 3), now: t0)
        XCTAssertEqual(q.waiting.map(\.title), ["SNOWY"])
    }

    func testARareItemCutsAnOrdinaryOneShortAndGoesFirst() {
        var q = IslandQueue(mode: .everything)
        q.offer(biome("RAINY", at: 0), now: t0)
        XCTAssertEqual(q.tick(now: t0)?.title, "RAINY")
        q.offer(IslandItem(id: "m", kind: .merchant, title: "Mari arrived", detail: "", biome: nil, rare: false, at: t0), now: t0)
        q.offer(biome("GLITCHED", at: 1, rare: true), now: t0.addingTimeInterval(1))
        XCTAssertEqual(q.tick(now: t0.addingTimeInterval(1.1))?.title, "GLITCHED", "the rare biome does not wait for the ordinary one")
        XCTAssertEqual(q.tick(now: t0.addingTimeInterval(6.9))?.title, "GLITCHED", "and stays for about six seconds")
        XCTAssertEqual(q.tick(now: t0.addingTimeInterval(7.2))?.title, "Mari arrived")
    }

    func testTheSameEventIsNeverShownTwice() {
        var q = IslandQueue(mode: .everything)
        let item = biome("RAINY", at: 0)
        q.offer(item, now: t0)
        _ = q.tick(now: t0)
        q.offer(item, now: t0.addingTimeInterval(5))
        XCTAssertNil(q.tick(now: t0.addingTimeInterval(5)))
    }

    func testOldNewsIsDropped() {
        var q = IslandQueue(mode: .everything)
        q.offer(biome("RAINY", at: 0), now: t0)
        XCTAssertNil(q.tick(now: t0.addingTimeInterval(30)), "an ordinary biome from half a minute ago is not shown late")
        q.offer(biome("GLITCHED", at: 0, rare: true), now: t0)
        XCTAssertEqual(q.tick(now: t0.addingTimeInterval(90))?.title, "GLITCHED", "a rare biome still is")
    }

    func testHeldBackWhileRobloxIsFullScreen() {
        var q = IslandQueue(mode: .everything)
        q.offer(biome("RAINY", at: 0), now: t0)
        q.offer(biome("GLITCHED", at: 0, rare: true), now: t0)
        XCTAssertNil(q.tick(now: t0, suppressed: true))
        XCTAssertEqual(q.waiting.map(\.title), ["GLITCHED"], "ordinary items are dropped, rare ones wait")
        XCTAssertEqual(q.tick(now: t0.addingTimeInterval(10))?.title, "GLITCHED")
    }

    func testCapacity() {
        var q = IslandQueue(mode: .everything)
        for i in 0..<12 {
            q.offer(IslandItem(id: "m\(i)", kind: .merchant, title: "m\(i)", detail: "", biome: nil, rare: false, at: t0), now: t0)
        }
        XCTAssertEqual(q.waiting.count, IslandQueue.capacity)
        XCTAssertEqual(q.waiting.last?.title, "m11", "the newest are kept")
    }

    func testDismiss() {
        var q = IslandQueue(mode: .everything)
        q.offer(biome("GLITCHED", at: 0, rare: true), now: t0)
        _ = q.tick(now: t0)
        q.dismiss(now: t0.addingTimeInterval(1))
        XCTAssertNil(q.tick(now: t0.addingTimeInterval(1.1)))
    }
}
