import AppKit
import Foundation
import SiverCore
import SiverEngine
import SiverInput
import SiverMacro
import SiverVision

func artifactsDir() -> URL {
    // Screenshots stay in the repo's gitignored artifacts/ folder when run from the repo, else Application Support.
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0..<6 {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("project.yml").path) { return dir.appendingPathComponent("artifacts/screens") }
        dir.deleteLastPathComponent()
    }
    return SiverSol.supportDirectory.appendingPathComponent("screens")
}

func captureRoblox() async -> (RobloxWindow, CGImage) {
    guard let window = RobloxWindowFinder.mainWindow() else { fail("No on-screen Roblox window found.") }
    do { return (window, try await WindowCapture.capture(windowId: window.windowId, titleBar: window.titleBar)) }
    catch { fail("\(error)") }
}

func snapshot(name: String) async {
    let (window, image) = await captureRoblox()
    let url = artifactsDir().appendingPathComponent("\(name).png")
    guard SiverVision.savePNG(image, to: url) else { fail("cannot write \(url.path)") }
    print("saved \(url.path)  \(image.width)×\(image.height) px  (window \(Int(window.bounds.width))×\(Int(window.bounds.height)) pt, scale \(window.scale))")
}

/// F10 check: capture, cover the chat and player list, save, and optionally post as a TEST merchant alert.
func proofShot(post: Bool) async {
    let (_, image) = await captureRoblox()
    let url = artifactsDir().appendingPathComponent("proof-test.png")
    guard SiverVision.savePNG(ProofShot.masked(image), to: url) else { fail("cannot write \(url.path)") }
    print("saved \(url.path)")
    if let chat = SiverVision.crop(image, to: ProofShot.chatRegion), let lines = try? OCR.recognize(chat) {
        print("chat area text (what the merchant watcher reads): \(lines.isEmpty ? "nothing" : "")")
        for l in lines { print("  \(l.text)\(LogLineParser.merchantName(in: l.text).map { "   <- merchant: \($0)" } ?? "")") }
    }
    guard post else { return }
    let rig = await NotifyRig.make()
    let id = "prooftest\(Int(Date().timeIntervalSince1970))"
    let event = SiverEvent.merchantArrived(MerchantArrived(id: id, name: "Mari", at: Date(), biome: BiomeRef(raw: "NORMAL"), source: "screen"))
    await rig.mesh.handle(batch: [event], origin: .test, attachments: [id: [url.path]])
    await rig.finish("proof shot (TEST merchant alert)", expect: [id])
}

/// Phase C check without starting an engine: what the current log and the Roblox process say right now.
func inspect() async {
    guard let log = LogDiscovery.newest(in: SiverSol.logsDirectory) else { fail("No Roblox Player log found.") }
    var inspector = SessionInspector()
    inspector.setClientVersion(log.version)
    var entries: [LogLabEntry] = []
    var events: [SiverEvent] = []
    var tracker = BiomeTracker(sessionId: log.sessionId)
    for line in readLog(log.url.path).split(whereSeparator: \.isNewline) {
        guard let e = LogLineParser.parse(String(line)) else { continue }
        if let entry = inspector.note(e) { entries.append(entry) }
        events += tracker.ingest(e)
    }
    let info = inspector.info
    print("SESSION")
    print("  client \(info.clientVersion ?? "?")\(info.updatePending ? "  (update pending: \(info.offeredVersion ?? "?"))" : "  (up to date)")")
    print("  \(info.joinKind?.label ?? "no join seen") · server \(info.shortJobId ?? "?") · joined \(info.joinedAt.map { clock.string(from: $0) } ?? "?") · \(info.joins) join(s), \(info.teleports) teleport(s)")
    print("  render size \(info.windowWidth.map { "\($0)×\(info.windowHeight ?? 0)" } ?? "?") · last heartbeat \(info.lastHeartbeatAt.map { "\(Int(Date().timeIntervalSince($0))) s ago" } ?? "none")")
    print("  daily reset \(info.dailyResetAt.map { "\($0.formatted(.iso8601)) (in \(duration($0.timeIntervalSinceNow)))" } ?? "not printed yet")")
    if !inspector.unknown.isEmpty { print("  seen, not used yet: \(inspector.unknown)") }
    print("LOG LAB (last 8 of \(entries.count), heartbeats folded)")
    for e in entries.filter({ $0.kind != .heartbeat }).suffix(8) { print("  \(clock.string(from: e.at))  \(e.kind.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(e.summary)") }
    print("ROBLOX PROCESS")
    if let pid = RobloxWindowFinder.mainWindow()?.pid, let a = ProcessStats.usage(pid: pid) {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if let b = ProcessStats.usage(pid: pid) {
            print(String(format: "  memory %.2f GB · CPU %.0f%% of one core (2 s sample)", Double(b.memory) / 1_073_741_824, (b.cpuNs - a.cpuNs) / 2e9 * 100))
        }
    } else {
        print("  no game window / process not readable")
    }
    let intel = BiomeIntel.compute(events: events)
    print("BIOME INTELLIGENCE (this log)")
    print("  watched \(duration(intel.watchedSeconds)) · longest NORMAL \(duration(intel.longestNormalSeconds))\(intel.streakKey.map { " · streak \($0) ×\(intel.streakCount)" } ?? "")")
    for s in intel.stats.prefix(6) {
        print("  \(s.key.padding(toLength: 14, withPad: " ", startingAt: 0)) ×\(s.count)  total \(duration(s.totalSeconds))  last \(s.lastStartedAt.map { clock.string(from: $0) } ?? "?")\(s.averageGapSeconds.map { "  every ~\(duration($0))" } ?? "")")
    }
}

func printOCR(_ boxes: [TextBox]) {
    for b in boxes {
        print(String(format: "x %.3f  y %.3f  w %.3f  h %.3f  conf %.2f  %@", b.box.minX, b.box.minY, b.box.width, b.box.height, b.confidence, b.text))
    }
    print("— \(boxes.count) lines (x, y = top-left corner as window ratios)")
}

func ocr(path: String?, fast: Bool = false) async {
    let image: CGImage
    if let path {
        guard let loaded = SiverVision.loadImage(URL(fileURLWithPath: path)) else { fail("cannot read image \(path)") }
        image = loaded
    } else {
        image = await captureRoblox().1
    }
    do { printOCR(try OCR.recognize(image, fast: fast)) } catch { fail("OCR failed: \(error)") }
}

func guardianCheck() async {
    let guardian = Guardian(log: ActionLog(url: nil)) { await Guardian.robloxLook() }
    let result = await guardian.dryRun()
    print("screen readable: \(result.seen)  (\(result.lines) text lines)   accessibility: \(InputDriver.isTrusted)   screen recording: \(SiverVision.hasScreenRecordingAccess)")
    for (action, verdict) in result.verdicts {
        switch verdict {
        case .approved: print("  ALLOW  \(action)")
        case .blocked(let reason, let forbidden): print("  \(forbidden ? "BLOCK!" : "block ")  \(action)  — \(reason)")
        case .held(let reason): print("  wait    \(action)  — \(reason)")
        }
    }
    print("Nothing was pressed or clicked.")
}

func makeGuardian() -> Guardian {
    Guardian(log: ActionLog(url: ActionLog.defaultURL)) { await Guardian.robloxLook() }
}

func waitForIdle(_ input: InputDriver, seconds: Double = 10, maxWait: Double = 90) async -> Bool {
    var waited = 0.0
    while input.userIdleSeconds() < seconds {
        if waited == 0 { print("waiting for the Mac to be untouched for \(Int(seconds)) s…"); fflush(stdout) }
        if waited >= maxWait { return false }
        try? await Task.sleep(nanoseconds: 1_000_000_000); waited += 1
    }
    return true
}

/// Phase 4 check: does Roblox accept key events sent to it in the background, or only when frontmost?
/// Uses camera zoom (O out, I back in), which changes the picture but nothing in the game.
func inputProbe() async {
    guard InputDriver.isTrusted else { fail("Accessibility is not allowed for the app running this command.") }
    let input = InputDriver()
    let guardian = makeGuardian()
    guard let roblox = FocusManager.robloxApp() else { fail("Roblox is not running.") }
    let pid = roblox.processIdentifier
    let world = CGRect(x: 0.2, y: 0.12, width: 0.6, height: 0.6)
    func frame() async -> CGImage { await captureRoblox().1 }
    func taps(_ key: Key, _ delivery: InputDriver.Delivery, count: Int = 3) async {
        for _ in 0..<count {
            await input.tap(key, delivery: delivery, pid: pid, hold: 0.09, yieldToUser: false)
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
    }
    guard await waitForIdle(input) else { fail("The Mac is in use; not touching the keyboard. Try again when it is idle.") }
    switch await guardian.approve(.key("o")) {
    case .approved: break
    case .blocked(let reason, _), .held(let reason): fail("Guardian blocked the probe: \(reason)")
    }

    let a = await frame()
    try? await Task.sleep(nanoseconds: 700_000_000)
    let b = await frame()
    let noise = FrameHash.difference(a, b, region: world)
    print(String(format: "baseline (no input, 0.7 s apart): difference %.2f", noise))

    // 1. Background delivery: postToPid, Roblox not brought forward.
    let frontBefore = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
    await taps(.o, .toProcess)
    try? await Task.sleep(nanoseconds: 700_000_000)
    let c = await frame()
    SiverVision.savePNG(b, to: artifactsDir().appendingPathComponent("probe-1-before.png"))
    SiverVision.savePNG(c, to: artifactsDir().appendingPathComponent("probe-2-after-background-zoom-out.png"))
    let background = FrameHash.difference(b, c, region: world)
    await taps(.i, .toProcess)
    try? await Task.sleep(nanoseconds: 700_000_000)
    print(String(format: "postToPid (Roblox in background, frontmost app: %@): difference %.2f", frontBefore, background))

    // 2. HID delivery with a short focus swap.
    let d = await frame()
    let started = Date()
    SiverVision.savePNG(d, to: artifactsDir().appendingPathComponent("probe-3-after-background-zoom-in.png"))
    let swapped: Void? = await FocusManager.withRobloxFrontmost { await taps(.o, .hid) }
    let focusTime = Date().timeIntervalSince(started)
    try? await Task.sleep(nanoseconds: 700_000_000)
    let e = await frame()
    let hid = FrameHash.difference(d, e, region: world)
    _ = await FocusManager.withRobloxFrontmost { await taps(.i, .hid) }
    print(String(format: "HID + focus swap (%@, Roblox frontmost for %.2f s): difference %.2f", swapped == nil ? "FAILED to focus" : "ok", focusTime, hid))
    print("frontmost app now: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")

    let threshold = max(noise * 2.5, noise + 3)
    print(String(format: "verdict (a change above %.2f counts): background %@, focus swap %@", threshold,
                 background > threshold ? "WORKS" : "no effect", hid > threshold ? "WORKS" : "no effect"))
}

func afkPulse(delivery: String?, force: Bool) async {
    let input = InputDriver()
    var config = AntiAFK.Config()
    if let delivery, let d = InputDriver.Delivery(rawValue: delivery) { config.delivery = d }
    let afk = AntiAFK(config: config, guardian: makeGuardian(), input: input)
    if !force, !(await waitForIdle(input)) { fail("The Mac is in use; no pulse sent.") }
    let before = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
    let started = Date()
    let outcome = await afk.pulse(ignoreUserActivity: force)
    print("outcome: \(outcome)   took \(String(format: "%.2f", Date().timeIntervalSince(started))) s   frontmost before: \(before), after: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
}

/// Phase H permission check: can the recorder's event tap be created with Accessibility alone?
func macroProbe() async {
    let p = InputTap.permissions()
    print("accessibility granted: \(p.accessibility)")
    print("input monitoring (listen access) granted: \(p.listenAccess)")
    final class Counter: @unchecked Sendable { var total = 0; var own = 0; var keys = 0; let lock = NSLock() }
    let counter = Counter()
    let tap = InputTap { raw, own in
        counter.lock.lock(); counter.total += 1; if own { counter.own += 1 }
        if raw.kind == .keyDown || raw.kind == .keyUp { counter.keys += 1 }
        counter.lock.unlock()
    }
    let created = tap.start()
    print("active pass-through tap created: \(created)")
    guard created else { print("RESULT: the recorder cannot run for this app (Accessibility is missing)."); return }
    // Post two marked key events to the Roblox process only if it exists; otherwise just watch for a second.
    let out = LiveMacroOutput(window: { RobloxWindowFinder.mainWindow()?.content }, pid: { FocusManager.robloxApp()?.processIdentifier })
    out.mouseDelta(dx: 0, dy: 0)   // a zero-movement mouse event carrying our marker
    try? await Task.sleep(nanoseconds: 1_200_000_000)
    tap.stop()
    counter.lock.lock()
    print("events seen in 1.2 s: \(counter.total) (own marked events: \(counter.own), key events: \(counter.keys))")
    counter.lock.unlock()
    let after = InputTap.permissions()
    print("input monitoring after the test: \(after.listenAccess)  (unchanged means no new permission was involved)")
    print("RESULT: \(created && !p.listenAccess ? "the tap works with Accessibility alone; Input Monitoring is not granted and was not needed." : created ? "the tap works; this app also has Input Monitoring, so this run cannot prove it is unnecessary." : "tap failed")")
}
