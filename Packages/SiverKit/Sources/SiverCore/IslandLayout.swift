import CoreGraphics
import Foundation

/// How much of itself the island is showing.
public enum IslandState: String, Equatable, Sendable {
    /// Always Show: the biome and its timer, nothing else.
    case resting
    /// An ordinary announcement: one line.
    case compact
    /// A rare biome or a rare roll: the full card.
    case expanded
}

/// Where the Biome Island goes on one screen. Pure geometry: the panel and the view both draw from this, and
/// the tests check it against made-up laptops.
///
/// On a screen with a notch the island is the notch grown sideways: a black shape exactly as tall as the
/// camera housing and centred on it, with content only in the two "ears" beside the camera. A rare event
/// grows it downwards. On a screen without a notch it is a pill under the menu bar.
public struct IslandLayout: Equatable, Sendable {
    public enum Style: String, Sendable { case pill, notch }

    public var style: Style
    public var state: IslandState
    /// The visible shape, in Cocoa screen coordinates.
    public var body: CGRect
    /// Notch style: the two strips beside the camera where content is drawn.
    public var leftEar: CGRect?
    public var rightEar: CGRect?
    /// The camera housing. Nothing is ever drawn here.
    public var notch: CGRect?
    /// The part below the menu bar strip: the rare card, or the one-time first line.
    public var below: CGRect?

    public struct Metrics: Equatable, Sendable {
        /// The widest an ear may be in each state. Resting ears are narrow so they cover few menu bar items.
        public var restingEar: CGFloat = 116
        public var compactEar: CGFloat = 150
        public var expandedEar: CGFloat = 124
        public var minimumEar: CGFloat = 40
        public var cardHeight: CGFloat = 104
        public var lineHeight: CGFloat = 24
        public var pillGap: CGFloat = 6
        public var restingPill = CGSize(width: 210, height: 30)
        public var compactPillHeight: CGFloat = 38
        public var compactPillWidths: ClosedRange<CGFloat> = 250...430
        public var expandedPill = CGSize(width: 430, height: 118)
        public init() {}
    }

    /// - Parameters:
    ///   - wanted: how wide the content would like to be: one ear (notch) or the whole pill (no notch).
    ///   - extraLine: the one-time first line under a resting island.
    public static func make(state: IslandState, screen: ScreenShape, wanted: CGFloat = 0, extraLine: Bool = false, metrics m: Metrics = Metrics()) -> IslandLayout {
        let geometry = NotchGeometry(screen)
        guard let notch = geometry.notch, let left = geometry.leftEar, let right = geometry.rightEar else {
            return pill(state: state, screen: screen, wanted: wanted, extraLine: extraLine, metrics: m)
        }
        let cap: CGFloat
        switch state {
        case .resting: cap = m.restingEar
        case .compact: cap = m.compactEar
        case .expanded: cap = m.expandedEar
        }
        // Never past the strips the system says are usable, and the same on both sides so the shape stays
        // centred on the camera.
        let room = max(0, min(left.width, right.width))
        let ear = min(room, min(cap, max(m.minimumEar, state == .expanded ? cap : wanted)))
        var extra: CGFloat = 0
        if state == .expanded { extra = m.cardHeight } else if extraLine { extra = m.lineHeight }
        let body = CGRect(x: notch.minX - ear, y: notch.minY - extra, width: notch.width + ear * 2, height: notch.height + extra)
        return IslandLayout(style: .notch, state: state, body: body,
                            leftEar: CGRect(x: notch.minX - ear, y: notch.minY, width: ear, height: notch.height),
                            rightEar: CGRect(x: notch.maxX, y: notch.minY, width: ear, height: notch.height),
                            notch: notch,
                            below: extra > 0 ? CGRect(x: body.minX, y: body.minY, width: body.width, height: extra) : nil)
    }

    private static func pill(state: IslandState, screen: ScreenShape, wanted: CGFloat, extraLine: Bool, metrics m: Metrics) -> IslandLayout {
        var size: CGSize
        switch state {
        case .resting: size = CGSize(width: max(150, min(m.restingPill.width, wanted > 0 ? wanted : m.restingPill.width)), height: m.restingPill.height)
        case .compact: size = CGSize(width: min(m.compactPillWidths.upperBound, max(m.compactPillWidths.lowerBound, wanted)), height: m.compactPillHeight)
        case .expanded: size = m.expandedPill
        }
        var below: CGFloat = 0
        if state == .resting, extraLine {
            below = m.lineHeight
            size.width = max(size.width, 420)
        }
        size.width = min(size.width, max(120, screen.frame.width - 40))
        // Under the menu bar. When the menu bar is hidden the visible frame reaches the top of the screen.
        let top = min(screen.visibleFrame.maxY, screen.frame.maxY - screen.safeTop) - m.pillGap
        let body = CGRect(x: screen.frame.midX - size.width / 2, y: top - size.height - below, width: size.width, height: size.height + below)
        return IslandLayout(style: .pill, state: state, body: body, leftEar: nil, rightEar: nil, notch: nil,
                            below: below > 0 ? CGRect(x: body.minX, y: body.minY, width: body.width, height: below) : nil)
    }

    /// One frame big enough for every state on this screen, so the panel never has to move while the island
    /// changes shape. The shape hangs from the top centre of it.
    public static func panel(on screen: ScreenShape, metrics m: Metrics = Metrics(), margin: CGFloat = 36) -> CGRect {
        let states: [(IslandState, Bool)] = [(.resting, true), (.compact, false), (.expanded, false)]
        var union = CGRect.null
        for (state, line) in states {
            union = union.union(make(state: state, screen: screen, wanted: 10_000, extraLine: line, metrics: m).body)
        }
        return CGRect(x: union.minX - margin, y: union.minY - margin, width: union.width + margin * 2, height: union.height + margin)
    }
}

/// Reasons the island stays away although there is something to show.
public enum IslandHold: String, Equatable, Sendable {
    /// Roblox is in full screen and the user did not ask to see the island there.
    case fullScreen
    /// The screen is being mirrored to another display (a projector, AirPlay).
    case mirrored
}

public enum IslandRules {
    public static func hold(robloxFullScreen: Bool, overFullScreen: Bool, mirrored: Bool) -> IslandHold? {
        if mirrored { return .mirrored }
        if robloxFullScreen && !overFullScreen { return .fullScreen }
        return nil
    }

    /// Does the resting island show right now? Only in Always Show, only while SiverSol is watching.
    public static func restingVisible(mode: IslandMode, watching: Bool, hold: IslandHold?) -> Bool {
        mode == .always && watching && hold == nil
    }
}

/// What the resting island says: the biome on the left, its timer on the right.
public struct IslandResting: Equatable, Sendable {
    public var biome: BiomeKey?
    public var title: String
    /// When the biome is expected to end (a countdown), or nil.
    public var endsAt: Date?
    /// When it started (counted up when there is no end).
    public var startedAt: Date?
    public var rare: Bool

    public init(biome: BiomeKey?, title: String, endsAt: Date?, startedAt: Date?, rare: Bool) {
        self.biome = biome; self.title = title; self.endsAt = endsAt; self.startedAt = startedAt; self.rare = rare
    }

    /// The name as the island shows it: "Pumpkin Moon", not "PUMPKIN MOON".
    public static func displayName(_ key: String) -> String {
        key.lowercased().split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// "1:26", "12:05", "1:02:09". Never negative.
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    public func timer(now: Date) -> String {
        if let endsAt, endsAt > now { return Self.clock(endsAt.timeIntervalSince(now)) }
        if let startedAt { return Self.clock(now.timeIntervalSince(startedAt)) }
        return ""
    }
}

/// The first time the resting island appears, ever, it carries one extra line for a few seconds.
public enum IslandIntro {
    public static let key = "islandIntroShown"
    public static let seconds: TimeInterval = 6
    public static let text = "Stays here while SiverSol watches · you can turn this off in Settings"

    /// True exactly once for a given defaults store.
    public static func take(_ defaults: UserDefaults) -> Bool {
        if defaults.bool(forKey: key) { return false }
        defaults.set(true, forKey: key)
        return true
    }
}

/// The words behind the "?" next to the island's setting. Each sentence is a claim about the code: the
/// island's panel never becomes key, lets clicks through, ticks once a second and has no moving sky at rest.
public enum IslandGuide {
    public static let title = "Biome Island"
    public static let symbol = "capsule.tophalf.filled"
    public static let button = "Show an example"
    public static let parts: [(id: String, heading: String, text: String)] = [
        ("what", "What it is", "A small live view of the biome and its timer, beside the notch or at the top of the screen."),
        ("why", "Why it is on", "It is on by default so you can see the sky without opening SiverSol."),
        ("quieter", "Turning it off or down", "“Always show” keeps it up while SiverSol watches. “Rares only” shows it only for rare biomes and rare rolls. “Off” hides it. “Also over full-screen Roblox” decides whether it shows while Roblox fills the screen."),
        ("never", "What it never does", "It never takes a click from Roblox and never takes the keyboard. Macro clicks pass straight through it."),
        ("cost", "What it costs", "About nothing. It updates once a second and does not animate while resting."),
    ]
}
