import XCTest
import CoreGraphics
@testable import SiverMacro
@testable import SiverCore

/// Records every output call with the virtual time it happened at.
final class FakeOutput: MacroOutput, @unchecked Sendable {
    struct Call: Equatable { let t: TimeInterval; let what: String }
    private let lock = NSLock()
    private var _calls: [Call] = []
    private var held: Set<String> = []
    var clock: () -> TimeInterval = { 0 }
    var releases = 0

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    var stillHeld: Set<String> { lock.lock(); defer { lock.unlock() }; return held }
    private func add(_ s: String) { lock.lock(); _calls.append(Call(t: clock(), what: s)); lock.unlock() }

    func keyDown(_ code: UInt16) { lock.lock(); held.insert("k\(code)"); lock.unlock(); add("down \(code)") }
    func keyUp(_ code: UInt16) { lock.lock(); held.remove("k\(code)"); lock.unlock(); add("up \(code)") }
    func mouseMove(x: Double, y: Double) { add(String(format: "move %.3f %.3f", x, y)) }
    func mouseDown(_ b: MouseButton, x: Double, y: Double) { lock.lock(); held.insert("m\(b.rawValue)"); lock.unlock(); add(String(format: "mdown %@ %.3f %.3f", b.rawValue, x, y)) }
    func mouseUp(_ b: MouseButton, x: Double, y: Double) { lock.lock(); held.remove("m\(b.rawValue)"); lock.unlock(); add("mup \(b.rawValue)") }
    func mouseDelta(dx: Double, dy: Double) { add(String(format: "delta %.0f %.0f", dx, dy)) }
    func scroll(dx: Double, dy: Double) { add(String(format: "scroll %.0f", dy)) }
    func releaseAll() { lock.lock(); held.removeAll(); releases += 1; lock.unlock() }
}

/// Virtual time for the player. `overshoot` makes every sleep run a little long, like a real scheduler.
final class FakeTime: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 1000
    var overshoot: () -> TimeInterval = { 0 }
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ d: TimeInterval) { lock.lock(); t += d; lock.unlock() }
    func environment() -> MacroEnvironment {
        var e = MacroEnvironment()
        e.now = { self.now }
        e.sleep = { d in self.advance(max(0, d) + self.overshoot()); await Task.yield() }
        e.random = { 0.5 }
        return e
    }
}

let W: UInt16 = 13, A: UInt16 = 0, S: UInt16 = 1, D: UInt16 = 2, SPACE: UInt16 = 49
let win = CGRect(x: 959, y: 30, width: 960, height: 953)
func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: win.minX + win.width * x, y: win.minY + win.height * y) }

final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var v: Bool
    init(_ v: Bool) { self.v = v }
    var value: Bool { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
}

final class RecorderTests: XCTestCase {
    func recorder(frontmost: Flag = Flag(true), options: RecorderOptions = RecorderOptions(), window: CGRect? = win) -> MacroRecorder {
        MacroRecorder(options: options, window: { window }, robloxFrontmost: { frontmost.value })
    }

    func testWalkIsRecordedWithExactHoldTimes() {
        let r = recorder()
        r.start(at: 100)
        r.ingest(RawInput(.keyDown, time: 100.500, keyCode: W))
        r.ingest(RawInput(.keyDown, time: 100.750, keyCode: W, isRepeat: true))   // auto-repeat while held
        r.ingest(RawInput(.keyDown, time: 101.000, keyCode: D))
        r.ingest(RawInput(.keyUp, time: 102.250, keyCode: W))
        r.ingest(RawInput(.keyUp, time: 102.400, keyCode: D))
        let steps = r.stop(at: 103)
        XCTAssertEqual(steps.map(\.action), [.keyDown(code: W), .keyDown(code: D), .keyUp(code: W), .keyUp(code: D)])
        XCTAssertEqual(steps.map(\.delay), [0.5, 0.5, 1.25, 0.15], accuracy: 1e-9)
    }

    func testOnlyRobloxIsRecorded() {
        let front = Flag(true)
        let r = recorder(frontmost: front)
        r.start(at: 0)
        r.ingest(RawInput(.keyDown, time: 1, keyCode: W))
        front.value = false                                    // the user switches to another app…
        for (i, code) in [UInt16(35), 0, 1, 1, 13].enumerated() {   // …and types something there
            r.ingest(RawInput(.keyDown, time: 2 + Double(i) * 0.1, keyCode: code))
            r.ingest(RawInput(.keyUp, time: 2.05 + Double(i) * 0.1, keyCode: code))
        }
        r.ingest(RawInput(.mouseDown(.left), time: 3, location: pt(0.5, 0.5)))
        front.value = true
        r.ingest(RawInput(.keyUp, time: 4, keyCode: W))
        let steps = r.stop(at: 5)
        XCTAssertEqual(steps.map(\.action), [.keyDown(code: W), .keyUp(code: W)], "nothing from the other app is in the macro")
        XCTAssertEqual(r.droppedFromOtherApps, 11)
    }

    func testClicksUseWindowRatiosAndOutsideIsDropped() {
        let r = recorder()
        r.start(at: 0)
        r.ingest(RawInput(.mouseDown(.left), time: 1, location: pt(0.25, 0.75)))
        r.ingest(RawInput(.mouseUp(.left), time: 1.08, location: pt(0.25, 0.75)))
        r.ingest(RawInput(.mouseDown(.left), time: 2, location: CGPoint(x: 100, y: 100)))   // on the desktop, outside Roblox
        r.ingest(RawInput(.mouseUp(.left), time: 2.1, location: CGPoint(x: 100, y: 100)))
        r.ingest(RawInput(.scroll, time: 3, location: pt(0.5, 0.5), dy: -3))
        let steps = r.stop(at: 4)
        XCTAssertEqual(steps.map(\.action), [.mouseDown(button: .left, x: 0.25, y: 0.75), .mouseUp(button: .left, x: 0.25, y: 0.75), .scroll(dx: 0, dy: -3)])
        // With no Roblox window there is nothing to be relative to, so mouse input is not recorded at all.
        let none = recorder(window: nil); none.start(at: 0)
        none.ingest(RawInput(.mouseDown(.left), time: 1, location: pt(0.5, 0.5)))
        XCTAssertTrue(none.stop(at: 2).isEmpty)
    }

    func testMouseMovesAreThinnedToAbout120PerSecond() {
        let r = recorder()
        r.start(at: 0)
        for i in 0..<1000 {   // a 1000 Hz mouse for one second
            r.ingest(RawInput(.mouseMove, time: 1 + Double(i) / 1000, location: pt(0.1 + Double(i) * 0.0005, 0.5), dx: 1))
        }
        r.ingest(RawInput(.mouseDown(.left), time: 2.0005, location: pt(0.6, 0.5)))
        let steps = r.stop(at: 3)
        let moves = steps.filter { if case .mouseMove = $0.action { return true }; return false }
        XCTAssertGreaterThan(moves.count, 100); XCTAssertLessThan(moves.count, 130)
        // The last position before the click is always kept, so the click lands where the cursor really was.
        guard case .mouseMove(let x, _) = steps[steps.count - 3].action else { return XCTFail("\(steps.suffix(3))") }
        XCTAssertEqual(x, 0.1 + 999 * 0.0005, accuracy: 1e-6)
    }

    func testCameraTurnsAreRawDeltas() {
        let r = recorder()
        r.start(at: 0)
        r.ingest(RawInput(.mouseDown(.right), time: 1, location: pt(0.5, 0.5)))
        for i in 0..<10 { r.ingest(RawInput(.mouseDrag(.right), time: 1.02 + Double(i) * 0.02, location: pt(0.5, 0.5), dx: 12, dy: -3)) }
        r.ingest(RawInput(.mouseUp(.right), time: 1.3, location: pt(0.5, 0.5)))
        // Shift lock: the cursor is pinned, the mouse still reports movement.
        r.ingest(RawInput(.mouseMove, time: 2.00, location: pt(0.5, 0.5), dx: 0, dy: 0))
        r.ingest(RawInput(.mouseMove, time: 2.02, location: pt(0.5, 0.5), dx: 40, dy: 0))
        let steps = r.stop(at: 3)
        let deltas = steps.compactMap { s -> (Double, Double)? in if case .mouseDelta(let dx, let dy) = s.action { return (dx, dy) }; return nil }
        XCTAssertEqual(deltas.map(\.0).reduce(0, +), 160, accuracy: 1e-9, "10 × 12 from the right-drag, plus 40 from shift lock")
        XCTAssertEqual(deltas.map(\.1).reduce(0, +), -30, accuracy: 1e-9)
        XCTAssertFalse(steps.contains { if case .mouseMove(let x, _) = $0.action { return x != 0.5 }; return false })
    }

    func testChatTypingIsSkipped() {
        let r = recorder()
        r.start(at: 0)
        r.ingest(RawInput(.keyDown, time: 1, keyCode: W)); r.ingest(RawInput(.keyUp, time: 1.5, keyCode: W))
        r.ingest(RawInput(.keyDown, time: 2, keyCode: KeyNames.slash)); r.ingest(RawInput(.keyUp, time: 2.05, keyCode: KeyNames.slash))
        for (i, code) in [UInt16(4), 14, 37, 37, 31].enumerated() {   // "hello"
            r.ingest(RawInput(.keyDown, time: 2.2 + Double(i) * 0.1, keyCode: code)); r.ingest(RawInput(.keyUp, time: 2.25 + Double(i) * 0.1, keyCode: code))
        }
        r.ingest(RawInput(.keyDown, time: 3, keyCode: KeyNames.returnKey)); r.ingest(RawInput(.keyUp, time: 3.05, keyCode: KeyNames.returnKey))
        r.ingest(RawInput(.keyDown, time: 4, keyCode: A)); r.ingest(RawInput(.keyUp, time: 4.5, keyCode: A))
        let steps = r.stop(at: 5)
        XCTAssertEqual(steps.map(\.action), [.keyDown(code: W), .keyUp(code: W), .keyDown(code: A), .keyUp(code: A)], "the chat message is not in the macro")
        var keep = RecorderOptions(); keep.skipChatTyping = false
        let all = recorder(options: keep)
        all.start(at: 0)
        all.ingest(RawInput(.keyDown, time: 1, keyCode: KeyNames.slash)); all.ingest(RawInput(.keyUp, time: 1.1, keyCode: KeyNames.slash))
        XCTAssertEqual(all.stop(at: 2).count, 2)
    }

    func testPauseExcludesTimeAndNothingStaysHeld() {
        let r = recorder()
        r.start(at: 0)
        r.ingest(RawInput(.keyDown, time: 1, keyCode: W))
        r.pause(at: 2)                                         // W is released at the pause
        r.ingest(RawInput(.keyDown, time: 5, keyCode: SPACE))  // ignored while paused
        r.resume(at: 62)
        XCTAssertEqual(r.elapsed(now: 63), 3, accuracy: 1e-9)
        r.ingest(RawInput(.keyDown, time: 63, keyCode: S))
        let steps = r.stop(at: 64)                             // S is released at stop
        XCTAssertEqual(steps.map(\.action), [.keyDown(code: W), .keyUp(code: W), .keyDown(code: S), .keyUp(code: S)])
        XCTAssertEqual(steps.map(\.delay), [1, 1, 1, 1], accuracy: 1e-9)
        XCTAssertEqual(r.state, .idle)
        // A key that was already down when recording began never produces a lone release.
        let late = recorder(); late.start(at: 0)
        late.ingest(RawInput(.keyUp, time: 1, keyCode: W))
        XCTAssertTrue(late.stop(at: 2).isEmpty)
    }
}

func XCTAssertEqual(_ a: [Double], _ b: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}

final class PlayerTests: XCTestCase {
    func rig(_ configure: (inout MacroEnvironment) -> Void = { _ in }) -> (MacroPlayer, FakeOutput, FakeTime) {
        let time = FakeTime(); let out = FakeOutput(); out.clock = { time.now }
        var env = time.environment(); configure(&env)
        return (MacroPlayer(output: out, environment: env), out, time)
    }

    func walk() -> Macro {
        Macro(name: "walk", steps: [MacroStep(delay: 0.5, .keyDown(code: W)), MacroStep(delay: 0.5, .keyDown(code: D)),
                                     MacroStep(delay: 1.25, .keyUp(code: W)), MacroStep(delay: 0.15, .keyUp(code: D))])
    }

    func testRecordThenReplayRoundTrip() async {
        // Record synthetic input, replay it, and compare what comes out with what went in.
        let r = MacroRecorder(window: { win }, robloxFrontmost: { true })
        r.start(at: 0)
        let input: [(Double, RawInput.Kind, UInt16, CGPoint)] = [(0.50, .keyDown, W, .zero), (1.00, .keyDown, D, .zero), (2.25, .keyUp, W, .zero), (2.40, .keyUp, D, .zero),
                                                                 (3.00, .mouseDown(.left), 0, pt(0.3, 0.4)), (3.07, .mouseUp(.left), 0, pt(0.3, 0.4))]
        for (t, kind, code, loc) in input { r.ingest(RawInput(kind, time: t, keyCode: code, location: loc)) }
        let macro = Macro(name: "roundtrip", steps: r.stop(at: 3.5))
        let (player, out, time) = rig()
        let t0 = time.now
        let result = await player.play(macro)
        XCTAssertNil(result.stopped)
        XCTAssertEqual(out.calls.map(\.what), ["down 13", "down 2", "up 13", "up 2", "mdown left 0.300 0.400", "mup left"])
        XCTAssertEqual(out.calls.map { $0.t - t0 }, [0.50, 1.00, 2.25, 2.40, 3.00, 3.07], accuracy: 1e-6)
        XCTAssertTrue(out.stillHeld.isEmpty)
    }

    func testTimingDriftStaysUnder15msPerMinute() async {
        // A one-minute walk of 600 key events, replayed on a clock whose every sleep overshoots by up to 3 ms.
        var steps: [MacroStep] = []
        for i in 0..<300 { steps.append(MacroStep(delay: 0.1, .keyDown(code: i % 2 == 0 ? W : A))); steps.append(MacroStep(delay: 0.1, .keyUp(code: i % 2 == 0 ? W : A))) }
        let macro = Macro(name: "minute", steps: steps)
        XCTAssertEqual(macro.duration, 60, accuracy: 1e-9)
        let (player, out, time) = rig()
        var seed: UInt64 = 42
        time.overshoot = { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 40) / Double(1 << 24) * 0.003 }
        let t0 = time.now
        let result = await player.play(macro)
        XCTAssertNil(result.stopped); XCTAssertEqual(result.stepsPlayed, 600)
        let errors = out.calls.enumerated().map { i, c in (c.t - t0) - Double(i + 1) * 0.1 }
        XCTAssertLessThan(errors.map(abs).max()!, 0.015, "no single step is 15 ms off")
        XCTAssertLessThan(abs(errors.last!), 0.015, "after a full minute the macro is still within 15 ms: errors do not add up")
        XCTAssertGreaterThanOrEqual(errors.min()!, -1e-9, "steps never fire early")
    }

    func testSpeedLoopsAndLoopDelay() async {
        var macro = walk()
        macro.settings.speed = 2; macro.settings.loops = 3; macro.settings.loopDelayS = 1
        let (player, out, time) = rig()
        let t0 = time.now
        let result = await player.play(macro)
        XCTAssertEqual(result.loopsCompleted, 3); XCTAssertEqual(result.stepsPlayed, 12)
        XCTAssertEqual(out.calls.prefix(4).map { $0.t - t0 }, [0.25, 0.5, 1.125, 1.2], accuracy: 1e-6)
        XCTAssertEqual(out.calls[4].t - t0, 1.2 + 1 + 0.25, accuracy: 0.06, "second loop starts after the loop delay")
        XCTAssertEqual(result.duration, 3 * 1.2 + 2 * 1, accuracy: 0.2)
    }

    func testStopReleasesEveryHeldKey() async {
        let macro = Macro(name: "hold", steps: [MacroStep(delay: 0.1, .keyDown(code: W)), MacroStep(delay: 0.1, .mouseDown(button: .right, x: 0.5, y: 0.5)),
                                                MacroStep(delay: 30, .keyUp(code: W)), MacroStep(delay: 0, .mouseUp(button: .right, x: 0.5, y: 0.5))])
        let (player, out, time) = rig()
        let t0 = time.now
        let stopper = Task { while time.now - t0 < 5 { await Task.yield() }; player.stop(.panic) }
        let result = await player.play(macro)
        await stopper.value
        XCTAssertEqual(result.stopped, .panic)
        XCTAssertTrue(out.stillHeld.isEmpty, "W and the right button were held when panic hit; both are released")
        XCTAssertGreaterThan(out.releases, 0)
        XCTAssertFalse(player.isPlaying)
        XCTAssertLessThan(result.duration, 6, "stopped within a slice, not at the end of the 30 s hold")
    }

    func testGuardianStopsBeforeTheClickAndReleasesKeys() async {
        let macro = Macro(name: "click", steps: [MacroStep(delay: 0.1, .keyDown(code: W)), MacroStep(delay: 0.5, .mouseDown(button: .left, x: 0.5, y: 0.5)),
                                                 MacroStep(delay: 0.05, .mouseUp(button: .left, x: 0.5, y: 0.5)), MacroStep(delay: 0.1, .keyUp(code: W))])
        let (player, out, _) = rig { env in env.checkClick = { _, _ in .stop(.guardian("purchase dialog (\"robux\" on screen)")) } }
        let result = await player.play(macro)
        XCTAssertEqual(result.stopped, .guardian("purchase dialog (\"robux\" on screen)"))
        XCTAssertEqual(out.calls.map(\.what), ["down 13"], "the click never happened")
        XCTAssertTrue(out.stillHeld.isEmpty)
    }

    func testScreenWatchAbortsAKeyboardOnlyMacro() async {
        // Aura Storage opens 12 s into a keyboard-only macro; the 5 s screen check must stop it.
        let (player, out, time) = rig { _ in }
        let t0 = time.now
        var env = time.environment()
        env.checkScreen = { time.now - t0 >= 12 ? .stop(.guardian("Aura Storage is open")) : .ok }
        let p = MacroPlayer(output: out, environment: env)
        _ = player
        let macro = Macro(name: "long", steps: [MacroStep(delay: 0.1, .keyDown(code: W)), MacroStep(delay: 60, .keyUp(code: W))])
        let result = await p.play(macro)
        XCTAssertEqual(result.stopped, .guardian("Aura Storage is open"))
        XCTAssertLessThan(result.duration, 18, "noticed at the next 5 s check")
        XCTAssertTrue(out.stillHeld.isEmpty)
    }

    func testCutsceneHoldPausesAndThenResumes() async {
        let time = FakeTime(); let out = FakeOutput(); out.clock = { time.now }
        let t0 = time.now
        var env = time.environment()
        env.checkScreen = { (2..<10).contains(time.now - t0) ? .hold("a roll cutscene is playing") : .ok }
        let macro = Macro(name: "walk", steps: [MacroStep(delay: 1, .keyDown(code: W)), MacroStep(delay: 6, .keyUp(code: W)), MacroStep(delay: 1, .keyDown(code: SPACE)), MacroStep(delay: 0.1, .keyUp(code: SPACE))])
        let result = await MacroPlayer(output: out, environment: env).play(macro)
        XCTAssertNil(result.stopped, "a cutscene is waited out, not treated as an error")
        XCTAssertEqual(result.stepsPlayed, 4)
        XCTAssertGreaterThan(result.duration, 8.1 + 3, "the wait was added to the run")
    }

    func testMouseMacroYieldsToTheUser() async {
        let time = FakeTime(); let out = FakeOutput(); out.clock = { time.now }
        let t0 = time.now
        var env = time.environment()
        env.userTouched = { time.now - t0 > 1 }
        let mouse = Macro(name: "m", steps: [MacroStep(delay: 0.2, .mouseMove(x: 0.5, y: 0.5)), MacroStep(delay: 5, .mouseMove(x: 0.6, y: 0.5))])
        let r1 = await MacroPlayer(output: out, environment: env).play(mouse)
        XCTAssertEqual(r1.stopped, .userInput)
        // A keyboard-only macro plays in the background and does not care what the user does.
        let keys = Macro(name: "k", steps: [MacroStep(delay: 0.2, .keyDown(code: W)), MacroStep(delay: 3, .keyUp(code: W))])
        XCTAssertTrue(keys.isKeyboardOnly)
        let r2 = await MacroPlayer(output: out, environment: env).play(keys)
        XCTAssertNil(r2.stopped)
    }

    func testRareBiomeStopsTheMacroUnlessTurnedOff() async {
        let (player, out, _) = rig { env in env.rareBiomeActive = { true } }
        var macro = walk()
        let r1 = await player.play(macro)
        XCTAssertEqual(r1.stopped, .rareBiome); XCTAssertTrue(out.calls.isEmpty)
        macro.settings.pauseDuringRareBiomes = false
        let r2 = await player.play(macro)
        XCTAssertNil(r2.stopped)
    }

    func testItemBarAndMenuClicksNeedPermissionAndAreCapped() async {
        XCTAssertTrue(MacroZones.isItemOrMenu(x: 0.8, y: 0.95)); XCTAssertTrue(MacroZones.isItemOrMenu(x: 0.03, y: 0.5))
        XCTAssertFalse(MacroZones.isItemOrMenu(x: 0.5, y: 0.92), "the Roll button is not the item bar")
        var macro = Macro(name: "items", steps: (0..<4).flatMap { _ in [MacroStep(delay: 0.1, .mouseDown(button: .left, x: 0.8, y: 0.95)), MacroStep(delay: 0.05, .mouseUp(button: .left, x: 0.8, y: 0.95))] })
        let (player, out, _) = rig()
        let refused = await player.play(macro)
        guard case .guardian(let why)? = refused.stopped else { return XCTFail() }
        XCTAssertTrue(why.contains("not allowed")); XCTAssertTrue(out.calls.isEmpty)
        macro.settings.allowItemAndMenuClicks = true; macro.settings.itemClickHourlyCap = 3
        let capped = await player.play(macro)
        guard case .guardian(let cap)? = capped.stopped else { return XCTFail() }
        XCTAssertTrue(cap.contains("hourly limit"))
        XCTAssertEqual(out.calls.filter { $0.what.hasPrefix("mdown") }.count, 3)
    }

    func testALostWindowStopsTheMacroAndSaysWhy() async {
        // The display Roblox was on is unplugged halfway through: the next step finds no window.
        let gone = Flag(false)
        let (player, out, _) = rig { env in env.windowLost = { gone.value } }
        let macro = Macro(name: "clicks", steps: [MacroStep(delay: 0.1, .mouseDown(button: .left, x: 0.5, y: 0.5)), MacroStep(delay: 0.05, .mouseUp(button: .left, x: 0.5, y: 0.5)),
                                                   MacroStep(delay: 0.1, .keyDown(code: W)), MacroStep(delay: 0.1, .keyUp(code: W))])
        let fine = await player.play(macro)
        XCTAssertNil(fine.stopped)
        gone.value = true
        let before = out.calls.count
        let result = await player.play(macro)
        XCTAssertEqual(result.stopped, .noWindow)
        XCTAssertEqual(out.calls.count, before, "nothing is pressed or clicked at where the window used to be")
        XCTAssertTrue(MacroStopReason.noWindow.label.contains("could not be found"))
        XCTAssertTrue(out.stillHeld.isEmpty)
    }

    func testClicksWhileAnItemWindowIsOpenCountTowardTheCap() async {
        // Not in the item bar zone, but Guardian reports an item window: allowed clicks are counted and capped.
        var macro = Macro(name: "inventory", steps: (0..<4).flatMap { _ in [MacroStep(delay: 0.1, .mouseDown(button: .left, x: 0.36, y: 0.54)), MacroStep(delay: 0.05, .mouseUp(button: .left, x: 0.36, y: 0.54))] })
        // Without permission the ordinary check is used, and Guardian refuses it.
        let (refusing, out1, _) = rig { env in
            env.checkClick = { _, _ in .stop(.guardian("the Inventory window is open, and a click could use an item")) }
            env.checkItemClick = { _, _ in XCTFail("a macro without permission must not use the item check"); return .ok }
        }
        let refused = await refusing.play(macro)
        guard case .guardian(let why)? = refused.stopped else { return XCTFail() }
        XCTAssertTrue(why.contains("Inventory")); XCTAssertTrue(out1.calls.isEmpty, "nothing was clicked")
        // With permission: the item check is used, and its clicks are limited per hour.
        macro.settings.allowItemAndMenuClicks = true; macro.settings.itemClickHourlyCap = 2
        let (allowed, out2, _) = rig { env in env.checkItemClick = { _, _ in .okItem } }
        let capped = await allowed.play(macro)
        guard case .guardian(let cap)? = capped.stopped else { return XCTFail() }
        XCTAssertTrue(cap.contains("hourly limit"))
        XCTAssertEqual(out2.calls.filter { $0.what.hasPrefix("mdown") }.count, 2)
    }

    func testSmartSteps() async {
        let time = FakeTime(); let out = FakeOutput(); out.clock = { time.now }
        let t0 = time.now
        var env = time.environment()
        env.inGame = { time.now - t0 >= 3 }
        env.currentBiome = { time.now - t0 >= 5 ? "WINDY" : "NORMAL" }
        env.textOnScreen = { text in text == "Play" && time.now - t0 >= 8 }
        let macro = Macro(name: "smart", steps: [MacroStep(delay: 0, .waitInGame(timeoutS: 30)), MacroStep(delay: 0, .waitBiome(biome: "windy", timeoutS: 30)),
                                                 MacroStep(delay: 0, .waitText(text: "Play", timeoutS: 30)), MacroStep(delay: 0, .wait(seconds: 2)),
                                                 MacroStep(delay: 0.5, .keyDown(code: SPACE)), MacroStep(delay: 0.1, .keyUp(code: SPACE))])
        let result = await MacroPlayer(output: out, environment: env).play(macro)
        XCTAssertNil(result.stopped)
        XCTAssertEqual(out.calls.first!.t - t0, 8 + 2 + 0.5, accuracy: 1.1, "input timing continues from when the waits ended")
        let never = Macro(name: "never", steps: [MacroStep(delay: 0, .waitText(text: "Nope", timeoutS: 4))])
        let timedOut = await MacroPlayer(output: out, environment: env).play(never)
        XCTAssertEqual(timedOut.stopped, .timeout("“Nope” on screen"))
    }

    func testNothingIsPressedOrClickedUnlessRobloxIsInFront() async {
        // The live output drops presses, clicks and moves when another app is in front, and remembers that it did.
        let front = Flag(false)
        let live = LiveMacroOutput(window: { win }, pid: { nil }, robloxFrontmost: { front.value })
        XCTAssertFalse(live.focusLost)
        live.keyDown(W)                         // dropped: nothing reaches the app that is in front
        live.mouseDown(.left, x: 0.5, y: 0.5)   // dropped
        XCTAssertTrue(live.focusLost)
        live.resetFocusLost()
        XCTAssertFalse(live.focusLost)

        // The player stops as soon as the output reports it.
        let time = FakeTime(); let out = FakeOutput(); out.clock = { time.now }
        let t0 = time.now
        var env = time.environment()
        env.focusLost = { time.now - t0 > 1 }
        let mouse = Macro(name: "m", steps: [MacroStep(delay: 0.2, .mouseDown(button: .left, x: 0.5, y: 0.5)), MacroStep(delay: 5, .mouseUp(button: .left, x: 0.5, y: 0.5))])
        let r = await MacroPlayer(output: out, environment: env).play(mouse)
        XCTAssertEqual(r.stopped, .lostFocus)
        XCTAssertTrue(out.stillHeld.isEmpty)

        // The auto clicker does not click while another app is in front.
        var waiting = time.environment(); waiting.robloxFrontmost = { false }
        var limited = AutoClickerConfig(); limited.stopAfterMinutes = 0.05
        let run = await AutoClicker(output: out, environment: waiting, cursor: { (0.5, 0.5) }).run(limited)
        XCTAssertEqual(run.clicks, 0); XCTAssertNil(run.stopped)
    }

    func testAutoClicker() async {
        let time = FakeTime(); let out = FakeOutput(); out.clock = { time.now }
        var config = AutoClickerConfig(); config.intervalMs = 100; config.stopAfterClicks = 50
        let clicker = AutoClicker(output: out, environment: time.environment(), cursor: { (0.5, 0.5) })
        let run = await clicker.run(config)
        XCTAssertEqual(run.clicks, 50); XCTAssertNil(run.stopped)
        XCTAssertEqual(Double(run.clicks) / run.seconds, 10, accuracy: 1.0, "about 10 clicks per second")
        var stats = AutoClickerStats(); stats.totalClicks = run.clicks; stats.totalSeconds = run.seconds; stats.runs = 1
        XCTAssertEqual(stats.averageCPS, 10, accuracy: 1.0)
        // Guardian sees a forbidden dialog: the clicker stops at once.
        var env = time.environment(); env.checkClick = { _, _ in .stop(.guardian("trade window")) }
        let blocked = await AutoClicker(output: out, environment: env, cursor: { (0.5, 0.5) }).run(config)
        XCTAssertEqual(blocked.clicks, 0); XCTAssertEqual(blocked.stopped, .guardian("trade window"))
        // It never clicks the item bar, and it does not click while the cursor is outside the Roblox window.
        let items = await AutoClicker(output: out, environment: time.environment(), cursor: { (0.9, 0.96) }).run(config)
        XCTAssertEqual(items.clicks, 0)
        var limited = AutoClickerConfig(); limited.stopAfterMinutes = 0.05
        let outside = await AutoClicker(output: out, environment: time.environment(), cursor: { nil }).run(limited)
        XCTAssertEqual(outside.clicks, 0); XCTAssertNil(outside.stopped)
    }
}

final class FormatTests: XCTestCase {
    func sample() -> Macro {
        var m = Macro(name: "Walk to Stella", steps: [MacroStep(delay: 0.5, .keyDown(code: W)), MacroStep(delay: 1.2345678, .keyUp(code: W)),
                                                     MacroStep(delay: 0.016, .mouseMove(x: 0.123456789, y: 0.5)), MacroStep(delay: 0.1, .mouseDown(button: .right, x: 0.5, y: 0.5)),
                                                     MacroStep(delay: 0.01, .mouseDelta(dx: 12, dy: -3)), MacroStep(delay: 0.1, .mouseUp(button: .right, x: 0.5, y: 0.5)),
                                                     MacroStep(delay: 0, .scroll(dx: 0, dy: -3)), MacroStep(delay: 0, .wait(seconds: 2)),
                                                     MacroStep(delay: 0, .waitText(text: "Play", timeoutS: 30)), MacroStep(delay: 0, .waitBiome(biome: "WINDY", timeoutS: 600)),
                                                     MacroStep(delay: 0, .waitInGame(timeoutS: 90))], createdAt: Date(timeIntervalSince1970: 1_795_000_000))
        m.settings.triggers = [.everyMinutes(15), .biomeStarted("WINDY"), .afterRejoin, .dailyReset]
        m.settings.chainTo = "Other"
        m.windowWidth = 960; m.windowHeight = 953
        return m
    }

    func testFileRoundTripIsVersionedJSON() throws {
        let data = try MacroCodec.encode(sample())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["format"] as? String, "siversol-macro")
        XCTAssertEqual(json["version"] as? Int, 2, "version 2: positions are ratios of the game area")
        let back = try MacroCodec.decode(data)
        XCTAssertEqual(back.name, "Walk to Stella")
        XCTAssertEqual(back.steps.count, 11)
        XCTAssertEqual(back.steps[1].delay, 1.2346, accuracy: 1e-9, "delays are stored to a tenth of a millisecond")
        XCTAssertEqual(back.settings.triggers, sample().settings.triggers)
        XCTAssertEqual(back.steps.map(\.action.isSmart).filter { $0 }.count, 4)
        XCTAssertFalse(back.isKeyboardOnly)
        XCTAssertEqual(MacroLibrary.fileName(for: "a/b:c"), "a-b-c.svmacro")
    }

    // MARK: old recordings (version 1: ratios of the whole window, title bar included)

    /// A version 1 file as the Mac mini wrote it: recorded in a 960×953 window with a 32-point title bar.
    func oldFile(width: Double = 960, height: Double = 953) throws -> Data {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: MacroCodec.encode(sample())) as? [String: Any])
        json["version"] = 1
        json["windowWidth"] = width; json["windowHeight"] = height
        json.removeValue(forKey: "titleBar")
        // A click that was 80% of the way down the game: (32 + 0.8 × 921) / 953 of the whole window.
        let y = (32 + 0.8 * 921) / 953
        json["steps"] = [["d": 0.1, "a": "down", "button": "left", "x": 0.5, "y": y], ["d": 0.05, "a": "up", "button": "left", "x": 0.5, "y": y],
                         ["d": 0.1, "a": "move", "x": 0.25, "y": 0.01], ["d": 0.1, "a": "keyDown", "key": 13], ["d": 0.1, "a": "keyUp", "key": 13]]
        return try JSONSerialization.data(withJSONObject: json)
    }

    func testAnOldRecordingIsMovedToTheGameArea() throws {
        let keep = MacroCodec.legacyTitleBar
        defer { MacroCodec.legacyTitleBar = keep }
        MacroCodec.legacyTitleBar = { size in
            // This Mac: one plain 1920×1080 display, standard title bars 32 points tall.
            MacroMigration.legacyTitleBar(recorded: size, screens: [ScreenShape(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))], systemTitleBar: 32)
        }
        let macro = try MacroCodec.decode(oldFile())
        XCTAssertEqual(macro.version, 2)
        XCTAssertEqual(macro.titleBar, 32)
        XCTAssertEqual(macro.windowHeight, 921, "now the size of the game area")
        guard case .mouseDown(_, let x, let y) = macro.steps[0].action else { return XCTFail() }
        XCTAssertEqual(x, 0.5); XCTAssertEqual(y, 0.8, accuracy: 1e-9, "80% of the way down the game, as it was recorded")
        guard case .mouseMove(_, let top) = macro.steps[2].action else { return XCTFail() }
        XCTAssertEqual(top, 0, "a point on the old title bar lands on the top edge of the game")
        XCTAssertEqual(macro.steps[3].action, .keyDown(code: 13), "keys are untouched")

        // Saved again it is a version 2 file, and reading that changes nothing more.
        let again = try MacroCodec.decode(MacroCodec.encode(macro))
        XCTAssertEqual(again, macro)
    }

    func testAnOldRecordingReplaysOnAMacBookWindowOfADifferentSize() throws {
        let keep = MacroCodec.legacyTitleBar
        defer { MacroCodec.legacyTitleBar = keep }
        MacroCodec.legacyTitleBar = { _ in 32 }
        let macro = try MacroCodec.decode(oldFile())
        guard case .mouseDown(_, let x, let y) = macro.steps[0].action else { return XCTFail() }

        // On the Mac mini it still clicks the very pixel it was recorded on.
        let mini = GameFrame(window: CGRect(x: 0, y: 30, width: 960, height: 953), titleBar: 32)
        XCTAssertEqual(mini.point(x: x, y: y).y, 30 + 32 + 0.8 * 921, accuracy: 0.001)
        XCTAssertEqual(mini.point(x: x, y: y).x, 480)

        // 13" Air, 1470×956, Roblox full screen below the camera housing (37 points): no title bar.
        let fullScreen = GameFrame(window: CGRect(x: 0, y: 37, width: 1470, height: 919), titleBar: 0, scale: 2)
        XCTAssertEqual(fullScreen.point(x: x, y: y), CGPoint(x: 735, y: 37 + 0.8 * 919), "80% down the game, not 80% down the screen")

        // The same Air with Roblox in a window that fills the space under the menu bar.
        let windowed = GameFrame(window: CGRect(x: 0, y: 37, width: 1470, height: 849), titleBar: 32, scale: 2)
        XCTAssertEqual(windowed.point(x: x, y: y).y, 37 + 32 + 0.8 * 817, accuracy: 0.001)

        // Without the migration the click would be a title bar's share too high in full screen.
        let unmigrated = (32 + 0.8 * 921) / 953
        XCTAssertGreaterThan(abs(fullScreen.point(x: 0.5, y: unmigrated).y - fullScreen.point(x: x, y: y).y), 5)
    }

    func testAnOldFullScreenRecordingNeedsNoShift() throws {
        // Recorded with Roblox as large as the screen: there was no title bar, so nothing moves.
        let screens = [ScreenShape(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))]
        XCTAssertEqual(MacroMigration.legacyTitleBar(recorded: CGSize(width: 1920, height: 1080), screens: screens, systemTitleBar: 32), 0)
        XCTAssertEqual(MacroMigration.legacyTitleBar(recorded: CGSize(width: 960, height: 953), screens: screens, systemTitleBar: 32), 32)
        let air = LaptopProfile.air13.screen(midX: 735, top: 956)
        XCTAssertEqual(MacroMigration.legacyTitleBar(recorded: CGSize(width: 1470, height: 919), screens: [air], systemTitleBar: 32), 0, "full screen below a notch")
        XCTAssertEqual(MacroMigration.legacyTitleBar(recorded: .zero, screens: screens, systemTitleBar: 32), 0, "a macro built by hand has no window size")

        let keep = MacroCodec.legacyTitleBar
        defer { MacroCodec.legacyTitleBar = keep }
        MacroCodec.legacyTitleBar = { MacroMigration.legacyTitleBar(recorded: $0, screens: screens, systemTitleBar: 32) }
        let macro = try MacroCodec.decode(oldFile(width: 1920, height: 1080))
        guard case .mouseDown(_, _, let y) = macro.steps[0].action else { return XCTFail() }
        XCTAssertEqual(y, (32 + 0.8 * 921) / 953, accuracy: 1e-5, "unchanged")
        XCTAssertEqual(macro.version, 2); XCTAssertEqual(macro.titleBar, 0)
    }

    func testItemZonesAreWhereTheyWereOnTheReferenceWindow() {
        // The zones were measured as ratios of the whole 953-point window. Their edges, as screen rows, have not moved.
        func row(_ contentY: Double) -> Double { 32 + contentY * 921 }
        XCTAssertEqual(row(MacroZones.itemBarTop), 0.90 * 953, accuracy: 0.001)
        XCTAssertEqual(row(MacroZones.menuTop), 0.38 * 953, accuracy: 0.001)
        XCTAssertEqual(row(MacroZones.menuBottom), 0.66 * 953, accuracy: 0.001)
    }

    func testImportValidationRejectsBadFiles() throws {
        func reject(_ edit: (inout [String: Any]) -> Void, _ expected: String, line: UInt = #line) throws {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: MacroCodec.encode(sample())) as? [String: Any])
            edit(&json)
            XCTAssertThrowsError(try MacroCodec.decode(JSONSerialization.data(withJSONObject: json)), line: line) { error in
                XCTAssertTrue("\(error)".contains(expected), "\(error)", line: line)
            }
        }
        func step(_ json: inout [String: Any], _ i: Int, _ key: String, _ value: Any) { var steps = json["steps"] as! [[String: Any]]; steps[i][key] = value; json["steps"] = steps }
        try reject({ $0["format"] = "something-else" }, "not a SiverSol macro")
        try reject({ $0["version"] = 99 }, "newer SiverSol")
        try reject({ $0["name"] = "" }, "name")
        try reject({ $0["name"] = "../../etc/passwd" }, "name")
        try reject({ step(&$0, 2, "x", 1.4) }, "outside the Roblox window")
        try reject({ step(&$0, 3, "y", -0.2) }, "outside the Roblox window")
        try reject({ step(&$0, 0, "d", -1) }, "delay")
        try reject({ step(&$0, 0, "d", 99999) }, "delay")
        try reject({ step(&$0, 0, "key", 900) }, "unknown key")
        try reject({ step(&$0, 0, "a", "runShellCommand") }, "could not be read")
        try reject({ step(&$0, 4, "dx", 1e9) }, "impossible mouse movement")
        try reject({ var s = $0["settings"] as! [String: Any]; s["speed"] = 50; $0["settings"] = s }, "speed")
        try reject({ $0["steps"] = Array(repeating: ["d": 3000, "a": "wait", "seconds": 3000], count: 5) }, "longer than 6 hours")
        XCTAssertThrowsError(try MacroCodec.decode(Data("not json".utf8)))
        XCTAssertThrowsError(try MacroCodec.decode(Data(#"{"hello":1}"#.utf8)))
        XCTAssertNoThrow(try MacroCodec.decode(MacroCodec.encode(sample())))
    }

    func testLibraryAndSafeImport() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("svmacro-\(UUID().uuidString)")
        let lib = MacroLibrary(directory: dir)
        try lib.save(sample())
        XCTAssertEqual(lib.all().map(\.name), ["Walk to Stella"])
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("broken.svmacro"))
        XCTAssertEqual(lib.all().count, 1, "a broken file is skipped")
        // Importing a file someone sent: validated, marked for review, and stripped of anything that runs by itself.
        var shared = sample(); shared.settings.allowItemAndMenuClicks = true
        let file = dir.appendingPathComponent("incoming.json")
        try MacroCodec.encode(shared).write(to: file)
        let preview = try lib.previewImport(file)
        XCTAssertFalse(preview.reviewed)
        XCTAssertTrue(preview.settings.triggers.isEmpty); XCTAssertNil(preview.settings.chainTo)
        XCTAssertFalse(preview.settings.allowItemAndMenuClicks)
        XCTAssertEqual(preview.name, "Walk to Stella 2", "it does not overwrite the macro you already have")
        try lib.rename("Walk to Stella", to: "Morning walk")
        XCTAssertEqual(lib.all().map(\.name), ["Morning walk"])
        lib.delete("Morning walk")
        XCTAssertTrue(lib.all().isEmpty)
    }

    func testStopShortcutIsNotPartOfTheRecording() {
        let ctrl: UInt16 = 59, opt: UInt16 = 58, cmd: UInt16 = 55, shift: UInt16 = 56, R: UInt16 = 15
        let walk = [MacroStep(delay: 0, .keyDown(code: shift)), MacroStep(delay: 0.1, .keyDown(code: W)), MacroStep(delay: 1, .keyUp(code: W)),
                    MacroStep(delay: 0.2, .keyDown(code: R)), MacroStep(delay: 0.1, .keyUp(code: R))]
        // ⌃⌥⌘R pressed to stop, with Shift (sprint) still held: the chord goes, Shift is released, the earlier R tap stays.
        let chord = [MacroStep(delay: 0.5, .keyDown(code: ctrl)), MacroStep(delay: 0.05, .keyDown(code: opt)), MacroStep(delay: 0.05, .keyDown(code: cmd)),
                     MacroStep(delay: 0.05, .keyDown(code: R)), MacroStep(delay: 0, .keyUp(code: R)),
                     MacroStep(delay: 0, .keyUp(code: cmd)), MacroStep(delay: 0, .keyUp(code: opt)), MacroStep(delay: 0, .keyUp(code: ctrl)), MacroStep(delay: 0, .keyUp(code: shift))]
        let cleaned = MacroEditing.dropTrailingShortcut(walk + chord)
        XCTAssertEqual(cleaned.map(\.action), walk.map(\.action) + [.keyUp(code: shift)])
        // A recording that does not end with the shortcut is left alone.
        XCTAssertEqual(MacroEditing.dropTrailingShortcut(walk + [MacroStep(delay: 0, .keyUp(code: shift))]).count, walk.count + 1)
    }

    func testPauseShortcutInTheMiddleIsNotRecorded() {
        let ctrl: UInt16 = 59, opt: UInt16 = 58, cmd: UInt16 = 55, shift: UInt16 = 56, E: UInt16 = 14
        // Walk, ⌃⌥⌘E (pause), ⌃⌥⌘E (resume), walk on. Shift is held throughout and must survive.
        func chord() -> [MacroStep] {
            [MacroStep(delay: 0.2, .keyDown(code: ctrl)), MacroStep(delay: 0.03, .keyDown(code: opt)), MacroStep(delay: 0.03, .keyDown(code: cmd)),
             MacroStep(delay: 0.04, .keyDown(code: E)), MacroStep(delay: 0.05, .keyUp(code: E)),
             MacroStep(delay: 0.02, .keyUp(code: cmd)), MacroStep(delay: 0.02, .keyUp(code: opt)), MacroStep(delay: 0.01, .keyUp(code: ctrl))]
        }
        let first = [MacroStep(delay: 0, .keyDown(code: shift)), MacroStep(delay: 0.1, .keyDown(code: W)), MacroStep(delay: 1, .keyUp(code: W))]
        let second = [MacroStep(delay: 0.5, .keyDown(code: D)), MacroStep(delay: 0.7, .keyUp(code: D)), MacroStep(delay: 0.1, .keyUp(code: shift))]
        let recorded = first + chord() + chord() + second
        let cleaned = MacroEditing.dropShortcutChords(recorded)
        XCTAssertEqual(cleaned.map(\.action), (first + second).map(\.action))
        XCTAssertEqual(cleaned.reduce(0) { $0 + $1.delay }, recorded.reduce(0) { $0 + $1.delay }, accuracy: 0.0001, "total time is kept")
        // A lone Control or Command press (no full chord) is the user's own input and stays.
        let lone = [MacroStep(delay: 0, .keyDown(code: ctrl)), MacroStep(delay: 0.3, .keyUp(code: ctrl))]
        XCTAssertEqual(MacroEditing.dropShortcutChords(lone), lone)

        // The recorder itself drops a key that arrives with all three modifiers held (how a shortcut key looks to the tap).
        let rec = MacroRecorder(window: { win }, robloxFrontmost: { true })
        rec.start(at: 0)
        var e = RawInput(.keyDown, time: 0.5, keyCode: E); e.isShortcut = true
        rec.ingest(e)
        rec.ingest(RawInput(.keyUp, time: 0.6, keyCode: E))
        rec.ingest(RawInput(.keyDown, time: 1.0, keyCode: W)); rec.ingest(RawInput(.keyUp, time: 1.5, keyCode: W))
        XCTAssertEqual(rec.stop(at: 2).map(\.action), [.keyDown(code: W), .keyUp(code: W)])
    }

    func testEditingKeepsTimingAndBalance() {
        let steps = [MacroStep(delay: 1, .keyDown(code: W)), MacroStep(delay: 0.01, .mouseMove(x: 0.1, y: 0.1)), MacroStep(delay: 0.01, .mouseMove(x: 0.2, y: 0.1)),
                     MacroStep(delay: 0.01, .mouseMove(x: 0.3, y: 0.1)), MacroStep(delay: 2, .keyUp(code: W)), MacroStep(delay: 1, .keyDown(code: A)), MacroStep(delay: 1, .keyUp(code: A))]
        let merged = MacroEditing.mergeMouseMoves(steps)
        XCTAssertEqual(merged.count, 5)
        XCTAssertEqual(merged[1], MacroStep(delay: 0.03, .mouseMove(x: 0.3, y: 0.1)))
        XCTAssertEqual(merged.reduce(0) { $0 + $1.delay }, steps.reduce(0) { $0 + $1.delay }, accuracy: 1e-9)
        // Deleting the release of W would leave it stuck: the editor puts a release back.
        let deleted = MacroEditing.delete(steps, range: 4..<5)
        XCTAssertEqual(deleted.last?.action, .keyUp(code: W))
        XCTAssertEqual(deleted.reduce(0) { $0 + $1.delay }, steps.reduce(0) { $0 + $1.delay }, accuracy: 1e-9, "the rest keeps its timing")
        // Trim to the A press only.
        let trimmed = MacroEditing.trim(steps, to: 5..<7)
        XCTAssertEqual(trimmed, [MacroStep(delay: 0, .keyDown(code: A)), MacroStep(delay: 1, .keyUp(code: A))])
        XCTAssertEqual(MacroEditing.balance([MacroStep(delay: 1, .keyUp(code: W)), MacroStep(delay: 1, .keyDown(code: D))]),
                       [MacroStep(delay: 2, .keyDown(code: D)), MacroStep(delay: 0, .keyUp(code: D))])
    }
}

final class PianoRollTests: XCTestCase {
    private let w: UInt16 = 13, space: UInt16 = 49
    private func walk() -> [MacroStep] {
        [MacroStep(delay: 0.5, .keyDown(code: w)),          // 0.5
         MacroStep(delay: 1.0, .keyDown(code: space)),      // 1.5
         MacroStep(delay: 0.1, .keyUp(code: space)),        // 1.6
         MacroStep(delay: 0.9, .keyUp(code: w)),            // 2.5
         MacroStep(delay: 0.5, .mouseDown(button: .left, x: 0.5, y: 0.5)),   // 3.0
         MacroStep(delay: 0.1, .mouseUp(button: .left, x: 0.5, y: 0.5)),     // 3.1
         MacroStep(delay: 0.4, .wait(seconds: 2)),          // 3.5 .. 5.5
         MacroStep(delay: 0.5, .keyDown(code: w)),          // 6.0
         MacroStep(delay: 1.0, .keyUp(code: w))]            // 7.0
    }

    func testBarsAreHoldTimes() {
        let roll = PianoRoll.build(walk())
        XCTAssertEqual(roll.keyLanes, [w, space], "one lane per key, in the order the keys are first pressed")
        XCTAssertEqual(roll.duration, 7.0, accuracy: 0.0001)
        let keys = roll.notes.filter { if case .key = $0.lane { return true }; return false }
        XCTAssertEqual(keys.map(\.start), [0.5, 1.5, 6.0])
        XCTAssertEqual(keys.map { ($0.duration * 1000).rounded() / 1000 }, [2.0, 0.1, 1.0], "a bar is as long as the key is held")
        let click = roll.notes.first { $0.lane == .mouse }
        XCTAssertEqual(click?.start ?? 0, 3.0, accuracy: 0.0001)
        XCTAssertEqual(click?.isDrag, false)
        XCTAssertEqual(roll.waits.map(\.label), ["wait 2.0 s"])
        XCTAssertEqual(roll.waits.first?.time ?? 0, 3.5, accuracy: 0.0001)
    }

    func testTimesIncludePlainWaits() {
        XCTAssertEqual(PianoRoll.times(walk()).map { ($0 * 10).rounded() / 10 }, [0.5, 1.5, 1.6, 2.5, 3.0, 3.1, 3.5, 6.0, 7.0])
    }

    func testMovingANoteKeepsEverythingElseInPlace() {
        let steps = walk()
        let jump = steps[1].id
        let moved = PianoRollEdit.move([jump], by: 1.2, in: steps)       // the jump goes from 1.5 to 2.7, after W is released
        let roll = PianoRoll.build(moved)
        let note = roll.notes.first { $0.id == jump }
        XCTAssertEqual(note?.start ?? 0, 2.7, accuracy: 0.0001)
        XCTAssertEqual(note?.duration ?? 0, 0.1, accuracy: 0.0001, "its hold time is unchanged")
        XCTAssertEqual(roll.notes.first { $0.id == steps[0].id }?.duration ?? 0, 2.0, accuracy: 0.0001, "W is still held for two seconds")
        XCTAssertEqual(roll.notes.first { $0.lane == .mouse }?.start ?? 0, 3.0, accuracy: 0.0001)
        XCTAssertEqual(roll.duration, 7.0, accuracy: 0.0001, "the macro is as long as before")
        XCTAssertEqual(moved.count, steps.count)
        XCTAssertTrue(moved.allSatisfy { $0.delay >= 0 })
    }

    func testANoteCannotMoveBeforeTheStart() {
        let steps = walk()
        let moved = PianoRollEdit.move([steps[0].id], by: -5, in: steps)
        XCTAssertEqual(PianoRoll.build(moved).notes.first { $0.id == steps[0].id }?.start ?? -1, 0, accuracy: 0.0001)
    }

    func testTrimmingChangesOnlyTheHold() {
        let steps = walk()
        let trimmed = PianoRollEdit.trim(steps[0].id, toDuration: 0.6, in: steps)
        let roll = PianoRoll.build(trimmed)
        let note = roll.notes.first { $0.id == steps[0].id }
        XCTAssertEqual(note?.start ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(note?.duration ?? 0, 0.6, accuracy: 0.0001)
        XCTAssertEqual(roll.notes.first { $0.id == steps[1].id }?.start ?? 0, 1.5, accuracy: 0.0001, "the jump did not move")
        XCTAssertEqual(PianoRoll.build(PianoRollEdit.trim(steps[0].id, toDuration: -3, in: steps)).notes.first { $0.id == steps[0].id }?.duration ?? 0, 0.02, accuracy: 0.0001,
                       "a hold never becomes shorter than a tap")
    }

    func testDeletingSeveralNotesAtOnce() {
        let steps = walk()
        let left = PianoRollEdit.delete([steps[1].id, steps[4].id], in: steps)   // the jump and the click
        XCTAssertEqual(left.count, steps.count - 4, "each note goes with its release")
        let roll = PianoRoll.build(left)
        XCTAssertEqual(roll.keyLanes, [w])
        XCTAssertFalse(roll.hasMouse)
        XCTAssertEqual(roll.notes.map(\.start), [0.5, 6.0], "what is left stays where it was in time")
        XCTAssertEqual(roll.duration, 7.0, accuracy: 0.0001)
    }

    func testADragCarriesItsMouseMoves() {
        let steps = [MacroStep(delay: 1, .mouseDown(button: .right, x: 0.2, y: 0.5)),
                     MacroStep(delay: 0.2, .mouseMove(x: 0.4, y: 0.5)),
                     MacroStep(delay: 0.2, .mouseMove(x: 0.6, y: 0.5)),
                     MacroStep(delay: 0.1, .mouseUp(button: .right, x: 0.6, y: 0.5)),
                     MacroStep(delay: 1, .keyDown(code: w)), MacroStep(delay: 0.5, .keyUp(code: w))]
        let roll = PianoRoll.build(steps)
        XCTAssertEqual(roll.notes.first?.isDrag, true)
        XCTAssertGreaterThan(roll.motion.max() ?? 0, 0.9, "the mouse lane shows how much the mouse moves")
        let moved = PianoRollEdit.move([steps[0].id], by: 2.5, in: steps)   // now after the W press
        let times = PianoRoll.times(moved)
        let downAt = times[moved.firstIndex { $0.id == steps[0].id }!]
        XCTAssertEqual(downAt, 3.5, accuracy: 0.0001)
        XCTAssertEqual(times[moved.firstIndex { $0.id == steps[2].id }!] - downAt, 0.4, accuracy: 0.0001, "the moves inside the drag came along")
        XCTAssertEqual(PianoRollEdit.delete([steps[0].id], in: steps).count, 2, "deleting a drag removes its moves too")
    }
}
