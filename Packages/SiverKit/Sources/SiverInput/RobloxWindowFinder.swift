import AppKit
import CoreGraphics
import SiverCore

/// One on-screen Roblox window. Bounds are in global display points (top-left origin).
public struct RobloxWindow: Equatable, Sendable {
    public let windowId: CGWindowID
    public let pid: pid_t
    /// The whole window, title bar included.
    public let bounds: CGRect
    public let layer: Int
    /// Backing scale of the screen holding most of the window (1.0 on a plain 1080p display, 2.0 on Retina).
    public let scale: CGFloat
    /// Height of the title bar above the game, in points (0 in full screen).
    public let titleBar: CGFloat

    public init(windowId: CGWindowID, pid: pid_t, bounds: CGRect, layer: Int, scale: CGFloat, titleBar: CGFloat = 0) {
        self.windowId = windowId; self.pid = pid; self.bounds = bounds; self.layer = layer; self.scale = scale; self.titleBar = titleBar
    }

    /// The window with its title bar taken off: everything read or clicked in the game is measured against this.
    public var frame: GameFrame { GameFrame(window: bounds, titleBar: titleBar, scale: scale) }
    /// The game itself, in global points.
    public var content: CGRect { frame.content }

    /// Content ratio (0…1 of the game area) -> global point, for CGEvent.
    public func point(ratioX: CGFloat, ratioY: CGFloat) -> CGPoint {
        frame.point(x: Double(ratioX), y: Double(ratioY))
    }

    /// Pixel of a screenshot of the game area -> global point. Pixels are `scale`× points.
    public func point(pixelX: CGFloat, pixelY: CGFloat) -> CGPoint {
        frame.point(pixelX: pixelX, pixelY: pixelY)
    }
}

/// The screens as the system describes them right now. Read fresh every time: nothing about a notch is stored.
public enum SystemScreens {
    public static func shape(_ s: NSScreen) -> ScreenShape {
        ScreenShape(frame: s.frame, visibleFrame: s.visibleFrame, safeTop: s.safeAreaInsets.top,
                    auxLeft: s.auxiliaryTopLeftArea, auxRight: s.auxiliaryTopRightArea, scale: s.backingScaleFactor)
    }
    public static func shapes() -> [ScreenShape] { NSScreen.screens.map(shape) }
    /// Height of the primary display: window server rectangles are flipped against it.
    public static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
}

/// What is known about the Roblox window's title bar.
public enum RobloxChrome {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var render: (width: Int, height: Int)?
    nonisolated(unsafe) private static var standardTitleBar: CGFloat = 28

    /// Ask the system once how tall it makes a standard title bar (call on the main thread at launch).
    @MainActor public static func prime() {
        let h = NSWindow.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled]).height - 300
        lock.lock(); if h >= 0, h <= 60 { standardTitleBar = h }; lock.unlock()
    }

    /// The size the game is drawn at, from the Roblox log ("resizing main targets to WxH").
    public static func noteRenderSize(width: Int, height: Int) {
        lock.lock(); render = (width, height); lock.unlock()
    }

    public static var renderSize: (width: Int, height: Int)? { lock.lock(); defer { lock.unlock() }; return render }
    public static var systemTitleBar: CGFloat { lock.lock(); defer { lock.unlock() }; return standardTitleBar }

    /// Title bar height for a window with these bounds (window server coordinates).
    public static func titleBar(forWindow bounds: CGRect) -> CGFloat {
        let full = FullScreenCheck.isFullScreen(windowTopLeft: bounds, primaryHeight: SystemScreens.primaryHeight, screens: SystemScreens.shapes())
        return GameChrome.titleBar(window: bounds.size, render: renderSize, fullScreen: full, systemTitleBar: systemTitleBar)
    }
}

/// F14: find the Roblox game window without calibration.
public enum RobloxWindowFinder {
    public static let ownerName = "Roblox"
    public static let bundleId = "com.roblox.RobloxPlayer"

    /// Raw window dictionaries -> Roblox windows. Split out so tests can feed fake lists.
    /// `isRoblox` confirms the owning process: the real callers check its bundle id, so a window of some
    /// other app that merely calls itself "Roblox" is never looked at, captured or clicked.
    public static func windows(from list: [[String: Any]], isRoblox: (pid_t) -> Bool = { _ in true }, scaleFor: (CGRect) -> CGFloat,
                               titleBarFor: (CGRect) -> CGFloat = { _ in 0 }) -> [RobloxWindow] {
        list.compactMap { w in
            guard (w[kCGWindowOwnerName as String] as? String) == ownerName,
                  let id = w[kCGWindowNumber as String] as? Int,
                  let pid = w[kCGWindowOwnerPID as String] as? Int, isRoblox(pid_t(pid)),
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary)
            else { return nil }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            return RobloxWindow(windowId: CGWindowID(id), pid: pid_t(pid), bounds: rect,
                                layer: layer, scale: scaleFor(rect), titleBar: layer == 0 && rect.height >= 200 ? titleBarFor(rect) : 0)
        }
    }

    public static func allWindows() -> [RobloxWindow] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let list = (CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]) ?? []
        return windows(from: list, isRoblox: ownedByRoblox, scaleFor: scale(for:), titleBarFor: RobloxChrome.titleBar(forWindow:))
    }

    /// Is this process the Roblox player (by bundle id, not by name)?
    public static func ownedByRoblox(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleId
    }

    /// The game window: largest on-screen layer-0 window owned by Roblox.
    public static func mainWindow(in windows: [RobloxWindow]) -> RobloxWindow? {
        windows.filter { $0.layer == 0 && $0.bounds.width >= 200 && $0.bounds.height >= 200 }
            .max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    public static func mainWindow() -> RobloxWindow? { mainWindow(in: allWindows()) }

    /// True when Roblox has a game window at all, even minimized, hidden or on another Space.
    /// After a quit, Roblox's menu bar helper relaunches the player as a windowless background process
    /// (`RobloxPlayer -launchToTray`), so "the process exists" does not mean a game is open (seen live 2026-11-18).
    public static func hasGameWindow() -> Bool {
        let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        return mainWindow(in: windows(from: list, isRoblox: ownedByRoblox, scaleFor: { _ in 1 })) != nil
    }

    /// A Roblox process that actually shows a game.
    public static var gameIsOpen: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty && hasGameWindow()
    }

    /// Backing scale of the screen that overlaps the rect most. CG rects are top-left origin,
    /// NSScreen frames are bottom-left origin, so flip against the primary screen height.
    public static func scale(for rect: CGRect) -> CGFloat {
        guard let primary = NSScreen.screens.first else { return 1 }
        let flipped = CGRect(x: rect.minX, y: primary.frame.height - rect.maxY, width: rect.width, height: rect.height)
        var best: (area: CGFloat, scale: CGFloat) = (0, primary.backingScaleFactor)
        for s in NSScreen.screens {
            let i = s.frame.intersection(flipped)
            let area = i.isNull ? 0 : i.width * i.height
            if area > best.area { best = (area, s.backingScaleFactor) }
        }
        return best.scale
    }
}
