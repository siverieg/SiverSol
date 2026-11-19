import AppKit
import SiverCore
import SiverInput

/// The screens as the system describes them right now, and the one made-up laptop screen used for testing.
///
/// Nothing here is cached: every answer is read again from `NSScreen` (`safeAreaInsets.top`,
/// `auxiliaryTopLeftArea`, `auxiliaryTopRightArea`), so a display that is plugged in, unplugged or rearranged
/// is seen the next time anyone asks. `NotchGeometry` turns the numbers into a notch.
@MainActor
enum Screens {
    /// A made-up MacBook screen: `--fake-notch air13` (or air15, pro14, pro16), or set by the design review.
    /// The Mac SiverSol was built on has no notch, so this is how the notch layout is looked at.
    static var fake: LaptopProfile? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--fake-notch"), i + 1 < args.count else { return nil }
        return LaptopProfile.named(args[i + 1])
    }() {
        didSet { if fake != oldValue { NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil) } }
    }

    static var primaryHeight: CGFloat { SystemScreens.primaryHeight }

    /// The made-up screen hangs from the top centre of the real one, so its notch is at the real top edge.
    static func all() -> [ScreenShape] {
        if let fake, let real = NSScreen.screens.first {
            return [fake.screen(midX: real.frame.midX, top: real.frame.maxY)]
        }
        return SystemScreens.shapes()
    }

    /// The screen Roblox is on (`window` as the window server reports it); the screen with the menu bar when
    /// Roblox has no window.
    static func forRoblox(_ window: CGRect?) -> ScreenShape? {
        let shapes = all()
        if fake == nil, let window,
           let i = ScreenMath.screenIndex(holding: ScreenMath.cocoa(window, primaryHeight: primaryHeight), screens: shapes) {
            return shapes[i]
        }
        return shapes.first
    }

    private static var loggedFallback = false

    static func geometry(_ shape: ScreenShape) -> NotchGeometry {
        let g = NotchGeometry(shape)
        if g.usedFallback, !loggedFallback {
            loggedFallback = true
            NSLog("SiverSol: this screen reports a camera inset of %.0f pt but not the menu bar areas beside it; assuming a centred notch %.0f pt wide.",
                  shape.safeTop, NotchGeometry.fallbackNotchWidth)
        }
        return g
    }

    /// Is the menu bar off screen on this display? It is in a full-screen Space. Read from the window list:
    /// the menu bar is a window of the window server at the main menu level.
    static func menuBarHidden(on shape: ScreenShape) -> Bool? {
        guard fake == nil else { return false }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let level = Int(CGWindowLevelForKey(.mainMenuWindow))
        let top = ScreenMath.topLeft(shape.frame, primaryHeight: primaryHeight)
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == level, (w[kCGWindowOwnerName as String] as? String) == "Window Server",
                  let b = w[kCGWindowBounds as String] as? [String: Any], let rect = CGRect(dictionaryRepresentation: b as CFDictionary),
                  rect.height <= 80 else { continue }
            if rect.intersects(CGRect(x: top.minX, y: top.minY, width: top.width, height: 80)) { return false }
        }
        return true
    }

    /// Is any display being mirrored (a projector, AirPlay)? What is on the island would be on the other screen too.
    static var mirrored: Bool {
        guard fake == nil else { return false }
        return NSScreen.screens.contains { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsInMirrorSet(id) != 0
        }
    }

    /// Is Roblox in full screen right now?
    static func robloxIsFullScreen(_ window: RobloxWindow?) -> Bool {
        guard fake == nil, let window else { return false }
        let shapes = all()
        let cocoa = ScreenMath.cocoa(window.bounds, primaryHeight: primaryHeight)
        let hidden = ScreenMath.screenIndex(holding: cocoa, screens: shapes).flatMap { menuBarHidden(on: shapes[$0]) }
        return FullScreenCheck.isFullScreen(window: cocoa, screens: shapes, menuBarHidden: hidden)
    }
}

/// The black camera housing drawn on a made-up laptop screen, so the island can be seen around it.
@MainActor
final class FakeNotchWindow: NSPanel {
    static var shared: FakeNotchWindow?

    static func update() {
        guard let shape = Screens.all().first, Screens.fake != nil, let notch = Screens.geometry(shape).notch else {
            shared?.orderOut(nil)
            return
        }
        if shared == nil { shared = FakeNotchWindow() }
        shared?.setFrame(notch, display: true)
        shared?.orderFrontRegardless()
    }

    init() {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.cornerRadius = 9
        view.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
