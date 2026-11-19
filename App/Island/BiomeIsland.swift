import AppKit
import MetalKit
import SiverCore
import SiverInput
import SiverSky
import SwiftUI

/// The Biome Island: a small live view of the biome and its timer at the top of the screen.
///
/// On a screen with a notch it is the notch grown sideways: a black shape exactly as tall as the camera housing
/// and centred on it, with the biome in the left "ear" and the timer in the right one. Nothing is drawn where
/// the camera is. A rare biome or a rare roll grows it downwards into a card. On a screen without a notch it is
/// a pill under the menu bar. Where everything goes is `IslandLayout` (SiverCore), which only knows what the
/// system reports about the screen; no notch size is written down anywhere.
///
/// In "Always show" the resting island stays up while SiverSol watches. It redraws once a second (the timer)
/// and has no moving sky.
///
/// It lives in a panel that never becomes the key window and never activates SiverSol, so Roblox keeps the
/// keyboard. The panel lets every click through to whatever is underneath, except on its own buttons, and while
/// a macro is recording or playing it lets every click through, buttons included.
@MainActor
final class IslandController: ObservableObject {
    static let shared = IslandController()

    /// An announcement (a rare biome, a rare roll, or in "Everything" any news), or nil.
    @Published private(set) var item: IslandItem?
    /// What the resting island says, or nil while it is not up.
    @Published private(set) var resting: IslandResting?
    /// The one-time first line under the resting island.
    @Published private(set) var introLine = false
    /// The screen the island is on, and the panel's frame there.
    @Published private(set) var screen = ScreenShape(frame: .zero)
    @Published private(set) var panelFrame = CGRect.zero
    /// Where the buttons are, in the panel's own coordinates (top-left origin); nil when there are none.
    var buttonsFrame: CGRect?

    @AppStorage("islandOverFullScreen") var overFullScreen = false
    /// Keep the island out of screenshots, recordings and shared screens.
    @AppStorage("islandOutOfCaptures") var outOfCaptures = true { didSet { applySharing() } }

    /// The design review sets these, so pictures never depend on (or change) what the user chose.
    var modeOverride: IslandMode? { didSet { queue.mode = mode; refresh() } }
    var restingOverride: IslandResting? { didSet { refresh() } }
    var introOverride: Bool? { didSet { introLine = introOverride ?? false } }

    private let defaults = UserDefaults.standard
    private var queue = IslandQueue(mode: .standard)
    private var panel: IslandPanel?
    private var timer: Timer?
    private var interval: TimeInterval?
    private var hideWork: DispatchWorkItem?
    private var hold: (value: IslandHold?, at: TimeInterval) = (nil, -10)
    private var previewRestingUntil: Date?
    private var observers: [NSObjectProtocol] = []

    /// Nothing stored means the user never chose, and they get Always Show; a choice they made is kept.
    var mode: IslandMode {
        get { modeOverride ?? IslandMode.resolve(stored: defaults.string(forKey: IslandMode.storageKey)) }
        set {
            defaults.set(newValue.rawValue, forKey: IslandMode.storageKey)
            queue.mode = newValue
            objectWillChange.send()
            refresh()
        }
    }

    private init() {
        queue.mode = mode
        // The screens changed (a display plugged in or out, a new arrangement, another Space): read the
        // geometry again and move the island.
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanged() }
            })
        }
    }

    /// Build the panel and its view before they are first needed, so the island's first appearance is as
    /// smooth as every later one. The panel stays out of sight.
    func prewarm() {
        guard panel == nil else { return }
        panel = IslandPanel()
        applySharing()
        place(RobloxWindowFinder.mainWindow())
        panel?.contentView?.layoutSubtreeIfNeeded()
        panel?.displayIfNeeded()
    }

    /// Called at launch and whenever watching starts or stops.
    func refresh() {
        retime()
        tick()
    }

    /// Something happened in the game.
    func offer(_ event: SiverEvent, catalog: BiomeCatalog, auras: AuraCatalog) {
        guard let item = IslandItem.make(for: event, catalog: catalog, auras: auras) else { return }
        offer(item)
    }

    func offer(_ item: IslandItem) {
        queue.offer(item, now: Date())
        refresh()
    }

    /// "Show an example" in Settings: shown whatever the mode is.
    func preview(rare: Bool, catalog: BiomeCatalog) {
        let key: BiomeKey = rare ? "GLITCHED" : "RAINY"
        let info = catalog.info(for: key)
        var q = IslandQueue(mode: .everything)
        q.offer(IslandItem(id: "preview-\(Date().timeIntervalSince1970)", kind: .biome, title: key.value,
                           detail: info.durationS.map { "about \(IslandItem.shortDuration(TimeInterval($0)))" } ?? "", biome: key, rare: rare, at: Date()))
        queue = q
        refresh()
        // Back to the user's mode once the example has had its time.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self else { return }
            self.queue.mode = self.mode
            self.refresh()
        }
    }

    /// The "?" explainer's example: the resting island for a few seconds, whatever the mode is.
    func previewResting() {
        previewRestingUntil = Date().addingTimeInterval(7)
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.2) { [weak self] in self?.refresh() }
    }

    func dismiss() {
        queue.dismiss()
        tick()
    }

    func openApp() {
        dismiss()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.styleMask.contains(.titled) && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    /// Fast while an announcement is up or waiting, once a second while only the resting island could show,
    /// and not at all otherwise.
    private func retime() {
        let previewing = previewRestingUntil.map { $0 > Date() } ?? false
        let wanted: TimeInterval? = (item != nil || !queue.isIdle) ? 0.1 : ((mode == .always || previewing || resting != nil) ? 1 : nil)
        guard wanted != interval else { return }
        timer?.invalidate()
        timer = nil
        interval = wanted
        guard let wanted else { return }
        let t = Timer.scheduledTimer(withTimeInterval: wanted, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = wanted * 0.2
        timer = t
    }

    private func tick() {
        let now = Date()
        let roblox = RobloxWindowFinder.mainWindow()
        let held = currentHold(roblox)
        let next = queue.tick(now: now, suppressed: held != nil)
        var rest: IslandResting?
        if let until = previewRestingUntil, until > now {
            rest = restingNow() ?? IslandResting(biome: "RAINY", title: "Rainy", endsAt: now.addingTimeInterval(86), startedAt: now, rare: false)
        } else if let restingOverride {
            rest = restingOverride
        } else if IslandRules.restingVisible(mode: mode, watching: AppModel.shared.isRunning, hold: held) {
            rest = restingNow()
        }
        var opened = false
        if next != item {
            opened = next != nil
            item = next
            if let next { announce(next) }
        }
        if rest != resting {
            let appeared = resting == nil && rest != nil
            resting = rest
            if appeared { firstAppearance() }
        }
        if next != nil || rest != nil { show(roblox) } else if panel?.isVisible == true, hideWork == nil { scheduleHide() }
        // The island opened for an announcement (it grew out of its resting shape, or appeared with one).
        if opened, isOnScreen { EggDirector.shared.islandExpanded() }
        updateClickThrough()
        retime()
    }

    /// Why the island stays away right now, looked up at most once a second.
    private func currentHold(_ roblox: RobloxWindow?) -> IslandHold? {
        let now = ProcessInfo.processInfo.systemUptime
        if now - hold.at < 1 { return hold.value }
        let value = IslandRules.hold(robloxFullScreen: Screens.robloxIsFullScreen(roblox), overFullScreen: overFullScreen, mirrored: Screens.mirrored)
        hold = (value, now)
        return value
    }

    private func restingNow() -> IslandResting? {
        let model = AppModel.shared
        guard model.isRunning else { return nil }
        guard model.permissions.robloxRunning else {
            return IslandResting(biome: nil, title: "Waiting for Roblox", endsAt: nil, startedAt: nil, rare: false)
        }
        guard let current = model.snapshot.current else {
            return IslandResting(biome: nil, title: "Watching", endsAt: nil, startedAt: nil, rare: false)
        }
        let info = model.catalog.info(for: current.biome.key)
        let known = current.observedStart
        return IslandResting(biome: current.biome.key, title: info.display,
                             endsAt: known ? info.durationS.map { current.since.addingTimeInterval(TimeInterval($0)) } : nil,
                             startedAt: known ? current.since : nil, rare: info.isRare)
    }

    /// The first time the resting island appears, ever, it carries one extra line for a few seconds.
    private func firstAppearance() {
        guard introOverride == nil, previewRestingUntil == nil, IslandIntro.take(defaults) else { return }
        introLine = true
        DispatchQueue.main.asyncAfter(deadline: .now() + IslandIntro.seconds) { [weak self] in self?.introLine = false }
    }

    private func screensChanged() {
        hold.at = -10
        FakeNotchWindow.update()
        if panel?.isVisible == true { place(RobloxWindowFinder.mainWindow()) }
        tick()
    }

    private func show(_ roblox: RobloxWindow?) {
        hideWork?.cancel()
        hideWork = nil
        if panel == nil {
            panel = IslandPanel()
            applySharing()
        }
        place(roblox)
        if panel?.isVisible != true { panel?.orderFrontRegardless() }
    }

    /// On the screen Roblox is on. Only a screen with a notch gets the notch style; any other gets the pill.
    private func place(_ roblox: RobloxWindow?) {
        guard let shape = Screens.forRoblox(roblox?.bounds) else { return }
        FakeNotchWindow.update()
        let frame = IslandLayout.panel(on: shape)
        if shape != screen { screen = shape }
        if frame != panelFrame { panelFrame = frame }
        guard let panel else { return }
        // Beside a notch the island sits in front of the menu bar; elsewhere it stays just under it.
        let level = Screens.geometry(shape).hasNotch ? NSWindow.Level.statusBar : NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        if panel.level != level { panel.level = level }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func applySharing() {
        // The design review photographs the island, so there it must stay visible to the camera.
        panel?.sharingType = outOfCaptures && !DesignReview.isOn ? .none : .readOnly
    }

    private func scheduleHide() {
        // Leave time for the island to slide away before the panel goes.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWork = nil
            guard self.item == nil, self.resting == nil else { return }
            self.panel?.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    /// Clicks pass through the island unless the pointer is on one of its buttons. While a macro is recording
    /// or playing they always pass through: a macro's click must never land on SiverSol. The resting island has
    /// no buttons, so it never takes a click at all.
    private func updateClickThrough() {
        guard let panel, panel.isVisible else { return }
        var overButton = false
        let status = AppModel.shared.macroStatus
        let macroBusy = status.recording != .idle || status.playing != nil || status.autoClicking
        if !macroBusy, item != nil, let frame = buttonsFrame {
            let mouse = NSEvent.mouseLocation
            let local = CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)
            overButton = frame.insetBy(dx: -4, dy: -4).contains(local)
        }
        if panel.ignoresMouseEvents == overButton { panel.ignoresMouseEvents = !overButton }
    }

    private func announce(_ item: IslandItem) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        let text = [item.rare && item.kind == .biome ? "Rare biome" : "", item.title, item.detail].filter { !$0.isEmpty }.joined(separator: ", ")
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    /// Is the island where it can be seen right now?
    var isOnScreen: Bool { panel?.isVisible == true && (item != nil || resting != nil) }

    /// For the design review: the panel's window number, so it can be photographed.
    var panelNumber: Int { panel?.isVisible == true ? panel?.windowNumber ?? 0 : 0 }
}

extension IslandItem {
    static func shortDuration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s >= 3600 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        if s >= 60 { return s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m \(s % 60)s" }
        return "\(s)s"
    }
}

/// A panel that floats over other apps without ever taking the keyboard or the front.
final class IslandPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 200),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = FirstClickHostingView(rootView: IslandView())
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Buttons in a panel that is never key must still answer the first click.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct IslandView: View {
    @ObservedObject private var island = IslandController.shared
    @ObservedObject private var power = PowerWatch.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// The last thing shown, kept while the island slides away so it does not go blank on the way out.
    @State private var shownItem: IslandItem?
    @State private var shownResting: IslandResting?

    /// No springs and no moving sky with Reduce Motion, in Low Power Mode, or when the Mac is running hot.
    private var calm: Bool { reduceMotion || power.saving }

    var body: some View {
        let item = island.item
        let resting = item == nil ? island.resting : nil
        let visible = item != nil || resting != nil
        let shape = island.screen
        let layout = self.layout(item: item ?? (visible ? nil : shownItem), resting: resting ?? (visible ? nil : shownResting), on: shape)
        let panel = island.panelFrame
        ZStack(alignment: .topLeading) {
            if panel.width > 0 {
                Group {
                    if layout.style == .notch {
                        notchIsland(layout, item: item ?? (visible ? nil : shownItem), resting: resting ?? (visible ? nil : shownResting), visible: visible)
                    } else {
                        pillIsland(layout, item: item ?? (visible ? nil : shownItem), resting: resting ?? (visible ? nil : shownResting), visible: visible)
                    }
                }
                .offset(x: layout.body.minX - panel.minX, y: panel.maxY - layout.body.maxY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(calm ? .easeOut(duration: 0.2) : Sky.spring, value: item)
        .animation(calm ? .easeOut(duration: 0.2) : Sky.spring, value: resting)
        .animation(calm ? .easeOut(duration: 0.2) : Sky.spring, value: island.introLine)
        .onChange(of: island.item) { _, new in if let new { shownItem = new; shownResting = nil } }
        .onChange(of: island.resting) { _, new in if let new, island.item == nil { shownResting = new; shownItem = nil } }
        .environment(\.colorScheme, .dark)
    }

    // MARK: layout

    private func layout(item: IslandItem?, resting: IslandResting?, on shape: ScreenShape) -> IslandLayout {
        let notched = shape.safeTop > 0
        if let item {
            if item.rare { return IslandLayout.make(state: .expanded, screen: shape) }
            let title = Self.width(item.title, size: 12.5), detail = Self.width(item.detail, size: 11)
            return IslandLayout.make(state: .compact, screen: shape, wanted: notched ? max(title + 34, detail + 20) : title + detail + 96)
        }
        let name = Self.width(resting?.title ?? "", size: 11.5)
        // Room for "0:00:00" in the right ear, so the island does not change width as the timer runs.
        let clock: CGFloat = resting?.endsAt == nil && resting?.startedAt == nil ? 0 : 54
        let wanted = notched ? max(name + 38, clock + 18) : name + clock + (clock > 0 ? 64 : 50)
        return IslandLayout.make(state: .resting, screen: shape, wanted: wanted, extraLine: island.introLine)
    }

    /// A good-enough width for a short label, without measuring it on every pass.
    static func width(_ text: String, size: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .bold)]).width) + 2
    }

    private func look(_ biome: BiomeKey?) -> (BiomeInfo?, SkyLook) {
        let info = biome.map { AppModel.shared.catalog.info(for: $0) }
        return (info, SkyModel.look(info?.palette ?? .clear, hour: SkyState.hour(of: Date()), dark: true))
    }

    // MARK: beside a notch

    /// The notch grown sideways: black, exactly as tall as the camera housing, content only in the two ears.
    @ViewBuilder private func notchIsland(_ l: IslandLayout, item: IslandItem?, resting: IslandResting?, visible: Bool) -> some View {
        let notch = l.notch ?? .zero
        let ear = l.leftEar?.width ?? 0
        let (info, look) = self.look(item?.biome ?? resting?.biome)
        let radius: CGFloat = l.state == .expanded ? 24 : (l.below != nil ? 14 : 10)
        let shape = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: radius, bottomTrailingRadius: radius, topTrailingRadius: 0, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(Color.black)
            if l.state == .expanded, let item, let below = l.below {
                card(item, info, look)
                    .frame(width: l.body.width, height: below.height)
                    .offset(y: notch.height)
            }
            // Left ear: the glyph and the name. Right ear: the timer. The camera area between them stays empty.
            Group {
                if let item { leftEar(item, info, look, expanded: l.state == .expanded) } else if let resting { restingName(resting, info, look) }
            }
            .frame(width: max(0, ear - 12), height: notch.height, alignment: .leading)
            .offset(x: 10)
            Group {
                if let item { rightEar(item) } else if let resting { restingClock(resting) }
            }
            .frame(width: max(0, ear - 12), height: notch.height, alignment: .trailing)
            .offset(x: ear + notch.width + 2)
            if l.state == .resting, let below = l.below {
                introText.frame(width: l.body.width, height: below.height).offset(y: notch.height - 2)
            }
        }
        .frame(width: l.body.width, height: l.body.height, alignment: .topLeading)
        .overlay { IslandComet() }
        .clipShape(shape)
        .shadow(color: l.state == .expanded ? look.accent.color.opacity(0.45) : .clear, radius: 18, y: 6)
        // Out of sight it is simply the notch again.
        .scaleEffect(x: visible ? 1 : max(0.2, notch.width / max(1, l.body.width)), y: 1, anchor: .top)
        .opacity(visible ? 1 : 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spoken(item, resting))
    }

    private func restingName(_ r: IslandResting, _ info: BiomeInfo?, _ look: SkyLook) -> some View {
        HStack(spacing: 6) {
            restingGlyph(r, info).foregroundStyle(look.accent.color)
            Text(r.title).font(Sky.display(11.5, .bold)).lineLimit(1).minimumScaleFactor(0.75)
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder private func restingGlyph(_ r: IslandResting, _ info: BiomeInfo?) -> some View {
        if let info {
            BiomeGlyph(info: info, size: 14, night: SkyState.shared.isNight)
        } else {
            Image(systemName: r.title == "Watching" ? "binoculars.fill" : "gamecontroller.fill").font(.system(size: 11, weight: .semibold))
        }
    }

    /// The one thing that ticks: once a second, and only while there is a time to show.
    @ViewBuilder private func restingClock(_ r: IslandResting) -> some View {
        if r.endsAt != nil || r.startedAt != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(r.timer(now: context.date)).font(Sky.mono(11.5)).foregroundStyle(.white.opacity(0.86)).lineLimit(1)
            }
        }
    }

    private var introText: some View {
        Text(IslandIntro.text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.82))
            .lineLimit(1).minimumScaleFactor(0.6).padding(.horizontal, 12)
    }

    private func leftEar(_ item: IslandItem, _ info: BiomeInfo?, _ look: SkyLook, expanded: Bool) -> some View {
        HStack(spacing: 6) {
            icon(item, info, size: 14).foregroundStyle(look.accent.color)
            if expanded {
                Text(item.kind == .biome ? "RARE BIOME" : "RARE ROLL").font(.system(size: 9.5, weight: .bold)).tracking(1.1).lineLimit(1).minimumScaleFactor(0.7)
            } else {
                Text(item.title).font(Sky.display(12, .bold)).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .foregroundStyle(.white)
    }

    private func rightEar(_ item: IslandItem) -> some View {
        Text(item.detail).font(Sky.mono(11)).foregroundStyle(.white.opacity(0.82)).lineLimit(1).minimumScaleFactor(0.7)
    }

    /// The part that grows down below the camera for a rare event: the biome's own sky, fading up into the black.
    private func card(_ item: IslandItem, _ info: BiomeInfo?, _ look: SkyLook) -> some View {
        ZStack {
            LinearGradient(colors: [look.top.color, look.bottom.color], startPoint: .top, endPoint: .bottom)
            if SkyMetalView.renderer != nil { IslandSky(look: look, still: calm) }
            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.35), location: 0.38), .init(color: .black.opacity(0.25), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 7) {
                Text(item.title).font(Sky.display(27)).lineLimit(1).minimumScaleFactor(0.5)
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                islandButtons
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
        }
    }

    // MARK: under the menu bar

    @ViewBuilder private func pillIsland(_ l: IslandLayout, item: IslandItem?, resting: IslandResting?, visible: Bool) -> some View {
        let (info, look) = self.look(item?.biome ?? resting?.biome)
        let rare = l.state == .expanded
        let radius: CGFloat = rare ? 30 : min(19, l.body.height / 2)
        let shape = RoundedRectangle(cornerRadius: l.below != nil && !rare ? 16 : radius, style: .continuous)
        Group {
            if let item {
                if item.rare { expanded(item, info, look) } else { compact(item, info, look) }
            } else if let resting {
                VStack(spacing: 0) {
                    HStack(spacing: 7) {
                        restingGlyph(resting, info).foregroundStyle(look.accent.color)
                        Text(resting.title).font(Sky.display(12, .bold)).lineLimit(1).minimumScaleFactor(0.75)
                        Spacer(minLength: 4)
                        restingClock(resting)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .frame(height: l.body.height - (l.below?.height ?? 0))
                    if let below = l.below { introText.frame(height: below.height).offset(y: -3) }
                }
            }
        }
        .frame(width: l.body.width, height: l.body.height)
        .background { surface(rare: rare, look, shape) }
        .overlay { IslandComet() }
        .clipShape(shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [look.accent.color.opacity(item == nil ? 0.45 : 0.75), .white.opacity(0.12)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .shadow(color: look.accent.color.opacity(rare ? 0.45 : (item == nil ? 0.0 : 0.2)), radius: rare ? 22 : 10, y: 4)
        .offset(y: visible || calm ? 0 : -(l.body.height + 40))
        .opacity(visible ? 1 : 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spoken(item, resting))
    }

    /// The pill is control-layer glass; the open island wears the biome's own sky.
    @ViewBuilder private func surface(rare: Bool, _ look: SkyLook, _ shape: RoundedRectangle) -> some View {
        if rare {
            ZStack {
                LinearGradient(colors: [look.top.color, look.bottom.color], startPoint: .top, endPoint: .bottom)
                if SkyMetalView.renderer != nil { IslandSky(look: look, still: calm) }
                LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.30)], startPoint: .top, endPoint: .bottom)
            }
        } else if reduceTransparency {
            Color(red: 0.07, green: 0.08, blue: 0.11)
        } else if #available(macOS 26.0, *) {
            Color.black.opacity(0.55).glassEffect(.regular.tint(look.accent.color.opacity(0.25)), in: shape)
        } else {
            ZStack { Rectangle().fill(.ultraThinMaterial); Color.black.opacity(0.55); look.accent.color.opacity(0.12) }
        }
    }

    private func compact(_ item: IslandItem, _ info: BiomeInfo?, _ look: SkyLook) -> some View {
        HStack(spacing: 9) {
            icon(item, info, size: 16).foregroundStyle(look.accent.color)
            Text(item.title).font(Sky.display(13.5, .bold)).lineLimit(1)
            if !item.detail.isEmpty {
                Text(item.detail).font(Sky.mono(11.5)).foregroundStyle(.white.opacity(0.72)).lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
    }

    private func expanded(_ item: IslandItem, _ info: BiomeInfo?, _ look: SkyLook) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                icon(item, info, size: 13)
                Text(item.kind == .biome ? "RARE BIOME" : "RARE ROLL").font(.system(size: 10.5, weight: .bold)).tracking(1.5)
            }
            .opacity(0.9)
            Text(item.title).font(Sky.display(30)).lineLimit(1).minimumScaleFactor(0.5)
                .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
            HStack(spacing: 10) {
                if !item.detail.isEmpty { Text(item.detail).font(Sky.mono(12)).opacity(0.92) }
                islandButtons
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
    }

    // MARK: shared parts

    private func spoken(_ item: IslandItem?, _ resting: IslandResting?) -> String {
        if let item { return "\(item.title). \(item.detail)" }
        if let resting { return [resting.title, resting.timer(now: Date())].filter { !$0.isEmpty }.joined(separator: ", ") }
        return ""
    }

    /// The island's only buttons. Their frame is reported to the controller, which lets clicks through everywhere else.
    @ViewBuilder private var islandButtons: some View {
        let row = HStack(spacing: 6) {
            Button { island.openApp() } label: { Label("Open", systemImage: "macwindow").font(.caption.weight(.semibold)) }
                .help("Open SiverSol")
            ProfileMenu().environmentObject(AppModel.shared).labelStyle(.iconOnly).fixedSize()
            Button { island.dismiss() } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                .accessibilityLabel("Dismiss").help("Dismiss")
        }
        .controlSize(.small)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { island.buttonsFrame = $0 }
        .onDisappear { island.buttonsFrame = nil }
        // Real buttons with white text on the dark island (the dim glass ones were hard to read).
        row.buttonStyle(.sky)
    }

    @ViewBuilder private func icon(_ item: IslandItem, _ info: BiomeInfo?, size: CGFloat) -> some View {
        switch item.kind {
        case .biome:
            if let info { BiomeGlyph(info: info, size: size, night: SkyState.shared.isNight) } else { Image(systemName: "cloud.fill") }
        case .roll: Image(systemName: "sparkles").font(.system(size: size))
        case .merchant: Image(systemName: "cart.fill").font(.system(size: size))
        case .notice: Image(systemName: "battery.25percent").font(.system(size: size))
        }
    }
}

/// The open island's own patch of sky: the same renderer as the window, with one fixed scene.
private struct IslandSky: NSViewRepresentable {
    let look: SkyLook
    let still: Bool

    func makeNSView(context: Context) -> IslandSkyView { IslandSkyView() }
    func updateNSView(_ view: IslandSkyView, context: Context) {
        view.look = look
        view.still = still
        view.isPaused = still
        view.enableSetNeedsDisplay = still
        view.needsDisplay = true
    }
}

final class IslandSkyView: MTKView, MTKViewDelegate {
    var look: SkyLook?
    var still = false
    private let started = CACurrentMediaTime()

    init() {
        super.init(frame: .zero, device: SkyMetalView.renderer?.device)
        colorPixelFormat = SkyRenderer.pixelFormat
        preferredFramesPerSecond = SkyMetalView.framesPerSecond
        framebufferOnly = true
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let look, let renderer = SkyMetalView.renderer, let drawable = currentDrawable, let pass = currentRenderPassDescriptor,
              let buffer = renderer.makeCommandBuffer() else { return }
        let scene = SkyScene(look: look, motion: !still)
        // The scene is drawn as if the island were a window three times its size, so the weather reads at this scale.
        renderer.encode(scene, time: CACurrentMediaTime() - started, pixels: drawableSize, scale: drawableSize.width / max(1, bounds.width) / 1.5,
                        pass: pass, into: buffer)
        buffer.present(drawable)
        buffer.commit()
    }
}
