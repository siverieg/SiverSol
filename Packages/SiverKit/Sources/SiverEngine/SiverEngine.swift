import AppKit
import Foundation
import SiverCore
import SiverInput
import SiverMacro
import SiverNotify
import SiverVision

/// The running macro: Biome Radar -> timeline -> Notify Mesh, plus the Live Session Card.
/// The app and `siversolctl run` both host this, so what is tested headless is what ships.
public final class SiverEngine: @unchecked Sendable {
    public struct Options: Sendable {
        public var logsDirectory: URL = SiverSol.logsDirectory
        public var supportDirectory: URL = SiverSol.supportDirectory
        public var liveCard = true
        /// Keep the Mac from idle-sleeping and SiverSol out of App Nap while running (F7).
        public var keepAwake = true
        /// F7. Set `antiAFK.enabled = false` for a notify-only run.
        public var antiAFK = AntiAFK.Config()
        /// F8. `rejoin.enabled = false` keeps the health checks but never restarts Roblox.
        public var rejoin = Rejoiner.Config()
        public var health = HealthState.Config()
        public var healthCheckIntervalS: Double = 5
        /// How often the Roblox window is captured and read for disconnect dialogs and frozen-frame checks.
        public var screenCheckIntervalS: Double = 30
        /// If the Mac was used this recently when Roblox closed, the quit is taken as deliberate.
        public var manualQuitWindowS: Double = 60
        /// F10 proof screenshots and F6 on-screen merchant detection.
        public var proof = ProofConfig()
        public var merchantScreenWatch = true
        /// How often the chat is read for merchant notices. A notice stays in the chat for minutes, so 5 s loses
        /// nothing and costs clearly less CPU and memory than 3 s (each read is a screenshot plus text recognition).
        public var merchantScanIntervalS: Double = 5
        public var dailyReports = true
        /// The permission-free extras (roll feed, watchdogs, monitors).
        public var extras = ExtrasConfig()
        /// Minutes a quit may last before the next start counts as a new session (new card, new uptime).
        public var sessionResumeWindow: TimeInterval = 30 * 60
        /// How Guardian looks at the Roblox window. nil = capture and read the real window. Tests and the
        /// command-line tool replace it to rehearse what happens when a dangerous dialog is on screen.
        public var screenLook: (@Sendable () async -> Guardian.Look?)?
        /// Where Moments are saved. nil = `~/Movies/SiverSol Moments`.
        public var momentsDirectory: URL?
        /// How a clip is recorded. nil = the real recorder. Tests replace it.
        public var momentRecorder: (@Sendable (MomentRecorder.Request) async throws -> MomentRecorder.Result)?
        public init() {}
    }

    public let catalog: BiomeCatalog
    public let auras = AuraCatalog.bundled()
    public let config: NotifyConfig
    public let radar: BiomeRadar
    public let mesh: NotifyMesh
    public let timeline: TimelineStore
    public let outbox: OutboxStore
    public let options: Options
    public let input = InputDriver()
    public let guardian: Guardian
    public let antiAFK: AntiAFK
    public let actionLog: ActionLog
    private let pauseFlag = Flag()
    /// Macro Studio: recorder, player, queue and triggers.
    public let macros: MacroCoordinator
    let extra = ExtraState()
    let network = NetworkSentinel()
    private let secrets: Secrets
    private let healthLock = NSLock()
    private var health: HealthState
    private var merchantGate = MerchantGate()
    private var recovering = false
    private var failedAttempts = 0
    private var nextAttemptAt = Date.distantPast
    /// What the last look at the Roblox window gave (about every 30 s). For the UI and for diagnostics only.
    public struct ScreenStatus: Equatable, Sendable {
        public var at: Date
        public var captured: Bool
        public var textLines: Int
        public var brightness: Double
        /// A picture came back, but it is black and has no text: the display is probably off.
        public var isBlank: Bool { captured && textLines == 0 && brightness < 4 }
    }
    private let screenLock = NSLock()
    private var screenStatusValue: ScreenStatus?
    public var screenStatus: ScreenStatus? { screenLock.lock(); defer { screenLock.unlock() }; return screenStatusValue }
    func setScreenStatus(_ s: ScreenStatus) { screenLock.lock(); screenStatusValue = s; screenLock.unlock() }

    public private(set) var lastIncident: IncidentReport?
    public private(set) var sessionKey = ""
    public private(set) var sessionStartedAt = Date()

    /// Called for every radar event, after it was recorded and queued.
    public var onEvent: (@Sendable (SiverEvent) -> Void)?
    /// Called when a Session Wrapped card has been drawn and saved.
    public var onWrapped: (@Sendable (URL) -> Void)?
    /// Called when a Moment has been saved.
    public var onMoment: (@Sendable (Moment) -> Void)?
    /// Called when the battery guard has something to say (a MacBook went on battery, or is getting low).
    public var onPowerAlert: (@Sendable (BatteryGuard.Alert) -> Void)?
    public var onLog: (@Sendable (String) -> Void)?

    var tasks: [Task<Void, Never>] = []
    private let lock: EngineLock
    private var activity: NSObjectProtocol?
    /// Held while the engine watches, released when it stops (see `pmset -g assertions`).
    let stayAwake = StayAwake()
    private var wakeObserver: NSObjectProtocol?
    public private(set) var isRunning = false

    public enum StartError: Error, CustomStringConvertible {
        case alreadyRunning
        public var description: String { "Another SiverSol engine is already running (the app or `siversolctl run`). Stop it first." }
    }

    public init(config: NotifyConfig, secrets: Secrets, options: Options = Options(),
                transport: HTTPTransport = URLSessionTransport()) throws {
        self.options = options
        self.config = config
        self.secrets = secrets
        var healthConfig = options.health
        if !options.extras.freezeWatchdog { healthConfig.frozenLogS = .infinity }
        if !options.extras.menuSentinel { healthConfig.menuGraceS = .infinity }
        health = HealthState(config: healthConfig)
        catalog = try BiomeCatalog.bundled(learnedURL: options.supportDirectory.appendingPathComponent("learned_biomes.json"))
        timeline = TimelineStore(directory: options.supportDirectory.appendingPathComponent("timeline", isDirectory: true))
        outbox = OutboxStore(directory: options.supportDirectory.appendingPathComponent("outbox", isDirectory: true))
        mesh = NotifyMesh(config: config, secrets: secrets, catalog: catalog, store: outbox, transport: transport)
        radar = BiomeRadar(logsDirectory: options.logsDirectory, catalog: catalog)
        lock = EngineLock(directory: options.supportDirectory)
        actionLog = ActionLog(url: options.supportDirectory.appendingPathComponent("actions.jsonl"))
        let look = options.screenLook
        guardian = Guardian(log: actionLog) { if let look { return await look() } else { return await Guardian.robloxLook() } }
        antiAFK = AntiAFK(config: options.antiAFK, guardian: guardian, input: input)
        let flag = pauseFlag
        macros = MacroCoordinator(supportDirectory: options.supportDirectory, guardian: guardian, radar: radar, catalog: catalog,
                                  inputPaused: { flag.value })
        macros.policy = options.extras.macroPolicy
    }

    // MARK: automation (inputs). Detection and notifications never pause.

    /// True after the panic key (F11) or a Guardian alarm. No key or click is sent while paused.
    public var automationPaused: Bool { pauseFlag.value }

    /// F11 panic: let go of every key and button, stop sending input. Safe to call from any thread.
    public func panic(reason: String = "panic key") {
        input.releaseAll(pid: FocusManager.robloxApp()?.processIdentifier)
        macros.shutdown(.panic)
        guard !pauseFlag.value else { return }
        pauseFlag.value = true
        onLog?("automation paused: \(reason)")
        onAutomationChange?(true, reason)
    }

    public func resumeAutomation() {
        guard pauseFlag.value else { return }
        pauseFlag.value = false
        onLog?("automation resumed")
        onAutomationChange?(false, "resumed")
    }

    /// (paused, reason)
    public var onAutomationChange: (@Sendable (Bool, String) -> Void)?

    private func startAutomation() {
        let flag = pauseFlag
        let macros = self.macros
        // Anti-AFK stays quiet while input is paused or a macro is doing the pressing.
        antiAFK.paused = { flag.value || macros.isBusy }
        macros.log = onLog
        macros.announce = { [weak self] event, wantsProof in
            guard let self else { return }
            let proof = wantsProof ? await self.takeProofShot(name: event.id) : nil
            await self.mesh.postMacro(event, proof: proof)
        }
        antiAFK.onOutcome = { [weak self] outcome in
            switch outcome {
            case .pulsed(let how): self?.onLog?("anti-AFK: key sent (\(how.rawValue))")
            case .skipped(let why): self?.onLog?("anti-AFK skipped: \(why)")
            case .blocked(let why): self?.onLog?("anti-AFK blocked by Guardian: \(why)")
            }
        }
        // Hard rule 2: a purchase, delete or trade dialog on screen means Escape, pause, alert.
        guardian.onForbidden = { [weak self] action, reason in
            guard let self else { return }
            if let pid = FocusManager.robloxApp()?.processIdentifier {
                await self.input.tap(.escape, delivery: .toProcess, pid: pid, yieldToUser: false)
            }
            self.panic(reason: "Guardian: \(reason)")
            let message = RichTemplates.actionNeeded("Look at the Roblox window, close the dialog yourself, then choose Resume automation in SiverSol.",
                                                    detail: "Guardian stopped \"\(action)\" because it saw a \(reason). I pressed Escape once and paused all key presses and clicks. Biome detection and notifications are still running.")
            // One alert per 10 minutes at most.
            let bucket = Int(Date().timeIntervalSince1970 / 600)
            for route in self.config.routes where route.wants(.status) {
                await self.mesh.post(message, route: route.name, id: "guardian-alarm-\(bucket)", priority: true)
            }
        }
        if options.antiAFK.enabled {
            tasks.append(Task { [antiAFK] in await antiAFK.run() })
        }
        startHealthWatch()
        startExtras()
    }

    // MARK: health + auto-rejoin (F8)

    private func withHealth<T>(_ body: (inout HealthState) -> T) -> T {
        healthLock.lock(); defer { healthLock.unlock() }
        return body(&health)
    }

    private func startHealthWatch() {
        radar.onLogEvent = { [weak self] event in
            guard let self else { return }
            self.withHealth { $0.note(event) }
            self.extra.note(event)
        }
        tasks.append(Task { [weak self] in
            var lastScreenCheck = Date.distantPast
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.options.healthCheckIntervalS * 1_000_000_000))
                if Task.isCancelled { break }
                let now = Date()
                var screen: [TextBox]?
                if now.timeIntervalSince(lastScreenCheck) >= self.options.screenCheckIntervalS, SiverVision.hasScreenRecordingAccess,
                   let window = RobloxWindowFinder.mainWindow() {
                    lastScreenCheck = now
                    if let image = try? await WindowCapture.capture(windowId: window.windowId, titleBar: window.titleBar) {
                        screen = try? OCR.recognize(image)
                        let hash = FrameHash.average(image)
                        self.withHealth { $0.noteFrame(hash: hash, now: now) }
                        self.setScreenStatus(ScreenStatus(at: now, captured: true, textLines: screen?.count ?? 0, brightness: FrameHash.brightness(image)))
                    } else {
                        // No picture (display off, window on another Space…). That is not trouble by itself:
                        // only the log heartbeat and real disconnect lines decide whether Roblox needs help.
                        self.setScreenStatus(ScreenStatus(at: now, captured: false, textLines: 0, brightness: 0))
                    }
                }
                // "Running" means a Roblox process with a game window; the windowless tray process does not count.
                let running = RobloxWindowFinder.gameIsOpen
                let bytesAt = self.radar.snapshot.lastBytesAt
                let phase = self.radar.snapshot.phase
                let trouble = self.withHealth { $0.evaluate(now: now, robloxRunning: running, lastLogBytesAt: bytesAt, screen: screen, phase: phase) }
                if let trouble { await self.handle(trouble) }
            }
        })
    }

    /// "Rejoin private server now" from the menu. Refused during a rare biome (hard rule 5) and while input is paused.
    public func rejoinNow() async {
        nextAttemptAt = .distantPast
        await handle(.requested)
    }

    func handle(_ trouble: Trouble) async {
        guard !recovering, Date() >= nextAttemptAt else { return }
        let snapshot = radar.snapshot
        let rare = snapshot.current.map { catalog.isRare($0.biome.key) } ?? false
        guard options.rejoin.enabled, !automationPaused else {
            if failedAttempts == 0 {
                failedAttempts = 1
                onLog?("health: \(trouble). Auto-rejoin is \(automationPaused ? "paused" : "off"), so nothing is restarted.")
            }
            return
        }
        // Roblox closed while someone was at the keyboard: that was the user quitting it, not a crash. Leave it closed.
        if trouble == .processExited, input.userIdleSeconds() < options.manualQuitWindowS {
            onLog?("health: Roblox was closed while the Mac was in use, so I take it you quit it. Not reopening.")
            withHealth { $0.forgetRoblox() }
            return
        }
        guard !trouble.needsRestart || Rejoiner.mayRestart(trouble: trouble, currentBiomeIsRare: rare) else {
            onLog?("health: \(trouble) during a rare biome. Roblox is left alone (rule 5).")
            nextAttemptAt = Date().addingTimeInterval(60)
            return
        }
        recovering = true
        defer { recovering = false }
        onLog?("health: \(trouble). Starting recovery.")
        let recoveryStartedAt = Date()
        if trouble == .frozen {
            await postStatus(RichTemplates.info(title: "🧊 Roblox looks frozen",
                                                text: "No log activity for 6 minutes while the game window is open (the client normally writes a line every 2 minutes). Restarting it and rejoining your private server now.",
                                                color: 0xFFCC00), id: "frozen-\(Int(recoveryStartedAt.timeIntervalSince1970))")
        }
        let flag = pauseFlag
        let rejoiner = Rejoiner(config: options.rejoin, secrets: secrets,
                                world: .live(radar: radar, guardian: guardian, input: input, paused: { flag.value }))
        rejoiner.log = onLog
        var report = await rejoiner.recover(from: trouble, incidentId: "incident-\(Int(Date().timeIntervalSince1970))")
        // Network Sentinel: show connection drops and restores from the last 10 minutes inside the timeline.
        if options.extras.networkSentinel {
            let extraSteps = network.steps(from: recoveryStartedAt.addingTimeInterval(-600), to: Date())
            if !extraSteps.isEmpty { report.steps = (report.steps + extraSteps).sorted { $0.at < $1.at } }
        }
        lastIncident = report
        withHealth { $0.reset() }
        if report.recovered {
            if trouble.needsRestart { macros.rejoined() }
            failedAttempts = 0
            nextAttemptAt = Date().addingTimeInterval(30)
        } else {
            let waits = options.rejoin.backoffMinutes
            let minutes = waits.isEmpty ? 10 : waits[min(failedAttempts, waits.count - 1)]
            failedAttempts += 1
            nextAttemptAt = Date().addingTimeInterval(minutes * 60)
            onLog?("recovery failed; next attempt in \(Int(minutes)) min")
        }
        // One timeline embed per incident, on every route that wants incidents.
        for route in config.routes where route.wants(.incident) && route.profile == .rich {
            if let ctx = await mesh.renderContext(route: route.name, origin: .live) {
                await mesh.post(RichTemplates.incident(report, ctx), route: route.name, id: report.id)
            }
        }
        onIncident?(report)
    }

    public var onIncident: (@Sendable (IncidentReport) -> Void)?

    /// Take the single-instance lock. Call before `run()`; throws if another engine holds it.
    public func claim() throws {
        guard lock.acquire() else { throw StartError.alreadyRunning }
    }

    /// Runs until the surrounding task is cancelled or `stop()` is called.
    public func run() async {
        guard lock.acquire() else { onLog?(StartError.alreadyRunning.description); return }
        isRunning = true
        if options.keepAwake {
            // Two things: no App Nap for this process, and no idle sleep for the Mac while it is watching.
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                             reason: "SiverSol is watching Roblox")
            stayAwake.hold()
        }
        // Mac woke up: re-read the log right away and reconcile state (F1 sleep/wake).
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.radar.reconcile()
        }
        resumeOrStartSession()
        let timeline = self.timeline
        let log = onLog
        await mesh.setLogger { log?($0) }
        await mesh.setStats { timeline.count($0, on: Date()) }
        await mesh.setSession(key: sessionKey, startedAt: sessionStartedAt)
        await mesh.start()
        startAutomation()

        if options.liveCard, let route = config.liveCardRoute {
            let interval = TimeInterval(max(15, config.liveCardIntervalS))
            tasks.append(Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)   // let the first events go out first
                while !Task.isCancelled {
                    await self?.updateCard(route: route, ended: false)
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
            })
        }

        pruneProofShots()
        if options.merchantScreenWatch { tasks.append(Task { [weak self] in await self?.watchMerchantsOnScreen() }) }
        if options.dailyReports { tasks.append(Task { [weak self] in await self?.runDailyReports() }) }

        for await batch in radar.eventBatches(pollInterval: 0.5) {
            if Task.isCancelled { break }
            await deliver(batch)
        }
    }

    /// Record, queue and announce a batch of events. Merchant sightings from the log and from the screen share one
    /// gate here (one alert per merchant per 3 minutes), and proof shots are taken before queueing.
    func deliver(_ batch: [SiverEvent]) async {
        let events = batch.filter { event in
            if case .merchantArrived(let m) = event { return allowMerchant(m) }
            return true
        }
        guard !events.isEmpty else { return }
        for event in events { timeline.record(event) }
        for event in events { macros.handle(event) }
        for event in events { considerMoment(event) }
        // Rolls are announced after their screenshot; an equip line that repeats a roll is not announced twice.
        let announce = applyRollFeed(to: events)
        if !announce.isEmpty { await mesh.handle(batch: announce, attachments: await attachments(for: announce)) }
        for event in events { onEvent?(event) }
    }

    private func allowMerchant(_ m: MerchantArrived) -> Bool {
        healthLock.lock(); defer { healthLock.unlock() }
        return merchantGate.shouldAlert(m.name, at: m.at)
    }

    public func stop() async {
        // An engine that never got the lock must not touch the shared outbox or the live card.
        guard isRunning else { return }
        input.releaseAll(pid: FocusManager.robloxApp()?.processIdentifier)
        macros.shutdown(.user)
        network.stop()
        radar.stop()
        tasks.forEach { $0.cancel() }
        tasks = []
        await wrapUpSession()
        _ = await mesh.flush(timeout: 8)
        if options.liveCard, let route = config.liveCardRoute { await updateCard(route: route, ended: true) }
        await mesh.stop()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        stayAwake.release()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        isRunning = false
        lock.release()
    }

    // MARK: session + live card (F4)

    private func resumeOrStartSession() {
        let now = Date()
        if let key = outbox.meta("session.key"),
           let started = outbox.meta("session.startedAt").flatMap(TimeInterval.init),
           let seen = outbox.meta("session.lastSeen").flatMap(TimeInterval.init),
           now.timeIntervalSince1970 - seen < options.sessionResumeWindow {
            sessionKey = key
            sessionStartedAt = Date(timeIntervalSince1970: started)
        } else {
            sessionKey = "s\(Int(now.timeIntervalSince1970))"
            sessionStartedAt = now
            outbox.setMeta("session.key", sessionKey)
            outbox.setMeta("session.startedAt", String(now.timeIntervalSince1970))
        }
        outbox.setMeta("session.lastSeen", String(now.timeIntervalSince1970))
    }

    public func cardState(now: Date = Date(), ended: Bool = false) -> LiveCardState {
        let snap = radar.snapshot
        var s = LiveCardState(sessionStartedAt: sessionStartedAt, now: now)
        s.biome = snap.current?.biome
        s.biomeSince = snap.current?.since
        s.biomeStartObserved = snap.current?.observedStart ?? false
        s.todayCounts = timeline.counts(on: now)
        s.lastAura = timeline.lastAura?.name ?? snap.equippedAura
        s.lastAuraAt = timeline.lastAura?.at
        s.lastMerchant = timeline.lastMerchant?.name
        s.lastMerchantAt = timeline.lastMerchant?.at
        s.serverJobId = snap.serverJobId
        s.outboxDepth = outbox.depth
        s.thermal = Self.thermalName(ProcessInfo.processInfo.thermalState)
        s.health = recovering ? "rejoining" : Self.health(snapshot: snap)
        s.sessionLine = sessionLine(now: now)
        if options.extras.dailyResetCountdown { s.dailyResetAt = nextDailyReset(now: now) }
        if options.extras.resourceMonitor, let r = extra.resourceSamples.last, now.timeIntervalSince(r.at) < 30 {
            s.resourceLine = String(format: "%.1f GB · %.0f%% CPU", r.memoryGB, r.cpuPercent)
        }
        s.macroLine = macros.status.playing?.line ?? (macros.status.autoClicking ? "🖱 auto clicker running" : nil)
        s.lastRoll = timeline.lastRoll?.name
        s.lastRollAt = timeline.lastRoll?.at
        s.endedAt = ended ? now : nil
        // Glitch Hunt Mode: how much of the day and the week the sky was really being watched.
        if config.profileName == Profiles.glitchHunt.name { s.coverageLine = huntCoverage(now: now).line }
        return s
    }

    private func updateCard(route: String, ended: Bool) async {
        outbox.setMeta("session.lastSeen", String(Date().timeIntervalSince1970))
        let message = RichTemplates.liveCard(cardState(ended: ended), catalog: catalog, auras: auras, profile: config.profileName)
        _ = await mesh.upsertCard(message, route: route, metaKey: "card|\(sessionKey)")
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func health(snapshot: BiomeRadar.Snapshot) -> String {
        guard RobloxWindowFinder.gameIsOpen else { return "not running" }
        switch snapshot.phase {
        case .inGame: return "connected"
        case .menu: return "in main menu"
        case .unknown: return "starting"
        }
    }
}

/// A tiny thread-safe boolean.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
