import AppKit
import SiverCore
import SiverEngine
import SiverNotify
import SwiftUI

/// The sidebar, as part of the Living Sky.
///
/// It is still a real sidebar `List` inside the `NavigationSplitView`: arrow keys, VoiceOver, collapsing and
/// resizing are the system's. What is its own: the brand header, small quiet sections, a selection capsule in the
/// current biome's tint that slides between rows, live accessories at the right of a row, and a status card at
/// the foot that mirrors the Biome Island.
///
/// It is glass, so nothing inside it is glass or a card. Nothing here redraws every frame: the only clock is the
/// countdown, once a second, and only while there is one to show.
struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var sky = SkyState.shared
    @ObservedObject private var dex = SolDexModel.shared
    @ObservedObject private var moments = MomentsModel.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("momentsSeenAt") private var momentsSeenAt = 0.0
    @State private var hovered: AppPage?
    @State private var bounces: [AppPage: Int] = [:]
    @State private var pulse = false

    static let selectionSpring = Animation.spring(response: 0.35, dampingFraction: 0.85)
    static let tintFade = Animation.easeInOut(duration: 1.2)

    /// The biome's accent, nudged until it reads on the sidebar; brand steel when no biome is on.
    private var tint: Color {
        guard sky.biome != nil else { return scheme == .dark ? Color(hex: 0x9FB0CC) : Sky.steel }
        return SkyModel.legibleAccent(sky.look, dark: scheme == .dark).color
    }

    var body: some View {
        List(selection: Binding<AppPage?>(get: { model.selection }, set: { if let s = $0 { select(s) } })) {
            ForEach(SidebarSection.allCases) { section in
                Section {
                    ForEach(section.pages) { page in
                        row(page)
                            .tag(page)
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    Text(section.rawValue).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).textCase(nil)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // Secondary text in the sidebar is a little stronger than the system's: over a dark sky in light mode (or
        // a bright one in dark mode) the glass turns mid-grey, and the usual secondary grey drops under 4.5:1.
        .foregroundStyle(Color.primary, Color.primary.opacity(0.72))
        // The selection: one capsule in the biome's tint, drawn behind the rows, that slides to the selected one.
        .backgroundPreferenceValue(RowBoundsKey.self) { anchors in
            GeometryReader { proxy in
                if let anchor = anchors[model.selection] {
                    let r = proxy[anchor].insetBy(dx: -8, dy: -3)
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(tint.opacity(contrast == .increased ? 0.34 : 0.18))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(tint.opacity(contrast == .increased ? 0.9 : 0.28), lineWidth: contrast == .increased ? 1.5 : 0.75)
                        }
                        // A rare biome arriving: the Dashboard's capsule glows twice, then settles.
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(pulse && model.selection == .dashboard ? 0.35 : 0))
                        }
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .animation(reduceMotion ? .easeInOut(duration: 0.15) : Self.selectionSpring, value: model.selection)
                        .animation(reduceMotion ? .easeInOut(duration: 0.2) : Self.tintFade, value: sky.look.accent)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarStatusCard(tint: tint) }
        .background { if reduceTransparency { Color(nsColor: .windowBackgroundColor).ignoresSafeArea() } }
        .onAppear {
            dex.reload(catalog: model.auras)
            moments.reload()
        }
        .onChange(of: sky.biome?.key) { _, _ in
            guard sky.biome?.isRare == true, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.4).repeatCount(4, autoreverses: true)) { pulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { withAnimation(.easeOut(duration: 0.3)) { pulse = false } }
        }
        .onChange(of: model.selection) { _, page in
            if page == .moments { momentsSeenAt = Date().timeIntervalSince1970 }
        }
    }

    private func select(_ page: AppPage) {
        guard page != model.selection else { return }
        model.selection = page
        if !reduceMotion { bounces[page, default: 0] += 1 }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 9) {
            BrandMark(size: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text("SiverSol").font(Sky.display(16, .heavy))
                Text(EggDirector.shared.enabled ? SeasonalEgg.sidebarLine(statusLine, on: Date()) : statusLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.82)
                    .contentTransition(.opacity)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: statusLine)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.top, 6).padding(.bottom, 8)
        .foregroundStyle(Color.primary, Color.primary.opacity(0.72))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var statusLine: String {
        var attention = false
        if case .attention = model.runState { attention = true }
        return SidebarStatus.line(watching: model.isRunning, starting: model.runState == .starting, needsAttention: attention,
                                  inputPaused: model.automationPaused, robloxRunning: model.permissions.robloxRunning,
                                  biome: model.currentBiome?.display)
    }

    // MARK: rows

    private func row(_ page: AppPage) -> some View {
        let selected = model.selection == page
        let accessory = accessory(for: page)
        // (The design review can ask for a hover, to photograph it.)
        let hovering = hovered == page || model.reviewNote == "sidebar-hover:\(page.rawValue)"
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                icon(page, selected: selected)
                Text(page.title).lineLimit(1).fixedSize().foregroundStyle(.primary)
                Spacer(minLength: 4)
                trailing(accessory, page: page, hovering: hovering)
            }
            // Narrow: the accessory goes before the label is cut short.
            HStack(spacing: 8) {
                icon(page, selected: selected)
                Text(page.title).lineLimit(1).foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
        }
        .fontWeight(selected ? .semibold : .regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .anchorPreference(key: RowBoundsKey.self, value: .bounds) { [page: $0] }
        .background {
            // Hover: a soft highlight that fades in.
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(hovering && !selected ? 0.07 : 0))
                .padding(.horizontal, -8).padding(.vertical, -3)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .background { if page == .dashboard { SidebarTableTweak() } }
        .onHover { inside in hovered = inside ? page : (hovered == page ? nil : hovered) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessory.spoken.isEmpty ? page.title : "\(page.title), \(accessory.spoken)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func icon(_ page: AppPage, selected: Bool) -> some View {
        Image(systemName: page.symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(selected ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
            .symbolEffect(.bounce, value: bounces[page, default: 0])
            .symbolEffect(.variableColor.iterative, isActive: page == .notifications && notifyHealth == .retrying && !reduceMotion)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : Self.tintFade, value: sky.look.accent)
            .frame(width: 22)
            .accessibilityHidden(true)
    }

    private var notifyHealth: NotifyHealth {
        NotifyHealth.of(hasWebhook: model.hasWebhook || DesignReview.isOn, deadRoutes: model.reading.dead.count, waiting: model.reading.outboxDepth)
    }

    private func accessory(for page: AppPage) -> SidebarAccessory {
        switch page {
        case .dashboard:
            guard let c = model.isRunning ? model.snapshot.current : nil else { return .none }
            let info = model.catalog.info(for: c.biome.key)
            guard info.isRare, let d = info.durationS, c.observedStart else { return .none }
            return .countdown(until: c.since.addingTimeInterval(TimeInterval(d)), spoken: "\(info.display) is on")
        case .timeline:
            return SidebarFormat.eventsToday(model.reading.eventsToday)
        case .auras:
            return dex.dex.map { SidebarFormat.dex(found: $0.collected, total: $0.collectable.count) } ?? .none
        case .moments:
            guard let newest = moments.moments.first, newest.at.timeIntervalSince1970 > momentsSeenAt, model.selection != .moments else { return .none }
            return .dot(spoken: "new clips")
        case .notifications:
            let health = notifyHealth
            return model.isRunning || health != .healthy ? .health(health) : .none
        case .automation:
            return SidebarFormat.nextRun(model.reading.nextRun, now: Date())
        case .macros:
            if model.macroStatus.recording != .idle { return .dot(spoken: "recording") }
            guard let p = model.macroStatus.playing else { return .none }
            return SidebarFormat.playhead(step: p.step, of: p.totalSteps, name: p.name)
        case .logLab:
            // Only when the reader has fallen behind: Roblox is open but its log has been silent for five minutes.
            guard model.isRunning, model.permissions.robloxRunning, let beat = model.reading.session.lastHeartbeatAt,
                  Date().timeIntervalSince(beat) > 300 else { return .none }
            return .dot(spoken: "the log has been quiet for a while")
        case .settings:
            return model.permissions.allGranted || DesignReview.isOn ? .none : .dot(spoken: "a permission is missing")
        case .about, .tips:
            return .none
        }
    }

    /// The right-hand end of a row: the ⌘ shortcut while the pointer is over it, the accessory otherwise.
    /// One fixed width for all of them, so a changing number never moves the label.
    @ViewBuilder private func trailing(_ accessory: SidebarAccessory, page: AppPage, hovering: Bool) -> some View {
        ZStack(alignment: .trailing) {
            Text(page.shortcutLabel).font(Sky.mono(10.5)).foregroundStyle(.secondary).opacity(hovering ? 1 : 0)
            accessoryView(accessory, page: page).opacity(hovering ? 0 : 1)
        }
        .frame(width: 44, alignment: .trailing)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func accessoryView(_ accessory: SidebarAccessory, page: AppPage) -> some View {
        switch accessory {
        case .none:
            EmptyView()
        case .text(let text, _):
            Text(text).font(Sky.mono(10.5)).foregroundStyle(.secondary).lineLimit(1)
        case .countdown(let until, _):
            HStack(spacing: 4) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Ticker { context in
                    Text(SidebarFormat.clock(until.timeIntervalSince(context.date))).font(Sky.mono(10.5)).foregroundStyle(.secondary)
                }
            }
        case .dot:
            Circle().fill(page == .macros ? Color.red : (page == .settings || page == .logLab ? Sky.warning : tint)).frame(width: 7, height: 7)
        case .health(let health):
            switch health {
            case .healthy: Circle().fill(Color.green).frame(width: 7, height: 7)
            case .retrying: Circle().fill(Color.orange).frame(width: 7, height: 7)
            case .failing: Circle().fill(Color.red).frame(width: 7, height: 7)
            case .notSetUp: Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(Sky.warning)
            }
        case .playhead(let progress, _):
            // A tiny playhead: it moves when the macro reports a step, not on every frame.
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15)).frame(width: 34, height: 3)
                Capsule().fill(Color.green).frame(width: max(3, 34 * progress), height: 3)
                Circle().fill(Color.green).frame(width: 7, height: 7).offset(x: max(0, 34 * progress - 3.5))
            }
            .frame(width: 34)
            .animation(reduceMotion ? nil : .linear(duration: 0.25), value: progress)
        }
    }
}

/// Where each row is, so the selection capsule can be drawn behind the list and slide between rows.
private struct RowBoundsKey: PreferenceKey {
    static let defaultValue: [AppPage: Anchor<CGRect>] = [:]
    static func reduce(value: inout [AppPage: Anchor<CGRect>], nextValue: () -> [AppPage: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The system draws a grey selection pill in a sidebar list. The sidebar draws its own tinted capsule instead, so
/// the system's is turned off; the selection itself (and with it the arrow keys and VoiceOver) stays the list's.
private struct SidebarTableTweak: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            var v: NSView? = view
            while let current = v, !(current is NSTableView) { v = current.superview }
            guard let table = v as? NSTableView else { return }
            if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
        }
    }
}

/// The status card at the foot of the sidebar: a small Biome Island that is always there. It shows the biome's
/// glyph and name, the countdown, and the profile, with a pause or resume button. Clicking it opens the Dashboard.
/// Its four looks are the island's: resting, a rare biome (a slow breathing glow), paused (colour drained), and
/// Roblox not running (an outline only).
struct SidebarStatusCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var sky = SkyState.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    let tint: Color
    @State private var breathe = false

    private var state: StatusCardState {
        StatusCardState.of(watching: model.isRunning, inputPaused: model.automationPaused, robloxRunning: model.permissions.robloxRunning,
                           rareBiome: model.currentBiome?.isRare == true)
    }

    var body: some View {
        let state = self.state
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let current = model.isRunning ? model.snapshot.current : nil
        let info = current.map { model.catalog.info(for: $0.biome.key) }
        HStack(spacing: 9) {
            Button { model.selection = .dashboard } label: {
                HStack(spacing: 9) {
                    Group {
                        if let info, state != .noRoblox {
                            BiomeGlyph(info: info, size: 17, night: sky.isNight)
                        } else {
                            Image(systemName: state == .noRoblox ? "gamecontroller" : "moon.zzz.fill").font(.system(size: 14, weight: .semibold))
                        }
                    }
                    .foregroundStyle(tint)
                    .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(info)).font(Sky.display(12.5, .bold)).lineLimit(1).minimumScaleFactor(0.8)
                        subtitle(current, info).font(Sky.mono(10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { model.toggle() } label: {
                Image(systemName: model.isRunning ? "pause.fill" : "play.fill").font(.system(size: 11, weight: .bold)).frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.09), in: Circle())
            }
            .buttonStyle(PressStyle())
            .help(model.isRunning ? "Pause (⌘P)" : "Start (⌘P)")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .foregroundStyle(Color.primary, Color.primary.opacity(0.72))
        .background {
            if state != .noRoblox { shape.fill(tint.opacity(state == .paused ? 0.10 : 0.16)) }
        }
        .overlay {
            shape.strokeBorder(tint.opacity(contrast == .increased ? 0.9 : (state == .noRoblox ? 0.55 : 0.32)),
                               style: StrokeStyle(lineWidth: contrast == .increased ? 1.5 : 1, dash: state == .noRoblox ? [4, 3] : []))
        }
        .shadow(color: state == .rare ? tint.opacity(breathe ? 0.75 : 0.25) : .clear, radius: state == .rare ? (breathe ? 10 : 4) : 0)
        .saturation(state == .paused ? 0.15 : 1)
        .opacity(state == .paused ? 0.85 : 1)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : SidebarView.tintFade, value: sky.look.accent)
        .padding(.horizontal, 10).padding(.bottom, 10).padding(.top, 6)
        .onChange(of: state, initial: true) { _, new in
            // A slow breath while a rare biome is on, and only then.
            if new == .rare && !reduceMotion {
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { breathe = true }
            } else {
                withAnimation(.easeOut(duration: 0.3)) { breathe = false }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(current, info))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.selection = .dashboard }
        .accessibilityAction(named: model.isRunning ? "Pause" : "Start") { model.toggle() }
    }

    private func title(_ info: BiomeInfo?) -> String {
        switch state {
        case .noRoblox: return "Roblox isn't open"
        case .paused where !model.isRunning: return "Paused"
        default: return info?.display ?? "Watching the horizon"
        }
    }

    private var profile: String { model.activeProfile ?? "Default" }

    @ViewBuilder private func subtitle(_ current: BiomeTracker.Current?, _ info: BiomeInfo?) -> some View {
        if model.isRunning, state != .noRoblox, let current, let info, let d = info.durationS, current.observedStart {
            // The one clock in the sidebar: once a second, and only while a countdown is showing.
            Ticker { context in
                let left = Double(d) - context.date.timeIntervalSince(current.since)
                Text("\(left > 0 ? SidebarFormat.clock(left) : "any moment") · \(profile)")
            }
        } else {
            Text(model.isRunning && model.automationPaused ? "input paused · \(profile)" : profile)
        }
    }

    private func spoken(_ current: BiomeTracker.Current?, _ info: BiomeInfo?) -> String {
        var parts = [title(info)]
        if model.isRunning, let current, let info, let d = info.durationS, current.observedStart {
            let left = Double(d) - Date().timeIntervalSince(current.since)
            if left > 0 { parts.append("about \(DiscordTime.duration(left)) left") }
        }
        if model.isRunning && model.automationPaused { parts.append("input paused") }
        parts.append("profile \(profile)")
        return parts.joined(separator: ", ")
    }
}
