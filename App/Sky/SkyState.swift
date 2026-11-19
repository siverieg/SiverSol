import AppKit
import SiverCore
import SiverSky
import SwiftUI

/// What the sky is showing: the biome, the time of day and the light or dark appearance, resolved into colours.
///
/// Views watch the few published values (they change when the biome changes, and about once a minute around
/// dawn and dusk). The renderer asks `scene(at:)` for every frame and reads the plain properties, so a moving
/// sky never makes SwiftUI redraw anything.
@MainActor
final class SkyState: ObservableObject {
    static let shared = SkyState()

    /// The sky as it is (or is becoming). Text that sits on the sky takes its colour from here.
    @Published private(set) var look: SkyLook
    /// The biome the sky is showing; nil is the plain sky.
    @Published private(set) var biome: BiomeInfo?

    // Read by the renderer, never published.
    private var previous: SkyLook
    private var changedAt = Date.distantPast
    private var shockAt: Date?
    private(set) var since: Date?
    private(set) var duration: TimeInterval?
    /// Where the Dashboard's hero wants the arc, and the ring a rare biome gets, in window coordinates.
    var heroArcRect: CGRect? { didSet { publish() } }
    var heroRingRect: CGRect? { didSet { publish() } }
    /// Set by the design review: a fixed hour, a still sky, a fixed place on the arc.
    var hourOverride: Double?
    var forceStill = false { didSet { publish() } }
    /// Low Power Mode or a hot Mac: the sky is a still picture until that passes (set by `PowerWatch`).
    var powerStill = false { didSet { if powerStill != oldValue { objectWillChange.send() }; publish() } }
    var mustBeStill: Bool { forceStill || powerStill }
    var progressOverride: Double? { didSet { publish() } }
    /// Rare sky surprises that are playing (set by `EggDirector`; drawn only in the app's own window).
    var eggBoard = EggBoard() { didSet { publish() } }
    private var dark = false
    private var minuteTimer: Timer?

    nonisolated static let frontSeconds = 1.5

    private init() {
        let look = SkyModel.look(.clear, hour: Self.hour(of: Date()), dark: false)
        self.look = look
        previous = look
        // The time of day moves on by itself; one look a minute is plenty.
        minuteTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(animated: false) }
        }
        publish()
    }

    /// Hand the renderer a copy of everything it reads. The sky is drawn on its own thread, so that a busy
    /// main thread (a page being built) never makes it skip; it works from this copy, never from here.
    private func publish() {
        SkyFeed.shared.set(SkyCore(look: look, previous: previous, changedAt: changedAt, shockAt: shockAt, since: since, duration: duration,
                                   hasBiome: biome != nil, rare: biome?.isRare == true, heroArcRect: heroArcRect, heroRingRect: heroRingRect,
                                   progressOverride: progressOverride, still: mustBeStill, eggs: eggBoard))
    }

    static func hour(of date: Date) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return Double(c.hour ?? 12) + Double(c.minute ?? 0) / 60
    }

    private var hour: Double { hourOverride ?? Self.hour(of: Date()) }
    var isNight: Bool { SkyClock(hour: hour).isNight }

    /// The biome changed (or the engine stopped: nil). A weather front crosses the sky.
    func show(_ info: BiomeInfo?, since: Date?, known: Bool) {
        let changed = info?.key != biome?.key
        self.since = since
        duration = known ? info?.durationS.map(TimeInterval.init) : nil
        guard changed else { publish(); return }
        let old = biome
        biome = info
        EggDirector.shared.biomeChanged(from: old, to: info)
        if info?.isRare == true { shockAt = Date() }
        refresh(animated: true)
    }

    func setDark(_ dark: Bool) {
        guard dark != self.dark else { return }
        self.dark = dark
        refresh(animated: false)
    }

    /// Recompute the colours. `animated` starts a weather front; otherwise the sky simply is the new one.
    func refresh(animated: Bool) {
        let next = SkyModel.look(biome?.palette ?? .clear, hour: hour, dark: dark)
        defer { publish() }
        guard next != look || animated else { return }
        let now = Date()
        if animated && !Self.reduceMotion {
            // Start from whatever is on screen now, even in the middle of an earlier front.
            previous = mixProgress(now) >= 1 ? look : previous
            changedAt = now
        } else {
            previous = next
            changedAt = .distantPast
        }
        look = next
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func mixProgress(_ now: Date) -> Double {
        min(1, max(0, now.timeIntervalSince(changedAt) / Self.frontSeconds))
    }

    /// True while a front is crossing: the still sky needs redrawing until it has passed.
    func inTransition(_ now: Date = Date()) -> Bool { SkyFeed.shared.inTransition(now) }
}

/// Everything one frame of sky is made from. A plain value: the renderer's thread reads a copy.
struct SkyCore: Sendable {
    var look: SkyLook
    var previous: SkyLook
    var changedAt = Date.distantPast
    var shockAt: Date?
    var since: Date?
    var duration: TimeInterval?
    var hasBiome = false
    var rare = false
    var heroArcRect: CGRect?
    var heroRingRect: CGRect?
    var progressOverride: Double?
    var still = false
    var eggs = EggBoard()

    func mixProgress(_ now: Date) -> Double {
        min(1, max(0, now.timeIntervalSince(changedAt) / SkyState.frontSeconds))
    }

    func shockProgress(_ now: Date) -> Double? {
        guard let shockAt else { return nil }
        let p = now.timeIntervalSince(shockAt) / 2.2
        return p >= 0 && p < 1 ? p : nil
    }

    /// One frame's worth of sky. `origin` is the backdrop's top-left corner in window coordinates.
    func scene(at now: Date, origin: CGPoint, motion: Bool) -> SkyScene {
        var s = SkyScene(look: look, motion: motion && !still)
        if !eggs.isIdle { s.eggs = eggs.sky(at: now, motion: motion && !still) }
        s.from = previous
        s.mix = mixProgress(now)
        if let rect = rare ? (heroRingRect ?? heroArcRect) : heroArcRect {
            let r = rect.offsetBy(dx: -origin.x, dy: -origin.y)
            if rare, heroRingRect != nil {
                s.arc = SkyArc(center: CGPoint(x: r.midX, y: r.midY), radius: min(r.width, r.height) / 2, halfAngle: .pi)
            } else {
                s.arc = SkyArc.fitting(r)
            }
            s.rare = rare
            let weather = look.weather
            // A biome that brings its own moon keeps it; the arc then carries a plain marker.
            s.body = weather == .pumpkin ? .marker : (look.night > 0.5 ? .moon : .sun)
            s.bodyRadius = rare ? 8 : 13
            let elapsed = since.map { now.timeIntervalSince($0) } ?? now.timeIntervalSinceReferenceDate
            s.bodyProgress = progressOverride ?? SkyModel.arcProgress(elapsed: elapsed, duration: hasBiome ? duration : nil)
            s.shock = motion ? shockProgress(now) : nil
        }
        return s
    }
}

/// The latest `SkyCore`, readable from any thread.
final class SkyFeed: @unchecked Sendable {
    static let shared = SkyFeed()
    private let lock = NSLock()
    private var core: SkyCore?

    func set(_ new: SkyCore) { lock.lock(); core = new; lock.unlock() }
    private var current: SkyCore? { lock.lock(); defer { lock.unlock() }; return core }

    func scene(at now: Date, origin: CGPoint, motion: Bool) -> SkyScene? { current?.scene(at: now, origin: origin, motion: motion) }
    var still: Bool { current?.still ?? false }
    func inTransition(_ now: Date) -> Bool {
        guard let c = current else { return false }
        return c.mixProgress(now) < 1 || c.shockProgress(now) != nil
    }
}

extension RGB {
    var color: Color { Color(red: r, green: g, blue: b) }
}
