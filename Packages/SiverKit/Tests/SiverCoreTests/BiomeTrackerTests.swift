import XCTest
@testable import SiverCore

final class BiomeTrackerTests: XCTestCase {
    func testTransitionEmitsEndedThenStarted() {
        let (events, tracker) = track([
            joinLine("2026-11-18T10:00:00.000Z"),
            rpc("2026-11-18T10:00:10.000Z", "NORMAL"),
            rpc("2026-11-18T10:05:00.000Z", "WINDY"),
            rpc("2026-11-18T10:07:00.000Z", "NORMAL"),
        ])
        XCTAssertEqual(events.startKeys, ["NORMAL", "WINDY", "NORMAL"])
        let ends = events.ends
        XCTAssertEqual(ends.map(\.biome.key.value), ["NORMAL", "WINDY"])
        XCTAssertEqual(ends[1].duration, 120, accuracy: 0.001)
        XCTAssertEqual(ends[1].reason, .changed)
        XCTAssertEqual(ends[1].next, "NORMAL")
        // Ended links back to its Started.
        XCTAssertEqual(ends[1].startedEventId, events.starts[1].id)
        // Order inside one transition: ended first, then started.
        let idxEnd = events.firstIndex { if case .biomeEnded(let e) = $0 { return e.biome.key == "WINDY" }; return false }!
        let idxStart = events.lastIndex { if case .biomeStarted = $0 { return true }; return false }!
        XCTAssertLessThan(idxEnd, idxStart)
        XCTAssertEqual(tracker.current?.biome.key, "NORMAL")
    }

    func testRepeatedLinesEmitNothing() {
        // The game re-sends identical lines, often several in the same millisecond.
        let (events, _) = track([
            rpc("2026-11-18T10:00:10.000Z", "PUMPKIN MOON"),
            rpc("2026-11-18T10:00:10.000Z", "PUMPKIN MOON"),
            rpc("2026-11-18T10:00:10.000Z", "PUMPKIN MOON"),
            rpc("2026-11-18T10:00:40.000Z", "PUMPKIN MOON"),
            rpc("2026-11-18T10:00:40.000Z", "pumpkin  moon"),
        ])
        XCTAssertEqual(events.startKeys, ["PUMPKIN MOON"])
        XCTAssertTrue(events.ends.isEmpty)
        XCTAssertEqual(events.auras.count, 1)
    }

    func testFirstBiomeAfterJoinIsNotAnObservedStart() {
        let (events, _) = track([
            joinLine("2026-11-18T10:00:00.000Z"),
            rpc("2026-11-18T10:00:10.000Z", "STARFALL"),
            rpc("2026-11-18T10:03:00.000Z", "NORMAL"),
        ])
        XCTAssertFalse(events.starts[0].observedStart)
        XCTAssertTrue(events.starts[1].observedStart)
        XCTAssertFalse(events.ends[0].startObserved)
        XCTAssertFalse(events.starts[0].wasRunning)
    }

    func testMainMenuBiomeIsIgnoredUntilInGame() {
        let (events, tracker) = track([
            joinLine("2026-11-18T10:00:00.000Z"),
            rpc("2026-11-18T10:00:02.000Z", "NORMAL", state: "In Main Menu"),
            rpc("2026-11-18T10:00:04.000Z", "NORMAL", state: "In Main Menu"),
        ])
        XCTAssertTrue(events.starts.isEmpty)
        XCTAssertEqual(tracker.phase, .menu)
        XCTAssertNil(tracker.current)
    }

    func testAuraOnlyOnChangeAndInitialFlag() {
        let (events, tracker) = track([
            joinLine("2026-11-18T10:00:00.000Z"),
            rpc("2026-11-18T10:00:20.000Z", "NORMAL", state: "Equipped _None_"),
            rpc("2026-11-18T10:00:20.200Z", "NORMAL", state: "Equipped \\\"SeekerOfTheCrimsonMoon\\\""),
            rpc("2026-11-18T10:02:00.000Z", "WINDY", state: "Equipped \\\"SeekerOfTheCrimsonMoon\\\""),
            rpc("2026-11-18T10:03:00.000Z", "WINDY", state: "Equipped \\\"Enchanted\\\""),
            rpc("2026-11-18T10:03:00.000Z", "WINDY", state: "Equipped \\\"Enchanted\\\""),
            rpc("2026-11-18T10:04:00.000Z", "NORMAL", state: "Equipped \\\"Enchanted\\\""),
        ])
        let auras = events.auras
        XCTAssertEqual(auras.map(\.internalName), ["SeekerOfTheCrimsonMoon", "Enchanted"])
        XCTAssertTrue(auras[0].initial, "the aura restored right after joining is not a fresh roll")
        XCTAssertFalse(auras[1].initial)
        XCTAssertEqual(auras[1].biome?.key, "WINDY")
        XCTAssertEqual(auras[1].biomeEventId, events.starts[1].id)
        XCTAssertEqual(tracker.equippedAura, "Enchanted")
    }

    func testRejoinInsideOneLogEndsBiomeAsLeftServer() {
        let (events, tracker) = track([
            joinLine("2026-11-18T10:00:00.000Z", job: "a"),
            rpc("2026-11-18T10:00:10.000Z", "HELL"),
            joinLine("2026-11-18T10:05:00.000Z", job: "b"),
            rpc("2026-11-18T10:05:20.000Z", "NORMAL"),
        ])
        XCTAssertEqual(events.ends.first?.reason, .leftServer)
        XCTAssertNil(events.ends.first?.next)
        XCTAssertEqual(events.startKeys, ["HELL", "NORMAL"])
        XCTAssertFalse(events.starts[1].observedStart)
        XCTAssertEqual(tracker.serverJobId, "b")
    }

    func testOtherGamesRichPresenceIsIgnored() {
        let (events, _) = track([
            joinLine("2026-11-18T10:00:00.000Z", job: "x", place: 999),
            rpc("2026-11-18T10:00:10.000Z", "Lobby"),
        ])
        XCTAssertTrue(events.starts.isEmpty)
    }

    func testEndSessionClosesBiomeAndResets() {
        var (events, tracker) = track([rpc("2026-11-18T10:00:10.000Z", "GLITCHED")])
        events += tracker.endSession(at: date("2026-11-18T10:01:00.000Z"))
        XCTAssertEqual(events.ends.first?.reason, .sessionEnded)
        XCTAssertNil(tracker.current)
        XCTAssertTrue(tracker.endSession(at: Date()).isEmpty)
    }

    func testEventIdsAreStableAndUnique() {
        let lines = [joinLine("2026-11-18T10:00:00.000Z"), rpc("2026-11-18T10:00:10.000Z", "NORMAL"),
                     rpc("2026-11-18T10:05:00.000Z", "WINDY"), rpc("2026-11-18T10:07:00.000Z", "NORMAL")]
        let a = track(lines, session: "s1").events.map(\.id)
        let b = track(lines, session: "s1").events.map(\.id)
        XCTAssertEqual(a, b, "same log, same ids: the outbox can dedupe across restarts")
        XCTAssertEqual(Set(a).count, a.count)
        XCTAssertNotEqual(a, track(lines, session: "s2").events.map(\.id))
    }

    func testEventsRoundTripThroughJSON() throws {
        let events = track(try Fixture.lines("synthetic-rare.log")).events
        let data = try JSONEncoder().encode(events)
        XCTAssertEqual(try JSONDecoder().decode([SiverEvent].self, from: data), events)
    }
}
