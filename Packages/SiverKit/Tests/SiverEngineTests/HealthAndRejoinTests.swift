import XCTest
import CoreGraphics
@testable import SiverCore
@testable import SiverEngine
@testable import SiverInput
@testable import SiverNotify
@testable import SiverVision

private let t0 = Date(timeIntervalSince1970: 1_795_000_000)
private func box(_ text: String, x: CGFloat = 0.5, y: CGFloat = 0.5) -> TextBox {
    TextBox(text: text, box: CGRect(x: x - 0.05, y: y - 0.01, width: 0.1, height: 0.02))
}

final class HealthStateTests: XCTestCase {
    func testHealthyGameIsNoTrouble() {
        var h = HealthState()
        for i in 0..<100 {
            h.noteFrame(hash: UInt64(i) &* 0x9E3779B97F4A7C15, now: t0.addingTimeInterval(Double(i) * 30))
            XCTAssertNil(h.evaluate(now: t0.addingTimeInterval(Double(i) * 30), robloxRunning: true, lastLogBytesAt: t0.addingTimeInterval(Double(i) * 30 - 5),
                                    screen: [box("Roll", y: 0.92), box("15m 34s left until rejoin.", y: 0.87)]))
        }
    }

    func testDisconnectLineWaitsForTheGamesOwnRejoin() {
        var h = HealthState()
        h.note(.disconnected(reason: 277, kind: "reason-received", at: t0))
        XCTAssertNil(h.evaluate(now: t0.addingTimeInterval(5), robloxRunning: true, lastLogBytesAt: t0, screen: nil), "grace period")
        XCTAssertEqual(h.evaluate(now: t0.addingTimeInterval(21), robloxRunning: true, lastLogBytesAt: t0, screen: nil),
                       .disconnectLine(reason: 277, kind: "reason-received"))
        // Sol's RNG rejoins by itself on a timer: a join right after the disconnect clears it.
        var g = HealthState()
        g.note(.disconnected(reason: 277, kind: "reason-received", at: t0))
        g.note(.joined(jobId: "x", placeId: SiverSol.solsRNGPlaceId, at: t0.addingTimeInterval(8)))
        XCTAssertNil(g.evaluate(now: t0.addingTimeInterval(60), robloxRunning: true, lastLogBytesAt: t0.addingTimeInterval(59), screen: nil))
    }

    func testProcessExitNeedsRobloxToHaveBeenRunning() {
        var never = HealthState()
        XCTAssertNil(never.evaluate(now: t0, robloxRunning: false, lastLogBytesAt: nil, screen: nil), "Roblox was never open: nothing to recover")
        var h = HealthState()
        XCTAssertNil(h.evaluate(now: t0, robloxRunning: true, lastLogBytesAt: t0, screen: nil))
        XCTAssertNil(h.evaluate(now: t0.addingTimeInterval(1), robloxRunning: false, lastLogBytesAt: t0, screen: nil), "could be a quick relaunch")
        XCTAssertEqual(h.evaluate(now: t0.addingTimeInterval(10), robloxRunning: false, lastLogBytesAt: t0, screen: nil), .processExited)
    }

    func testDeliberateQuitIsForgottenUntilRobloxRunsAgain() {
        var h = HealthState()
        _ = h.evaluate(now: t0, robloxRunning: true, lastLogBytesAt: t0, screen: nil)
        _ = h.evaluate(now: t0.addingTimeInterval(1), robloxRunning: false, lastLogBytesAt: t0, screen: nil)
        XCTAssertEqual(h.evaluate(now: t0.addingTimeInterval(10), robloxRunning: false, lastLogBytesAt: t0, screen: nil), .processExited)
        h.forgetRoblox()   // the engine calls this when the Mac was in use at the time
        XCTAssertNil(h.evaluate(now: t0.addingTimeInterval(600), robloxRunning: false, lastLogBytesAt: t0, screen: nil))
        // Opened again later, then it crashes: that one counts.
        _ = h.evaluate(now: t0.addingTimeInterval(700), robloxRunning: true, lastLogBytesAt: t0.addingTimeInterval(700), screen: nil)
        _ = h.evaluate(now: t0.addingTimeInterval(710), robloxRunning: false, lastLogBytesAt: t0.addingTimeInterval(700), screen: nil)
        XCTAssertEqual(h.evaluate(now: t0.addingTimeInterval(720), robloxRunning: false, lastLogBytesAt: t0.addingTimeInterval(700), screen: nil), .processExited)
    }

    func testDisconnectDialogOnScreenButNotInChat() {
        var h = HealthState()
        XCTAssertEqual(h.evaluate(now: t0, robloxRunning: true, lastLogBytesAt: t0, screen: [box("Disconnected"), box("Reconnect", y: 0.6)]),
                       .disconnectDialog("Disconnected"))
        XCTAssertEqual(h.evaluate(now: t0, robloxRunning: true, lastLogBytesAt: t0, screen: [box("You were kicked from this experience (Error Code: 267)")]),
                       .disconnectDialog("You were kicked from this experience (Error Code: 267)"))
        XCTAssertNil(h.evaluate(now: t0, robloxRunning: true, lastLogBytesAt: t0, screen: [box("[Bob]: i got disconnected lol", x: 0.15, y: 0.3)]))
    }

    func testFreezeWatchdogSixSilentMinutes() {
        var h = HealthState()
        // Heartbeats arrive every 120 s; up to 5 min 59 s of silence is still fine.
        XCTAssertNil(h.evaluate(now: t0.addingTimeInterval(359), robloxRunning: true, lastLogBytesAt: t0, screen: nil))
        XCTAssertEqual(h.evaluate(now: t0.addingTimeInterval(361), robloxRunning: true, lastLogBytesAt: t0, screen: nil), .frozen)
        // Fresh log bytes mean it is alive.
        XCTAssertNil(h.evaluate(now: t0.addingTimeInterval(700), robloxRunning: true, lastLogBytesAt: t0.addingTimeInterval(650), screen: nil))
        // Nothing to watch if the game is not open.
        var closed = HealthState()
        XCTAssertNil(closed.evaluate(now: t0.addingTimeInterval(4000), robloxRunning: false, lastLogBytesAt: t0, screen: nil))
    }

    func testFrozenCanAlsoRequireAStillPicture() {
        var config = HealthState.Config(); config.frozenNeedsStillFrame = true; config.frozenLogS = 600
        var h = HealthState(config: config)
        h.noteFrame(hash: 0xABCD, now: t0)
        h.noteFrame(hash: 0xFFFF_0000, now: t0.addingTimeInterval(650))
        XCTAssertNil(h.evaluate(now: t0.addingTimeInterval(660), robloxRunning: true, lastLogBytesAt: t0, screen: nil), "picture changed recently")
        h.noteFrame(hash: 0xFFFF_0001, now: t0.addingTimeInterval(720))
        XCTAssertEqual(h.evaluate(now: t0.addingTimeInterval(780), robloxRunning: true, lastLogBytesAt: t0, screen: nil), .frozen)
    }

    func testStuckOnTheStartMenuIsFixedWithoutRestartingRoblox() async {
        var h = HealthState()
        XCTAssertNil(h.evaluate(now: t0, robloxRunning: true, lastLogBytesAt: t0, screen: nil, phase: .menu))
        XCTAssertNil(h.evaluate(now: t0.addingTimeInterval(30), robloxRunning: true, lastLogBytesAt: t0, screen: nil, phase: .menu))
        XCTAssertEqual(h.evaluate(now: t0.addingTimeInterval(46), robloxRunning: true, lastLogBytesAt: t0, screen: nil, phase: .menu), .stuckInMenu)
        XCTAssertNil(h.evaluate(now: t0.addingTimeInterval(50), robloxRunning: true, lastLogBytesAt: t0, screen: nil, phase: .inGame))

        let roblox = FakeRoblox()
        roblox.phase = .menu
        roblox.screen = [box("Play", y: 0.7)]
        let report = await Rejoiner(secrets: Secrets(privateServerLink: "https://www.roblox.com/share?code=abc&type=Server"), world: roblox.world)
            .recover(from: .stuckInMenu, incidentId: "m1")
        XCTAssertTrue(report.recovered)
        XCTAssertTrue(roblox.quits.isEmpty && roblox.opened.isEmpty, "Roblox is not quit or relaunched for a menu")
        XCTAssertEqual(report.steps.map(\.label), ["detected: Stuck on the start menu", "clicked Play", "in game"])
        XCTAssertFalse(Trouble.stuckInMenu.needsRestart)
    }

    func testRareBiomeRule() {
        XCTAssertFalse(Rejoiner.mayRestart(trouble: .requested, currentBiomeIsRare: true), "a manual rejoin is refused during a rare biome too")
        XCTAssertFalse(Rejoiner.mayRestart(trouble: .frozen, currentBiomeIsRare: true), "rule 5: never restart during a rare biome…")
        XCTAssertTrue(Rejoiner.mayRestart(trouble: .processExited, currentBiomeIsRare: true), "…unless already disconnected")
        XCTAssertTrue(Rejoiner.mayRestart(trouble: .disconnectLine(reason: 277, kind: "x"), currentBiomeIsRare: true))
        XCTAssertTrue(Rejoiner.mayRestart(trouble: .frozen, currentBiomeIsRare: false))
        XCTAssertFalse(Rejoiner.mayRestart(trouble: .memoryHigh(gigabytes: 7), currentBiomeIsRare: true), "high memory never restarts during a rare biome")
    }
}

/// A scripted Roblox for the rejoiner: virtual time, and a list of what happens when.
private final class FakeRoblox: @unchecked Sendable {
    var now = t0
    var running = true
    var trayOnly = false
    var session: String? = "old"
    var phase: BiomeTracker.Phase = .inGame
    var jobId: String? = "old-server"
    /// When set, the join lands in the log that is already current (the windowless relaunch's log).
    var joinKeepsSession = false
    var opened: [URL] = []
    var quits: [Bool] = []
    var clicks: [String] = []
    var approvals: [GuardedAction] = []
    var screen: [TextBox] = []
    var deepLinkWorks = true
    var webLinkWorks = true
    var ignoresQuit = false
    var playWorks = true
    var guardianVerdict: GuardianVerdict = .approved
    private var joinAt: Date?

    func tick() {
        guard let j = joinAt, now >= j, jobId != "new-server" else { return }
        if !joinKeepsSession { session = "new" }
        jobId = "new-server"; running = true; trayOnly = false; phase = .menu
        screen = [box("Sol's RNG", y: 0.3), box("Play", y: 0.7)]
    }

    var world: Rejoiner.World {
        Rejoiner.World(
            now: { self.now },
            sleep: { self.now.addTimeInterval($0); self.tick() },
            robloxRunning: { self.running },
            gameOpen: { self.running && !self.trayOnly },
            quitRoblox: { force in
                self.quits.append(force)
                if force || !self.ignoresQuit { self.running = false; self.phase = .unknown }
            },
            open: { url in
                self.opened.append(url)
                let works = url.scheme == "roblox" ? self.deepLinkWorks : self.webLinkWorks
                if works { self.joinAt = self.now.addingTimeInterval(12) }
                return true
            },
            radar: { (self.session, self.phase, self.jobId) },
            look: { self.screen },
            approve: { self.approvals.append($0); return self.guardianVerdict },
            click: { b in
                self.clicks.append(b.text)
                if self.playWorks { self.phase = .inGame; self.screen = [box("Roll", y: 0.92)] }
                return true
            })
    }
}

final class RejoinerTests: XCTestCase {
    let secrets = Secrets(privateServerLink: "https://www.roblox.com/share?code=abc123DEF&type=Server")

    func testFullRecoveryTimeline() async {
        let roblox = FakeRoblox()
        let report = await Rejoiner(secrets: secrets, world: roblox.world).recover(from: .disconnectLine(reason: 277, kind: "reason-received"), incidentId: "i1")
        XCTAssertTrue(report.recovered)
        XCTAssertEqual(report.steps.map(\.label), ["detected: Disconnected (reason 277)", "quit Roblox", "opened the private server link",
                                                   "joined the server", "clicked Play", "in game"])
        XCTAssertEqual(roblox.quits, [false], "graceful quit, no force")
        XCTAssertEqual(roblox.opened.map(\.absoluteString), ["roblox://navigation/share_links?code=abc123DEF&type=Server"])
        XCTAssertEqual(roblox.approvals, [.clickAnchor("Play")], "the click went through Guardian")
        XCTAssertEqual(roblox.clicks, ["Play"])
        // The timeline is in order and renders as one incident embed.
        XCTAssertEqual(report.steps.map(\.at), report.steps.map(\.at).sorted())
        let ctx = RenderContext(catalog: try! BiomeCatalog.bundled(), route: RouteConfig(name: "test", profile: .rich), now: roblox.now)
        let embed = RichTemplates.incident(report, ctx).embeds[0]
        XCTAssertTrue(embed.title?.hasPrefix("🔌 Disconnected (reason 277) → recovered in ") ?? false, embed.title ?? "")
    }

    func testFallsBackToWebLinkWhenDeepLinkDoesNothing() async {
        let roblox = FakeRoblox()
        roblox.deepLinkWorks = false
        roblox.running = false
        let report = await Rejoiner(secrets: secrets, world: roblox.world).recover(from: .processExited, incidentId: "i2")
        XCTAssertTrue(report.recovered)
        XCTAssertEqual(roblox.opened.map(\.scheme), ["roblox", "https"])
        XCTAssertEqual(roblox.opened[1].host, "www.roblox.com")
        XCTAssertTrue(roblox.quits.isEmpty, "Roblox was already closed")
        XCTAssertTrue(report.steps.contains { $0.label.contains("web link") })
    }

    func testWindowlessTrayProcessIsNotQuitFirst() async {
        // After a quit, Roblox leaves a background process with no window. Nothing to quit: just open the link.
        let roblox = FakeRoblox()
        roblox.trayOnly = true
        let report = await Rejoiner(secrets: secrets, world: roblox.world).recover(from: .processExited, incidentId: "t1")
        XCTAssertTrue(report.recovered)
        XCTAssertTrue(roblox.quits.isEmpty)
        XCTAssertEqual(report.steps.map(\.label), ["detected: Roblox closed", "opened the private server link", "joined the server", "clicked Play", "in game"])
    }

    /// The live failure of 2026-11-18 14:04Z: Roblox had already relaunched windowless and started a new log before
    /// recovery began, so the join arrived in the log that was already current.
    func testJoinInTheAlreadyCurrentLogStillCounts() async {
        let roblox = FakeRoblox()
        roblox.trayOnly = true
        roblox.session = "tray-log"; roblox.jobId = nil; roblox.phase = .unknown
        roblox.joinKeepsSession = true
        let report = await Rejoiner(secrets: secrets, world: roblox.world).recover(from: .processExited, incidentId: "t2")
        XCTAssertTrue(report.recovered, "\(report.steps.map(\.label))")
        XCTAssertEqual(roblox.opened.map(\.scheme), ["roblox"], "no web-link fallback needed")
        XCTAssertEqual(roblox.session, "tray-log")
    }

    func testForcesQuitOnlyAfterTheGracePeriod() async {
        let roblox = FakeRoblox()
        roblox.ignoresQuit = true
        let report = await Rejoiner(secrets: secrets, world: roblox.world).recover(from: .frozen, incidentId: "i3")
        XCTAssertEqual(roblox.quits, [false, true])
        let forced = report.steps.first { $0.label.contains("forced") }
        XCTAssertGreaterThanOrEqual(forced!.at.timeIntervalSince(report.steps[0].at), 20)
        XCTAssertTrue(report.recovered)
    }

    func testGuardianBlockMeansNoClickAndAnHonestReport() async {
        let roblox = FakeRoblox()
        roblox.guardianVerdict = .blocked(reason: "purchase dialog", forbidden: true)
        let report = await Rejoiner(secrets: secrets, world: roblox.world).recover(from: .processExited, incidentId: "i4")
        XCTAssertFalse(report.recovered)
        XCTAssertTrue(roblox.clicks.isEmpty, "nothing is clicked without Guardian's approval")
        XCTAssertEqual(report.steps.last?.label, "stuck on the start menu: no Play or Skip button found")
    }

    func testNothingJoinsAndNoLinkConfigured() async {
        let roblox = FakeRoblox()
        roblox.deepLinkWorks = false; roblox.webLinkWorks = false
        let failed = await Rejoiner(secrets: secrets, world: roblox.world).recover(from: .processExited, incidentId: "i5")
        XCTAssertFalse(failed.recovered)
        XCTAssertEqual(failed.steps.last?.label, "no server join seen in the Roblox log")

        let none = FakeRoblox()
        let report = await Rejoiner(secrets: Secrets(), world: none.world).recover(from: .processExited, incidentId: "i6")
        XCTAssertFalse(report.recovered)
        XCTAssertTrue(none.quits.isEmpty && none.opened.isEmpty, "without a saved link nothing is quit or opened")
    }

    func testShareCodeOnlyFromTheSavedLink() {
        XCTAssertEqual(Rejoiner.shareCode(from: secrets), "abc123DEF")
        XCTAssertEqual(Rejoiner.shareCode(from: Secrets(privateServerLink: nil, privateServerShareCode: "ZZ99")), "ZZ99")
        XCTAssertNil(Rejoiner.shareCode(from: Secrets(privateServerLink: "https://evil.example/share?code=abc")), "not a roblox.com link")
        XCTAssertNil(Rejoiner.shareCode(from: Secrets(privateServerLink: "https://www.roblox.com/share?code=a%26b=1&type=Server")), "odd characters are refused")
        XCTAssertEqual(Rejoiner.deepLink(code: "abc123DEF")?.absoluteString, "roblox://navigation/share_links?code=abc123DEF&type=Server")
    }
}
