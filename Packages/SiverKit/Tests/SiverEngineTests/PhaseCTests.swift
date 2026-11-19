import XCTest
@testable import SiverCore
@testable import SiverEngine
@testable import SiverInput
@testable import SiverMacro
@testable import SiverNotify
@testable import SiverVision

private func d(_ iso: String) -> Date { try! Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(iso) }
private func events(_ lines: [(String, String)]) -> [SiverEvent] {
    var tracker = BiomeTracker(sessionId: "s"); var out: [SiverEvent] = []
    for (t, biome) in lines {
        let line = "\(t),1,0,6 [BloxstrapRPC] {\"command\":\"SetRichPresence\",\"data\":{\"state\":\"Equipped \\\"Enchanted\\\"\",\"largeImage\":{\"hoverText\":\"\(biome)\",\"assetId\":1}}}"
        if let e = LogLineParser.parse(line) { out += tracker.ingest(e) }
    }
    return out
}

final class BiomeIntelligenceTests: XCTestCase {
    func testStatsGapsStreaksAndDroughts() throws {
        let ev = events([("2026-11-18T10:00:00.000Z", "NORMAL"), ("2026-11-18T10:20:00.000Z", "PUMPKIN MOON"), ("2026-11-18T10:22:27.000Z", "NORMAL"),
                         ("2026-11-18T10:25:00.000Z", "PUMPKIN MOON"), ("2026-11-18T10:27:27.000Z", "NORMAL"), ("2026-11-18T10:30:00.000Z", "PUMPKIN MOON"),
                         ("2026-11-18T10:32:27.000Z", "NORMAL"), ("2026-11-18T10:40:00.000Z", "WINDY"), ("2026-11-18T10:42:00.000Z", "NORMAL")])
        let intel = BiomeIntel.compute(events: ev, now: d("2026-11-18T11:00:00.000Z"))
        let pumpkin = try XCTUnwrap(intel.stat("PUMPKIN MOON"))
        XCTAssertEqual(pumpkin.count, 3)
        XCTAssertEqual(pumpkin.totalSeconds, 441, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(pumpkin.averageGapSeconds), 300, accuracy: 0.01, "it came every five minutes")
        XCTAssertEqual(pumpkin.lastStartedAt, d("2026-11-18T10:30:00.000Z"))
        XCTAssertEqual(intel.longestNormalSeconds, 1200, accuracy: 0.01, "the opening 20 minutes of NORMAL")
        XCTAssertEqual(try XCTUnwrap(intel.currentNormalSeconds), 1080, accuracy: 0.01)
        XCTAssertEqual(intel.streakKey, "WINDY"); XCTAssertEqual(intel.streakCount, 1)
        XCTAssertEqual(intel.watchedSeconds, 3600, accuracy: 0.01)
        XCTAssertNil(intel.stat("WINDY")?.averageGapSeconds, "one start has no gap")
        let streak = BiomeIntel.compute(events: Array(ev.prefix(ev.count - 4)), now: d("2026-11-18T10:35:00.000Z"))
        XCTAssertEqual(streak.streakKey, "PUMPKIN MOON"); XCTAssertEqual(streak.streakCount, 3)
        XCTAssertEqual(BiomeIntel.compute(events: []).stats, [])
    }

    func testExportHasNoFullServerIdsAndValidShapes() throws {
        var ev = events([("2026-11-18T10:00:00.000Z", "NORMAL"), ("2026-11-18T10:20:00.000Z", "SAND STORM")])
        ev.append(.serverJoined(ServerJoined(id: "j", jobId: "abcdef01-2222-3333-4444-555555555555", placeId: 1, at: d("2026-11-18T09:59:00.000Z"))))
        ev.append(.auraRolled(AuraRolled(id: "r", name: "Sym, \"phony\"", at: d("2026-11-18T10:21:00.000Z"), durationS: 34.2)))
        let csv = TimelineExport.csv(ev)
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.first, "time_utc,event,name,seconds,note,server")
        XCTAssertEqual(lines.count, ev.count + 1)
        XCTAssertFalse(csv.contains("2222-3333"), "only the first 8 characters of a server id are exported")
        XCTAssertTrue(csv.contains("abcdef01"))
        XCTAssertTrue(csv.contains("\"Sym, \"\"phony\"\"\""), "commas and quotes are escaped")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: TimelineExport.json(ev)) as? [[String: String]])
        XCTAssertEqual(json.count, ev.count)
        XCTAssertEqual(json.first { $0["event"] == "biome_ended" }?["seconds"], "1200")
    }
}

final class ExtrasStateTests: XCTestCase {
    func testRollIsNotAnnouncedTwice() {
        let state = ExtraState()
        let rolledAt = d("2026-11-18T17:47:36.151Z")
        state.noteRoll("Symphony", at: rolledAt)
        XCTAssertTrue(state.wasJustRolled("Symphony", at: rolledAt.addingTimeInterval(4)), "the equip line 4 s later repeats the roll")
        XCTAssertTrue(state.wasJustRolled("symphony", at: rolledAt.addingTimeInterval(60)))
        XCTAssertFalse(state.wasJustRolled("Symphony", at: rolledAt.addingTimeInterval(600)), "equipping it again later is its own event")
        XCTAssertFalse(state.wasJustRolled("Enchanted", at: rolledAt.addingTimeInterval(4)))
        // Catalog-style key: the game's display name and internal name meet.
        state.noteRoll("Flushed : Pumpkinity", at: rolledAt)
        XCTAssertTrue(state.wasJustRolled(":Flushed:_Pumpkinity", at: rolledAt.addingTimeInterval(5)))
    }

    func testCutsceneLockHoldsEveryInputThroughGuardian() async {
        let state = ExtraState()
        let log = ActionLog(url: nil)
        let guardian = Guardian(log: log) { Guardian.Look(text: [], frameHash: 1) }
        guardian.hold = { state.cutsceneRemaining() > 0 ? "a roll cutscene is playing" : nil }
        var v = await guardian.approve(.key("space"))
        XCTAssertTrue(v.isApproved)
        state.lockForCutscene(until: Date().addingTimeInterval(34.23))
        XCTAssertEqual(state.cutsceneRemaining(), 34.23, accuracy: 0.5)
        for action in [GuardedAction.key("space"), .clickAnchor("Play")] {
            v = await guardian.approve(action)
            guard case .held(let reason) = v else { return XCTFail("\(action) went through during a cutscene") }
            XCTAssertTrue(reason.contains("cutscene"))
        }
        v = await guardian.approve(.escape)
        XCTAssertTrue(v.isApproved, "Escape is never held")
        XCTAssertEqual(log.entries.filter { $0.verdict == "held" }.count, 2)
        // A shorter lock never shortens a longer one.
        state.lockForCutscene(until: Date().addingTimeInterval(5))
        XCTAssertGreaterThan(state.cutsceneRemaining(), 30)
        XCTAssertEqual(state.cutsceneRemaining(now: Date().addingTimeInterval(40)), 0)
    }

    func testResourceSamplesAndCPU() {
        let state = ExtraState()
        let t = d("2026-11-18T12:00:00.000Z")
        XCTAssertEqual(state.addSample(pid: 10, memory: 3_221_225_472, cpuNs: 1e9, at: t).cpuPercent, 0, "first sample has no baseline")
        let second = state.addSample(pid: 10, memory: 4 * 1_073_741_824, cpuNs: 3.5e9, at: t.addingTimeInterval(5))
        XCTAssertEqual(second.cpuPercent, 50, accuracy: 0.01, "2.5 s of CPU in 5 s of wall time")
        XCTAssertEqual(second.memoryGB, 4, accuracy: 0.001)
        // A new process (rejoin) starts a new baseline instead of a negative reading.
        XCTAssertEqual(state.addSample(pid: 11, memory: 1, cpuNs: 0.2e9, at: t.addingTimeInterval(10)).cpuPercent, 0)
        for i in 0..<800 { _ = state.addSample(pid: 11, memory: 1, cpuNs: Double(i) * 1e9, at: t.addingTimeInterval(20 + Double(i) * 5)) }
        XCTAssertEqual(state.resourceSamples.count, 720, "one hour at 5 s is kept")
        XCTAssertTrue(state.raise("memory-high")); XCTAssertFalse(state.raise("memory-high")); state.lower("memory-high"); XCTAssertTrue(state.raise("memory-high"))
    }

    func testProcessStatsReadOurOwnProcess() throws {
        let usage = try XCTUnwrap(ProcessStats.usage(pid: getpid()))
        XCTAssertGreaterThan(usage.memory, 1_000_000)
        XCTAssertGreaterThan(usage.cpuNs, 0)
        XCTAssertNil(ProcessStats.usage(pid: 999_999))
    }

    func testNetworkTimelineBecomesIncidentSteps() {
        let net = NetworkSentinel()
        let t = d("2026-11-18T14:00:00.000Z")
        net.record(NetworkChange(at: t, online: true, interface: "Wi-Fi"))
        net.record(NetworkChange(at: t.addingTimeInterval(1), online: true, interface: "Wi-Fi"))   // no change: not recorded
        net.record(NetworkChange(at: t.addingTimeInterval(60), online: false, interface: "none"))
        net.record(NetworkChange(at: t.addingTimeInterval(180), online: true, interface: "Wi-Fi"))
        XCTAssertEqual(net.timeline.count, 3)
        XCTAssertTrue(net.isOnline)
        XCTAssertEqual(net.steps(from: t.addingTimeInterval(30), to: t.addingTimeInterval(300)).map(\.label), ["network dropped", "network back (Wi-Fi)"])
    }

    func testExtrasConfigDefaultsAndOldFiles() throws {
        let old = try JSONDecoder().decode(ExtrasConfig.self, from: Data(#"{"soundCue":true}"#.utf8))
        XCTAssertTrue(old.soundCue)
        XCTAssertTrue(old.auraRollFeed && old.cutsceneLock && old.freezeWatchdog && old.menuSentinel && old.resourceMonitor && old.windowGuard)
        XCTAssertFalse(old.dailyResetPing); XCTAssertFalse(old.memoryAutoRejoin)
        XCTAssertEqual(old.memoryAlertGB, 6)
        XCTAssertEqual(try JSONDecoder().decode(ExtrasConfig.self, from: JSONEncoder().encode(ExtrasConfig())), ExtrasConfig())
    }

    func testLiveCardShowsTheNewLines() {
        var s = LiveCardState(sessionStartedAt: d("2026-11-18T10:00:00.000Z"), now: d("2026-11-18T12:00:00.000Z"))
        s.sessionLine = "private server · joined <t:1:R> · client 0.745.100.7450979"
        s.resourceLine = "3.7 GB · 41% CPU"
        s.dailyResetAt = d("2026-11-19T00:00:00.000Z")
        s.lastRoll = "Symphony"
        let fields = Dictionary(uniqueKeysWithValues: (RichTemplates.liveCard(s, catalog: try! BiomeCatalog.bundled()).embeds[0].fields ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(fields["Session"], s.sessionLine)
        XCTAssertEqual(fields["Roblox process"], "3.7 GB · 41% CPU")
        XCTAssertEqual(fields["Daily reset"], "<t:1795046400:R>")
        XCTAssertEqual(fields["Last roll"], "🎉 Symphony")
    }
}

final class MomentsTests: XCTestCase {
    private let t0 = d("2026-11-18T17:47:36.000Z")
    private let catalog = try! BiomeCatalog.bundled()
    private let auras = AuraCatalog.bundled()
    private var on: ExtrasConfig { var x = ExtrasConfig(); x.moments = true; return x }

    func testMomentsAreOffUntilTurnedOn() {
        let roll = SiverEvent.auraRolled(AuraRolled(id: "r", name: "Symphony", at: t0, captureDelayMs: 15000, durationS: 34.23))
        XCTAssertNil(MomentPlan.plan(for: roll, extras: ExtrasConfig(), catalog: catalog, auras: auras, now: t0))
        XCTAssertFalse(ExtrasConfig().moments, "recording video is something the user turns on")
        XCTAssertFalse(ExtrasConfig().momentsUpload)
    }

    func testARollIsRecordedForTheWholeCutscene() throws {
        let roll = SiverEvent.auraRolled(AuraRolled(id: "r", name: "Symphony", at: t0, captureDelayMs: 15000, durationS: 34.23))
        let plan = try XCTUnwrap(MomentPlan.plan(for: roll, extras: on, catalog: catalog, auras: auras, now: t0.addingTimeInterval(0.5)))
        XCTAssertEqual(plan.kind, .roll)
        XCTAssertEqual(plan.title, "Rolled Symphony")
        XCTAssertEqual(plan.seconds, 33.73, accuracy: 0.01, "from now until the game's own clip length has passed")
        XCTAssertEqual(plan.eventId, "r")

        let noLength = SiverEvent.auraRolled(AuraRolled(id: "r2", name: "Symphony", at: t0))
        XCTAssertEqual(MomentPlan.plan(for: noLength, extras: on, catalog: catalog, auras: auras, now: t0)?.seconds, 12)
        let endless = SiverEvent.auraRolled(AuraRolled(id: "r3", name: "Symphony", at: t0, durationS: 900))
        XCTAssertEqual(MomentPlan.plan(for: endless, extras: on, catalog: catalog, auras: auras, now: t0)?.seconds, 60, "never longer than a minute")
        XCTAssertNil(MomentPlan.plan(for: roll, extras: on, catalog: catalog, auras: auras, now: t0.addingTimeInterval(33)), "a roll found when the cutscene is nearly over is not worth a clip")
    }

    func testARareBiomeGetsTwelveSecondsAndOrdinaryOnesNothing() throws {
        func started(_ key: String, wasRunning: Bool = false) -> SiverEvent {
            .biomeStarted(BiomeStarted(id: key, biome: BiomeRef(raw: key), at: t0, observedStart: true, wasRunning: wasRunning, serverJobId: nil, previous: nil))
        }
        let plan = try XCTUnwrap(MomentPlan.plan(for: started("GLITCHED"), extras: on, catalog: catalog, auras: auras, now: t0))
        XCTAssertEqual(plan.kind, .rareBiome)
        XCTAssertEqual(plan.seconds, 12)
        XCTAssertNil(MomentPlan.plan(for: started("RAINY"), extras: on, catalog: catalog, auras: auras, now: t0))
        XCTAssertNil(MomentPlan.plan(for: started("GLITCHED", wasRunning: true), extras: on, catalog: catalog, auras: auras, now: t0), "a biome that was already running is not a start")
        var noRares = on; noRares.momentsOnRareBiomes = false
        XCTAssertNil(MomentPlan.plan(for: started("GLITCHED"), extras: noRares, catalog: catalog, auras: auras, now: t0))
    }

    func testDirectorSavesTrimsAndDecidesAboutUploading() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("siversol-director-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MomentsStore(directory: dir, capBytes: 2500)
        try store.createDirectory()
        // An older clip that the new one will push out.
        let old = Moment(id: MomentsStore.baseName(kind: .roll, title: "Rolled Ruby", at: t0.addingTimeInterval(-3600)), kind: .roll, title: "Rolled Ruby",
                         detail: "", biome: nil, at: t0.addingTimeInterval(-3600), seconds: 8, bytes: 2000, eventId: nil)
        try Data(count: 2000).write(to: store.videoURL(old.id))
        try store.save(old)

        func director(bytes: Int, limit: Int?) -> MomentsDirector {
            MomentsDirector(store: store, uploadLimit: limit, window: { 42 }, record: { request in
                XCTAssertEqual(request.windowId, 42)
                XCTAssertEqual(request.masks, ProofShot.defaultMasks, "clips are masked like proof shots")
                try Data(count: bytes).write(to: request.output)
                return MomentRecorder.Result(url: request.output, seconds: request.seconds, bytes: bytes, frames: 10, width: 1280, height: 720)
            })
        }
        let plan = MomentPlan(kind: .roll, title: "Rolled Symphony", detail: "1 in 2,400,000", biome: "NORMAL", eventId: "r", at: t0, seconds: 8)
        let small = await director(bytes: 1000, limit: 1500).run(plan)
        let moment = try XCTUnwrap(small.moment)
        XCTAssertTrue(small.uploadable)
        XCTAssertEqual(small.trimmed.map(\.id), [old.id], "the oldest clip went to keep the folder under its cap")
        XCTAssertEqual(store.all().map(\.id), [moment.id])
        XCTAssertEqual(store.all().first?.eventId, "r")

        let big = await director(bytes: 2400, limit: 1500).run(MomentPlan(kind: .rareBiome, title: "GLITCHED", detail: "rare biome", biome: "GLITCHED", eventId: "b", at: t0.addingTimeInterval(60), seconds: 12))
        XCTAssertNotNil(big.moment)
        XCTAssertFalse(big.uploadable, "too large for Discord: it stays on the Mac")
        let off = await director(bytes: 10, limit: nil).run(MomentPlan(kind: .roll, title: "Rolled Wind", detail: "", biome: nil, eventId: "c", at: t0.addingTimeInterval(120), seconds: 8))
        XCTAssertFalse(off.uploadable, "uploads are off unless the user turned them on")

        let noWindow = await MomentsDirector(store: store, uploadLimit: nil, window: { nil }, record: { _ in throw CaptureError.failed("x") }).run(plan)
        XCTAssertNil(noWindow.moment)
        XCTAssertNotNil(noWindow.problem)
    }

    func testMomentMessageNeverPingsAndSaysWhereTheClipIs() async {
        let moment = Moment(id: "Moment-x", kind: .roll, title: "Rolled Symphony", detail: "1 in 2,400,000", biome: "NORMAL", at: t0, seconds: 34, bytes: 14_000_000, eventId: "r")
        let route = RouteConfig(name: "main", profile: .rich)
        let ctx = RenderContext(catalog: catalog, route: route, origin: .live)
        let kept = RichTemplates.moment(moment, ctx, hasVideo: false, stillFileName: "Moment-x.jpg")
        XCTAssertEqual(kept.allowedMentions, AllowedMentions.none)
        XCTAssertTrue(kept.embeds[0].description?.contains("saved on this Mac") == true)
        XCTAssertEqual(kept.embeds[0].image?.url, "attachment://Moment-x.jpg")
        let sent = RichTemplates.moment(moment, ctx, hasVideo: true, stillFileName: nil)
        XCTAssertTrue(sent.embeds[0].description?.contains("attached") == true)
        XCTAssertTrue(RichTemplates.moment(moment, RenderContext(catalog: catalog, route: route, origin: .test), hasVideo: true, stillFileName: nil).embeds[0].title?.hasPrefix("🧪") == true)
    }
}

final class ProfileTests: XCTestCase {
    private func base() -> (NotifyConfig, ExtrasConfig, ProfileToggles) {
        var hunt = RouteConfig(name: "hunt", profile: .huntCompat, enabled: false, includeNormal: false)
        hunt.pingsEnabled = true
        let main = RouteConfig(name: "main", profile: .rich, pings: RouteConfig.defaultPings)
        return (NotifyConfig(routes: [main, hunt]), ExtrasConfig(), ProfileToggles(antiAFK: false, rejoin: false, island: .everything))
    }

    func testGlitchHuntMode() {
        var (config, extras, toggles) = base()
        Profiles.apply(Profiles.glitchHunt, to: &config, extras: &extras, toggles: &toggles)
        let hunt = config.route("hunt")!, main = config.route("main")!
        XCTAssertTrue(hunt.enabled, "Hunt-Compat on")
        XCTAssertTrue(hunt.includeNormal, "with NORMAL included, so hunt bots see the macro is alive")
        XCTAssertEqual(hunt.profile, .huntCompat)
        XCTAssertFalse(hunt.digest, "a hunt route is never digested")
        XCTAssertTrue(main.pingsEnabled)
        XCTAssertEqual(extras.macroPolicy, .stayInServer, "macros that could leave the server are blocked")
        XCTAssertTrue(toggles.rejoin); XCTAssertTrue(toggles.antiAFK)
        XCTAssertTrue(extras.freezeWatchdog && extras.menuSentinel, "the most reliable rejoin")
        XCTAssertTrue(extras.moments && extras.momentsOnRareBiomes, "Moments on for rare biomes")
        XCTAssertFalse(extras.momentsOnRolls)
        XCTAssertEqual(toggles.island, .always)
        XCTAssertEqual(config.profileName, "Glitch Hunt", "the name every card's footer shows")
    }

    func testSwitchingProfilesChangesOnlyWhatAProfileCovers() {
        var (config, extras, toggles) = base()
        extras.memoryAlertGB = 9
        config.liveCardRoute = "main"
        Profiles.apply(Profiles.afkGrind, to: &config, extras: &extras, toggles: &toggles)
        XCTAssertEqual(config.profileName, "AFK Grind")
        XCTAssertTrue(config.route("main")!.digest)
        XCTAssertFalse(config.route("main")!.pingsEnabled)
        XCTAssertEqual(extras.macroPolicy, .all)
        XCTAssertEqual(extras.memoryAlertGB, 9, "a setting no profile covers is left alone")
        XCTAssertEqual(config.liveCardRoute, "main")
        XCTAssertFalse(config.route("hunt")!.enabled, "AFK Grind says nothing about hunt routes, so they stay as they were")

        Profiles.apply(Profiles.quietNight, to: &config, extras: &extras, toggles: &toggles)
        XCTAssertEqual(config.profileName, "Quiet Night")
        XCTAssertTrue(config.quietHours.enabled)
        XCTAssertEqual(config.quietHours.startHour, 22); XCTAssertEqual(config.quietHours.endHour, 8)
        XCTAssertEqual(toggles.island, .off)
        XCTAssertFalse(extras.moments)
        XCTAssertTrue(config.route("main")!.pingsEnabled, "rare biomes still ping (outside quiet hours, or if they are exceptions)")

        Profiles.apply(Profiles.glitchHunt, to: &config, extras: &extras, toggles: &toggles)
        XCTAssertFalse(config.quietHours.enabled, "Glitch Hunt turns quiet hours off again")
        XCTAssertEqual(toggles.island, .always)
    }

    func testACustomProfileRestoresExactlyWhatWasSaved() {
        var (config, extras, toggles) = base()
        extras.moments = true; extras.macroPolicy = .none; toggles.island = .off
        config.quietHours.enabled = true; config.quietHours.startHour = 1
        let mine = Profiles.capture(name: "Mine", config: config, extras: extras, toggles: toggles)
        Profiles.apply(Profiles.glitchHunt, to: &config, extras: &extras, toggles: &toggles)
        Profiles.apply(mine, to: &config, extras: &extras, toggles: &toggles)
        XCTAssertEqual(config.profileName, "Mine")
        XCTAssertTrue(extras.moments); XCTAssertEqual(extras.macroPolicy, .none); XCTAssertEqual(toggles.island, .off)
        XCTAssertTrue(config.quietHours.enabled); XCTAssertEqual(config.quietHours.startHour, 1)
        XCTAssertFalse(config.route("hunt")!.enabled)
        XCTAssertFalse(toggles.rejoin)
        // Saved profiles survive the settings file.
        extras.profiles = [mine]
        let back = try! JSONDecoder().decode(ExtrasConfig.self, from: JSONEncoder().encode(extras))
        XCTAssertEqual(back.profiles, [mine])
        XCTAssertEqual(Profiles.all(custom: [mine, Profile(name: "Glitch Hunt", symbol: "x", summary: "", settings: ProfileSettings())]).map(\.name),
                       ["Glitch Hunt", "AFK Grind", "Quiet Night", "Mine"], "a saved profile cannot replace a built-in one")
    }

    func testMacrosThatCouldLeaveTheServerAreBlockedInGlitchHunt() {
        let walk = Macro(name: "walk", steps: [MacroStep(delay: 0, .keyDown(code: 13)), MacroStep(delay: 1, .keyUp(code: 13))])
        let menu = Macro(name: "menu", steps: [MacroStep(delay: 0, .keyDown(code: 53)), MacroStep(delay: 0.1, .keyUp(code: 53))])
        let click = Macro(name: "click", steps: [MacroStep(delay: 0, .mouseDown(button: .left, x: 0.5, y: 0.5)), MacroStep(delay: 0.1, .mouseUp(button: .left, x: 0.5, y: 0.5))])
        XCTAssertNil(MacroRules.couldLeaveServer(walk))
        XCTAssertNotNil(MacroRules.couldLeaveServer(menu), "Escape opens Roblox's menu")
        XCTAssertNotNil(MacroRules.couldLeaveServer(click), "a click can land on a button")
        XCTAssertNil(MacroRules.refusal(walk, policy: .stayInServer))
        XCTAssertTrue(MacroRules.refusal(menu, policy: .stayInServer)?.contains("Escape") ?? false)
        XCTAssertNotNil(MacroRules.refusal(click, policy: .stayInServer))
        XCTAssertNil(MacroRules.refusal(click, policy: .all))
        XCTAssertNotNil(MacroRules.refusal(walk, policy: .none))
    }

    func testHuntCoverage() {
        let store = TimelineStore(directory: nil)
        let now = d("2026-11-18T12:00:00.000Z")
        func add(_ biome: String, _ at: String, _ id: String) {
            store.record(.biomeStarted(BiomeStarted(id: id, biome: BiomeRef(raw: biome), at: d(at), observedStart: true, wasRunning: false, serverJobId: nil, previous: nil)))
        }
        add("NORMAL", "2026-11-18T08:00:00.000Z", "a")
        add("RAINY", "2026-11-18T10:00:00.000Z", "b")
        add("NORMAL", "2026-11-17T20:00:00.000Z", "c")
        store.record(.biomeEnded(BiomeEnded(id: "c-end", biome: BiomeRef(raw: "NORMAL"), startedAt: d("2026-11-17T20:00:00.000Z"), at: d("2026-11-17T22:00:00.000Z"),
                                            startedEventId: "c", startObserved: true, reason: .sessionEnded, next: nil, serverJobId: nil)))
        let coverage = HuntCoverage.compute(timeline: store, now: now, isRare: { _ in false })
        XCTAssertEqual(coverage.todaySeconds, 4 * 3600, accuracy: 60, "watching since 08:00")
        XCTAssertEqual(coverage.weekSeconds, 6 * 3600, accuracy: 60, "plus two hours yesterday")
        XCTAssertEqual(HuntCoverage(todaySeconds: 6 * 3600 + 12 * 60, weekSeconds: 31 * 3600 + 5 * 60).line, "6h 12m today · 31h 5m this week")
    }
}
