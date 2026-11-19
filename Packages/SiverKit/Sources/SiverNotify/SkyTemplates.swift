import Foundation
import SiverCore

/// Every Rich message in the Sky Cards layout. Each function here builds the classic v1.0 message and attaches its
/// card; the notifier sends one form or the other. Words are sentence case, calm and specific: no emoji, no
/// exclamation marks. Anything that ticks is a Discord timestamp, so a card is never stale.
extension RichTemplates {
    // MARK: shared pieces

    /// "SiverSol v1.0 · Glitch Hunt"
    static func footer(_ profile: String?) -> String {
        let parts = SiverSol.version.split(separator: ".")
        let short = parts.count >= 2 ? "\(parts[0]).\(parts[1])" : SiverSol.version
        return "SiverSol v\(short) · \(profile?.isEmpty == false ? profile! : "Default")"
    }

    static func kind(_ info: BiomeInfo) -> String {
        switch info.category {
        case .rare: return "rare biome"
        case .event: return "event biome"
        case .weather: return "weather"
        case .normal: return "clear sky"
        case .unknown: return "new biome"
        }
    }

    static func accent(_ info: BiomeInfo) -> Int { info.palette.accent.int }
    static let silver = 0xC9D1DC, calm = 0x5B6E8C, good = 0x57C785, warn = 0xF5B841, bad = 0xE63946

    /// The local hour of an event, which decides whether its pictures show a day or a night sky.
    static func hour(_ date: Date) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return Double(c.hour ?? 12) + Double(c.minute ?? 0) / 60
    }

    /// "17:46 UTC": a clock time that means the same to every reader, for words baked into a picture.
    static func utc(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d UTC", c.hour ?? 0, c.minute ?? 0)
    }

    /// The first words of a context line when the message is not about a real event.
    static func previewNote(_ origin: EventOrigin) -> String? {
        switch origin {
        case .live: return nil
        case .replay: return "preview · replayed, not happening now"
        case .simulated: return "preview · simulated, not a real event"
        case .test: return "preview · test, not a real event"
        }
    }

    static func context(_ parts: [String?], origin: EventOrigin) -> String {
        ([previewNote(origin)] + parts).compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Titles written for the classic embeds start with an emoji; a card's headline does not.
    static func plain(_ title: String) -> String {
        var scalars = Substring(title).unicodeScalars
        while let first = scalars.first, !(first.isASCII && (CharacterSet.alphanumerics.contains(first) || first == "\"" || first == "“")) && !CharacterSet.letters.contains(first) {
            scalars.removeFirst()
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    // MARK: biomes

    public static func biomeStarted(_ e: BiomeStarted, _ ctx: RenderContext) -> DiscordMessage {
        var m = classicBiomeStarted(e, ctx)
        let info = ctx.catalog.info(for: e.biome.key)
        let name = info.display
        let end = info.durationS.map { e.at.addingTimeInterval(TimeInterval($0)) }
        let headline = e.wasRunning ? "\(name) is under way" : (e.observedStart ? "\(name) has started" : "\(name) is on")
        var facts: [String] = []
        if e.observedStart {
            facts.append(end.map { "Started \(DiscordTime.tag(e.at, "t")) · ends \(DiscordTime.tag($0, "R"))" } ?? "Started \(DiscordTime.tag(e.at, "t")) (\(DiscordTime.tag(e.at, "R")))")
        } else {
            facts.append("Already running when SiverSol joined. First seen \(DiscordTime.tag(e.at, "t")).")
        }
        var second: [String] = []
        if let d = info.durationS { second.append("Usually lasts `\(DiscordTime.duration(TimeInterval(d)))`") }
        if let n = ctx.todayCount(e.biome.key), n > 0 { second.append("\(ordinal(n)) today") }
        if !second.isEmpty { facts.append(second.joined(separator: " · ")) }
        if info.isRare, let rarity = info.rarity {
            facts.append(rarity.prefix(1).uppercased() + rarity.dropFirst())
        } else if let prev = e.previous {
            facts.append("After \(ctx.catalog.info(for: prev).display)")
        }
        let line = e.observedStart ? (end.map { "\(utc(e.at)) · ends about \(utc($0))" } ?? "started \(utc(e.at))") : "seen \(utc(e.at))"
        let preview = ctx.origin != .live
        m.sky = SkyCard(accent: accent(info), headline: headline,
                        context: context([kind(info), ctx.shortServer(e.serverJobId).map { "server \($0)" }], origin: ctx.origin),
                        facts: facts,
                        button: ctx.serverLink.map { SkyCard.Button(label: "Join server", url: $0) },
                        footer: footer(ctx.profileName),
                        art: SkyArt(thumb: .biome(e.biome.key.value), card: .biome(key: e.biome.key.value, eyebrow: kind(info), title: name, line: line),
                                    preview: preview, hour: hour(e.at)))
        return m
    }

    /// The edit applied to a Started card once its biome is over. No button: "Join server" is for a biome that is on.
    public static func startedMessageAfterEnd(_ e: BiomeEnded, _ ctx: RenderContext) -> DiscordMessage {
        var m = classicStartedMessageAfterEnd(e, ctx)
        let info = ctx.catalog.info(for: e.biome.key)
        let ended = e.reason == .changed
        var facts = ["Lasted `\(DiscordTime.duration(e.duration))`" + (e.startObserved ? "" : " or longer (the start was not seen)"),
                     "\(e.startObserved ? "Started" : "First seen") \(DiscordTime.tag(e.startedAt, "t")) · \(ended ? "ended" : "last seen") \(DiscordTime.tag(e.at, "t"))"]
        if !ended { facts.append(lostTrackNote(e.reason)) } else if let next = e.next { facts.append("Then \(ctx.catalog.info(for: next).display)") }
        m.sky = SkyCard(accent: accent(info), headline: ended ? "\(info.display) has ended" : "Lost track of \(info.display)",
                        context: context([kind(info), ctx.shortServer(e.serverJobId).map { "server \($0)" }], origin: ctx.origin),
                        facts: facts, footer: footer(ctx.profileName))
        return m
    }

    public static func biomeEnded(_ e: BiomeEnded, _ ctx: RenderContext) -> DiscordMessage {
        var m = classicBiomeEnded(e, ctx)
        let info = ctx.catalog.info(for: e.biome.key)
        let ended = e.reason == .changed
        var facts = ["\(ended ? "Ended" : "Last seen") \(DiscordTime.tag(e.at, "t")) (\(DiscordTime.tag(e.at, "R")))"]
        if !ended { facts.append(lostTrackNote(e.reason)) }
        var third: [String] = []
        if let next = e.next { third.append("Then \(ctx.catalog.info(for: next).display)") }
        if let j = ctx.link(e.startedEventId)?.jumpURL { third.append("[Started card](\(j))") }
        if !third.isEmpty { facts.append(third.joined(separator: " · ")) }
        m.sky = SkyCard(accent: accent(info), headline: ended ? "\(info.display) has ended" : "Lost track of \(info.display)",
                        context: context([kind(info), "lasted \(DiscordTime.duration(e.duration))" + (e.startObserved ? "" : " or longer")], origin: ctx.origin),
                        facts: facts, footer: footer(ctx.profileName),
                        art: SkyArt(thumb: .biome(e.biome.key.value), preview: ctx.origin != .live, hour: hour(e.at)))
        return m
    }

    public static func newBiome(_ e: NewBiomeSeen, _ ctx: RenderContext) -> DiscordMessage {
        var m = classicNewBiome(e, ctx)
        let info = ctx.catalog.info(for: e.biome.key)
        m.sky = SkyCard(accent: accent(info), headline: "A biome SiverSol has not seen before: \(info.display)",
                        context: context(["new biome", "not in the catalog yet"], origin: ctx.origin),
                        facts: ["Saved to the catalog on this Mac. Detection keeps working.", "The game calls it `\(e.biome.raw)`"],
                        footer: footer(ctx.profileName),
                        art: SkyArt(thumb: .biome(e.biome.key.value), preview: ctx.origin != .live, hour: hour(e.at)))
        return m
    }

    public static func simulated(biome: BiomeKey, _ ctx: RenderContext) -> DiscordMessage {
        var m = classicSimulated(biome: biome, ctx)
        let info = ctx.catalog.info(for: biome)
        m.sky = SkyCard(accent: accent(info), headline: "\(info.display), simulated",
                        context: context([kind(info)], origin: ctx.origin == .live ? .simulated : ctx.origin),
                        facts: ["Nobody was pinged, and this is never sent in hunt format.",
                                info.durationS.map { "Usually lasts `\(DiscordTime.duration(TimeInterval($0)))`" } ?? "No usual length known"],
                        footer: footer(ctx.profileName),
                        art: SkyArt(thumb: .biome(biome.value), card: .biome(key: biome.value, eyebrow: kind(info), title: info.display, line: "simulated at \(utc(ctx.now))"),
                                    preview: true, hour: hour(ctx.now)))
        return m
    }

    // MARK: auras

    private static func auraFacts(_ name: String, at: Date, verb: String, biome: BiomeRef?, ctx: RenderContext) -> [String] {
        var facts = ["\(verb) \(DiscordTime.tag(at, "t")) (\(DiscordTime.tag(at, "R")))"]
        if let b = biome {
            var text = "During \(ctx.catalog.info(for: b.key).display)"
            if let boost = ctx.auras?.nativeBoost(for: name, in: b.key) { text += " · \(boost)" }
            facts.append(text)
        }
        return facts
    }

    private static func auraCard(_ name: String, kindWord: String, headline: String, facts: [String], withCard: Bool, at: Date, ctx: RenderContext) -> SkyCard {
        let entry = ctx.auras?.info(for: name)
        let tier = DexTier(catalog: entry?.tier)
        let odds = entry?.chance.map { "1 in \(AuraCatalog.grouped($0))" }
        return SkyCard(accent: tier.color.int, headline: headline,
                       context: context([kindWord, entry?.tier, odds], origin: ctx.origin),
                       facts: facts, footer: footer(ctx.profileName),
                       art: SkyArt(thumb: .aura(name), card: withCard ? .aura(name: name) : nil, preview: ctx.origin != .live, hour: hour(at)))
    }

    public static func aura(_ e: AuraEquipped, _ ctx: RenderContext) -> DiscordMessage {
        var m = classicAura(e, ctx)
        let display = ctx.auras?.display(for: e.internalName) ?? AuraName.display(e.internalName)
        var facts = auraFacts(e.internalName, at: e.at, verb: "Equipped", biome: e.biome, ctx: ctx)
        if let note = ctx.auras?.info(for: e.internalName)?.note { facts.append(note) }
        // The full card is for the rolls worth looking at; an everyday equip gets the small emblem only.
        let rare = (ctx.auras?.chance(for: e.internalName) ?? 0) >= 1_000_000
        m.sky = auraCard(e.internalName, kindWord: "aura", headline: "\(display) equipped", facts: facts, withCard: rare, at: e.at, ctx: ctx)
        return m
    }

    public static func auraRolled(_ e: AuraRolled, _ ctx: RenderContext) -> DiscordMessage {
        var m = classicAuraRolled(e, ctx)
        let display = ctx.auras?.info(for: e.name)?.display ?? e.name
        var facts = auraFacts(e.name, at: e.at, verb: "Rolled", biome: e.biome, ctx: ctx)
        if let d = e.durationS { facts.append("Cutscene `\(DiscordTime.duration(d))`") }
        m.sky = auraCard(e.name, kindWord: "roll", headline: "Rolled \(display)", facts: facts, withCard: true, at: e.at, ctx: ctx)
        return m
    }

    // MARK: moments, wrapped, daily

    public static func moment(_ mo: Moment, _ ctx: RenderContext, hasVideo: Bool, stillFileName: String?) -> DiscordMessage {
        var m = classicMoment(mo, ctx, hasVideo: hasVideo, stillFileName: stillFileName)
        let megabytes = String(format: "%.1f MB", Double(mo.bytes) / 1_048_576)
        var facts = [hasVideo ? "The clip is attached. Chat and player list are covered." : "The clip stayed on the Mac: `\(megabytes)` is more than Discord takes from a webhook."]
        if let j = mo.eventId.flatMap(ctx.link)?.jumpURL { facts.append("[\(mo.kind == .roll ? "Roll" : "Biome") card](\(j))") }
        let thumb: SkyArt.Thumb = mo.kind == .rareBiome ? .biome(mo.biome ?? mo.title) : .symbol("film.stack", calm)
        let accentColor = mo.kind == .rareBiome ? accent(ctx.catalog.info(for: BiomeKey(mo.biome ?? mo.title))) : calm
        m.sky = SkyCard(accent: accentColor, headline: "A moment: \(mo.kind == .rareBiome ? ctx.catalog.info(for: BiomeKey(mo.title)).display : mo.title)",
                        context: context(["clip", DiscordTime.duration(mo.seconds), megabytes], origin: ctx.origin),
                        facts: facts, footer: footer(ctx.profileName), art: SkyArt(thumb: thumb, preview: ctx.origin != .live, hour: hour(mo.at)))
        return m
    }

    public static func wrapped(_ w: SessionWrap, _ ctx: RenderContext, imageFileName: String) -> DiscordMessage {
        var m = classicWrapped(w, ctx, imageFileName: imageFileName)
        let info = ctx.catalog.info(for: BiomeKey(w.signatureBiome))
        var facts = ["`\(w.biomeCounts.values.reduce(0, +))` biomes · `\(w.rolls)` rolls · `\(w.merchants)` merchant visits"]
        facts.append(w.rares.isEmpty ? "No rare biomes this time" : "Rare: \(Array(Set(w.rares)).sorted().map { ctx.catalog.info(for: BiomeKey($0)).display }.joined(separator: ", "))")
        if let r = w.rarestRoll { facts.append("Rarest roll: \(r)") }
        m.sky = SkyCard(accent: accent(info), headline: "Session wrapped",
                        context: context(["recap", "watched \(DiscordTime.duration(w.duration))"], origin: ctx.origin),
                        facts: facts, footer: footer(ctx.profileName),
                        art: SkyArt(thumb: .biome(w.signatureBiome), preview: ctx.origin != .live, hour: hour(w.end)))
        return m
    }

    public static func dailyReport(_ r: DailyReport, _ ctx: RenderContext, chartFileName: String? = nil) -> DiscordMessage {
        var m = classicDailyReport(r, ctx, chartFileName: chartFileName)
        let top = r.counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(4)
            .map { "\(ctx.catalog.info(for: BiomeKey($0.key)).display) ×\($0.value)" }.joined(separator: " · ")
        let rares = r.rares.isEmpty ? "No rare biomes" : "Rare: \(r.rares.map { ctx.catalog.info(for: BiomeKey($0)).display }.joined(separator: ", "))"
        m.sky = SkyCard(accent: calm, headline: "Daily report for \(r.day)",
                        context: context(["daily", "watched \(DiscordTime.duration(r.uptimeS))"], origin: ctx.origin),
                        facts: ["`\(r.counts.values.reduce(0, +))` biomes · `\(r.auras)` auras · `\(r.merchants ?? 0)` merchants", rares, top],
                        footer: footer(ctx.profileName), art: SkyArt(thumb: .symbol("chart.bar.xaxis", calm), preview: ctx.origin != .live))
        return m
    }

    // MARK: merchants, incidents, macros, status

    public static func merchant(_ me: MerchantArrived, _ ctx: RenderContext) -> DiscordMessage {
        var m = classicMerchant(me, ctx)
        var facts = ["Arrived \(DiscordTime.tag(me.at, "t")) (\(DiscordTime.tag(me.at, "R")))"]
        if let b = me.biome { facts.append("During \(ctx.catalog.info(for: b.key).display)") }
        let colors = ["mari": 0xC9A7E8, "jester": 0xA63DFF, "rin": 0xAC5E31]
        let tint = colors[me.name.lowercased()] ?? calm
        m.sky = SkyCard(accent: tint, headline: "\(me.name) has arrived",
                        context: context(["merchant", "seen in the \(me.source ?? "log")"], origin: ctx.origin),
                        facts: facts, footer: footer(ctx.profileName), art: SkyArt(thumb: .symbol("cart.fill", tint), preview: ctx.origin != .live, hour: hour(me.at)))
        return m
    }

    public static func incident(_ i: IncidentReport, _ ctx: RenderContext) -> DiscordMessage {
        var m = classicIncident(i, ctx)
        let first = i.steps.first?.at ?? ctx.now, last = i.steps.last?.at ?? ctx.now
        var facts = ["\(i.cause)."]
        if !i.steps.isEmpty { facts.append(i.steps.suffix(3).map(\.label).joined(separator: " → ")) }
        facts.append(i.recovered ? "Back in the game after `\(DiscordTime.duration(last.timeIntervalSince(first)))`" : "Not back yet. SiverSol will try again.")
        m.sky = SkyCard(accent: i.recovered ? good : bad, headline: i.recovered ? "Back in the game" : "Roblox is not back yet",
                        context: context(["incident", "\(DiscordTime.tag(first, "t"))"], origin: ctx.origin),
                        facts: facts, footer: footer(ctx.profileName),
                        art: SkyArt(thumb: .symbol(i.recovered ? "checkmark" : "bolt.horizontal", i.recovered ? good : bad), preview: ctx.origin != .live))
        return m
    }

    public static func macro(_ e: MacroEvent, _ ctx: RenderContext, hasProof: Bool = false) -> DiscordMessage {
        var m = classicMacro(e, ctx, hasProof: hasProof)
        let headline: String, tint: Int, symbol: String
        var facts: [String] = []
        switch e.kind {
        case .started:
            headline = "Macro started: \(e.name)"; tint = calm; symbol = "play.fill"
            if e.steps > 0 { facts.append("`\(e.steps)` steps") }
        case .finished:
            headline = "Macro finished: \(e.name)"; tint = good; symbol = "flag.fill"
            facts.append("`\(e.loops)` loop\(e.loops == 1 ? "" : "s") in `\(DiscordTime.duration(e.durationS))`")
        case .stopped:
            headline = "Macro stopped: \(e.name)"; tint = e.guardianStop ? bad : warn; symbol = "stop.fill"
            facts.append(e.reason.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Stopped")
            if e.guardianStop { facts.append("Guardian stopped it. Every key and button was released" + (hasProof ? "; the picture shows what it saw." : ".")) }
            facts.append("Ran for `\(DiscordTime.duration(e.durationS))`, `\(e.loops)` loop\(e.loops == 1 ? "" : "s") done")
        case .recorded:
            headline = "Macro recorded: \(e.name)"; tint = calm; symbol = "record.circle"
            facts.append("`\(DiscordTime.duration(e.durationS))` long, `\(e.steps)` steps")
        }
        m.sky = SkyCard(accent: tint, headline: headline, context: context(["macro studio", e.trigger], origin: ctx.origin),
                        facts: facts, footer: footer(ctx.profileName), art: SkyArt(thumb: .symbol(symbol, tint), preview: ctx.origin != .live))
        return m
    }

    /// A plain note (updates, memory, reminders). The classic title's emoji and markdown bold are left out of the card.
    public static func info(title: String, text: String, color: Int = 0x5865F2, origin: EventOrigin = .live, now: Date = Date(), profile: String? = nil) -> DiscordMessage {
        var m = classicInfo(title: title, text: text, color: color, origin: origin, now: now)
        let lines = text.replacingOccurrences(of: "**", with: "").split(whereSeparator: \.isNewline).map(String.init)
        m.sky = SkyCard(accent: color == 0x5865F2 ? calm : color, headline: plain(title), context: context(["status"], origin: origin),
                        facts: lines, footer: footer(profile), art: SkyArt(thumb: .symbol("info", color == 0x5865F2 ? calm : color), preview: origin != .live))
        return m
    }

    public static func connected(route: RouteConfig, webhookName: String?, channelId: String?, catalog: BiomeCatalog, now: Date = Date(), profile: String? = nil) -> DiscordMessage {
        var m = classicConnected(route: route, webhookName: webhookName, channelId: channelId, catalog: catalog, now: now)
        var gets: [String] = []
        if route.wants(.biome) { gets.append("biome changes") }
        if route.wants(.aura) { gets.append("auras and rolls") }
        if route.wants(.merchant) { gets.append("merchants") }
        if route.wants(.incident) { gets.append("disconnects") }
        if route.wants(.daily) { gets.append("a daily report") }
        if route.wants(.liveCard) { gets.append("one live session card") }
        let place = channelId.map { "<#\($0)>" } ?? "this channel"
        m.sky = SkyCard(accent: good, headline: "SiverSol is connected",
                        context: "connection test · route `\(route.name)`",
                        facts: ["This webhook works. Cards for this route will arrive in \(place).",
                                gets.isEmpty ? "Nothing is turned on for this route yet." : "You will get: \(gets.joined(separator: ", ")).",
                                "Rare biomes \(route.pingsEnabled ? "ping" : "do not ping") on this route."],
                        footer: footer(profile),
                        art: SkyArt(thumb: .symbol("checkmark", good), card: .banner(title: "Connected", line: "the sky is being watched", biome: nil), preview: false, hour: hour(now)))
        return m
    }

    // MARK: digest

    /// The "Biome feed": one message an hour for the ordinary biomes of a route in Digest mode.
    public static func biomeFeed(_ entries: [DigestEntry], hourStart: Date, _ ctx: RenderContext) -> DiscordMessage {
        let sorted = entries.sorted { $0.at < $1.at }
        var counts: [String: Int] = [:]
        for e in sorted { counts[e.biome, default: 0] += 1 }
        func name(_ key: String) -> String { ctx.catalog.info(for: BiomeKey(key)).display }
        let tally = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { "\(name($0.key)) ×\($0.value)" }.joined(separator: " · ")
        func line(_ e: DigestEntry) -> String {
            "\(DiscordTime.tag(e.at, "t")) \(name(e.biome))" + (e.endedAt.map { " · \(DiscordTime.duration($0.timeIntervalSince(e.at)))" } ?? " · on now")
        }
        // Classic: the whole hour, one line a biome (the newest at the top, as many as fit).
        var description = ""
        for e in sorted.reversed() {
            let next = line(e) + "\n"
            if description.count + next.count > 3800 { description += "…"; break }
            description += next
        }
        var m = DiscordMessage(content: "", username: username,
                               embeds: [Embed(title: ctx.origin.titlePrefix + "🗞 Biome feed · \(sorted.count) biome\(sorted.count == 1 ? "" : "s")",
                                              description: description, color: blurple, fields: [.init("This hour", tally, inline: false)], timestamp: hourStart)],
                               allowedMentions: .none)
        // Card: three lines. What is on now, the latest few, and the hour's tally.
        let latest = sorted.reversed().prefix(4).map(line).joined(separator: " · ")
        let current = sorted.last.flatMap { $0.endedAt == nil ? $0 : nil }
        let info = ctx.catalog.info(for: BiomeKey(current?.biome ?? sorted.last?.biome ?? "NORMAL"))
        m.sky = SkyCard(accent: accent(info), headline: "Biome feed",
                        context: context(["digest", "the hour from \(DiscordTime.tag(hourStart, "t"))", "\(sorted.count) biome\(sorted.count == 1 ? "" : "s")"], origin: ctx.origin),
                        facts: [current.map { "On now: \(name($0.biome)) since \(DiscordTime.tag($0.at, "R"))" } ?? "Nothing on right now",
                                "Latest: \(latest)", tally],
                        footer: footer(ctx.profileName),
                        art: SkyArt(thumb: .biome(info.key.value), preview: ctx.origin != .live, hour: hour(sorted.last?.at ?? hourStart)))
        return m
    }

    // MARK: the live session card

    public static func liveCard(_ s: LiveCardState, catalog: BiomeCatalog, auras: AuraCatalog? = nil, profile: String? = nil) -> DiscordMessage {
        var m = classicLiveCard(s, catalog: catalog, auras: auras)
        let ended = s.endedAt != nil
        var headline = ended ? "Session ended" : "Watching the horizon"
        var color = calm
        var first = "No biome yet"
        if let b = s.biome {
            let info = catalog.info(for: b.key)
            if !ended { headline = info.display; color = accent(info) }
            if let since = s.biomeSince {
                if let d = info.durationS, s.biomeStartObserved {
                    first = "\(ended ? info.display + " · " : "")ends \(DiscordTime.tag(since.addingTimeInterval(TimeInterval(d)), "R"))"
                } else {
                    first = "\(ended ? info.display + " · " : "")since \(DiscordTime.tag(since, "R"))"
                }
            }
        }
        var second = ["watching for `\(DiscordTime.duration((s.endedAt ?? s.now).timeIntervalSince(s.sessionStartedAt)))`", "Roblox \(s.health)"]
        if let id = s.serverJobId { second.append("server `\(id.prefix(8))`") }
        if let res = s.resourceLine { second.append("`\(res)`") }
        if let coverage = s.coverageLine { second = ["hunt coverage `\(coverage)`"] + second.prefix(2) }
        var third: [String] = []
        if let a = s.lastAura { third.append("aura \(auras?.display(for: a) ?? AuraName.display(a))" + (s.lastAuraAt.map { " \(DiscordTime.tag($0, "R"))" } ?? "")) }
        if let r = s.lastRoll { third.append("roll \(r)" + (s.lastRollAt.map { " \(DiscordTime.tag($0, "R"))" } ?? "")) }
        if let me = s.lastMerchant { third.append("\(me)" + (s.lastMerchantAt.map { " \(DiscordTime.tag($0, "R"))" } ?? "")) }
        if let macro = s.macroLine { third.append("macro \(macro)") }
        m.sky = SkyCard(accent: ended ? 0x8D99AE : color, headline: headline,
                        context: "live session · updated \(DiscordTime.tag(s.now, "R")) · started \(DiscordTime.tag(s.sessionStartedAt, "t"))",
                        facts: [first.prefix(1).uppercased() + first.dropFirst(), second.joined(separator: " · ").prefix(1).uppercased() + second.joined(separator: " · ").dropFirst(),
                                third.isEmpty ? "" : "Last: " + third.joined(separator: " · ")],
                        footer: footer(profile))
        return m
    }
}
