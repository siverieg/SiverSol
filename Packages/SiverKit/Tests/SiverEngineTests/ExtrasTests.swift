import XCTest
import CoreGraphics
@testable import SiverCore
@testable import SiverEngine
@testable import SiverNotify
@testable import SiverVision

private func d(_ iso: String) -> Date { try! Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(iso) }

final class MerchantTests: XCTestCase {
    func testArrivalWordingFromTheWiki() {
        XCTAssertEqual(LogLineParser.merchantName(in: "[Merchant]: Mari has arrived on the island..."), "Mari")
        XCTAssertEqual(LogLineParser.merchantName(in: "[Merchant]: Rin has arrived on the island!!"), "Rin")
        XCTAssertEqual(LogLineParser.merchantName(in: "[Merchant]: Jester has arrived on the island!!"), "Jester")
        // OCR damage: missing brackets, odd case.
        XCTAssertEqual(LogLineParser.merchantName(in: "Merchant]: JESTER has arrived on the"), "Jester")
        XCTAssertEqual(LogLineParser.merchantName(in: "mari has arrived on the island"), "Mari")
        // A merchant added by a future update is accepted only with the game's tag.
        XCTAssertEqual(LogLineParser.merchantName(in: "[Merchant]: Zeno has arrived on the island"), "Zeno")
        XCTAssertNil(LogLineParser.merchantName(in: "[Bob]: winter has arrived lol"))
        XCTAssertNil(LogLineParser.merchantName(in: "[Heaven]: A hand of angel leads you into divine place..."))
    }

    func testLogLineBecomesAnEventWithTheCurrentBiome() {
        var tracker = BiomeTracker(sessionId: "s")
        var events: [SiverEvent] = []
        for line in [
            #"2026-11-18T10:00:10.000Z,1,0,6 [BloxstrapRPC] {"command":"SetRichPresence","data":{"state":"Equipped \"Enchanted\"","largeImage":{"hoverText":"RAINY","assetId":1}}}"#,
            "2026-11-18T10:01:00.000Z,2,0,6 [FLog::Output] [Merchant]: Mari has arrived on the island...",
        ] { if let e = LogLineParser.parse(line) { events += tracker.ingest(e) } }
        guard case .merchantArrived(let m)? = events.last else { return XCTFail("\(events)") }
        XCTAssertEqual(m.name, "Mari"); XCTAssertEqual(m.biome?.key, "RAINY"); XCTAssertEqual(m.source, "log")
        XCTAssertEqual(m.at, d("2026-11-18T10:01:00.000Z"))
        // The sanitizer keeps the line (it holds no personal data).
        XCTAssertTrue(LogSanitizer.sanitize("2026-11-18T10:01:00.000Z,2,0,6 [FLog::Output] [Merchant]: Mari has arrived on the island...").contains("Mari has arrived"))
    }

    func testOneAlertPerMerchantPerThreeMinutes() {
        var gate = MerchantGate()
        let t = d("2026-11-18T10:00:00.000Z")
        XCTAssertTrue(gate.shouldAlert("Mari", at: t))
        XCTAssertFalse(gate.shouldAlert("mari", at: t.addingTimeInterval(60)), "log and screen both saw her")
        XCTAssertTrue(gate.shouldAlert("Jester", at: t.addingTimeInterval(61)), "a different merchant is its own alert")
        XCTAssertFalse(gate.shouldAlert("Mari", at: t.addingTimeInterval(179)))
        XCTAssertTrue(gate.shouldAlert("Mari", at: t.addingTimeInterval(181)))
    }

    func testScreenWatcherFiresOnlyWhenTheNoticeAppears() {
        var w = MerchantScreenWatcher()
        XCTAssertEqual(w.newArrivals(in: ["[Heaven]: A hand of angel leads you", "[Tip]: join our server"]), [])
        XCTAssertEqual(w.newArrivals(in: ["[Tip]: join our server", "[Merchant]: Mari has arrived on the island..."]), ["Mari"])
        XCTAssertEqual(w.newArrivals(in: ["[Merchant]: Mari has arrived on the island...", "[Snowy]: White snow"]), [], "still on screen: not new")
        XCTAssertEqual(w.newArrivals(in: ["[Snowy]: White snow"]), [])
        XCTAssertEqual(w.newArrivals(in: ["[Merchant]: Jester has arrived on the island!!", "[Merchant]: Mari has arrived on the island..."]), ["Jester", "Mari"])
    }

    func testMerchantGoesToRichRoutesOnlyWithItsScreenshot() async throws {
        final class Transport: HTTPTransport, @unchecked Sendable {
            var bodies: [(String, String)] = []
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                bodies.append((request.url!.path, String(decoding: request.httpBody ?? Data(), as: UTF8.self)))
                let json = request.httpMethod == "GET" ? #"{"id":"1","guild_id":"9","channel_id":"5"}"# : #"{"id":"77","channel_id":"5"}"#
                return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let transport = Transport()
        let mesh = NotifyMesh(config: NotifyConfig(routes: [RouteConfig(name: "test", profile: .rich), RouteConfig(name: "hunt", profile: .huntCompat)], messageStyle: .classic),
                              secrets: Secrets(discordWebhooks: ["test": "https://discord.com/api/webhooks/111/a", "hunt": "https://discord.com/api/webhooks/222/b"]),
                              catalog: try BiomeCatalog.bundled(), store: OutboxStore(directory: nil), transport: transport)
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("proof-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: png)
        let event = SiverEvent.merchantArrived(MerchantArrived(id: "m1", name: "Jester", at: Date(), biome: BiomeRef(raw: "NORMAL"), source: "screen"))
        await mesh.handle(batch: [event], attachments: ["m1": [png.path]])
        _ = await mesh.flush(timeout: 10)
        let posts = transport.bodies.filter { $0.1.contains("payload_json") || $0.1.contains("embeds") }
        XCTAssertEqual(posts.count, 1)
        XCTAssertTrue(posts[0].0.contains("/111/"), "merchants never go to a hunt-format route")
        XCTAssertTrue(posts[0].1.contains("🛒 Jester arrived"))
        XCTAssertTrue(posts[0].1.contains("attachment://\(png.lastPathComponent)"), "the proof shot is shown inside the embed")
        XCTAssertTrue(posts[0].1.contains("name=\"files[0]\""))
    }
}

final class DailyReportTests: XCTestCase {
    func ev(_ lines: [(String, String)]) -> [SiverEvent] {
        var tracker = BiomeTracker(sessionId: "s")
        var out: [SiverEvent] = []
        for (t, biome) in lines {
            let line = "\(t),1,0,6 [BloxstrapRPC] {\"command\":\"SetRichPresence\",\"data\":{\"state\":\"Equipped \\\"Enchanted\\\"\",\"largeImage\":{\"hoverText\":\"\(biome)\",\"assetId\":1}}}"
            if let e = LogLineParser.parse(line) { out += tracker.ingest(e) }
        }
        return out
    }

    func testCountsSecondsHoursAndRares() throws {
        let events = ev([("2026-11-18T10:30:00.000Z", "NORMAL"), ("2026-11-18T10:50:00.000Z", "STARFALL"), ("2026-11-18T11:00:00.000Z", "GLITCHED"),
                         ("2026-11-18T11:02:44.000Z", "NORMAL")])
        let r = DailyReport.build(day: "2026-11-18", events: events, isRare: { $0 == "GLITCHED" }, now: d("2026-11-18T11:30:00.000Z"))
        XCTAssertEqual(r.counts, ["NORMAL": 2, "STARFALL": 1, "GLITCHED": 1])
        XCTAssertEqual(r.rares, ["GLITCHED"])
        XCTAssertEqual(r.seconds["STARFALL"] ?? 0, 600, accuracy: 0.01)
        XCTAssertEqual(r.seconds["GLITCHED"] ?? 0, 164, accuracy: 0.01)
        // NORMAL: 20 min before STARFALL, plus the one still running from 11:02:44 until "now".
        XCTAssertEqual(r.seconds["NORMAL"] ?? 0, 1200 + 1636, accuracy: 0.01)
        let hourly = try XCTUnwrap(r.hourly)
        XCTAssertEqual(hourly["NORMAL"]?[10] ?? 0, 1200, accuracy: 0.01)
        XCTAssertEqual(hourly["NORMAL"]?[11] ?? 0, 1636, accuracy: 0.01)
        XCTAssertEqual(hourly["STARFALL"]?[10] ?? 0, 600, accuracy: 0.01)
        XCTAssertEqual(hourly["GLITCHED"]?[11] ?? 0, 164, accuracy: 0.01)
        XCTAssertEqual(r.auras, 0, "the aura restored on join is not counted")
        XCTAssertEqual(r.uptimeS, 3600, accuracy: 0.01)
    }

    func testBiomeAcrossMidnightIsSplitBetweenDays() {
        let events = ev([("2026-11-18T23:50:00.000Z", "HELL"), ("2026-11-19T00:10:00.000Z", "NORMAL")])
        let a = DailyReport.build(day: "2026-11-18", events: events, isRare: { _ in false }, now: d("2026-11-19T01:00:00.000Z"))
        let b = DailyReport.build(day: "2026-11-19", events: events, isRare: { _ in false }, now: d("2026-11-19T01:00:00.000Z"))
        XCTAssertEqual(a.seconds["HELL"] ?? 0, 600, accuracy: 0.01)
        XCTAssertEqual(a.hourly?["HELL"]?[23] ?? 0, 600, accuracy: 0.01)
        XCTAssertEqual(b.seconds["HELL"] ?? 0, 600, accuracy: 0.01)
        XCTAssertEqual(b.hourly?["HELL"]?[0] ?? 0, 600, accuracy: 0.01)
    }

    @MainActor
    func testChartRendersAPNG() throws {
        let events = ev([("2026-11-18T10:30:00.000Z", "NORMAL"), ("2026-11-18T10:50:00.000Z", "STARFALL"), ("2026-11-18T12:00:00.000Z", "NORMAL")])
        let r = DailyReport.build(day: "2026-11-18", events: events, isRare: { _ in false }, now: d("2026-11-18T13:00:00.000Z"))
        let data = try XCTUnwrap(DailyChart.png(report: r, catalog: try BiomeCatalog.bundled()))
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertGreaterThan(data.count, 5000)
        XCTAssertNil(DailyChart.png(report: DailyReport(day: "x", counts: [:], seconds: [:], rares: [], uptimeS: 0, auras: 0), catalog: try BiomeCatalog.bundled()))
    }

    func testTimelineKeepsEventsOnceAndCountsPerDay() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("siversol-tl-\(UUID().uuidString)")
        let events = ev([("2026-11-18T10:30:00.000Z", "NORMAL"), ("2026-11-18T10:50:00.000Z", "WINDY"), ("2026-11-19T00:10:00.000Z", "NORMAL")])
        var store = TimelineStore(directory: dir)
        for e in events { XCTAssertTrue(store.record(e)) }
        for e in events { XCTAssertFalse(store.record(e), "a restart replays the same ids") }
        XCTAssertEqual(store.counts(on: d("2026-11-18T12:00:00.000Z")), ["NORMAL": 1, "WINDY": 1])
        store = TimelineStore(directory: dir)   // new process
        XCTAssertEqual(store.count("NORMAL", on: d("2026-11-19T12:00:00.000Z")), 1)
        XCTAssertEqual(store.events(day: "2026-11-18").count, 4, "two starts, one end and the aura equip")
        XCTAssertEqual(store.availableDays, ["2026-11-18", "2026-11-19"])
        XCTAssertFalse(store.record(events[0]))
    }
}

final class ProofShotTests: XCTestCase {
    func testMaskCoversChatAndPlayerListOnly() throws {
        let side = 200
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let masked = ProofShot.masked(ctx.makeImage()!)
        func brightness(_ x: CGFloat, _ y: CGFloat) -> UInt8 {   // window ratios, top-left origin
            var px = [UInt8](repeating: 0, count: 4)
            let c = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(masked, in: CGRect(x: -x * CGFloat(side), y: -(1 - y) * CGFloat(side) + 1, width: CGFloat(side), height: CGFloat(side)))
            return px[0]
        }
        XCTAssertLessThan(brightness(0.2, 0.3), 60, "chat area is covered")
        XCTAssertLessThan(brightness(0.9, 0.08), 60, "player list is covered")
        XCTAssertGreaterThan(brightness(0.6, 0.5), 200, "the world stays visible")
        XCTAssertGreaterThan(brightness(0.05, 0.85), 200, "the on-screen biome label stays visible")
        XCTAssertGreaterThan(brightness(0.5, 0.92), 200, "the Roll button stays visible")
    }
}
