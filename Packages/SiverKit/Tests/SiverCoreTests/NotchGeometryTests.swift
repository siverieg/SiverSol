import XCTest
import CoreGraphics
@testable import SiverCore

/// The Mac this is built on has no notch, so every notch here is made up. What is tested is the arithmetic:
/// given what a screen reports, where is the notch, what counts as full screen, where may the island go.
final class NotchGeometryTests: XCTestCase {
    /// A laptop screen hanging from the top of a 1920×1080 desk, like the design review places it.
    func screen(_ p: LaptopProfile) -> ScreenShape { p.screen(midX: 960, top: 1080) }
    let plain = ScreenShape(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 0, y: 97, width: 1920, height: 953))

    func testAScreenWithoutAnInsetHasNoNotch() {
        let g = NotchGeometry(plain)
        XCTAssertFalse(g.hasNotch)
        XCTAssertNil(g.notch); XCTAssertNil(g.leftEar); XCTAssertNil(g.rightEar)
        XCTAssertFalse(g.usedFallback)
    }

    func testTheNotchIsTheGapBetweenTheTwoStripsAtFullSafeAreaHeight() {
        for p in LaptopProfile.all {
            let s = screen(p)
            let g = NotchGeometry(s)
            guard let notch = g.notch, let left = g.leftEar, let right = g.rightEar else { return XCTFail("\(p.id): no notch") }
            XCTAssertEqual(notch.width, p.notchWidth, accuracy: 0.01, p.id)
            XCTAssertEqual(notch.height, p.safeTop, p.id)
            XCTAssertEqual(notch.maxY, s.frame.maxY, "the notch touches the top of the screen")
            XCTAssertEqual(notch.midX, s.frame.midX, accuracy: 0.01)
            XCTAssertEqual(left.maxX, notch.minX); XCTAssertEqual(right.minX, notch.maxX)
            XCTAssertEqual(left.minX, s.frame.minX); XCTAssertEqual(right.maxX, s.frame.maxX)
            XCTAssertFalse(g.usedFallback)
        }
    }

    func testANotchThatIsNotCentredIsTakenFromWhatTheSystemSays() {
        // Nothing assumes the middle: the strips decide.
        let frame = CGRect(x: 0, y: 0, width: 1500, height: 900)
        let s = ScreenShape(frame: frame, safeTop: 30, auxLeft: CGRect(x: 0, y: 870, width: 500, height: 30), auxRight: CGRect(x: 740, y: 870, width: 760, height: 30))
        let g = NotchGeometry(s)
        XCTAssertEqual(g.notch, CGRect(x: 500, y: 870, width: 240, height: 30))
    }

    func testFallbackWhenTheStripsAreMissing() {
        let s = ScreenShape(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeTop: 32)
        let g = NotchGeometry(s)
        XCTAssertTrue(g.usedFallback)
        XCTAssertEqual(g.notch, CGRect(x: 756 - 100, y: 950, width: NotchGeometry.fallbackNotchWidth, height: 32), "a centred notch about 200 points wide")
        XCTAssertEqual(g.leftEar?.width, 656); XCTAssertEqual(g.rightEar?.minX, 856)
    }

    func testASecondScreenKeepsItsOwnGeometry() {
        // A notched laptop below-left of an external display: each screen answers for itself.
        let laptop = LaptopProfile.pro14.screen(midX: -756, top: 982)
        XCTAssertTrue(NotchGeometry(laptop).hasNotch)
        XCTAssertFalse(NotchGeometry(plain).hasNotch)
        XCTAssertEqual(ScreenMath.screenIndex(holding: CGRect(x: -700, y: 100, width: 600, height: 500), screens: [plain, laptop]), 1)
        XCTAssertEqual(ScreenMath.screenIndex(holding: CGRect(x: 100, y: 100, width: 600, height: 500), screens: [plain, laptop]), 0)
        XCTAssertEqual(ScreenMath.screenIndex(holding: CGRect(x: -100, y: 100, width: 600, height: 500), screens: [plain, laptop]), 0, "the screen holding most of it")
        XCTAssertNil(ScreenMath.screenIndex(holding: CGRect(x: 5000, y: 0, width: 10, height: 10), screens: [plain, laptop]))
    }

    // MARK: full screen

    func testFullScreenWithoutANotch() {
        XCTAssertTrue(FullScreenCheck.isFullScreen(window: plain.frame, screens: [plain]))
        XCTAssertFalse(FullScreenCheck.isFullScreen(window: plain.visibleFrame, screens: [plain]), "a zoomed window under the menu bar is not full screen")
        XCTAssertFalse(FullScreenCheck.isFullScreen(window: CGRect(x: 0, y: 97, width: 960, height: 953), screens: [plain]))
        // The window server measures from the top-left.
        XCTAssertTrue(FullScreenCheck.isFullScreen(windowTopLeft: CGRect(x: 0, y: 0, width: 1920, height: 1080), primaryHeight: 1080, screens: [plain]))
        XCTAssertFalse(FullScreenCheck.isFullScreen(windowTopLeft: CGRect(x: 0, y: 30, width: 960, height: 953), primaryHeight: 1080, screens: [plain]))
    }

    func testFullScreenWithANotchSitsBelowTheCamera() {
        for p in LaptopProfile.all {
            let s = p.screen(midX: p.size.width / 2, top: p.size.height)   // a laptop on its own
            let below = CGRect(x: 0, y: 0, width: p.size.width, height: p.size.height - p.safeTop)
            XCTAssertTrue(FullScreenCheck.isFullScreen(window: below, screens: [s]), "\(p.id): the usual full-screen window is shorter than its screen")
            XCTAssertTrue(FullScreenCheck.isFullScreen(window: s.frame, screens: [s]), "\(p.id): an app that draws under the camera covers the whole screen")
            XCTAssertTrue(FullScreenCheck.isFullScreen(windowTopLeft: CGRect(x: 0, y: p.safeTop, width: p.size.width, height: p.size.height - p.safeTop),
                                                       primaryHeight: p.size.height, screens: [s]), "\(p.id): the same window as the window server reports it")
            XCTAssertFalse(FullScreenCheck.isFullScreen(window: s.visibleFrame, screens: [s]), "\(p.id): a zoomed window above the Dock is not full screen")
            let windowed = CGRect(x: 40, y: 120, width: 960, height: 700)
            XCTAssertFalse(FullScreenCheck.isFullScreen(window: windowed, screens: [s]))
            XCTAssertFalse(FullScreenCheck.isFullScreen(window: windowed, screens: [s], menuBarHidden: true), "a hidden menu bar alone proves nothing")
        }
    }

    func testAFullScreenSpaceCountsEvenWhenTheWindowIsAFewPointsOff() {
        let p = LaptopProfile.air13
        let s = p.screen(midX: p.size.width / 2, top: p.size.height)
        // Letterboxed by the app: as wide as the screen, reaching the bottom, a little taller than the area below the camera.
        let odd = CGRect(x: 0, y: 0, width: p.size.width, height: p.size.height - p.safeTop + 9)
        XCTAssertFalse(FullScreenCheck.isFullScreen(window: odd, screens: [s]))
        XCTAssertTrue(FullScreenCheck.isFullScreen(window: odd, screens: [s], menuBarHidden: true))
    }

    // MARK: the menu bar icon

    func testMenuBarIconBehindTheNotchOrOffScreenIsHidden() {
        let s = screen(.air13)
        let g = NotchGeometry(s)
        let top = s.frame.maxY - 30
        let fine = CGRect(x: g.rightEar!.minX + 200, y: top, width: 28, height: 24)
        XCTAssertFalse(MenuBarIconCheck.isHidden(item: fine, screens: [s]))
        XCTAssertTrue(MenuBarIconCheck.isHidden(item: CGRect(x: g.notch!.midX - 14, y: top, width: 28, height: 24), screens: [s]), "behind the camera")
        XCTAssertTrue(MenuBarIconCheck.isHidden(item: CGRect(x: g.notch!.maxX - 10, y: top, width: 28, height: 24), screens: [s]), "half behind the camera")
        XCTAssertTrue(MenuBarIconCheck.isHidden(item: CGRect(x: -4000, y: top, width: 28, height: 24), screens: [s]), "parked off screen")
        XCTAssertTrue(MenuBarIconCheck.isHidden(item: nil, screens: [s]))
        XCTAssertTrue(MenuBarIconCheck.isHidden(item: .zero, screens: [s]))
        XCTAssertFalse(MenuBarIconCheck.isHidden(item: CGRect(x: 1700, y: 1052, width: 28, height: 24), screens: [plain]), "no notch, nothing to hide behind")
    }
}

final class IslandLayoutTests: XCTestCase {
    func screen(_ p: LaptopProfile) -> ScreenShape { p.screen(midX: 960, top: 1080) }
    let plain = ScreenShape(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 0, y: 97, width: 1920, height: 953))
    let m = IslandLayout.Metrics()

    func testOnANotchTheIslandIsTheNotchGrownSideways() {
        for p in LaptopProfile.all {
            let s = screen(p)
            let g = NotchGeometry(s)
            for state in [IslandState.resting, .compact] {
                let l = IslandLayout.make(state: state, screen: s, wanted: 10_000)
                XCTAssertEqual(l.style, .notch)
                XCTAssertEqual(l.body.height, g.notch!.height, "\(p.id) \(state): exactly as tall as the camera housing")
                XCTAssertEqual(l.body.maxY, s.frame.maxY, "it hangs from the very top")
                XCTAssertEqual(l.body.midX, g.notch!.midX, accuracy: 0.01, "centred on the notch")
                XCTAssertNil(l.below)
            }
        }
    }

    func testContentOnlyEverLivesInTheEars() {
        for p in LaptopProfile.all {
            let s = screen(p)
            let g = NotchGeometry(s)
            for state in [IslandState.resting, .compact, .expanded] {
                let l = IslandLayout.make(state: state, screen: s, wanted: 10_000, extraLine: state == .resting)
                guard let left = l.leftEar, let right = l.rightEar, let notch = l.notch else { return XCTFail("no ears") }
                XCTAssertEqual(notch, g.notch)
                XCTAssertFalse(left.intersects(notch), "\(p.id) \(state): nothing in the camera area")
                XCTAssertFalse(right.intersects(notch))
                XCTAssertEqual(left.maxX, notch.minX); XCTAssertEqual(right.minX, notch.maxX)
                XCTAssertTrue(g.leftEar!.contains(left), "never beyond the strip the system says is usable")
                XCTAssertTrue(g.rightEar!.contains(right))
                XCTAssertEqual(left.width, right.width, "the same on both sides")
                if let below = l.below { XCTAssertFalse(below.intersects(notch), "what grows down is below the camera") }
            }
        }
    }

    func testWidthIsClamped() {
        let s = screen(.pro14)
        let notch = NotchGeometry(s).notch!
        XCTAssertEqual(IslandLayout.make(state: .resting, screen: s, wanted: 10_000).body.width, notch.width + m.restingEar * 2, "resting ears are narrow")
        XCTAssertEqual(IslandLayout.make(state: .compact, screen: s, wanted: 10_000).body.width, notch.width + m.compactEar * 2)
        XCTAssertEqual(IslandLayout.make(state: .expanded, screen: s).body.width, notch.width + m.expandedEar * 2)
        XCTAssertEqual(IslandLayout.make(state: .resting, screen: s, wanted: 62).leftEar?.width, 62, "no wider than its content")
        XCTAssertEqual(IslandLayout.make(state: .resting, screen: s, wanted: 3).leftEar?.width, m.minimumEar)
        XCTAssertLessThan(IslandLayout.make(state: .resting, screen: s, wanted: 10_000).body.width, IslandLayout.make(state: .compact, screen: s, wanted: 10_000).body.width)
    }

    func testCrowdedMenuBarSqueezesTheEars() {
        // The system reports only 50 points free beside the notch: the island takes no more than that.
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let s = ScreenShape(frame: frame, safeTop: 32, auxLeft: CGRect(x: 613, y: 950, width: 50, height: 32), auxRight: CGRect(x: 849, y: 950, width: 400, height: 32))
        for state in [IslandState.resting, .compact, .expanded] {
            let l = IslandLayout.make(state: state, screen: s, wanted: 10_000)
            XCTAssertEqual(l.leftEar?.width, 50); XCTAssertEqual(l.rightEar?.width, 50)
            XCTAssertEqual(l.body.width, 186 + 100)
        }
    }

    func testARareEventGrowsDownBelowTheNotch() {
        for p in LaptopProfile.all {
            let s = screen(p)
            let notch = NotchGeometry(s).notch!
            let l = IslandLayout.make(state: .expanded, screen: s)
            XCTAssertEqual(l.body.maxY, s.frame.maxY)
            XCTAssertEqual(l.body.minY, notch.minY - m.cardHeight, "\(p.id): the card hangs below the camera housing")
            XCTAssertEqual(l.below, CGRect(x: l.body.minX, y: l.body.minY, width: l.body.width, height: m.cardHeight))
            XCTAssertEqual(l.body.midX, notch.midX, accuracy: 0.01)
        }
    }

    func testTheFirstLineHangsBelowARestingIsland() {
        let s = screen(.air13)
        let l = IslandLayout.make(state: .resting, screen: s, wanted: 80, extraLine: true)
        XCTAssertEqual(l.below?.height, m.lineHeight)
        XCTAssertEqual(l.body.height, NotchGeometry(s).notch!.height + m.lineHeight)
    }

    func testWithoutANotchItIsAPillUnderTheMenuBar() {
        for state in [IslandState.resting, .compact, .expanded] {
            let l = IslandLayout.make(state: state, screen: plain, wanted: 200)
            XCTAssertEqual(l.style, .pill)
            XCTAssertNil(l.notch); XCTAssertNil(l.leftEar)
            XCTAssertEqual(l.body.maxY, plain.visibleFrame.maxY - m.pillGap, "\(state): just under the menu bar")
            XCTAssertEqual(l.body.midX, plain.frame.midX)
        }
        XCTAssertEqual(IslandLayout.make(state: .resting, screen: plain, wanted: 200).body.size, CGSize(width: 200, height: m.restingPill.height))
        XCTAssertEqual(IslandLayout.make(state: .expanded, screen: plain).body.size, m.expandedPill)
        XCTAssertLessThanOrEqual(IslandLayout.make(state: .compact, screen: plain, wanted: 5000).body.width, 430)
    }

    func testOnlyANotchedScreenGetsTheNotchStyle() {
        // Roblox on the external display: a pill there, whatever the laptop next to it looks like.
        XCTAssertEqual(IslandLayout.make(state: .resting, screen: plain).style, .pill)
        XCTAssertEqual(IslandLayout.make(state: .resting, screen: screen(.pro16)).style, .notch)
    }

    func testOnePanelHoldsEveryState() {
        for s in LaptopProfile.all.map(screen) + [plain] {
            let panel = IslandLayout.panel(on: s)
            for (state, line) in [(IslandState.resting, true), (.resting, false), (.compact, false), (.expanded, false)] {
                XCTAssertTrue(panel.contains(IslandLayout.make(state: state, screen: s, wanted: 10_000, extraLine: line).body))
            }
            XCTAssertLessThanOrEqual(panel.maxY, s.frame.maxY)
        }
    }

    // MARK: Always Show

    func testFreshInstallGetsAlwaysShowAndAnExplicitChoiceIsKept() {
        XCTAssertEqual(IslandMode.resolve(stored: nil), .always, "nothing stored: the user never chose")
        XCTAssertEqual(IslandMode.resolve(stored: "raresOnly"), .raresOnly)
        XCTAssertEqual(IslandMode.resolve(stored: "everything"), .everything)
        XCTAssertEqual(IslandMode.resolve(stored: "off"), .off, "Off stays off")
        XCTAssertEqual(IslandMode.resolve(stored: "always"), .always)
        XCTAssertEqual(IslandMode.resolve(stored: "something else"), .always)

        // Through real defaults: reading never writes, so "never chose" stays "never chose" until they do choose.
        let name = "siversol-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(IslandMode.resolve(stored: defaults.string(forKey: IslandMode.storageKey)), .always)
        XCTAssertNil(defaults.object(forKey: IslandMode.storageKey))
        defaults.set(IslandMode.raresOnly.rawValue, forKey: IslandMode.storageKey)
        XCTAssertEqual(IslandMode.resolve(stored: defaults.string(forKey: IslandMode.storageKey)), .raresOnly)
    }

    func testTheFirstAppearanceLineShowsOnceOnly() {
        let name = "siversol-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(IslandIntro.take(defaults), "the first time")
        XCTAssertFalse(IslandIntro.take(defaults))
        XCTAssertFalse(IslandIntro.take(defaults), "never again")
        XCTAssertFalse(IslandIntro.take(UserDefaults(suiteName: name)!), "not after a relaunch either")
    }

    func testRestingShowsOnlyInAlwaysShowWhileWatchingAndNotHeldBack() {
        XCTAssertTrue(IslandRules.restingVisible(mode: .always, watching: true, hold: nil))
        XCTAssertFalse(IslandRules.restingVisible(mode: .always, watching: false, hold: nil), "it stays while SiverSol watches, and only then")
        XCTAssertFalse(IslandRules.restingVisible(mode: .raresOnly, watching: true, hold: nil))
        XCTAssertFalse(IslandRules.restingVisible(mode: .everything, watching: true, hold: nil))
        XCTAssertFalse(IslandRules.restingVisible(mode: .off, watching: true, hold: nil))
        XCTAssertFalse(IslandRules.restingVisible(mode: .always, watching: true, hold: .fullScreen))

        XCTAssertEqual(IslandRules.hold(robloxFullScreen: true, overFullScreen: false, mirrored: false), .fullScreen)
        XCTAssertNil(IslandRules.hold(robloxFullScreen: true, overFullScreen: true, mirrored: false), "unless the user asked for it over full screen")
        XCTAssertEqual(IslandRules.hold(robloxFullScreen: false, overFullScreen: true, mirrored: true), .mirrored)
        XCTAssertNil(IslandRules.hold(robloxFullScreen: false, overFullScreen: false, mirrored: false))
    }

    func testAlwaysShowAnnouncesRaresLikeRaresOnly() {
        let now = Date()
        var q = IslandQueue(mode: .always)
        q.offer(IslandItem(id: "a", kind: .biome, title: "RAINY", detail: "", biome: "RAINY", rare: false, at: now), now: now)
        XCTAssertNil(q.tick(now: now), "ordinary news is not announced: the resting island already shows the biome")
        q.offer(IslandItem(id: "b", kind: .biome, title: "GLITCHED", detail: "", biome: "GLITCHED", rare: true, at: now), now: now)
        XCTAssertEqual(q.tick(now: now)?.id, "b")
    }

    func testRestingText() {
        XCTAssertEqual(IslandResting.displayName("PUMPKIN MOON"), "Pumpkin Moon")
        XCTAssertEqual(IslandResting.clock(86), "1:26")
        XCTAssertEqual(IslandResting.clock(3729), "1:02:09")
        XCTAssertEqual(IslandResting.clock(-4), "0:00")
        let now = Date(timeIntervalSince1970: 1_000_000)
        let timed = IslandResting(biome: "RAINY", title: "Rainy", endsAt: now.addingTimeInterval(70), startedAt: now.addingTimeInterval(-50), rare: false)
        XCTAssertEqual(timed.timer(now: now), "1:10", "a countdown while the biome has time left")
        XCTAssertEqual(timed.timer(now: now.addingTimeInterval(80)), "2:10", "then how long it has been")
        XCTAssertEqual(IslandResting(biome: nil, title: "Watching", endsAt: nil, startedAt: nil, rare: false).timer(now: now), "")
    }
}

final class GameFrameTests: XCTestCase {
    /// The Mac mini's window, as measured: 960×953 on screen, the game drawn 960×921.
    let mini = GameFrame(window: CGRect(x: 0, y: 30, width: 960, height: 953), titleBar: 32, scale: 1)

    func testTheTitleBarComesFromTheLogAndTheWindowTogether() {
        XCTAssertEqual(GameChrome.titleBar(window: CGSize(width: 960, height: 953), render: (960, 921), fullScreen: false, systemTitleBar: 28), 32, "measured, not assumed")
        XCTAssertEqual(GameChrome.titleBar(window: CGSize(width: 960, height: 953), render: (1920, 1842), fullScreen: false, systemTitleBar: 28), 32, "the same window on a Retina display")
        XCTAssertEqual(GameChrome.titleBar(window: CGSize(width: 1470, height: 919), render: (2940, 1838), fullScreen: true, systemTitleBar: 32), 0, "full screen below a notch")
        XCTAssertEqual(GameChrome.titleBar(window: CGSize(width: 1470, height: 919), render: (1470, 919), fullScreen: true, systemTitleBar: 32), 0, "drawn at half resolution: only the proportions matter")
        // No usable log line: none in full screen, the system's standard height otherwise.
        XCTAssertEqual(GameChrome.titleBar(window: CGSize(width: 960, height: 953), render: nil, fullScreen: false, systemTitleBar: 32), 32)
        XCTAssertEqual(GameChrome.titleBar(window: CGSize(width: 1920, height: 1080), render: nil, fullScreen: true, systemTitleBar: 32), 0)
        // A log line from before a resize does not fit the window: it is not believed.
        XCTAssertEqual(GameChrome.titleBar(window: CGSize(width: 1400, height: 700), render: (960, 921), fullScreen: false, systemTitleBar: 32), 32)
    }

    func testContentIsTheWindowWithoutItsTitleBar() {
        XCTAssertEqual(mini.content, CGRect(x: 0, y: 62, width: 960, height: 921))
        XCTAssertEqual(mini.pixelSize, CGSize(width: 960, height: 921))
        XCTAssertEqual(GameFrame(window: mini.window, titleBar: 32, scale: 2).pixelSize, CGSize(width: 1920, height: 1842), "pixels are points times the scale")
        XCTAssertEqual(GameFrame(window: CGRect(x: 0, y: 37, width: 1470, height: 919)).content, CGRect(x: 0, y: 37, width: 1470, height: 919), "full screen: all of it")
    }

    func testPointsAndRatiosRoundTrip() {
        let p = mini.point(x: 0.25, y: 0.5)
        XCTAssertEqual(p, CGPoint(x: 240, y: 62 + 460.5))
        let r = mini.ratio(of: p)!
        XCTAssertEqual(r.x, 0.25, accuracy: 1e-9); XCTAssertEqual(r.y, 0.5, accuracy: 1e-9)
        XCTAssertNil(mini.ratio(of: CGPoint(x: 100, y: 45)), "a point on the title bar is not in the game")
        XCTAssertEqual(mini.ratio(of: CGPoint(x: 100, y: 45), clamp: true)?.y, 0)
        XCTAssertNil(mini.ratio(of: CGPoint(x: 961, y: 500)))
    }

    func testPixelsAndPointsAreKeptApart() {
        let retina = GameFrame(window: CGRect(x: 100, y: 50, width: 960, height: 953), titleBar: 32, scale: 2)
        // Pixel (960, 200) of a Retina screenshot of the game is point (480, 100) inside the game area.
        XCTAssertEqual(retina.point(pixelX: 960, pixelY: 200), CGPoint(x: 580, y: 182))
        XCTAssertEqual(mini.point(pixelX: 960, pixelY: 200), CGPoint(x: 960, y: 262))
        // The rows of a whole-window screenshot that hold the game, at either density.
        XCTAssertEqual(mini.contentCrop(inCapture: CGSize(width: 960, height: 953)), CGRect(x: 0, y: 32, width: 960, height: 921))
        XCTAssertEqual(retina.contentCrop(inCapture: CGSize(width: 1920, height: 1906)), CGRect(x: 0, y: 64, width: 1920, height: 1842))
        XCTAssertEqual(GameFrame(window: mini.window).contentCrop(inCapture: CGSize(width: 960, height: 953)), CGRect(x: 0, y: 0, width: 960, height: 953))
    }

    func testTheSameSpotInTheGameOnAMacMiniWindowAndAFullScreenMacBook() {
        // A button 80% of the way down the game, in the middle.
        let onMini = mini.point(x: 0.5, y: 0.8)
        XCTAssertEqual(onMini, CGPoint(x: 480, y: 30 + 32 + 0.8 * 921))
        // 13" Air, Roblox in full screen below the camera: no title bar, and the window starts under the notch.
        let air = GameFrame(window: CGRect(x: 0, y: 37, width: 1470, height: 919), titleBar: 0, scale: 2)
        XCTAssertEqual(air.point(x: 0.5, y: 0.8), CGPoint(x: 735, y: 37 + 0.8 * 919))
        // Measured against the whole window instead, the same ratio would land 6 points too high on the mini.
        let wrong = mini.window.minY + 0.8 * mini.window.height
        XCTAssertEqual(onMini.y - wrong, 32 * 0.2, accuracy: 0.001)
    }

    func testOldRegionsCoverExactlyTheSamePixelsOnTheReferenceWindow() {
        // Regions were measured as ratios of the whole 953-point window. As content ratios they must mark the
        // same rows of the screen, or the Mac mini would start reading the chat differently.
        for old in [CGRect(x: 0, y: 0.10, width: 0.22, height: 0.55), CGRect(x: 0, y: 0.10, width: 0.42, height: 0.55), CGRect(x: 0.72, y: 0.035, width: 0.28, height: 0.14)] {
            let new = GameChrome.contentRegion(fromLegacyWindow: old)
            let topBefore = old.minY * 953, bottomBefore = old.maxY * 953
            let topNow = 32 + new.minY * 921, bottomNow = 32 + new.maxY * 921
            XCTAssertEqual(topNow, topBefore, accuracy: 0.001)
            XCTAssertEqual(bottomNow, bottomBefore, accuracy: 0.001)
            XCTAssertEqual(new.minX, old.minX); XCTAssertEqual(new.width, old.width)
            // And back again, for a video that shows the whole window.
            let back = mini.windowRegion(fromContent: new)
            XCTAssertEqual(back.minY, old.minY, accuracy: 1e-9); XCTAssertEqual(back.height, old.height, accuracy: 1e-9)
        }
        XCTAssertEqual(GameChrome.contentRegion(fromLegacyWindow: CGRect(x: 0, y: 0, width: 1, height: 0.02)).minY, 0, "never above the game")
    }
}

final class PowerTests: XCTestCase {
    func battery(_ state: String, _ now: Int, minutes: Int = -1) -> [[String: Any]] {
        [["Type": "InternalBattery", "Is Present": true, "Power Source State": state, "Current Capacity": now, "Max Capacity": 100, "Time to Empty": minutes]]
    }

    func testAMacWithoutABatteryIsNeverOnBattery() {
        XCTAssertEqual(PowerReading.parse([]), .desktop)
        XCTAssertEqual(PowerReading.parse([["Type": "UPS", "Power Source State": "Battery Power", "Current Capacity": 50, "Max Capacity": 100]]), .desktop, "a UPS is not a laptop battery")
        var guardian = BatteryGuard()
        XCTAssertNil(guardian.note(.desktop))
    }

    func testReadingTheBattery() {
        XCTAssertEqual(PowerReading.parse(battery("AC Power", 80)), PowerReading(hasBattery: true, onBattery: false, percent: 80))
        XCTAssertEqual(PowerReading.parse(battery("Battery Power", 18, minutes: 40)), PowerReading(hasBattery: true, onBattery: true, percent: 18, minutesLeft: 40))
        XCTAssertNil(PowerReading.parse(battery("Battery Power", 60)).minutesLeft, "still being estimated")
        XCTAssertEqual(PowerReading.parse([["Type": "InternalBattery", "Power Source State": "Battery Power", "Current Capacity": 4100, "Max Capacity": 5000]]).percent, 82)
    }

    func testBatteryGuardSaysItOnceAndAgainWhenLow() {
        var g = BatteryGuard()
        let t = Date(timeIntervalSince1970: 1_000_000)
        func on(_ percent: Int, _ minutes: Int? = nil) -> PowerReading { PowerReading(hasBattery: true, onBattery: true, percent: percent, minutesLeft: minutes) }
        let plugged = PowerReading(hasBattery: true, onBattery: false, percent: 90)
        XCTAssertNil(g.note(plugged, now: t))
        XCTAssertEqual(g.note(on(64, 190), now: t.addingTimeInterval(5)), .onBattery(percent: 64, minutesLeft: 190))
        XCTAssertNil(g.note(on(63, 185), now: t.addingTimeInterval(10)), "said once")
        XCTAssertNil(g.note(on(20, 50), now: t.addingTimeInterval(3000)), "20% is not below 20%")
        XCTAssertEqual(g.note(on(18, 40), now: t.addingTimeInterval(3600)), .low(percent: 18, minutesLeft: 40))
        XCTAssertNil(g.note(on(12, 20), now: t.addingTimeInterval(4000)), "low is said once too")
        // Plugged in and out again: a new unplug is a new message, but a loose cable is not a stream of them.
        XCTAssertNil(g.note(plugged, now: t.addingTimeInterval(4100)))
        XCTAssertNil(g.note(on(30), now: t.addingTimeInterval(4150)), "within ten minutes of the last message")
        XCTAssertNil(g.note(plugged, now: t.addingTimeInterval(5000)))
        XCTAssertEqual(g.note(on(55), now: t.addingTimeInterval(6000)), .onBattery(percent: 55, minutesLeft: nil))
    }

    func testUnpluggedWhileAlreadyLowIsOneMessage() {
        var g = BatteryGuard()
        XCTAssertEqual(g.note(PowerReading(hasBattery: true, onBattery: true, percent: 9, minutesLeft: 12)), .low(percent: 9, minutesLeft: 12))
        XCTAssertNil(g.note(PowerReading(hasBattery: true, onBattery: true, percent: 8, minutesLeft: 10)))
    }

    func testTheWordsAreCalm() {
        XCTAssertEqual(BatteryGuard.Alert.onBattery(percent: 18, minutesLeft: 40).sentence, "Your MacBook is on battery, 18%, about 40 min left")
        XCTAssertEqual(BatteryGuard.Alert.onBattery(percent: 64, minutesLeft: nil).sentence, "Your MacBook is on battery, 64%")
        XCTAssertEqual(BatteryGuard.Alert.low(percent: 18, minutesLeft: 95).sentence, "Your MacBook is down to 18% on battery, about 1 h 35 min left")
        XCTAssertEqual(BatteryGuard.Alert.onBattery(percent: 18, minutesLeft: 40).short, "On battery · 18%")
        for alert in [BatteryGuard.Alert.onBattery(percent: 5, minutesLeft: 3), .low(percent: 5, minutesLeft: 3)] {
            XCTAssertFalse(alert.sentence.contains("!"))
        }
    }

    func testLowPowerModeAndHeatStopTheDecorationOnly() {
        XCTAssertFalse(PowerSaving.decorationStill(lowPowerMode: false, thermal: .nominal))
        XCTAssertFalse(PowerSaving.decorationStill(lowPowerMode: false, thermal: .fair))
        XCTAssertTrue(PowerSaving.decorationStill(lowPowerMode: true, thermal: .nominal))
        XCTAssertTrue(PowerSaving.decorationStill(lowPowerMode: false, thermal: .serious))
        XCTAssertTrue(PowerSaving.decorationStill(lowPowerMode: false, thermal: .critical))
    }

    func testABatteryNoticeShowsInEveryModeButOff() {
        let now = Date()
        let notice = IslandItem(id: "battery-1", kind: .notice, title: "On battery · 18%", detail: "about 40 min", biome: nil, rare: false, at: now)
        for mode in [IslandMode.always, .raresOnly, .everything] {
            var q = IslandQueue(mode: mode)
            q.offer(notice, now: now)
            XCTAssertEqual(q.tick(now: now)?.id, "battery-1", "\(mode)")
        }
        var off = IslandQueue(mode: .off)
        off.offer(notice, now: now)
        XCTAssertNil(off.tick(now: now))
    }
}
