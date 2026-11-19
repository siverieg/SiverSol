import XCTest
import CoreGraphics
@testable import SiverInput

final class RobloxWindowFinderTests: XCTestCase {
    private func win(_ owner: String, id: Int, layer: Int, _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> [String: Any] {
        [kCGWindowOwnerName as String: owner, kCGWindowNumber as String: id, kCGWindowOwnerPID as String: 2545,
         kCGWindowLayer as String: layer,
         kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h]]
    }

    func testPicksLargestLayerZeroRobloxWindow() {
        let list = [
            win("Finder", id: 1, layer: 0, 0, 0, 1920, 1080),
            win("Roblox", id: 341, layer: 25, 0, 0, 1920, 24),      // menu bar item
            win("Roblox", id: 342, layer: 0, 959, 35, 960, 953),    // game window (real bounds from a 1080p display)
            win("Roblox", id: 343, layer: 0, 100, 100, 300, 200),   // small dialog
        ]
        let windows = RobloxWindowFinder.windows(from: list) { _ in 1.0 }
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(RobloxWindowFinder.mainWindow(in: windows)?.windowId, 342)
    }

    func testAWindowThatOnlyCallsItselfRobloxIsIgnored() {
        // The owner name is not enough: the owning process must be the Roblox app (checked by bundle id).
        var impostor = win("Roblox", id: 900, layer: 0, 0, 0, 1600, 1000)
        impostor[kCGWindowOwnerPID as String] = 777
        let list = [impostor, win("Roblox", id: 342, layer: 0, 959, 35, 960, 953)]
        let windows = RobloxWindowFinder.windows(from: list, isRoblox: { $0 == 2545 }) { _ in 1.0 }
        XCTAssertEqual(windows.map(\.windowId), [342])
        XCTAssertFalse(RobloxWindowFinder.ownedByRoblox(getpid()), "this test process is not Roblox")
    }

    func testRatioAndPixelConversion() {
        let w = RobloxWindow(windowId: 1, pid: 1, bounds: CGRect(x: 959, y: 35, width: 960, height: 953), layer: 0, scale: 2)
        XCTAssertEqual(w.point(ratioX: 0.5, ratioY: 0.5), CGPoint(x: 1439, y: 511.5))
        // On a 2x screen a screenshot pixel (960, 100) is point (480, 50) inside the window.
        XCTAssertEqual(w.point(pixelX: 960, pixelY: 100), CGPoint(x: 1439, y: 85))
    }

    func testNoRobloxWindow() {
        let windows = RobloxWindowFinder.windows(from: [win("Finder", id: 1, layer: 0, 0, 0, 10, 10)]) { _ in 1 }
        XCTAssertNil(RobloxWindowFinder.mainWindow(in: windows))
    }
}
