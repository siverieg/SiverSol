import Foundation
import SiverCore

/// Where an event came from. Only `.live` events may use the Hunt-Compat format or ping anyone (hard rules 8, 9).
public enum EventOrigin: String, Codable, Sendable {
    case live, replay, simulated, test

    var titlePrefix: String {
        switch self {
        case .live: return ""
        case .replay: return "🧪 REPLAY · "
        case .simulated: return "🧪 SIMULATED · "
        case .test: return "🧪 TEST · "
        }
    }
}

public struct IncidentReport: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable {
        public var label: String
        public var at: Date
        public init(_ label: String, at: Date) { self.label = label; self.at = at }
    }
    public var id: String
    public var cause: String
    public var steps: [Step]
    public var recovered: Bool
    public init(id: String, cause: String, steps: [Step], recovered: Bool) {
        self.id = id; self.cause = cause; self.steps = steps; self.recovered = recovered
    }
}

public struct DailyReport: Codable, Equatable, Sendable {
    public var day: String            // 2026-11-18 (UTC)
    public var counts: [String: Int]  // biome key -> starts
    public var seconds: [String: Double]
    public var rares: [String]
    public var uptimeS: Double
    public var auras: Int
    public var merchants: Int?
    /// Macro Studio totals for the day.
    public var macroRuns: Int?
    public var autoClicks: Int?
    /// biome key -> 24 values: seconds spent in that biome during each UTC hour (the heat strip).
    public var hourly: [String: [Double]]?
    public init(day: String, counts: [String: Int], seconds: [String: Double], rares: [String], uptimeS: Double, auras: Int,
                merchants: Int? = nil, hourly: [String: [Double]]? = nil) {
        self.day = day; self.counts = counts; self.seconds = seconds; self.rares = rares; self.uptimeS = uptimeS; self.auras = auras
        self.merchants = merchants; self.hourly = hourly
    }

    /// Build the report for one UTC day ("2026-11-18") from that day's timeline events.
    public static func build(day: String, events: [SiverEvent], isRare: (BiomeKey) -> Bool, now: Date = Date()) -> DailyReport {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let parts = day.split(separator: "-").compactMap { Int($0) }
        let start = cal.date(from: DateComponents(year: parts.first, month: parts.count > 1 ? parts[1] : 1, day: parts.count > 2 ? parts[2] : 1)) ?? now
        let end = start.addingTimeInterval(86400)
        var counts: [String: Int] = [:], seconds: [String: Double] = [:], hourly: [String: [Double]] = [:]
        var rares: [String] = [], auras = 0, merchants = 0
        var open: [String: BiomeStarted] = [:]   // started id -> event, for biomes still running at report time

        func add(_ key: String, from: Date, to: Date) {
            let a = max(from, start), b = min(to, end)
            guard b > a else { return }
            seconds[key, default: 0] += b.timeIntervalSince(a)
            var t = a
            while t < b {
                let hour = min(23, max(0, Int(t.timeIntervalSince(start) / 3600)))
                let hourEnd = min(b, start.addingTimeInterval(Double(hour + 1) * 3600))
                hourly[key, default: Array(repeating: 0, count: 24)][hour] += hourEnd.timeIntervalSince(t)
                t = hourEnd
            }
        }
        for event in events {
            switch event {
            case .biomeStarted(let s):
                counts[s.biome.key.value, default: 0] += 1
                if isRare(s.biome.key) { rares.append(s.biome.key.value) }
                open[s.id] = s
            case .biomeEnded(let e):
                open[e.startedEventId] = nil
                add(e.biome.key.value, from: e.startedAt, to: e.at)
            case .auraEquipped(let a) where !a.initial: auras += 1
            case .merchantArrived: merchants += 1
            default: break
            }
        }
        // The biome in progress counts up to "now" (or the end of the day).
        if let last = open.values.max(by: { $0.at < $1.at }) { add(last.biome.key.value, from: last.at, to: min(now, end)) }
        return DailyReport(day: day, counts: counts, seconds: seconds, rares: rares, uptimeS: seconds.values.reduce(0, +),
                           auras: auras, merchants: merchants, hourly: hourly)
    }
}

public struct LiveCardState: Equatable, Sendable {
    public var biome: BiomeRef?
    public var biomeSince: Date?
    public var biomeStartObserved = false
    public var sessionStartedAt: Date
    public var todayCounts: [String: Int] = [:]
    public var lastAura: String?
    public var lastAuraAt: Date?
    public var lastMerchant: String?
    public var lastMerchantAt: Date?
    public var health = "connected"
    public var thermal = "nominal"
    public var outboxDepth = 0
    public var serverJobId: String?
    public var now: Date
    /// Set when the session is over; the card gets a final edit and stops updating.
    public var endedAt: Date?
    /// Session Inspector: "private server · joined … · 2 teleports · client 0.745…".
    public var sessionLine: String?
    /// Resource Monitor: "3.7 GB · 41% CPU".
    public var resourceLine: String?
    public var dailyResetAt: Date?
    /// Macro Studio: the running macro and its progress.
    public var macroLine: String?
    public var lastRoll: String?
    public var lastRollAt: Date?
    /// Glitch Hunt Mode: "6h 12m today · 31h 5m this week".
    public var coverageLine: String?

    public init(sessionStartedAt: Date, now: Date) { self.sessionStartedAt = sessionStartedAt; self.now = now }
}

public struct RenderContext: Sendable {
    public var catalog: BiomeCatalog
    public var auras: AuraCatalog?
    public var route: RouteConfig
    public var origin: EventOrigin
    public var serverLink: String?
    /// Event id -> the message that event produced on this route (for jump links).
    public var link: @Sendable (String) -> MessageRef?
    public var todayCount: @Sendable (BiomeKey) -> Int?
    public var sessionStartedAt: Date?
    public var now: Date
    /// Shown in a Sky Card's footer.
    public var profileName: String?

    public init(catalog: BiomeCatalog, route: RouteConfig, origin: EventOrigin = .live, serverLink: String? = nil,
                link: @escaping @Sendable (String) -> MessageRef? = { _ in nil },
                todayCount: @escaping @Sendable (BiomeKey) -> Int? = { _ in nil },
                sessionStartedAt: Date? = nil, now: Date = Date()) {
        self.catalog = catalog; self.route = route; self.origin = origin; self.serverLink = serverLink
        self.link = link; self.todayCount = todayCount; self.sessionStartedAt = sessionStartedAt; self.now = now
    }

    func joinButton() -> [ActionRow]? { serverLink.map { [ActionRow.link("Join server", $0)] } }
    func shortServer(_ jobId: String?) -> String? { jobId.map { "`\($0.prefix(8))`" } }
}

// MARK: - Rich profile

public enum RichTemplates {
    public static let username = "SiverSol"
    static let gray = 0x99AAB5, green = 0x57F287, amber = 0xFFCC00, red = 0xED4245, blurple = 0x5865F2

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    static func jump(_ ref: MessageRef?, _ label: String) -> String? {
        ref?.jumpURL.map { "[↗ \(label)](\($0))" }
    }

    public static func classicBiomeStarted(_ e: BiomeStarted, _ ctx: RenderContext) -> DiscordMessage {
        let info = ctx.catalog.info(for: e.biome.key)
        let live = ctx.origin == .live
        let rare = info.isRare
        var title: String
        if rare { title = "🚨 \(e.biome.key) STARTED" }
        else if e.wasRunning { title = "\(info.emoji) \(e.biome.key) in progress" }
        else { title = "\(info.emoji) \(e.biome.key) started" }
        title = ctx.origin.titlePrefix + title

        var fields: [Embed.Field] = []
        var description: String
        if e.observedStart {
            description = "Started \(DiscordTime.tag(e.at, "T")) (\(DiscordTime.tag(e.at, "R")))"
            if let d = info.durationS {
                fields.append(.init("Ends", "\(DiscordTime.tag(e.at.addingTimeInterval(TimeInterval(d)), "R")) · usually \(DiscordTime.duration(TimeInterval(d)))"))
            }
        } else {
            description = "Already running when I joined the server. First seen \(DiscordTime.tag(e.at, "T")) (\(DiscordTime.tag(e.at, "R")))."
        }
        if e.wasRunning { description += "\nSiverSol started while this biome was in progress." }
        if !live { description += "\n**Not a real biome.** Sent by `siversolctl` (\(ctx.origin.rawValue))." }
        if let s = ctx.shortServer(e.serverJobId) { fields.append(.init("Server", s)) }
        if let start = ctx.sessionStartedAt { fields.append(.init("Session uptime", DiscordTime.duration(e.at.timeIntervalSince(start)))) }
        if let n = ctx.todayCount(e.biome.key), n > 0 { fields.append(.init("Today", "\(ordinal(n)) \(info.display)")) }
        if let prev = e.previous { fields.append(.init("After", "\(ctx.catalog.info(for: prev).emoji) \(prev)")) }
        if rare, let link = ctx.serverLink { fields.append(.init("Private server", link, inline: false)) }
        if let rarity = info.rarity, rare { fields.append(.init("Rarity", rarity, inline: false)) }

        let ping = live ? ctx.route.ping(for: e.biome.key, isRare: rare) : nil
        return DiscordMessage(content: ping?.content, username: username,
                              embeds: [Embed(title: title, description: description, color: info.colorValue, fields: fields, timestamp: e.at)],
                              allowedMentions: ping?.allowedMentions ?? .none, components: ctx.joinButton())
    }

    /// The edit applied to a Started message once its biome is over.
    public static func classicStartedMessageAfterEnd(_ e: BiomeEnded, _ ctx: RenderContext) -> DiscordMessage {
        let info = ctx.catalog.info(for: e.biome.key)
        let lasted = DiscordTime.duration(e.duration) + (e.startObserved ? "" : "+")
        let title: String, color: Int
        if e.reason == .changed {
            title = "✅ \(e.biome.key) · ended · lasted \(lasted)"; color = gray
        } else {
            title = "⚪ \(e.biome.key) · lost track after \(lasted)"; color = gray
        }
        var description = "\(info.emoji) \(e.startObserved ? "Started" : "First seen") \(DiscordTime.tag(e.startedAt, "T")) · \(e.reason == .changed ? "ended" : "last seen") \(DiscordTime.tag(e.at, "T"))"
        if e.reason != .changed { description += "\n\(lostTrackNote(e.reason))" }
        var fields: [Embed.Field] = []
        if let s = ctx.shortServer(e.serverJobId) { fields.append(.init("Server", s)) }
        if let next = e.next { fields.append(.init("Next", "\(ctx.catalog.info(for: next).emoji) \(next)")) }
        return DiscordMessage(content: "", username: username,
                              embeds: [Embed(title: ctx.origin.titlePrefix + title, description: description, color: color, fields: fields, timestamp: e.startedAt)],
                              allowedMentions: .none, components: ctx.joinButton())
    }

    static func lostTrackNote(_ reason: BiomeEndReason) -> String {
        switch reason {
        case .changed: return ""
        case .leftServer: return "I joined another server. The biome may still be running on the old one."
        case .sessionEnded: return "Roblox closed or restarted. The biome may still be running on the server."
        }
    }

    public static func classicBiomeEnded(_ e: BiomeEnded, _ ctx: RenderContext) -> DiscordMessage {
        let lasted = DiscordTime.duration(e.duration) + (e.startObserved ? "" : "+")
        let title = e.reason == .changed ? "✅ \(e.biome.key) ended · \(lasted)" : "⚪ \(e.biome.key) · lost track · \(lasted)"
        var fields: [Embed.Field] = []
        if let j = jump(ctx.link(e.startedEventId), "Started message") { fields.append(.init("Started", j)) }
        if let next = e.next { fields.append(.init("Next", "\(ctx.catalog.info(for: next).emoji) \(next)")) }
        var description = "\(e.reason == .changed ? "Ended" : "Last seen") \(DiscordTime.tag(e.at, "T")) (\(DiscordTime.tag(e.at, "R")))"
        if e.reason != .changed { description += "\n\(lostTrackNote(e.reason))" }
        if !e.startObserved { description += "\nThe start was not observed, so the real length is longer." }
        return DiscordMessage(username: username,
                              embeds: [Embed(title: ctx.origin.titlePrefix + title, description: description, color: gray, fields: fields, timestamp: e.at)],
                              allowedMentions: .none)
    }

    public static func classicAura(_ e: AuraEquipped, _ ctx: RenderContext) -> DiscordMessage {
        var fields: [Embed.Field] = [.init("Rarity", ctx.auras?.rarityText(for: e.internalName) ?? "unknown")]
        if let note = ctx.auras?.info(for: e.internalName)?.note { fields.append(.init("Note", note)) }
        if let b = e.biome {
            var text = "\(ctx.catalog.info(for: b.key).emoji) \(b.key)"
            if let boost = ctx.auras?.nativeBoost(for: e.internalName, in: b.key) { text += " · \(boost)" }
            if let j = jump(e.biomeEventId.flatMap(ctx.link), "biome message") { text += "\n\(j)" }
            fields.append(.init("Biome", text))
        }
        fields.append(.init("Internal name", "`\(e.internalName)`"))
        return DiscordMessage(username: username,
                              embeds: [Embed(title: ctx.origin.titlePrefix + "✨ \(ctx.auras?.display(for: e.internalName) ?? AuraName.display(e.internalName))",
                                             description: "Equipped \(DiscordTime.tag(e.at, "T")) (\(DiscordTime.tag(e.at, "R")))",
                                             color: 0xF5C542, fields: fields, timestamp: e.at)],
                              allowedMentions: .none)
    }

    /// Aura Roll Feed: the game itself reported this roll (a cutscene roll), so it is announced as a roll, not an equip.
    public static func classicAuraRolled(_ e: AuraRolled, _ ctx: RenderContext) -> DiscordMessage {
        let display = ctx.auras?.info(for: e.name)?.display ?? e.name
        var fields: [Embed.Field] = [.init("Rarity", ctx.auras?.rarityText(for: e.name) ?? "unknown")]
        if let b = e.biome {
            var text = "\(ctx.catalog.info(for: b.key).emoji) \(b.key)"
            if let boost = ctx.auras?.nativeBoost(for: e.name, in: b.key) { text += " · \(boost)" }
            if let j = jump(e.biomeEventId.flatMap(ctx.link), "biome message") { text += "\n\(j)" }
            fields.append(.init("Biome", text))
        }
        if let d = e.durationS { fields.append(.init("Cutscene", DiscordTime.duration(d))) }
        return DiscordMessage(username: username,
                              embeds: [Embed(title: ctx.origin.titlePrefix + "🎉 Rolled \(display)",
                                             description: "Rolled \(DiscordTime.tag(e.at, "T")) (\(DiscordTime.tag(e.at, "R")))",
                                             color: 0xF5C542, fields: fields, timestamp: e.at)],
                              allowedMentions: .none)
    }

    /// Session Wrapped: the card is the message; the embed only names it.
    public static func classicWrapped(_ w: SessionWrap, _ ctx: RenderContext, imageFileName: String) -> DiscordMessage {
        var lines = ["Watched \(DiscordTime.duration(w.duration))", "\(w.biomeCounts.values.reduce(0, +)) biomes"]
        if !w.rares.isEmpty { lines.append("rare: \(Array(Set(w.rares)).sorted().joined(separator: ", "))") }
        if let r = w.rarestRoll { lines.append("rarest roll: \(r)") }
        var embed = Embed(title: ctx.origin.titlePrefix + "🌅 Session Wrapped", description: lines.joined(separator: " · "), color: 0x6B3FA0, timestamp: w.end)
        embed.image = .init(url: "attachment://\(imageFileName)")
        return DiscordMessage(username: username, embeds: [embed], allowedMentions: .none)
    }

    /// A Moment: the clip is attached, or the message says it stayed on the Mac.
    public static func classicMoment(_ m: Moment, _ ctx: RenderContext, hasVideo: Bool, stillFileName: String?) -> DiscordMessage {
        var fields: [Embed.Field] = []
        if !m.detail.isEmpty { fields.append(.init(m.kind == .roll ? "Rarity" : "Kind", m.detail)) }
        fields.append(.init("Length", DiscordTime.duration(m.seconds)))
        if let j = jump(m.eventId.flatMap(ctx.link), m.kind == .roll ? "roll message" : "biome message") { fields.append(.init("From", j)) }
        let megabytes = String(format: "%.1f MB", Double(m.bytes) / 1_048_576)
        let text = hasVideo ? "The clip is attached (\(megabytes)). Chat and player list are covered."
                            : "Clip saved on this Mac (\(megabytes) is more than Discord takes from a webhook). Chat and player list are covered."
        var embed = Embed(title: ctx.origin.titlePrefix + "🎬 Moment · \(m.title)", description: text, color: 0x8A6BFF, fields: fields, timestamp: m.at)
        if let stillFileName { embed.image = .init(url: "attachment://\(stillFileName)") }
        return DiscordMessage(username: username, embeds: [embed], allowedMentions: .none)
    }

    public static func classicNewBiome(_ e: NewBiomeSeen, _ ctx: RenderContext) -> DiscordMessage {
        DiscordMessage(username: username,
                       embeds: [Embed(title: ctx.origin.titlePrefix + "🆕 New biome seen: \(e.biome.key)",
                                      description: "Not in the catalog yet. Saved to `learned_biomes.json`; detection keeps working.",
                                      color: blurple,
                                      fields: [.init("Raw hoverText", "`\(e.biome.raw)`"), .init("assetId", e.biome.assetId.map { "`\($0)`" } ?? "none")],
                                      timestamp: e.at)],
                       allowedMentions: .none)
    }

    public static func classicMerchant(_ m: MerchantArrived, _ ctx: RenderContext) -> DiscordMessage {
        var fields: [Embed.Field] = []
        if let b = m.biome {
            var text = "\(ctx.catalog.info(for: b.key).emoji) \(b.key)"
            if let j = jump(m.biomeEventId.flatMap(ctx.link), "biome message") { text += "\n\(j)" }
            fields.append(.init("Biome", text))
        }
        if let link = ctx.serverLink { fields.append(.init("Private server", link, inline: false)) }
        let colors = ["mari": 0xF2D9FF, "jester": 0xA63DFF, "rin": 0xAC5E31]
        return DiscordMessage(username: username,
                              embeds: [Embed(title: ctx.origin.titlePrefix + "🛒 \(m.name) arrived",
                                             description: "Seen \(DiscordTime.tag(m.at, "T")) (\(DiscordTime.tag(m.at, "R")))",
                                             color: colors[m.name.lowercased()] ?? blurple, fields: fields, timestamp: m.at)],
                              allowedMentions: .none, components: ctx.joinButton())
    }

    public static func classicIncident(_ i: IncidentReport, _ ctx: RenderContext) -> DiscordMessage {
        let first = i.steps.first?.at ?? ctx.now, last = i.steps.last?.at ?? ctx.now
        let title = i.recovered ? "🔌 \(i.cause) → recovered in \(DiscordTime.duration(last.timeIntervalSince(first)))"
                                : "🔌 \(i.cause) → not recovered yet"
        let timeline = i.steps.map { "\(DiscordTime.tag($0.at, "T")) · \($0.label) (+\(DiscordTime.duration($0.at.timeIntervalSince(first))))" }.joined(separator: "\n")
        return DiscordMessage(username: username,
                              embeds: [Embed(title: ctx.origin.titlePrefix + title, description: timeline.isEmpty ? "No steps recorded." : timeline,
                                             color: i.recovered ? green : red, timestamp: last)],
                              allowedMentions: .none)
    }

    /// What a route will receive, as short lines for the connection test.
    public static func alertSummary(for route: RouteConfig) -> [String] {
        var lines: [String] = []
        if route.wants(.biome) {
            // Wording note: never write "Biome started/ended" here; a hunt bot's pattern would match it.
            lines.append("🌦️ Every biome change, start and end" + (route.includeNormal ? ", NORMAL included" : ", NORMAL left out"))
            lines.append("🚨 Rare biomes (GLITCHED, DREAMSPACE, CYBERSPACE, SINGULARITY) " + (route.pingsEnabled ? "**with a ping**" : "without a ping"))
        }
        if route.wants(.aura) { lines.append("✨ New auras and 🎉 cutscene rolls") }
        if route.wants(.merchant) { lines.append("🛒 Merchants (Mari, Jester, Rin)") }
        if route.wants(.incident) { lines.append("🔌 Disconnects and how the rejoin went") }
        if route.wants(.status) { lines.append("ℹ️ Status notes (updates, memory, things that need you)") }
        if route.wants(.daily) { lines.append("📊 A daily report at 00:00 UTC") }
        if route.wants(.liveCard) { lines.append("📡 One live session card, edited in place") }
        return lines
    }

    /// The connection test (onboarding and "Send test"): proof the webhook works, what this channel will get,
    /// and a clearly marked sample of a biome alert. Never used for a Hunt-Compat route.
    public static func classicConnected(route: RouteConfig, webhookName: String?, channelId: String?, catalog: BiomeCatalog, now: Date = Date()) -> DiscordMessage {
        let place = channelId.map { "<#\($0)>" } ?? "this channel"
        let hook = webhookName.map { " through the webhook “\($0)”" } ?? ""
        let summary = alertSummary(for: route)
        let main = Embed(title: "✅ SiverSol is connected",
                         description: "This webhook works. Alerts for the route **\(route.name)** will arrive in \(place)\(hook).",
                         color: green,
                         fields: [.init("This channel will get", summary.isEmpty ? "Nothing yet. Turn on some alerts for this route in SiverSol." : summary.joined(separator: "\n"), inline: false),
                                  .init("Version", "SiverSol v\(SiverSol.version)"),
                                  .init("Pings", route.pingsEnabled ? "on for rare biomes" : "off")],
                         timestamp: now)
        let windy = catalog.info(for: "WINDY")
        let sample = Embed(title: "🧪 SIMULATED · \(windy.emoji) WINDY started",
                           description: "This is what a biome alert looks like. **Not a real biome.**\nStarted \(DiscordTime.tag(now, "T")) (\(DiscordTime.tag(now, "R")))",
                           color: windy.colorValue,
                           fields: [.init("Ends", "\(DiscordTime.tag(now.addingTimeInterval(120), "R")) · usually 2m 0s"), .init("Server", "`a1b2c3d4`"), .init("Today", "1st Windy")],
                           timestamp: now)
        return DiscordMessage(username: username, embeds: [main, sample], allowedMentions: .none)
    }

    /// Macro Studio events (Rich routes only; never in hunt format).
    public static func classicMacro(_ e: MacroEvent, _ ctx: RenderContext, hasProof: Bool = false) -> DiscordMessage {
        var fields: [Embed.Field] = []
        if let t = e.trigger { fields.append(.init("Trigger", t)) }
        let title: String, color: Int
        switch e.kind {
        case .started:
            title = "▶️ Macro started · \(e.name)"; color = blurple
            if e.steps > 0 { fields.append(.init("Steps", "\(e.steps)")) }
        case .finished:
            title = "🏁 Macro finished · \(e.name)"; color = green
            fields.append(.init("Loops", "\(e.loops)")); fields.append(.init("Took", DiscordTime.duration(e.durationS))); fields.append(.init("Steps played", "\(e.steps)"))
        case .stopped:
            title = "⏹️ Macro stopped · \(e.name)"; color = e.guardianStop ? red : amber
            fields.append(.init("Why", e.reason ?? "stopped", inline: false))
            fields.append(.init("Loops done", "\(e.loops)")); fields.append(.init("Ran for", DiscordTime.duration(e.durationS)))
        case .recorded:
            title = "⏺️ Macro recorded · \(e.name)"; color = blurple
            fields.append(.init("Length", DiscordTime.duration(e.durationS))); fields.append(.init("Steps", "\(e.steps)"))
        }
        if let j = jump(e.biomeEventId.flatMap(ctx.link), "biome message") { fields.append(.init("Triggered by", j)) }
        var description: String?
        if e.kind == .stopped, e.guardianStop {
            description = "Guardian stopped this macro. Every key and button was released" + (hasProof ? "; the screenshot shows what it saw." : ".")
        }
        return DiscordMessage(username: username,
                              embeds: [Embed(title: ctx.origin.titlePrefix + title, description: description, color: color, fields: fields, timestamp: e.at)],
                              allowedMentions: .none)
    }

    /// A plain informational message (updates, resource alerts, reminders).
    public static func classicInfo(title: String, text: String, color: Int = 0x5865F2, origin: EventOrigin = .live, now: Date = Date()) -> DiscordMessage {
        DiscordMessage(username: username,
                       embeds: [Embed(title: origin.titlePrefix + title, description: text, color: color, timestamp: now)],
                       allowedMentions: .none)
    }

    public static func buildLog(phase: String, done: [String], next: String, needsYou: [String] = [], origin: EventOrigin = .live, now: Date = Date()) -> DiscordMessage {
        var fields = [Embed.Field("Done", done.map { "• \($0)" }.joined(separator: "\n"), inline: false), .init("Next", next, inline: false)]
        fields.append(.init("Needs you", needsYou.isEmpty ? "Nothing right now." : needsYou.map { "• \($0)" }.joined(separator: "\n"), inline: false))
        return DiscordMessage(username: username,
                              embeds: [Embed(title: origin.titlePrefix + "🛠 Build Log · \(phase)", color: blurple, fields: fields, timestamp: now)],
                              allowedMentions: .none)
    }

    public static func actionNeeded(_ action: String, detail: String? = nil, origin: EventOrigin = .live, now: Date = Date()) -> DiscordMessage {
        DiscordMessage(username: username,
                       embeds: [Embed(title: origin.titlePrefix + "⚠️ Action needed", description: detail, color: amber,
                                      fields: [.init("Action", action, inline: false)], timestamp: now)],
                       allowedMentions: .none)
    }

    public static func classicDailyReport(_ r: DailyReport, _ ctx: RenderContext, chartFileName: String? = nil) -> DiscordMessage {
        let top = r.counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(12)
        let lines = top.map { key, n -> String in
            let info = ctx.catalog.info(for: BiomeKey(key))
            return "\(info.emoji) **\(key)** × \(n) · \(DiscordTime.duration(r.seconds[key] ?? 0))"
        }
        var embed = Embed(title: ctx.origin.titlePrefix + "📊 Daily report · \(r.day)",
                          description: lines.isEmpty ? "No biomes recorded." : lines.joined(separator: "\n"), color: blurple,
                          fields: [.init("Rares", r.rares.isEmpty ? "none" : r.rares.joined(separator: ", ")),
                                   .init("Watched", DiscordTime.duration(r.uptimeS)), .init("Auras", "\(r.auras)"),
                                   .init("Merchants", "\(r.merchants ?? 0)")]
                                  + ((r.macroRuns ?? 0) > 0 || (r.autoClicks ?? 0) > 0
                                     ? [.init("Macros", "\(r.macroRuns ?? 0) run\((r.macroRuns ?? 0) == 1 ? "" : "s") · \(r.autoClicks ?? 0) auto clicks")] : []),
                          timestamp: ctx.now)
        if let chartFileName { embed.image = .init(url: "attachment://\(chartFileName)") }
        return DiscordMessage(username: username, embeds: [embed], allowedMentions: .none)
    }

    /// Rule 8: simulated biomes get this title and nothing a hunt bot could parse.
    public static func classicSimulated(biome: BiomeKey, _ ctx: RenderContext) -> DiscordMessage {
        let info = ctx.catalog.info(for: biome)
        return DiscordMessage(username: username,
                              embeds: [Embed(title: "🧪 SIMULATED · \(biome)",
                                             description: "\(info.emoji) Simulated by `siversolctl simulate`. **Not a real biome**, nobody was pinged, and this is not in hunt format.",
                                             color: info.colorValue,
                                             fields: [.init("Category", info.category.rawValue), .init("Usual length", info.durationS.map { DiscordTime.duration(TimeInterval($0)) } ?? "unknown")],
                                             timestamp: ctx.now)],
                              allowedMentions: .none)
    }

    public static func progressBar(_ fraction: Double, width: Int = 12) -> String {
        let f = min(1, max(0, fraction))
        let filled = Int((f * Double(width)).rounded())
        return String(repeating: "▰", count: filled) + String(repeating: "▱", count: width - filled)
    }

    public static func classicLiveCard(_ s: LiveCardState, catalog: BiomeCatalog, auras: AuraCatalog? = nil) -> DiscordMessage {
        var fields: [Embed.Field] = []
        var biomeText = "unknown"
        var color = gray
        if let b = s.biome {
            let info = catalog.info(for: b.key)
            color = info.colorValue
            biomeText = "\(info.emoji) **\(b.key)**"
            if let since = s.biomeSince {
                let elapsed = s.now.timeIntervalSince(since)
                if let d = info.durationS, s.biomeStartObserved {
                    let end = since.addingTimeInterval(TimeInterval(d))
                    biomeText += "\n\(progressBar(elapsed / Double(d))) \(Int(min(1, max(0, elapsed / Double(d))) * 100))%\nends \(DiscordTime.tag(end, "R"))"
                } else {
                    biomeText += "\nsince \(DiscordTime.tag(since, "R"))"
                }
            }
        }
        fields.append(.init("Biome", biomeText))
        fields.append(.init("Session uptime", DiscordTime.duration((s.endedAt ?? s.now).timeIntervalSince(s.sessionStartedAt))))
        fields.append(.init("Roblox", s.health + (s.serverJobId.map { " · `\($0.prefix(8))`" } ?? "")))
        let tallies = s.todayCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\(catalog.info(for: BiomeKey($0.key)).emoji) \($0.key) × \($0.value)" }
        fields.append(.init("Today's biomes", tallies.isEmpty ? "none yet" : tallies.joined(separator: "\n"), inline: false))
        fields.append(.init("Last aura", s.lastAura.map { "✨ \(auras?.display(for: $0) ?? AuraName.display($0))" + (s.lastAuraAt.map { " \(DiscordTime.tag($0, "R"))" } ?? "") } ?? "none"))
        fields.append(.init("Last merchant", s.lastMerchant.map { "🛒 \($0)" + (s.lastMerchantAt.map { " \(DiscordTime.tag($0, "R"))" } ?? "") } ?? "none"))
        if let roll = s.lastRoll { fields.append(.init("Last roll", "🎉 \(roll)" + (s.lastRollAt.map { " \(DiscordTime.tag($0, "R"))" } ?? ""))) }
        if let line = s.sessionLine { fields.append(.init("Session", line, inline: false)) }
        if let macro = s.macroLine { fields.append(.init("Macro", macro, inline: false)) }
        if let reset = s.dailyResetAt, s.endedAt == nil { fields.append(.init("Daily reset", DiscordTime.tag(reset, "R"))) }
        if let res = s.resourceLine { fields.append(.init("Roblox process", res)) }
        if let coverage = s.coverageLine { fields.append(.init("Hunt coverage", coverage, inline: false)) }
        fields.append(.init("Mac", "thermal \(s.thermal) · outbox \(s.outboxDepth)"))
        let title = s.endedAt == nil ? "📡 Live session" : "📡 Session ended"
        return DiscordMessage(content: "", username: username,
                              embeds: [Embed(title: title, description: "Updated \(DiscordTime.tag(s.now, "R")) · started \(DiscordTime.tag(s.sessionStartedAt, "f"))",
                                             color: s.endedAt == nil ? color : gray, fields: fields, timestamp: s.now)],
                              allowedMentions: .none)
    }
}

// MARK: - Hunt-Compat profile (SPEC F3)

public enum HuntTemplates {
    // LOCKED FORMAT. Confirmed by Shayge, owner of Shay's Glitch Hunt bot (2026-11-18):
    // the bot matches "Biome Started - {biome}" (Coteab style, case-insensitive) and searches every embed field for the
    // private server link; the footer does not matter. Therefore:
    //   • the title starts EXACTLY with "Biome Started - " / "Biome Ended - ": no emoji, no prefix, nothing before "Biome";
    //   • the link is the raw URL, alone, in a field named exactly "Private Server Link".
    // HuntCompatTests.testLockedFormat fails if either drifts. Change this only if Shayge changes his bot.
    public static let startedPrefix = "Biome Started - "
    public static let endedPrefix = "Biome Ended - "
    public static let linkFieldName = "Private Server Link"

    /// `nil` unless the event is live: simulated, replayed and test events never get the hunt format (hard rule 8).
    public static func biomeStarted(_ e: BiomeStarted, _ ctx: RenderContext) -> DiscordMessage? {
        guard ctx.origin == .live else { return nil }
        let info = ctx.catalog.info(for: e.biome.key)
        var fields: [Embed.Field] = []
        if let link = ctx.serverLink { fields.append(.init(linkFieldName, link, inline: false)) }
        let ping = ctx.route.ping(for: e.biome.key, isRare: info.isRare)
        var embed = Embed(title: startedPrefix + e.biome.key.value,
                          description: "Started \(DiscordTime.tag(e.at, "T")) (\(DiscordTime.tag(e.at, "R")))",
                          color: info.colorValue, fields: fields.isEmpty ? nil : fields, timestamp: e.at)
        if let t = info.thumbnail { embed.thumbnail = .init(url: t) }
        return DiscordMessage(content: ping?.content, embeds: [embed], allowedMentions: ping?.allowedMentions ?? .none)
    }

    /// Ended carries no server link (same as Noteab and JARAM).
    public static func biomeEnded(_ e: BiomeEnded, _ ctx: RenderContext) -> DiscordMessage? {
        guard ctx.origin == .live else { return nil }
        let info = ctx.catalog.info(for: e.biome.key)
        // If we only lost track of a rare biome it is probably still live on the server: do not call it ended.
        if e.reason != .changed && info.isRare { return nil }
        var embed = Embed(title: endedPrefix + e.biome.key.value,
                          description: "Ended \(DiscordTime.tag(e.at, "T")) (\(DiscordTime.tag(e.at, "R")))",
                          color: info.colorValue, timestamp: e.at)
        if let t = info.thumbnail { embed.thumbnail = .init(url: t) }
        return DiscordMessage(embeds: [embed], allowedMentions: .none)
    }
}
