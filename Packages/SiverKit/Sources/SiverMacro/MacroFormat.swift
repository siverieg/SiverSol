import CoreGraphics
import Foundation
import SiverCore
import SiverInput

public enum MouseButton: String, Codable, Sendable, CaseIterable { case left, right, middle }

/// One thing a macro does. Positions are ratios (0…1, top-left origin) of the game area, which is the Roblox
/// window without its title bar, so a macro survives the window being moved, resized or put in full screen,
/// on any display and at any pixel density. Camera turns are raw mouse deltas because the cursor is locked
/// while turning.
public enum MacroAction: Equatable, Sendable {
    case keyDown(code: UInt16)
    case keyUp(code: UInt16)
    case mouseMove(x: Double, y: Double)
    case mouseDown(button: MouseButton, x: Double, y: Double)
    case mouseUp(button: MouseButton, x: Double, y: Double)
    case mouseDelta(dx: Double, dy: Double)
    case scroll(dx: Double, dy: Double)
    // Smart steps
    case wait(seconds: Double)
    case waitText(text: String, timeoutS: Double)
    case waitBiome(biome: String, timeoutS: Double)
    case waitInGame(timeoutS: Double)

    public var isKeyboard: Bool {
        switch self { case .keyDown, .keyUp: return true; default: return false }
    }
    public var isMouse: Bool {
        switch self { case .mouseMove, .mouseDown, .mouseUp, .mouseDelta, .scroll: return true; default: return false }
    }
    public var isSmart: Bool {
        switch self { case .wait, .waitText, .waitBiome, .waitInGame: return true; default: return false }
    }
    public var isClick: Bool { if case .mouseDown = self { return true }; return false }
}

/// A step: how long after the previous step it happens, and what happens.
public struct MacroStep: Equatable, Sendable, Identifiable {
    public var id = UUID()
    /// Seconds after the previous step (the previous step's start, for input; its completion, for a smart step).
    public var delay: Double
    public var action: MacroAction

    public init(delay: Double, _ action: MacroAction) { self.delay = delay; self.action = action }
    public static func == (a: MacroStep, b: MacroStep) -> Bool { a.delay == b.delay && a.action == b.action }
}

extension MacroStep: Codable {
    enum Keys: String, CodingKey { case d, a, key, x, y, button, dx, dy, seconds, text, biome, timeout }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        delay = try c.decode(Double.self, forKey: .d)
        let kind = try c.decode(String.self, forKey: .a)
        func num(_ k: Keys) throws -> Double { try c.decode(Double.self, forKey: k) }
        func button() throws -> MouseButton { try c.decode(MouseButton.self, forKey: .button) }
        switch kind {
        case "keyDown": action = .keyDown(code: try c.decode(UInt16.self, forKey: .key))
        case "keyUp": action = .keyUp(code: try c.decode(UInt16.self, forKey: .key))
        case "move": action = .mouseMove(x: try num(.x), y: try num(.y))
        case "down": action = .mouseDown(button: try button(), x: try num(.x), y: try num(.y))
        case "up": action = .mouseUp(button: try button(), x: try num(.x), y: try num(.y))
        case "delta": action = .mouseDelta(dx: try num(.dx), dy: try num(.dy))
        case "scroll": action = .scroll(dx: try num(.dx), dy: try num(.dy))
        case "wait": action = .wait(seconds: try num(.seconds))
        case "waitText": action = .waitText(text: try c.decode(String.self, forKey: .text), timeoutS: try num(.timeout))
        case "waitBiome": action = .waitBiome(biome: try c.decode(String.self, forKey: .biome), timeoutS: try num(.timeout))
        case "waitInGame": action = .waitInGame(timeoutS: try num(.timeout))
        default: throw DecodingError.dataCorruptedError(forKey: .a, in: c, debugDescription: "unknown step type \(kind.prefix(30))")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        // Three decimals are plenty (1 ms) and keep files small.
        try c.encode((delay * 10000).rounded() / 10000, forKey: .d)
        func r(_ v: Double) -> Double { (v * 100000).rounded() / 100000 }
        switch action {
        case .keyDown(let code): try c.encode("keyDown", forKey: .a); try c.encode(code, forKey: .key)
        case .keyUp(let code): try c.encode("keyUp", forKey: .a); try c.encode(code, forKey: .key)
        case .mouseMove(let x, let y): try c.encode("move", forKey: .a); try c.encode(r(x), forKey: .x); try c.encode(r(y), forKey: .y)
        case .mouseDown(let b, let x, let y): try c.encode("down", forKey: .a); try c.encode(b, forKey: .button); try c.encode(r(x), forKey: .x); try c.encode(r(y), forKey: .y)
        case .mouseUp(let b, let x, let y): try c.encode("up", forKey: .a); try c.encode(b, forKey: .button); try c.encode(r(x), forKey: .x); try c.encode(r(y), forKey: .y)
        case .mouseDelta(let dx, let dy): try c.encode("delta", forKey: .a); try c.encode(r(dx), forKey: .dx); try c.encode(r(dy), forKey: .dy)
        case .scroll(let dx, let dy): try c.encode("scroll", forKey: .a); try c.encode(r(dx), forKey: .dx); try c.encode(r(dy), forKey: .dy)
        case .wait(let s): try c.encode("wait", forKey: .a); try c.encode(s, forKey: .seconds)
        case .waitText(let t, let timeout): try c.encode("waitText", forKey: .a); try c.encode(t, forKey: .text); try c.encode(timeout, forKey: .timeout)
        case .waitBiome(let b, let timeout): try c.encode("waitBiome", forKey: .a); try c.encode(b, forKey: .biome); try c.encode(timeout, forKey: .timeout)
        case .waitInGame(let timeout): try c.encode("waitInGame", forKey: .a); try c.encode(timeout, forKey: .timeout)
        }
    }
}

/// When a macro runs by itself.
public enum MacroTrigger: Equatable, Sendable, Codable {
    case everyMinutes(Double)
    case biomeStarted(String)
    case biomeEnded(String)
    case afterRejoin
    case dailyReset

    public var label: String {
        switch self {
        case .everyMinutes(let m): return "every \(m == m.rounded() ? String(Int(m)) : String(m)) min"
        case .biomeStarted(let b): return "when \(b) starts"
        case .biomeEnded(let b): return "when \(b) ends"
        case .afterRejoin: return "after a rejoin"
        case .dailyReset: return "at the daily reset"
        }
    }
}

public enum MacroNotify: String, Codable, Sendable, CaseIterable {
    case none, errors, startEnd
    public var label: String {
        switch self { case .none: return "Nothing"; case .errors: return "Only when it is stopped"; case .startEnd: return "Start and end" }
    }
}

public struct MacroSettings: Equatable, Sendable, Codable {
    /// 0.25 … 10. 1 = real time.
    public var speed: Double = 1
    /// 0 = forever.
    public var loops: Int = 1
    public var loopDelayS: Double = 0
    /// Small random timing and position jitter.
    public var humanize = false
    public var notify: MacroNotify = .errors
    public var pauseDuringRareBiomes = true
    /// Hard rule 3: clicks on the item bar and the menu column use or open things. They are refused unless the
    /// user turns this on for this macro, and then only up to `itemClickHourlyCap` per hour.
    public var allowItemAndMenuClicks = false
    public var itemClickHourlyCap = 30
    public var triggers: [MacroTrigger] = []
    /// Name of a macro to queue when this one finishes.
    public var chainTo: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MacroSettings()
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? d.speed
        loops = try c.decodeIfPresent(Int.self, forKey: .loops) ?? d.loops
        loopDelayS = try c.decodeIfPresent(Double.self, forKey: .loopDelayS) ?? d.loopDelayS
        humanize = try c.decodeIfPresent(Bool.self, forKey: .humanize) ?? d.humanize
        notify = try c.decodeIfPresent(MacroNotify.self, forKey: .notify) ?? d.notify
        pauseDuringRareBiomes = try c.decodeIfPresent(Bool.self, forKey: .pauseDuringRareBiomes) ?? d.pauseDuringRareBiomes
        allowItemAndMenuClicks = try c.decodeIfPresent(Bool.self, forKey: .allowItemAndMenuClicks) ?? d.allowItemAndMenuClicks
        itemClickHourlyCap = try c.decodeIfPresent(Int.self, forKey: .itemClickHourlyCap) ?? d.itemClickHourlyCap
        triggers = try c.decodeIfPresent([MacroTrigger].self, forKey: .triggers) ?? []
        chainTo = try c.decodeIfPresent(String.self, forKey: .chainTo)
    }
}

/// A recorded or hand-built macro. Stored as `<name>.svmacro` (versioned JSON).
public struct Macro: Equatable, Sendable, Codable, Identifiable {
    public static let formatName = "siversol-macro"
    /// 1: positions were ratios of the whole window, title bar included. 2: ratios of the game area.
    public static let currentVersion = 2
    public static let fileExtension = "svmacro"

    public var format = Macro.formatName
    public var version = Macro.currentVersion
    public var name: String
    public var createdAt: Date
    public var note = ""
    /// Size of the game area in points when it was recorded (for information; positions are ratios).
    /// In a version 1 file this was the whole window, title bar included.
    public var windowWidth: Double = 0
    public var windowHeight: Double = 0
    /// Height of the window's title bar in points when it was recorded (0 in full screen; nil in old files).
    public var titleBar: Double?
    public var settings = MacroSettings()
    public var steps: [MacroStep]
    /// True once the user has looked at the steps and chosen to trust an imported macro.
    public var reviewed = true

    public var id: String { name }

    public init(name: String, steps: [MacroStep], createdAt: Date = Date()) {
        self.name = name; self.steps = steps; self.createdAt = createdAt
    }

    /// Length of one pass at 1× (smart waits count their fixed part only).
    public var duration: TimeInterval {
        steps.reduce(0) { total, step in
            if case .wait(let s) = step.action { return total + step.delay + s }
            return total + step.delay
        }
    }
    public var isKeyboardOnly: Bool { !steps.contains { $0.action.isMouse } }
    public var clickCount: Int { steps.filter { $0.action.isClick }.count }
    public var keyCount: Int { steps.filter { if case .keyDown = $0.action { return true }; return false }.count }
}

public enum MacroError: Error, Equatable, CustomStringConvertible {
    case notAMacro
    case newerVersion(Int)
    case invalid(String)

    public var description: String {
        switch self {
        case .notAMacro: return "This is not a SiverSol macro file."
        case .newerVersion(let v): return "This macro was made by a newer SiverSol (format version \(v)). Update SiverSol to use it."
        case .invalid(let why): return "This macro file is not valid: \(why)."
        }
    }
}

public enum MacroCodec {
    public static let maxSteps = 200_000
    public static let maxDurationS: Double = 6 * 3600
    public static let maxFileBytes = 25 * 1024 * 1024

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    public static func encode(_ macro: Macro) throws -> Data { try encoder.encode(macro) }

    /// Decode and validate. Anything outside the rules is rejected, never "fixed up".
    public static func decode(_ data: Data) throws -> Macro {
        guard data.count <= maxFileBytes else { throw MacroError.invalid("the file is larger than 25 MB") }
        struct Header: Decodable { let format: String?; let version: Int? }
        guard let header = try? decoder.decode(Header.self, from: data), header.format == Macro.formatName else { throw MacroError.notAMacro }
        guard let version = header.version, version >= 1 else { throw MacroError.invalid("no format version") }
        guard version <= Macro.currentVersion else { throw MacroError.newerVersion(version) }
        var macro: Macro
        do { macro = try decoder.decode(Macro.self, from: data) }
        catch { throw MacroError.invalid("a step or setting could not be read") }
        try validate(macro)
        if macro.version < 2 {
            // An old recording: move its positions from "ratio of the whole window" to "ratio of the game area".
            let bar = legacyTitleBar(CGSize(width: macro.windowWidth, height: macro.windowHeight))
            macro = MacroMigration.toContentSpace(macro, titleBar: Double(bar))
        }
        return macro
    }

    /// How tall the title bar was on the window an old (version 1) macro was recorded in. Old files do not say,
    /// so: none if the window was as large as one of this Mac's screens (it was in full screen), otherwise the
    /// height of a standard title bar.
    nonisolated(unsafe) public static var legacyTitleBar: @Sendable (CGSize) -> CGFloat = { recorded in
        MacroMigration.legacyTitleBar(recorded: recorded, screens: SystemScreens.shapes(), systemTitleBar: RobloxChrome.systemTitleBar)
    }

    public static func validate(_ m: Macro) throws {
        let name = m.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 80 else { throw MacroError.invalid("the name must be 1 to 80 characters") }
        guard !name.contains("/"), !name.contains(":"), !name.hasPrefix(".") else { throw MacroError.invalid("the name cannot contain / or : or start with a dot") }
        guard m.steps.count <= maxSteps else { throw MacroError.invalid("more than \(maxSteps) steps") }
        guard (0.25...10).contains(m.settings.speed) else { throw MacroError.invalid("speed must be between 0.25× and 10×") }
        guard (0...1_000_000).contains(m.settings.loops), (0...86_400).contains(m.settings.loopDelayS) else { throw MacroError.invalid("loop settings out of range") }
        guard (0...100_000).contains(m.settings.itemClickHourlyCap) else { throw MacroError.invalid("item click cap out of range") }
        var total = 0.0
        func ratio(_ v: Double) -> Bool { v.isFinite && v >= 0 && v <= 1 }
        for (i, step) in m.steps.enumerated() {
            guard step.delay.isFinite, step.delay >= 0, step.delay <= 3600 else { throw MacroError.invalid("step \(i + 1) has a delay outside 0 to 3600 s") }
            total += step.delay
            switch step.action {
            case .keyDown(let code), .keyUp(let code):
                guard code <= 127 else { throw MacroError.invalid("step \(i + 1) has an unknown key") }
            case .mouseMove(let x, let y), .mouseDown(_, let x, let y), .mouseUp(_, let x, let y):
                guard ratio(x), ratio(y) else { throw MacroError.invalid("step \(i + 1) points outside the Roblox window") }
            case .mouseDelta(let dx, let dy), .scroll(let dx, let dy):
                guard dx.isFinite, dy.isFinite, abs(dx) <= 5000, abs(dy) <= 5000 else { throw MacroError.invalid("step \(i + 1) has an impossible mouse movement") }
            case .wait(let s):
                guard s.isFinite, s >= 0, s <= 3600 else { throw MacroError.invalid("step \(i + 1) waits longer than an hour") }
                total += s
            case .waitText(let text, let timeout):
                guard !text.isEmpty, text.count <= 60, timeout.isFinite, timeout > 0, timeout <= 3600 else { throw MacroError.invalid("step \(i + 1) has a bad text wait") }
            case .waitBiome(let biome, let timeout):
                guard !biome.isEmpty, biome.count <= 40, timeout.isFinite, timeout > 0, timeout <= 86_400 else { throw MacroError.invalid("step \(i + 1) has a bad biome wait") }
            case .waitInGame(let timeout):
                guard timeout.isFinite, timeout > 0, timeout <= 3600 else { throw MacroError.invalid("step \(i + 1) has a bad wait") }
            }
        }
        guard total <= maxDurationS else { throw MacroError.invalid("one pass is longer than 6 hours") }
        for trigger in m.settings.triggers {
            if case .everyMinutes(let minutes) = trigger, !(minutes.isFinite && minutes >= 1 && minutes <= 1440) {
                throw MacroError.invalid("a schedule must be between 1 minute and 24 hours")
            }
        }
    }
}

/// Old recordings (format version 1) measured positions against the whole Roblox window, title bar included.
public enum MacroMigration {
    public static func legacyTitleBar(recorded: CGSize, screens: [ScreenShape], systemTitleBar: CGFloat) -> CGFloat {
        guard recorded.width > 0, recorded.height > 0 else { return 0 }
        for s in screens {
            let sizes = [s.frame.size, s.belowNotch.size]
            if sizes.contains(where: { abs($0.width - recorded.width) <= 2 && abs($0.height - recorded.height) <= 2 }) { return 0 }
        }
        return systemTitleBar
    }

    /// The same macro with every position as a ratio of the game area. A point that was on the title bar
    /// itself lands on the top edge of the game. A macro without a recorded window size is left as it is.
    public static func toContentSpace(_ macro: Macro, titleBar: Double) -> Macro {
        var out = macro
        out.version = Macro.currentVersion
        let height = macro.windowHeight
        guard titleBar > 0, height > titleBar + 1 else {
            out.titleBar = macro.windowHeight > 0 ? 0 : nil
            return out
        }
        func y(_ v: Double) -> Double { min(1, max(0, GameChrome.contentY(fromWindow: v, windowHeight: height, titleBar: titleBar))) }
        out.steps = macro.steps.map { step in
            var s = step
            switch step.action {
            case .mouseMove(let x, let v): s.action = .mouseMove(x: x, y: y(v))
            case .mouseDown(let b, let x, let v): s.action = .mouseDown(button: b, x: x, y: y(v))
            case .mouseUp(let b, let x, let v): s.action = .mouseUp(button: b, x: x, y: y(v))
            default: break
            }
            return s
        }
        out.windowHeight = height - titleBar
        out.titleBar = titleBar
        return out
    }
}

/// Human-readable key names for the editor (US layout; the macro itself stores key codes).
public enum KeyNames {
    static let table: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Escape",
        54: "Right ⌘", 55: "⌘", 56: "Shift", 57: "Caps Lock", 58: "⌥", 59: "Control", 60: "Right Shift", 61: "Right ⌥", 62: "Right Control", 63: "Fn",
        123: "←", 124: "→", 125: "↓", 126: "↑", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
    ]
    public static func name(_ code: UInt16) -> String { table[code] ?? "key \(code)" }
    public static let modifiers: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    public static let slash: UInt16 = 44, returnKey: UInt16 = 36, escape: UInt16 = 53
}

extension MacroStep {
    /// One line for the editor.
    public var summary: String {
        switch action {
        case .keyDown(let c): return "Press \(KeyNames.name(c))"
        case .keyUp(let c): return "Release \(KeyNames.name(c))"
        case .mouseMove(let x, let y): return String(format: "Move to %.0f%%, %.0f%%", x * 100, y * 100)
        case .mouseDown(let b, let x, let y): return String(format: "%@ button down at %.0f%%, %.0f%%", b.rawValue.capitalized, x * 100, y * 100)
        case .mouseUp(let b, _, _): return "\(b.rawValue.capitalized) button up"
        case .mouseDelta(let dx, let dy): return String(format: "Turn camera by %.0f, %.0f", dx, dy)
        case .scroll(_, let dy): return String(format: "Scroll %.0f", dy)
        case .wait(let s): return String(format: "Wait %.1f s", s)
        case .waitText(let t, let timeout): return "Wait for “\(t)” on screen (up to \(Int(timeout)) s)"
        case .waitBiome(let b, let timeout): return "Wait for biome \(b) (up to \(Int(timeout)) s)"
        case .waitInGame(let timeout): return "Wait until in the game (up to \(Int(timeout)) s)"
        }
    }
}
