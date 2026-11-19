import SiverCore
import SiverNotify
import SwiftUI

/// Draws a `DiscordMessage` the way Discord would, so a route can be checked without posting anything.
struct EmbedPreview: View {
    let message: DiscordMessage
    @Environment(\.colorScheme) private var scheme

    private var chat: Color { scheme == .dark ? Color(hex: 0x313338) : Color(hex: 0xFFFFFF) }
    private var embedFill: Color { scheme == .dark ? Color(hex: 0x2B2D31) : Color(hex: 0xF2F3F5) }
    private var text: Color { scheme == .dark ? Color(hex: 0xDBDEE1) : Color(hex: 0x313338) }
    private var muted: Color { scheme == .dark ? Color(hex: 0x949BA4) : Color(hex: 0x5C5E66) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(Color(hex: 0x5865F2)).frame(width: 38, height: 38)
                .overlay(Image(systemName: "sparkles").foregroundStyle(.white))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(message.username ?? "SiverSol").fontWeight(.semibold).foregroundStyle(text)
                    Text("APP").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1).background(Color(hex: 0x5865F2), in: RoundedRectangle(cornerRadius: 3))
                    Text("Today at \(Date().formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(muted)
                }
                if let content = message.content, !content.isEmpty {
                    Text(Self.markdown(content)).foregroundStyle(text)
                }
                ForEach(Array(message.embeds.enumerated()), id: \.offset) { _, embed in embedView(embed) }
                if let rows = message.components {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack {
                            ForEach(Array(row.components.enumerated()), id: \.offset) { _, button in
                                Label(button.label, systemImage: "arrow.up.right.square")
                                    .font(.callout.weight(.medium)).foregroundStyle(text)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(muted.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(chat, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview of the Discord message")
    }

    private func embedView(_ e: Embed) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color(hex: e.color ?? 0x99AAB5)).frame(width: 4)
            VStack(alignment: .leading, spacing: 8) {
                if let title = e.title { Text(Self.markdown(title)).font(.headline).foregroundStyle(text) }
                if let d = e.description { Text(Self.markdown(d)).font(.callout).foregroundStyle(text).fixedSize(horizontal: false, vertical: true) }
                if let fields = e.fields, !fields.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .topLeading)], alignment: .leading, spacing: 8) {
                        ForEach(Array(fields.enumerated()), id: \.offset) { _, f in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.name).font(.caption.weight(.semibold)).foregroundStyle(text)
                                Text(Self.markdown(f.value)).font(.callout).foregroundStyle(text).fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if e.image != nil {
                    RoundedRectangle(cornerRadius: 6).fill(muted.opacity(0.2)).frame(height: 90)
                        .overlay(Label("screenshot or chart", systemImage: "photo").foregroundStyle(muted))
                }
                if e.footer != nil || e.timestamp != nil {
                    Text([e.footer?.text, e.timestamp == nil ? nil : "event time"].compactMap { $0 }.joined(separator: " • "))
                        .font(.caption).foregroundStyle(muted)
                }
            }
            .padding(12)
            .frame(maxWidth: 480, alignment: .leading)
        }
        .background(embedFill)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    /// Discord markdown, close enough for a preview: bold, links, code, and `<t:…>` time tags.
    static func markdown(_ source: String) -> AttributedString {
        var s = source
        // <t:1795000000:R> -> a readable time
        while let open = s.range(of: "<t:"), let close = s.range(of: ">", range: open.upperBound..<s.endIndex) {
            let parts = s[open.upperBound..<close.lowerBound].split(separator: ":")
            let date = parts.first.flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) } ?? Date()
            let style = parts.count > 1 ? String(parts[1]) : "f"
            let shown: String
            switch style {
            case "R": shown = date.formatted(.relative(presentation: .named))
            case "T", "t": shown = date.formatted(date: .omitted, time: .shortened)
            default: shown = date.formatted(date: .abbreviated, time: .shortened)
            }
            s.replaceSubrange(open.lowerBound..<close.upperBound, with: shown)
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }
}

/// Sample messages for the preview. They are built by the real templates from made-up events and are only drawn
/// on screen; nothing here is ever sent.
enum PreviewSamples {
    enum Kind: String, CaseIterable, Identifiable {
        case biomeStarted = "Biome started", rareStarted = "Rare biome started", biomeEnded = "Biome ended",
             aura = "New aura", auraRolled = "Aura rolled (cutscene)", merchant = "Merchant", newBiome = "New biome seen",
             incident = "Disconnect and rejoin", liveCard = "Live session card", daily = "Daily report",
             macro = "Macro finished", connected = "Connection test"
        var id: String { rawValue }
        var event: EventKind {
            switch self {
            case .biomeStarted, .rareStarted, .biomeEnded: return .biome
            case .aura, .auraRolled: return .aura
            case .merchant: return .merchant
            case .newBiome: return .newBiome
            case .incident: return .incident
            case .liveCard: return .liveCard
            case .daily: return .daily
            case .macro: return .macros
            case .connected: return .status
            }
        }
    }

    static let placeholderLink = "https://www.roblox.com/share?code=YOUR-CODE&type=Server"

    /// The kinds a route would actually receive.
    static func kinds(for route: RouteConfig) -> [Kind] {
        if route.profile == .huntCompat { return route.wants(.biome) ? [.biomeStarted, .rareStarted, .biomeEnded] : [] }
        return Kind.allCases.filter { $0 == .connected || route.wants($0.event) }
    }

    static func message(_ kind: Kind, route: RouteConfig, catalog: BiomeCatalog, auras: AuraCatalog, hasServerLink: Bool) -> DiscordMessage? {
        let now = Date()
        let job = "0f3a9c1e-sample"
        var ctx = RenderContext(catalog: catalog, route: route, origin: .live, serverLink: hasServerLink ? placeholderLink : nil,
                                todayCount: { _ in 3 }, sessionStartedAt: now.addingTimeInterval(-5400), now: now)
        ctx.auras = auras
        func started(_ name: String) -> BiomeStarted {
            BiomeStarted(id: "preview-start-\(name)", biome: BiomeRef(raw: name), at: now.addingTimeInterval(-95), observedStart: true,
                         wasRunning: false, serverJobId: job, previous: "NORMAL")
        }
        func ended(_ name: String) -> BiomeEnded {
            BiomeEnded(id: "preview-end-\(name)", biome: BiomeRef(raw: name), startedAt: now.addingTimeInterval(-700), at: now.addingTimeInterval(-5),
                       startedEventId: "preview-start-\(name)", startObserved: true, reason: .changed, next: "NORMAL", serverJobId: job)
        }
        if route.profile == .huntCompat {
            switch kind {
            case .biomeStarted: return HuntTemplates.biomeStarted(started("WINDY"), ctx)
            case .rareStarted: return HuntTemplates.biomeStarted(started("GLITCHED"), ctx)
            case .biomeEnded: return HuntTemplates.biomeEnded(ended("WINDY"), ctx)
            default: return nil
            }
        }
        switch kind {
        case .biomeStarted: return RichTemplates.biomeStarted(started("WINDY"), ctx)
        case .rareStarted:
            var m = RichTemplates.biomeStarted(started("GLITCHED"), ctx)
            if let ping = route.ping(for: "GLITCHED", isRare: true) { m.content = ping.content }
            return m
        case .biomeEnded: return RichTemplates.biomeEnded(ended("WINDY"), ctx)
        case .aura:
            return RichTemplates.aura(AuraEquipped(id: "preview-aura", internalName: "Symphony", at: now, biome: BiomeRef(raw: "WINDY"),
                                                   biomeEventId: nil, initial: false, serverJobId: job), ctx)
        case .auraRolled:
            return RichTemplates.auraRolled(AuraRolled(id: "preview-roll", name: "Symphony", at: now, captureDelayMs: 15000, durationS: 34,
                                                       biome: BiomeRef(raw: "WINDY")), ctx)
        case .merchant: return RichTemplates.merchant(MerchantArrived(id: "preview-merchant", name: "Mari", at: now, biome: BiomeRef(raw: "NORMAL"), source: "screen"), ctx)
        case .newBiome: return RichTemplates.newBiome(NewBiomeSeen(id: "preview-new", biome: BiomeRef(raw: "AURORA"), at: now), ctx)
        case .incident:
            let report = IncidentReport(id: "preview-incident", cause: "Roblox was disconnected",
                                        steps: [.init("noticed the disconnect", at: now.addingTimeInterval(-50)), .init("opened the private server link", at: now.addingTimeInterval(-40)),
                                                .init("clicked Play", at: now.addingTimeInterval(-12)), .init("back in the game", at: now.addingTimeInterval(-5))], recovered: true)
            return RichTemplates.incident(report, ctx)
        case .liveCard:
            var s = LiveCardState(sessionStartedAt: now.addingTimeInterval(-5400), now: now)
            s.biome = BiomeRef(raw: "WINDY"); s.biomeSince = now.addingTimeInterval(-95); s.biomeStartObserved = true
            s.todayCounts = ["WINDY": 3, "RAINY": 2, "SNOWY": 1]
            s.lastAura = "Symphony"; s.lastAuraAt = now.addingTimeInterval(-900)
            s.serverJobId = job
            return RichTemplates.liveCard(s, catalog: catalog, auras: auras)
        case .daily:
            let r = DailyReport(day: TimelineStore.day(now), counts: ["WINDY": 6, "RAINY": 4, "SNOWY": 3, "NORMAL": 13], seconds: ["WINDY": 720, "RAINY": 480, "SNOWY": 360, "NORMAL": 41000],
                                rares: [], uptimeS: 42560, auras: 2, merchants: 3)
            return RichTemplates.dailyReport(r, ctx)
        case .macro:
            var e = MacroEvent(id: "preview-macro", kind: .finished, name: "Walk to the shop", at: now, trigger: "manual")
            e.loops = 3; e.steps = 42; e.durationS = 20
            return RichTemplates.macro(e, ctx)
        case .connected:
            return RichTemplates.connected(route: route, webhookName: "SiverSol", channelId: nil, catalog: catalog, now: now)
        }
    }
}
