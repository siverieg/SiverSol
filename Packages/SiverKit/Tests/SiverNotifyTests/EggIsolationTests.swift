import XCTest
import CoreGraphics
@testable import SiverNotify
@testable import SiverCore
import SiverSky

/// Rare sky surprises have nothing to do with Discord. With every surprise found and switched on, every
/// payload and every picture made for Discord is byte for byte what it is with them off.
final class EggIsolationTests: XCTestCase {
    private func canonical(_ wire: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: wire), options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Everything that can go to Discord, as bytes: hunt payloads, every Sky Card and its classic form, test
    /// content, and the pictures drawn for cards and for Session Wrapped.
    private func everything() throws -> [String: Data] {
        var out: [String: Data] = [:]
        let cards = SkyCardTests()
        for origin in [EventOrigin.live, .test] {
            for (name, message) in cards.samples(origin: origin) {
                out["card-\(origin)-\(name)"] = try canonical(message.json())
                out["classic-\(origin)-\(name)"] = try canonical(message.classic.json())
            }
        }
        let cat = catalog()
        let route = RouteConfig(name: "hunt", profile: .huntCompat, pingsEnabled: true, pings: ["GLITCHED": .everyone])
        let ctx = RenderContext(catalog: cat, route: route, origin: .live, serverLink: fakeLink, now: date("2026-11-18T11:42:23.000Z"))
        for biome in ["GLITCHED", "RAINY", "NORMAL"] {
            let started = BiomeStarted(id: "h-\(biome)", biome: BiomeRef(raw: biome), at: date("2026-11-18T11:42:22.289Z"), observedStart: true, wasRunning: false, serverJobId: "abcdef01-0000", previous: "NORMAL")
            if let m = HuntTemplates.biomeStarted(started, ctx) { out["hunt-started-\(biome)"] = m.json() }
            let ended = BiomeEnded(id: "he-\(biome)", biome: BiomeRef(raw: biome), startedAt: date("2026-11-18T11:42:22.289Z"), at: date("2026-11-18T11:44:22.289Z"),
                                   startedEventId: "s", startObserved: true, reason: .changed, next: "NORMAL", serverJobId: "abcdef01-0000")
            if let m = HuntTemplates.biomeEnded(ended, ctx) { out["hunt-ended-\(biome)"] = try canonical(m.json()) }
        }
        // Pictures.
        if let sky = SkyRenderer.shared {
            for biome in ["RAINY", "GLITCHED", "PUMPKIN MOON"] {
                let look = SkyModel.look(cat.info(for: BiomeKey(biome)).palette, hour: 22, dark: true)
                if let image = sky.image(SkyScene(look: look), size: CGSize(width: 550, height: 200), scale: 1), let data = image.dataProvider?.data as Data? {
                    out["picture-\(biome)"] = data
                }
            }
        }
        return out
    }

    func testEveryPayloadAndPictureIsIdenticalWithEverySurpriseOn() throws {
        let defaults = UserDefaults.standard
        let keepFound = defaults.object(forKey: EggStore.key), keepOn = defaults.object(forKey: EggStore.enabledKey)
        defer {
            if let keepFound { defaults.set(keepFound, forKey: EggStore.key) } else { defaults.removeObject(forKey: EggStore.key) }
            if let keepOn { defaults.set(keepOn, forKey: EggStore.enabledKey) } else { defaults.removeObject(forKey: EggStore.enabledKey) }
        }
        // Off, nothing found.
        let store = EggStore(defaults: defaults)
        store.reset()
        store.enabled = false
        let before = try everything()
        XCTAssertGreaterThan(before.count, 40)

        // On, all eight found (so Egg Hunter too), and every sky surprise playing on a board of its own.
        store.enabled = true
        for egg in SkyEgg.allCases { store.record(egg, at: Date()) }
        XCTAssertTrue(store.hunter)
        var board = EggBoard()
        for egg in SkyEgg.allCases { board.start(egg, at: Date().addingTimeInterval(-5), until: Date().addingTimeInterval(600)) }
        board.bats = true
        board.fireworksBegan = Date().addingTimeInterval(-1)
        XCTAssertFalse(board.sky(at: Date()).isNone)

        let after = try everything()
        XCTAssertEqual(Set(before.keys), Set(after.keys))
        for (name, bytes) in before { XCTAssertEqual(after[name], bytes, "\(name) changed when the surprises were switched on") }

        // And the hunt payloads still match the files recorded from v1.0.
        try HuntGoldenTests().testHuntPayloadsAreByteIdenticalToV1()
    }

    func testNoPayloadMentionsASurprise() throws {
        let words = SkyEgg.allCases.map { $0.name.lowercased() } + ["egg hunter", "sky surprise", "glimmer", "secret", "(probably)"]
        for (name, bytes) in try everything() where !name.hasPrefix("picture-") {
            let text = String(decoding: bytes, as: UTF8.self).lowercased()
            for word in words { XCTAssertFalse(text.contains(word), "\(name) contains “\(word)”") }
        }
    }

    func testAPictureForDiscordCannotCarryASurprise() {
        // The pictures are drawn from a scene that is built without surprises; only the app's window adds them.
        let look = SkyModel.look(.clear, hour: 22, dark: true)
        XCTAssertTrue(SkyScene(look: look).eggs.isNone)
        // The shader draws the ordinary sky for a scene without them, and a different one with them.
        guard let sky = SkyRenderer.shared else { return }
        var forced = SkyScene(look: look)
        forced.eggs.aurora = 1; forced.eggs.twinMoon = 1; forced.eggs.star = 0.5
        let plain = sky.image(SkyScene(look: look), size: CGSize(width: 320, height: 200), scale: 1)?.dataProvider?.data as Data?
        let again = sky.image(SkyScene(look: look), size: CGSize(width: 320, height: 200), scale: 1)?.dataProvider?.data as Data?
        let egged = sky.image(forced, size: CGSize(width: 320, height: 200), scale: 1)?.dataProvider?.data as Data?
        XCTAssertNotNil(plain)
        XCTAssertEqual(plain, again, "the ordinary sky is drawn the same every time")
        XCTAssertNotEqual(plain, egged, "the surprises do draw when asked")
    }
}
