import XCTest
@testable import SiverCore
@testable import SiverNotify

/// SPEC F3 acceptance: the hunt-bot parser (ported from sora-bot) must read every Hunt-Compat template correctly.
final class HuntCompatTests: XCTestCase {
    func ctx(pings: Bool = false, link: String? = fakeLink, origin: EventOrigin = .live) -> RenderContext {
        let route = RouteConfig(name: "hunt", profile: .huntCompat, pingsEnabled: pings,
                                pings: ["GLITCHED": .everyone, "DREAMSPACE": .role("42"), "WINDY": .everyone])
        return RenderContext(catalog: catalog(), route: route, origin: origin, serverLink: link, now: date("2026-11-18T11:42:23.000Z"))
    }

    func testStartedMatchesSpecExactly() throws {
        let m = try XCTUnwrap(HuntTemplates.biomeStarted(started("GLITCHED"), ctx(pings: true)))
        XCTAssertEqual(m.content, "@everyone")
        XCTAssertEqual(m.allowedMentions, AllowedMentions(parse: ["everyone"]))
        XCTAssertEqual(m.embeds.count, 1)
        let e = m.embeds[0]
        XCTAssertEqual(e.title, "Biome Started - GLITCHED")
        XCTAssertEqual(e.description, "Started <t:1795002142:T> (<t:1795002142:R>)")
        XCTAssertEqual(e.color, 6619088)
        XCTAssertEqual(e.fields, [Embed.Field("Private Server Link", fakeLink, inline: false)])
        XCTAssertEqual(e.timestamp, "2026-11-18T11:42:22.289Z", "the log line's time, not the send time")
        XCTAssertEqual(e.footer?.text, "SiverSol v1.0.0")
        XCTAssertNil(m.components)
        XCTAssertNil(m.username)
    }

    /// Locked on 2026-11-18 after Shayge (Shay's Glitch Hunt bot) confirmed what his bot matches.
    /// If this test fails, the Hunt-Compat format drifted. Do not "fix" the test; fix the template.
    func testLockedFormat() throws {
        // Catalog biomes plus an unknown one and one with odd spacing and case.
        let names = catalog().all.map(\.key.value) + ["GargantuaBiome", "  sand   storm ", "Null's Realm"]
        for raw in names {
            let key = BiomeKey(raw).value
            let ev = BiomeStarted(id: "x-\(key)", biome: BiomeRef(raw: raw), at: date("2026-11-18T11:42:22.289Z"), observedStart: true,
                                  wasRunning: false, serverJobId: nil, previous: nil)
            for pings in [false, true] {
                let m = try XCTUnwrap(HuntTemplates.biomeStarted(ev, ctx(pings: pings)))
                let embed = m.embeds[0]
                let title = try XCTUnwrap(embed.title)
                // Exactly "Biome Started - <BIOME>": nothing before "Biome", no emoji, no brackets, no timestamp.
                XCTAssertEqual(title, "Biome Started - \(key)")
                XCTAssertTrue(title.hasPrefix("Biome Started - "))
                XCTAssertEqual(title.unicodeScalars.first, "B")
                XCTAssertTrue(title.unicodeScalars.allSatisfy { $0.isASCII }, "no emoji or fancy characters in \(title)")
                XCTAssertEqual(key, key.uppercased())
                // The raw link, alone, in a field named exactly "Private Server Link".
                let field = try XCTUnwrap(embed.fields?.first { $0.name == "Private Server Link" }, title)
                XCTAssertEqual(field.value, fakeLink, "raw URL only: no markdown, no angle brackets, no label")
                XCTAssertEqual(embed.fields?.filter { $0.value.contains("roblox.com") }.count, 1)
                XCTAssertNil(m.components, "no button on a hunt message; the link is plain text")
                XCTAssertEqual(m.embeds.count, 1, "the biome embed is embeds[0] and the only one")
                // What Shayge described: "Biome Started - {biome}", case-insensitive, link found in any embed field.
                let re = try NSRegularExpression(pattern: "^biome started - (.+)$", options: [.caseInsensitive])
                let hit = try XCTUnwrap(re.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)))
                XCTAssertEqual(String(title[Range(hit.range(at: 1), in: title)!]), key)
                XCTAssertTrue((embed.fields ?? []).contains { $0.value.range(of: "https://www.roblox.com/") != nil })
            }
            let end = BiomeEnded(id: "y-\(key)", biome: BiomeRef(raw: raw), startedAt: date("2026-11-18T11:42:22.289Z"), at: date("2026-11-18T11:44:22.289Z"),
                                 startedEventId: "x-\(key)", startObserved: true, reason: .changed, next: nil, serverJobId: nil)
            let ended = try XCTUnwrap(HuntTemplates.biomeEnded(end, ctx()))
            XCTAssertEqual(ended.embeds[0].title, "Biome Ended - \(key)")
            XCTAssertNil(ended.embeds[0].fields, "Ended carries no link")
        }
        XCTAssertEqual(HuntTemplates.startedPrefix, "Biome Started - ")
        XCTAssertEqual(HuntTemplates.linkFieldName, "Private Server Link")
    }

    func testParserExtractsBiomeEventAndLinkFromEveryTemplate() throws {
        let c = catalog()
        for info in c.all {
            let name = info.key.value
            let botKey = HuntFormat.normalize(name)
            // The bot's own list has no NORMAL and no LOST FOREST / THE RADIANT FOREST; teach the port our full catalog
            // so the regex and word logic are exercised for every name, then check the seed list separately below.
            let known = HuntFormat.botSeedBiomes.union([botKey])
            let s = try XCTUnwrap(HuntTemplates.biomeStarted(started(name), ctx()))
            let sx = try XCTUnwrap(HuntFormat.extract(s, knownBiomes: known), name)
            XCTAssertEqual(sx.event, "started", name)
            XCTAssertEqual(sx.biome, botKey, name)
            XCTAssertEqual(sx.serverLink, fakeLink, name)
            XCTAssertEqual(sx.timestamp, "2026-11-18T11:42:22.289Z")

            let e = try XCTUnwrap(HuntTemplates.biomeEnded(ended(name), ctx()))
            let ex = try XCTUnwrap(HuntFormat.extract(e, knownBiomes: known), name)
            XCTAssertEqual(ex.event, "ended", name)
            XCTAssertEqual(ex.biome, botKey, name)
            XCTAssertNil(ex.serverLink, "Ended carries no link")
            XCTAssertEqual(e.embeds[0].title, "Biome Ended - \(name)")
        }
    }

    func testSeedListBiomesParseWithTheBotsOwnList() throws {
        for name in ["WINDY", "SAND STORM", "PUMPKIN MOON", "GLITCHED", "DREAMSPACE", "CYBERSPACE", "SINGULARITY", "BLOOD RAIN"] {
            let m = try XCTUnwrap(HuntTemplates.biomeStarted(started(name), ctx()))
            XCTAssertEqual(HuntFormat.extract(m)?.biome, HuntFormat.normalize(name), name)
        }
        // Known gap, not ours to fix: the open-source bot has no NORMAL entry, so it ignores NORMAL messages.
        XCTAssertNil(HuntFormat.extract(try XCTUnwrap(HuntTemplates.biomeStarted(started("NORMAL"), ctx()))))
    }

    func testNameKeepsSpacesAndUppercase() throws {
        let m = try XCTUnwrap(HuntTemplates.biomeStarted(BiomeStarted(id: "x", biome: BiomeRef(raw: "Sand  Storm"), at: date("2026-11-18T11:42:22.289Z"),
                                                                     observedStart: true, wasRunning: false, serverJobId: nil, previous: nil), ctx()))
        XCTAssertEqual(m.embeds[0].title, "Biome Started - SAND STORM")
    }

    func testPingRules() throws {
        // Pings off on the route: no content, nobody allowed.
        let off = try XCTUnwrap(HuntTemplates.biomeStarted(started("GLITCHED"), ctx(pings: false)))
        XCTAssertNil(off.content)
        XCTAssertEqual(off.allowedMentions, .none)
        // Not rare: never pings, even if the config lists it.
        let windy = try XCTUnwrap(HuntTemplates.biomeStarted(started("WINDY"), ctx(pings: true)))
        XCTAssertNil(windy.content)
        XCTAssertEqual(windy.allowedMentions, .none)
        // Role ping.
        let dream = try XCTUnwrap(HuntTemplates.biomeStarted(started("DREAMSPACE"), ctx(pings: true)))
        XCTAssertEqual(dream.content, "<@&42>")
        XCTAssertEqual(dream.allowedMentions, AllowedMentions(parse: [], roles: ["42"]))
        // Rare without a configured target.
        XCTAssertNil(try XCTUnwrap(HuntTemplates.biomeStarted(started("CYBERSPACE"), ctx(pings: true))).content)
        // Ended never pings.
        XCTAssertEqual(try XCTUnwrap(HuntTemplates.biomeEnded(ended("GLITCHED"), ctx(pings: true))).allowedMentions, .none)
    }

    func testNoLinkMeansNoField() throws {
        let m = try XCTUnwrap(HuntTemplates.biomeStarted(started("WINDY"), ctx(link: nil)))
        XCTAssertNil(m.embeds[0].fields)
        XCTAssertNil(HuntFormat.serverLink(in: m))
    }

    func testNonLiveEventsNeverGetHuntFormat() {
        for origin in [EventOrigin.simulated, .replay, .test] {
            XCTAssertNil(HuntTemplates.biomeStarted(started("GLITCHED"), ctx(pings: true, origin: origin)))
            XCTAssertNil(HuntTemplates.biomeEnded(ended("GLITCHED"), ctx(origin: origin)))
        }
    }

    func testLostTrackOfRareBiomeIsNotReportedAsEnded() {
        XCTAssertNil(HuntTemplates.biomeEnded(ended("GLITCHED", reason: .sessionEnded), ctx()))
        XCTAssertNotNil(HuntTemplates.biomeEnded(ended("WINDY", reason: .leftServer), ctx()))
    }

    func testFooterDoesNotImpersonateAnotherMacro() {
        XCTAssertNil(HuntFormat.detectedMacro(footer: SiverSol.footer), "must fall through to the common parser")
        XCTAssertEqual(HuntFormat.detectedMacro(footer: "Coteab Macro v2.2.0"), "coteab")
    }

    func testRichAndSimulatedMessagesDoNotParseAsHuntEvents() {
        let rich = RenderContext(catalog: catalog(), route: RouteConfig(name: "test", profile: .rich), serverLink: fakeLink)
        let messages: [DiscordMessage] = [
            RichTemplates.biomeStarted(started("GLITCHED"), rich),
            RichTemplates.biomeStarted(started("WINDY", wasRunning: true), rich),
            RichTemplates.biomeEnded(ended("WINDY"), rich),
            RichTemplates.startedMessageAfterEnd(ended("GLITCHED"), rich),
            RichTemplates.simulated(biome: "GLITCHED", rich),
            RichTemplates.liveCard(LiveCardState(sessionStartedAt: Date(), now: Date()), catalog: catalog()),
        ]
        for m in messages {
            XCTAssertFalse(HuntFormat.looksLikeHuntEvent(m), m.embeds[0].title ?? "")
            XCTAssertNil(HuntFormat.extract(m))
        }
        XCTAssertEqual(RichTemplates.simulated(biome: "GLITCHED", rich).embeds[0].title, "🧪 SIMULATED · GLITCHED")
    }

    func testPortMatchesTheBotOnOtherMacrosFormats() {
        func msg(title: String? = nil, description: String? = nil, field: String? = nil) -> DiscordMessage {
            DiscordMessage(embeds: [Embed(title: title, description: description, fields: field.map { [Embed.Field("x", $0)] })])
        }
        // Noteab style: "[HH:MM:SS] Biome Started - GLITCHED"
        XCTAssertEqual(HuntFormat.extract(msg(title: "[11:42:22] Biome Started - GLITCHED"))?.biome, "GLITCHED")
        // Markdown and a trailing link on the same line.
        let x = HuntFormat.extract(msg(description: "**Biome Started - Sand Storm** [Join Server](https://www.roblox.com/share?code=z&type=Server)"))
        XCTAssertEqual(x?.biome, "SANDSTORM")
        XCTAssertEqual(x?.serverLink, "https://www.roblox.com/share?code=z&type=Server")
        XCTAssertEqual(HuntFormat.extract(msg(field: "biome ended: heaven"))?.event, "ended")
        // "NULL'S" stays one word and must not be read as NULL.
        XCTAssertNil(HuntFormat.extract(msg(title: "Biome Started - NULL'S REALM")))
        XCTAssertNil(HuntFormat.extract(msg(title: "The Hell Gate opened")))
        XCTAssertEqual(HuntFormat.normalize("Pumpkin Moon"), "PUMPKINMOON")
    }
}
