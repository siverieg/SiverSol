import Foundation

/// The pages of the app. ⌘1 to ⌘9 open the first nine, ⌘0 the tenth; Tips, added later, has no shortcut.
/// (The raw values are also what `siversol://<page>` links use, so they do not change.)
public enum AppPage: String, CaseIterable, Identifiable, Sendable {
    case dashboard, timeline, auras, moments, notifications, automation, macros, logLab, settings, about, tips
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .timeline: return "Timeline"
        case .auras: return "Sol Dex"
        case .moments: return "Moments"
        case .notifications: return "Notifications"
        case .automation: return "Automation"
        case .macros: return "Macros"
        case .logLab: return "Log Lab"
        case .settings: return "Settings"
        case .about: return "About"
        case .tips: return "Tips"
        }
    }

    /// SF Symbol names, first choice first (a newer symbol falls back to one every supported macOS has).
    public var symbols: [String] {
        switch self {
        case .dashboard: return ["sun.horizon"]
        case .timeline: return ["clock.arrow.circlepath"]
        case .auras: return ["rectangle.stack"]
        case .moments: return ["film.stack"]
        case .notifications: return ["bell.badge"]
        case .automation: return ["wand.and.sparkles", "wand.and.stars"]
        case .macros: return ["pianokeys"]
        case .logLab: return ["text.magnifyingglass"]
        case .settings: return ["gearshape"]
        case .about: return ["info.circle"]
        case .tips: return ["lightbulb"]
        }
    }

    /// The digit of this page's ⌘ shortcut: 1 to 9, then 0. nil for a page without one.
    public var shortcutDigit: Int? {
        guard let i = AppPage.allCases.firstIndex(of: self), i < 10 else { return nil }
        return (i + 1) % 10
    }
    public var shortcutLabel: String { shortcutDigit.map { "⌘\($0)" } ?? "" }
}

/// The sidebar's small, quiet groups.
public enum SidebarSection: String, CaseIterable, Identifiable, Sendable {
    case sky = "Sky", collection = "Collection", control = "Control", tools = "Tools"
    public var id: String { rawValue }

    public var pages: [AppPage] {
        switch self {
        case .sky: return [.dashboard, .timeline]
        case .collection: return [.auras, .moments]
        case .control: return [.notifications, .automation, .macros]
        case .tools: return [.logLab, .settings, .tips, .about]
        }
    }

    public static func of(_ page: AppPage) -> SidebarSection { allCases.first { $0.pages.contains(page) } ?? .tools }
}

/// How the notifier is doing, for the dot beside Notifications.
public enum NotifyHealth: String, Sendable {
    case healthy, retrying, failing, notSetUp

    public static func of(hasWebhook: Bool, deadRoutes: Int, waiting: Int) -> NotifyHealth {
        if !hasWebhook { return .notSetUp }
        if deadRoutes > 0 { return .failing }
        return waiting > 0 ? .retrying : .healthy
    }

    public var spoken: String {
        switch self {
        case .healthy: return "delivering"
        case .retrying: return "messages waiting to send"
        case .failing: return "a webhook is failing"
        case .notSetUp: return "no webhook set"
        }
    }
}

/// The small thing at the right of a sidebar row. Text is short and fixed-width, so a row never shifts.
public enum SidebarAccessory: Equatable, Sendable {
    case none
    case text(String, spoken: String)
    /// A countdown to a moment, with a dot (the Dashboard row during a rare biome).
    case countdown(until: Date, spoken: String)
    case dot(spoken: String)
    case health(NotifyHealth)
    /// Progress of the macro that is playing, 0 to 1.
    case playhead(Double, spoken: String)

    /// What VoiceOver adds after the row's title; empty when there is nothing to say.
    public var spoken: String {
        switch self {
        case .none: return ""
        case .text(_, let s), .countdown(_, let s), .dot(let s), .playhead(_, let s): return s
        case .health(let h): return h.spoken
        }
    }
}

public enum SidebarFormat {
    /// "48/212", read as "48 of 212 found".
    public static func dex(found: Int, total: Int) -> SidebarAccessory {
        total > 0 ? .text("\(found)/\(total)", spoken: "\(found) of \(total) found") : .none
    }

    /// Events today: "128", "1.2k" from a thousand up. Nothing for none.
    public static func eventsToday(_ n: Int) -> SidebarAccessory {
        guard n > 0 else { return .none }
        let text = n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
        return .text(text, spoken: "\(n) event\(n == 1 ? "" : "s") today")
    }

    /// The next scheduled run as a clock time ("17:30"), in the given calendar's zone.
    public static func nextRun(_ date: Date?, now: Date, calendar: Calendar = .current) -> SidebarAccessory {
        guard let date, date > now else { return .none }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let text = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        return .text(text, spoken: "next run at \(text)")
    }

    /// A countdown as "1:12", or "1:02:03" from an hour up.
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    public static func playhead(step: Int, of total: Int, name: String) -> SidebarAccessory {
        guard total > 0 else { return .none }
        return .playhead(min(1, max(0, Double(step) / Double(total))), spoken: "playing \(name)")
    }
}

/// What the status card at the foot of the sidebar looks like. It mirrors the Biome Island.
public enum StatusCardState: String, Sendable {
    /// Watching, an ordinary biome (or none yet).
    case resting
    /// Watching, a rare biome is on: a gentle breathing glow.
    case rare
    /// Not watching, or input paused: desaturated.
    case paused
    /// Watching, but Roblox is not running: an outline only.
    case noRoblox

    public static func of(watching: Bool, inputPaused: Bool, robloxRunning: Bool, rareBiome: Bool) -> StatusCardState {
        guard watching else { return .paused }
        if !robloxRunning { return .noRoblox }
        if inputPaused { return .paused }
        return rareBiome ? .rare : .resting
    }
}

public enum SidebarStatus {
    /// The line under the wordmark: "Watching · Pumpkin Moon", "Paused", "Waiting for Roblox".
    public static func line(watching: Bool, starting: Bool = false, needsAttention: Bool = false, inputPaused: Bool, robloxRunning: Bool, biome: String?) -> String {
        if needsAttention { return "Needs a look" }
        guard watching else { return "Paused" }
        if starting { return "Starting…" }
        if !robloxRunning { return "Waiting for Roblox" }
        if inputPaused { return "Input paused" + (biome.map { " · \($0)" } ?? "") }
        return biome.map { "Watching · \($0)" } ?? "Watching the horizon"
    }
}

extension SkyModel {
    /// A biome's accent, moved just far enough towards dark (light mode) or light (dark mode) to be seen clearly
    /// as an icon or a selection on the sidebar over that same sky. The hue stays the biome's own.
    public static func legibleAccent(_ look: SkyLook, dark: Bool) -> RGB {
        let surface = sidebarSurface(over: look.top.mix(look.bottom, 0.4), dark: dark)
        var c = look.accent
        var steps = 0
        while c.contrast(surface) < 3.0, steps < 40 {
            c = c.mix(dark ? .white : RGB(hex: 0x0B1026), 0.06)
            steps += 1
        }
        return c
    }

    /// Roughly what the sidebar's glass looks like over a patch of sky.
    public static func sidebarSurface(over sky: RGB, dark: Bool) -> RGB {
        sky.mix(dark ? RGB(hex: 0x1A1C22) : RGB(hex: 0xF2F4F8), dark ? 0.62 : 0.60)
    }
}

extension SkyModel {
    /// The colours of a filled (primary) button for a sky: the biome's accent, moved until it stands out from
    /// the card it sits on, and black or white text, whichever reads better on it (always at least 4.5:1).
    public static func buttonFill(_ look: SkyLook, dark: Bool) -> (fill: RGB, text: RGB) {
        let card = cardBase(dark: dark).color
        var fill = look.accent
        var steps = 0
        // Away from the card: darker on a light card, lighter on a dark one.
        while fill.contrast(card) < 2.2, steps < 40 {
            fill = fill.mix(dark ? .white : RGB(hex: 0x0B1026), 0.05)
            steps += 1
        }
        let black = RGB(hex: 0x0B0D12), white = RGB(hex: 0xFFFFFF)
        let text = fill.contrast(black) >= fill.contrast(white) ? black : white
        return (fill, text)
    }
}
