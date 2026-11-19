import Foundation
import SiverCore

/// Where a macro's input goes. The live implementation posts CGEvents; tests record calls.
public protocol MacroOutput: AnyObject, Sendable {
    func keyDown(_ code: UInt16)
    func keyUp(_ code: UInt16)
    func mouseMove(x: Double, y: Double)
    func mouseDown(_ button: MouseButton, x: Double, y: Double)
    func mouseUp(_ button: MouseButton, x: Double, y: Double)
    func mouseDelta(dx: Double, dy: Double)
    func scroll(dx: Double, dy: Double)
    /// Let go of every key and button this output has pressed. Must be safe to call at any time, any number of times.
    func releaseAll()
}

public enum MacroStopReason: Equatable, Sendable, Codable {
    case user
    case panic
    case guardian(String)
    case rareBiome
    case userInput
    /// Another app came to the front while a macro that needs Roblox in front was playing.
    case lostFocus
    /// The Roblox window could not be found while a macro that uses the mouse was playing.
    case noWindow
    case timeout(String)
    case failed(String)

    public var label: String {
        switch self {
        case .user: return "stopped by you"
        case .panic: return "stopped by the panic key"
        case .guardian(let why): return "stopped by Guardian: \(why)"
        case .rareBiome: return "stopped because a rare biome started"
        case .userInput: return "stopped because the mouse or keyboard was used"
        case .lostFocus: return "stopped because Roblox was no longer the front window"
        case .noWindow: return "stopped because the Roblox window could not be found (closed, minimised, or its display was unplugged)"
        case .timeout(let what): return "gave up waiting for \(what)"
        case .failed(let why): return "could not run: \(why)"
        }
    }
    /// Stops worth a message even when the macro only reports errors.
    public var isError: Bool { self != .user }
}

/// What a safety check says about going on.
public enum MacroCheck: Equatable, Sendable {
    case ok
    /// Allowed, and it may use an item (an item panel is open): the player counts it toward the hourly cap.
    case okItem
    /// Wait (a roll cutscene is playing), then carry on.
    case hold(String)
    case stop(MacroStopReason)
}

public struct MacroProgress: Equatable, Sendable {
    public var name: String
    public var loop: Int
    public var totalLoops: Int        // 0 = forever
    public var step: Int
    public var totalSteps: Int
    public var startedAt: Date

    public init(name: String, loop: Int, totalLoops: Int, step: Int, totalSteps: Int, startedAt: Date) {
        self.name = name; self.loop = loop; self.totalLoops = totalLoops; self.step = step; self.totalSteps = totalSteps; self.startedAt = startedAt
    }

    public var line: String {
        let loops = totalLoops == 0 ? "loop \(loop + 1)" : "loop \(loop + 1) of \(totalLoops)"
        let percent = totalSteps > 0 ? Int(Double(step) / Double(totalSteps) * 100) : 0
        return "▶ \(name) · \(loops) · \(percent)%"
    }
}

public struct MacroRunResult: Equatable, Sendable {
    public var name: String
    public var loopsCompleted: Int
    public var stepsPlayed: Int
    public var duration: TimeInterval
    /// nil = ran to the end.
    public var stopped: MacroStopReason?
}

/// Item bar and menu column: clicking there uses or opens things (hard rule 3), so macros need explicit permission.
public enum MacroZones {
    // Measured as ratios of a whole window with a title bar; converted to ratios of the game area, so on such
    // a window the zones are where they always were.
    static func content(_ y: Double) -> Double {
        GameChrome.contentY(fromWindow: y, windowHeight: Double(GameChrome.referenceWindowHeight), titleBar: Double(GameChrome.referenceTitleBar))
    }
    static let itemBarTop = content(0.90), menuTop = content(0.38), menuBottom = content(0.66)

    /// `x`, `y`: ratios of the game area.
    public static func isItemOrMenu(x: Double, y: Double) -> Bool {
        (x >= 0.58 && y >= itemBarTop) || (x <= 0.07 && y >= menuTop && y <= menuBottom)
    }
}

/// Everything the player needs from the outside world, as closures (real ones in the engine, fakes in tests).
public struct MacroEnvironment: Sendable {
    /// Monotonic seconds.
    public var now: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    public var sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }
    /// Bring Roblox forward if the macro needs the mouse. nil = ready; otherwise why it cannot start.
    public var prepare: @Sendable (_ needsFocus: Bool) async -> String? = { _ in nil }
    /// Guardian's verdict for a click at this window position, on a fresh (or under one second old) look.
    public var checkClick: @Sendable (_ x: Double, _ y: Double) async -> MacroCheck = { _, _ in .ok }
    /// The same check for a macro that was allowed to click where an item can be used. Returns `.okItem` when
    /// an item panel is open, so the click is counted.
    public var checkItemClick: @Sendable (_ x: Double, _ y: Double) async -> MacroCheck = { _, _ in .ok }
    /// Guardian's verdict for the screen as it is now (called every 5 s during playback).
    public var checkScreen: @Sendable () async -> MacroCheck = { .ok }
    /// True the moment the user touches the mouse or keyboard (only asked for macros that use the mouse).
    public var userTouched: @Sendable () -> Bool = { false }
    /// True once an input was dropped because Roblox was not the front app.
    public var focusLost: @Sendable () -> Bool = { false }
    /// True once a mouse step found no Roblox window to aim at.
    public var windowLost: @Sendable () -> Bool = { false }
    /// Is Roblox the front app? The auto clicker waits while it is not.
    public var robloxFrontmost: @Sendable () -> Bool = { true }
    public var rareBiomeActive: @Sendable () -> Bool = { false }
    public var textOnScreen: @Sendable (String) async -> Bool = { _ in false }
    public var currentBiome: @Sendable () -> String? = { nil }
    public var inGame: @Sendable () -> Bool = { true }
    /// Random number in 0..<1, for humanize.
    public var random: @Sendable () -> Double = { Double.random(in: 0..<1) }
    public init() {}
}

/// Plays one macro at a time. Steps are scheduled against the time the loop started, not against each other,
/// so small sleep overshoots do not add up: a minute-long walk ends within a few milliseconds of the recording.
public final class MacroPlayer: @unchecked Sendable {
    private let output: MacroOutput
    private let env: MacroEnvironment
    private let lock = NSLock()
    private var stopRequest: MacroStopReason?
    private var playing = false
    private var screenVerdict = MacroCheck.ok
    private var itemClicks: [TimeInterval] = []
    private var lastCheckAt: TimeInterval = 0
    private var checkInFlight = false
    /// How often the screen is looked at during playback.
    public static let screenCheckInterval: TimeInterval = 5
    /// Longest single sleep, so stop requests, the user's hands and safety verdicts are noticed quickly.
    static let slice: TimeInterval = 0.05

    public init(output: MacroOutput, environment: MacroEnvironment = MacroEnvironment()) {
        self.output = output; self.env = environment
    }

    public var isPlaying: Bool { lock.lock(); defer { lock.unlock() }; return playing }

    /// Ask the running macro to stop. Keys are released by the player on its way out.
    public func stop(_ reason: MacroStopReason = .user) {
        lock.lock(); if stopRequest == nil { stopRequest = reason }; lock.unlock()
    }

    private var requested: MacroStopReason? { lock.lock(); defer { lock.unlock() }; return stopRequest }
    private var verdict: MacroCheck {
        get { lock.lock(); defer { lock.unlock() }; return screenVerdict }
        set { lock.lock(); screenVerdict = newValue; lock.unlock() }
    }

    public func play(_ macro: Macro, progress: (@Sendable (MacroProgress) -> Void)? = nil) async -> MacroRunResult {
        guard begin() else { return MacroRunResult(name: macro.name, loopsCompleted: 0, stepsPlayed: 0, duration: 0, stopped: .failed("another macro is playing")) }
        let started = env.now()
        let startedAt = Date()
        var loopsDone = 0, stepsPlayed = 0
        var stopped: MacroStopReason?

        // Whatever happens below, nothing stays pressed.
        defer {
            output.releaseAll()
            end()
        }

        let usesMouse = !macro.isKeyboardOnly
        if let problem = await env.prepare(usesMouse) {
            return MacroRunResult(name: macro.name, loopsCompleted: 0, stepsPlayed: 0, duration: 0, stopped: .failed(problem))
        }
        // One look before the first step; after that the screen is re-checked every 5 s without delaying any key press.
        verdict = await env.checkScreen()
        setLastCheck(env.now())

        let speed = min(10, max(0.25, macro.settings.speed))
        let totalLoops = max(0, macro.settings.loops)
        var loop = 0
        outer: while totalLoops == 0 || loop < totalLoops {
            var base = env.now()
            var scheduled = 0.0
            for (index, step) in macro.steps.enumerated() {
                var delay = step.delay / speed
                if macro.settings.humanize, delay > 0.02 {
                    delay += (env.random() - 0.5) * 2 * min(0.008, delay * 0.05)
                }
                scheduled += max(0, delay)
                // Sleep toward the scheduled moment in short slices, watching for reasons to stop or wait.
                while true {
                    if let why = await interruption(macro: macro, usesMouse: usesMouse, base: &base) { stopped = why; break outer }
                    let remaining = base + scheduled - env.now()
                    if remaining <= 0 { break }
                    await env.sleep(min(remaining, Self.slice))
                }
                switch await perform(step.action, macro: macro, base: &base) {
                case .ok, .okItem: stepsPlayed += 1
                case .stop(let why): stopped = why; break outer
                case .hold: break
                }
                progress?(MacroProgress(name: macro.name, loop: loop, totalLoops: totalLoops, step: index + 1, totalSteps: macro.steps.count, startedAt: startedAt))
            }
            loopsDone += 1
            loop += 1
            output.releaseAll()
            if totalLoops == 0 || loop < totalLoops {
                let until = env.now() + macro.settings.loopDelayS
                while env.now() < until {
                    if let why = await interruption(macro: macro, usesMouse: usesMouse, base: &base) { stopped = why; break outer }
                    await env.sleep(min(until - env.now(), Self.slice))
                }
            }
            if macro.steps.isEmpty { break }
        }
        return MacroRunResult(name: macro.name, loopsCompleted: loopsDone, stepsPlayed: stepsPlayed, duration: env.now() - started, stopped: stopped)
    }

    private func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !playing else { return false }
        playing = true; stopRequest = nil; screenVerdict = .ok
        return true
    }

    private func end() { lock.lock(); playing = false; lock.unlock() }

    private func setLastCheck(_ t: TimeInterval) { lock.lock(); lastCheckAt = t; lock.unlock() }

    /// Start a screen check in the background when one is due. It reports through `verdict`; nothing waits for it.
    private func startScreenCheckIfDue() {
        let now = env.now()
        lock.lock()
        let due = !checkInFlight && now - lastCheckAt >= Self.screenCheckInterval
        if due { checkInFlight = true; lastCheckAt = now }
        lock.unlock()
        guard due else { return }
        let env = self.env
        Task { [weak self] in
            let v = await env.checkScreen()
            guard let self else { return }
            self.lock.lock()
            self.checkInFlight = false
            // A stop verdict is never overwritten by a later, calmer look.
            if case .stop = self.screenVerdict {} else { self.screenVerdict = v }
            self.lock.unlock()
        }
    }

    /// A reason to stop now, or nil. A hold (cutscene) releases the keys, waits it out and shifts the schedule.
    private func interruption(macro: Macro, usesMouse: Bool, base: inout TimeInterval) async -> MacroStopReason? {
        if let r = requested { return r }
        if macro.settings.pauseDuringRareBiomes, env.rareBiomeActive() { return .rareBiome }
        if usesMouse, env.userTouched() { return .userInput }
        if env.windowLost() { return .noWindow }
        if env.focusLost() { return .lostFocus }
        startScreenCheckIfDue()
        switch verdict {
        case .ok, .okItem: return nil
        case .stop(let why): return why
        case .hold:
            output.releaseAll()
            let began = env.now()
            while case .hold = verdict {
                if let r = requested { return r }
                await env.sleep(0.25)
                verdict = await env.checkScreen()
            }
            if case .stop(let why) = verdict { return why }
            base += env.now() - began
            setLastCheck(env.now())
            return nil
        }
    }

    private func perform(_ action: MacroAction, macro: Macro, base: inout TimeInterval) async -> MacroCheck {
        func jitter(_ v: Double) -> Double {
            macro.settings.humanize ? min(1, max(0, v + (env.random() - 0.5) * 0.004)) : v
        }
        switch action {
        case .keyDown(let code): output.keyDown(code)
        case .keyUp(let code): output.keyUp(code)
        case .mouseMove(let x, let y): output.mouseMove(x: jitter(x), y: jitter(y))
        case .mouseDown(let button, let x, let y):
            // Every click passes Guardian first. The time the check takes is added to the schedule, so the
            // rest of the macro keeps its rhythm.
            let began = env.now()
            let allowed = macro.settings.allowItemAndMenuClicks
            let inZone = MacroZones.isItemOrMenu(x: x, y: y)
            if inZone, !allowed {
                return .stop(.guardian("this macro is not allowed to click the item bar or the menu buttons"))
            }
            func look() async -> MacroCheck { allowed ? await env.checkItemClick(x, y) : await env.checkClick(x, y) }
            var check = await look()
            while case .hold = check {
                if let r = requested { return .stop(r) }
                await env.sleep(0.25)
                check = await look()
            }
            if case .stop(let why) = check { return .stop(why) }
            // Clicks that can use an item (the item bar, the menu column, anywhere while an item panel is open)
            // are limited per hour.
            if inZone || check == .okItem {
                let hourAgo = began - 3600
                itemClicks.removeAll { $0 < hourAgo }
                guard itemClicks.count < macro.settings.itemClickHourlyCap else {
                    return .stop(.guardian("the hourly limit of \(macro.settings.itemClickHourlyCap) item and menu clicks was reached"))
                }
                itemClicks.append(began)
            }
            base += env.now() - began
            output.mouseDown(button, x: jitter(x), y: jitter(y))
        case .mouseUp(let button, let x, let y): output.mouseUp(button, x: x, y: y)
        case .mouseDelta(let dx, let dy): output.mouseDelta(dx: dx, dy: dy)
        case .scroll(let dx, let dy): output.scroll(dx: dx, dy: dy)
        case .wait(let seconds):
            let began = env.now()
            while env.now() - began < seconds {
                if let r = requested { return .stop(r) }
                await env.sleep(min(seconds - (env.now() - began), Self.slice))
            }
            base += env.now() - began
        case .waitText(let text, let timeout):
            return await waitFor("“\(text)” on screen", timeout: timeout, every: 1, base: &base) { await self.env.textOnScreen(text) }
        case .waitBiome(let biome, let timeout):
            let wanted = BiomeKey(biome).value
            return await waitFor("biome \(wanted)", timeout: timeout, every: 0.25, base: &base) { self.env.currentBiome() == wanted }
        case .waitInGame(let timeout):
            return await waitFor("the game to load", timeout: timeout, every: 0.25, base: &base) { self.env.inGame() }
        }
        return .ok
    }

    private func waitFor(_ what: String, timeout: Double, every: Double, base: inout TimeInterval, _ condition: () async -> Bool) async -> MacroCheck {
        let began = env.now()
        output.releaseAll()   // nothing is held while waiting on the game
        while true {
            if let r = requested { return .stop(r) }
            if await condition() { break }
            if env.now() - began >= timeout { return .stop(.timeout(what)) }
            await env.sleep(every)
        }
        base += env.now() - began
        return .ok
    }
}

// MARK: - auto clicker

public struct AutoClickerConfig: Equatable, Sendable, Codable {
    public enum Mode: String, Codable, Sendable, CaseIterable { case toggle, hold }
    /// Fixed interval between clicks.
    public var intervalMs: Double = 100
    public var randomize = false
    public var minMs: Double = 80
    public var maxMs: Double = 140
    public var button: MouseButton = .left
    public var mode: Mode = .toggle
    public var stopAfterClicks: Int?
    public var stopAfterMinutes: Double?
    public init() {}
}

public struct AutoClickerStats: Equatable, Sendable, Codable {
    public var totalClicks = 0
    public var runs = 0
    public var totalSeconds: Double = 0
    public init() {}
    public var averageCPS: Double { totalSeconds > 0 ? Double(totalClicks) / totalSeconds : 0 }
}

/// Clicks at the cursor while it is inside the Roblox window. Each click goes through the same Guardian check as a macro click.
public final class AutoClicker: @unchecked Sendable {
    private let output: MacroOutput
    private let env: MacroEnvironment
    private let cursor: @Sendable () -> (x: Double, y: Double)?
    private let lock = NSLock()
    private var stopRequest: MacroStopReason?
    private var running = false

    public init(output: MacroOutput, environment: MacroEnvironment, cursor: @escaping @Sendable () -> (x: Double, y: Double)?) {
        self.output = output; self.env = environment; self.cursor = cursor
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    public func stop(_ reason: MacroStopReason = .user) { lock.lock(); if stopRequest == nil { stopRequest = reason }; lock.unlock() }
    private var requested: MacroStopReason? { lock.lock(); defer { lock.unlock() }; return stopRequest }

    private func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return false }
        running = true; stopRequest = nil
        return true
    }
    private func end() { lock.lock(); running = false; lock.unlock() }

    /// Runs until stopped or a limit is reached. Returns (clicks, seconds, why it ended; nil = a limit).
    public func run(_ config: AutoClickerConfig) async -> (clicks: Int, seconds: Double, stopped: MacroStopReason?) {
        guard begin() else { return (0, 0, .failed("the auto clicker is already running")) }
        defer { output.releaseAll(); end() }
        if let problem = await env.prepare(true) { return (0, 0, .failed(problem)) }
        let began = env.now()
        var clicks = 0
        var next = began
        while true {
            if let r = requested { return (clicks, env.now() - began, r) }
            if let limit = config.stopAfterClicks, clicks >= limit { break }
            if let minutes = config.stopAfterMinutes, env.now() - began >= minutes * 60 { break }
            if env.rareBiomeActive() { return (clicks, env.now() - began, .rareBiome) }
            let wait = next - env.now()
            if wait > 0 { await env.sleep(min(wait, MacroPlayer.slice)); continue }
            guard env.robloxFrontmost() else { next = env.now() + 0.1; continue }   // another app is in front: no click
            guard let p = cursor() else { next = env.now() + 0.1; continue }   // cursor outside the Roblox window: no click
            if MacroZones.isItemOrMenu(x: p.x, y: p.y) { return (clicks, env.now() - began, .guardian("the auto clicker does not click the item bar or the menu buttons")) }
            switch await env.checkClick(p.x, p.y) {
            case .stop(let why): return (clicks, env.now() - began, why)
            case .hold: next = env.now() + 0.25; continue
            case .okItem: return (clicks, env.now() - began, .guardian("the auto clicker does not click while an item window is open"))
            case .ok: break
            }
            output.mouseDown(config.button, x: p.x, y: p.y)
            output.mouseUp(config.button, x: p.x, y: p.y)
            clicks += 1
            let interval = config.randomize ? config.minMs + (max(config.minMs, config.maxMs) - config.minMs) * env.random() : config.intervalMs
            next = max(next, env.now() - 1) + max(0.01, interval / 1000)
        }
        return (clicks, env.now() - began, nil)
    }
}

// MARK: - library

/// Macros on disk: `~/Library/Application Support/SiverSol/Macros/<name>.svmacro`.
public final class MacroLibrary: @unchecked Sendable {
    public let directory: URL

    public init(directory: URL = SiverSol.supportDirectory.appendingPathComponent("Macros", isDirectory: true)) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func fileName(for name: String) -> String {
        let safe = name.map { $0 == "/" || $0 == ":" || $0 == "\\" ? "-" : $0 }
        return String(safe).trimmingCharacters(in: .whitespaces) + "." + Macro.fileExtension
    }

    public func url(for name: String) -> URL { directory.appendingPathComponent(Self.fileName(for: name)) }

    /// Every valid macro, by name. Files that fail validation are skipped, not loaded "as far as possible".
    public func all() -> [Macro] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == Macro.fileExtension }
            .compactMap { try? MacroCodec.decode(Data(contentsOf: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func load(_ name: String) -> Macro? {
        (try? Data(contentsOf: url(for: name))).flatMap { try? MacroCodec.decode($0) }
    }

    public func save(_ macro: Macro) throws {
        try MacroCodec.validate(macro)
        try MacroCodec.encode(macro).write(to: url(for: macro.name), options: .atomic)
    }

    public func delete(_ name: String) { try? FileManager.default.removeItem(at: url(for: name)) }

    public func rename(_ old: String, to new: String) throws {
        guard var macro = load(old) else { throw MacroError.notAMacro }
        macro.name = new
        try save(macro)
        if Self.fileName(for: old) != Self.fileName(for: new) { delete(old) }
    }

    /// Read and validate a macro from anywhere. It is marked "not reviewed", so it will not run until the user
    /// has seen its steps. Nothing is saved until `save` is called.
    public func previewImport(_ url: URL) throws -> Macro {
        var macro = try MacroCodec.decode(Data(contentsOf: url))
        macro.reviewed = false
        // Imported macros never arrive with their own triggers switched on or with item clicks allowed.
        macro.settings.triggers = []
        macro.settings.chainTo = nil
        macro.settings.allowItemAndMenuClicks = false
        if load(macro.name) != nil { macro.name = uniqueName(macro.name) }
        return macro
    }

    public func uniqueName(_ base: String) -> String {
        var n = 2
        while load("\(base) \(n)") != nil { n += 1 }
        return "\(base) \(n)"
    }

    public func export(_ name: String, to destination: URL) throws {
        guard let macro = load(name) else { throw MacroError.notAMacro }
        try MacroCodec.encode(macro).write(to: destination, options: .atomic)
    }
}
