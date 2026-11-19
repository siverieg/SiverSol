import Foundation
import CoreGraphics
import SiverCore
import SiverVision

/// Something SiverSol wants to do to the Roblox window. Every one of these must pass `Guardian.approve` first.
public enum GuardedAction: Equatable, Sendable, CustomStringConvertible {
    /// A harmless key (anti-AFK jump, camera zoom).
    case key(String)
    /// A click on an OCR anchor such as "Play", "Skip" or "Reconnect".
    case clickAnchor(String)
    /// Using, crafting, buying or selling an item (F9). Off unless the user turns the feature on.
    case useItem(name: String, feature: String)
    /// A click from a user-recorded macro or the auto clicker, at a position in the game area (ratios).
    case macroClick(x: Double, y: Double)
    /// The same, from a macro whose owner allowed clicks that may use an item (off by default, capped per hour).
    case macroItemClick(x: Double, y: Double)
    /// Escape, used to back out of a dangerous dialog. Always allowed.
    case escape

    public var description: String {
        switch self {
        case .key(let k): return "key \(k)"
        case .clickAnchor(let a): return "click \"\(a)\""
        case .useItem(let name, let feature): return "use \(name) (\(feature))"
        case .macroClick(let x, let y): return String(format: "macro click at %.0f%%, %.0f%%", x * 100, y * 100)
        case .macroItemClick(let x, let y): return String(format: "macro click (items allowed) at %.0f%%, %.0f%%", x * 100, y * 100)
        case .escape: return "escape"
        }
    }
}

public enum GuardianVerdict: Equatable, Sendable {
    case approved
    /// `forbidden` = a dangerous dialog is on screen: press Escape, pause automation, alert the user.
    case blocked(reason: String, forbidden: Bool)
    /// Not now, but nothing is wrong (a roll cutscene is playing). Try again shortly.
    case held(reason: String)

    public var isApproved: Bool { self == .approved }
}

/// Per-feature permission for item use (hard rule 3). Everything is off in V1.0.
public struct ItemFeature: Codable, Equatable, Sendable {
    public var enabled = false
    public var allowlist: [String] = []
    public var hourlyCap = 0
    public init(enabled: Bool = false, allowlist: [String] = [], hourlyCap: Int = 0) {
        self.enabled = enabled; self.allowlist = allowlist; self.hourlyCap = hourlyCap
    }
}

/// F15 "AuraGuard": the rules, as a pure function of the action and the text on screen.
public struct GuardianPolicy: Sendable {
    /// Clicks are only ever allowed on these anchors.
    public var clickAnchors: Set<String> = ["play", "skip", "reconnect", "rejoin", "leave", "ok", "close"]
    public var features: [String: ItemFeature] = [:]
    /// A text line whose CENTER falls in here is chat (other people's words), so it cannot trigger a block.
    /// Chat lines are left-aligned from x≈0.01 and at most about 0.36 wide, so their centers stay left of 0.2.
    /// A dialog is centered in the window, so its text can never have its center this far left.
    /// A ratio of the game area (measured on a whole window with a title bar, converted here).
    public var chatRegion = GameChrome.contentRegion(fromLegacyWindow: CGRect(x: 0, y: 0.10, width: 0.22, height: 0.55))

    public init() {}

    static let purchaseWords = ["robux", "purchase", "purchasing", "premium"]
    static let buttonLabels: Set<String> = ["buy", "buy now", "confirm", "confirm purchase", "buy robux", "get robux", "pay"]
    static let auraDangerWords = ["delete", "deleting", "sell", "selling", "trade", "trading", "auto delete", "auto-delete"]
    static let storageTitles = ["aura storage", "aura inventory", "storage"]
    static let lockLabels: Set<String> = ["lock", "unlock", "lock aura", "unlock aura"]
    /// Panels where a click can use, equip or craft an item: their titles, and the buttons that do it.
    static let itemPanelTitles: Set<String> = ["inventory", "crafting", "potion crafting", "gear crafting"]
    static let itemActionLabels: Set<String> = ["use", "use item", "equip", "unequip", "craft", "auto craft", "consume"]

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    public static func label(_ text: String) -> String {
        words(text).joined(separator: " ")
    }

    /// Why the screen is dangerous, or nil if it looks safe. Chat text is ignored.
    public func forbiddenContext(in screen: [TextBox]) -> String? {
        let lines = screen.filter { !chatRegion.contains($0.center) }
        for line in lines {
            let w = Self.words(line.text)
            let label = w.joined(separator: " ")
            if let hit = Self.purchaseWords.first(where: w.contains) { return "purchase dialog (\"\(hit)\" on screen)" }
            if Self.buttonLabels.contains(label) { return "purchase or confirm button (\"\(line.text)\")" }
            if let hit = Self.auraDangerWords.first(where: { label == $0 || w.contains($0) }) { return "delete, sell or trade UI (\"\(hit)\" on screen)" }
            if Self.lockLabels.contains(label) { return "aura lock control (\"\(line.text)\")" }
        }
        return nil
    }

    /// An item panel (the Inventory, a crafting window) is open: what gave it away, or nil.
    /// A click in such a panel can use an item, so it is treated like a click on the item bar (hard rule 3).
    public func itemPanel(in screen: [TextBox]) -> String? {
        for line in screen where !chatRegion.contains(line.center) {
            let label = Self.label(line.text)
            if Self.itemPanelTitles.contains(label) { return "the \(line.text.trimmingCharacters(in: .whitespaces)) window is open" }
            if Self.itemActionLabels.contains(label) { return "a “\(line.text.trimmingCharacters(in: .whitespaces))” button is on screen" }
        }
        return nil
    }

    public func auraStorageOpen(in screen: [TextBox]) -> Bool {
        screen.contains { line in
            guard !chatRegion.contains(line.center) else { return false }
            let label = Self.label(line.text)
            return label == "aura storage" || label.hasPrefix("aura storage") || label == "aura inventory"
        }
    }

    /// `screen == nil` means we could not look (no permission, window gone). `itemUsesLastHour` feeds the cap check.
    public func evaluate(_ action: GuardedAction, screen: [TextBox]?, itemUsesLastHour: Int = 0) -> GuardianVerdict {
        if action == .escape { return .approved }
        guard let screen else {
            return .blocked(reason: "cannot see the Roblox window, so nothing is pressed or clicked blind", forbidden: false)
        }
        if let why = forbiddenContext(in: screen) { return .blocked(reason: why, forbidden: true) }
        if auraStorageOpen(in: screen) {
            return .blocked(reason: "Aura Storage is open; SiverSol never presses or clicks anything inside it", forbidden: false)
        }
        switch action {
        case .macroClick:
            // A macro click is the user's own recorded input: allowed wherever nothing dangerous is on screen.
            // While an item panel is open a click can use an item, so only a macro that was allowed to may click.
            if let why = itemPanel(in: screen) {
                return .blocked(reason: "\(why), and a click could use an item. Close it, or allow item clicks for this macro", forbidden: false)
            }
            return .approved
        case .key, .escape, .macroItemClick:
            // (Item clicks have their own opt-in and hourly cap in the macro player.)
            return .approved
        case .clickAnchor(let anchor):
            let wanted = Self.label(anchor)
            guard clickAnchors.contains(wanted) else {
                return .blocked(reason: "\"\(anchor)\" is not on the list of things SiverSol may click", forbidden: false)
            }
            guard screen.contains(where: { Self.label($0.text) == wanted }) else {
                return .blocked(reason: "\"\(anchor)\" is not on screen", forbidden: false)
            }
            return .approved
        case .useItem(let name, let feature):
            guard let f = features[feature], f.enabled else {
                return .blocked(reason: "the \(feature) feature is off", forbidden: false)
            }
            guard f.allowlist.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
                return .blocked(reason: "\(name) is not on the \(feature) allowlist", forbidden: false)
            }
            guard itemUsesLastHour < f.hourlyCap else {
                return .blocked(reason: "hourly cap for \(feature) reached (\(f.hourlyCap))", forbidden: false)
            }
            return .approved
        }
    }
}

/// Append-only audit trail of every action Guardian was asked about (F15).
public final class ActionLog: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var time: Date
        public var action: String
        public var verdict: String
        public var reason: String?
        public var frameHash: String?
    }

    private let lock = NSLock()
    private let url: URL?
    public private(set) var entries: [Entry] = []

    public init(url: URL?) { self.url = url }
    public static var defaultURL: URL { SiverSol.supportDirectory.appendingPathComponent("actions.jsonl") }

    public func append(_ entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        entries.append(entry)
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
        guard let url, let data = try? Self.encoder.encode(entry) else { return }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd(); try? h.write(contentsOf: data + Data("\n".utf8)); try? h.close()
        }
    }

    public func itemUses(since: Date) -> Int {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.time >= since && $0.verdict == "approved" && $0.action.hasPrefix("use ") }.count
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }()
}

/// The single gate in front of every synthetic input. Takes a fresh screenshot, reads it, applies the policy, logs it.
public final class Guardian: @unchecked Sendable {
    public struct Look: Sendable {
        public var text: [TextBox]
        public var frameHash: UInt64
        public init(text: [TextBox], frameHash: UInt64) { self.text = text; self.frameHash = frameHash }
    }

    public var policy: GuardianPolicy
    public let log: ActionLog
    private let look: @Sendable () async -> Look?
    private let cacheLock = NSLock()
    private var lastLook: (look: Look?, at: Date)?
    /// A reason to send no input right now (a roll cutscene is playing), or nil. Checked before the screen is read.
    public var hold: (@Sendable () -> String?)?
    /// Called when a forbidden dialog is on screen. The owner presses Escape, pauses automation and alerts the user.
    public var onForbidden: (@Sendable (_ action: GuardedAction, _ reason: String) async -> Void)?

    public init(policy: GuardianPolicy = GuardianPolicy(), log: ActionLog, look: @escaping @Sendable () async -> Look?) {
        self.policy = policy; self.log = log; self.look = look
    }

    /// The standard "look": capture the Roblox window and OCR it. nil when it cannot be seen.
    public static func robloxLook() async -> Look? {
        guard let window = RobloxWindowFinder.mainWindow(),
              let image = try? await WindowCapture.capture(windowId: window.windowId, titleBar: window.titleBar),
              let text = try? OCR.recognize(image) else { return nil }
        return Look(text: text, frameHash: FrameHash.average(image))
    }

    /// Was an item panel open the last time Guardian looked? (Used to count allowed item clicks toward their cap.)
    public var itemPanelOnLastLook: Bool {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard let text = lastLook?.look?.text else { return false }
        return policy.itemPanel(in: text) != nil
    }

    private func cachedLook(maxAge: TimeInterval, now: Date) -> (Look?, Bool) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if maxAge > 0, let l = lastLook, now.timeIntervalSince(l.at) <= maxAge { return (l.look, true) }
        return (nil, false)
    }

    /// `maxLookAge`: reuse the previous screenshot if it is at most this old (0 = always take a fresh one).
    /// Rapid macro clicks use one second, so the screen is still read every second while clicking.
    public func approve(_ action: GuardedAction, maxLookAge: TimeInterval = 0, now: Date = Date()) async -> GuardianVerdict {
        if action != .escape, let why = hold?() {
            log.append(ActionLog.Entry(time: now, action: action.description, verdict: "held", reason: why, frameHash: nil))
            return .held(reason: why)
        }
        var seen: Look?
        if action != .escape {
            let (cached, hit) = cachedLook(maxAge: maxLookAge, now: now)
            if hit { seen = cached } else {
                seen = await look()
                cacheLock.lock(); lastLook = (seen, Date()); cacheLock.unlock()
            }
        }
        let verdict = policy.evaluate(action, screen: seen?.text, itemUsesLastHour: log.itemUses(since: now.addingTimeInterval(-3600)))
        var entry = ActionLog.Entry(time: now, action: action.description, verdict: "approved", reason: nil,
                                    frameHash: seen.map { String($0.frameHash, radix: 16) })
        if case .blocked(let reason, let forbidden) = verdict {
            entry.verdict = forbidden ? "blocked-forbidden" : "blocked"
            entry.reason = reason
            log.append(entry)
            if forbidden { await onForbidden?(action, reason) }
        } else if maxLookAge == 0 || action.description.hasPrefix("macro click") == false || log.entries.last?.action != action.description {
            // Rapid identical macro clicks are logged once per position, not thousands of times.
            log.append(entry)
        }
        return verdict
    }

    /// What Guardian thinks of the screen right now, without doing anything (menu-bar dry run, `siversolctl guardian check`).
    public func dryRun() async -> (seen: Bool, lines: Int, verdicts: [(GuardedAction, GuardianVerdict)]) {
        let seen = await look()
        let actions: [GuardedAction] = [.key("space"), .clickAnchor("Play"), .clickAnchor("Skip"), .clickAnchor("Reconnect"),
                                        .useItem(name: "Heavenly Potion", feature: "autoPop")]
        return (seen != nil, seen?.text.count ?? 0, actions.map { ($0, policy.evaluate($0, screen: seen?.text)) })
    }
}
