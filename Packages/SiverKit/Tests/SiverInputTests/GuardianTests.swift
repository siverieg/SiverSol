import XCTest
import AppKit
import CoreGraphics
@testable import SiverInput
@testable import SiverVision

/// Draws a fake Roblox-style screen with text at window-relative positions, so real Vision OCR can read it.
/// Real screenshots of the forbidden dialogs are not recorded on purpose: the hard rules forbid opening them.
func renderScreen(_ items: [(text: String, x: CGFloat, y: CGFloat, size: CGFloat)], width: Int = 960, height: Int = 953) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns
    for item in items {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: item.size), .foregroundColor: NSColor.white]
        let s = NSAttributedString(string: item.text, attributes: attrs)
        let size = s.size()
        // x, y are the text's center as window ratios with a top-left origin.
        s.draw(at: CGPoint(x: item.x * CGFloat(width) - size.width / 2, y: (1 - item.y) * CGFloat(height) - size.height / 2))
    }
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

let hud: [(text: String, x: CGFloat, y: CGFloat, size: CGFloat)] = [
    ("Roll", 0.5, 0.925, 22), ("Auto roll : ON", 0.34, 0.925, 14), ("Quick roll : ON", 0.66, 0.925, 14),
    ("[ NORMAL ]", 0.06, 0.845, 14), ("MOST ROLLED", 0.78, 0.35, 16),
]

final class GuardianPolicyTests: XCTestCase {
    let policy = GuardianPolicy()

    func box(_ text: String, x: CGFloat = 0.5, y: CGFloat = 0.5) -> TextBox {
        TextBox(text: text, box: CGRect(x: x - 0.05, y: y - 0.01, width: 0.1, height: 0.02))
    }

    func testNormalHUDAllowsHarmlessKey() {
        let screen = [box("Roll", y: 0.92), box("Auto roll : ON", x: 0.34, y: 0.92), box("[ NORMAL ]", x: 0.06, y: 0.85), box("MOST ROLLED", x: 0.78, y: 0.35)]
        XCTAssertEqual(policy.evaluate(.key("space"), screen: screen), .approved)
    }

    func testBlindMeansNoInput() {
        guard case .blocked(_, let forbidden) = policy.evaluate(.key("space"), screen: nil) else { return XCTFail("must block when the screen cannot be read") }
        XCTAssertFalse(forbidden)
        XCTAssertEqual(policy.evaluate(.escape, screen: nil), .approved, "Escape is always allowed")
    }

    func testEveryForbiddenContextBlocksEveryAction() {
        let dangerous: [[TextBox]] = [
            [box("Buy 400 Robux?")], [box("Purchase"), box("Cancel")], [box("Confirm Purchase")], [box("Buy")], [box("Confirm")],
            [box("Buy Now")], [box("Get Robux")], [box("Roblox Premium")],
            [box("Delete Aura?")], [box("Are you sure you want to delete this aura?")], [box("Auto Delete")], [box("Sell")],
            [box("Sell all")], [box("Trade Request")], [box("Trading with Player")], [box("Lock")], [box("Unlock")], [box("Lock Aura")],
        ]
        let actions: [GuardedAction] = [.key("space"), .clickAnchor("Play"), .useItem(name: "Heavenly Potion", feature: "autoPop")]
        for screen in dangerous {
            for action in actions {
                guard case .blocked(_, let forbidden) = policy.evaluate(action, screen: screen + [box("Play", y: 0.8)]) else {
                    return XCTFail("\(action) was approved with \"\(screen[0].text)\" on screen")
                }
                XCTAssertTrue(forbidden, screen[0].text)
            }
            XCTAssertEqual(policy.evaluate(.escape, screen: screen), .approved)
        }
    }

    func testChatTextCannotTriggerABlock() {
        // Someone typing "free robux" or "delete" in chat must not stop anti-AFK.
        let chat = [box("[Player1]: selling for robux, trade me", x: 0.18, y: 0.25), box("[Player2]: delete it", x: 0.08, y: 0.3)]
        XCTAssertEqual(policy.evaluate(.key("space"), screen: chat + [box("Roll", y: 0.92)]), .approved)
        // The same words in the middle of the window (a dialog) do block.
        XCTAssertNotEqual(policy.evaluate(.key("space"), screen: [box("selling for robux", x: 0.5, y: 0.45)]), .approved)
        // A dialog button on the left half of a centered dialog is still far right of the chat zone.
        XCTAssertNotEqual(policy.evaluate(.key("space"), screen: [box("Buy", x: 0.36, y: 0.5)]), .approved)
    }

    func testWordsInsideOtherWordsDoNotBlock() {
        // "Unlocked", "Trader", "Buyer" style words and the game's own labels are not the dangerous controls.
        let screen = [box("Achievement unlocked!", x: 0.6, y: 0.2), box("Blockade", x: 0.7, y: 0.4), box("Confirmed kills: 3", x: 0.7, y: 0.5), box("Rebuy timer", x: 0.7, y: 0.6)]
        XCTAssertEqual(policy.evaluate(.key("space"), screen: screen), .approved)
    }

    func testAuraStorageOpenBlocksButIsNotAnEmergency() {
        guard case .blocked(let reason, let forbidden) = policy.evaluate(.key("space"), screen: [box("Aura Storage", y: 0.15), box("Equip", y: 0.8)]) else { return XCTFail() }
        XCTAssertFalse(forbidden)
        XCTAssertTrue(reason.contains("Aura Storage"))
    }

    func testClicksOnlyOnListedAnchorsThatAreOnScreen() {
        let screen = [box("Play", y: 0.7), box("Settings", y: 0.8)]
        XCTAssertEqual(policy.evaluate(.clickAnchor("Play"), screen: screen), .approved)
        XCTAssertNotEqual(policy.evaluate(.clickAnchor("Skip"), screen: screen), .approved, "not on screen")
        XCTAssertNotEqual(policy.evaluate(.clickAnchor("Settings"), screen: screen), .approved, "not on the click list")
    }

    func testItemUseNeedsFeatureAllowlistAndCap() {
        var p = GuardianPolicy()
        let potion = GuardedAction.useItem(name: "Heavenly Potion", feature: "autoPop")
        XCTAssertNotEqual(p.evaluate(potion, screen: []), .approved, "off by default in V1.0")
        p.features["autoPop"] = ItemFeature(enabled: true, allowlist: ["Heavenly Potion"], hourlyCap: 2)
        XCTAssertEqual(p.evaluate(potion, screen: []), .approved)
        XCTAssertNotEqual(p.evaluate(.useItem(name: "Oblivion Potion", feature: "autoPop"), screen: []), .approved, "not on the allowlist")
        XCTAssertNotEqual(p.evaluate(potion, screen: [], itemUsesLastHour: 2), .approved, "hourly cap")
        XCTAssertNotEqual(p.evaluate(.useItem(name: "Heavenly Potion", feature: "crafting"), screen: []), .approved, "other feature is off")
    }
}

/// SPEC F15 acceptance, with rendered screens read by the real Vision OCR.
final class GuardianScreenTests: XCTestCase {
    func verdict(_ extra: [(text: String, x: CGFloat, y: CGFloat, size: CGFloat)], action: GuardedAction = .key("space")) throws -> (GuardianVerdict, [TextBox]) {
        let text = try OCR.recognize(renderScreen(hud + extra))
        return (GuardianPolicy().evaluate(action, screen: text), text)
    }

    func testOCRReadsTheRenderedHUDAndApproves() throws {
        let (v, text) = try verdict([])
        XCTAssertTrue(text.contains { $0.text.contains("Roll") }, "\(text.map(\.text))")
        let biome = try XCTUnwrap(OCR.find("NORMAL", in: text))
        XCTAssertEqual(biome.center.x, 0.06, accuracy: 0.03)
        XCTAssertEqual(biome.center.y, 0.845, accuracy: 0.02, "boxes use a top-left origin, like window ratios")
        XCTAssertEqual(v, .approved)
    }

    func testEachForbiddenUIIsBlocked() throws {
        let dialogs: [(String, [(text: String, x: CGFloat, y: CGFloat, size: CGFloat)])] = [
            ("Robux purchase", [("Buy Item", 0.5, 0.36, 24), ("Would you like to buy this for 400 Robux?", 0.5, 0.45, 16), ("Buy", 0.42, 0.56, 20), ("Cancel", 0.58, 0.56, 20)]),
            ("Purchase confirm", [("Confirm Purchase", 0.5, 0.4, 24), ("Confirm", 0.5, 0.56, 20)]),
            ("Aura delete", [("Aura Storage", 0.5, 0.14, 26), ("Delete", 0.62, 0.8, 18), ("Equip", 0.4, 0.8, 18)]),
            ("Delete confirmation", [("Are you sure you want to delete this aura?", 0.5, 0.45, 18), ("Yes", 0.44, 0.56, 20), ("No", 0.56, 0.56, 20)]),
            ("Aura lock", [("Aura Storage", 0.5, 0.14, 26), ("Lock", 0.62, 0.8, 18)]),
            ("Trade window", [("Trade Request", 0.5, 0.36, 24), ("Accept", 0.44, 0.56, 20), ("Decline", 0.56, 0.56, 20)]),
            ("Sell confirmation", [("Sell", 0.5, 0.56, 20), ("Merchant", 0.5, 0.36, 24)]),
        ]
        for (name, extra) in dialogs {
            for action in [GuardedAction.key("space"), .clickAnchor("Play")] {
                let (v, text) = try verdict(extra, action: action)
                guard case .blocked(_, let forbidden) = v else { return XCTFail("\(name): \(action) was approved. OCR saw \(text.map(\.text))") }
                XCTAssertTrue(forbidden, name)
            }
        }
    }

    func testGuardianLogsAndRaisesTheAlarm() async throws {
        let image = renderScreen(hud + [("Would you like to buy this for 400 Robux?", 0.5, 0.45, 16)])
        let text = try OCR.recognize(image)
        let log = ActionLog(url: nil)
        let guardian = Guardian(log: log) { Guardian.Look(text: text, frameHash: FrameHash.average(image)) }
        final class Box: @unchecked Sendable { var reason: String? }
        let alarm = Box()
        guardian.onForbidden = { _, reason in alarm.reason = reason }
        let v = await guardian.approve(.key("space"))
        XCTAssertFalse(v.isApproved)
        XCTAssertNotNil(alarm.reason)
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries[0].verdict, "blocked-forbidden")
        XCTAssertNotNil(log.entries[0].frameHash)
        // A clean screen is approved and logged too.
        let clean = try OCR.recognize(renderScreen(hud))
        let ok = await Guardian(log: log) { Guardian.Look(text: clean, frameHash: 1) }.approve(.key("space"))
        XCTAssertTrue(ok.isApproved)
        XCTAssertEqual(log.entries.map(\.verdict), ["blocked-forbidden", "approved"])
    }

    func testFrameHashAndDifference() {
        let a = renderScreen(hud), b = renderScreen(hud), c = renderScreen(hud + [("BIG CHANGE", 0.5, 0.5, 120)])
        XCTAssertEqual(FrameHash.average(a), FrameHash.average(b))
        XCTAssertEqual(FrameHash.difference(a, b), 0, accuracy: 0.001)
        XCTAssertGreaterThan(FrameHash.difference(a, c), 2)
        XCTAssertGreaterThan(FrameHash.distance(FrameHash.average(a), FrameHash.average(c)), 0)
    }
}
