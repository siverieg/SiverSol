import Foundation
import SiverCore
import SiverEngine
import SiverNotify
import SiverInput
import SiverVision

/// Everything a notify command needs. Posting commands use an in-memory outbox so they never mix with the app's queue.
struct NotifyRig {
    let config: NotifyConfig
    let secrets: Secrets
    let catalog: BiomeCatalog
    let store: OutboxStore
    let mesh: NotifyMesh
    /// The Rich route that test, simulated and replayed messages go to.
    var testRoute: String {
        guard let name = config.testRouteName else { fail("no Rich route that accepts test messages in the config") }
        return name
    }

    static func make() async -> NotifyRig {
        let secrets: Secrets
        do { secrets = try ConfigLocator.loadSecrets() }
        catch { fail("cannot load Config/secrets.local.json (run from the repo, or set SIVERSOL_SECRETS): \(error.localizedDescription)") }
        let config = ConfigLocator.loadConfig()
        let catalog = loadCatalog(learn: false)
        let store = OutboxStore(directory: nil)
        let mesh = NotifyMesh(config: config, secrets: secrets, catalog: catalog, store: store)
        await mesh.setLogger { print("  mesh: \($0)") }
        await mesh.setSession(key: "ctl\(Int(Date().timeIntervalSince1970))", startedAt: Date())
        return NotifyRig(config: config, secrets: secrets, catalog: catalog, store: store, mesh: mesh)
    }

    /// Flush and report. Prints message ids, never URLs.
    func finish(_ label: String, expect ids: [String] = []) async {
        let ok = await mesh.flush(timeout: 180)
        let sent = await mesh.sentCount
        print("\(label): \(sent) requests delivered, \(store.depth) left in queue\(ok ? "" : "  (NOT all delivered)")")
        for id in ids {
            if let ref = store.ref(OutboxStore.ledgerKey(route: testRoute, eventId: id)) {
                print("  \(id) -> message \(ref.messageId)\(ref.jumpURL.map { "  \($0)" } ?? "")")
            }
        }
        if !ok { exit(1) }
    }
}

func webhookInfo() async {
    let rig = await NotifyRig.make()
    for route in rig.config.routes {
        guard let url = rig.secrets.webhook(route.name) else {
            print("\(route.name): no valid webhook in secrets (\(route.profile.rawValue))"); continue
        }
        do {
            let info = try await rig.mesh.webhookInfo(route: route.name)
            print("\(route.name): \(route.profile.rawValue) · \(url.redacted) · name \"\(info.name ?? "?")\" · guild \(info.guildId ?? "?") · channel \(info.channelId ?? "?") · pings \(route.pingsEnabled ? "ON" : "off")")
        } catch {
            print("\(route.name): \(url.redacted) · ERROR \(error)")
        }
    }
    print("private server link: \(rig.secrets.serverLink == nil ? "missing or not a roblox.com URL" : "present")")
}

/// F13 `webhook test-all`: every template, marked TEST, to the test route only.
func webhookTestAll(cardOnly: Bool = false) async {
    let rig = await NotifyRig.make()
    let route = rig.testRoute
    guard let ctx = await rig.mesh.renderContext(route: route, origin: .test) else { fail("no '\(route)' route in config") }
    let now = Date()
    let run = "t\(Int(now.timeIntervalSince1970))"
    func at(_ secondsAgo: TimeInterval) -> Date { now.addingTimeInterval(-secondsAgo) }

    if !cardOnly {
    // 1–4: biome lifecycle through the real event path (post, edit, link).
    let windy = BiomeStarted(id: "\(run)|windy", biome: BiomeRef(raw: "WINDY"), at: at(120), observedStart: true, wasRunning: false,
                             serverJobId: "00000000-test", previous: "NORMAL")
    let windyEnd = BiomeEnded(id: "\(run)|windy-end", biome: windy.biome, startedAt: windy.at, at: now, startedEventId: windy.id,
                              startObserved: true, reason: .changed, next: "NORMAL", serverJobId: windy.serverJobId)
    let rare = BiomeStarted(id: "\(run)|rare", biome: BiomeRef(raw: "GLITCHED"), at: at(5), observedStart: true, wasRunning: false,
                            serverJobId: "00000000-test", previous: "NORMAL")
    let aura = AuraEquipped(id: "\(run)|aura", internalName: "SeekerOfTheCrimsonMoon", at: now, biome: windy.biome,
                            biomeEventId: windy.id, initial: false, serverJobId: windy.serverJobId)
    let newBiome = NewBiomeSeen(id: "\(run)|new", biome: BiomeRef(raw: "GargantuaBiome", assetId: 3), at: now)
    await rig.mesh.handle(.biomeStarted(windy), origin: .test)
    await rig.mesh.handle(.auraEquipped(aura), origin: .test)
    await rig.mesh.handle(.biomeEnded(windyEnd), origin: .test)
    await rig.mesh.handle(.biomeStarted(rare), origin: .test)
    await rig.mesh.handle(.newBiomeSeen(newBiome), origin: .test)

    // 5–9: status-style templates.
    await rig.mesh.post(RichTemplates.merchant(MerchantArrived(id: "\(run)|mari", name: "Mari", at: now, biome: windy.biome, biomeEventId: windy.id), ctx),
                        route: route, id: "\(run)|merchant", origin: .test)
    await rig.mesh.post(RichTemplates.incident(IncidentReport(id: "\(run)|inc", cause: "Disconnected", steps: [
        .init("detected (reason 277)", at: at(100)), .init("quit Roblox", at: at(95)), .init("launched private server", at: at(80)),
        .init("joined server", at: at(30)), .init("in game", at: now)], recovered: true), ctx), route: route, id: "\(run)|incident", origin: .test)
    await rig.mesh.post(RichTemplates.buildLog(phase: "Phase N", done: ["first thing", "second thing"], next: "the next phase",
                                               needsYou: ["nothing, this is a template test"], origin: .test), route: route, id: "\(run)|buildlog", origin: .test)
    await rig.mesh.post(RichTemplates.actionNeeded("Nothing. This is a template test.", detail: "What a real request for your hands looks like.", origin: .test),
                        route: route, id: "\(run)|needs", origin: .test)
    await rig.mesh.post(RichTemplates.dailyReport(DailyReport(day: TimelineStore.day(now), counts: ["NORMAL": 14, "WINDY": 5, "PUMPKIN MOON": 6, "STARFALL": 1],
                                                              seconds: ["NORMAL": 2400, "WINDY": 600, "PUMPKIN MOON": 880, "STARFALL": 600],
                                                              rares: [], uptimeS: 4480, auras: 2), ctx), route: route, id: "\(run)|daily", origin: .test)
    // 10: the simulated-biome format from hard rule 8.
    await rig.mesh.post(RichTemplates.simulated(biome: "GLITCHED", ctx), route: route, id: "\(run)|sim", origin: .simulated)

    // 11: Hunt-Compat is never posted as a message here (rule 8). Its exact JSON goes up as a file instead.
    let huntRoute = RouteConfig(name: "hunt", profile: .huntCompat, pingsEnabled: true, pings: ["GLITCHED": .everyone])
    let huntCtx = RenderContext(catalog: rig.catalog, route: huntRoute, origin: .live, serverLink: "https://www.roblox.com/share?code=EXAMPLE&type=Server")
    let previews: [String: DiscordMessage?] = [
        "started_normal_biome": HuntTemplates.biomeStarted(windy, huntCtx),
        "ended_normal_biome": HuntTemplates.biomeEnded(windyEnd, huntCtx),
        "started_rare_biome_pings_on": HuntTemplates.biomeStarted(rare, huntCtx),
    ]
    var preview = "{\n"
    preview += previews.sorted { $0.key < $1.key }.map { "  \"\($0.key)\": " + String(decoding: ($0.value ?? DiscordMessage()).json(pretty: true), as: UTF8.self).replacingOccurrences(of: "\n", with: "\n  ") }.joined(separator: ",\n")
    preview += "\n}\n"
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("siversol-ctl-\(run)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("hunt-compat-preview.json")
    try? Data(preview.utf8).write(to: file)
    let note = DiscordMessage(username: RichTemplates.username,
                              embeds: [Embed(title: "🧪 TEST · Hunt-Compat preview (file attached)",
                                             description: "The exact JSON a `hunt-compat` route would send is in the attached file. It is not posted as a message, because nothing simulated may ever look like a real hunt event (rule 8).",
                                             color: 0x5865F2, timestamp: now)], allowedMentions: .none)
    await rig.mesh.post(note, route: route, id: "\(run)|hunt-preview", origin: .test, files: [file.path])

    await rig.finish("test-all", expect: [windy.id, windyEnd.id, rare.id, aura.id, newBiome.id, "\(run)|merchant", "\(run)|incident",
                                          "\(run)|buildlog", "\(run)|needs", "\(run)|daily", "\(run)|sim", "\(run)|hunt-preview"])

    try? FileManager.default.removeItem(at: dir)
    }
    // 12: live card: post, then edit the same message once.
    var state = LiveCardState(sessionStartedAt: at(3600), now: now)
    state.biome = BiomeRef(raw: "STARFALL"); state.biomeSince = at(150); state.biomeStartObserved = true
    state.todayCounts = ["NORMAL": 14, "WINDY": 5, "PUMPKIN MOON": 6, "STARFALL": 1]
    state.lastAura = "Enchanted"; state.lastAuraAt = at(900); state.serverJobId = "00000000-test"
    var card = RichTemplates.liveCard(state, catalog: rig.catalog)
    card.embeds[0].title = "🧪 TEST · " + (card.embeds[0].title ?? "")
    let posted = await rig.mesh.upsertCard(card, route: route, metaKey: "card|\(run)")
    state.now = Date(); state.outboxDepth = 0
    card = RichTemplates.liveCard(state, catalog: rig.catalog)
    card.embeds[0].title = "🧪 TEST · " + (card.embeds[0].title ?? "") + " (edited once)"
    let edited = await rig.mesh.upsertCard(card, route: route, metaKey: "card|\(run)")
    print("live card: posted=\(posted) edited=\(edited) message \(rig.store.meta("card|\(run)") ?? "?")")
    if !(posted && edited) { exit(1) }
}

/// Post a Build Log or Action needed embed to the test route (the builder's progress channel).
func postStatus(kind: String, phase: String, done: [String], next: String, needs: [String], detail: String?, title: String? = nil, files: [String] = []) async {
    let rig = await NotifyRig.make()
    let id = "\(kind)\(Int(Date().timeIntervalSince1970))"
    var message = kind == "needs"
        ? RichTemplates.actionNeeded(needs.joined(separator: "\n"), detail: detail)
        : RichTemplates.buildLog(phase: phase, done: done, next: next, needsYou: needs)
    if let title, !message.embeds.isEmpty { message.embeds[0].title = title }
    await rig.mesh.post(message, route: rig.testRoute, id: id, files: files)
    await rig.finish(kind, expect: [id])
}

/// F12: build the daily report for a UTC day from the real timeline, render the chart, optionally post it marked TEST.
func dailyReportCommand(day: String?, post: Bool) async {
    let secrets = (try? ConfigLocator.loadSecrets()) ?? Secrets()
    var options = SiverEngine.Options()
    options.liveCard = false
    guard let engine = try? SiverEngine(config: ConfigLocator.loadConfig(), secrets: secrets, options: options) else { fail("cannot set up the engine") }
    let day = day ?? TimelineStore.day(Date())
    let report = engine.dailyReport(day: day)
    print("Daily report \(day): \(report.counts.values.reduce(0, +)) biome starts, watched \(DiscordTime.duration(report.uptimeS)), \(report.auras) auras, \(report.merchants ?? 0) merchants, rares: \(report.rares.isEmpty ? "none" : report.rares.joined(separator: ", "))")
    for (key, n) in report.counts.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }) {
        print("  \(engine.catalog.info(for: BiomeKey(key)).emoji) \(key) × \(n)  \(DiscordTime.duration(report.seconds[key] ?? 0))")
    }
    guard !report.counts.isEmpty else { print("No events recorded for \(day)."); return }
    let chart = await engine.renderDailyChart(report)
    if let chart {
        let copy = artifactsDir().appendingPathComponent("daily-\(day).png")
        try? FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: copy)
        try? FileManager.default.copyItem(atPath: chart, toPath: copy.path)
        print("chart: \(copy.path)")
    } else {
        print("chart: could not be rendered")
    }
    if post {
        let rig = await NotifyRig.make()
        guard let ctx = await rig.mesh.renderContext(route: rig.testRoute, origin: .test) else { fail("no test route") }
        let id = "dailytest\(Int(Date().timeIntervalSince1970))"
        await rig.mesh.post(RichTemplates.dailyReport(report, ctx, chartFileName: chart.map { URL(fileURLWithPath: $0).lastPathComponent }),
                            route: rig.testRoute, id: id, origin: .test, files: chart.map { [$0] } ?? [])
        await rig.finish("daily report (TEST)", expect: [id])
    }
}

/// Phase 7 soak check: compare what SiverSol recorded and delivered with an independent scan of the same Roblox logs.
func audit(since sinceArg: String?, post: Bool) async {
    let support = SiverSol.supportDirectory
    let store = OutboxStore(directory: support.appendingPathComponent("outbox", isDirectory: true))
    let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    var since: Date
    if let sinceArg {
        guard let d = (try? iso.parse(sinceArg)) ?? (try? Date.ISO8601FormatStyle().parse(sinceArg)) else { fail("--since wants an ISO time like 2026-11-18T15:00:00Z", code: 2) }
        since = d
    } else if let started = store.meta("session.startedAt").flatMap(TimeInterval.init) {
        since = Date(timeIntervalSince1970: started)
    } else {
        fail("no session on record; pass --since")
    }
    let until = Date()

    // 1. Independent side: plain text scan of every Player log launched since the day before.
    var expected: [(ms: Int64, biome: String)] = []
    for log in LogDiscovery.playerLogs(in: SiverSol.logsDirectory).reversed() where log.launchedAt > since.addingTimeInterval(-86400) {
        for t in grepTransitionsTimed(readLog(log.url.path)) {
            guard let at = try? iso.parse(t.at), at >= since, at <= until else { continue }
            expected.append((Int64((at.timeIntervalSince1970 * 1000).rounded()), t.biome))
        }
    }
    // 2. SiverSol's side: the timeline.
    let timeline = TimelineStore(directory: support.appendingPathComponent("timeline", isDirectory: true))
    var days = Set([TimelineStore.day(since), TimelineStore.day(until)])
    var cursor = since
    while cursor < until { days.insert(TimelineStore.day(cursor)); cursor.addTimeInterval(86400) }
    let events = days.sorted().flatMap { timeline.events(day: $0) }.filter { $0.at >= since && $0.at <= until }
    let starts = events.compactMap { e -> BiomeStarted? in if case .biomeStarted(let s) = e { return s }; return nil }
    let recorded = starts.map { (ms: Int64(($0.at.timeIntervalSince1970 * 1000).rounded()), biome: $0.biome.key.value) }

    let want = Set(expected.map { "\($0.ms)|\($0.biome)" }), got = Set(recorded.map { "\($0.ms)|\($0.biome)" })
    let missed = want.subtracting(got).sorted(), extra = got.subtracting(want).sorted()
    let duplicates = recorded.count - got.count

    // 3. Delivery: every recorded biome event must have a Discord message on the main Rich route.
    let auditRoute = (FileManager.default.fileExists(atPath: AppConfig.url.path) ? AppConfig.load() : ConfigLocator.loadConfig()).testRouteName ?? "main"
    var undelivered: [String] = []
    var delivered = 0
    for e in events {
        switch e {
        case .biomeStarted, .biomeEnded:
            if store.ref(OutboxStore.ledgerKey(route: auditRoute, eventId: e.id)) != nil { delivered += 1 } else { undelivered.append(e.id) }
        default: break
        }
    }
    let hours = until.timeIntervalSince(since) / 3600
    let auras = events.filter { if case .auraEquipped(let a) = $0 { return !a.initial }; return false }.count
    let merchants = events.filter { if case .merchantArrived = $0 { return true }; return false }.count
    let afk = ((try? String(contentsOf: support.appendingPathComponent("actions.jsonl"), encoding: .utf8)) ?? "")
        .split(separator: "\n").filter { line in
            guard line.contains("\"key space\""), line.contains("\"approved\""),
                  let r = line.range(of: "\"time\":\""), let t = try? Date.ISO8601FormatStyle().parse(String(line[r.upperBound...].prefix(20))) else { return false }
            return t >= since
        }.count
    let ok = missed.isEmpty && extra.isEmpty && duplicates == 0 && undelivered.isEmpty
    var lines = [
        String(format: "window: %@ → %@ (%.2f h)", clock.string(from: since), clock.string(from: until), hours),
        "biome changes in the Roblox logs (independent scan): \(expected.count)",
        "biome starts recorded by SiverSol: \(recorded.count)   missed: \(missed.count)   extra: \(extra.count)   duplicated: \(duplicates)",
        "biome messages delivered to Discord: \(delivered)   not delivered: \(undelivered.count)   still queued: \(store.depth)",
        "auras: \(auras)   merchants: \(merchants)   anti-AFK key presses: \(afk)",
        "live card message: \(store.meta("card|\(store.meta("session.key") ?? "")") ?? "none")",
    ]
    for m in missed.prefix(5) { lines.append("  MISSED \(m)") }
    for m in extra.prefix(5) { lines.append("  EXTRA \(m)") }
    for m in undelivered.prefix(5) { lines.append("  UNDELIVERED \(m)") }
    lines.append(ok ? "RESULT: PASS" : "RESULT: FAIL")
    print(lines.joined(separator: "\n"))
    if post {
        let rig = await NotifyRig.make()
        let id = "soak\(Int(Date().timeIntervalSince1970))"
        let message = RichTemplates.buildLog(phase: String(format: "Soak report · %.1f h · %@", hours, ok ? "PASS" : "FAIL"),
                                             done: Array(lines.dropFirst().dropLast()), next: ok ? "Release build and zip." : "Fix what failed and soak again.")
        await rig.mesh.post(message, route: rig.testRoute, id: id)
        await rig.finish("soak report", expect: [id])
    }
    if !ok { exit(1) }
}

/// The connection test: "✅ SiverSol is connected" with what the channel will get and a simulated sample.
func webhookTest() async {
    let rig = await NotifyRig.make()
    if let problem = await rig.mesh.sendConnectionTest(route: rig.testRoute) { fail("connection test failed: \(problem)") }
    print("connection test delivered to route \(rig.testRoute)")
}

func simulate(_ name: String) async {
    let rig = await NotifyRig.make()
    guard let ctx = await rig.mesh.renderContext(route: rig.testRoute, origin: .simulated) else { fail("no 'test' route in config") }
    let key = BiomeKey(name)
    if !rig.catalog.isKnown(key) { print("note: \(key) is not in the catalog; sending it with the unknown-biome look") }
    let id = "sim\(Int(Date().timeIntervalSince1970))|\(key)"
    await rig.mesh.post(RichTemplates.simulated(biome: key, ctx), route: rig.testRoute, id: id, origin: .simulated)
    await rig.finish("simulate \(key)", expect: [id])
}

/// Replay a log through parser -> state machine -> mesh, as REPLAY-marked Rich messages on the test route.
func replayToTest(path: String, speed: Double) async {
    let rig = await NotifyRig.make()
    let run = "replay\(Int(Date().timeIntervalSince1970))-" + URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    var tracker = BiomeTracker(sessionId: run)
    var previous: Date?
    var count = 0
    await rig.mesh.start()
    for line in readLog(path).split(whereSeparator: \.isNewline) {
        guard let event = LogLineParser.parse(String(line)) else { continue }
        if speed > 0, let previous {
            let wait = min(event.timestamp.timeIntervalSince(previous) / speed, 30)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
        previous = event.timestamp
        for e in tracker.ingest(event) {
            print(describe(e, catalog: rig.catalog)); fflush(stdout); count += 1
            await rig.mesh.handle(e, origin: .replay)
        }
    }
    await rig.mesh.stop()
    await rig.finish("replay (\(count) events)")
}

/// Headless SiverSol: the same engine the app hosts. Live events, live routes, live card.
func runEngine(duration: TimeInterval?, card: Bool, antiAFK: Bool = true, rejoin: Bool = true, afkInterval: Double? = nil, play: String? = nil,
               pretendScreen: String? = nil, pretendAfter: Double = 60, rejoinAfter: Double? = nil) async {
    let secrets: Secrets
    do { secrets = try ConfigLocator.loadSecrets() } catch { fail("cannot load secrets: \(error.localizedDescription)") }
    var options = SiverEngine.Options()
    options.liveCard = card
    options.antiAFK.enabled = antiAFK
    options.rejoin.enabled = rejoin
    if let afkInterval { options.antiAFK.minIntervalS = afkInterval; options.antiAFK.maxIntervalS = afkInterval }
    if let pretendScreen {
        // Rehearsal of a Guardian alarm without opening a real purchase dialog (which SiverSol must never do):
        // after a while, the given words are added to what Guardian reads from the real window. Everything that
        // follows (the stop, Escape, the pause, the alert, the proof shot) is the real thing.
        let began = Date()
        options.screenLook = {
            guard var look = await Guardian.robloxLook() else { return nil }
            if Date().timeIntervalSince(began) >= pretendAfter {
                look.text.append(TextBox(text: pretendScreen, box: CGRect(x: 0.4, y: 0.45, width: 0.2, height: 0.04)))
            }
            return look
        }
        print("REHEARSAL: from \(Int(pretendAfter)) s on, Guardian will also read “\(pretendScreen)” in the middle of the window.")
    }
    let engine: SiverEngine
    do { engine = try SiverEngine(config: ConfigLocator.loadConfig(), secrets: secrets, options: options) }
    catch { fail("cannot start engine: \(error)") }
    let catalog = engine.catalog
    engine.onLog = { print("  · \($0)"); fflush(stdout) }
    engine.onIncident = { report in
        print("  INCIDENT \(report.recovered ? "recovered" : "NOT recovered"): \(report.cause)")
        for step in report.steps { print("    \(clock.string(from: step.at))  \(step.label)") }
        fflush(stdout)
    }
    engine.onEvent = { e in
        var line = describe(e, catalog: catalog)
        if case .biomeStarted(let s) = e, s.wasRunning {} else { line += String(format: "   [seen +%.2fs]", Date().timeIntervalSince(e.at)) }
        print(line); fflush(stdout)
    }
    print("SiverSol engine running (routes: \(engine.config.routes.filter(\.enabled).map { "\($0.name)/\($0.profile.rawValue)" }.joined(separator: ", "))). Ctrl-C to stop.")
    fflush(stdout)
    let runner = Task { await engine.run() }
    if let play {
        // Start one of the user's macros through the engine, so its Discord posts and the live card can be checked.
        Task {
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            if let problem = engine.macros.enqueue(play) { print("  macro not started: \(problem)") } else { print("  macro queued: \(play)") }
            fflush(stdout)
        }
    }
    if let rejoinAfter {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(rejoinAfter * 1_000_000_000))
            print("  rejoin requested (the same path as “Rejoin private server now”)"); fflush(stdout)
            await engine.rejoinNow()
        }
    }
    if let duration {
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    } else {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            source.setEventHandler { c.resume() }
            source.resume()
        }
    }
    await engine.stop()
    runner.cancel()
    let sent = await engine.mesh.sentCount
    print("stopped. session \(engine.sessionKey), \(sent) requests delivered, outbox \(engine.outbox.depth)")
}
