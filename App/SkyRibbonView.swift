import AppKit
import SiverCore
import SiverEngine
import SiverNotify
import SiverSky
import SwiftUI

/// The last day of events, turned into a ribbon off the main thread.
@MainActor
final class RibbonModel: ObservableObject {
    static let shared = RibbonModel()
    @Published private(set) var ribbon: SkyRibbon?
    private var loading = false
    private var lastLoad = Date.distantPast

    func reload(model: AppModel, force: Bool = false) {
        guard !loading, force || Date().timeIntervalSince(lastLoad) > 20 else { return }
        loading = true
        lastLoad = Date()
        let catalog = model.catalog, auras = model.auras, running = model.isRunning
        let engineTimeline = model.engine?.timeline
        Task {
            let built = await Task.detached(priority: .utility) { () -> SkyRibbon in
                let now = Date()
                let store = engineTimeline ?? TimelineStore(directory: TimelineStore.defaultDirectory)
                var events: [SiverEvent] = []
                for day in [TimelineStore.day(now.addingTimeInterval(-2 * 86_400)), TimelineStore.day(now.addingTimeInterval(-86_400)), TimelineStore.day(now)] {
                    events += store.events(day: day)
                }
                return SkyRibbon.build(events: events, end: now, open: running, isRare: { catalog.isRare($0) },
                                       auraName: { auras.info(for: $0)?.display ?? AuraName.display($0) })
            }.value
            self.ribbon = built
            self.loading = false
        }
    }
}

/// Sky Ribbon: the last 24 hours as a strip coloured by biome, like a weather radar's timeline.
/// Move the pointer along it (or press and drag) to read any moment; click to open that moment in the Timeline.
struct SkyRibbonCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var data = RibbonModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the pointer is along the ribbon, 0...1; nil when it is elsewhere.
    @State private var scrub: Double?
    @State private var dragDistance: CGFloat = 0
    @State private var a11yFraction = 1.0

    private static let stripHeight: CGFloat = 30
    private static let markerRow: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CardTitle(title: "Sky Ribbon · last 24 hours", symbol: "calendar.day.timeline.left")
                Spacer()
                if let r = data.ribbon {
                    Text("watched \(DiscordTime.duration(r.watchedSeconds))").font(Sky.mono(11.5)).foregroundStyle(.secondary)
                }
            }
            if let ribbon = data.ribbon {
                GeometryReader { geo in strip(ribbon, width: geo.size.width) }
                    .frame(height: Self.markerRow + Self.stripHeight + 18)
                    .accessibilityElement()
                    .accessibilityLabel("Sky Ribbon, the last 24 hours")
                    .accessibilityValue(describe(ribbon, at: ribbon.date(at: a11yFraction)))
                    .accessibilityAdjustableAction { direction in
                        // Half an hour a step.
                        let step = 1800 / max(1, ribbon.seconds)
                        a11yFraction = min(1, max(0, a11yFraction + (direction == .increment ? step : -step)))
                    }
                    .accessibilityHint("Adjust to move through the day")
            } else {
                Text("Reading the day…").foregroundStyle(.secondary).frame(height: 60)
            }
        }
        .card()
        .onAppear { data.reload(model: model, force: true) }
        .task(id: model.recent.first?.id) { data.reload(model: model, force: true) }
        .task(id: model.isRunning) { data.reload(model: model, force: true) }
    }

    private func color(_ key: BiomeKey) -> Color {
        if key.value == "NORMAL" { return Color(hex: 0x6FA8DC).opacity(0.55) }
        return model.catalog.info(for: key).palette.accent.color
    }

    private func strip(_ ribbon: SkyRibbon, width: CGFloat) -> some View {
        let top = Self.markerRow
        return ZStack(alignment: .topLeading) {
            // The strip itself.
            Canvas { ctx, size in
                let rect = CGRect(x: 0, y: top, width: size.width, height: Self.stripHeight)
                let shape = Path(roundedRect: rect, cornerRadius: 8, style: .continuous)
                ctx.fill(shape, with: .color(.primary.opacity(0.08)))
                ctx.clip(to: shape)
                for s in ribbon.segments {
                    let x0 = ribbon.fraction(s.start) * size.width, x1 = ribbon.fraction(s.end) * size.width
                    let r = CGRect(x: x0, y: top, width: max(s.rare ? 2.5 : 1, x1 - x0), height: Self.stripHeight)
                    ctx.fill(Path(r), with: .color(color(s.biome)))
                    if s.rare { ctx.stroke(Path(r.insetBy(dx: -0.5, dy: 0.75)), with: .color(.white.opacity(0.9)), lineWidth: 1.5) }
                }
                // Hour ticks, on local clock hours.
                var cal = Calendar.current
                cal.timeZone = .current
                var tick = cal.nextDate(after: ribbon.start, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? ribbon.start
                while tick < ribbon.end {
                    let hour = cal.component(.hour, from: tick)
                    let x = ribbon.fraction(tick) * size.width
                    ctx.fill(Path(CGRect(x: x, y: top + Self.stripHeight - (hour % 3 == 0 ? 8 : 4), width: 1, height: hour % 3 == 0 ? 8 : 4)), with: .color(.black.opacity(0.35)))
                    tick = tick.addingTimeInterval(3600)
                }
            }
            .allowsHitTesting(false)

            // Marks above it: a glyph for a rare biome, a sparkle for a roll, a cart for a merchant.
            ForEach(ribbon.markers) { m in
                marker(m).position(x: min(width - 8, max(8, ribbon.fraction(m.at) * width)), y: top / 2)
            }

            // Hour labels under it.
            ForEach(labels(ribbon), id: \.0) { date, text in
                Text(text).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary).fixedSize()
                    .position(x: min(width - 16, max(16, ribbon.fraction(date) * width)), y: top + Self.stripHeight + 10)
            }
            Text("now").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary).fixedSize()
                .position(x: width - 12, y: top + Self.stripHeight + 10)

            // The scrub line and its bubble.
            if let scrub {
                let x = scrub * width
                Rectangle().fill(Color.primary).frame(width: 1.5, height: Self.stripHeight + 8).position(x: x, y: top + Self.stripHeight / 2)
                bubble(ribbon, at: ribbon.date(at: scrub))
                    .fixedSize()
                    .position(x: min(width - 110, max(110, x)), y: -24)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): scrub = min(1, max(0, p.x / max(1, width)))
            case .ended: scrub = nil
            }
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                scrub = min(1, max(0, g.location.x / max(1, width)))
                dragDistance = max(dragDistance, abs(g.translation.width))
            }
            .onEnded { g in
                // A click (no real drag) opens that moment in the Timeline.
                if dragDistance < 4 { model.showInTimeline(ribbon.date(at: min(1, max(0, g.location.x / max(1, width))))) }
                dragDistance = 0
            })
        .help("Move along the ribbon to read the day. Click to open that moment in the Timeline.")
    }

    @ViewBuilder private func marker(_ m: RibbonMarker) -> some View {
        switch m.kind {
        case .rareBiome:
            if let key = m.biome {
                BiomeGlyph(info: model.catalog.info(for: key), size: 13).foregroundStyle(model.catalog.info(for: key).palette.accent.color)
                    .shadow(color: .black.opacity(0.4), radius: 1)
            }
        case .roll: Image(systemName: "sparkle").font(.system(size: 10, weight: .bold)).foregroundStyle(.yellow).shadow(color: .black.opacity(0.4), radius: 1)
        case .merchant: Image(systemName: "cart.fill").font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
    }

    /// One label every three hours, on the clock hour.
    private func labels(_ ribbon: SkyRibbon) -> [(Date, String)] {
        var out: [(Date, String)] = []
        let cal = Calendar.current
        var tick = cal.nextDate(after: ribbon.start, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? ribbon.start
        while tick < ribbon.end.addingTimeInterval(-3600) {
            if cal.component(.hour, from: tick) % 3 == 0 { out.append((tick, tick.formatted(.dateTime.hour()))) }
            tick = tick.addingTimeInterval(3600)
        }
        return out
    }

    private func describe(_ ribbon: SkyRibbon, at date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        guard let s = ribbon.segment(at: date) else { return "\(time): not watching" }
        var text = "\(time): \(s.biome.value), for \(DiscordTime.duration(s.seconds))"
        for m in ribbon.markers(near: date, within: 900).prefix(2) { text += ". \(m.title)" }
        return text
    }

    private func bubble(_ ribbon: SkyRibbon, at date: Date) -> some View {
        let segment = ribbon.segment(at: date)
        let near = ribbon.markers(near: date, within: max(240, ribbon.seconds * 0.006))
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let segment {
                    BiomeGlyph(info: model.catalog.info(for: segment.biome), size: 13).foregroundStyle(color(segment.biome))
                    Text(segment.biome.value).font(Sky.display(13, .bold))
                } else {
                    Image(systemName: "moon.zzz").font(.caption)
                    Text("Not watching").font(Sky.display(13, .bold))
                }
                Text(date.formatted(date: .omitted, time: .shortened)).font(Sky.mono(11)).foregroundStyle(.secondary)
            }
            if let segment {
                Text("\(segment.start.formatted(date: .omitted, time: .shortened)) to \(segment.end.formatted(date: .omitted, time: .shortened)) · \(DiscordTime.duration(segment.seconds))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(near.prefix(2)) { m in
                Label(m.title, systemImage: m.kind == .merchant ? "cart.fill" : (m.kind == .roll ? "sparkle" : "star.fill")).font(.caption)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        .allowsHitTesting(false)
    }
}

/// Session Wrapped on the Dashboard: the newest card, and a button to draw one now.
struct WrappedCardPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var latest: URL?
    @State private var image: NSImage?
    @State private var busy = false
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(title: "Session Wrapped", symbol: "sparkles.rectangle.stack")
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        RoundedRectangle(cornerRadius: 8).fill(Sky.dusk).overlay(Image(systemName: "sparkles").font(.title2).foregroundStyle(.white.opacity(0.7)))
                    }
                }
                .frame(width: 92, height: 115)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.2)))
                .accessibilityLabel(latest == nil ? "No card yet" : "The newest Session Wrapped card")
                VStack(alignment: .leading, spacing: 6) {
                    Text(latest == nil ? "A recap card of your session: time under the sky, biome mix, rarest roll." : "Your newest recap card. One is drawn each time a session ends.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(busy ? "Drawing…" : "Make one now") { make() }.disabled(busy)
                        if let latest {
                            Button { NSWorkspace.shared.activateFileViewerSelecting([latest]) } label: { Image(systemName: "magnifyingglass") }
                                .help("Reveal in Finder").accessibilityLabel("Reveal the card in Finder")
                            Button { copy() } label: { Image(systemName: "doc.on.doc") }.help("Copy the picture").accessibilityLabel("Copy the card")
                        }
                    }
                    if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .task { await load() }
        .task(id: model.wrappedStamp) { await load() }
    }

    private func load() async {
        let dir = SiverEngine.wrappedDirectory
        let found = await Task.detached(priority: .utility) { () -> (URL, NSImage)? in
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("Wrapped-") && $0.hasSuffix(".png") }.sorted()
            guard let last = names.last else { return nil }
            let url = dir.appendingPathComponent(last)
            return NSImage(contentsOf: url).map { (url, $0) }
        }.value
        latest = found?.0
        image = found?.1
    }

    private func make() {
        busy = true
        note = ""
        Task {
            let url = await model.makeWrappedNow()
            busy = false
            note = url == nil ? "Could not draw the card." : "Saved \(url!.lastPathComponent)"
            await load()
        }
    }

    private func copy() {
        guard let image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        note = "Copied."
    }
}
