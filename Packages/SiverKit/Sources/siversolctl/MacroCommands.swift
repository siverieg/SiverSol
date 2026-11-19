import AppKit
import Carbon.HIToolbox
import Foundation
import SiverCore
import SiverEngine
import SiverInput
import SiverMacro
import SiverNotify
import SiverVision

/// A Macro Studio coordinator without the engine, for recording and playing from the command line.
func makeMacroCoordinator() -> MacroCoordinator {
    let catalog = loadCatalog(learn: false)
    let radar = BiomeRadar(logsDirectory: SiverSol.logsDirectory, catalog: catalog)
    _ = radar.step()
    let guardian = Guardian(log: ActionLog(url: ActionLog.defaultURL)) { await Guardian.robloxLook() }
    let coordinator = MacroCoordinator(supportDirectory: SiverSol.supportDirectory, guardian: guardian, radar: radar, catalog: catalog, inputPaused: { false })
    coordinator.log = { print("  · \($0)"); fflush(stdout) }
    return coordinator
}

func macroList() {
    let macros = MacroLibrary().all()
    if macros.isEmpty { print("No macros yet. They live in \(MacroLibrary().directory.path)"); return }
    for m in macros {
        print("\(m.name)  ·  \(m.steps.count) steps, \(duration(m.duration))  ·  \(m.isKeyboardOnly ? "keyboard only (plays in the background)" : "\(m.clickCount) clicks (needs Roblox in front)")\(m.reviewed ? "" : "  ·  NOT REVIEWED")")
    }
}

/// Posts a scripted walk as ordinary (unmarked) input, the way a person's keyboard would, so the recorder can be
/// tested end to end without a person at the keyboard. Roblox must be frontmost: these go through the HID path.
func driveScriptedWalk() async {
    func key(_ code: Int, hold: Double) async {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: true)?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
        CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: false)?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 250_000_000)
    }
    await key(kVK_ANSI_W, hold: 1.2)          // forward
    await key(kVK_ANSI_D, hold: 0.7)          // right
    await key(kVK_RightArrow, hold: 0.5)      // camera turns right
    await key(kVK_LeftArrow, hold: 0.5)       // …and back
    await key(kVK_ANSI_A, hold: 0.7)          // left
    await key(kVK_ANSI_S, hold: 1.2)          // back to the start
    await key(kVK_Space, hold: 0.08)          // one jump
}

/// Mouse counterpart of the scripted walk: a click on open ground, a camera turn with the right button held
/// (and the same turn back), and a zoom in and out with the scroll wheel. Posted as ordinary input.
func driveScriptedMouse() async {
    guard let w = RobloxWindowFinder.mainWindow()?.content else { return }
    let src = CGEventSource(stateID: .hidSystemState)
    func at(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: w.minX + w.width * x, y: w.minY + w.height * y) }
    func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
    func mouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton = .left, dx: Int64 = 0, dy: Int64 = 0) {
        let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        e?.setIntegerValueField(.mouseEventDeltaX, value: dx); e?.setIntegerValueField(.mouseEventDeltaY, value: dy)
        e?.post(tap: .cghidEventTap)
    }
    // Glide to a point over the sky, away from every button, and click once.
    for i in 0...20 { mouse(.mouseMoved, at(0.30 + 0.20 * Double(i) / 20, 0.22 + 0.06 * Double(i) / 20)); await pause(0.012) }
    await pause(0.2)
    mouse(.leftMouseDown, at(0.5, 0.28)); await pause(0.08); mouse(.leftMouseUp, at(0.5, 0.28))
    await pause(0.4)
    // Camera: hold the right button, turn right, turn back.
    let p = at(0.5, 0.30)
    mouse(.rightMouseDown, p, .right); await pause(0.1)
    for _ in 0..<30 { mouse(.rightMouseDragged, p, .right, dx: 6); await pause(0.012) }
    await pause(0.3)
    for _ in 0..<30 { mouse(.rightMouseDragged, p, .right, dx: -6); await pause(0.012) }
    await pause(0.1)
    mouse(.rightMouseUp, p, .right)
    await pause(0.4)
    // Zoom in two notches, then back out.
    func wheel(_ dy: Int32) { CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap) }
    wheel(2); await pause(0.4); wheel(-2); await pause(0.4)
}

/// Run the auto clicker for a few seconds over open sky in the Roblox window, and report what it did.
func macroAutoClick(seconds: Double, intervalMs: Double) async {
    let coordinator = makeMacroCoordinator()
    guard let w = RobloxWindowFinder.mainWindow()?.content else { fail("the Roblox window is not on screen") }
    guard await FocusManager.bringRobloxToFront(timeout: 2) else { fail("Roblox did not come to the front.") }
    CGWarpMouseCursorPosition(CGPoint(x: w.minX + w.width * 0.5, y: w.minY + w.height * 0.25))
    try? await Task.sleep(nanoseconds: 300_000_000)
    var config = AutoClickerConfig(); config.intervalMs = intervalMs
    let before = coordinator.stats.autoClicker
    if let problem = coordinator.startAutoClicker(config) { fail("cannot start: \(problem)") }
    print("auto clicker running over the sky for \(seconds) s (every \(Int(intervalMs)) ms)…"); fflush(stdout)
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    coordinator.stopAutoClicker()
    while coordinator.isBusy { try? await Task.sleep(nanoseconds: 50_000_000) }
    try? await Task.sleep(nanoseconds: 300_000_000)
    let after = coordinator.stats.autoClicker
    print("\(coordinator.status.lastResult)")
    print("totals: \(after.totalClicks) clicks in \(after.runs) runs, average \(String(format: "%.1f", after.averageCPS)) a second (this run: \(after.totalClicks - before.totalClicks) clicks)")
    // Second run with another app in front: it must not click at all.
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
    try? await Task.sleep(nanoseconds: 800_000_000)
    let mid = coordinator.stats.autoClicker.totalClicks
    if coordinator.startAutoClicker(config) == nil {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        coordinator.stopAutoClicker()
        while coordinator.isBusy { try? await Task.sleep(nanoseconds: 50_000_000) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        print("with Finder in front for 2 s: \(coordinator.stats.autoClicker.totalClicks - mid) clicks (expected 0)")
    } else { print("with Finder in front: it refused to start (\(coordinator.status.lastResult))") }
}

func macroRecord(name: String, seconds: Double, drive: Bool, driveMouse: Bool = false) async {
    let coordinator = makeMacroCoordinator()
    let drive = drive || driveMouse
    if drive {
        guard FocusManager.robloxApp() != nil else { fail("Roblox is not running.") }
        guard await FocusManager.bringRobloxToFront(timeout: 2) else { fail("Roblox did not come to the front.") }
        try? await Task.sleep(nanoseconds: 300_000_000)
    }
    if let problem = coordinator.startRecording() { fail("cannot record: \(problem)") }
    print("recording\(drive ? " a scripted walk" : " for \(Int(seconds)) s: use Roblox now")…"); fflush(stdout)
    if driveMouse { await driveScriptedMouse() } else if drive { await driveScriptedWalk() } else { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    try? await Task.sleep(nanoseconds: 300_000_000)
    guard let macro = coordinator.stopRecording(name: name) else { fail("nothing was recorded: \(coordinator.status.lastResult)") }
    print("saved “\(macro.name)”: \(macro.steps.count) steps, \(String(format: "%.2f", macro.duration)) s, keyboard only: \(macro.isKeyboardOnly)")
    for step in macro.steps.prefix(40) { print(String(format: "  +%.3f  %@", step.delay, step.summary)) }
    try? await Task.sleep(nanoseconds: 1_500_000_000)   // let the "recorded" post go out when a mesh is attached
}

func macroPlay(name: String, loops: Int?, speed: Double?, notify: Bool = false) async {
    let coordinator = makeMacroCoordinator()
    // --notify: post the macro's start and end to Discord through a queue that lives only in this process,
    // so it cannot collide with a running engine's outbox.
    var mesh: NotifyMesh?
    if notify, let secrets = try? ConfigLocator.loadSecrets() {
        let m = NotifyMesh(config: ConfigLocator.loadConfig(), secrets: secrets, catalog: loadCatalog(learn: false), store: OutboxStore(directory: nil))
        mesh = m
        coordinator.announce = { event, _ in await m.postMacro(event) }
    }
    guard var macro = coordinator.library.load(name) else { fail("no macro called “\(name)”") }
    if let loops { macro.settings.loops = loops }
    if let speed { macro.settings.speed = speed }
    do { try coordinator.library.save(macro) } catch { fail("\(error)") }
    if let problem = coordinator.enqueue(name) { fail(problem) }
    let began = Date()
    var lastLoop = -1
    while coordinator.isBusy {
        if let p = coordinator.status.playing, p.step > 0, p.loop != lastLoop {
            lastLoop = p.loop
            print(String(format: "  %6.2f s  loop %d of %@", Date().timeIntervalSince(began), p.loop + 1, p.totalLoops == 0 ? "∞" : String(p.totalLoops))); fflush(stdout)
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    if let mesh {
        try? await Task.sleep(nanoseconds: 300_000_000)   // the "finished" post is announced just after the player returns
        let ok = await mesh.flush(timeout: 30)
        print("Discord: \(await mesh.sentCount) macro posts delivered\(ok ? "" : " (some are still queued)")")
    }
    print("\(coordinator.status.lastResult)  (wall time \(String(format: "%.2f", Date().timeIntervalSince(began))) s)")
}
