import XCTest
@testable import SiverCore
@testable import SiverNotify

final class TemplateTests: XCTestCase {
    func ctx(_ route: RouteConfig = RouteConfig(name: "test", profile: .rich), origin: EventOrigin = .live,
             links: [String: MessageRef] = [:]) -> RenderContext {
        RenderContext(catalog: catalog(), route: route, origin: origin, serverLink: fakeLink,
                      link: { links[$0] }, todayCount: { _ in 3 }, sessionStartedAt: date("2026-11-18T11:00:00.000Z"),
                      now: date("2026-11-18T11:42:23.000Z"))
    }

    func testEveryMessageSetsAllowedMentionsInItsJSON() throws {
        let c = ctx()
        let all: [DiscordMessage] = [
            RichTemplates.biomeStarted(started("WINDY"), c), RichTemplates.biomeEnded(ended("WINDY"), c),
            RichTemplates.startedMessageAfterEnd(ended("WINDY"), c),
            RichTemplates.aura(AuraEquipped(id: "a", internalName: "SeekerOfTheCrimsonMoon", at: Date(), biome: BiomeRef(raw: "WINDY"), biomeEventId: nil, initial: false, serverJobId: nil), c),
            RichTemplates.newBiome(NewBiomeSeen(id: "n", biome: BiomeRef(raw: "GargantuaBiome", assetId: 3), at: Date()), c),
            RichTemplates.merchant(MerchantArrived(id: "m", name: "Mari", at: Date()), c),
            RichTemplates.incident(IncidentReport(id: "i", cause: "Disconnected", steps: [], recovered: false), c),
            RichTemplates.buildLog(phase: "Phase 2", done: ["x"], next: "y"), RichTemplates.actionNeeded("flip a toggle"),
            RichTemplates.dailyReport(DailyReport(day: "2026-11-18", counts: [:], seconds: [:], rares: [], uptimeS: 0, auras: 0), c),
            RichTemplates.simulated(biome: "GLITCHED", c),
            RichTemplates.liveCard(LiveCardState(sessionStartedAt: Date(), now: Date()), catalog: catalog()),
        ]
        for m in all {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: m.json()) as? [String: Any])
            let allowed = try XCTUnwrap(json["allowed_mentions"] as? [String: Any], "rule 9: \(m.embeds[0].title ?? "")")
            XCTAssertEqual(allowed["parse"] as? [String], [], m.embeds[0].title ?? "")
            XCTAssertEqual(m.embeds[0].footer?.text, "SiverSol v1.0.0")
            XCTAssertLessThanOrEqual(m.embeds[0].title?.count ?? 0, 256)
        }
    }

    func testRichStarted() {
        let m = RichTemplates.biomeStarted(started("WINDY"), ctx())
        let e = m.embeds[0]
        XCTAssertEqual(e.title, "🌬️ WINDY started")
        XCTAssertEqual(e.color, 0x9AE5FF)
        let fields = Dictionary(uniqueKeysWithValues: (e.fields ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(fields["Ends"], "<t:1795002262:R> · usually 2m 0s")
        XCTAssertEqual(fields["Server"], "`dff0485d`")
        XCTAssertEqual(fields["Session uptime"], "42m 22s")
        XCTAssertEqual(fields["Today"], "3rd Windy")
        XCTAssertEqual(m.components?.first?.components.first?.url, fakeLink)
        XCTAssertEqual(m.components?.first?.components.first?.style, 5, "link button, not interactive")
        XCTAssertNil(m.content)
    }

    func testRareStartedPingsOnlyWhenRouteAllows() {
        let on = RouteConfig(name: "test", profile: .rich, pingsEnabled: true, pings: ["GLITCHED": .everyone])
        let m = RichTemplates.biomeStarted(started("GLITCHED"), ctx(on))
        XCTAssertEqual(m.embeds[0].title, "🚨 GLITCHED STARTED")
        XCTAssertEqual(m.content, "@everyone")
        XCTAssertEqual(m.allowedMentions, .everyone)
        XCTAssertTrue(m.embeds[0].fields?.contains { $0.name == "Private server" && $0.value == fakeLink } ?? false)
        let off = RichTemplates.biomeStarted(started("GLITCHED"), ctx())
        XCTAssertNil(off.content); XCTAssertEqual(off.allowedMentions, .none)
        // Same route, but a replay: never pings, and says so.
        let replay = RichTemplates.biomeStarted(started("GLITCHED"), ctx(on, origin: .replay))
        XCTAssertNil(replay.content); XCTAssertEqual(replay.allowedMentions, .none)
        XCTAssertEqual(replay.embeds[0].title, "🧪 REPLAY · 🚨 GLITCHED STARTED")
        XCTAssertTrue(replay.embeds[0].description?.contains("Not a real biome") ?? false)
    }

    func testUnobservedStartDoesNotPromiseAnEnd() {
        let e = RichTemplates.biomeStarted(started("WINDY", observed: false, wasRunning: true), ctx()).embeds[0]
        XCTAssertEqual(e.title, "🌬️ WINDY in progress")
        XCTAssertFalse(e.fields?.contains { $0.name == "Ends" } ?? true)
    }

    func testEndedLinksBackToStarted() {
        let ref = MessageRef(messageId: "777", channelId: "5005", guildId: "9001")
        let m = RichTemplates.biomeEnded(ended("WINDY"), ctx(links: ["s|2026-11-18T11:42:22.289Z|bs|WINDY": ref]))
        XCTAssertEqual(m.embeds[0].title, "✅ WINDY ended · 2m 0s")
        XCTAssertEqual(m.embeds[0].fields?.first?.value, "[↗ Started message](https://discord.com/channels/9001/5005/777)")
        let patch = RichTemplates.startedMessageAfterEnd(ended("WINDY"), ctx())
        XCTAssertEqual(patch.embeds[0].title, "✅ WINDY · ended · lasted 2m 0s")
        let lost = RichTemplates.startedMessageAfterEnd(ended("GLITCHED", reason: .sessionEnded), ctx())
        XCTAssertEqual(lost.embeds[0].title, "⚪ GLITCHED · lost track after 2m 0s")
    }

    func testAuraNames() {
        XCTAssertEqual(AuraName.display("SeekerOfTheCrimsonMoon"), "Seeker Of The Crimson Moon")
        XCTAssertEqual(AuraName.display("Enchanted"), "Enchanted")
        XCTAssertEqual(AuraName.display("HTTPError404Page"), "HTTP Error 404 Page")
        XCTAssertEqual(AuraName.display("snake_case_Name"), "snake case Name")
        let m = RichTemplates.aura(AuraEquipped(id: "a", internalName: "SeekerOfTheCrimsonMoon", at: Date(), biome: nil, biomeEventId: nil, initial: false, serverJobId: nil), ctx())
        XCTAssertEqual(m.embeds[0].title, "✨ Seeker Of The Crimson Moon", "no aura catalog in this context: split words")
        var withCatalog = ctx()
        withCatalog.auras = AuraCatalog.bundled()
        let wind = RichTemplates.aura(AuraEquipped(id: "w", internalName: "Wind", at: Date(), biome: BiomeRef(raw: "WINDY"), biomeEventId: nil, initial: false, serverJobId: nil), withCatalog).embeds[0]
        XCTAssertEqual(wind.title, "✨ Wind")
        let fields = Dictionary(uniqueKeysWithValues: (wind.fields ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(fields["Rarity"], "1 in 900 · Basic")
        XCTAssertEqual(fields["Biome"], "🌬️ WINDY · native biome: 1 in 300 here")
        let pumpkin = RichTemplates.aura(AuraEquipped(id: "p", internalName: ":Flushed:_Pumpkinity", at: Date(), biome: BiomeRef(raw: "PUMPKIN MOON"), biomeEventId: nil, initial: false, serverJobId: nil), withCatalog).embeds[0]
        XCTAssertEqual(pumpkin.title, "✨ Flushed : Pumpkinity")
    }

    func testLiveCard() {
        var s = LiveCardState(sessionStartedAt: date("2026-11-18T10:00:00.000Z"), now: date("2026-11-18T12:00:00.000Z"))
        s.biome = BiomeRef(raw: "STARFALL"); s.biomeSince = date("2026-11-18T11:55:00.000Z"); s.biomeStartObserved = true
        s.todayCounts = ["NORMAL": 9, "WINDY": 2]; s.lastAura = "Enchanted"; s.outboxDepth = 4; s.thermal = "fair"
        let e = RichTemplates.liveCard(s, catalog: catalog()).embeds[0]
        let fields = Dictionary(uniqueKeysWithValues: (e.fields ?? []).map { ($0.name, $0.value) })
        XCTAssertTrue(fields["Biome"]?.contains("▰▰▰▰▰▰▱▱▱▱▱▱ 50%") ?? false, fields["Biome"] ?? "")
        XCTAssertEqual(fields["Session uptime"], "2h 0m 0s")
        XCTAssertEqual(fields["Today's biomes"], "🌤️ NORMAL × 9\n🌬️ WINDY × 2")
        XCTAssertEqual(fields["Mac"], "thermal fair · outbox 4")
        XCTAssertEqual(RichTemplates.progressBar(0, width: 4), "▱▱▱▱")
        XCTAssertEqual(RichTemplates.progressBar(7, width: 4), "▰▰▰▰")
    }

    func testDurationsAndOrdinals() {
        XCTAssertEqual(DiscordTime.duration(120), "2m 0s")
        XCTAssertEqual(DiscordTime.duration(59.6), "1m 0s")
        XCTAssertEqual(DiscordTime.duration(3725), "1h 2m 5s")
        XCTAssertEqual([1, 2, 3, 4, 11, 12, 13, 21, 22, 103, 111].map(RichTemplates.ordinal),
                       ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "103rd", "111th"])
    }

    func testConfigDecodingAndFilters() throws {
        let json = #"{"routes":[{"name":"test"},{"name":"hunt","profile":"hunt-compat","pings":{"GLITCHED":"everyone","DREAMSPACE":"role:42"},"includeNormal":true,"events":["biome","aura"]}]}"#
        let config = try JSONDecoder().decode(NotifyConfig.self, from: Data(json.utf8))
        let hunt = try XCTUnwrap(config.route("hunt"))
        XCTAssertEqual(hunt.profile, .huntCompat)
        XCTAssertFalse(hunt.pingsEnabled, "pings are off unless the user turns them on")
        XCTAssertNil(hunt.ping(for: "GLITCHED", isRare: true))
        XCTAssertTrue(hunt.wants(biome: "NORMAL"))
        XCTAssertFalse(hunt.wants(.aura), "a hunt route carries biome events only, whatever the config says")
        XCTAssertTrue(try XCTUnwrap(config.route("test")).wants(.aura))
        XCTAssertNil(PingTarget(string: "role:abc")); XCTAssertNil(PingTarget(string: "here"))
        XCTAssertThrowsError(try JSONDecoder().decode(NotifyConfig.self, from: Data(#"{"routes":[{"name":"x","pings":{"GLITCHED":"@here"}}]}"#.utf8)))
    }

    func testWebhookURLValidation() {
        XCTAssertEqual(WebhookURL(fakeHook)?.id, "111")
        XCTAssertEqual(WebhookURL(fakeHook)?.redacted, "https://discord.com/api/webhooks/111/…")
        for bad in ["http://discord.com/api/webhooks/1/t", "https://evil.example/api/webhooks/1/t", "https://discord.com.evil.example/api/webhooks/1/t",
                    "https://discord.com/api/webhooks/abc/t", "https://discord.com/api/webhooks/1", "", "not a url"] {
            XCTAssertNil(WebhookURL(bad), bad)
        }
        XCTAssertNil(Secrets(privateServerLink: "https://evil.example/share?code=1").serverLink)
        XCTAssertEqual(Secrets(privateServerLink: fakeLink).serverLink, fakeLink)
    }

    func testQuietHours() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let q = QuietHours(enabled: true, startHour: 23, endHour: 7)
        XCTAssertTrue(q.isQuiet(at: date("2026-11-18T23:30:00.000Z"), calendar: cal))
        XCTAssertTrue(q.isQuiet(at: date("2026-11-18T03:00:00.000Z"), calendar: cal))
        XCTAssertFalse(q.isQuiet(at: date("2026-11-18T07:00:00.000Z"), calendar: cal))
        XCTAssertFalse(q.isQuiet(at: date("2026-11-18T12:00:00.000Z"), calendar: cal))
        XCTAssertFalse(q.allowsPing(for: "CYBERSPACE", at: date("2026-11-18T03:00:00.000Z"), calendar: cal))
        XCTAssertTrue(q.allowsPing(for: "GLITCHED", at: date("2026-11-18T03:00:00.000Z"), calendar: cal), "never sleep through GLITCHED")
        XCTAssertTrue(q.allowsPing(for: "DREAMSPACE", at: date("2026-11-18T03:00:00.000Z"), calendar: cal))
        XCTAssertTrue(q.allowsPing(for: "CYBERSPACE", at: date("2026-11-18T12:00:00.000Z"), calendar: cal))
        let day = QuietHours(enabled: true, startHour: 9, endHour: 17)
        XCTAssertTrue(day.isQuiet(at: date("2026-11-18T10:00:00.000Z"), calendar: cal))
        XCTAssertFalse(day.isQuiet(at: date("2026-11-18T18:00:00.000Z"), calendar: cal))
        XCTAssertFalse(QuietHours(enabled: false).isQuiet(at: date("2026-11-18T03:00:00.000Z"), calendar: cal))
    }

    func testAuraRolledTemplate() {
        var c = ctx(); c.auras = AuraCatalog.bundled()
        let e = AuraRolled(id: "r", name: "Symphony", at: date("2026-11-18T17:47:36.151Z"), captureDelayMs: 15000, durationS: 34.23,
                           biome: BiomeRef(raw: "PUMPKIN MOON"))
        let m = RichTemplates.auraRolled(e, c)
        XCTAssertEqual(m.embeds[0].title, "🎉 Rolled Symphony")
        let fields = Dictionary(uniqueKeysWithValues: (m.embeds[0].fields ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(fields["Cutscene"], "34s")
        XCTAssertEqual(fields["Biome"], "🎃 PUMPKIN MOON")
        XCTAssertNotEqual(fields["Rarity"], "unknown", "Symphony is in the wiki catalog")
        XCTAssertEqual(m.allowedMentions, .none)
        XCTAssertFalse(HuntFormat.looksLikeHuntEvent(m))
    }
}
