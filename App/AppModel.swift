import AppKit
import ApplicationServices
import Combine
import ServiceManagement
import SiverCore
import SiverEngine
import SiverInput
import SiverMacro
import SiverNotify
import SiverSky
import SiverVision
import SwiftUI

/// One row in an event list.
struct EventRow: Identifiable, Equatable {
    let id: String
    let time: Date
    /// SF Symbol name. Biome rows carry the biome instead and draw its glyph.
    let icon: String
    let title: String
    let detail: String
    var biome: BiomeInfo?
    var tint: Color?
}

struct PermissionState: Equatable {
    var accessibility = false
    var screenRecording = false
    var robloxInstalled = false
    var robloxRunning = false
    var allGranted: Bool { accessibility && screenRecording }
}

/// The pages of the app live in SiverCore (`AppPage`), with the sidebar's grouping and order.
typealias AppSection = AppPage

extension AppPage {
    private static let resolved: [AppPage: String] = Dictionary(uniqueKeysWithValues: AppPage.allCases.map { page in
        (page, page.symbols.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil } ?? "circle")
    })
    /// The first of the page's symbols that this macOS has.
    var symbol: String { Self.resolved[self] ?? "circle" }
    var shortcut: KeyEquivalent? { shortcutDigit.map { KeyEquivalent(Character(String($0))) } }
}

/// A flag that can be read from any thread (the macro coordinator asks it before every start).
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

/// Everything the UI shows about a running engine, gathered off the main thread once a second.
struct EngineReading: Sendable {
    var snapshot = BiomeRadar.Snapshot()
    var outboxDepth = 0
    var todayCounts: [String: Int] = [:]
    var sessionStartedAt: Date?
    var session = SessionInfo()
    var resources: [ResourceSample] = []
    var logLab: [LogLabEntry] = []
    var unknownSignals: [String: Int] = [:]
    var network: [NetworkChange] = []
    var nextReset: Date?
    var windowWarning: String?
    var cutsceneRemaining: TimeInterval = 0
    var lastAura: String?
    var lastAuraAt: Date?
    var lastRoll: String?
    var lastRollAt: Date?
    var lastMerchant: String?
    var lastMerchantAt: Date?
    var sent = 0
    var dead: [String] = []
    var intel: BiomeIntel?
    /// The engine's last look at the Roblox window: did a picture come back, and was it black?
    var screenCaptured: Bool?
    var screenBlank = false
    var screenLines = 0
    /// Glitch Hunt Mode: hours watched today and this week.
    var coverage: HuntCoverage?
    /// For the sidebar: events recorded today, and when the next scheduled macro is due.
    var eventsToday = 0
    var nextRun: Date?
}

extension EngineReading {
    /// Would the two look the same on screen? The engine reading is taken every second, but most seconds nothing
    /// a view shows has changed (only counters such as "log lines read"). Publishing only real changes keeps the
    /// whole interface from being rebuilt every second.
    func looksTheSame(as o: EngineReading) -> Bool {
        var a = session, b = o.session
        a.lastHeartbeatAt = nil; b.lastHeartbeatAt = nil
        return snapshot.current == o.snapshot.current && snapshot.equippedAura == o.snapshot.equippedAura
            && snapshot.serverJobId == o.snapshot.serverJobId && snapshot.phase == o.snapshot.phase
            && snapshot.clientVersion == o.snapshot.clientVersion && snapshot.logFile == o.snapshot.logFile
            && outboxDepth == o.outboxDepth && todayCounts == o.todayCounts && sessionStartedAt == o.sessionStartedAt
            && a == b && resources.count == o.resources.count && resources.last == o.resources.last
            && logLab.count == o.logLab.count && logLab.last == o.logLab.last && unknownSignals == o.unknownSignals
            && network == o.network && nextReset == o.nextReset && windowWarning == o.windowWarning
            && (cutsceneRemaining > 0) == (o.cutsceneRemaining > 0)
            && lastAura == o.lastAura && lastAuraAt == o.lastAuraAt && lastRoll == o.lastRoll && lastRollAt == o.lastRollAt
            && lastMerchant == o.lastMerchant && lastMerchantAt == o.lastMerchantAt
            && sent == o.sent && dead == o.dead && intel == o.intel
            && screenCaptured == o.screenCaptured && screenBlank == o.screenBlank
            && coverage.map { Int($0.todaySeconds / 60) } == o.coverage.map { Int($0.todaySeconds / 60) }
            && eventsToday == o.eventsToday && nextRun == o.nextRun
    }
}

/// The menu bar title changes every second while a countdown shows. It lives in its own small object so that
/// only the menu bar item is redrawn, not every page of the window.
@MainActor
final class MenuBarModel: ObservableObject {
    static let shared = MenuBarModel()
    /// SF Symbol for the state or the current biome, and the short text beside it (a countdown, or nothing).
    @Published var symbol = "moon.zzz"
    @Published var title = ""
}

/// App state and the only place that starts or stops the engine.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum RunState: Equatable {
        case stopped, starting, running
        case attention(String)

        var glyph: String {
            switch self {
            case .running: return "●"
            case .starting: return "◌"
            case .stopped: return "⏸"
            case .attention: return "⚠"
            }
        }
        var label: String {
            switch self {
            case .running: return "Running"
            case .starting: return "Starting…"
            case .stopped: return "Paused"
            case .attention(let why): return "Needs attention: \(why)"
            }
        }
    }

    // MARK: published state

    @Published private(set) var runState: RunState = .stopped {
        didSet {
            // The resting island is up exactly while SiverSol watches.
            let was = oldValue == .running || oldValue == .starting
            if was != isRunning { DispatchQueue.main.async { IslandController.shared.refresh() } }
        }
    }
    @Published private(set) var reading = EngineReading()
    @Published private(set) var recent: [EventRow] = []
    @Published private(set) var permissions = PermissionState()
    @Published private(set) var lastLog = ""
    @Published private(set) var lastIncident = ""
    @Published var config: NotifyConfig = DesignReview.isOn ? .default : AppConfig.load()
    @Published var secrets: Secrets = DesignReview.isOn ? Secrets() : (KeychainSecrets.load() ?? Secrets())
    @Published var extras: ExtrasConfig = DesignReview.isOn ? ExtrasConfig() : AppConfig.loadExtras()
    @Published var settingsMessage = ""
    @Published var selection: AppSection = .dashboard
    @Published var showOnboarding = false
    @Published var aboutShowsPrivacy = false
    /// True after the panic key or a Guardian alarm: no keys or clicks are sent, detection keeps running.
    @Published private(set) var automationPaused = false
    @Published private(set) var pauseReason = ""
    @Published var guardianReport: String?
    @Published private(set) var testShotMessage = ""
    @Published private(set) var testShot: NSImage?
    @Published private(set) var diagnoses: [String: WebhookDiagnosis] = [:]
    @Published private(set) var diagnosing: Set<String> = []
    @Published private(set) var launchAtLogin = false

    // Macro Studio (see AppModel+Macros.swift)
    @Published var macroStatus = MacroCoordinator.Status()
    @Published var macroList: [Macro] = []
    @Published var selectedMacro: String?
    @Published var macroMessage = ""
    @Published var pendingImport: Macro?
    @Published var macroStats = MacroStats()
    @Published var autoClicker = AutoClickerConfig()
    @Published var recorderOptions = RecorderOptions()
    @Published var pendingLink: URL?
    /// Result of the last recorder start: which permissions the event tap really needed on this Mac.
    @Published var recorderCheck = ""
    @Published var macroToDelete: String?

    @AppStorage("autoStart") var autoStart = false
    @AppStorage("antiAFKEnabled") var antiAFKEnabled = true
    @AppStorage("rejoinEnabled") var rejoinEnabled = true
    @AppStorage("proofEnabled") var proofEnabled = true
    @AppStorage("onboardingDone") var onboardingDone = false
    @AppStorage("linkCommandsAllowed") var linkCommandsAllowed = false
    @AppStorage("showRecorderBar") var showRecorderBar = true

    let auras = AuraCatalog.bundled()
    let catalog: BiomeCatalog = (try? BiomeCatalog.bundled(learnedURL: BiomeCatalog.defaultLearnedURL)) ?? BiomeCatalog(builtIn: [])

    // MARK: private

    private(set) var engine: SiverEngine?
    private var runTask: Task<Void, Never>?
    private var ticker: Timer?
    private var fastTicker: Timer?
    private var ticks = 0
    private var gathering = false
    var hotKeys: [GlobalHotKey] = []
    /// Key codes whose global shortcut macOS refused (another app owns the combination).
    var hotKeyProblems: [Int] = []
    let panicFlag = AtomicFlag()
    var standaloneMacros: MacroCoordinator?
    var standaloneRadar: BiomeRadar?
    var standaloneRadarTask: Task<Void, Never>?
    let recorderBar = RecorderBarController()
    /// True inside the unit-test host and in the design review: nothing starts by itself there.
    static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || DesignReview.isOn
    /// Design review only: a note for pages that take one.
    @Published var reviewNote = ""
    /// A moment the Timeline should open at (set by the Sky Ribbon).
    @Published var timelineFocus: Date?
    /// Changes whenever a new Session Wrapped card has been saved.
    @Published var wrappedStamp = 0

    private init() {
        RobloxChrome.prime()
        _ = PowerWatch.shared
        if DesignReview.isOn {
            // Made-up data only: see DesignReview.
            DispatchQueue.main.async { DesignReview.shared.start() }
            return
        }
        refreshPermissions()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        guard !Self.isTestHost else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // The fast timer only runs the macro readout, and only does work while a macro is busy (4 Hz).
        fastTicker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.macroTick() }
        }
        reloadMacros()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { IslandController.shared.prewarm(); IslandController.shared.refresh(); EggDirector.shared.start() }
        // Vision prepares its text model once per new build; do that now, not in front of the first key press.
        Task.detached(priority: .utility) { OCR.warmUp() }
        showOnboarding = !onboardingDone && !hasWebhook
        handleLaunchArguments()
    }

    var isRunning: Bool { runState == .running || runState == .starting }
    var hasWebhook: Bool { config.routes.contains { $0.enabled && secrets.webhook($0.name) != nil } }
    var snapshot: BiomeRadar.Snapshot { reading.snapshot }

    var stateLabel: String {
        if isRunning && automationPaused { return "Input paused (\(pauseReason)). Detection and notifications are still running." }
        return runState.label
    }

    /// The biome on screen now, when the engine is running and knows.
    var currentBiome: BiomeInfo? {
        guard isRunning, let c = snapshot.current else { return nil }
        return catalog.info(for: c.biome.key)
    }

    // MARK: panic + Guardian

    func panic() {
        panicFlag.value = true
        if let engine { engine.panic() } else { InputDriver().releaseAll() }
        standaloneMacros?.shutdown(.panic)
        automationPaused = true
        if pauseReason.isEmpty { pauseReason = "panic key" }
        writeStatusFile()
    }

    func resumeAutomation() {
        panicFlag.value = false
        engine?.resumeAutomation()
        automationPaused = false
        pauseReason = ""
        writeStatusFile()
    }

    /// Quit Roblox and reopen the private server now (the same path auto-rejoin takes).
    func rejoinNow() {
        guard let engine else { return }
        lastIncident = "Rejoin requested…"
        Task { await engine.rejoinNow() }
    }

    /// Look at the screen and report what Guardian would allow. Presses nothing.
    func guardianDryRun() {
        let guardian = Guardian(log: ActionLog(url: nil)) { await Guardian.robloxLook() }
        Task {
            let result = await guardian.dryRun()
            var lines = [result.seen ? "I can see the Roblox window (\(result.lines) lines of text)." : "I cannot see the Roblox window (is it open, and is Screen Recording allowed?)."]
            for (action, verdict) in result.verdicts {
                switch verdict {
                case .approved: lines.append("Allow: \(action)")
                case .held(let reason): lines.append("Wait: \(action) (\(reason))")
                case .blocked(let reason, let forbidden): lines.append("\(forbidden ? "Block (forbidden)" : "Block"): \(action) (\(reason))")
                }
            }
            lines.append("Nothing was pressed or clicked.")
            self.guardianReport = lines.joined(separator: "\n")
        }
    }

    // MARK: start / stop

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard !isRunning else { return }
        guard hasWebhook else { runState = .attention("no webhook set. Open Notifications."); return }
        // One macro coordinator at a time: the engine brings its own.
        standaloneMacros?.shutdown(.user)
        standaloneRadarTask?.cancel()
        standaloneMacros = nil
        standaloneRadar = nil
        let engine: SiverEngine
        do {
            var options = SiverEngine.Options()
            options.antiAFK.enabled = antiAFKEnabled
            options.rejoin.enabled = rejoinEnabled
            options.proof.enabled = proofEnabled
            options.extras = extras
            engine = try SiverEngine(config: config, secrets: secrets, options: options)
            try engine.claim()
        } catch {
            runState = .attention("\(error)")
            return
        }
        runState = .starting
        self.engine = engine
        let catalog = self.catalog
        let auras = self.auras
        engine.onPowerAlert = { alert in
            Task { @MainActor in
                var detail = ""
                switch alert {
                case .onBattery(_, let minutes), .low(_, let minutes): detail = minutes.map { "about \($0) min left" } ?? ""
                }
                IslandController.shared.offer(IslandItem(id: "battery-\(Int(Date().timeIntervalSince1970))", kind: .notice, title: alert.short, detail: detail,
                                                         biome: nil, rare: false, at: Date()))
            }
        }
        engine.onEvent = { [weak self] event in
            Task { @MainActor in IslandController.shared.offer(event, catalog: catalog, auras: auras) }
            guard let row = Self.row(for: event, catalog: catalog, auras: auras) else { return }
            Task { @MainActor in self?.append(row) }
        }
        engine.onIncident = { [weak self] report in
            let text = "\(report.cause): \(report.recovered ? "recovered" : "not recovered") · \(report.steps.last?.label ?? "")"
            Task { @MainActor in
                self?.lastIncident = text
                if !report.recovered {
                    self?.notify(title: "SiverSol could not get back into Sol's RNG", body: "\(report.cause). Last step: \(report.steps.last?.label ?? "none"). It will try again later.")
                }
            }
        }
        engine.onLog = { [weak self] line in Task { @MainActor in self?.lastLog = line } }
        engine.onMoment = { _ in Task { @MainActor in MomentsModel.shared.reload() } }
        engine.onWrapped = { [weak self] _ in Task { @MainActor in self?.wrappedStamp += 1 } }
        engine.onAutomationChange = { [weak self] paused, reason in
            Task { @MainActor in
                self?.automationPaused = paused
                self?.pauseReason = paused ? reason : ""
                self?.panicFlag.value = paused
            }
        }
        automationPaused = false
        pauseReason = ""
        panicFlag.value = false
        wire(engine.macros)
        Task { await engine.mesh.setRouteDiedHandler { [weak self] route, status in
            Task { @MainActor in
                self?.notify(title: "Discord route \"\(route)\" stopped working",
                             body: "Discord answered HTTP \(status). The webhook was deleted or the URL is wrong. Messages for it are kept in the queue. Open Notifications to fix it.")
            }
        } }
        runTask = Task { [weak self] in
            await engine.run()
            await MainActor.run { if self?.engine === engine { self?.runState = .stopped } }
        }
        runState = .running
        reading.sessionStartedAt = Date()
    }

    func stop() {
        guard let engine else { runState = .stopped; return }
        self.engine = nil
        runState = .stopped
        SkyState.shared.show(nil, since: nil, known: false)
        let task = runTask
        runTask = nil
        Task {
            await engine.stop()
            task?.cancel()
        }
    }

    /// Stop and start again, so saved settings take effect.
    func restart() {
        guard isRunning else { return }
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.start() }
    }

    // MARK: periodic refresh (1 Hz; all engine and file reads happen off the main thread)

    private func tick() {
        refreshPermissions()
        ticks += 1
        if ticks % 3 == 0 { writeStatusFile() }
        updateMenuBarTitle()
        guard let engine, !gathering else { return }
        gathering = true
        let wantIntel = ticks % 15 == 1
        Task.detached(priority: .utility) { [weak self] in
            var r = EngineReading()
            r.snapshot = engine.radar.snapshot
            r.outboxDepth = engine.outbox.depth
            r.todayCounts = engine.timeline.counts(on: Date())
            r.sessionStartedAt = engine.sessionStartedAt
            r.session = engine.sessionInfo
            r.resources = engine.resourceSamples
            r.logLab = engine.logLabEntries
            r.unknownSignals = engine.unknownSignals
            r.network = engine.networkTimeline
            r.nextReset = engine.nextDailyReset()
            r.windowWarning = engine.windowWarning
            r.cutsceneRemaining = engine.cutsceneRemaining
            if let a = engine.timeline.lastAura { r.lastAura = a.name; r.lastAuraAt = a.at }
            if let a = engine.timeline.lastRoll { r.lastRoll = a.name; r.lastRollAt = a.at }
            if let m = engine.timeline.lastMerchant { r.lastMerchant = m.name; r.lastMerchantAt = m.at }
            if let look = engine.screenStatus { r.screenCaptured = look.captured; r.screenBlank = look.isBlank; r.screenLines = look.textLines }
            r.sent = await engine.mesh.sentCount
            r.dead = await engine.mesh.deadRouteNames
            if wantIntel { r.intel = engine.biomeIntel() }
            r.eventsToday = engine.timeline.eventCount(on: Date())
            r.nextRun = engine.macros.nextScheduledRun()
            if engine.config.profileName == Profiles.glitchHunt.name { r.coverage = engine.huntCoverage() }
            let result = r
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.gathering = false
                guard self.engine === engine else { return }
                var next = result
                if next.intel == nil { next.intel = self.reading.intel }
                if !next.looksTheSame(as: self.reading) { self.reading = next }
                self.updateSky()
            }
        }
    }

    /// Open the Timeline at a moment (the Sky Ribbon does this).
    func showInTimeline(_ date: Date) {
        timelineFocus = date
        selection = .timeline
    }

    /// Draw a Session Wrapped card now: for the running session, or for the last six hours when nothing is running.
    func makeWrappedNow() async -> URL? {
        if let engine { return await engine.makeWrapped(start: engine.sessionStartedAt, end: Date()) }
        let catalog = self.catalog, auras = self.auras
        let url = await Task.detached(priority: .userInitiated) { () -> URL? in
            let end = Date(), start = end.addingTimeInterval(-6 * 3600)
            let store = TimelineStore(directory: TimelineStore.defaultDirectory)
            var events: [SiverEvent] = []
            for day in Set([TimelineStore.day(start.addingTimeInterval(-86_400)), TimelineStore.day(start), TimelineStore.day(end)]).sorted() { events += store.events(day: day) }
            let wrap = SessionWrap.build(events: events, start: start, end: end, isRare: { catalog.isRare($0) }, chance: { auras.chance(for: $0) },
                                         auraName: { auras.info(for: $0)?.display ?? AuraName.display($0) })
            guard let image = WrappedCard.render(wrap, catalog: catalog, auras: auras, sky: SkyRenderer.shared, foil: FoilRenderer.shared),
                  let data = WrappedCard.png(image) else { return nil }
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmm"
            let dir = SiverEngine.wrappedDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("Wrapped-\(f.string(from: end)).png")
            return (try? data.write(to: url, options: .atomic)) != nil ? url : nil
        }.value
        if url != nil { wrappedStamp += 1 }
        return url
    }

    /// Tell the sky which biome is on. Cheap when nothing changed.
    func updateSky() {
        if let c = isRunning ? snapshot.current : nil {
            SkyState.shared.show(catalog.info(for: c.biome.key), since: c.since, known: c.observedStart)
        } else {
            SkyState.shared.show(nil, since: nil, known: false)
        }
    }

    /// The biome's symbol and a countdown while running; a record mark while a macro is being recorded.
    private func updateMenuBarTitle() {
        var symbol = "moon.zzz", title = ""
        if macroStatus.recording != .idle {
            symbol = "record.circle.fill"; title = "REC"
        } else if !isRunning {
            symbol = "moon.zzz"
        } else if case .attention = runState {
            symbol = "exclamationmark.triangle.fill"
        } else if let c = snapshot.current {
            let info = catalog.info(for: c.biome.key)
            symbol = BiomeGlyph.menuSymbol(info, night: SkyState.shared.isNight)
            if automationPaused {
                title = "paused"
            } else if let d = info.durationS, c.observedStart {
                let left = Double(d) - Date().timeIntervalSince(c.since)
                if left > 0 { title = Self.menuBarTime(left) }
            }
        } else {
            symbol = "cloud"
        }
        if macroStatus.playing != nil { title += title.isEmpty ? "▶" : " ▶" }
        let bar = MenuBarModel.shared
        if symbol != bar.symbol { bar.symbol = symbol }
        if title != bar.title { bar.title = title }
    }

    /// The time left as the menu bar shows it: whole minutes, and seconds only in the last minute.
    /// macOS redraws a menu bar item (and its copies on every display and Space) each time its text changes,
    /// which measured about 2% of a core for a clock ticking every second. The island, the sidebar and the
    /// Dashboard carry the exact clock.
    static func menuBarTime(_ left: TimeInterval) -> String {
        left >= 60 ? "\(Int((left / 60).rounded(.up)))m" : clock(left)
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: permissions

    func refreshPermissions() {
        var p = PermissionState()
        p.accessibility = AXIsProcessTrusted()
        p.screenRecording = CGPreflightScreenCaptureAccess()
        // Whether Roblox is installed hardly ever changes; asking LaunchServices every second is wasteful.
        if ticks % 30 == 0 || !permissions.robloxInstalled {
            p.robloxInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: RobloxWindowFinder.bundleId) != nil
        } else {
            p.robloxInstalled = permissions.robloxInstalled
        }
        p.robloxRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: RobloxWindowFinder.bundleId).isEmpty
        if p != permissions { permissions = p }
    }

    func isGranted(_ topic: PermissionTopic) -> Bool {
        switch topic.id {
        case PermissionGuide.screenRecording.id: return permissions.screenRecording
        case PermissionGuide.accessibility.id: return permissions.accessibility
        case PermissionGuide.launchAtLogin.id: return launchAtLogin
        default: return false
        }
    }

    /// Ask for a permission (the system prompt the first time, System Settings after that).
    func request(_ topic: PermissionTopic) {
        switch topic.id {
        case PermissionGuide.screenRecording.id:
            if !CGRequestScreenCaptureAccess() { openSettings(topic) }
        case PermissionGuide.accessibility.id:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) { openSettings(topic) }
        case PermissionGuide.launchAtLogin.id:
            setLaunchAtLogin(!launchAtLogin)
        default: break
        }
    }

    func openSettings(_ topic: PermissionTopic) {
        if let url = URL(string: topic.settingsURL) { NSWorkspace.shared.open(url) }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            settingsMessage = "Could not change Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Capture the Roblox window once, to prove Screen Recording works for SiverSol itself.
    func testScreenshot() {
        testShotMessage = "Capturing…"
        Task {
            let url = SiverSol.supportDirectory.appendingPathComponent("screens/app-test.png")
            var message: String
            var image: NSImage?
            if let window = RobloxWindowFinder.mainWindow() {
                do {
                    let shot = try await WindowCapture.capture(windowId: window.windowId, titleBar: window.titleBar)
                    await Task.detached { _ = SiverVision.savePNG(shot, to: url) }.value
                    image = NSImage(cgImage: shot, size: NSSize(width: shot.width, height: shot.height))
                    message = "Captured the Roblox window: \(shot.width)×\(shot.height) px."
                } catch {
                    message = "Capture failed. \(error)"
                }
            } else {
                message = "No Roblox window on screen."
            }
            self.testShot = image
            self.testShotMessage = message
            self.writeStatusFile()
        }
    }

    /// Things the user should know even when Discord is the part that broke. Shown in the app and the menu bar;
    /// no system notification, because that would need another permission.
    func notify(title: String, body: String) {
        runState = .attention(title)
        lastLog = body
    }

    func noteLog(_ line: String) { lastLog = line }
    func setPause(_ reason: String) { pauseReason = reason }

    // MARK: events

    private func append(_ row: EventRow) {
        recent.insert(row, at: 0)
        if recent.count > 200 { recent.removeLast(recent.count - 200) }
    }

    nonisolated static func row(for event: SiverEvent, catalog: BiomeCatalog, auras: AuraCatalog? = nil) -> EventRow? {
        switch event {
        case .biomeStarted(let e):
            let info = catalog.info(for: e.biome.key)
            return EventRow(id: e.id, time: e.at, icon: "cloud.fill", title: "\(e.biome.key) \(e.wasRunning ? "in progress" : "started")",
                            detail: info.isRare ? "RARE" : (info.durationS.map { "usually \(DiscordTime.duration(TimeInterval($0)))" } ?? ""), biome: info)
        case .biomeEnded(let e):
            return EventRow(id: e.id, time: e.at, icon: e.reason == .changed ? "checkmark.circle" : "circle.dashed",
                            title: "\(e.biome.key) \(e.reason == .changed ? "ended" : "lost track")", detail: "lasted \(DiscordTime.duration(e.duration))")
        case .auraEquipped(let e):
            return EventRow(id: e.id, time: e.at, icon: "sparkles", title: auras?.display(for: e.internalName) ?? AuraName.display(e.internalName),
                            detail: e.initial ? "restored on join" : (auras?.rarityText(for: e.internalName) ?? "equipped"))
        case .auraRolled(let e):
            return EventRow(id: e.id, time: e.at, icon: "party.popper.fill", title: "Rolled \(auras?.info(for: e.name)?.display ?? e.name)",
                            detail: auras?.rarityText(for: e.name) ?? "", tint: .yellow)
        case .merchantArrived(let e):
            return EventRow(id: e.id, time: e.at, icon: "cart.fill", title: "\(e.name) arrived", detail: "seen in the \(e.source ?? "log")")
        case .serverJoined(let e):
            return EventRow(id: e.id, time: e.at, icon: "link", title: "Joined server", detail: String(e.jobId.prefix(8)))
        case .disconnected(let e):
            return EventRow(id: e.id, time: e.at, icon: "bolt.horizontal.circle", title: "Disconnect line", detail: "\(e.kind) \(e.reason.map(String.init) ?? "")")
        case .newBiomeSeen(let e):
            return EventRow(id: e.id, time: e.at, icon: "sparkle.magnifyingglass", title: "New biome: \(e.biome.key)", detail: "saved to the catalog")
        }
    }

    // MARK: settings

    /// Saves routes, extras and secrets. File and Keychain writes happen off the main thread.
    func saveSettings(restartIfRunning: Bool = false) {
        let config = self.config, extras = self.extras, secrets = self.secrets
        settingsMessage = "Saving…"
        Task {
            let (okConfig, okSecrets) = await Task.detached { (AppConfig.save(config, extras: extras), KeychainSecrets.save(secrets)) }.value
            if okConfig && okSecrets {
                self.settingsMessage = self.isRunning ? (restartIfRunning ? "Saved. Restarting the macro…" : "Saved. Restart the macro to apply.") : "Saved."
                if restartIfRunning { self.restart() }
            } else {
                self.settingsMessage = "Could not save \(okConfig ? "to the Keychain" : "the settings file")."
            }
        }
    }

    func importSecrets(from url: URL) {
        do {
            secrets = try KeychainSecrets.importFile(url)
            settingsMessage = "Imported \(secrets.discordWebhooks.count) webhook(s) into the Keychain."
        } catch {
            settingsMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    func chooseSecretsFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a secrets file. Its contents are copied into your Keychain."
        if panel.runModal() == .OK, let url = panel.url { importSecrets(from: url) }
    }

    func addRoute(name: String, profile: FormatProfile) {
        let trimmed = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty, config.route(trimmed) == nil else { return }
        config.routes.append(RouteConfig(name: trimmed, profile: profile, pings: RouteConfig.defaultPings,
                                         acceptsTests: profile == .rich))
    }

    func removeRoute(_ name: String) {
        config.routes.removeAll { $0.name == name }
        secrets.discordWebhooks[name] = nil
        if config.liveCardRoute == name { config.liveCardRoute = config.routes.first { $0.profile == .rich }?.name }
    }

    /// The route test messages go to: the first Rich route that accepts them and has a webhook.
    var testRoute: String? {
        config.routes.first { $0.isTestTarget && secrets.webhook($0.name) != nil }?.name
    }

    func sendTestMessage(route: String? = nil) {
        guard let route = route ?? testRoute else { settingsMessage = "Add a Rich route with a webhook first."; return }
        guard config.route(route)?.isTestTarget == true else { settingsMessage = "Test messages never go to a Hunt-Compat route."; return }
        guard secrets.webhook(route) != nil else { settingsMessage = "No valid webhook for \(route)."; return }
        let mesh = NotifyMesh(config: config, secrets: secrets, catalog: catalog, store: OutboxStore(directory: nil))
        settingsMessage = "Sending…"
        Task {
            let problem = await mesh.sendConnectionTest(route: route)
            self.settingsMessage = problem ?? "Connected. Look for “✅ SiverSol is connected” in your channel."
        }
    }

    /// Webhook Doctor: check a route's URL with Discord. Nothing is posted.
    func diagnose(_ route: String) {
        guard let url = secrets.discordWebhooks[route], !diagnosing.contains(route) else {
            diagnoses[route] = WebhookDiagnosis(ok: false, problem: "Paste a Discord webhook URL.")
            return
        }
        diagnosing.insert(route)
        Task {
            let result = await WebhookDoctor.examine(url)
            self.diagnoses[route] = result
            self.diagnosing.remove(route)
        }
    }

    /// Open the Discord channel a route posts to (known after Webhook Doctor ran once).
    func openChannel(_ route: String? = nil) {
        guard let route = route ?? testRoute ?? config.routes.first?.name else { return }
        if let url = diagnoses[route]?.channelURL { NSWorkspace.shared.open(url); return }
        guard let urlString = secrets.discordWebhooks[route] else { return }
        Task {
            let result = await WebhookDoctor.examine(urlString)
            self.diagnoses[route] = result
            if let url = result.channelURL { NSWorkspace.shared.open(url) }
        }
    }

    func copyServerLink() {
        guard let link = secrets.serverLink else { settingsMessage = "No private server link saved."; return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        settingsMessage = "Private server link copied."
    }

    func revealDataFolder() { NSWorkspace.shared.open(SiverSol.supportDirectory) }

    // MARK: launch arguments and URLs

    private func handleLaunchArguments() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--import-secrets"), i + 1 < args.count {
            importSecrets(from: URL(fileURLWithPath: args[i + 1]))
            if args.contains("--quit-after-import") {
                // One-shot mode for setup scripts: copy the file into the Keychain, report, leave.
                print(settingsMessage)
                exit(secrets.discordWebhooks.isEmpty ? 1 : 0)
            }
            showOnboarding = false
        }
        if args.contains("--onboarding-step") { showOnboarding = true }
        if args.contains("--autostart") || autoStart {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.start() }
        }
    }

    /// Files (`.svmacro`) and `siversol://` links both arrive here.
    func handle(url: URL) {
        if url.isFileURL { previewImport(url); return }
        guard url.scheme == "siversol" else { return }
        let host = url.host ?? ""
        // Opening a page is harmless. Anything that makes SiverSol act needs the user's say-so,
        // because a link can come from anywhere (a web page, a chat message).
        if let section = AppSection(rawValue: host) ?? ["history": .timeline, "setup": .settings, "loglab": .logLab][host] {
            selection = section
            return
        }
        if linkCommandsAllowed { run(link: url) } else { pendingLink = url }
    }

    /// What a link would do, in words, for the confirmation dialog.
    func describe(link url: URL) -> String {
        switch url.host ?? "" {
        case "start": return "start the macro"
        case "stop": return "stop the macro"
        case "toggle": return "start or stop the macro"
        case "panic": return "pause all input"
        case "resume": return "resume automation"
        case "snapshot": return "take a test screenshot of Roblox"
        case "rejoin": return "quit Roblox and rejoin your private server"
        case "test": return "send the test message to Discord"
        case "macro":
            let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value ?? "?"
            return url.path == "/stop" ? "stop the macro that is playing" : "play your macro “\(name)”"
        default: return "do something SiverSol does not know (“\(url.host ?? "")”)"
        }
    }

    func run(link url: URL) {
        switch url.host ?? "" {
        case "start": start()
        case "stop": stop()
        case "toggle": toggle()
        case "panic": panic()
        case "resume": resumeAutomation()
        case "snapshot": testScreenshot()
        case "rejoin": rejoinNow()
        case "test": sendTestMessage()
        case "macro":
            let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value
            if url.path == "/stop" { stopMacro() } else if url.path == "/play", let name { playMacro(name) }
        default: break
        }
        writeStatusFile()
    }

    /// Design review: put a made-up session on screen. Nothing is read from the game and nothing is sent.
    func applyDemo(biome: String) {
        let now = Date()
        var r = EngineReading()
        permissions = PermissionState(accessibility: true, screenRecording: true, robloxInstalled: true, robloxRunning: true)
        guard !biome.isEmpty else {
            runState = .stopped
            reading = r
            recent = []
            updateSky()
            return
        }
        runState = .running
        let info = catalog.info(for: BiomeKey(biome))
        let elapsed = (info.durationS.map(Double.init) ?? 300) * (SkyState.shared.progressOverride ?? 0.35)
        r.snapshot.current = BiomeTracker.Current(biome: BiomeRef(raw: biome), since: now.addingTimeInterval(-elapsed), observedStart: true,
                                                  startEventId: "demo", previous: "NORMAL")
        r.snapshot.equippedAura = "Starlight"
        r.snapshot.phase = .inGame
        r.snapshot.clientVersion = "0.700.0.7000000"
        r.snapshot.serverJobId = "0d3m0000"
        r.sessionStartedAt = now.addingTimeInterval(-5 * 3600 - 1260)
        var session = SessionInfo()
        session.joinedAt = now.addingTimeInterval(-5 * 3600)
        session.joinKind = .privateServer
        session.shortJobId = "0d3m0000"
        session.joins = 1
        session.clientVersion = "0.700.0.7000000"
        r.session = session
        r.nextReset = now.addingTimeInterval(7 * 3600 + 11 * 60)
        r.sent = 128
        let events = DemoDay.events(endingAt: now)
        var counts: [String: Int] = [:]
        for case .biomeStarted(let e) in events { counts[e.biome.key.value, default: 0] += 1 }
        r.todayCounts = counts
        r.resources = (0..<120).map { i in
            let x = Double(i)
            return ResourceSample(at: now.addingTimeInterval(Double(i - 120) * 30), memoryBytes: UInt64((1.9 + 0.25 * sin(x / 17) + x * 0.002) * 1_073_741_824),
                                  cpuPercent: 38 + 14 * sin(x / 6) + 6 * sin(x / 2.3))
        }
        r.lastRoll = "Symphony"; r.lastRollAt = now.addingTimeInterval(-2400)
        r.lastMerchant = "Mari"; r.lastMerchantAt = now.addingTimeInterval(-5400)
        r.screenCaptured = true
        r.screenLines = 24
        r.eventsToday = events.count
        r.nextRun = now.addingTimeInterval(23 * 60)
        if reviewNote == "sidebar-failing" { r.dead = ["main"] }
        if reviewNote == "sidebar-retrying" { r.outboxDepth = 3 }
        if reviewNote == "sidebar-macro" {
            var status = MacroCoordinator.Status()
            status.playing = MacroProgress(name: "Demo walk", loop: 0, totalLoops: 3, step: 11, totalSteps: 27, startedAt: now)
            macroStatus = status
        } else if DesignReview.isOn {
            macroStatus = MacroCoordinator.Status()
        }
        if reviewNote == "sidebar-paused" { automationPaused = true; pauseReason = "panic key" } else if DesignReview.isOn { automationPaused = false }
        if reviewNote == "sidebar-noroblox" { permissions.robloxRunning = false; r.snapshot.current = nil }
        reading = r
        recent = events.reversed().prefix(40).compactMap { Self.row(for: $0, catalog: catalog, auras: auras) }
        updateSky()
    }

    /// A small status file so scripts can confirm what the app is doing without the UI. Written off the main thread.
    func writeStatusFile() {
        guard !DesignReview.isOn else { return }
        let status: [String: Any] = ["state": stateLabel, "running": isRunning, "automationPaused": automationPaused,
                                     "biome": snapshot.current?.biome.key.value ?? "", "outbox": reading.outboxDepth, "sent": reading.sent,
                                     "updated": DiscordTime.iso(Date()), "testShot": testShotMessage, "lastIncident": lastIncident, "lastLog": lastLog,
                                     "accessibility": permissions.accessibility, "screenRecording": permissions.screenRecording,
                                     "page": selection.rawValue, "macro": macroStatus.playing?.line ?? "", "macroResult": macroStatus.lastResult,
                                     "recording": macroStatus.recording != .idle, "recorderCheck": recorderCheck,
                                     "message": settingsMessage, "macroMessage": macroMessage, "bundle": Bundle.main.bundleIdentifier ?? "",
                                     "hotKeys": hotKeys.count, "hotKeysRefused": hotKeyProblems.count,
                                     "recordingState": "\(macroStatus.recording)", "autoClicking": macroStatus.autoClicking,
                                     "recordedSteps": macroStatus.recordedSteps,
                                     "capture": reading.screenCaptured.map { $0 ? (reading.screenBlank ? "black picture" : "ok, \(reading.screenLines) lines of text") : "no picture" } ?? "not looked yet",
                                     "displayAsleep": CGDisplayIsAsleep(CGMainDisplayID()) != 0]
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: SiverSol.supportDirectory.appendingPathComponent("status.json"), options: .atomic)
            }
        }
    }
}
