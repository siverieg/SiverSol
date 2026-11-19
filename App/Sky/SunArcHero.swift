import SiverCore
import SiverNotify
import SwiftUI

/// The Dashboard's hero: the sky itself, with the biome's name on it.
///
/// A sun (by day) or moon (by night) crosses a thin arc; how far along it is shows how much of the biome's usual
/// length has passed. A biome with no known length lets it drift near the top. A rare biome trades the arc for a
/// glowing ring. The arc, the ring and the body are painted by the sky itself (see `SkyShader`); this view only
/// tells the sky where they go and sets the text on top.
struct SunArcHero: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var sky = SkyState.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let height: CGFloat

    var body: some View {
        let current = model.isRunning ? model.snapshot.current : nil
        let info = current.map { model.catalog.info(for: $0.biome.key) }
        let rare = info?.isRare == true
        let arcHeight = height * 0.40
        let ink = sky.look.ink.color

        ZStack(alignment: .top) {
            // Where the arc goes. The sky reads this rectangle; nothing is drawn here.
            Color.clear
                .frame(height: arcHeight)
                .padding(.horizontal, 30)
                .padding(.top, 22)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sky.heroArcRect = $0 }

            VStack(spacing: 4) {
                // Where a rare biome's ring goes: around the glyph.
                ZStack {
                    Color.clear.frame(width: 96, height: 96)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sky.heroRingRect = $0 }
                    if let info, rare {
                        BiomeGlyph(info: info, size: 38, night: sky.isNight).foregroundStyle(ink)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .frame(height: rare ? 104 : max(8, arcHeight * 0.42))

                if let current, let info {
                    title(current, info)
                        .id(current.biome.key.value)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .offset(x: 46).combined(with: .opacity),
                            removal: .offset(x: -70).combined(with: .opacity)))
                } else {
                    idle.transition(.opacity)
                }
            }
            .padding(.top, 22)
            .frame(maxWidth: .infinity)
            .foregroundStyle(ink)
            // The scrim that keeps the words readable: only as strong as this sky needs.
            .background {
                Ellipse()
                    .fill((sky.look.inkIsLight ? Color.black : Color.white).opacity(sky.look.veil))
                    .blur(radius: 46)
                    .padding(.horizontal, 60).padding(.top, 40)
                    .allowsHitTesting(false)
            }
            .animation(reduceMotion ? nil : Sky.front, value: current?.biome.key.value)
            .animation(reduceMotion ? nil : Sky.front, value: sky.look.inkIsLight)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .top)
        .onDisappear { sky.heroArcRect = nil; sky.heroRingRect = nil }
    }

    // MARK: a biome is on

    @ViewBuilder private func title(_ current: BiomeTracker.Current, _ info: BiomeInfo) -> some View {
        let rare = info.isRare
        VStack(spacing: 4) {
            HStack(spacing: 7) {
                if !rare { BiomeGlyph(info: info, size: 15, night: sky.isNight) }
                Text(eyebrow(info)).font(.system(size: 11.5, weight: .bold)).tracking(1.6)
            }
            .opacity(0.85)
            Text(current.biome.key.value)
                .font(Sky.display(58))
                .lineLimit(1).minimumScaleFactor(0.45)
                .shadow(color: (sky.look.inkIsLight ? Color.black : Color.white).opacity(0.28), radius: 10, y: 1)
                .padding(.horizontal, 24)
            Ticker { context in
                let elapsed = max(0, context.date.timeIntervalSince(current.since))
                let total = info.durationS.map(Double.init)
                let known = total != nil && current.observedStart
                let remaining = known ? max(0, total! - elapsed) : 0
                VStack(spacing: 3) {
                    // Plain digits: a per-second clock never animates.
                    if known {
                        Text(remaining > 0 ? AppModel.clock(remaining) : "any moment now")
                            .font(Sky.mono(remaining > 0 ? 27 : 20))
                        Text("left of about \(DiscordTime.duration(total!)) · rolled in at \(current.since.formatted(date: .omitted, time: .shortened))")
                            .font(.callout).opacity(0.85)
                    } else {
                        Text("running \(DiscordTime.duration(elapsed))").font(Sky.mono(22))
                        Text(current.observedStart ? "since \(current.since.formatted(date: .omitted, time: .shortened)) · no usual length known"
                                                   : "it was already here when SiverSol looked up")
                            .font(.callout).opacity(0.85)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(known ? "\(current.biome.key.value), about \(DiscordTime.duration(remaining)) left"
                                          : "\(current.biome.key.value), running for \(DiscordTime.duration(elapsed))")
            }
        }
    }

    private func eyebrow(_ info: BiomeInfo) -> String {
        switch info.category {
        case .rare: return "RARE BIOME"
        case .event: return "EVENT BIOME"
        case .weather: return "WEATHER"
        case .normal: return sky.isNight ? "CLEAR NIGHT" : "CLEAR SKY"
        case .unknown: return "NEW BIOME"
        }
    }

    // MARK: nothing to show yet

    private var idle: some View {
        VStack(spacing: 8) {
            Text(idleTitle).font(Sky.display(38, .bold)).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
            Text(idleText).font(.title3).opacity(0.9).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if !model.isRunning {
                Button { model.start() } label: {
                    Label("Start watching", systemImage: "play.fill").font(.headline).padding(.horizontal, 6).padding(.vertical, 2)
                }
                .skyGlassButton(prominent: true)
                .controlSize(.large)
                .padding(.top, 8)
                .help("Start watching the Roblox log (⌘P)")
            }
        }
        .padding(.horizontal, 40)
        .accessibilityElement(children: .contain)
    }

    private var idleTitle: String {
        guard model.isRunning else { return "The sky is quiet" }
        if !model.permissions.robloxRunning { return "Roblox isn't open" }
        if case .menu = model.snapshot.phase { return "At the start menu" }
        return "Watching the horizon"
    }

    private var idleText: String {
        guard model.isRunning else {
            return model.hasWebhook ? "Press Start and SiverSol begins watching the sky over Sol's RNG." : "Add a Discord webhook in Notifications, then press Start."
        }
        if !model.permissions.robloxRunning { return "SiverSol is watching an empty sky." }
        if case .menu = model.snapshot.phase { return "The game is waiting on its start menu." }
        return "The first biome shows up here as soon as the game reports one."
    }
}
