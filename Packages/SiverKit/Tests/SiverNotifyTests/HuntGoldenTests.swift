import XCTest
@testable import SiverCore
@testable import SiverNotify

/// The Hunt-Compat payloads exactly as SiverSol v1.0 sent them, kept as files. Glitch-hunt bots read these
/// messages, so they must never change: not the words, not the fields, not the bytes on the wire.
/// If this test fails, a change leaked into the hunt format. Fix the change, never the golden files.
final class HuntGoldenTests: XCTestCase {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Golden", isDirectory: true)

    private func ctx(pings: Bool) -> RenderContext {
        let route = RouteConfig(name: "hunt", profile: .huntCompat, pingsEnabled: pings,
                                pings: ["GLITCHED": .everyone, "DREAMSPACE": .role("42"), "WINDY": .everyone])
        return RenderContext(catalog: catalog(), route: route, origin: .live, serverLink: fakeLink, now: date("2026-11-18T11:42:23.000Z"))
    }

    /// Name -> the message as the hunt templates build it today.
    private func samples() throws -> [(String, DiscordMessage)] {
        var out: [(String, DiscordMessage)] = []
        for (name, biome, pings) in [("started-glitched-ping", "GLITCHED", true), ("started-glitched", "GLITCHED", false), ("started-windy", "WINDY", false),
                                     ("started-normal", "NORMAL", false), ("started-sand-storm", "Sand  Storm", false), ("started-dreamspace-role-ping", "DREAMSPACE", true)] {
            let ev = BiomeStarted(id: "g-\(name)", biome: BiomeRef(raw: biome), at: date("2026-11-18T11:42:22.289Z"), observedStart: true,
                                  wasRunning: false, serverJobId: "abcdef01-0000", previous: "NORMAL")
            out.append((name, try XCTUnwrap(HuntTemplates.biomeStarted(ev, ctx(pings: pings)))))
        }
        for (name, biome) in [("ended-glitched", "GLITCHED"), ("ended-windy", "WINDY")] {
            let ev = BiomeEnded(id: "g-\(name)", biome: BiomeRef(raw: biome), startedAt: date("2026-11-18T11:42:22.289Z"), at: date("2026-11-18T11:44:22.289Z"),
                                startedEventId: "s", startObserved: true, reason: .changed, next: "NORMAL", serverJobId: "abcdef01-0000")
            out.append((name, try XCTUnwrap(HuntTemplates.biomeEnded(ev, ctx(pings: false)))))
        }
        return out
    }

    /// The payload with its keys in alphabetical order. JSON objects have no order, and v1.0 itself wrote the keys
    /// in a different order on every launch, so this is the form in which two payloads can be compared byte for byte.
    private func canonical(_ wire: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: wire)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    func testHuntPayloadsAreByteIdenticalToV1() throws {
        let record = ProcessInfo.processInfo.environment["SIVERSOL_RECORD_GOLDEN"] != nil
        for (name, message) in try samples() {
            let wire = message.json()
            let url = Self.directory.appendingPathComponent("hunt-v1.0-\(name).json")
            if record {
                try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                try canonical(wire).write(to: url)
                continue
            }
            let golden = try Data(contentsOf: url)
            XCTAssertEqual(String(decoding: try canonical(wire), as: UTF8.self), String(decoding: golden, as: UTF8.self), "hunt payload \(name) differs from v1.0")
            XCTAssertEqual(try canonical(wire), golden, "byte for byte, with the keys in order")
            XCTAssertEqual(wire.count, golden.count, "and not one byte more or less on the wire")
            // Never the new layout: no flags, no components, no extra keys, one classic embed.
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
            XCTAssertTrue(Set(object.keys).isSubset(of: ["content", "embeds", "allowed_mentions"]), "unexpected keys in a hunt payload: \(object.keys.sorted())")
            XCTAssertEqual((object["embeds"] as? [[String: Any]])?.count, 1)
        }
    }

    /// The same check through the whole pipeline: whatever the message style is set to, a hunt route sends the v1.0 payload.
    func testAHuntRouteIgnoresTheMessageStyle() async throws {
        for style in MessageStyle.allCases {
            let rig = await Rig(routes: [RouteConfig(name: "hunt", profile: .huntCompat)], style: style)
            let ev = BiomeStarted(id: "g-started-glitched", biome: BiomeRef(raw: "GLITCHED"), at: date("2026-11-18T11:42:22.289Z"), observedStart: true,
                                  wasRunning: false, serverJobId: "abcdef01-0000", previous: "NORMAL")
            await rig.mesh.handle(.biomeStarted(ev))
            _ = await rig.mesh.flush(timeout: 5)
            let sent = try XCTUnwrap(rig.discord.calls.first { $0.method == "POST" })
            XCTAssertFalse(sent.query.contains("with_components"), "\(style): a hunt message is a classic embed")
            let golden = try Data(contentsOf: Self.directory.appendingPathComponent("hunt-v1.0-started-glitched.json"))
            XCTAssertEqual(try canonical(sent.body), golden, "\(style)")
        }
    }
}
