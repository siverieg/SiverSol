import Foundation

// Rare sky surprises ("luck eggs"): cosmetic things the sky does by chance while someone is looking.
//
// Hard boundary: this file knows nothing about Discord. It must never import or call SiverNotify, and nothing
// in SiverNotify reads it. A surprise never sends, edits, delays or changes a message, and a surprise that was
// found is never part of a Discord payload or picture. `EggIsolationTests` checks both directions.
//
// They are for fun only: nothing here reads, predicts or changes anything in the game.

/// One surprise.
public enum SkyEgg: String, CaseIterable, Codable, Sendable, Identifiable {
    case shootingStar, doubleRainbow, auroraNight, glimmer, retroFrame, goldenSun, islandComet, twinMoons
    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .shootingStar: return "Shooting star"
        case .doubleRainbow: return "Double rainbow"
        case .auroraNight: return "Aurora night"
        case .glimmer: return "Glimmer visits"
        case .retroFrame: return "Retro frame"
        case .goldenSun: return "Golden sun"
        case .islandComet: return "Island comet"
        case .twinMoons: return "Twin moons"
        }
    }

    /// One chance in this many, each time its moment comes.
    public var oneIn: Int {
        switch self {
        case .shootingStar: return 90
        case .doubleRainbow: return 8
        case .auroraNight: return 300
        case .glimmer: return 250
        case .retroFrame: return 600
        case .goldenSun: return 600
        case .islandComet: return 50
        case .twinMoons: return 3_000
        }
    }

    /// The moment it is rolled at.
    public var moment: EggMoment {
        switch self {
        case .shootingStar: return .presentMinute
        case .doubleRainbow: return .rainyEnded
        case .auroraNight, .twinMoons: return .nightMinute
        case .glimmer, .retroFrame: return .biomeChange
        case .goldenSun: return .eveningMinute
        case .islandComet: return .islandExpanded
        }
    }

    /// The odds as the Secrets list shows them once it is found.
    public var odds: String {
        let n = NumberFormatter.localizedString(from: NSNumber(value: oneIn), number: .decimal)
        switch moment {
        case .presentMinute: return "1 in \(n) per minute at the Mac"
        case .rainyEnded: return "1 in \(n) per Rainy ending seen"
        case .nightMinute: return "1 in \(n) per minute at the Mac, 10 PM to 5 AM"
        case .biomeChange: return "1 in \(n) per biome change seen"
        case .eveningMinute: return "1 in \(n) per minute at the Mac in the evening"
        case .islandExpanded: return "1 in \(n) each time the island opens"
        }
    }

    public var symbol: String {
        switch self {
        case .shootingStar: return "sparkle"
        case .doubleRainbow: return "rainbow"
        case .auroraNight: return "wind"
        case .glimmer: return "moon.stars"
        case .retroFrame: return "square.grid.3x3.square"
        case .goldenSun: return "sun.max"
        case .islandComet: return "capsule.tophalf.filled"
        case .twinMoons: return "moon.circle"
        }
    }

    /// How long it plays, in seconds. Nil: until something ends it (the biome, the hour).
    public var seconds: TimeInterval? {
        switch self {
        case .shootingStar: return 1.8
        case .doubleRainbow: return 20
        case .auroraNight: return 60
        case .glimmer: return 14
        case .retroFrame: return 15
        case .islandComet: return 1.6
        case .goldenSun, .twinMoons: return nil
        }
    }

    /// Shown on the island, not in the window.
    public var onIsland: Bool { self == .islandComet }
}

/// When a surprise is rolled. Every one of these only happens while someone is present (`EggPresence`).
public enum EggMoment: String, Sendable {
    /// A minute with someone present has added up.
    case presentMinute
    /// The same, when that minute was at night (10 PM to 5 AM, local).
    case nightMinute
    /// The same, when that minute was in the evening (5 PM to 9 PM, local).
    case eveningMinute
    /// A Rainy biome ended while someone was present.
    case rainyEnded
    /// The biome changed while someone was present.
    case biomeChange
    /// The island opened to announce something while someone was present.
    case islandExpanded
}

/// Is someone there to see it? A SiverSol window or the island is on screen, the display is awake, and the
/// Mac was used in the last ten minutes. "Used" is the system's own idle time (how long since the keyboard,
/// mouse or trackpad was last touched), which any app may read; it needs no permission and nothing is recorded.
public enum EggPresence {
    public static let idleLimit: TimeInterval = 600

    public static func isPresent(windowVisible: Bool, islandVisible: Bool, displayAsleep: Bool, idleSeconds: TimeInterval) -> Bool {
        (windowVisible || islandVisible) && !displayAsleep && idleSeconds >= 0 && idleSeconds < idleLimit
    }
}

/// What is true at the moment of a roll.
public struct EggConditions: Equatable, Sendable {
    /// "Rare sky surprises" in Settings.
    public var enabled: Bool
    /// A SiverSol window is where it can be seen.
    public var windowVisible: Bool
    /// The island is on screen.
    public var islandVisible: Bool
    public var rareBiome: Bool
    /// A macro is recording or playing.
    public var macroBusy: Bool
    /// The display is awake and the Mac was used in the last ten minutes.
    public var awakeAndUsed: Bool

    public init(enabled: Bool = true, windowVisible: Bool, islandVisible: Bool = false, rareBiome: Bool = false, macroBusy: Bool = false, awakeAndUsed: Bool = true) {
        self.enabled = enabled; self.windowVisible = windowVisible; self.islandVisible = islandVisible
        self.rareBiome = rareBiome; self.macroBusy = macroBusy; self.awakeAndUsed = awakeAndUsed
    }

    /// Someone is present: something of SiverSol's is on screen, the display is awake, the Mac is in use.
    public var present: Bool { (windowVisible || islandVisible) && awakeAndUsed }

    /// May this surprise be rolled now? Only while someone is present and where its result could be seen (the
    /// window for the sky's surprises, the island for the island's), never during a rare biome and never while
    /// a macro is busy. A roll that may not happen is skipped, not kept for later.
    public func allows(_ egg: SkyEgg) -> Bool {
        guard enabled, present, !rareBiome, !macroBusy else { return false }
        return egg.onIsland ? islandVisible : windowVisible
    }
}

/// A small, fast generator that gives the same numbers for the same seed (SplitMix64), for tests.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Rolls the dice. The generator is the app's own local one, or a seeded one in tests.
public struct EggRoller<G: RandomNumberGenerator> {
    public var generator: G
    public init(generator: G) { self.generator = generator }

    /// One roll: true once in `oneIn` times.
    public mutating func hit(oneIn: Int) -> Bool {
        guard oneIn > 0 else { return false }
        return Int.random(in: 0..<oneIn, using: &generator) == 0
    }

    /// The surprises that come up at this moment (usually none). `skipping`: surprises that are already playing
    /// are not rolled again while they play.
    public mutating func roll(_ moment: EggMoment, conditions: EggConditions, skipping: Set<SkyEgg> = []) -> [SkyEgg] {
        var out: [SkyEgg] = []
        for egg in SkyEgg.allCases where egg.moment == moment && !skipping.contains(egg) {
            // A roll that is not allowed is not made at all: no number is drawn for it.
            guard conditions.allows(egg) else { continue }
            if hit(oneIn: egg.oneIn) { out.append(egg) }
        }
        return out
    }
}

/// Counts the minutes someone was present, and says what each one was (any minute, a night minute, an evening
/// minute). Time without anyone present does not count: there are no hidden rolls.
public struct EggClock: Equatable, Sendable {
    public private(set) var presentSeconds: TimeInterval = 0

    public init() {}

    public static func isNight(hour: Int) -> Bool { hour >= 22 || hour < 5 }
    public static func isEvening(hour: Int) -> Bool { hour >= 17 && hour < 21 }

    /// `seconds` more went by. Returns the moments for every whole present minute that has now added up.
    public mutating func advance(by seconds: TimeInterval, present: Bool, hour: Int) -> [EggMoment] {
        guard present, seconds > 0 else { return [] }
        let before = Int(presentSeconds / 60)
        presentSeconds += seconds
        let minutes = Int(presentSeconds / 60) - before
        var moments: [EggMoment] = []
        for _ in 0..<max(0, minutes) {
            moments.append(.presentMinute)
            if Self.isNight(hour: hour) { moments.append(.nightMinute) }
            if Self.isEvening(hour: hour) { moments.append(.eveningMinute) }
        }
        return moments
    }
}

/// Which surprises were found, and when. Kept in the app's own preferences on this Mac; never sent anywhere.
public struct EggStore {
    public static let key = "skyEggsFound"
    public static let enabledKey = "skyEggsEnabled"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// On unless the user turned it off.
    public var enabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) == nil ? true : defaults.bool(forKey: Self.enabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    public var found: [SkyEgg: Date] {
        guard let raw = defaults.dictionary(forKey: Self.key) else { return [:] }
        var out: [SkyEgg: Date] = [:]
        for (k, v) in raw { if let egg = SkyEgg(rawValue: k), let t = v as? Double { out[egg] = Date(timeIntervalSince1970: t) } }
        return out
    }

    /// Remember a surprise the first time it is seen. Returns true when it was new.
    @discardableResult public func record(_ egg: SkyEgg, at date: Date = Date()) -> Bool {
        var raw = defaults.dictionary(forKey: Self.key) ?? [:]
        guard raw[egg.rawValue] == nil else { return false }
        raw[egg.rawValue] = date.timeIntervalSince1970
        defaults.set(raw, forKey: Self.key)
        return true
    }

    public var foundCount: Int { found.count }
    /// "Egg Hunter": all eight found.
    public var hunter: Bool { found.count == SkyEgg.allCases.count }
    /// When the last of the eight was found.
    public var hunterSince: Date? { hunter ? found.values.max() : nil }

    public func reset() { defaults.removeObject(forKey: Self.key) }
}

/// One line of the Secrets list.
public struct EggRow: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var odds: String
    public var symbol: String
    public var foundAt: Date?

    /// A found surprise shows its name, its odds and the day; one not found yet gives nothing away.
    public static func rows(found: [SkyEgg: Date]) -> [EggRow] {
        SkyEgg.allCases.map { egg in
            if let at = found[egg] { return EggRow(id: egg.rawValue, name: egg.name, odds: egg.odds, symbol: egg.symbol, foundAt: at) }
            return EggRow(id: egg.rawValue, name: "???", odds: "1 in ?", symbol: "questionmark", foundAt: nil)
        }
    }

    public static func summary(found: Int) -> String { "Found \(found) of \(SkyEgg.allCases.count)" }
    public static let disclaimer = "Just for fun · doesn't change your in-game luck"
    public static let cardLabel = "Sky surprise · not a real aura"
}

/// Things that happen on a date, not by luck. In-app display only.
public enum SeasonalEgg: String, CaseIterable, Sendable {
    case halloweenBats, newYearFireworks, aprilFirst

    public var name: String {
        switch self {
        case .halloweenBats: return "Halloween week: bats over night skies"
        case .newYearFireworks: return "New Year: fireworks at midnight"
        case .aprilFirst: return "April 1: a slightly unsure sidebar"
        }
    }

    /// What is on at this moment (local time).
    public static func active(at date: Date, calendar: Calendar = .current) -> Set<SeasonalEgg> {
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        guard let month = c.month, let day = c.day, let hour = c.hour, let minute = c.minute else { return [] }
        var out: Set<SeasonalEgg> = []
        if month == 10, day >= 25 { out.insert(.halloweenBats) }
        // From the stroke of midnight, for five minutes.
        if month == 1, day == 1, hour == 0, minute < 5 { out.insert(.newYearFireworks) }
        if month == 4, day == 1 { out.insert(.aprilFirst) }
        return out
    }

    /// April 1: "Watching · Normal (probably)". Only the sidebar's own subtitle; nothing else ever says it.
    public static func sidebarLine(_ line: String, on date: Date, calendar: Calendar = .current) -> String {
        guard active(at: date, calendar: calendar).contains(.aprilFirst), line.hasPrefix("Watching · ") else { return line }
        return line + " (probably)"
    }
}

/// What the sky is showing of the surprises right now, as plain numbers for the renderer.
public struct EggSky: Equatable, Sendable {
    /// 0...1 along its path while the shooting star flies; nil otherwise.
    public var star: Double?
    public var rainbow = 0.0
    public var aurora = 0.0
    public var retro = 0.0
    public var gold = 0.0
    public var twinMoon = 0.0
    public var bats = 0.0
    /// Seconds since the fireworks began; nil when there are none.
    public var fireworks: Double?

    public init() {}
    public static let none = EggSky()
    public var isNone: Bool { self == .none }
}

/// The surprises that are playing, with when each began and ends.
public struct EggBoard: Equatable, Sendable {
    public struct Showing: Equatable, Sendable {
        public var began: Date
        /// Nil: until `stop` is called (the biome changes, the hour ends).
        public var ends: Date?
    }

    public private(set) var showing: [SkyEgg: Showing] = [:]
    public var bats = false
    public var fireworksBegan: Date?

    public init() {}

    public mutating func start(_ egg: SkyEgg, at now: Date, until: Date? = nil) {
        showing[egg] = Showing(began: now, ends: until ?? egg.seconds.map { now.addingTimeInterval($0) })
    }

    public mutating func stop(_ egg: SkyEgg) { showing[egg] = nil }

    /// Drop what has finished. Returns true when something changed.
    @discardableResult public mutating func tidy(now: Date) -> Bool {
        let before = showing.count
        showing = showing.filter { $0.value.ends.map { $0 > now } ?? true }
        return showing.count != before
    }

    public func isShowing(_ egg: SkyEgg, at now: Date) -> Bool {
        guard let s = showing[egg] else { return false }
        return s.ends.map { $0 > now } ?? true
    }

    public var isIdle: Bool { showing.isEmpty && !bats && fireworksBegan == nil }

    /// A surprise fades in and out over a second; with Reduce Motion that soft fade is all the movement there is.
    static func envelope(_ s: Showing, now: Date, fade: TimeInterval = 1) -> Double {
        let t = now.timeIntervalSince(s.began)
        guard t >= 0 else { return 0 }
        var a = min(1, t / fade)
        if let ends = s.ends { a = min(a, max(0, ends.timeIntervalSince(now) / fade)) }
        return max(0, min(1, a))
    }

    /// The numbers for one frame. `motion` false is the calm version: nothing travels, things only fade.
    public func sky(at now: Date, motion: Bool = true) -> EggSky {
        var out = EggSky()
        if let s = showing[.shootingStar], isShowing(.shootingStar, at: now) {
            let total = SkyEgg.shootingStar.seconds ?? 1.8
            // Calm version: the streak simply appears in the middle of its path and fades.
            out.star = motion ? min(1, max(0, now.timeIntervalSince(s.began) / total)) : 0.5
        }
        if let s = showing[.doubleRainbow] { out.rainbow = Self.envelope(s, now: now, fade: 2) }
        if let s = showing[.auroraNight] { out.aurora = Self.envelope(s, now: now, fade: 3) }
        if let s = showing[.retroFrame] { out.retro = Self.envelope(s, now: now, fade: 0.6) }
        if let s = showing[.goldenSun] { out.gold = Self.envelope(s, now: now, fade: 2) }
        if let s = showing[.twinMoons] { out.twinMoon = Self.envelope(s, now: now, fade: 3) }
        if bats { out.bats = 1 }
        if let began = fireworksBegan {
            let t = now.timeIntervalSince(began)
            if t >= 0, t < 300 { out.fireworks = motion ? t : 1.1 }
        }
        return out
    }
}

/// Glimmer: a tiny sky spirit, a small silver-lilac crescent with two dot eyes. It says one short, calm line.
/// It never says anything about the person looking, and it knows nothing.
public enum Glimmer {
    public static let lines = [
        "Nice sky today",
        "I'll keep watch",
        "Rainy is my favourite",
        "The clouds are slow today",
        "I like it up here",
        "That arc is a good seat",
        "Windy days tickle",
        "I counted the stars. Lots",
        "Quiet skies are nice too",
        "Snow makes everything soft",
        "The moon and I are friends",
        "I was just passing by",
        "This is a good spot",
        "Hello from up here",
        "Back to the sky I go",
    ]

    public static func line<G: RandomNumberGenerator>(using generator: inout G) -> String {
        lines.randomElement(using: &generator) ?? lines[0]
    }
}
