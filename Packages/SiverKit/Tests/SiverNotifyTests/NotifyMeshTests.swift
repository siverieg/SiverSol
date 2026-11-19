import XCTest
@testable import SiverCore
@testable import SiverNotify

final class NotifyMeshTests: XCTestCase {
    func testStartedThenEndedInterlinks() async {
        let rig = await Rig()
        let s = started("WINDY")
        await rig.mesh.handle(.biomeStarted(s))
        await rig.mesh.handle(.biomeEnded(ended("WINDY")))
        let ok = await rig.mesh.flush()
        XCTAssertTrue(ok)
        // GET info once (guild for jump links), POST started, POST ended, PATCH started (the edit is the least urgent).
        XCTAssertEqual(rig.discord.calls.map(\.method), ["GET", "POST", "POST", "PATCH"])
        XCTAssertTrue(rig.discord.posts.allSatisfy { $0.query.contains("wait=true") })
        XCTAssertTrue(rig.discord.posts[0].query.contains("with_components=true"))
        let startedRef = rig.store.ref("test|\(s.id)")
        XCTAssertEqual(startedRef?.guildId, "9001")
        XCTAssertEqual(rig.discord.patches[0].path, "/api/webhooks/111/test-token/messages/\(startedRef!.messageId)")
        XCTAssertEqual(rig.discord.patches[0].message?.embeds[0].title, "✅ WINDY · ended · lasted 2m 0s")
        XCTAssertEqual(rig.discord.posts[1].message?.embeds[0].fields?.first?.value,
                       "[↗ Started message](https://discord.com/channels/9001/5005/\(startedRef!.messageId))")
        XCTAssertEqual(rig.store.depth, 0)
        // An edit never lands within 2 s of the message being created (Discord can overwrite it).
        XCTAssertGreaterThanOrEqual(rig.discord.patches[0].at.timeIntervalSince(rig.discord.posts[0].at), 2)
    }

    func testBiomeChangeSendsTheNewBiomeFirstAndWithoutSpacing() async {
        let rig = await Rig()
        await rig.mesh.handle(.biomeStarted(started("NORMAL", at: "2026-11-18T11:40:00.000Z")))
        _ = await rig.mesh.flush()
        rig.clock.advance(120)
        let t0 = rig.clock.now
        // One log read: NORMAL ended and SNOWY started at the same instant, in the tracker's order.
        await rig.mesh.handle(batch: [.biomeEnded(ended("NORMAL", startedAt: "2026-11-18T11:40:00.000Z", at: "2026-11-18T11:42:00.000Z")),
                                      .biomeStarted(started("SNOWY", at: "2026-11-18T11:42:00.000Z"))])
        _ = await rig.mesh.flush()
        let after = rig.discord.calls.filter { $0.at >= t0 }
        XCTAssertEqual(after.map { "\($0.method) \($0.message?.embeds[0].title ?? "")" },
                       ["POST ❄️ SNOWY started", "POST ✅ NORMAL ended · 2m 0s", "PATCH ✅ NORMAL · ended · lasted 2m 0s"])
        XCTAssertEqual(after.map { $0.at.timeIntervalSince(t0) }, [0, 0, 0], "no artificial gap inside one biome change")
    }

    func testSameEventIsNeverSentTwiceEvenAfterRestart() async {
        let dir = tempDir()
        var rig = await Rig(directory: dir)
        await rig.mesh.handle(.biomeStarted(started("RAINY")))
        await rig.mesh.handle(.biomeStarted(started("RAINY")))
        _ = await rig.mesh.flush()
        XCTAssertEqual(rig.discord.posts.count, 1)
        // New process, same Application Support folder, same event from the startup scan.
        rig = await Rig(directory: dir)
        await rig.mesh.handle(.biomeStarted(started("RAINY", wasRunning: true)))
        _ = await rig.mesh.flush()
        XCTAssertEqual(rig.discord.posts.count, 0)
    }

    /// SPEC F2 acceptance: 50 events queued while offline are all delivered in order, rare first, with no 429 storm.
    func testFiftyQueuedOfflineThenDeliveredInOrderRareFirst() async {
        let dir = tempDir()
        var rig = await Rig(directory: dir)
        rig.discord.offline = true
        var expected: [String] = []
        for i in 0..<24 {
            let at = String(format: "2026-11-18T11:%02d:00.000Z", i)
            let end = String(format: "2026-11-18T11:%02d:30.000Z", i)
            await rig.mesh.handle(.biomeStarted(started("WINDY", at: at)))
            await rig.mesh.handle(.biomeEnded(ended("WINDY", startedAt: at, at: end)))   // patch + post
            expected += ["🌬️ WINDY started", "✅ WINDY ended · 30s"]
        }
        await rig.mesh.handle(.biomeStarted(started("GLITCHED", at: "2026-11-18T11:30:00.000Z")))
        await rig.mesh.handle(.biomeEnded(ended("GLITCHED", startedAt: "2026-11-18T11:30:00.000Z", at: "2026-11-18T11:32:44.000Z")))
        XCTAssertEqual(rig.store.depth, 24 * 3 + 3)
        let gaveUp = await rig.mesh.flush(timeout: 30)
        XCTAssertFalse(gaveUp, "offline: nothing can be delivered")
        XCTAssertEqual(rig.discord.calls.count, 0)
        XCTAssertEqual(rig.store.depth, 75)

        // The Mac sleeps, SiverSol restarts, Wi-Fi comes back. The queue is read back from disk.
        rig = await Rig(directory: dir)
        var throttled = 0
        rig.discord.fault = { call, index in
            // A greedy sender would trip this; ours must not send faster than the documented 5 per 2 s.
            return nil
        }
        let ok = await rig.mesh.flush(timeout: 600)
        XCTAssertTrue(ok)
        XCTAssertEqual(rig.store.depth, 0)
        let posts = rig.discord.titles("POST")
        XCTAssertEqual(Array(posts.prefix(2)), ["🚨 GLITCHED STARTED", "✅ GLITCHED ended · 2m 44s"], "rare lane goes first")
        XCTAssertEqual(Array(posts.dropFirst(2)), expected, "everything else in the order it happened")
        XCTAssertEqual(rig.discord.patches.count, 25)
        // Pacing: never more than 5 requests in any 2 s window, never more than 25 a minute.
        let times = rig.discord.calls.filter { $0.method != "GET" }.map(\.at)
        for (i, t) in times.enumerated() {
            let in2s = times[i...].prefix { $0.timeIntervalSince(t) < 2 }.count
            XCTAssertLessThanOrEqual(in2s, 5)
            let in60s = times[i...].prefix { $0.timeIntervalSince(t) < 60 }.count
            XCTAssertLessThanOrEqual(in60s, 25)
            if in2s > 5 { throttled += 1 }
        }
        XCTAssertEqual(throttled, 0)
    }

    func testHonors429RetryAfterAndThenContinuesInOrder() async {
        let rig = await Rig()
        rig.discord.fault = { call, index in
            (call.method == "POST" && index == 1) ? (429, #"{"message":"You are being rate limited.","retry_after":3.5,"global":false}"#) : nil
        }
        await rig.mesh.handle(.biomeStarted(started("WINDY", at: "2026-11-18T11:00:00.000Z")))
        await rig.mesh.handle(.biomeStarted(started("RAINY", at: "2026-11-18T11:05:00.000Z")))
        let ok = await rig.mesh.flush()
        XCTAssertTrue(ok)
        let posts = rig.discord.posts
        XCTAssertEqual(posts.compactMap { $0.message?.embeds.first?.title }, ["🌬️ WINDY started", "🌬️ WINDY started", "🌧️ RAINY started"])
        XCTAssertGreaterThanOrEqual(posts[1].at.timeIntervalSince(posts[0].at), 3.5, "waited what Discord asked for")
        XCTAssertEqual(rig.discord.calls.filter { $0.method == "POST" }.count, 3, "one retry, no storm")
    }

    func testServerErrorsBackOffExponentially() async {
        let rig = await Rig()
        rig.discord.fault = { call, index in (call.method == "POST" && index <= 4) ? (503, "{}") : nil }
        await rig.mesh.handle(.biomeStarted(started("WINDY")))
        let ok = await rig.mesh.flush()
        XCTAssertTrue(ok)
        let times = rig.discord.posts.map(\.at)
        XCTAssertEqual(times.count, 5)
        let gaps = zip(times.dropFirst(), times).map { $0.timeIntervalSince($1) }
        XCTAssertEqual(gaps.map { Int($0.rounded()) }, [1, 2, 4, 8])
    }

    func testDeadWebhookStopsTheRouteButKeepsItsQueue() async {
        let rig = await Rig(routes: [RouteConfig(name: "test", profile: .rich), RouteConfig(name: "hunt", profile: .huntCompat)])
        final class Flag: @unchecked Sendable { var value: (String, Int)? }
        let died = Flag()
        await rig.mesh.setRouteDiedHandler { died.value = ($0, $1) }
        rig.discord.fault = { call, _ in call.path.contains("/222/") ? (404, #"{"message":"Unknown Webhook","code":10015}"#) : nil }
        await rig.mesh.handle(.biomeStarted(started("WINDY")))
        let ok = await rig.mesh.flush(timeout: 20)
        XCTAssertFalse(ok)
        XCTAssertEqual(died.value?.0, "hunt"); XCTAssertEqual(died.value?.1, 404)
        XCTAssertEqual(rig.store.depth(route: "hunt"), 1)
        XCTAssertEqual(rig.store.depth(route: "test"), 0)
        let dead = await rig.mesh.deadRouteNames
        XCTAssertEqual(dead, ["hunt"])
        let before = rig.discord.calls.count
        await rig.mesh.handle(.biomeStarted(started("RAINY", at: "2026-11-18T11:50:00.000Z")))
        _ = await rig.mesh.flush(timeout: 20)
        XCTAssertEqual(rig.discord.calls.filter { $0.path.contains("/222/") }.count, rig.discord.calls.prefix(before).filter { $0.path.contains("/222/") }.count,
                       "a dead route is not hammered")
    }

    func testHuntRouteGetsPlainImmutableMessages() async {
        let rig = await Rig(routes: [RouteConfig(name: "hunt", profile: .huntCompat)])
        await rig.mesh.handle(.biomeStarted(started("NORMAL")))
        await rig.mesh.handle(.biomeEnded(ended("NORMAL")))
        await rig.mesh.handle(.auraEquipped(AuraEquipped(id: "a", internalName: "Enchanted", at: Date(), biome: nil, biomeEventId: nil, initial: false, serverJobId: nil)))
        _ = await rig.mesh.flush()
        XCTAssertEqual(rig.discord.titles(), ["Biome Started - NORMAL", "Biome Ended - NORMAL"])
        XCTAssertTrue(rig.discord.patches.isEmpty, "Hunt-Compat messages are never edited")
        XCTAssertFalse(rig.discord.posts[0].query.contains("with_components"))
        XCTAssertEqual(HuntFormat.serverLink(in: rig.discord.posts[0].message!), fakeLink)
        XCTAssertNil(HuntFormat.serverLink(in: rig.discord.posts[1].message!))
    }

    /// Hard rule 8, end to end: nothing simulated or replayed can reach a hunt route or look like a hunt message.
    func testSimulatedAndReplayedEventsNeverReachHuntRoutes() async {
        let rig = await Rig(routes: [RouteConfig(name: "test", profile: .rich, pingsEnabled: true, pings: ["GLITCHED": .everyone]),
                                     RouteConfig(name: "hunt", profile: .huntCompat, pingsEnabled: true, pings: ["GLITCHED": .everyone])])
        for origin in [EventOrigin.simulated, .replay, .test] {
            await rig.mesh.handle(.biomeStarted(started("GLITCHED", id: "x-\(origin.rawValue)")), origin: origin)
            await rig.mesh.handle(.biomeEnded(ended("GLITCHED", startId: "x-\(origin.rawValue)")), origin: origin)
        }
        // Even a hand-made message is refused off the test route, or if it would parse as a hunt event.
        let fake = DiscordMessage(embeds: [Embed(title: "Biome Started - GLITCHED")])
        let refused = await rig.mesh.post(fake, route: "hunt", id: "fake1", origin: .simulated)
        XCTAssertFalse(refused)
        await rig.mesh.post(fake, route: "test", id: "fake2", origin: .simulated)
        await rig.mesh.post(DiscordMessage(content: "@everyone", embeds: [Embed(title: "hi")], allowedMentions: .everyone), route: "test", id: "fake3", origin: .test)
        _ = await rig.mesh.flush()
        XCTAssertTrue(rig.discord.calls.allSatisfy { !$0.path.contains("/222/") }, "nothing went to the hunt webhook")
        for call in rig.discord.calls where call.method != "GET" {
            let m = call.message!
            XCTAssertFalse(HuntFormat.looksLikeHuntEvent(m), m.embeds[0].title ?? "")
            XCTAssertFalse(m.allowedMentions.pingsAnyone)
            XCTAssertNil(m.content.flatMap { $0.isEmpty ? nil : $0 })
            XCTAssertTrue(m.embeds[0].title?.hasPrefix("🧪") ?? false, m.embeds[0].title ?? "")
        }
        XCTAssertTrue(rig.logs.all.contains { $0.contains("rule 8") })
        XCTAssertTrue(rig.logs.all.contains { $0.contains("rule 9") })
        XCTAssertEqual(rig.store.depth, 0)
    }

    func testLiveRareBiomePingsOnlyWhereTurnedOnAndNotWhenStale() async {
        let rig = await Rig(routes: [RouteConfig(name: "test", profile: .rich),
                                     RouteConfig(name: "hunt", profile: .huntCompat, pingsEnabled: true, pings: ["GLITCHED": .everyone])])
        await rig.mesh.handle(.biomeStarted(started("GLITCHED", at: "2026-11-18T11:59:30.000Z")))   // 30 s old
        await rig.mesh.handle(.biomeStarted(started("GLITCHED", at: "2026-11-18T09:00:00.000Z")))   // 3 h old (was offline)
        _ = await rig.mesh.flush()
        let hunt = rig.discord.posts.filter { $0.path.contains("/222/") }.compactMap(\.message)
        let test = rig.discord.posts.filter { $0.path.contains("/111/") }.compactMap(\.message)
        XCTAssertEqual(hunt.map(\.content), ["@everyone", nil])
        XCTAssertEqual(hunt.map(\.allowedMentions), [.everyone, .none])
        XCTAssertTrue(test.allSatisfy { $0.content == nil && $0.allowedMentions == .none })
    }

    func testAuraRestoredOnJoinIsNotAnnounced() async {
        let rig = await Rig()
        func aura(_ name: String, initial: Bool) -> SiverEvent {
            .auraEquipped(AuraEquipped(id: "a-\(name)", internalName: name, at: Date(), biome: BiomeRef(raw: "NORMAL"), biomeEventId: nil, initial: initial, serverJobId: nil))
        }
        await rig.mesh.handle(aura("SeekerOfTheCrimsonMoon", initial: true))
        await rig.mesh.handle(aura("Enchanted", initial: false))
        _ = await rig.mesh.flush()
        XCTAssertEqual(rig.discord.titles(), ["✨ Enchanted"])
    }

    func testFallsBackToNoButtonIfDiscordRejectsComponents() async {
        let rig = await Rig()
        rig.discord.fault = { call, _ in (call.message?.components != nil) ? (400, #"{"message":"Invalid Form Body","code":50035}"#) : nil }
        await rig.mesh.handle(.biomeStarted(started("WINDY")))
        await rig.mesh.handle(.biomeStarted(started("RAINY", at: "2026-11-18T11:50:00.000Z")))
        let ok = await rig.mesh.flush()
        XCTAssertTrue(ok)
        XCTAssertEqual(rig.discord.posts.filter { $0.message?.components == nil }.compactMap { $0.message?.embeds.first?.title }, ["🌬️ WINDY started", "🌧️ RAINY started"])
        XCTAssertEqual(rig.discord.posts.count, 3, "one rejected try, then embeds only from then on")
    }

    func testForumRouteUsesOneThreadPerSession() async {
        let rig = await Rig(routes: [RouteConfig(name: "test", profile: .rich, endedMessages: false, sessionThreads: true)])
        await rig.mesh.setSession(key: "sess1", startedAt: date("2026-11-18T11:00:00.000Z"))
        await rig.mesh.handle(.biomeStarted(started("WINDY")))
        await rig.mesh.handle(.biomeEnded(ended("WINDY")))
        await rig.mesh.handle(.biomeStarted(started("RAINY", at: "2026-11-18T11:50:00.000Z")))
        _ = await rig.mesh.flush()
        XCTAssertEqual(rig.discord.posts[0].message?.threadName, "SiverSol session · 2026-11-18 11:00 UTC")
        XCTAssertFalse(rig.discord.posts[0].query.contains("thread_id"))
        XCTAssertTrue(rig.discord.patches[0].query.contains("thread_id=7777"))
        XCTAssertNil(rig.discord.posts[1].message?.threadName)
        XCTAssertTrue(rig.discord.posts[1].query.contains("thread_id=7777"))
    }

    func testLiveCardIsOneMessageEditedInPlace() async {
        let dir = tempDir()
        var rig = await Rig(directory: dir)
        var state = LiveCardState(sessionStartedAt: rig.clock.now, now: rig.clock.now)
        for i in 0..<5 {
            rig.clock.advance(60)
            state.now = rig.clock.now; state.outboxDepth = i
            let ok = await rig.mesh.upsertCard(RichTemplates.liveCard(state, catalog: catalog()), route: "test", metaKey: "card|s1")
            XCTAssertTrue(ok)
        }
        XCTAssertEqual(rig.discord.posts.count, 1)
        XCTAssertEqual(rig.discord.patches.count, 4)
        // Each edit carries the new state, not a copy of the first card.
        XCTAssertEqual(rig.discord.patches.map { $0.message?.embeds[0].fields?.last?.value }, (1...4).map { "thermal nominal · outbox \($0)" })
        XCTAssertEqual(Set(rig.discord.patches.compactMap { $0.message?.embeds[0].description }).count, 4)
        let cardId = rig.store.meta("card|s1")
        // A restarted SiverSol keeps editing the same card.
        rig = await Rig(directory: dir)
        _ = await rig.mesh.upsertCard(RichTemplates.liveCard(state, catalog: catalog()), route: "test", metaKey: "card|s1")
        XCTAssertEqual(rig.discord.posts.count, 0)
        XCTAssertEqual(rig.discord.patches.first?.path, "/api/webhooks/111/test-token/messages/\(cardId!)")
        // If someone deletes the card, a new one is made.
        rig.discord.fault = { call, _ in call.method == "PATCH" ? (404, #"{"message":"Unknown Message","code":10008}"#) : nil }
        _ = await rig.mesh.upsertCard(RichTemplates.liveCard(state, catalog: catalog()), route: "test", metaKey: "card|s1")
        XCTAssertEqual(rig.discord.posts.count, 1)
        XCTAssertNotEqual(rig.store.meta("card|s1"), cardId)
    }

    func testFileUploadUsesMultipartWithPayloadJSON() async throws {
        let rig = await Rig()
        let file = tempDir().appendingPathComponent("preview.json")
        try Data(#"{"hello":"world"}"#.utf8).write(to: file)
        await rig.mesh.post(RichTemplates.actionNeeded("look at the file", origin: .test), route: "test", id: "f1", origin: .test, files: [file.path])
        _ = await rig.mesh.flush()
        let call = try XCTUnwrap(rig.discord.posts.first)
        let body = String(decoding: call.body, as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"payload_json\""))
        XCTAssertTrue(body.contains("name=\"files[0]\"; filename=\"preview.json\""))
        XCTAssertTrue(body.contains(#"{"hello":"world"}"#))
        XCTAssertEqual(call.message?.embeds.first?.title, "🧪 TEST · ⚠️ Action needed")
    }

    func testRateLimiterBudget() {
        var l = RateLimiter()
        var now = date("2026-11-18T12:00:00.000Z")
        var sentAt: [Date] = []
        for _ in 0..<60 {
            now.addTimeInterval(l.delay(now: now))
            l.recordSuccess(now: now, info: RateLimitInfo(remaining: 4, resetAfter: 1))
            sentAt.append(now)
        }
        XCTAssertGreaterThanOrEqual(sentAt[25].timeIntervalSince(sentAt[0]), 60, "26th message waits for the minute window")
        l.recordSuccess(now: now, info: RateLimitInfo(remaining: 0, resetAfter: 7))
        XCTAssertGreaterThanOrEqual(l.delay(now: now), 7, "bucket exhausted: wait for the reset")
    }

    func testQuietHoursMuteThePingButNotTheMessage() async {
        // Quiet all day except for the exceptions: only the hour window matters, so use a 0 → 0-style full window.
        var config = NotifyConfig(routes: [RouteConfig(name: "test", profile: .rich, pingsEnabled: true,
                                                       pings: ["GLITCHED": .everyone, "CYBERSPACE": .everyone])], messageStyle: .classic)
        let hour = Calendar.current.component(.hour, from: VirtualClock().now)
        config.quietHours = QuietHours(enabled: true, startHour: hour, endHour: (hour + 1) % 24)
        let discord = MockDiscord(); let clock = VirtualClock(); discord.clock = clock
        let mesh = NotifyMesh(config: config, secrets: Secrets(discordWebhooks: ["test": fakeHook]), catalog: catalog(),
                              store: OutboxStore(directory: nil), transport: discord, environment: clock.environment)
        await mesh.handle(.biomeStarted(started("CYBERSPACE", at: "2026-11-18T11:59:50.000Z")))
        await mesh.handle(.biomeStarted(started("GLITCHED", at: "2026-11-18T11:59:55.000Z")))
        _ = await mesh.flush()
        let byTitle = Dictionary(uniqueKeysWithValues: discord.posts.compactMap { c in c.message.map { ($0.embeds[0].title ?? "", $0) } })
        XCTAssertNil(byTitle["🚨 CYBERSPACE STARTED"]?.content, "posted, but nobody is pinged in quiet hours")
        XCTAssertEqual(byTitle["🚨 CYBERSPACE STARTED"]?.allowedMentions, AllowedMentions.none)
        XCTAssertEqual(byTitle["🚨 GLITCHED STARTED"]?.content, "@everyone", "GLITCHED pings even in quiet hours")
        let stats = await mesh.routeStats()
        XCTAssertEqual(stats["test"]?.delivered, 2)
        XCTAssertEqual(stats["test"]?.rateLimited, 0)
    }

    func testRollFeedPostsOnRichRoutesWithItsShot() async throws {
        let rig = await Rig(routes: [RouteConfig(name: "test", profile: .rich), RouteConfig(name: "hunt", profile: .huntCompat)])
        let png = tempDir().appendingPathComponent("roll.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: png)
        let roll = AuraRolled(id: "roll1", name: "Symphony", at: rig.clock.now, captureDelayMs: 15000, durationS: 34.23, biome: BiomeRef(raw: "NORMAL"))
        await rig.mesh.handle(batch: [.auraRolled(roll)], attachments: ["roll1": [png.path]])
        _ = await rig.mesh.flush()
        XCTAssertEqual(rig.discord.posts.count, 1)
        XCTAssertTrue(rig.discord.posts[0].path.contains("/111/"))
        XCTAssertEqual(rig.discord.posts[0].message?.embeds[0].title, "🎉 Rolled Symphony")
        XCTAssertEqual(rig.discord.posts[0].message?.embeds[0].image?.url, "attachment://roll.png")
    }

    func testWebhookDoctor() async {
        let good = MockDiscord()
        let ok = await WebhookDoctor.examine(fakeHook, transport: good)
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(ok.webhookName, "SiverSol test")
        XCTAssertEqual(ok.channelURL?.absoluteString, "https://discord.com/channels/9001/5005")
        XCTAssertTrue(good.posts.isEmpty, "examining a webhook posts nothing")
        let shape = await WebhookDoctor.examine("https://example.com/hook", transport: good)
        XCTAssertFalse(shape.ok); XCTAssertNotNil(shape.problem)
        let empty = await WebhookDoctor.examine("   ", transport: good)
        XCTAssertFalse(empty.ok)
        let dead = MockDiscord(); dead.fault = { _, _ in (404, #"{"message":"Unknown Webhook","code":10015}"#) }
        let gone = await WebhookDoctor.examine(fakeHook, transport: dead)
        XCTAssertFalse(gone.ok)
        XCTAssertTrue(gone.problem?.contains("does not exist") ?? false)
        let off = MockDiscord(); off.offline = true
        let unreachable = await WebhookDoctor.examine(fakeHook, transport: off)
        XCTAssertTrue(unreachable.problem?.contains("Could not reach Discord") ?? false)
    }

    func testConnectionTestMessage() async throws {
        let rig = await Rig(routes: [RouteConfig(name: "main", profile: .rich, pingsEnabled: true, pings: RouteConfig.defaultPings),
                                     RouteConfig(name: "hunt", profile: .huntCompat)])
        let mesh = NotifyMesh(config: NotifyConfig(routes: await rig.mesh.config.routes, messageStyle: .classic),
                              secrets: Secrets(discordWebhooks: ["main": fakeHook, "hunt": fakeHuntHook]), catalog: catalog(),
                              store: OutboxStore(directory: nil), transport: rig.discord, environment: rig.clock.environment)
        let problem = await mesh.sendConnectionTest(route: "main")
        XCTAssertNil(problem)
        let m = try XCTUnwrap(rig.discord.posts.last?.message)
        XCTAssertEqual(m.embeds.count, 2)
        XCTAssertEqual(m.embeds[0].title, "✅ SiverSol is connected")
        XCTAssertTrue(m.embeds[0].description?.contains("<#5005>") ?? false, "Discord renders the channel mention as the channel's name")
        XCTAssertTrue(m.embeds[0].description?.contains("“SiverSol test”") ?? false)
        let fields = Dictionary(uniqueKeysWithValues: (m.embeds[0].fields ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(fields["Version"], "SiverSol v1.0.0")
        XCTAssertTrue(fields["This channel will get"]?.contains("**with a ping**") ?? false)
        XCTAssertTrue(fields["This channel will get"]?.contains("Merchants") ?? false)
        // The sample is marked SIMULATED, is not in hunt format, and nobody is pinged.
        XCTAssertTrue(m.embeds[1].title?.hasPrefix("🧪 SIMULATED · ") ?? false)
        XCTAssertTrue(m.embeds[1].description?.contains("Not a real biome") ?? false)
        XCTAssertEqual(m.allowedMentions, .none)
        XCTAssertNil(m.content)
        for i in 0..<2 {
            let alone = DiscordMessage(embeds: [m.embeds[i]])
            XCTAssertFalse(HuntFormat.looksLikeHuntEvent(alone)); XCTAssertNil(HuntFormat.extract(alone))
        }
        // Never to a hunt route, and nothing is posted when it is refused.
        let before = rig.discord.posts.count
        let refused = await mesh.sendConnectionTest(route: "hunt")
        XCTAssertTrue(refused?.contains("never sent to a Hunt-Compat route") ?? false)
        XCTAssertEqual(rig.discord.posts.count, before)
        XCTAssertTrue(rig.discord.calls.allSatisfy { !$0.path.contains("/222/") })
        let missing = await mesh.sendConnectionTest(route: "nope")
        XCTAssertNotNil(missing)
    }
}
