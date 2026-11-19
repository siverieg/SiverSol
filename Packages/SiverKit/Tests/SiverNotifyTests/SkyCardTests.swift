import XCTest
@testable import SiverCore
@testable import SiverNotify
@testable import SiverSky

/// Sky Cards: every Rich message in Discord's Components V2 layout.
final class SkyCardTests: XCTestCase {
    private let longJobId = "abcdef01-2222-3333-4444-555555555555"

    private func ctx(origin: EventOrigin = .live, pings: Bool = false, link: String? = fakeLink) -> RenderContext {
        var c = RenderContext(catalog: catalog(), route: RouteConfig(name: "main", profile: .rich, pingsEnabled: pings, pings: RouteConfig.defaultPings),
                              origin: origin, serverLink: link, todayCount: { _ in 3 }, sessionStartedAt: date("2026-11-18T09:00:00.000Z"), now: date("2026-11-18T11:42:23.000Z"))
        c.auras = AuraCatalog.bundled()
        c.profileName = "Glitch Hunt"
        return c
    }

    private func startedEvent(_ biome: String, id: String = "s1") -> BiomeStarted {
        BiomeStarted(id: id, biome: BiomeRef(raw: biome), at: date("2026-11-18T11:42:22.289Z"), observedStart: true, wasRunning: false, serverJobId: longJobId, previous: "NORMAL")
    }
    private func endedEvent(_ biome: String) -> BiomeEnded {
        BiomeEnded(id: "e1", biome: BiomeRef(raw: biome), startedAt: date("2026-11-18T11:42:22.289Z"), at: date("2026-11-18T11:44:49.289Z"),
                   startedEventId: "s1", startObserved: true, reason: .changed, next: "NORMAL", serverJobId: longJobId)
    }

    /// One of every message, as a real event and as a test.
    func samples(origin: EventOrigin = .live) -> [(String, DiscordMessage)] {
        let c = ctx(origin: origin)
        let t = date("2026-11-18T11:42:22.289Z")
        var macro = MacroEvent(id: "m1", kind: .stopped, name: "QA walk", at: t, trigger: "every 15 min")
        macro.reason = "this macro is not allowed to click the item bar"; macro.guardianStop = true; macro.loops = 2; macro.durationS = 41
        var live = LiveCardState(sessionStartedAt: date("2026-11-18T09:00:00.000Z"), now: t)
        live.biome = BiomeRef(raw: "PUMPKIN MOON"); live.biomeSince = t.addingTimeInterval(-60); live.biomeStartObserved = true
        live.serverJobId = longJobId; live.lastAura = "Starlight"; live.lastAuraAt = t.addingTimeInterval(-900); live.resourceLine = "3.7 GB · 41% CPU"
        let report = DailyReport(day: "2026-11-18", counts: ["NORMAL": 80, "RAINY": 12, "GLITCHED": 1], seconds: ["NORMAL": 60000, "RAINY": 1440, "GLITCHED": 164],
                                 rares: ["GLITCHED"], uptimeS: 82000, auras: 3, merchants: 2)
        let wrap = SessionWrap(start: t.addingTimeInterval(-18000), end: t, watchedSeconds: 18000, biomeSeconds: ["NORMAL": 17000, "GLITCHED": 164], biomeCounts: ["NORMAL": 40, "GLITCHED": 1],
                               rares: ["GLITCHED"], rolls: 2, rarestRoll: "Abyssal Hunter", rarestRollChance: 400_000_000, longestNormalSeconds: 3000, merchants: 1, macroRuns: 2)
        let moment = Moment(id: "Moment-x", kind: .roll, title: "Rolled Symphony", detail: "1 in 175,000,000 · Glorious", biome: "NORMAL", at: t, seconds: 34, bytes: 9_000_000, eventId: "r1")
        let incident = IncidentReport(id: "i1", cause: "Roblox disconnected", steps: [.init("noticed", at: t), .init("reopened the private server", at: t.addingTimeInterval(20)), .init("in game", at: t.addingTimeInterval(51))], recovered: true)
        return [
            ("biome-started", RichTemplates.biomeStarted(startedEvent("PUMPKIN MOON"), c)),
            ("rare-started", RichTemplates.biomeStarted(startedEvent("GLITCHED"), ctx(origin: origin, pings: true))),
            ("started-after-end", RichTemplates.startedMessageAfterEnd(endedEvent("PUMPKIN MOON"), c)),
            ("biome-ended", RichTemplates.biomeEnded(endedEvent("PUMPKIN MOON"), c)),
            ("new-biome", RichTemplates.newBiome(NewBiomeSeen(id: "n1", biome: BiomeRef(raw: "Gargantua Fields"), at: t), c)),
            ("simulated", RichTemplates.simulated(biome: "WINDY", ctx(origin: .simulated))),
            ("aura", RichTemplates.aura(AuraEquipped(id: "a1", internalName: "AbyssalHunter", at: t, biome: BiomeRef(raw: "RAINY"), biomeEventId: nil, initial: false, serverJobId: longJobId), c)),
            ("aura-rolled", RichTemplates.auraRolled(AuraRolled(id: "r1", name: "Symphony", at: t, captureDelayMs: 15000, durationS: 34.23, biome: BiomeRef(raw: "NORMAL")), c)),
            ("moment", RichTemplates.moment(moment, c, hasVideo: true, stillFileName: nil)),
            ("wrapped", RichTemplates.wrapped(wrap, c, imageFileName: "Wrapped-x.png")),
            ("daily", RichTemplates.dailyReport(report, c, chartFileName: "daily.png")),
            ("merchant", RichTemplates.merchant(MerchantArrived(id: "me1", name: "Mari", at: t, biome: BiomeRef(raw: "NORMAL"), source: "log"), c)),
            ("incident", RichTemplates.incident(incident, c)),
            ("macro", RichTemplates.macro(macro, c, hasProof: true)),
            ("info", RichTemplates.info(title: "📈 Roblox is using a lot of memory", text: "Roblox is at **6.4 GB** (your limit is 6.0 GB). Rejoining usually frees it.", origin: origin, now: t, profile: "Glitch Hunt")),
            ("connected", RichTemplates.connected(route: c.route, webhookName: "SiverSol test", channelId: "5005", catalog: catalog(), now: t, profile: "Glitch Hunt")),
            ("live-card", RichTemplates.liveCard(live, catalog: catalog(), auras: AuraCatalog.bundled(), profile: "Glitch Hunt")),
        ]
    }

    private func hasEmoji(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C) }
    }

    func testEveryRichMessageHasACardWithTheSameAnatomy() throws {
        for (name, message) in samples() {
            let card = try XCTUnwrap(message.sky, "\(name) has no Sky Card")
            XCTAssertLessThanOrEqual(card.facts.count, 3, "\(name): at most three fact lines")
            XCTAssertFalse(card.headline.isEmpty, name)
            XCTAssertEqual(card.footer, "SiverSol v1.0 · Glitch Hunt", name)
            for text in card.allText {
                XCTAssertFalse(hasEmoji(text), "\(name): no emoji in a card (\(text))")
                XCTAssertFalse(text.contains("!"), "\(name): no exclamation marks (\(text))")
            }
            XCTAssertEqual(String(card.headline.prefix(1)), String(card.headline.prefix(1)).uppercased(), "\(name): sentence case")
            XCTAssertNotEqual(card.headline, card.headline.uppercased(), "\(name): a headline is not shouted")
            XCTAssertLessThanOrEqual(card.componentCount, SkyCard.maxComponents, name)
            XCTAssertLessThanOrEqual(card.allText.reduce(0) { $0 + $1.count } + 20, SkyCard.maxText, name)
        }
    }

    func testPayloadIsComponentsV2AndNothingElse() throws {
        var card = try XCTUnwrap(RichTemplates.biomeStarted(startedEvent("PUMPKIN MOON"), ctx()).sky)
        card.thumbnail = "sky-thumb.png"; card.gallery = ["sky-card.png"]
        var message = DiscordMessage(username: "SiverSol", allowedMentions: .none)
        message.sky = card
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: message.json()) as? [String: Any])
        XCTAssertEqual(body["flags"] as? Int, 32768, "IS_COMPONENTS_V2")
        XCTAssertNil(body["content"]); XCTAssertNil(body["embeds"]); XCTAssertNil(body["sky"], "with the flag, content and embeds must be absent")
        XCTAssertEqual((body["allowed_mentions"] as? [String: Any])?["parse"] as? [String], [])
        let container = try XCTUnwrap((body["components"] as? [[String: Any]])?.first)
        XCTAssertEqual(container["type"] as? Int, 17)
        XCTAssertEqual(container["accent_color"] as? Int, 0xFF8A1F, "the accent is the biome's own colour from the palette")
        let inner = try XCTUnwrap(container["components"] as? [[String: Any]])
        XCTAssertEqual(inner.map { $0["type"] as? Int }, [9, 14, 10, 12, 1, 10], "section, separator, facts, gallery, link row, footer")
        let section = inner[0]
        XCTAssertEqual(((section["components"] as? [[String: Any]])?.first?["content"] as? String)?.hasPrefix("### Pumpkin Moon has started\n-# event biome · server `abcdef01`"), true)
        XCTAssertEqual(((section["accessory"] as? [String: Any])?["media"] as? [String: Any])?["url"] as? String, "attachment://sky-thumb.png")
        let facts = try XCTUnwrap(inner[2]["content"] as? String)
        XCTAssertTrue(facts.contains("Started <t:1795002142:t> · ends <t:1795002289:R>"), "anything that ticks is a Discord timestamp")
        XCTAssertTrue(facts.contains("Usually lasts `2m 27s` · 3rd today"))
        let button = try XCTUnwrap((inner[4]["components"] as? [[String: Any]])?.first)
        XCTAssertEqual(button["style"] as? Int, 5, "link buttons only: a plain webhook cannot send interactive parts")
        XCTAssertEqual(button["label"] as? String, "Join server")
        XCTAssertNil(button["custom_id"])
        XCTAssertEqual(inner[5]["content"] as? String, "-# SiverSol v1.0 · Glitch Hunt")
    }

    func testJoinButtonOnlyOnAStartedBiomeAndOnlyWithALink() throws {
        for (name, message) in samples() {
            let card = try XCTUnwrap(message.sky)
            if name == "biome-started" || name == "rare-started" { XCTAssertEqual(card.button?.label, "Join server") } else { XCTAssertNil(card.button, name) }
        }
        XCTAssertNil(RichTemplates.biomeStarted(startedEvent("WINDY"), ctx(link: nil)).sky?.button, "no link saved, no button")
    }

    /// Hard rule 4: no private data in a card. The server is a short hash; the share code is only inside the Join button.
    func testNothingPrivateInCardsOrPictures() throws {
        let artist = LivingSkyArtist(catalog: catalog())
        for origin in [EventOrigin.live, .test] {
            for (name, message) in samples(origin: origin) {
                let card = try XCTUnwrap(message.sky)
                var drawn: [String] = []
                if let art = card.art {
                    if let t = art.thumb { drawn += artist.picture(thumb: t, art: art)?.text ?? [] }
                    if let c = art.card { drawn += artist.picture(card: c, art: art)?.text ?? [] }
                }
                for text in card.allText + drawn {
                    XCTAssertFalse(text.contains("code=abc123"), "\(name): the private server's share code is in the text")
                    XCTAssertFalse(text.contains("roblox.com/share"), "\(name): the private server link is in the text")
                    XCTAssertFalse(text.contains("2222-3333"), "\(name): more than the short server hash")
                    XCTAssertNil(text.range(of: #"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#, options: .regularExpression), "\(name): an IP address")
                    XCTAssertNil(text.range(of: #"(?i)user(name|id)|ticket"#, options: .regularExpression), "\(name): \(text)")
                }
                // (The connection test is a real message about a real webhook, not a made-up event.)
                if origin != .live, name != "connected", let art = card.art, art.card != nil { XCTAssertTrue(drawn.contains("PREVIEW"), "\(name): a test picture carries the Preview ribbon") }
            }
        }
    }

    func testPicturesAreTheRightSizeAndSmall() throws {
        let artist = LivingSkyArtist(catalog: catalog())
        for key in ["PUMPKIN MOON", "RAINY", "GLITCHED", "HEAVEN", "NULL"] {
            let art = SkyArt(thumb: .biome(key), card: .biome(key: key, eyebrow: "weather", title: catalog().info(for: BiomeKey(key)).display, line: "11:42 UTC · ends about 11:44 UTC"), hour: 22)
            let banner = try XCTUnwrap(artist.picture(card: art.card!, art: art), key)
            XCTAssertEqual(banner.width, 1100); XCTAssertEqual(banner.height, 400)
            XCTAssertLessThanOrEqual(banner.data.count, SkyCardArt.maxBytes, "\(key) banner is \(banner.data.count) bytes")
            let thumb = try XCTUnwrap(artist.picture(thumb: art.thumb!, art: art), key)
            XCTAssertEqual(thumb.width, 192)
            XCTAssertLessThanOrEqual(thumb.data.count, SkyCardArt.maxBytes)
        }
        let aura = SkyArt(thumb: .aura("Abyssal Hunter"), card: .aura(name: "Abyssal Hunter"))
        let card = try XCTUnwrap(artist.picture(card: aura.card!, art: aura))
        XCTAssertEqual(card.width, 600); XCTAssertEqual(card.height, 840)
        XCTAssertLessThanOrEqual(card.data.count, SkyCardArt.maxBytes, "aura card is \(card.data.count) bytes")
        XCTAssertTrue(card.text.contains("1 in 400,000,000"))
        XCTAssertNotNil(artist.picture(thumb: .symbol("cart.fill", 0x5B6E8C), art: SkyArt()))
    }

    // MARK: through the notifier

    private func body(_ call: MockDiscord.Call) throws -> [String: Any] {
        var data = call.body
        if let marker = data.range(of: Data("name=\"payload_json\"".utf8)),
           let start = data.range(of: Data("\r\n\r\n".utf8), in: marker.upperBound..<data.endIndex),
           let end = data.range(of: Data("\r\n--".utf8), in: start.upperBound..<data.endIndex) {
            data = data.subdata(in: start.upperBound..<end.lowerBound)
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func text(_ body: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
    }

    func testAStartedBiomeGoesOutAsACardWithItsPictures() async throws {
        let rig = await Rig(style: .skyCards)
        await rig.mesh.handle(.biomeStarted(startedEvent("PUMPKIN MOON")))
        _ = await rig.mesh.flush(timeout: 5)
        let post = try XCTUnwrap(rig.discord.posts.first)
        XCTAssertTrue(post.query.contains("with_components=true"))
        XCTAssertTrue(post.query.contains("wait=true"))
        let sent = try body(post)
        XCTAssertEqual(sent["flags"] as? Int, 32768)
        let raw = String(decoding: post.body, as: UTF8.self)
        XCTAssertTrue(raw.contains("filename=\"sky-thumb.png\""), "the glyph thumbnail is uploaded with the message")
        XCTAssertTrue(raw.contains("filename=\"sky-card."), "and so is the sky banner")
        XCTAssertTrue(text(sent).contains("attachment://sky-thumb.png"))
    }

    func testClassicStyleSendsTheV1Embed() async throws {
        let rig = await Rig(style: .classic)
        await rig.mesh.handle(.biomeStarted(startedEvent("PUMPKIN MOON")))
        _ = await rig.mesh.flush(timeout: 5)
        let post = try XCTUnwrap(rig.discord.posts.first)
        let sent = try body(post)
        XCTAssertNil(sent["flags"]); XCTAssertNil(sent["sky"])
        XCTAssertEqual(post.message?.embeds.first?.title, "🎃 PUMPKIN MOON started")
    }

    func testFallsBackToAClassicEmbedWhenDiscordRefusesTheCard() async throws {
        let rig = await Rig(style: .skyCards)
        rig.discord.fault = { call, _ in String(decoding: call.body, as: UTF8.self).contains("32768") ? (400, #"{"components":["0"]}"#) : nil }
        await rig.mesh.handle(.biomeStarted(startedEvent("PUMPKIN MOON")))
        _ = await rig.mesh.flush(timeout: 10)
        await rig.mesh.handle(.merchantArrived(MerchantArrived(id: "me1", name: "Mari", at: date("2026-11-18T11:43:00.000Z"), source: "log")))
        _ = await rig.mesh.flush(timeout: 10)
        let accepted = rig.discord.posts.filter { !String(decoding: $0.body, as: UTF8.self).contains("32768") }
        XCTAssertEqual(accepted.count, 2)
        let first = try body(accepted[0])
        let embed = try XCTUnwrap((first["embeds"] as? [[String: Any]])?.first)
        XCTAssertEqual(embed["title"] as? String, "Pumpkin Moon has started", "the same words as the card")
        XCTAssertEqual(embed["color"] as? Int, 0xFF8A1F, "the same colour")
        XCTAssertEqual((embed["image"] as? [String: Any])?["url"] as? String ?? "", try XCTUnwrap((embed["image"] as? [String: Any])?["url"] as? String))
        XCTAssertTrue(((embed["image"] as? [String: Any])?["url"] as? String ?? "").hasPrefix("attachment://sky-card."), "the same picture")
        XCTAssertEqual((embed["footer"] as? [String: Any])?["text"] as? String, "SiverSol v1.0 · Default")
        XCTAssertEqual(rig.discord.posts.filter { String(decoding: $0.body, as: UTF8.self).contains("32768") }.count, 1, "the card was tried once; later messages go classic straight away")
        XCTAssertEqual(rig.logs.all.filter { $0.contains("refused the Sky Cards layout") }.count, 1, "logged once")
        let routes = await rig.mesh.classicFallbackRoutes
        XCTAssertEqual(routes, ["test"])
    }

    func testAPingGoesOutFirstAsATinyClassicMessageAndTheCardMentionsNobody() async throws {
        let rig = await Rig(routes: [RouteConfig(name: "test", profile: .rich, pingsEnabled: true, pings: RouteConfig.defaultPings)], style: .skyCards)
        // A real, current rare biome.
        let ev = BiomeStarted(id: "g1", biome: BiomeRef(raw: "GLITCHED"), at: rig.clock.now, observedStart: true, wasRunning: false, serverJobId: longJobId, previous: "NORMAL")
        await rig.mesh.handle(.biomeStarted(ev))
        _ = await rig.mesh.flush(timeout: 5)
        XCTAssertEqual(rig.discord.posts.count, 2)
        let ping = try body(rig.discord.posts[0]), card = try body(rig.discord.posts[1])
        XCTAssertEqual(ping["content"] as? String, "@everyone Glitched has started")
        XCTAssertEqual((ping["allowed_mentions"] as? [String: Any])?["parse"] as? [String], ["everyone"], "exactly what the ping config asks for")
        XCTAssertNil(ping["flags"])
        XCTAssertEqual(card["flags"] as? Int, 32768)
        XCTAssertEqual((card["allowed_mentions"] as? [String: Any])?["parse"] as? [String], [], "the card itself pings nobody")
        XCTAssertFalse(text(card).contains("@everyone"))
        // The Started card, not the ping, is what the ledger points at (for edits and jump links).
        let ref = rig.store.ref(OutboxStore.ledgerKey(route: "test", eventId: "g1"))
        XCTAssertEqual(ref?.messageId, "1003", "the mock numbers its answers: 1001 the webhook lookup, 1002 the ping, 1003 the card")
    }

    func testNoPingWithoutTheSettingAndNeverFromATest() async throws {
        let quiet = await Rig(style: .skyCards)
        await quiet.mesh.handle(.biomeStarted(BiomeStarted(id: "g1", biome: BiomeRef(raw: "GLITCHED"), at: quiet.clock.now, observedStart: true, wasRunning: false, serverJobId: nil, previous: nil)))
        _ = await quiet.mesh.flush(timeout: 5)
        XCTAssertEqual(quiet.discord.posts.count, 1, "pings are off by default: only the card")

        let rig = await Rig(routes: [RouteConfig(name: "test", profile: .rich, pingsEnabled: true, pings: RouteConfig.defaultPings)], style: .skyCards)
        await rig.mesh.handle(.biomeStarted(BiomeStarted(id: "g2", biome: BiomeRef(raw: "GLITCHED"), at: rig.clock.now, observedStart: true, wasRunning: false, serverJobId: nil, previous: nil)), origin: .simulated)
        _ = await rig.mesh.flush(timeout: 5)
        XCTAssertEqual(rig.discord.posts.count, 1, "a simulated biome never pings")
        let card = try body(rig.discord.posts[0])
        XCTAssertTrue(text(card).contains("preview · simulated, not a real event"))
        XCTAssertFalse(text(card).contains("@everyone"))
    }

    func testAStartedCardIsEditedInPlaceWhenTheBiomeEnds() async throws {
        let rig = await Rig(style: .skyCards)
        await rig.mesh.handle(.biomeStarted(startedEvent("PUMPKIN MOON")))
        _ = await rig.mesh.flush(timeout: 5)
        rig.clock.advance(150)
        await rig.mesh.handle(.biomeEnded(endedEvent("PUMPKIN MOON")))
        _ = await rig.mesh.flush(timeout: 10)
        let patch = try XCTUnwrap(rig.discord.patches.first)
        XCTAssertTrue(patch.query.contains("with_components=true"))
        let edited = try body(patch)
        XCTAssertEqual(edited["flags"] as? Int, 32768, "an edit keeps the card form")
        let all = text(edited)
        XCTAssertTrue(all.contains("### Pumpkin Moon has ended"))
        XCTAssertTrue(all.contains("Lasted `2m 27s`"))
        XCTAssertTrue(all.contains("attachment://sky-thumb.png"), "the pictures the card was sent with stay")
        XCTAssertFalse(all.contains("Join server"), "the Join button is only for a biome that is on")
    }

    func testAMessageSentClassicIsEditedClassic() async throws {
        let rig = await Rig(style: .classic)
        await rig.mesh.handle(.biomeStarted(startedEvent("PUMPKIN MOON")))
        _ = await rig.mesh.flush(timeout: 5)
        rig.clock.advance(150)
        await rig.mesh.handle(.biomeEnded(endedEvent("PUMPKIN MOON")))
        _ = await rig.mesh.flush(timeout: 10)
        let edited = try body(try XCTUnwrap(rig.discord.patches.first))
        XCTAssertNil(edited["flags"])
    }

    func testTestContentNeverReachesAHuntRouteInEitherStyle() async throws {
        for style in MessageStyle.allCases {
            let rig = await Rig(routes: [RouteConfig(name: "test", profile: .rich), RouteConfig(name: "hunt", profile: .huntCompat)], style: style)
            await rig.mesh.handle(.biomeStarted(startedEvent("GLITCHED")), origin: .test)
            await rig.mesh.handle(.biomeStarted(startedEvent("GLITCHED", id: "s2")), origin: .simulated)
            _ = await rig.mesh.flush(timeout: 5)
            XCTAssertFalse(rig.discord.posts.contains { $0.path.contains("/222/") || $0.path.contains("hunt") }, "\(style)")
            for post in rig.discord.posts {
                XCTAssertFalse(String(decoding: post.body, as: UTF8.self).contains("Biome Started - "), "\(style): nothing a hunt bot would read")
            }
        }
    }

    func testConfigDefaultsToSkyCardsAndOldFilesStillLoad() throws {
        XCTAssertEqual(NotifyConfig.default.messageStyle, .skyCards)
        let old = try JSONDecoder().decode(NotifyConfig.self, from: Data(#"{"routes":[{"name":"main"}]}"#.utf8))
        XCTAssertEqual(old.messageStyle, .skyCards)
        let classic = try JSONDecoder().decode(NotifyConfig.self, from: Data(#"{"routes":[{"name":"main"}],"messageStyle":"classic"}"#.utf8))
        XCTAssertEqual(classic.messageStyle, .classic)
    }
}

/// Digest: ordinary biomes on a personal route become one "Biome feed" message an hour, edited in place.
final class DigestTests: XCTestCase {
    private func start(_ biome: String, _ id: String, at: Date) -> SiverEvent {
        .biomeStarted(BiomeStarted(id: id, biome: BiomeRef(raw: biome), at: at, observedStart: true, wasRunning: false, serverJobId: nil, previous: nil))
    }
    private func end(_ biome: String, _ id: String, started: Date, at: Date) -> SiverEvent {
        .biomeEnded(BiomeEnded(id: id + "-end", biome: BiomeRef(raw: biome), startedAt: started, at: at, startedEventId: id, startObserved: true, reason: .changed, next: nil, serverJobId: nil))
    }
    private func payloadText(_ call: MockDiscord.Call) -> String {
        var data = call.body
        if let marker = data.range(of: Data("name=\"payload_json\"".utf8)),
           let s = data.range(of: Data("\r\n\r\n".utf8), in: marker.upperBound..<data.endIndex),
           let e = data.range(of: Data("\r\n--".utf8), in: s.upperBound..<data.endIndex) { data = data.subdata(in: s.upperBound..<e.lowerBound) }
        return String(decoding: data, as: UTF8.self)
    }

    func testOrdinaryBiomesShareOneMessageThatIsEdited() async throws {
        var route = RouteConfig(name: "test", profile: .rich)
        route.digest = true
        for style in MessageStyle.allCases {
            let rig = await Rig(routes: [route, RouteConfig(name: "hunt", profile: .huntCompat)], style: style)
            await rig.mesh.setArtist(nil)
            let t0 = rig.clock.now
            await rig.mesh.handle(start("RAINY", "a", at: t0))
            _ = await rig.mesh.flush(timeout: 5)
            XCTAssertEqual(rig.discord.posts.filter { $0.path.contains("/111/") }.count, 1, "\(style): the first ordinary biome of the hour posts the feed")
            XCTAssertTrue(payloadText(rig.discord.posts.first { $0.path.contains("/111/") }!).contains("Biome feed"))

            rig.clock.advance(120)
            await rig.mesh.handle(batch: [end("RAINY", "a", started: t0, at: rig.clock.now), start("NORMAL", "b", at: rig.clock.now)])
            _ = await rig.mesh.flush(timeout: 10)
            rig.clock.advance(60)
            await rig.mesh.handle(start("WINDY", "c", at: rig.clock.now))
            _ = await rig.mesh.flush(timeout: 10)

            let mine = rig.discord.calls.filter { $0.path.contains("/111/") && $0.method != "GET" }
            XCTAssertEqual(mine.filter { $0.method == "POST" }.count, 1, "\(style): still one message for the hour")
            XCTAssertGreaterThanOrEqual(mine.filter { $0.method == "PATCH" }.count, 1, "\(style): and it is edited as biomes come and go")
            let last = payloadText(try XCTUnwrap(mine.last))
            XCTAssertTrue(last.contains("Rainy"), style.rawValue)
            XCTAssertTrue(last.contains("2m 0s"), "\(style): a finished biome shows how long it lasted")
            XCTAssertTrue(last.contains("Windy"), style.rawValue)
            XCTAssertFalse(mine.contains { payloadText($0).contains("RAINY started") || payloadText($0).contains("Rainy has started") }, "\(style): no message per ordinary biome")
            // The hunt route is never digested: it got every biome as its own v1.0 message.
            let hunt = rig.discord.posts.filter { $0.path.contains("/222/") }.compactMap { $0.message?.embeds.first?.title }
            XCTAssertEqual(hunt, ["Biome Started - RAINY", "Biome Started - NORMAL", "Biome Ended - RAINY", "Biome Started - WINDY"].filter { hunt.contains($0) })
            XCTAssertEqual(Set(hunt), ["Biome Started - RAINY", "Biome Started - NORMAL", "Biome Ended - RAINY", "Biome Started - WINDY"])
        }
    }

    func testRareBiomesStillGetTheirOwnMessage() async throws {
        var route = RouteConfig(name: "test", profile: .rich)
        route.digest = true
        let rig = await Rig(routes: [route], style: .classic)
        await rig.mesh.handle(start("RAINY", "a", at: rig.clock.now))
        await rig.mesh.handle(start("GLITCHED", "g", at: rig.clock.now))
        await rig.mesh.handle(.merchantArrived(MerchantArrived(id: "m", name: "Mari", at: rig.clock.now, source: "log")))
        _ = await rig.mesh.flush(timeout: 5)
        let titles = rig.discord.titles()
        XCTAssertTrue(titles.contains("🚨 GLITCHED STARTED"), "a rare biome is never folded into the feed")
        XCTAssertTrue(titles.contains("🛒 Mari arrived"))
        XCTAssertEqual(titles.filter { $0.contains("Biome feed") }.count, 1)
    }

    func testANewHourStartsANewMessage() async throws {
        var route = RouteConfig(name: "test", profile: .rich)
        route.digest = true
        let rig = await Rig(routes: [route], style: .classic)
        await rig.mesh.handle(start("RAINY", "a", at: rig.clock.now))
        _ = await rig.mesh.flush(timeout: 5)
        rig.clock.advance(3700)
        await rig.mesh.handle(start("WINDY", "b", at: rig.clock.now))
        _ = await rig.mesh.flush(timeout: 5)
        XCTAssertEqual(rig.discord.titles().filter { $0.contains("Biome feed") }.count, 2)
    }

    func testDigestIsOffByDefaultAndNeverOnAHuntRoute() {
        XCTAssertFalse(RouteConfig(name: "main", profile: .rich).digest)
        var hunt = RouteConfig(name: "hunt", profile: .huntCompat)
        hunt.digest = true
        XCTAssertFalse(hunt.digests("RAINY", isRare: false), "a hunt route sends every biome, whatever the switch says")
        var rich = RouteConfig(name: "main", profile: .rich)
        rich.digest = true
        XCTAssertTrue(rich.digests("RAINY", isRare: false))
        XCTAssertFalse(rich.digests("GLITCHED", isRare: true))
    }
}
