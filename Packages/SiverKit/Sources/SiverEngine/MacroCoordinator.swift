import AppKit
import Foundation
import SiverCore
import SiverInput
import SiverMacro
import SiverNotify
import SiverVision

/// Totals Macro Studio keeps for the dashboard and the daily report.
public struct MacroStats: Codable, Equatable, Sendable {
    public struct Day: Codable, Equatable, Sendable {
        public var runs = 0
        public var autoClicks = 0
        public var recordings = 0
    }
    public var days: [String: Day] = [:]
    public var autoClicker = AutoClickerStats()
    public init() {}
}

/// Pure rules, kept apart from the machinery so they can be tested directly.
public enum MacroRules {
    /// Should this macro event be posted, given the macro's own notify setting?
    public static func shouldNotify(_ kind: MacroEvent.Kind, setting: MacroNotify, isError: Bool) -> Bool {
        switch (kind, setting) {
        case (.recorded, _): return true                      // the user just did this by hand
        case (_, .none): return false
        case (.stopped, .errors): return isError
        case (.started, .errors), (.finished, .errors): return false
        case (_, .startEnd): return true
        }
    }

    /// Names of the macros a trigger should start.
    public static func macros(for trigger: MacroTrigger, in library: [Macro]) -> [String] {
        library.filter { $0.reviewed && $0.settings.triggers.contains(trigger) }.map(\.name)
    }

    /// Schedules that are due. `lastRun` holds the last start per "name|minutes".
    public static func dueSchedules(in library: [Macro], lastRun: [String: Date], now: Date) -> [(name: String, minutes: Double)] {
        var due: [(String, Double)] = []
        for macro in library where macro.reviewed {
            for trigger in macro.settings.triggers {
                guard case .everyMinutes(let minutes) = trigger, minutes >= 1 else { continue }
                if let last = lastRun["\(macro.name)|\(minutes)"], now.timeIntervalSince(last) < minutes * 60 { continue }
                due.append((macro.name, minutes))
            }
        }
        return due
    }
}

/// Macro Studio inside the engine: one recorder, one player, one queue, the triggers, and the link to Discord.
public final class MacroCoordinator: @unchecked Sendable {
    public struct Status: Equatable, Sendable {
        public var recording = MacroRecorder.State.idle
        public var recordedSeconds: Double = 0
        public var recordedSteps = 0
        public var playing: MacroProgress?
        public var queued: [String] = []
        public var autoClicking = false
        public var lastResult = ""
        /// Why recording or playback cannot start, in a sentence.
        public var problem: String?
        public init() {}
    }

    public let library: MacroLibrary
    /// Which macros may play (set from the active profile). Checked on every start, triggers included.
    public var policy: MacroPolicy {
        get { cacheLock.lock(); defer { cacheLock.unlock() }; return policyValue }
        set { cacheLock.lock(); policyValue = newValue; cacheLock.unlock() }
    }
    private var policyValue = MacroPolicy.all
    private let guardian: Guardian
    private let radar: BiomeRadar
    private let catalog: BiomeCatalog
    private let supportDirectory: URL
    private let inputPaused: @Sendable () -> Bool
    public var log: (@Sendable (String) -> Void)?
    /// Called for every macro event that should reach Discord: (event, should attach a screenshot).
    public var announce: (@Sendable (MacroEvent, Bool) async -> Void)?
    /// A screen rectangle (global coordinates, top-left origin) whose clicks are never recorded: SiverSol's own recorder bar.
    public var ignoreInputIn: (@Sendable () -> CGRect?)?

    private let lock = NSLock()
    private let output: LiveMacroOutput
    private lazy var player = MacroPlayer(output: output, environment: makeEnvironment())
    private lazy var clicker = AutoClicker(output: output, environment: makeEnvironment(), cursor: { [weak self] in self?.cursorRatio() })
    private var recorder: MacroRecorder?
    private let cacheLock = NSLock()
    private var tap: InputTap?
    private var tapUsers = 0
    private var userTouch = false
    private var watchingForTouch = false
    private var queue: [(name: String, trigger: String, biomeEventId: String?, depth: Int)] = []
    private var worker: Task<Void, Never>?
    private var progress: MacroProgress?
    private var lastResult = ""
    private var problem: String?
    private var lastSchedule: [String: Date] = [:]
    private var statsValue = MacroStats()
    private var cachedWindow: (rect: CGRect?, at: TimeInterval) = (nil, 0)
    private var cachedFront: (value: Bool, at: TimeInterval) = (false, 0)
    private var startedAt = Date()

    public init(supportDirectory: URL, guardian: Guardian, radar: BiomeRadar, catalog: BiomeCatalog, inputPaused: @escaping @Sendable () -> Bool) {
        self.supportDirectory = supportDirectory
        self.guardian = guardian; self.radar = radar; self.catalog = catalog; self.inputPaused = inputPaused
        library = MacroLibrary(directory: supportDirectory.appendingPathComponent("Macros", isDirectory: true))
        let heldFile = supportDirectory.appendingPathComponent("held-keys.txt")
        // If the previous run died with keys down, let go of them before anything else.
        LiveMacroOutput.releaseLeftovers(file: heldFile, pid: FocusManager.robloxApp()?.processIdentifier)
        output = LiveMacroOutput(window: { RobloxWindowFinder.mainWindow()?.content }, pid: { FocusManager.robloxApp()?.processIdentifier }, heldFile: heldFile,
                                 robloxFrontmost: { FocusManager.robloxIsFrontmost })
        if let data = try? Data(contentsOf: supportDirectory.appendingPathComponent("macro-stats.json")),
           let saved = try? JSONDecoder().decode(MacroStats.self, from: data) { statsValue = saved }
        // A macro's first screen check must not wait for Vision to prepare its text model (see OCR.warmUp).
        Task.detached(priority: .utility) { OCR.warmUp() }
    }

    // MARK: status

    // Lock order: the recorder calls back into this class from the input thread while it holds its own lock
    // (to ask whether Roblox is in front). So nothing here may call the recorder while holding `lock`, and the
    // two answers the recorder asks for have a lock of their own. Breaking this freezes the app mid-recording.

    /// The recorder's state, read without holding `lock`.
    private var recordingState: MacroRecorder.State {
        lock.lock(); let rec = recorder; lock.unlock()
        return rec?.state ?? .idle
    }

    public var status: Status {
        lock.lock(); let rec = recorder; lock.unlock()
        var s = Status()
        s.recording = rec?.state ?? .idle
        s.recordedSeconds = rec?.elapsed(now: ProcessInfo.processInfo.systemUptime) ?? 0
        s.recordedSteps = rec?.stepCount ?? 0
        lock.lock(); defer { lock.unlock() }
        s.playing = progress
        s.queued = queue.map(\.name)
        s.autoClicking = clicker.isRunning
        s.lastResult = lastResult
        s.problem = problem
        return s
    }

    /// True while a macro plays, the auto clicker runs or a recording is in progress (anti-AFK stays quiet then).
    public var isBusy: Bool {
        if recordingState != .idle { return true }
        lock.lock(); defer { lock.unlock() }
        // `worker` covers the moment between taking a macro off the queue and its first progress report.
        return progress != nil || worker != nil || clicker.isRunning || !queue.isEmpty
    }

    public var stats: MacroStats { lock.lock(); defer { lock.unlock() }; return statsValue }

    public func todayTotals(now: Date = Date()) -> MacroStats.Day { stats.days[TimelineStore.day(now)] ?? MacroStats.Day() }

    private func bump(_ change: (inout MacroStats) -> Void) {
        lock.lock()
        change(&statsValue)
        let copy = statsValue
        lock.unlock()
        if let data = try? JSONEncoder().encode(copy) {
            try? data.write(to: supportDirectory.appendingPathComponent("macro-stats.json"), options: .atomic)
        }
    }

    // MARK: the world, as the player sees it

    private func robloxIsFrontmost() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        cacheLock.lock()
        if now - cachedFront.at < 0.15 { let v = cachedFront.value; cacheLock.unlock(); return v }
        cacheLock.unlock()
        let value = FocusManager.robloxIsFrontmost
        cacheLock.lock(); cachedFront = (value, now); cacheLock.unlock()
        return value
    }

    private func windowRect() -> CGRect? {
        let now = ProcessInfo.processInfo.systemUptime
        cacheLock.lock()
        if now - cachedWindow.at < 0.4 { let v = cachedWindow.rect; cacheLock.unlock(); return v }
        cacheLock.unlock()
        // The game area (the window without its title bar): macro positions are ratios of this.
        let rect = RobloxWindowFinder.mainWindow()?.content
        cacheLock.lock(); cachedWindow = (rect, now); cacheLock.unlock()
        return rect
    }

    private func cursorRatio() -> (x: Double, y: Double)? {
        guard robloxIsFrontmost(), let w = windowRect(), let p = CGEvent(source: nil)?.location, w.contains(p) else { return nil }
        return (Double((p.x - w.minX) / w.width), Double((p.y - w.minY) / w.height))
    }

    private static func check(_ verdict: GuardianVerdict) -> MacroCheck {
        switch verdict {
        case .approved: return .ok
        case .held(let why): return .hold(why)
        case .blocked(let why, _): return .stop(.guardian(why))
        }
    }

    private func makeEnvironment() -> MacroEnvironment {
        var env = MacroEnvironment()
        let guardian = self.guardian, radar = self.radar, catalog = self.catalog
        env.prepare = { [weak self] needsFocus in
            guard let self else { return "SiverSol is shutting down" }
            if self.inputPaused() { return "input is paused (panic key). Choose Resume automation first" }
            guard InputDriver.isTrusted else { return "SiverSol needs the Accessibility permission to press keys and click" }
            guard RobloxWindowFinder.mainWindow() != nil else { return "the Roblox window is not on screen" }
            self.output.keyboardToProcess = !needsFocus
            self.output.resetFocusLost()
            self.setTouchWatch(needsFocus)
            if needsFocus {
                guard FocusManager.robloxApp() != nil else { return "Roblox is not running" }
                guard await FocusManager.bringRobloxToFront(timeout: 1.5) else { return "Roblox did not come to the front" }
                try? await Task.sleep(nanoseconds: 150_000_000)
                self.clearTouch()
            }
            return nil
        }
        env.checkClick = { x, y in Self.check(await guardian.approve(.macroClick(x: x, y: y), maxLookAge: 1)) }
        env.checkItemClick = { x, y in
            let verdict = await guardian.approve(.macroItemClick(x: x, y: y), maxLookAge: 1)
            if verdict == .approved, guardian.itemPanelOnLastLook { return .okItem }
            return Self.check(verdict)
        }
        env.checkScreen = { Self.check(await guardian.approve(.key("macro")))  }
        env.userTouched = { [weak self] in self?.touched ?? false }
        env.focusLost = { [weak self] in self?.output.focusLost ?? false }
        env.windowLost = { [weak self] in self?.output.windowLost ?? false }
        env.robloxFrontmost = { FocusManager.robloxIsFrontmost }
        env.rareBiomeActive = { radar.snapshot.current.map { catalog.isRare($0.biome.key) } ?? false }
        env.currentBiome = { radar.snapshot.current?.biome.key.value }
        env.inGame = { radar.snapshot.phase == .inGame }
        env.textOnScreen = { text in
            guard let look = await Guardian.robloxLook() else { return false }
            let wanted = GuardianPolicy.label(text)
            return look.text.contains { GuardianPolicy.label($0.text).contains(wanted) }
        }
        return env
    }

    // MARK: the event tap (only while recording, or while a mouse macro plays)

    private var touched: Bool { lock.lock(); defer { lock.unlock() }; return userTouch }
    private func clearTouch() { lock.lock(); userTouch = false; lock.unlock() }

    private func setTouchWatch(_ on: Bool) {
        lock.lock(); let was = watchingForTouch; watchingForTouch = on; userTouch = false; lock.unlock()
        if on && !was { retainTap() } else if !on && was { releaseTap() }
    }

    @discardableResult
    private func retainTap() -> Bool {
        lock.lock()
        tapUsers += 1
        if tap == nil {
            tap = InputTap { [weak self] raw, own in self?.tapEvent(raw, own: own) }
        }
        let t = tap
        lock.unlock()
        let ok = t?.start() ?? false
        if !ok { releaseTap() }
        return ok
    }

    private func releaseTap() {
        lock.lock()
        tapUsers = max(0, tapUsers - 1)
        let stop = tapUsers == 0 ? tap : nil
        if tapUsers == 0 { tap = nil }
        lock.unlock()
        stop?.stop()
    }

    /// Does this input mean the user wants the mouse and keyboard back? Pressing a key, clicking, scrolling or
    /// moving the mouse does. Letting go of something does not (the keys of the shortcut that started the macro
    /// are still coming up when it begins), and neither does one of SiverSol's own shortcuts.
    static func countsAsTakingOver(_ raw: RawInput) -> Bool {
        switch raw.kind {
        case .keyUp, .mouseUp: return false
        case .keyDown: return !raw.isShortcut
        case .mouseMove, .mouseDrag, .mouseDown, .scroll: return true
        }
    }

    private func tapEvent(_ raw: RawInput, own: Bool) {
        if own { return }                      // SiverSol's own playback: never recorded, never "the user"
        lock.lock()
        let rec = recorder
        if watchingForTouch, Self.countsAsTakingOver(raw) { userTouch = true }
        lock.unlock()
        // A click on SiverSol's own floating recorder bar is not a click in Roblox, even where the two overlap.
        switch raw.kind {
        case .mouseDown, .mouseUp, .scroll:
            if let own = ignoreInputIn?(), own.contains(raw.location) { return }
        default: break
        }
        rec?.ingest(raw)                       // the recorder itself drops everything unless Roblox is frontmost
    }

    // MARK: recording

    /// Start recording. Returns nil when it started, or a sentence saying why it could not.
    public func startRecording(options: RecorderOptions = RecorderOptions()) -> String? {
        if inputPaused() { return "Input is paused. Choose Resume automation first." }
        let recording = recordingState != .idle
        lock.lock()
        let busy = progress != nil || recording
        lock.unlock()
        if busy { return "Stop the macro that is playing or recording first." }
        guard InputTap.permissions().accessibility else { return "Recording needs the Accessibility permission (the same one SiverSol uses to press keys)." }
        guard windowRect() != nil else { return "Open Roblox first: recording only happens inside the Roblox window." }
        let rec = MacroRecorder(options: options, window: { [weak self] in self?.windowRect() }, robloxFrontmost: { [weak self] in self?.robloxIsFrontmost() ?? false })
        guard retainTap() else { return "macOS did not allow SiverSol to watch input. Check Accessibility in System Settings." }
        rec.start(at: ProcessInfo.processInfo.systemUptime)
        lock.lock(); recorder = rec; problem = nil; lock.unlock()
        log?("macro: recording started")
        return nil
    }

    public func pauseRecording() { lock.lock(); let r = recorder; lock.unlock(); r?.pause(at: ProcessInfo.processInfo.systemUptime) }
    public func resumeRecording() { lock.lock(); let r = recorder; lock.unlock(); r?.resume(at: ProcessInfo.processInfo.systemUptime) }

    /// Stop recording and save. Returns the saved macro, or nil when nothing was recorded.
    @discardableResult
    public func stopRecording(name: String?) -> Macro? {
        lock.lock(); let rec = recorder; recorder = nil; lock.unlock()
        guard let rec else { return nil }
        let steps = MacroEditing.dropShortcutChords(rec.stop(at: ProcessInfo.processInfo.systemUptime))
        releaseTap()
        guard !steps.isEmpty else {
            lock.lock(); lastResult = "Nothing was recorded (was Roblox the frontmost app?)."; lock.unlock()
            return nil
        }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        var base = (name ?? "").trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "Recording \(f.string(from: Date()))" }
        var macro = Macro(name: library.load(base) == nil ? base : library.uniqueName(base), steps: steps)
        macro.windowWidth = Double(rec.recordedWindow.width); macro.windowHeight = Double(rec.recordedWindow.height)
        macro.titleBar = Double(RobloxWindowFinder.mainWindow()?.titleBar ?? 0)
        do { try library.save(macro) } catch {
            lock.lock(); lastResult = "Could not save the recording: \(error)"; lock.unlock()
            return nil
        }
        bump { $0.days[TimelineStore.day(Date()), default: .init()].recordings += 1 }
        lock.lock(); lastResult = "Saved “\(macro.name)” (\(steps.count) steps, \(DiscordTime.duration(macro.duration)))."; lock.unlock()
        log?("macro: recorded \(macro.name), \(steps.count) steps")
        var event = MacroEvent(id: "macro-rec-\(Int(Date().timeIntervalSince1970 * 1000))", kind: .recorded, name: macro.name, at: Date())
        event.steps = steps.count; event.durationS = macro.duration
        let announce = self.announce
        Task { await announce?(event, false) }
        return macro
    }

    // MARK: playing (one at a time, with a queue)

    /// Queue a macro. Returns nil when queued, or why not.
    @discardableResult
    public func enqueue(_ name: String, trigger: String = "manual", biomeEventId: String? = nil, depth: Int = 0) -> String? {
        guard let macro = library.load(name) else { return "There is no macro called “\(name)”." }
        guard macro.reviewed else { return "“\(name)” was imported and has not been reviewed yet. Open it in the Macros tab first." }
        if let refusal = MacroRules.refusal(macro, policy: policy) { return refusal }
        let recording = recordingState != .idle
        lock.lock()
        if progress?.name == name || queue.contains(where: { $0.name == name }) { lock.unlock(); return "“\(name)” is already playing or queued." }
        if recording { lock.unlock(); return "Stop the recording first." }
        queue.append((name, trigger, biomeEventId, depth))
        let start = worker == nil
        if start { worker = Task { [weak self] in await self?.drain() } }
        lock.unlock()
        return nil
    }

    public func stopCurrent(_ reason: MacroStopReason = .user) {
        lock.lock(); queue.removeAll(); lock.unlock()
        player.stop(reason)
        clicker.stop(reason)
    }

    private func drain() async {
        while true {
            lock.lock()
            guard !queue.isEmpty else { worker = nil; lock.unlock(); return }
            let next = queue.removeFirst()
            lock.unlock()
            await run(next.name, trigger: next.trigger, biomeEventId: next.biomeEventId, depth: next.depth)
        }
    }

    private func run(_ name: String, trigger: String, biomeEventId: String?, depth: Int) async {
        guard let macro = library.load(name) else { return }
        let began = Date()
        let id = "macro-\(Int(began.timeIntervalSince1970 * 1000))"
        lock.lock()
        progress = MacroProgress(name: name, loop: 0, totalLoops: macro.settings.loops, step: 0, totalSteps: macro.steps.count, startedAt: began)
        problem = nil
        lock.unlock()
        log?("macro: \(name) started (\(trigger))")
        if MacroRules.shouldNotify(.started, setting: macro.settings.notify, isError: false) {
            var e = MacroEvent(id: id + "-start", kind: .started, name: name, at: began, trigger: trigger, biomeEventId: biomeEventId)
            e.steps = macro.steps.count
            await announce?(e, false)
        }
        let result = await player.play(macro) { [weak self] p in
            guard let self else { return }
            self.lock.lock(); self.progress = p; self.lock.unlock()
        }
        setTouchWatch(false)
        bump { $0.days[TimelineStore.day(began), default: .init()].runs += 1 }
        var event = MacroEvent(id: id + "-end", kind: result.stopped == nil ? .finished : .stopped, name: name, at: Date(), trigger: trigger, biomeEventId: biomeEventId)
        event.loops = result.loopsCompleted; event.steps = result.stepsPlayed; event.durationS = result.duration
        var isGuardian = false
        if let why = result.stopped {
            event.reason = why.label
            if case .guardian = why { isGuardian = true }
            event.guardianStop = isGuardian
        }
        lock.lock()
        progress = nil
        lastResult = result.stopped.map { "“\(name)” \($0.label)." } ?? "“\(name)” finished: \(result.loopsCompleted) loop\(result.loopsCompleted == 1 ? "" : "s") in \(DiscordTime.duration(result.duration))."
        if case .failed(let why)? = result.stopped { problem = why }
        lock.unlock()
        log?("macro: \(name) \(result.stopped?.label ?? "finished")")
        if MacroRules.shouldNotify(event.kind, setting: macro.settings.notify, isError: result.stopped?.isError ?? false) {
            await announce?(event, isGuardian)
        }
        if result.stopped == nil, let next = macro.settings.chainTo, depth < 5 {
            enqueue(next, trigger: "after \(name)", biomeEventId: biomeEventId, depth: depth + 1)
        }
    }

    // MARK: auto clicker

    public func startAutoClicker(_ config: AutoClickerConfig) -> String? {
        if inputPaused() { return "Input is paused. Choose Resume automation first." }
        let recording = recordingState != .idle
        lock.lock(); let busy = progress != nil || recording; lock.unlock()
        if busy { return "Stop the macro that is playing or recording first." }
        guard !clicker.isRunning else { return nil }
        Task { [weak self] in
            guard let self else { return }
            let run = await self.clicker.run(config)
            self.setTouchWatch(false)
            self.bump {
                $0.autoClicker.totalClicks += run.clicks; $0.autoClicker.totalSeconds += run.seconds; $0.autoClicker.runs += 1
                $0.days[TimelineStore.day(Date()), default: .init()].autoClicks += run.clicks
            }
            self.lock.lock()
            self.lastResult = "Auto clicker: \(run.clicks) clicks in \(DiscordTime.duration(run.seconds))" + (run.stopped.map { ", \($0.label)." } ?? ".")
            self.lock.unlock()
            self.log?("auto clicker: \(run.clicks) clicks, \(run.stopped?.label ?? "limit reached")")
        }
        return nil
    }

    public func stopAutoClicker() { clicker.stop(.user) }

    // MARK: triggers

    private func fire(_ trigger: MacroTrigger, biomeEventId: String? = nil) {
        for name in MacroRules.macros(for: trigger, in: library.all()) {
            enqueue(name, trigger: trigger.label, biomeEventId: biomeEventId)
        }
    }

    /// Feed live events in; macros waiting for a biome start or end are queued.
    public func handle(_ event: SiverEvent) {
        switch event {
        case .biomeStarted(let s) where !s.wasRunning: fire(.biomeStarted(s.biome.key.value), biomeEventId: s.id)
        case .biomeEnded(let e) where e.reason == .changed: fire(.biomeEnded(e.biome.key.value), biomeEventId: e.startedEventId)
        default: break
        }
    }

    public func rejoined() { fire(.afterRejoin) }
    public func dailyReset() { fire(.dailyReset) }

    /// Called every few seconds by the engine: start the schedules that are due.
    public func tick(now: Date = Date()) {
        let all = library.all()
        lock.lock()
        // A schedule first fires one full interval after SiverSol started, not the moment it starts.
        for macro in all { for t in macro.settings.triggers { if case .everyMinutes(let m) = t, lastSchedule["\(macro.name)|\(m)"] == nil { lastSchedule["\(macro.name)|\(m)"] = startedAt } } }
        let due = MacroRules.dueSchedules(in: all, lastRun: lastSchedule, now: now)
        for d in due { lastSchedule["\(d.name)|\(d.minutes)"] = now }
        lock.unlock()
        for d in due { enqueue(d.name, trigger: MacroTrigger.everyMinutes(d.minutes).label) }
    }

    /// When the next scheduled macro is due, if any macro has a schedule.
    public func nextScheduledRun() -> Date? {
        let all = library.all()
        lock.lock(); defer { lock.unlock() }
        var next: Date?
        for macro in all where macro.reviewed {
            for t in macro.settings.triggers {
                guard case .everyMinutes(let m) = t, m >= 1 else { continue }
                let due = (lastSchedule["\(macro.name)|\(m)"] ?? startedAt).addingTimeInterval(m * 60)
                if next == nil || due < next! { next = due }
            }
        }
        return next
    }

    /// Panic or shutdown: stop everything and let go of every key.
    public func shutdown(_ reason: MacroStopReason = .user) {
        stopCurrent(reason)
        if (status.recording) != .idle { stopRecording(name: nil) }
        output.releaseAll()
    }
}
