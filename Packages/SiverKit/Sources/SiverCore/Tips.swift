import Foundation

/// One tip: a sentence or two about something SiverSol really does, and the page where it lives.
/// Every tip here was checked against the build. A tip about a feature that does not exist is a bug.
public struct Tip: Identifiable, Equatable, Sendable {
    public enum Group: String, CaseIterable, Sendable {
        case start = "Getting started", sky = "The sky", collection = "Your collection", discord = "Discord"
        case macros = "Macros", laptops = "Laptops", privacy = "Privacy and safety"
    }

    public let id: String
    public let group: Group
    public let text: String
    /// Where "Show me" goes.
    public let page: AppPage

    public init(_ id: String, _ group: Group, _ text: String, _ page: AppPage) {
        self.id = id; self.group = group; self.text = text; self.page = page
    }
}

public enum TipCatalog {
    public static let all: [Tip] = [
        Tip("island", .start, "The island stays by the notch or at the top of your screen while SiverSol watches. You can turn it off in Settings, under Island.", .settings),
        Tip("pages", .start, "⌘1 to ⌘0 jump between the first ten pages, in sidebar order.", .dashboard),
        Tip("profiles", .start, "A profile switches routes, pings, macros and the island together. Glitch Hunt is made for sharing a server with a hunt group.", .settings),
        Tip("display-off", .start, "You can let the display turn off. Biome alerts keep working; key presses wait until the screen is back.", .automation),

        Tip("ribbon", .sky, "Move the pointer along the Sky Ribbon to see what the sky did while you were away. Click a biome to open it in the Timeline.", .dashboard),
        Tip("timeline", .sky, "The Timeline keeps every biome, aura and merchant SiverSol saw, on this Mac. You can export a day as CSV or JSON.", .timeline),

        Tip("moments", .collection, "Moments keeps short clips of rolls and rare biomes on this Mac. It is off until you turn it on in Automation.", .automation),
        Tip("foil", .collection, "Sol Dex foil gets livelier the rarer the aura. Rest the pointer on a prismatic card to see it move.", .auras),
        Tip("wrapped", .collection, "Session Wrapped draws a recap card when a session of ten minutes or more ends. You can have it posted to Discord from Automation.", .dashboard),

        Tip("hunt", .discord, "Hunt messages keep the exact format glitch-hunt bots expect. Test messages never use it.", .notifications),
        Tip("digest", .discord, "Digest gathers ordinary biomes into one Discord message an hour. Rare biomes, rolls and merchants still post on their own.", .notifications),
        Tip("test", .discord, "⌘T sends a test message to your routes that accept tests. It is always marked as a test.", .notifications),

        Tip("panic", .macros, "Panic stop: ⌃⌥⌘P stops every macro and pauses all input at once, from any app.", .macros),
        Tip("macros-safe", .macros, "Macros send their input only to Roblox, and stop when a rare biome starts unless you turn that off for a macro.", .macros),
        Tip("roll", .macros, "In the piano roll, drag a bar to move a key press, or its right edge to change how long the key is held.", .macros),

        Tip("lid", .laptops, "On a MacBook, closing the lid sleeps the Mac unless it is plugged into power and an external display.", .automation),
        Tip("battery", .laptops, "Battery guard tells Discord when a MacBook that is watching goes on battery, and again below 20%.", .automation),

        Tip("log", .privacy, "SiverSol reads Roblox's own log files. It never changes the game, your auras or your account.", .about),
        Tip("raw", .privacy, "Raw log lines are never posted. Names, ids and server codes are removed first.", .logLab),
        Tip("why", .privacy, "Every permission has a “?” that explains exactly why it is needed and what works without it.", .settings),
    ]

    public static func tips(in group: Tip.Group) -> [Tip] { all.filter { $0.group == group } }
}

/// When a tip may be shown, and which one. Pure rules; the app stores the two small values they need.
public enum TipRules {
    /// A tip is never shown during a rare biome or while a macro is recording or playing: that is not the
    /// moment to learn about the Timeline.
    public static func mayShow(enabled: Bool, rareBiome: Bool, macroBusy: Bool) -> Bool {
        enabled && !rareBiome && !macroBusy
    }

    /// The day number tips rotate on (local days since the reference date).
    public static func day(_ date: Date, calendar: Calendar = .current) -> Int {
        Int((calendar.startOfDay(for: date).timeIntervalSinceReferenceDate / 86_400).rounded())
    }

    /// The tip of the day: one a day, in order, skipping the ones the user dismissed. nil when every tip has
    /// been dismissed, or when today's tip was dismissed (the next one waits for tomorrow: at most one a day).
    public static func tipOfDay(day: Int, dismissed: Set<String>, dismissedOn: Int?, tips: [Tip] = TipCatalog.all) -> Tip? {
        if dismissedOn == day { return nil }
        let left = tips.filter { !dismissed.contains($0.id) }
        guard !left.isEmpty else { return nil }
        return left[((day % left.count) + left.count) % left.count]
    }
}
