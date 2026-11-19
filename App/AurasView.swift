import AppKit
import MetalKit
import SiverCore
import SiverNotify
import SiverSky
import SwiftUI

/// The collection, built off the main thread from everything the timeline has recorded.
@MainActor
final class SolDexModel: ObservableObject {
    static let shared = SolDexModel()
    @Published private(set) var dex: SolDex?
    private var loading = false

    func reload(catalog: AuraCatalog) {
        guard !loading else { return }
        loading = true
        Task {
            let built = await Task.detached(priority: .userInitiated) { () -> SolDex in
                let store = TimelineStore(directory: TimelineStore.defaultDirectory)
                var events: [SiverEvent] = []
                for day in store.availableDays {
                    events += store.events(day: day).filter {
                        switch $0 { case .auraEquipped, .auraRolled: return true; default: return false }
                    }
                }
                return SolDex.build(catalog: catalog, events: events)
            }.value
            if built != self.dex { self.dex = built }
            self.loading = false
        }
    }
}

/// Sol Dex: every aura as a trading card. Cards you have rolled or equipped are lit, with a foil that climbs
/// with the tier; the rest wait as dark silhouettes with their odds.
/// SiverSol only reads which aura is equipped: it never opens Aura Storage and never changes an aura.
struct AurasView: View {
    enum Show: String, CaseIterable, Identifiable { case all = "All", collected = "Collected", missing = "Missing"; var id: String { rawValue } }

    @EnvironmentObject var model: AppModel
    @ObservedObject private var library = SolDexModel.shared
    @State private var search = ""
    @State private var tier: DexTier?
    @State private var biome = ""
    @State private var show: Show = .all
    @State private var selected: DexCard?

    var body: some View {
        Page {
            SectionHeader(title: "Sol Dex", subtitle: "Every aura you have rolled or equipped becomes a card. SiverSol only reads which aura is equipped: it never opens Aura Storage and never changes an aura.")
            if let dex = library.dex {
                HStack(alignment: .top, spacing: 16) {
                    spotlight(dex)
                    summary(dex)
                }
                // Rare sky surprises that were seen: their own "Secret" tier, never counted as auras.
                SecretCardsSection()
                filters(dex)
                let cards = filtered(dex)
                if cards.isEmpty {
                    ContentUnavailableView {
                        Label(search.isEmpty ? "Nothing here yet" : "No aura called “\(search)”", systemImage: "rectangle.stack")
                    } description: {
                        Text(show == .collected && dex.seen.isEmpty ? "Your first card appears with your next roll." : "Try a different filter.")
                    }
                    .frame(maxWidth: .infinity, minHeight: 180).card()
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 190), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                        ForEach(cards) { card in
                            Button { selected = card } label: { DexCardView(card: card, bottom: bottomTint(card)) }
                                .buttonStyle(PressStyle())
                                .popover(isPresented: Binding(get: { selected?.id == card.id }, set: { if !$0 { selected = nil } }), arrowEdge: .trailing) {
                                    DexDetail(card: card)
                                }
                        }
                    }
                }
                Text("Aura names and odds: Sol's RNG Wiki, licensed CC BY-SA. Card art is drawn by SiverSol.").font(.caption)
                    .foregroundStyle(SkyState.shared.look.ink.color.opacity(0.85))
            } else {
                ProgressView("Sorting the cards…").frame(maxWidth: .infinity, minHeight: 200).card()
            }
        }
        .onAppear {
            library.reload(catalog: model.auras)
            if model.reviewNote.hasPrefix("dex:") { search = String(model.reviewNote.dropFirst(4)) }
        }
        .task(id: model.recent.first?.id) { library.reload(catalog: model.auras) }
    }

    // MARK: pieces

    private func spotlight(_ dex: SolDex) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "Rarest ever", symbol: "crown.fill")
            if let rarest = dex.rarest {
                DexCardView(card: rarest, bottom: bottomTint(rarest), alwaysLive: true)
                    .frame(width: 190)
                    .frame(maxWidth: .infinity)
            } else {
                Text("Your rarest roll gets pride of place here.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 150)
            }
        }
        .card()
        .frame(width: 236)
    }

    private func summary(_ dex: SolDex) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "Collection", symbol: "rectangle.stack.fill")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(dex.collected)").font(Sky.display(40)).contentTransition(.numericText())
                Text("of \(dex.collectable.count) collected").foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f%%", dex.completion * 100)).font(Sky.mono(15)).foregroundStyle(.secondary)
            }
            ProgressView(value: dex.completion).tint(Sky.steel)
                .accessibilityLabel("Collection complete").accessibilityValue(String(format: "%.1f percent", dex.completion * 100))
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                ForEach(dex.byTier, id: \.tier) { row in
                    GridRow {
                        HStack(spacing: 6) {
                            Circle().fill(row.tier.color.color).frame(width: 8, height: 8)
                            Text(row.tier.rawValue).font(.callout)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.10))
                                Capsule().fill(row.tier.color.color.gradient).frame(width: row.total == 0 ? 0 : max(row.seen == 0 ? 0 : 4, geo.size.width * CGFloat(row.seen) / CGFloat(row.total)))
                            }
                        }
                        .frame(height: 6)
                        Text("\(row.seen) / \(row.total)").font(Sky.mono(11)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(row.tier.rawValue): \(row.seen) of \(row.total)")
                }
            }
            if let equipped = model.isRunning ? model.snapshot.equippedAura : nil {
                Divider()
                KeyValueRow(label: "Equipped now", value: model.auras.display(for: equipped))
            }
        }
        .card()
    }

    private func filters(_ dex: SolDex) -> some View {
        ControlStrip {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Search auras", text: $search).textFieldStyle(.plain).frame(minWidth: 120)
            Picker("Show", selection: $show) { ForEach(Show.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 230)
            Picker("Tier", selection: $tier) {
                Text("Every tier").tag(DexTier?.none)
                ForEach(dex.byTier.map(\.tier), id: \.self) { Text($0.rawValue).tag(DexTier?.some($0)) }
            }
            .frame(width: 170)
            Picker("Biome", selection: $biome) {
                Text("Any biome").tag("")
                ForEach(biomes(dex), id: \.self) { Text($0).tag($0) }
            }
            .frame(width: 190)
        }
    }

    /// Biomes that matter to at least one card: where an aura is native, the only place it rolls, or where it came.
    private func biomes(_ dex: SolDex) -> [String] {
        var out = Set<String>()
        for c in dex.cards { for b in [c.nativeBiome, c.onlyIn, c.biome] { if let b { out.insert(b) } } }
        return out.sorted()
    }

    private func filtered(_ dex: SolDex) -> [DexCard] {
        dex.cards.filter { c in
            if show == .collected && !c.seen { return false }
            if show == .missing && c.seen { return false }
            if let tier, c.tier != tier { return false }
            if !biome.isEmpty, ![c.nativeBiome, c.onlyIn, c.biome].contains(biome) { return false }
            if !search.isEmpty, !c.display.localizedCaseInsensitiveContains(search), !c.tierLabel.localizedCaseInsensitiveContains(search) { return false }
            return true
        }
        // Your own cards come first, rarest at the front; the silhouettes follow in tier order.
        .sorted { a, b in
            if a.seen != b.seen { return a.seen }
            guard a.seen else { return false }
            return (a.chance ?? 0) > (b.chance ?? 0)
        }
    }

    /// The lower colour of a card: the accent of the aura's own biome when the catalog names one.
    private func bottomTint(_ card: DexCard) -> RGB {
        let wanted = [card.nativeBiome, card.onlyIn, card.biome].compactMap { $0 }.first.map(AuraCatalog.key)
        if let wanted, let info = model.catalog.all.first(where: { AuraCatalog.key($0.key.value) == wanted }) { return info.palette.accent }
        return card.tier.color.mix(RGB(hex: 0x1E2F8F), 0.5)
    }
}

/// One trading card.
struct DexCardView: View {
    let card: DexCard
    let bottom: RGB
    /// The spotlight card keeps its foil moving even when the pointer is elsewhere.
    var alwaysLive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tilt = CGPoint.zero
    @State private var hovering = false
    /// True once the pointer has rested on the card for a moment. The moving foil is a Metal view; cards that
    /// only pass under the pointer (a fast scroll, a sweep across the grid) never start one.
    @State private var settled = false

    private var face: FoilCard {
        // Silhouettes share a handful of emblems; a lit card always has its own.
        FoilCard(level: card.foil, top: card.tier.color, bottom: bottom, seed: card.seen ? SolDex.seed(card.id) : SolDex.seed(card.id) % 12, seen: card.seen)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        let live = card.seen && card.foil == .prismatic && !reduceMotion && ((hovering && settled) || alwaysLive) && FoilCanvas.renderer != nil
        ZStack {
            FoilFace(card: face)
            if live {
                LiveFoil(card: face, tilt: tilt).transition(.opacity)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top) {
                    Text(card.tierLabel.uppercased()).font(.system(size: 8.5, weight: .heavy)).tracking(1.1)
                    Spacer(minLength: 4)
                    Text(card.chance.map { "1 in \(Self.compact($0))" } ?? "?").font(Sky.mono(8.5, .semibold))
                }
                .opacity(card.seen ? 0.95 : 0.6)
                Spacer(minLength: 0)
                Text(card.display).font(Sky.display(13.5, .bold)).lineLimit(2).minimumScaleFactor(0.75).multilineTextAlignment(.leading)
                    .opacity(card.seen ? 1 : 0.62)
                Text(caption).font(.system(size: 9.5, weight: .medium)).opacity(card.seen ? 0.85 : 0.5).lineLimit(1)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
            .padding(.horizontal, 11).padding(.vertical, 10)
        }
        .aspectRatio(0.73, contentMode: .fit)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(card.seen ? 0.22 : 0.08), lineWidth: 0.75))
        .shadow(color: card.seen ? card.tier.color.color.opacity(hovering ? 0.55 : 0.25) : .black.opacity(0.2), radius: hovering ? 12 : 5, y: 3)
        // Pointer-reactive tilt: the card leans towards the pointer.
        .rotation3DEffect(.degrees(reduceMotion || !card.seen ? 0 : Double(tilt.x) * 7), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        .rotation3DEffect(.degrees(reduceMotion || !card.seen ? 0 : Double(-tilt.y) * 6), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
        .scaleEffect(hovering && !reduceMotion ? 1.03 : 1)
        .animation(reduceMotion ? nil : Sky.spring, value: hovering)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let p):
                hovering = true
                // The card is about 160 by 220 points; map the pointer to -1...1 on each axis.
                tilt = CGPoint(x: min(1, max(-1, (p.x - 80) / 80)), y: min(1, max(-1, (p.y - 110) / 110)))
            case .ended:
                hovering = false
                withAnimation(reduceMotion ? nil : Sky.spring) { tilt = .zero }
            }
        }
        .task(id: hovering) {
            guard hovering else { settled = false; return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            if !Task.isCancelled { settled = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(card.display), \(card.tierLabel), \(card.odds). \(card.seen ? "Collected \(card.count) time\(card.count == 1 ? "" : "s")" : "Not seen yet")")
        .accessibilityAddTraits(.isButton)
    }

    private var caption: String {
        guard card.seen, let first = card.firstSeen else { return "not seen yet" }
        var parts = ["× \(card.count)", first.formatted(.dateTime.day().month(.abbreviated))]
        if let b = card.biome { parts.append(b.capitalized) }
        return parts.joined(separator: " · ")
    }

    /// 445000 -> "445K", 400000000 -> "400M": the full number is in the card's detail.
    static func compact(_ n: Int) -> String {
        func trim(_ x: Double, _ unit: String) -> String {
            let s = x >= 100 || x == x.rounded() ? String(format: "%.0f", x) : String(format: "%.1f", x)
            return s + unit
        }
        if n >= 1_000_000_000 { return trim(Double(n) / 1_000_000_000, "B") }
        if n >= 1_000_000 { return trim(Double(n) / 1_000_000, "M") }
        if n >= 10_000 { return trim(Double(n) / 1_000, "K") }
        return AuraCatalog.grouped(n)
    }
}

/// Everything the catalog and the timeline know about one aura.
struct DexDetail: View {
    let card: DexCard
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.display).font(Sky.display(20, .bold))
            HStack(spacing: 6) {
                Circle().fill(card.tier.color.color).frame(width: 9, height: 9)
                Text(card.tierLabel).fontWeight(.medium)
                Text("· \(card.foil.name) foil").foregroundStyle(.secondary)
            }
            Divider()
            KeyValueRow(label: "Odds", value: card.odds)
            if let b = card.nativeBiome { KeyValueRow(label: "Native biome", value: b) }
            if let b = card.onlyIn { KeyValueRow(label: "Only in", value: b) }
            if card.seen {
                KeyValueRow(label: "Collected", value: "\(card.count) time\(card.count == 1 ? "" : "s")")
                if let d = card.firstSeen { KeyValueRow(label: "First seen", value: d.formatted(date: .abbreviated, time: .shortened)) }
                if let d = card.lastSeen, d != card.firstSeen { KeyValueRow(label: "Last seen", value: d.formatted(date: .abbreviated, time: .shortened)) }
                if let b = card.biome { KeyValueRow(label: "Came in", value: b) }
            } else {
                Text("Not seen yet. It lights up the first time you roll or equip it while SiverSol is watching.").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = card.note { Text(note).font(.callout).foregroundStyle(.secondary) }
        }
        .padding(16)
        .frame(width: 300)
    }
}

// MARK: card faces

/// Still card faces, drawn once by the foil renderer and kept while there is room.
enum FoilCanvas {
    static let renderer = FoilRenderer.shared
    static let size = CGSize(width: 190, height: 260)
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 70 * 1024 * 1024
        return c
    }()

    static func key(_ c: FoilCard) -> NSString {
        "\(c.level.rawValue)|\(c.top.hex)|\(c.bottom.hex)|\(c.seed)|\(c.seen)" as NSString
    }

    static func cached(_ card: FoilCard) -> NSImage? { cache.object(forKey: key(card)) }

    static func render(_ card: FoilCard, scale: CGFloat) -> NSImage? {
        guard let renderer, let cg = renderer.image(card, size: size, scale: scale) else { return nil }
        let image = NSImage(cgImage: cg, size: size)
        cache.setObject(image, forKey: key(card), cost: cg.width * cg.height * 4)
        return image
    }
}

/// A still card face.
struct FoilFace: View {
    let card: FoilCard
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image = image ?? FoilCanvas.cached(card) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                // Until the face is drawn (or on a Mac without Metal): the tier's colours, plainly.
                LinearGradient(colors: card.seen ? [card.top.scaled(0.46).color, card.bottom.scaled(0.2).color] : [Color(white: 0.07), Color(white: 0.035)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .task(id: FoilCanvas.key(card) as String) {
            if let hit = FoilCanvas.cached(card) { image = hit; return }
            let scale = min(2, NSScreen.main?.backingScaleFactor ?? 2)
            let card = self.card
            image = await Task.detached(priority: .userInitiated) { FoilCanvas.render(card, scale: scale) }.value
        }
    }
}

/// A moving card face for the card under the pointer: the prismatic foil flows and follows the tilt.
private struct LiveFoil: NSViewRepresentable {
    let card: FoilCard
    let tilt: CGPoint

    func makeNSView(context: Context) -> LiveFoilView { LiveFoilView() }
    func updateNSView(_ view: LiveFoilView, context: Context) {
        var c = card
        c.tiltX = Double(tilt.x); c.tiltY = Double(tilt.y); c.animated = true
        view.card = c
    }
}

final class LiveFoilView: MTKView, MTKViewDelegate {
    var card: FoilCard?
    private let started = CACurrentMediaTime()

    init() {
        super.init(frame: .zero, device: FoilCanvas.renderer?.device)
        colorPixelFormat = FoilRenderer.pixelFormat
        preferredFramesPerSecond = SkyMetalView.framesPerSecond
        framebufferOnly = true
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isPaused = window == nil
    }

    func draw(in view: MTKView) {
        guard let card, let renderer = FoilCanvas.renderer, let drawable = currentDrawable, let pass = currentRenderPassDescriptor,
              let buffer = renderer.makeCommandBuffer(), bounds.width > 0 else { return }
        // Drawn in the same 190-point design space as the still faces, whatever size the card is on screen.
        renderer.encode(card, time: CACurrentMediaTime() - started, pixels: drawableSize, scale: drawableSize.width / FoilCanvas.size.width, pass: pass, into: buffer)
        buffer.present(drawable)
        buffer.commit()
    }
}
