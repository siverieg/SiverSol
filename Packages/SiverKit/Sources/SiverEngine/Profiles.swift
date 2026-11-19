import Foundation
import SiverCore
import SiverMacro
import SiverNotify

/// Which macros may play.
public enum MacroPolicy: String, Codable, CaseIterable, Sendable {
    /// Any reviewed macro.
    case all
    /// Only macros that cannot leave the server: no Escape key and no clicks.
    case stayInServer
    /// None.
    case none

    public var label: String {
        switch self {
        case .all: return "All macros"
        case .stayInServer: return "Only macros that cannot leave the server"
        case .none: return "No macros"
        }
    }
}

extension MacroRules {
    static let escapeKey: UInt16 = 53

    /// Why a macro could take the player out of the server, or nil when it cannot.
    /// Escape opens Roblox's menu (Leave is one key away), and a click can land on any button.
    public static func couldLeaveServer(_ macro: Macro) -> String? {
        for step in macro.steps {
            switch step.action {
            case .keyDown(let code) where code == escapeKey: return "it presses Escape, which opens Roblox's menu"
            case .mouseDown: return "it clicks, and a click can land on a button"
            default: continue
            }
        }
        return nil
    }

    /// May this macro start under a policy? nil = yes, otherwise the sentence to show.
    public static func refusal(_ macro: Macro, policy: MacroPolicy) -> String? {
        switch policy {
        case .all: return nil
        case .none: return "Macros are turned off in the current profile."
        case .stayInServer:
            return couldLeaveServer(macro).map { "“\(macro.name)” is not played in this profile because \($0)." }
        }
    }
}

/// What a profile sets. A field left out keeps whatever the user has.
public struct ProfileSettings: Codable, Equatable, Sendable {
    /// Rare biomes ping on Rich routes.
    public var pingRares: Bool?
    /// Rich routes also get NORMAL.
    public var normalMessages: Bool?
    /// Rich routes gather ordinary biomes into the hourly Biome feed.
    public var digest: Bool?
    /// Hunt-Compat routes are on.
    public var huntRoutes: Bool?
    /// Hunt-Compat routes include NORMAL (hunt bots read it as "this macro is active").
    public var huntIncludeNormal: Bool?
    public var quietHours: Bool?
    public var quietStart: Int?
    public var quietEnd: Int?
    public var antiAFK: Bool?
    public var rejoin: Bool?
    public var moments: Bool?
    public var momentsOnRolls: Bool?
    public var momentsOnRareBiomes: Bool?
    public var island: IslandMode?
    public var macros: MacroPolicy?
    public var soundCue: Bool?

    public init() {}
}

/// The switches a profile reaches that are not in the config file.
public struct ProfileToggles: Equatable, Sendable {
    public var antiAFK: Bool
    public var rejoin: Bool
    public var island: IslandMode
    public init(antiAFK: Bool, rejoin: Bool, island: IslandMode) { self.antiAFK = antiAFK; self.rejoin = rejoin; self.island = island }
}

/// A named preset: routes, pings, quiet hours, macros, anti-AFK, Moments and the Biome Island, switched together.
public struct Profile: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var symbol: String
    public var summary: String
    public var settings: ProfileSettings
    public var id: String { name }

    public init(name: String, symbol: String, summary: String, settings: ProfileSettings) {
        self.name = name; self.symbol = symbol; self.summary = summary; self.settings = settings
    }
}

public enum Profiles {
    /// Glitch Hunt Mode: built for sharing a server with a hunt group.
    public static let glitchHunt: Profile = {
        var s = ProfileSettings()
        s.huntRoutes = true; s.huntIncludeNormal = true; s.pingRares = true
        s.quietHours = false
        s.antiAFK = true; s.rejoin = true
        s.moments = true; s.momentsOnRareBiomes = true; s.momentsOnRolls = false
        s.island = .always
        s.macros = .stayInServer
        return Profile(name: "Glitch Hunt", symbol: "scope",
                       summary: "Hunt routes on with NORMAL included, pings for rare biomes, the most careful rejoin, clips of rare biomes, and no macro that could leave the server.",
                       settings: s)
    }()

    public static let afkGrind: Profile = {
        var s = ProfileSettings()
        s.antiAFK = true; s.rejoin = true
        s.pingRares = false; s.normalMessages = false; s.digest = true
        s.moments = true; s.momentsOnRolls = true; s.momentsOnRareBiomes = true
        s.island = .always
        s.macros = .all
        return Profile(name: "AFK Grind", symbol: "figure.walk",
                       summary: "Stay in the game for hours: anti-AFK and rejoin on, a quiet channel (an hourly biome feed, no pings), clips of rolls and rare biomes, all your macros.",
                       settings: s)
    }()

    public static let quietNight: Profile = {
        var s = ProfileSettings()
        s.antiAFK = true; s.rejoin = true
        s.quietHours = true; s.quietStart = 22; s.quietEnd = 8
        s.pingRares = true; s.digest = true
        s.island = .off; s.soundCue = false
        s.moments = false
        return Profile(name: "Quiet Night", symbol: "moon.zzz.fill",
                       summary: "For sleeping next to the Mac: no island, no sound, no pings from 22:00 to 08:00 except the biomes you would get up for, and an hourly biome feed.",
                       settings: s)
    }()

    public static let builtIn = [glitchHunt, afkGrind, quietNight]

    public static func isBuiltIn(_ name: String) -> Bool { builtIn.contains { $0.name == name } }

    /// Every profile: the built-in ones, then the user's own (one of the user's with a built-in's name is ignored).
    public static func all(custom: [Profile]) -> [Profile] { builtIn + custom.filter { !isBuiltIn($0.name) } }

    /// Put a profile's settings on top of the current ones, and note its name (it shows in the footer of every card).
    public static func apply(_ profile: Profile, to config: inout NotifyConfig, extras: inout ExtrasConfig, toggles: inout ProfileToggles) {
        let s = profile.settings
        for i in config.routes.indices {
            if config.routes[i].profile == .rich {
                if let v = s.pingRares { config.routes[i].pingsEnabled = v }
                if let v = s.normalMessages { config.routes[i].includeNormal = v }
                if let v = s.digest { config.routes[i].digest = v }
            } else {
                if let v = s.huntRoutes { config.routes[i].enabled = v }
                if let v = s.huntIncludeNormal { config.routes[i].includeNormal = v }
                // A hunt route is never digested and its pings stay whatever the user set for that server.
            }
        }
        if let v = s.quietHours { config.quietHours.enabled = v }
        if let v = s.quietStart { config.quietHours.startHour = v }
        if let v = s.quietEnd { config.quietHours.endHour = v }
        if let v = s.moments { extras.moments = v }
        if let v = s.momentsOnRolls { extras.momentsOnRolls = v }
        if let v = s.momentsOnRareBiomes { extras.momentsOnRareBiomes = v }
        if let v = s.macros { extras.macroPolicy = v }
        if let v = s.soundCue { extras.soundCue = v }
        if profile.name == glitchHunt.name {
            // "Most reliable rejoin": every watchdog that helps get back into the server.
            extras.freezeWatchdog = true; extras.menuSentinel = true; extras.networkSentinel = true
        }
        if let v = s.antiAFK { toggles.antiAFK = v }
        if let v = s.rejoin { toggles.rejoin = v }
        if let v = s.island { toggles.island = v }
        config.profileName = profile.name
    }

    /// A profile that holds the current settings exactly, for "Save as profile".
    public static func capture(name: String, config: NotifyConfig, extras: ExtrasConfig, toggles: ProfileToggles) -> Profile {
        var s = ProfileSettings()
        let rich = config.routes.filter { $0.profile == .rich }, hunt = config.routes.filter { $0.profile == .huntCompat }
        if let r = rich.first { s.pingRares = r.pingsEnabled; s.normalMessages = r.includeNormal; s.digest = r.digest }
        if let h = hunt.first { s.huntRoutes = h.enabled; s.huntIncludeNormal = h.includeNormal }
        s.quietHours = config.quietHours.enabled; s.quietStart = config.quietHours.startHour; s.quietEnd = config.quietHours.endHour
        s.antiAFK = toggles.antiAFK; s.rejoin = toggles.rejoin; s.island = toggles.island
        s.moments = extras.moments; s.momentsOnRolls = extras.momentsOnRolls; s.momentsOnRareBiomes = extras.momentsOnRareBiomes
        s.macros = extras.macroPolicy; s.soundCue = extras.soundCue
        return Profile(name: name, symbol: "slider.horizontal.3", summary: "Your own settings, saved \(Self.day(Date())).", settings: s)
    }

    private static func day(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "d MMM yyyy"
        return f.string(from: date)
    }
}

/// Hunt coverage: how long the sky was actually being watched, today and over the last seven days (UTC days).
public struct HuntCoverage: Equatable, Sendable {
    public var todaySeconds: Double
    public var weekSeconds: Double

    public init(todaySeconds: Double, weekSeconds: Double) { self.todaySeconds = todaySeconds; self.weekSeconds = weekSeconds }

    /// "6h 12m today · 31h 5m this week"
    public var line: String { "\(Self.hours(todaySeconds)) today · \(Self.hours(weekSeconds)) this week" }

    static func hours(_ t: Double) -> String {
        let m = Int((t / 60).rounded())
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    /// Watched time comes from the timeline: the stretches in which a biome was known. `open` is true while
    /// SiverSol is watching, so the biome that is on now counts up to this moment.
    public static func compute(timeline: TimelineStore, now: Date = Date(), open: Bool = true, isRare: (BiomeKey) -> Bool) -> HuntCoverage {
        var events: [SiverEvent] = []
        for back in (0...7).reversed() { events += timeline.events(day: TimelineStore.day(now.addingTimeInterval(-Double(back) * 86_400))) }
        let ribbon = SkyRibbon.build(events: events, end: now, hours: 24 * 7, open: open, isRare: isRare)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let midnight = cal.startOfDay(for: now)
        var today = 0.0, week = 0.0
        for s in ribbon.segments {
            week += s.seconds
            if s.end > midnight { today += s.end.timeIntervalSince(max(s.start, midnight)) }
        }
        return HuntCoverage(todaySeconds: today, weekSeconds: week)
    }
}
