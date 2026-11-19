import CoreGraphics
import Foundation

/// One display, as the system describes it. Cocoa screen coordinates: the origin is the bottom-left corner of
/// the primary display and y grows upwards.
///
/// Nothing here knows the size of any notch. The numbers are read from `NSScreen` every time the screens
/// change (`safeAreaInsets.top`, `auxiliaryTopLeftArea`, `auxiliaryTopRightArea`) and handed in.
public struct ScreenShape: Equatable, Sendable {
    public var frame: CGRect
    /// The frame without the menu bar and the Dock.
    public var visibleFrame: CGRect
    /// Height of the camera housing at the top of this screen. 0 means there is no notch.
    public var safeTop: CGFloat
    /// The usable strips of the menu bar left and right of the notch, when the system reports them.
    public var auxLeft: CGRect?
    public var auxRight: CGRect?
    /// Pixels per point.
    public var scale: CGFloat

    public init(frame: CGRect, visibleFrame: CGRect? = nil, safeTop: CGFloat = 0, auxLeft: CGRect? = nil, auxRight: CGRect? = nil, scale: CGFloat = 1) {
        self.frame = frame; self.visibleFrame = visibleFrame ?? frame; self.safeTop = max(0, safeTop)
        self.auxLeft = auxLeft; self.auxRight = auxRight; self.scale = scale
    }

    /// The part of the screen below the camera housing.
    public var belowNotch: CGRect {
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - safeTop)
    }
}

/// Where the notch is on one screen, and the menu bar strips beside it. The one place that works this out;
/// the island, the menu bar check and the full-screen check all ask here.
public struct NotchGeometry: Equatable, Sendable {
    public let screen: CGRect
    /// The camera housing, at the full height of the safe area. nil on a screen without a notch.
    public let notch: CGRect?
    /// The strips of menu bar left and right of the notch.
    public let leftEar: CGRect?
    public let rightEar: CGRect?
    /// True when the system reported a top inset but not the strips beside it, so a centred notch was assumed.
    public let usedFallback: Bool

    /// Only used when the system reports an inset without the areas beside it.
    public static let fallbackNotchWidth: CGFloat = 200

    public var hasNotch: Bool { notch != nil }

    public init(_ s: ScreenShape) {
        screen = s.frame
        guard s.safeTop > 0 else {
            notch = nil; leftEar = nil; rightEar = nil; usedFallback = false
            return
        }
        let top = s.frame.maxY - s.safeTop
        if let l = s.auxLeft, let r = s.auxRight, r.minX - l.maxX >= 1, l.maxX > s.frame.minX, r.minX < s.frame.maxX {
            notch = CGRect(x: l.maxX, y: top, width: r.minX - l.maxX, height: s.safeTop)
            leftEar = CGRect(x: max(s.frame.minX, l.minX), y: top, width: l.maxX - max(s.frame.minX, l.minX), height: s.safeTop)
            rightEar = CGRect(x: r.minX, y: top, width: min(s.frame.maxX, r.maxX) - r.minX, height: s.safeTop)
            usedFallback = false
        } else {
            let width = min(Self.fallbackNotchWidth, s.frame.width / 2)
            let n = CGRect(x: s.frame.midX - width / 2, y: top, width: width, height: s.safeTop)
            notch = n
            leftEar = CGRect(x: s.frame.minX, y: top, width: n.minX - s.frame.minX, height: s.safeTop)
            rightEar = CGRect(x: n.maxX, y: top, width: s.frame.maxX - n.maxX, height: s.safeTop)
            usedFallback = true
        }
    }
}

/// Is a window in full screen? On a Mac with a notch a full-screen window normally sits below the camera
/// housing, so it is shorter than its screen; an app that draws under the camera covers the whole screen.
public enum FullScreenCheck {
    static let slack: CGFloat = 2

    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= slack && abs(a.minY - b.minY) <= slack && abs(a.width - b.width) <= slack && abs(a.height - b.height) <= slack
    }

    /// `window` is in Cocoa screen coordinates, like the screens.
    /// `menuBarHidden`: whether the menu bar is off screen on the window's display (true in a full-screen
    /// Space), or nil when that could not be told.
    public static func isFullScreen(window: CGRect, screens: [ScreenShape], menuBarHidden: Bool? = nil) -> Bool {
        for s in screens {
            if close(window, s.frame) { return true }
            if s.safeTop > 0, close(window, s.belowNotch) { return true }
            // In a full-screen Space the menu bar is gone and the window fills everything below the camera,
            // whatever the app does with the corners.
            if menuBarHidden == true, s.frame.intersects(window) {
                let area = s.belowNotch
                if window.width >= area.width - slack, window.height >= area.height - slack, window.minY <= area.minY + slack { return true }
            }
        }
        return false
    }

    /// The same check for a rectangle from the window server (origin top-left of the primary display, y down).
    public static func isFullScreen(windowTopLeft: CGRect, primaryHeight: CGFloat, screens: [ScreenShape], menuBarHidden: Bool? = nil) -> Bool {
        isFullScreen(window: ScreenMath.cocoa(windowTopLeft, primaryHeight: primaryHeight), screens: screens, menuBarHidden: menuBarHidden)
    }
}

public enum ScreenMath {
    /// Window server rectangles measure from the top-left of the primary display; Cocoa measures from its bottom-left.
    public static func cocoa(_ topLeft: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: topLeft.minX, y: primaryHeight - topLeft.maxY, width: topLeft.width, height: topLeft.height)
    }

    public static func topLeft(_ cocoa: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: cocoa.minX, y: primaryHeight - cocoa.maxY, width: cocoa.width, height: cocoa.height)
    }

    /// The screen that holds most of a rectangle (both in Cocoa coordinates), or nil when it touches none.
    public static func screenIndex(holding rect: CGRect, screens: [ScreenShape]) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (i, s) in screens.enumerated() {
            let overlap = s.frame.intersection(rect)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > 0, area > (best?.area ?? 0) { best = (i, area) }
        }
        return best?.index
    }
}

/// Is SiverSol's menu bar icon somewhere the user can see it? On a Mac with a notch, macOS quietly drops the
/// icons that do not fit, and they end up behind the camera housing or off the screen.
public enum MenuBarIconCheck {
    /// `item` is the frame of the status item's own window (Cocoa coordinates); nil when it has none.
    public static func isHidden(item: CGRect?, screens: [ScreenShape]) -> Bool {
        guard let item, item.width > 1, item.height > 1 else { return true }
        guard let index = ScreenMath.screenIndex(holding: item, screens: screens) else { return true }
        let geometry = NotchGeometry(screens[index])
        if let notch = geometry.notch, notch.intersects(item.insetBy(dx: 1, dy: 1)) { return true }
        // Fully on its screen, not hanging off an edge.
        return !screens[index].frame.contains(item.insetBy(dx: 1, dy: 1))
    }
}

/// Made-up laptops for the design review and the tests, because the Mac this was built on has no notch.
/// The screen sizes are the default "looks like" sizes; the notch numbers are approximations and are never
/// used on a real Mac, where everything is read from the system.
public struct LaptopProfile: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var size: CGSize
    public var safeTop: CGFloat
    public var notchWidth: CGFloat
    public var scale: CGFloat
    /// Height taken by the Dock at the bottom.
    public var dock: CGFloat = 70

    public static let air13 = LaptopProfile(id: "air13", name: "MacBook Air 13\"", size: CGSize(width: 1470, height: 956), safeTop: 37, notchWidth: 212, scale: 2)
    public static let air15 = LaptopProfile(id: "air15", name: "MacBook Air 15\"", size: CGSize(width: 1710, height: 1107), safeTop: 38, notchWidth: 220, scale: 2)
    public static let pro14 = LaptopProfile(id: "pro14", name: "MacBook Pro 14\"", size: CGSize(width: 1512, height: 982), safeTop: 32, notchWidth: 185, scale: 2)
    public static let pro16 = LaptopProfile(id: "pro16", name: "MacBook Pro 16\"", size: CGSize(width: 1728, height: 1117), safeTop: 32, notchWidth: 185, scale: 2)
    public static let all = [air13, air15, pro14, pro16]

    public static func named(_ id: String) -> LaptopProfile? { all.first { $0.id == id } }

    /// The profile as a screen whose top edge is at `top` and whose centre is at `midX` (Cocoa coordinates).
    public func screen(midX: CGFloat, top: CGFloat) -> ScreenShape {
        let frame = CGRect(x: midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
        let stripY = frame.maxY - safeTop
        let left = CGRect(x: frame.minX, y: stripY, width: (size.width - notchWidth) / 2, height: safeTop)
        let right = CGRect(x: frame.midX + notchWidth / 2, y: stripY, width: (size.width - notchWidth) / 2, height: safeTop)
        let visible = CGRect(x: frame.minX, y: frame.minY + dock, width: size.width, height: size.height - safeTop - dock)
        return ScreenShape(frame: frame, visibleFrame: visible, safeTop: safeTop, auxLeft: left, auxRight: right, scale: scale)
    }
}
