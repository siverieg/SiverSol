import AppKit
import SiverCore
import SwiftUI

// Rare sky surprises, app side. This folder must never import SiverNotify or touch the notifier: a surprise
// is something the sky does on this Mac's screen and nowhere else (`EggIsolationTests` reads these files).

/// A visit from Glimmer: the line it says and when it arrived.
struct GlimmerVisit: Equatable {
    var line: String
    var began: Date
}

/// Decides when a surprise happens, plays it, and remembers that it was found.
///
/// Rolls are only made while someone is present: a SiverSol window or the island is on screen, the display is
/// awake, and the Mac was used in the last ten minutes. A surprise is only rolled where it could be seen (the
/// window for the sky's, the island for the island's), never during a rare biome and never while a macro is
/// recording or playing. The generator is the system's local one. Nothing here reads or changes anything in
/// the game.
@MainActor
final class EggDirector: ObservableObject {
    static let shared = EggDirector()

    @Published private(set) var found: [SkyEgg: Date] = [:]
    @Published private(set) var glimmer: GlimmerVisit?
    @Published private(set) var cometBegan: Date?
    /// The design review shows a made-up collection without touching the real one.
    var foundOverride: [SkyEgg: Date]? { didSet { found = foundOverride ?? store.found } }

    let store = EggStore()
    private var roller = EggRoller(generator: SystemRandomNumberGenerator())
    private var clock = EggClock()
    private var board = EggBoard() { didSet { if board != oldValue { SkyState.shared.eggBoard = board } } }
    private var timer: Timer?
    private var lastTick = Date()
    private var twinHour: Int?

    var enabled: Bool {
        get { store.enabled }
        set { store.enabled = newValue; objectWillChange.send(); if !newValue { stopEverything() } }
    }

    var hunter: Bool { found.count == SkyEgg.allCases.count }

    private init() { found = store.found }

    /// Start the slow clock that counts watched time. Not used by the design review, which only forces things.
    func start() {
        guard timer == nil, !DesignReview.isOn else { return }
        lastTick = Date()
        let t = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 5
        timer = t
    }

    private func conditions() -> EggConditions {
        let model = AppModel.shared
        let status = model.macroStatus
        return EggConditions(enabled: store.enabled, windowVisible: WindowWatch.shared.visible, islandVisible: IslandController.shared.isOnScreen,
                             rareBiome: model.isRunning && model.currentBiome?.isRare == true,
                             macroBusy: status.recording != .idle || status.playing != nil || status.autoClicking,
                             awakeAndUsed: Self.awakeAndUsed)
    }

    /// The display is awake and the keyboard, mouse or trackpad was touched in the last ten minutes. Both come
    /// from the system and need no permission: the idle time is one number, how long since the last real input
    /// (SiverSol's own synthetic key presses do not count), and nothing about what was typed or clicked.
    static var awakeAndUsed: Bool {
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
        let asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        return EggPresence.isPresent(windowVisible: true, islandVisible: true, displayAsleep: asleep, idleSeconds: idle)
    }

    /// Surprises that are playing now are not rolled again until they have finished.
    private func playing(_ now: Date) -> Set<SkyEgg> {
        var out = Set(SkyEgg.allCases.filter { board.isShowing($0, at: now) })
        if glimmer != nil { out.insert(.glimmer) }
        return out
    }

    private func tick() {
        let now = Date()
        let elapsed = min(120, now.timeIntervalSince(lastTick))
        lastTick = now
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let cond = conditions()
        // Only minutes with someone present count: there are no hidden rolls.
        let moments = clock.advance(by: elapsed, present: cond.present, hour: hour)
        for moment in moments { for egg in roller.roll(moment, conditions: cond, skipping: playing(now)) { play(egg, at: now) } }

        var next = board
        next.tidy(now: now)
        // Twin moons stay for the rest of the hour they appeared in.
        if let h = twinHour, h != hour { next.stop(.twinMoons); twinHour = nil }
        // Seasonal: on the date, not by luck. In-app only, and never over a rare biome's own sky.
        let season = cond.enabled && cond.windowVisible && !cond.rareBiome ? SeasonalEgg.active(at: now, calendar: cal) : []
        next.bats = season.contains(.halloweenBats) && SkyState.shared.isNight
        if season.contains(.newYearFireworks) {
            if next.fireworksBegan == nil { next.fireworksBegan = cal.startOfDay(for: now) }
        } else {
            next.fireworksBegan = nil
        }
        board = next
        if let g = glimmer, now.timeIntervalSince(g.began) > (SkyEgg.glimmer.seconds ?? 14) { glimmer = nil }
    }

    /// The biome changed (called by the sky when it shows a new one).
    func biomeChanged(from old: BiomeInfo?, to new: BiomeInfo?) {
        guard !DesignReview.isOn else { return }
        let now = Date()
        // The golden sun lasts for the rest of the biome it appeared in.
        var next = board
        next.stop(.goldenSun)
        board = next
        guard old != nil || new != nil, AppModel.shared.isRunning else { return }
        let cond = conditions()
        if old?.key.value == "RAINY" { for egg in roller.roll(.rainyEnded, conditions: cond, skipping: playing(now)) { play(egg, at: now) } }
        for egg in roller.roll(.biomeChange, conditions: cond, skipping: playing(now)) { play(egg, at: now) }
    }

    /// The island opened to announce something.
    func islandExpanded() {
        guard !DesignReview.isOn else { return }
        for egg in roller.roll(.islandExpanded, conditions: conditions()) { play(egg, at: Date()) }
    }

    private func play(_ egg: SkyEgg, at now: Date) {
        switch egg {
        case .glimmer:
            var g = SystemRandomNumberGenerator()
            glimmer = GlimmerVisit(line: Glimmer.line(using: &g), began: now)
        case .islandComet:
            cometBegan = now
        case .twinMoons:
            twinHour = Calendar.current.component(.hour, from: now)
            var next = board; next.start(egg, at: now); board = next
        default:
            var next = board; next.start(egg, at: now); board = next
        }
        if foundOverride == nil, store.record(egg, at: now) { found = store.found }
    }

    private func stopEverything() {
        board = EggBoard()
        glimmer = nil
        cometBegan = nil
    }

    // MARK: design review only (never reachable from the app's own interface)

    /// Show one surprise now, for a picture. Nothing is recorded as found.
    func force(_ name: String) {
        let now = Date()
        var next = EggBoard()
        glimmer = nil
        cometBegan = nil
        switch name {
        case "bats": next.bats = true
        case "fireworks": next.fireworksBegan = now.addingTimeInterval(-1.2)
        case "glimmer": glimmer = GlimmerVisit(line: Glimmer.lines[0], began: now.addingTimeInterval(-5))
        // Timed so that the picture, taken about a second and a half later, catches them in mid-flight.
        case "islandComet": cometBegan = now.addingTimeInterval(1.0)
        case "shootingStar": next.start(.shootingStar, at: now.addingTimeInterval(0.7), until: now.addingTimeInterval(60))
        default:
            if let egg = SkyEgg(rawValue: name) { next.start(egg, at: now.addingTimeInterval(-5), until: now.addingTimeInterval(600)) }
        }
        board = next
    }

    func clearForced() { stopEverything() }
}
