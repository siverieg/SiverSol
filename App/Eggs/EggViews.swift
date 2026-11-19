import SiverCore
import SiverSky
import SwiftUI

/// Glimmer: a small silver-lilac crescent with two dot eyes, drawn in code. It floats in, sits a while, says one
/// calm line, and drifts up and away with a sparkle. With Reduce Motion it simply fades in and out in place.
struct GlimmerOverlay: View {
    @ObservedObject private var eggs = EggDirector.shared
    @ObservedObject private var sky = SkyState.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            if let visit = eggs.glimmer {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                    let t = context.date.timeIntervalSince(visit.began)
                    let perch = perchPoint(in: geo)
                    let pose = Self.pose(t: t, perch: perch, size: geo.size, calm: reduceMotion)
                    ZStack(alignment: .topLeading) {
                        if pose.bubble > 0 {
                            Text(visit.line).font(Sky.display(13, .semibold)).foregroundStyle(.primary)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(.regularMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
                                .fixedSize()
                                .opacity(pose.bubble)
                                .position(x: pose.at.x, y: pose.at.y + 44)
                        }
                        GlimmerShape(wave: pose.wave)
                            .frame(width: 46, height: 46)
                            .scaleEffect(pose.scale)
                            .opacity(pose.alpha)
                            .position(pose.at)
                        if pose.sparkle > 0 {
                            Image(systemName: "sparkle").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                                .scaleEffect(0.6 + pose.sparkle).opacity(1 - pose.sparkle)
                                .position(pose.at)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("A small sky spirit says: \(visit.line)")
            }
        }
        .allowsHitTesting(false)
    }

    /// On the Sun-Arc when the Dashboard is showing it, near the top of the page otherwise.
    private func perchPoint(in geo: GeometryProxy) -> CGPoint {
        let frame = geo.frame(in: .global)
        if let arc = sky.heroArcRect, arc.width > 40 {
            // Sitting on the line of the arc, to the right of its top.
            return CGPoint(x: arc.minX + arc.width * 0.74 - frame.minX, y: arc.minY + arc.height * 0.24 - 16 - frame.minY)
        }
        return CGPoint(x: geo.size.width * 0.66, y: 96)
    }

    struct Pose { var at: CGPoint; var alpha: Double; var scale: Double; var wave: Double; var bubble: Double; var sparkle: Double }

    /// Where Glimmer is `t` seconds into its visit: in from the right, a while on its perch, then up and away.
    static func pose(t: TimeInterval, perch: CGPoint, size: CGSize, calm: Bool) -> Pose {
        func ease(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }
        if calm {
            let a = min(ease(t / 1.2), ease((13 - t) / 1.2))
            return Pose(at: perch, alpha: a, scale: 1, wave: 0, bubble: t > 1.5 && t < 11 ? min(1, a) : 0, sparkle: 0)
        }
        if t < 2.6 {   // floating in, with a small bob
            let k = ease(t / 2.6)
            let start = CGPoint(x: size.width + 30, y: perch.y - 70)
            return Pose(at: CGPoint(x: start.x + (perch.x - start.x) * k, y: start.y + (perch.y - start.y) * k + sin(t * 4) * 5 * (1 - k)),
                        alpha: ease(t / 0.6), scale: 1, wave: 0, bubble: 0, sparkle: 0)
        }
        if t < 10.5 {  // on its perch: a wave, a line, a slow breath
            let s = t - 2.6
            return Pose(at: CGPoint(x: perch.x, y: perch.y + sin(t * 1.6) * 1.5), alpha: 1, scale: 1,
                        wave: s < 2.4 ? sin(s * 6) * (1 - s / 2.4) : 0, bubble: min(ease((s - 0.4) / 0.5), ease((7.4 - s) / 0.5)), sparkle: 0)
        }
        let k = ease((t - 10.5) / 2.6)   // drifting up towards the island, then gone with a sparkle
        let end = CGPoint(x: size.width * 0.5, y: -10)
        let at = CGPoint(x: perch.x + (end.x - perch.x) * k, y: perch.y + (end.y - perch.y) * k)
        return Pose(at: at, alpha: 1 - ease((t - 12.4) / 0.6), scale: 1 - 0.45 * k, wave: 0, bubble: 0, sparkle: t > 12.6 ? min(1, (t - 12.6) / 0.9) : 0)
    }
}

/// The spirit itself: a crescent in the icon's silver-lilac, two dot eyes, a soft glow.
struct GlimmerShape: View {
    var wave: Double = 0

    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) * 0.42
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            var moon = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            let bite = Path(ellipseIn: CGRect(x: c.x - r * 0.35, y: c.y - r * 1.05, width: r * 1.9, height: r * 1.9))
            moon = moon.subtracting(bite)
            ctx.addFilter(.shadow(color: Color(red: 0.80, green: 0.74, blue: 1.0).opacity(0.9), radius: 6))
            ctx.fill(moon, with: .linearGradient(Gradient(colors: [Color(red: 0.93, green: 0.92, blue: 1.0), Color(red: 0.72, green: 0.66, blue: 0.93)]),
                                                 startPoint: CGPoint(x: c.x - r, y: c.y - r), endPoint: CGPoint(x: c.x, y: c.y + r)))
            // Two small eyes on the thick part of the crescent.
            for dx in [-0.62, -0.30] {
                let e = CGPoint(x: c.x + r * dx, y: c.y + r * 0.10)
                ctx.fill(Path(ellipseIn: CGRect(x: e.x - 1.7, y: e.y - 2.1, width: 3.4, height: 4.2)), with: .color(Color(red: 0.16, green: 0.13, blue: 0.30)))
            }
        }
        .rotationEffect(.degrees(wave * 14))
        .accessibilityHidden(true)
    }
}

/// A tiny comet crossing the island.
struct IslandComet: View {
    @ObservedObject private var eggs = EggDirector.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let began = eggs.cometBegan {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                let total = SkyEgg.islandComet.seconds ?? 1.6
                let t = context.date.timeIntervalSince(began) / total
                Canvas { ctx, size in
                    guard t >= 0, t <= 1 else { return }
                    // Calm version: a still streak in the middle that fades.
                    let k = reduceMotion ? 0.5 : t
                    let head = CGPoint(x: size.width * (0.04 + 0.92 * k), y: size.height * (0.30 + 0.34 * k))
                    let fade = sin(.pi * t)
                    var tail = Path()
                    tail.move(to: head)
                    tail.addLine(to: CGPoint(x: head.x - 34, y: head.y - 12))
                    ctx.stroke(tail, with: .linearGradient(Gradient(colors: [.white.opacity(0.95 * fade), .white.opacity(0)]), startPoint: head, endPoint: CGPoint(x: head.x - 34, y: head.y - 12)),
                               style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    ctx.fill(Path(ellipseIn: CGRect(x: head.x - 1.8, y: head.y - 1.8, width: 3.6, height: 3.6)), with: .color(.white.opacity(fade)))
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// The Secrets list at the foot of the Tips page.
struct SecretsCard: View {
    @ObservedObject private var eggs = EggDirector.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardTitle(title: "Secrets", symbol: "sparkles")
                Spacer()
                Text(EggRow.summary(found: eggs.found.count)).font(Sky.mono(12)).foregroundStyle(.secondary)
            }
            Text("The sky has a few rare surprises of its own. Each one you see is kept here.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(EggRow.rows(found: eggs.found)) { row in
                HStack(spacing: 10) {
                    Image(systemName: row.symbol).frame(width: 22).foregroundStyle(row.foundAt == nil ? .secondary : .primary).accessibilityHidden(true)
                    Text(row.name).fontWeight(row.foundAt == nil ? .regular : .semibold)
                    Spacer(minLength: 12)
                    Text(row.foundAt.map { "\(row.odds) · found \($0.formatted(date: .abbreviated, time: .omitted))" } ?? row.odds)
                        .font(.callout).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if eggs.hunter {
                Label("Egg Hunter: you have seen them all", systemImage: "rosette").fontWeight(.semibold)
            }
            Divider()
            Text("Seasonal (on the date, not by luck)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(SeasonalEgg.allCases, id: \.self) { s in
                Text(s.name).font(.callout).foregroundStyle(.secondary)
            }
            Text(EggRow.disclaimer).font(.callout.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// Settings › Fun.
struct FunSettingsCard: View {
    @ObservedObject private var eggs = EggDirector.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "Fun", symbol: "sparkles")
            HelpToggle(title: "Rare sky surprises",
                       help: "Now and then the sky does something rare while you are looking. Just for fun: it does not change your in-game luck, and nothing about it is ever sent to Discord.",
                       isOn: Binding(get: { eggs.enabled }, set: { eggs.enabled = $0 }))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// Found surprises as cards at the foot of the Sol Dex. They are their own "Secret" tier and are not auras:
/// they are never counted in the collection.
struct SecretCardsSection: View {
    @ObservedObject private var eggs = EggDirector.shared

    var body: some View {
        if !eggs.found.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardTitle(title: "Secret", symbol: "sparkles")
                    Spacer()
                    Text(EggRow.cardLabel).font(.callout).foregroundStyle(.secondary)
                }
                // One row that scrolls sideways, so the real collection below stays where it was.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(SkyEgg.allCases.filter { eggs.found[$0] != nil }) { egg in
                            SecretCard(title: egg.name, caption: "1 in \(egg.oneIn.formatted())", symbol: egg.symbol, seed: UInt32((SkyEgg.allCases.firstIndex(of: egg) ?? 0) * 37 + 11), rainbow: false)
                                .frame(width: 124)
                        }
                        if eggs.hunter {
                            SecretCard(title: "Egg Hunter", caption: "all eight found", symbol: "rosette", seed: 7, rainbow: true).frame(width: 124)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .card()
        }
    }
}

struct SecretCard: View {
    let title: String
    let caption: String
    let symbol: String
    let seed: UInt32
    let rainbow: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        ZStack {
            FoilFace(card: FoilCard(level: rainbow ? .prismatic : .holographic, top: RGB(hex: 0xB9A8F0), bottom: RGB(hex: 0x2B2A5E), seed: seed, seen: true))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top) {
                    Text("SECRET").font(.system(size: 8.5, weight: .heavy)).tracking(1.1)
                    Spacer(minLength: 4)
                    Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                }
                Spacer(minLength: 0)
                Text(title).font(Sky.display(13.5, .bold)).lineLimit(2).minimumScaleFactor(0.75)
                Text(caption).font(.system(size: 9.5, weight: .medium)).opacity(0.85).lineLimit(1)
                Text("not a real aura").font(.system(size: 8.5, weight: .medium)).opacity(0.75)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
            .padding(.horizontal, 11).padding(.vertical, 10)
        }
        .aspectRatio(0.73, contentMode: .fit)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.75))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), sky surprise, not a real aura. \(caption)")
    }
}
