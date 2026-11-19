import XCTest
@testable import SiverCore

/// Replays sanitized excerpts of real client logs and checks the tracker against the known sequence.
final class FixtureReplayTests: XCTestCase {
    func testSessionA() throws {
        let events = track(try Fixture.lines("session-a-2026-11-18.log")).events
        XCTAssertEqual(events.startKeys, ["NORMAL", "WINDY", "PUMPKIN MOON", "NORMAL", "PUMPKIN MOON", "NORMAL",
                                          "STARFALL", "NORMAL", "RAINY", "NORMAL", "PUMPKIN MOON", "NORMAL"])
        func length(_ key: BiomeKey) throws -> TimeInterval { try XCTUnwrap(events.ends.first { $0.biome.key == key }).duration }
        // Real lengths from the log: WINDY was cut short by PUMPKIN MOON after 25 s; the others ran full length.
        XCTAssertEqual(try length("WINDY"), 25.2, accuracy: 0.1)
        XCTAssertEqual(try length("STARFALL"), 600, accuracy: 0.1)
        XCTAssertEqual(try length("RAINY"), 120, accuracy: 0.1)
        XCTAssertEqual(try length("PUMPKIN MOON"), 146.7, accuracy: 0.1)
        // The game rejoined inside the same log at 12:12:24Z.
        XCTAssertEqual(events.ends.last?.reason, .leftServer)
    }

    func testSessionB() throws {
        let events = track(try Fixture.lines("session-b-2026-11-18.log")).events
        XCTAssertEqual(events.startKeys, ["NORMAL", "PUMPKIN MOON", "NORMAL", "SNOWY", "PUMPKIN MOON", "NORMAL", "SNOWY",
                                          "HEAVEN", "PUMPKIN MOON", "NORMAL", "RAINY", "NORMAL", "SNOWY", "NORMAL"])
        XCTAssertEqual(events.ends.count, 13)
        // Exactly one embed per distinct equip, none on repeats (F5 acceptance).
        XCTAssertEqual(events.auras.map(\.internalName), ["SeekerOfTheCrimsonMoon", "Enchanted"])
        XCTAssertEqual(events.auras.map(\.initial), [true, false])
        // PUMPKIN MOON lasted 146-147 s each time.
        for e in events.ends where e.biome.key == "PUMPKIN MOON" { XCTAssertEqual(e.duration, 146.7, accuracy: 1) }
    }

    func testSyntheticRare() throws {
        let events = track(try Fixture.lines("synthetic-rare.log")).events
        XCTAssertEqual(events.startKeys, ["NORMAL", "SAND STORM", "NORMAL", "GLITCHED", "HEAVEN", "GARGANTUABIOME", "DREAMSPACE", "NORMAL"])
        let glitched = try XCTUnwrap(events.ends.first { $0.biome.key == "GLITCHED" })
        XCTAssertEqual(glitched.duration, 164, accuracy: 0.001)
        XCTAssertEqual(events.filter { if case .disconnected = $0 { return true }; return false }.count, 2)
    }

    func testFixturesHoldNoPersonalData() throws {
        let fixtures = try FileManager.default.contentsOfDirectory(at: Fixture.repoRoot.appendingPathComponent("Fixtures"),
                                                                   includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "log" }
        XCTAssertFalse(fixtures.isEmpty)
        for url in fixtures {
            let text = try String(contentsOf: url, encoding: .utf8)
            // Sanitizing a fixture again must change nothing: every line is already whitelisted.
            if url.lastPathComponent.hasPrefix("session-") { XCTAssertEqual(LogSanitizer.sanitize(text), text, url.lastPathComponent) }
            for line in text.split(whereSeparator: \.isNewline) {
                if let m = line.firstMatch(of: #/Joining game '([^']+)'/#) {
                    XCTAssertTrue(m.1.hasPrefix("00000000-0000-4000-8000-"), "real job id in \(url.lastPathComponent)")
                    XCTAssertTrue(line.hasSuffix("at 0.0.0.0"), "real address in \(url.lastPathComponent)")
                }
                for word in ["ticket", "userid", "UserId", "roblosecurity"] + Fixture.privateTerms {
                    XCTAssertFalse(line.localizedCaseInsensitiveContains(word), "\(word) in \(url.lastPathComponent)")
                }
            }
        }
    }

    func testSanitizerDropsEverythingElseAndMasksIds() {
        let raw = [
            "2026-11-18T12:13:16.000Z,1.0,6be43000,6 [FLog::Output] userid:123456789, ticket abcdef, name SomePlayer99",
            "2026-11-18T12:13:17.324Z,2.324059,6be43000,6 [FLog::Output] ! Joining game 'dff0485d-aaaa-bbbb-cccc-b7aba773e1f8' place 15532962292 at 10.20.30.40",
            "2026-11-18T12:13:17.400Z,2.4,6be43000,6 [FLog::Output] Connecting to UDMUX server 10.20.30.40:55555",
            rpc("2026-11-18T12:13:40.000Z", "NORMAL"),
        ].joined(separator: "\n")
        let clean = LogSanitizer.sanitize(raw)
        XCTAssertEqual(clean.split(separator: "\n").count, 2)
        for secret in ["123456789", "abcdef", "SomePlayer99", "dff0485d", "10.20.30.40", "UDMUX"] {
            XCTAssertFalse(clean.contains(secret), secret)
        }
        XCTAssertTrue(clean.contains("'00000000-0000-4000-8000-000000000001' place 15532962292 at 0.0.0.0"))
    }
}
