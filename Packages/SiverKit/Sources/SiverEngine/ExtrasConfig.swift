import Darwin
import Foundation
import Network
import SiverCore
import SiverInput
import SiverNotify

/// Toggles and thresholds for the permission-free extras. Every field has a default, so old config files keep working.
public struct ExtrasConfig: Codable, Equatable, Sendable {
    /// "🎉 Rolled <Aura>" from the game's own roll event, with a screenshot at the cutscene's best moment.
    public var auraRollFeed = true
    /// No key presses or clicks while a roll cutscene plays.
    public var cutsceneLock = true
    /// Click Play when the game sits on its title screen, and say so if that fails for 2 minutes.
    public var menuSentinel = true
    /// No log activity for 6 minutes while Roblox is open = frozen: alert, then recover.
    public var freezeWatchdog = true
    public var sessionInspector = true
    public var dailyResetCountdown = true
    /// A Discord message 10 minutes before the daily reset. Off by default.
    public var dailyResetPing = false
    public var resourceMonitor = true
    public var memoryAlertGB: Double = 6
    /// Rejoin when Roblox memory is above the limit and no rare biome is active. Off by default.
    public var memoryAutoRejoin = false
    public var updateWatch = true
    public var networkSentinel = true
    public var biomeIntelligence = true
    public var windowGuard = true
    /// A local sound on a rare biome or a rare aura. Off by default.
    public var soundCue = false
    /// Moments: short video clips of the Roblox window, kept on this Mac. Off by default.
    public var moments = false
    /// A clip for a roll the game itself plays a cutscene for, as long as the cutscene.
    public var momentsOnRolls = true
    /// A 12-second clip when a rare biome starts.
    public var momentsOnRareBiomes = true
    /// Also post the clip to Discord when it is small enough. Off by default.
    public var momentsUpload = false
    /// The Moments folder may grow to this many gigabytes; the oldest clips go first.
    public var momentsCapGB: Double = 2
    /// Draw a Session Wrapped card when a session of ten minutes or more ends. It stays on this Mac.
    public var wrappedOnStop = true
    /// Also post the card to Rich routes that carry the daily report. Off by default.
    public var wrappedPost = false
    /// Battery guard: on a MacBook, say so when it goes on battery during a run, and again below 20%.
    public var batteryGuard = true
    /// Which macros may play (a profile can narrow this: Glitch Hunt keeps out anything that could leave the server).
    public var macroPolicy = MacroPolicy.all
    /// Profiles the user saved, beside the built-in ones.
    public var profiles: [Profile] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExtrasConfig()
        auraRollFeed = try c.decodeIfPresent(Bool.self, forKey: .auraRollFeed) ?? d.auraRollFeed
        cutsceneLock = try c.decodeIfPresent(Bool.self, forKey: .cutsceneLock) ?? d.cutsceneLock
        menuSentinel = try c.decodeIfPresent(Bool.self, forKey: .menuSentinel) ?? d.menuSentinel
        freezeWatchdog = try c.decodeIfPresent(Bool.self, forKey: .freezeWatchdog) ?? d.freezeWatchdog
        sessionInspector = try c.decodeIfPresent(Bool.self, forKey: .sessionInspector) ?? d.sessionInspector
        dailyResetCountdown = try c.decodeIfPresent(Bool.self, forKey: .dailyResetCountdown) ?? d.dailyResetCountdown
        dailyResetPing = try c.decodeIfPresent(Bool.self, forKey: .dailyResetPing) ?? d.dailyResetPing
        resourceMonitor = try c.decodeIfPresent(Bool.self, forKey: .resourceMonitor) ?? d.resourceMonitor
        memoryAlertGB = try c.decodeIfPresent(Double.self, forKey: .memoryAlertGB) ?? d.memoryAlertGB
        memoryAutoRejoin = try c.decodeIfPresent(Bool.self, forKey: .memoryAutoRejoin) ?? d.memoryAutoRejoin
        updateWatch = try c.decodeIfPresent(Bool.self, forKey: .updateWatch) ?? d.updateWatch
        networkSentinel = try c.decodeIfPresent(Bool.self, forKey: .networkSentinel) ?? d.networkSentinel
        biomeIntelligence = try c.decodeIfPresent(Bool.self, forKey: .biomeIntelligence) ?? d.biomeIntelligence
        windowGuard = try c.decodeIfPresent(Bool.self, forKey: .windowGuard) ?? d.windowGuard
        soundCue = try c.decodeIfPresent(Bool.self, forKey: .soundCue) ?? d.soundCue
        moments = try c.decodeIfPresent(Bool.self, forKey: .moments) ?? d.moments
        momentsOnRolls = try c.decodeIfPresent(Bool.self, forKey: .momentsOnRolls) ?? d.momentsOnRolls
        momentsOnRareBiomes = try c.decodeIfPresent(Bool.self, forKey: .momentsOnRareBiomes) ?? d.momentsOnRareBiomes
        momentsUpload = try c.decodeIfPresent(Bool.self, forKey: .momentsUpload) ?? d.momentsUpload
        momentsCapGB = try c.decodeIfPresent(Double.self, forKey: .momentsCapGB) ?? d.momentsCapGB
        wrappedOnStop = try c.decodeIfPresent(Bool.self, forKey: .wrappedOnStop) ?? d.wrappedOnStop
        wrappedPost = try c.decodeIfPresent(Bool.self, forKey: .wrappedPost) ?? d.wrappedPost
        macroPolicy = try c.decodeIfPresent(MacroPolicy.self, forKey: .macroPolicy) ?? d.macroPolicy
        batteryGuard = try c.decodeIfPresent(Bool.self, forKey: .batteryGuard) ?? d.batteryGuard
        profiles = try c.decodeIfPresent([Profile].self, forKey: .profiles) ?? []
    }
}

/// One reading of the Roblox process (Resource Monitor).
public struct ResourceSample: Equatable, Sendable, Identifiable {
    public var at: Date
    /// Memory footprint in bytes (what Activity Monitor calls "Memory").
    public var memoryBytes: UInt64
    /// CPU use since the previous sample, in percent of one core (can exceed 100).
    public var cpuPercent: Double
    public var id: Date { at }
    public var memoryGB: Double { Double(memoryBytes) / 1_073_741_824 }

    public init(at: Date, memoryBytes: UInt64, cpuPercent: Double) {
        self.at = at; self.memoryBytes = memoryBytes; self.cpuPercent = cpuPercent
    }
}

/// Process statistics through libproc. Works for any process of the same user; needs no permission.
public enum ProcessStats {
    private static let timebase: (numer: Double, denom: Double) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (Double(info.numer), Double(max(1, info.denom)))
    }()

    /// (memory footprint in bytes, total CPU time in nanoseconds), or nil if the process is gone.
    public static func usage(pid: pid_t) -> (memory: UInt64, cpuNs: Double)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        let ticks = Double(info.ri_user_time &+ info.ri_system_time)
        return (info.ri_phys_footprint, ticks * timebase.numer / timebase.denom)
    }
}

/// A change in the Mac's network path (Network Sentinel).
public struct NetworkChange: Equatable, Sendable, Identifiable {
    public var at: Date
    public var online: Bool
    /// "Wi-Fi", "Ethernet", "Cellular" or "none".
    public var interface: String
    public var id: Date { at }
}

/// NWPathMonitor wrapper that keeps a short timeline of drops and restores.
public final class NetworkSentinel: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var changes: [NetworkChange] = []
    private var started = false
    public var onChange: (@Sendable (NetworkChange) -> Void)?

    public init() {}

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let name = path.usesInterfaceType(.wifi) ? "Wi-Fi" : path.usesInterfaceType(.wiredEthernet) ? "Ethernet"
                : path.usesInterfaceType(.cellular) ? "Cellular" : (path.status == .satisfied ? "other" : "none")
            self?.record(NetworkChange(at: Date(), online: path.status == .satisfied, interface: name))
        }
        monitor.start(queue: DispatchQueue(label: "siversol.network"))
    }

    public func stop() { monitor.cancel() }

    func record(_ change: NetworkChange) {
        lock.lock()
        let isNew = changes.last.map { $0.online != change.online || $0.interface != change.interface } ?? true
        if isNew {
            changes.append(change)
            if changes.count > 200 { changes.removeFirst(changes.count - 200) }
        }
        lock.unlock()
        if isNew { onChange?(change) }
    }

    public var timeline: [NetworkChange] { lock.lock(); defer { lock.unlock() }; return changes }
    public var isOnline: Bool { lock.lock(); defer { lock.unlock() }; return changes.last?.online ?? true }

    /// Changes inside a time window, as incident steps ("network dropped", "network back (Wi-Fi)").
    public func steps(from: Date, to: Date) -> [IncidentReport.Step] {
        timeline.filter { $0.at >= from && $0.at <= to }.map {
            IncidentReport.Step($0.online ? "network back (\($0.interface))" : "network dropped", at: $0.at)
        }
    }
}

/// Mutable state shared by the extras. One lock, small critical sections.
final class ExtraState: @unchecked Sendable {
    private let lock = NSLock()
    private var inspector = SessionInspector()
    private var lab: [LogLabEntry] = []
    private var cutsceneEnd: Date?
    private var rolls: [(key: String, at: Date)] = []
    private var samples: [ResourceSample] = []
    private var lastCPU: (ns: Double, at: Date, pid: pid_t)?
    private var flags: Set<String> = []
    private var warning: String?

    func note(_ event: LogEvent) {
        lock.lock(); defer { lock.unlock() }
        let entry = inspector.note(event)
        if let w = inspector.info.windowWidth, let h = inspector.info.windowHeight { RobloxChrome.noteRenderSize(width: w, height: h) }
        if let entry {
            // Heartbeats would drown the feed: keep only the latest one.
            if entry.kind == .heartbeat, let i = lab.lastIndex(where: { $0.kind == .heartbeat }) { lab.remove(at: i) }
            // The game repeats identical status lines; one entry per distinct state is enough.
            if entry.kind == .presence, let last = lab.last(where: { $0.kind == .presence }), last.summary == entry.summary { return }
            lab.append(entry)
            if lab.count > 600 { lab.removeFirst(lab.count - 600) }
        }
    }

    func setClientVersion(_ v: String?) { lock.lock(); inspector.setClientVersion(v); lock.unlock() }
    var session: SessionInfo { lock.lock(); defer { lock.unlock() }; return inspector.info }
    var unknownSignals: [String: Int] { lock.lock(); defer { lock.unlock() }; return inspector.unknown }
    var logLab: [LogLabEntry] { lock.lock(); defer { lock.unlock() }; return lab }

    // Cutscene lock
    func lockForCutscene(until: Date) { lock.lock(); cutsceneEnd = max(cutsceneEnd ?? until, until); lock.unlock() }
    func cutsceneRemaining(now: Date = Date()) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return max(0, (cutsceneEnd ?? .distantPast).timeIntervalSince(now))
    }

    // Rolls, to avoid announcing the same aura twice (roll, then its equip line a few seconds later)
    func noteRoll(_ name: String, at: Date) {
        lock.lock(); defer { lock.unlock() }
        rolls.append((AuraCatalog.key(name), at))
        rolls.removeAll { at.timeIntervalSince($0.at) > 600 }
    }
    func wasJustRolled(_ internalName: String, at: Date, within: TimeInterval = 180) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let key = AuraCatalog.key(internalName)
        return rolls.contains { $0.key == key && abs(at.timeIntervalSince($0.at)) <= within }
    }

    // Resource samples
    func addSample(pid: pid_t, memory: UInt64, cpuNs: Double, at: Date) -> ResourceSample {
        lock.lock(); defer { lock.unlock() }
        var cpu = 0.0
        if let last = lastCPU, last.pid == pid, at > last.at {
            cpu = max(0, (cpuNs - last.ns) / (at.timeIntervalSince(last.at) * 1_000_000_000) * 100)
        }
        lastCPU = (cpuNs, at, pid)
        let sample = ResourceSample(at: at, memoryBytes: memory, cpuPercent: cpu)
        samples.append(sample)
        if samples.count > 720 { samples.removeFirst(samples.count - 720) }
        return sample
    }
    var resourceSamples: [ResourceSample] { lock.lock(); defer { lock.unlock() }; return samples }

    /// One-shot flags ("already alerted about X"). Returns true the first time a flag is set.
    private var battery = BatteryGuard()
    func noteBattery(_ reading: PowerReading, now: Date) -> BatteryGuard.Alert? {
        lock.lock(); defer { lock.unlock() }
        return battery.note(reading, now: now)
    }

    func raise(_ flag: String) -> Bool { lock.lock(); defer { lock.unlock() }; return flags.insert(flag).inserted }
    func lower(_ flag: String) { lock.lock(); flags.remove(flag); lock.unlock() }
    func lower(prefix: String) { lock.lock(); flags = flags.filter { !$0.hasPrefix(prefix) }; lock.unlock() }

    var windowWarning: String? {
        get { lock.lock(); defer { lock.unlock() }; return warning }
        set { lock.lock(); warning = newValue; lock.unlock() }
    }
}
