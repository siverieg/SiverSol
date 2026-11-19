import XCTest
@testable import SiverCore

final class LogLineParserTests: XCTestCase {
    func testRealMacLine() throws {
        // Verbatim line shape from a real macOS client log.
        let line = #"2026-11-18T11:42:22.289Z,120.289726,70603000,6,Info [FLog::CreatorOutput] [BloxstrapRPC] {"command":"SetRichPresence","data":{"state":"Equipped \"SeekerOfTheCrimsonMoon\"","smallImage":{"hoverText":"Sol's RNG","assetId":131439921277342},"largeImage":{"hoverText":"WINDY","assetId":138169499467564}}}"#
        guard case .presence(let p)? = LogLineParser.parse(line) else { return XCTFail("not parsed") }
        XCTAssertEqual(p.biome?.key, "WINDY")
        XCTAssertEqual(p.biome?.raw, "WINDY")
        XCTAssertEqual(p.biome?.assetId, 138169499467564)
        XCTAssertEqual(p.state, .equipped("SeekerOfTheCrimsonMoon"))
        XCTAssertEqual(p.timestamp, date("2026-11-18T11:42:22.289Z"))
    }

    func testDoesNotDependOnChannelTag() {
        for tag in ["FLog::CreatorOutput", "FLog::Output", "Whatever"] {
            guard case .presence(let p)? = LogLineParser.parse(rpc("2026-11-18T10:00:00.000Z", "RAINY", tag: tag)) else {
                return XCTFail("tag \(tag) not parsed")
            }
            XCTAssertEqual(p.biome?.key, "RAINY")
        }
    }

    func testStateShapes() {
        XCTAssertEqual(PresenceState(raw: "In Main Menu"), .mainMenu)
        XCTAssertEqual(PresenceState(raw: "Equipped _None_"), .equipped(nil))
        XCTAssertEqual(PresenceState(raw: "Equipped \"Enchanted\""), .equipped("Enchanted"))
        XCTAssertEqual(PresenceState(raw: "Fishing"), .other("Fishing"))
    }

    func testMixedCaseAndSpacingNormalizeButDisplayIsKept() {
        guard case .presence(let p)? = LogLineParser.parse(rpc("2026-11-18T10:00:00.000Z", "  Sand   Storm ")) else { return XCTFail() }
        XCTAssertEqual(p.biome?.key.value, "SAND STORM")
        XCTAssertEqual(p.biome?.raw, "  Sand   Storm ")
        XCTAssertEqual(BiomeKey("heaven"), BiomeKey("HEAVEN"))
        XCTAssertEqual(BiomeKey("Cyberspace").value, "CYBERSPACE")
    }

    func testIgnoresOtherCommandsAndBrokenJSON() {
        let other = #"2026-11-18T10:00:00.000Z,1,0,6,Info [FLog::CreatorOutput] [BloxstrapRPC] {"command":"SetLaunchData","data":"x"}"#
        XCTAssertNil(LogLineParser.parse(other))
        XCTAssertNil(LogLineParser.parse("2026-11-18T10:00:00.000Z,1,0,6 [BloxstrapRPC] {\"command\":\"SetRichPresence\",\"data\":{\"state\":"))
        XCTAssertNil(LogLineParser.parse("2026-11-18T10:00:00.000Z,1,0,6 [BloxstrapRPC] not json"))
        XCTAssertNil(LogLineParser.parse("2026-11-18T10:00:00.000Z,1,0,6 [FLog::Output] something unrelated"))
        XCTAssertNil(LogLineParser.parse(""))
    }

    func testTrailingJunkAndBracesInsideStrings() {
        let line = #"2026-11-18T10:00:00.000Z,1,0,6 [BloxstrapRPC] {"command":"SetRichPresence","data":{"state":"Equipped \"We}ird{\"","largeImage":{"hoverText":"NULL","assetId":"77"}}} trailing } junk"#
        guard case .presence(let p)? = LogLineParser.parse(line) else { return XCTFail() }
        XCTAssertEqual(p.biome?.key, "NULL")
        XCTAssertEqual(p.biome?.assetId, 77)   // string asset ids are accepted too
        XCTAssertEqual(p.state, .equipped("We}ird{"))
    }

    func testPartialPresenceWithoutLargeImageKeepsBiomeUnknown() {
        let line = #"2026-11-18T10:00:00.000Z,1,0,6 [BloxstrapRPC] {"command":"SetRichPresence","data":{"state":"Equipped \"Enchanted\""}}"#
        guard case .presence(let p)? = LogLineParser.parse(line) else { return XCTFail() }
        XCTAssertNil(p.biome)
        XCTAssertEqual(p.state, .equipped("Enchanted"))
    }

    func testMissingTimestampUsesFallback() {
        let fallback = Date(timeIntervalSince1970: 1000)
        guard case .presence(let p)? = LogLineParser.parse(#"[BloxstrapRPC] {"command":"SetRichPresence","data":{"largeImage":{"hoverText":"HELL"}}}"#, fallbackDate: fallback) else { return XCTFail() }
        XCTAssertEqual(p.timestamp, fallback)
    }

    func testJoinLine() {
        guard case .joined(let job, let place, let at)? = LogLineParser.parse(joinLine("2026-11-18T12:13:17.324Z")) else { return XCTFail() }
        XCTAssertEqual(job, "00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(place, SiverSol.solsRNGPlaceId)
        XCTAssertEqual(at, date("2026-11-18T12:13:17.324Z"))
    }

    func testDisconnectLines() {
        func kind(_ text: String) -> (Int?, String)? {
            guard case .disconnected(let r, let k, _)? = LogLineParser.parse("2026-11-18T10:00:00.000Z,1,0,6 \(text)") else { return nil }
            return (r, k)
        }
        XCTAssertEqual(kind("[FLog::Network] Disconnect reason received: 277")?.0, 277)
        XCTAssertEqual(kind("[FLog::Network] Disconnection Notification. Reason: 266")?.1, "notification")
        XCTAssertEqual(kind("[FLog::Network] Sending disconnect with reason: 288")?.0, 288)
        XCTAssertEqual(kind("[FLog::Network] Connection lost")?.1, "connection-lost")
    }

    func testHealthyLaunchNoiseIsNotADisconnect() {
        // Both appear in normal sessions on macOS.
        XCTAssertNil(LogLineParser.parse("2026-11-18T12:13:16.953Z,1.953377,6be43000,6 [DFLog::SignalRCoreError] ID: 1 Disconnected - stop() called"))
        XCTAssertNil(LogLineParser.parse("2026-11-18T11:56:34.067Z,972.0,74b5300,6 [FLog::Error] [FaceAnimatorService] Camera client signalled error: -2147483636; disconnecting video stream."))
        XCTAssertNil(LogLineParser.parse("2026-11-18T12:12:24.646Z,1922.6,6f5e7000,6,Info [DFLog::NetworkClient] Client:Disconnect"))
        XCTAssertNil(LogLineParser.parse("2026-11-18T12:12:24.647Z,1922.6,70c27000,7 [FLog::Network] Time to disconnect replication data: 0.464500"))
    }
}
