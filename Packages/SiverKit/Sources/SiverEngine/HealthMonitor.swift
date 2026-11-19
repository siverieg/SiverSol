import AppKit
import Foundation
import SiverCore
import SiverInput
import SiverNotify
import SiverVision

/// What went wrong with Roblox (F8).
public enum Trouble: Equatable, Sendable, CustomStringConvertible {
    case disconnectLine(reason: Int?, kind: String)
    case processExited
    case disconnectDialog(String)
    case frozen
    /// Joined, but still on the game's start menu after a while. Fixed by clicking Play; Roblox is not restarted.
    case stuckInMenu
    /// The user asked for a rejoin from the menu.
    case requested
    /// Roblox is using more memory than the user's limit (Resource Monitor, opt-in).
    case memoryHigh(gigabytes: Double)

    /// True when the client is certainly off the server. Only then may Roblox be restarted during a rare biome (hard rule 5).
    public var isDisconnected: Bool {
        switch self {
        case .disconnectLine, .processExited, .disconnectDialog: return true
        case .frozen, .stuckInMenu, .requested, .memoryHigh: return false
        }
    }

    /// Does fixing this involve quitting Roblox?
    public var needsRestart: Bool { self != .stuckInMenu }

    public var description: String {
        switch self {
        case .disconnectLine(let reason, _): return "Disconnected" + (reason.map { " (reason \($0))" } ?? "")
        case .processExited: return "Roblox closed"
        case .disconnectDialog(let text): return "Disconnected (\"\(text)\" on screen)"
        case .frozen: return "Roblox frozen"
        case .stuckInMenu: return "Stuck on the start menu"
        case .requested: return "Rejoin requested"
        case .memoryHigh(let gb): return String(format: "Roblox memory high (%.1f GB)", gb)
        }
    }
}

/// Pure decision logic for the four F8 signals. The engine feeds it observations; tests feed it fakes.
public struct HealthState: Sendable {
    public struct Config: Codable, Equatable, Sendable {
        /// After a disconnect line, wait this long for the game to rejoin by itself before calling it trouble.
        public var disconnectGraceS: Double = 20
        /// Roblox must be gone this long to count as closed (not a quick relaunch).
        public var exitGraceS: Double = 8
        /// Freeze Watchdog: the client writes a heartbeat line every 120 s, so 6 silent minutes = three missed.
        public var frozenLogS: Double = 360
        /// Also require an unchanged picture before calling it frozen (needs Screen Recording). Off: the log decides.
        public var frozenNeedsStillFrame = false
        public var frozenFrameS: Double = 120
        /// On the start menu this long = nobody is going to click Play.
        public var menuGraceS: Double = 45
        public init() {}
    }

    public var config = Config()
    private var pendingDisconnect: (reason: Int?, kind: String, at: Date)?
    private var sawRobloxRunning = false
    private var goneSince: Date?
    private var frame: (hash: UInt64, since: Date)?
    private var menuSince: Date?

    public init(config: Config = Config()) { self.config = config }

    static let dialogPhrases = ["disconnected", "reconnect", "connection error", "lost connection", "you were kicked",
                                "you have been kicked", "error code", "please check your internet", "same account launched"]

    public mutating func note(_ event: LogEvent) {
        switch event {
        case .disconnected(let reason, let kind, let at): pendingDisconnect = (reason, kind, at)
        case .joined: pendingDisconnect = nil      // the game (or we) joined a server again: that disconnect is history
        case .presence, .merchant, .signal: break
        }
    }

    public mutating func noteFrame(hash: UInt64, now: Date) {
        if let f = frame, FrameHash.distance(f.hash, hash) <= 1 { return }
        frame = (hash, now)
    }

    /// The user closed Roblox themselves: stop treating its absence as trouble until it is seen running again.
    public mutating func forgetRoblox() {
        sawRobloxRunning = false; goneSince = nil; pendingDisconnect = nil; frame = nil; menuSince = nil
    }

    /// Forget everything (after a recovery attempt).
    public mutating func reset() {
        pendingDisconnect = nil; goneSince = nil; frame = nil; menuSince = nil
    }

    /// The first disconnect phrase found in OCR text, ignoring the chat area.
    public static func dialogText(in screen: [TextBox], chatRegion: CGRect = GuardianPolicy().chatRegion) -> String? {
        for line in screen where !chatRegion.contains(line.center) {
            let lower = line.text.lowercased()
            if dialogPhrases.contains(where: lower.contains) { return line.text }
        }
        return nil
    }

    public mutating func evaluate(now: Date, robloxRunning: Bool, lastLogBytesAt: Date?, screen: [TextBox]?,
                                  phase: BiomeTracker.Phase = .unknown) -> Trouble? {
        if phase == .menu { if menuSince == nil { menuSince = now } } else { menuSince = nil }
        if robloxRunning {
            sawRobloxRunning = true
            goneSince = nil
        } else if sawRobloxRunning {
            if goneSince == nil { goneSince = now }
            if let g = goneSince, now.timeIntervalSince(g) >= config.exitGraceS { return .processExited }
            return nil
        } else {
            return nil   // Roblox was never running while we watched: nothing to recover
        }
        if let d = pendingDisconnect, now.timeIntervalSince(d.at) >= config.disconnectGraceS {
            return .disconnectLine(reason: d.reason, kind: d.kind)
        }
        if let screen, let text = Self.dialogText(in: screen) { return .disconnectDialog(text) }
        if let bytes = lastLogBytesAt, now.timeIntervalSince(bytes) >= config.frozenLogS {
            if !config.frozenNeedsStillFrame { return .frozen }
            if let f = frame, now.timeIntervalSince(f.since) >= config.frozenFrameS { return .frozen }
        }
        if let m = menuSince, now.timeIntervalSince(m) >= config.menuGraceS { return .stuckInMenu }
        return nil
    }
}

/// F8 recovery: quit Roblox, relaunch into the user's own private server, get through the start menu, report a timeline.
public final class Rejoiner: @unchecked Sendable {
    public struct Config: Codable, Equatable, Sendable {
        public var enabled = true
        public var quitGraceS: Double = 20
        public var joinTimeoutS: Double = 75
        public var presenceTimeoutS: Double = 90
        public var menuTimeoutS: Double = 90
        /// Wait between attempts (minutes): 1, 2, 5, 10.
        public var backoffMinutes: [Double] = [1, 2, 5, 10]
        public init() {}
    }

    /// Everything the rejoiner touches, behind closures so tests can run it without Roblox.
    public struct World: Sendable {
        public var now: @Sendable () -> Date = { Date() }
        public var sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }
        public var robloxRunning: @Sendable () -> Bool
        /// A Roblox process with a game window. False for the windowless tray process, which needs no quitting.
        public var gameOpen: @Sendable () -> Bool
        public var quitRoblox: @Sendable (_ force: Bool) -> Void
        public var open: @Sendable (URL) -> Bool
        /// Current radar state: (log session id, phase, the server we are joined to in this log or nil).
        public var radar: @Sendable () -> (session: String?, phase: BiomeTracker.Phase, jobId: String?)
        public var look: @Sendable () async -> [TextBox]?
        public var approve: @Sendable (GuardedAction) async -> GuardianVerdict
        /// Click the center of a text box (window ratios). Returns false if it could not (no focus, user busy).
        public var click: @Sendable (TextBox) async -> Bool
    }

    public var config: Config
    private let world: World
    private let shareCode: String?
    private let shareLink: String?
    public var log: (@Sendable (String) -> Void)?

    public init(config: Config = Config(), secrets: Secrets, world: World) {
        self.config = config; self.world = world
        shareLink = secrets.serverLink
        shareCode = Self.shareCode(from: secrets)
    }

    /// The share code: the explicit secret, else the `code` query item of the share link.
    public static func shareCode(from secrets: Secrets) -> String? {
        if let c = secrets.privateServerShareCode?.trimmingCharacters(in: .whitespaces), !c.isEmpty, c.allSatisfy({ $0.isLetter || $0.isNumber }) { return c }
        guard let link = secrets.serverLink, let items = URLComponents(string: link)?.queryItems else { return nil }
        return items.first { $0.name == "code" }?.value.flatMap { $0.allSatisfy({ $0.isLetter || $0.isNumber }) ? $0 : nil }
    }

    public static func deepLink(code: String) -> URL? {
        URL(string: "roblox://navigation/share_links?code=\(code)&type=Server")
    }

    /// May Roblox be quit right now? Never during a rare biome unless the client is already disconnected (hard rule 5).
    public static func mayRestart(trouble: Trouble, currentBiomeIsRare: Bool) -> Bool {
        !currentBiomeIsRare || trouble.isDisconnected
    }

    private func wait(upTo seconds: TimeInterval, step: TimeInterval = 1, until done: () -> Bool) async -> Bool {
        let deadline = world.now().addingTimeInterval(seconds)
        while world.now() < deadline {
            if done() { return true }
            await world.sleep(step)
        }
        return done()
    }

    /// One full recovery attempt. Always returns a timeline; `recovered` says whether the player is back in the game.
    public func recover(from trouble: Trouble, incidentId: String) async -> IncidentReport {
        var steps: [IncidentReport.Step] = [.init("detected: \(trouble)", at: world.now())]
        func step(_ label: String) { steps.append(.init(label, at: world.now())); log?("rejoin: \(label)") }
        func report(_ recovered: Bool) -> IncidentReport {
            IncidentReport(id: incidentId, cause: "\(trouble)", steps: steps, recovered: recovered)
        }
        guard let code = shareCode, let deepLink = Self.deepLink(code: code) else {
            step("no private server link in settings, cannot rejoin")
            return report(false)
        }
        // Remember where we were. After a quit, Roblox relaunches itself windowless and starts a new log BEFORE we get
        // here, so the log session alone cannot tell us that the link worked: the server id has to change too.
        let before = world.radar()
        if !trouble.needsRestart {
            // Already in the server, just not past the start menu: only the clicking is needed.
            let menu = await passStartMenu()
            steps += menu.steps
            return report(menu.inGame)
        }

        if world.robloxRunning() && world.gameOpen() {
            world.quitRoblox(false)
            if !(await wait(upTo: config.quitGraceS, until: { !self.world.robloxRunning() })) {
                world.quitRoblox(true)
                _ = await wait(upTo: 5, until: { !self.world.robloxRunning() })
                step("Roblox did not quit in \(Int(config.quitGraceS)) s, forced it")
            } else {
                step("quit Roblox")
            }
            await world.sleep(2)
        }

        // Only ever the user's own private server: the link comes from their saved settings, nothing else.
        _ = world.open(deepLink)
        step("opened the private server link")
        func joinedNewSession() -> Bool {
            let r = self.world.radar()
            guard let job = r.jobId else { return false }
            return r.session != before.session || job != before.jobId
        }
        var joined = await wait(upTo: config.joinTimeoutS, until: joinedNewSession)
        if !joined, let shareLink, let web = URL(string: shareLink) {
            // Known Mac issue: the roblox:// share link sometimes does not start the app. Try the web link.
            _ = world.open(web)
            step("deep link did not join, opened the web link instead")
            joined = await wait(upTo: config.joinTimeoutS, until: joinedNewSession)
        }
        guard joined else { step("no server join seen in the Roblox log"); return report(false) }
        step("joined the server")

        guard await wait(upTo: config.presenceTimeoutS, until: { self.world.radar().phase != .unknown }) else {
            step("joined, but the game sent no status within \(Int(config.presenceTimeoutS)) s")
            return report(false)
        }

        let menu = await passStartMenu()
        steps += menu.steps
        return report(menu.inGame)
    }

    /// Start menu: click "Play" (or "Skip") when it is on screen, each click through Guardian.
    private func passStartMenu() async -> (steps: [IncidentReport.Step], inGame: Bool) {
        var steps: [IncidentReport.Step] = []
        func step(_ label: String) { steps.append(.init(label, at: world.now())); log?("rejoin: \(label)") }
        let menuDeadline = world.now().addingTimeInterval(config.menuTimeoutS)
        var clicks = 0
        var seenText: [String] = []
        while world.radar().phase != .inGame && world.now() < menuDeadline {
            if let screen = await world.look() {
                seenText = screen.map(\.text)
                for anchor in Self.menuAnchors {
                    guard let box = screen.first(where: { GuardianPolicy.label($0.text) == anchor.lowercased() }) else { continue }
                    if await world.approve(.clickAnchor(anchor)) == .approved, await world.click(box) {
                        clicks += 1
                        step("clicked \(anchor)")
                    }
                    break
                }
            }
            await world.sleep(3)
        }
        guard world.radar().phase == .inGame else {
            step(clicks == 0 ? "stuck on the start menu: no Play or Skip button found" : "clicked \(clicks) time(s) but still not in game")
            if clicks == 0, !seenText.isEmpty { log?("rejoin: text on the menu was: \(seenText.prefix(25).joined(separator: " | "))") }
            return (steps, false)
        }
        step("in game")
        return (steps, true)
    }

    /// Buttons that lead from the game's start menu into the world, in the order to try them.
    public static let menuAnchors = ["Skip", "Play"]
}

extension Rejoiner.World {
    /// The real thing: NSWorkspace, the live radar, Guardian and a focus-swapped HID click.
    public static func live(radar: BiomeRadar, guardian: Guardian, input: InputDriver, paused: @escaping @Sendable () -> Bool) -> Rejoiner.World {
        Rejoiner.World(
            robloxRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: RobloxWindowFinder.bundleId).isEmpty },
            gameOpen: { RobloxWindowFinder.hasGameWindow() },
            quitRoblox: { force in
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: RobloxWindowFinder.bundleId) {
                    if force { app.forceTerminate() } else { app.terminate() }
                }
            },
            open: { NSWorkspace.shared.open($0) },
            radar: {
                let s = radar.snapshot
                return (s.sessionId, s.phase, s.serverJobId)
            },
            look: { await Guardian.robloxLook()?.text },
            approve: { await guardian.approve($0) },
            click: { box in
                guard !paused(), InputDriver.isTrusted, let window = RobloxWindowFinder.mainWindow() else { return false }
                // Do not grab the mouse while the user is using it; the caller retries a few seconds later.
                guard input.userIdleSeconds() >= 3 else { return false }
                let point = window.point(ratioX: box.center.x, ratioY: box.center.y)
                return await FocusManager.withRobloxFrontmost { await input.click(at: point) } == true
            })
    }
}
