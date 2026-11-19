import CoreGraphics
import Foundation

/// Where the game is drawn inside the Roblox window.
///
/// Everything SiverSol reads from or clicks in the game is measured against the window's CONTENT (the part
/// below the title bar), as a ratio from 0 to 1 with the origin at the top-left. A windowed Roblox has a title
/// bar and a full-screen one does not, so a ratio of the whole window would land a title bar's height off as
/// soon as the two are mixed (a recording made in a window, replayed in full screen on a MacBook).
///
/// Points and pixels are kept apart: `window` and `content` are points, as the window server reports them;
/// a screenshot is pixels, `scale` times as many.
public struct GameFrame: Equatable, Sendable {
    /// The whole window in global points, origin at the top-left of the primary display.
    public var window: CGRect
    /// Height of the title bar above the game, in points. 0 in full screen.
    public var titleBar: CGFloat
    /// Pixels per point on the screen the window is on (2 on a Retina display).
    public var scale: CGFloat

    public init(window: CGRect, titleBar: CGFloat = 0, scale: CGFloat = 1) {
        self.window = window
        self.titleBar = min(max(0, titleBar), max(0, window.height - 1))
        self.scale = scale > 0 ? scale : 1
    }

    /// The game itself, in global points.
    public var content: CGRect {
        CGRect(x: window.minX, y: window.minY + titleBar, width: window.width, height: window.height - titleBar)
    }

    /// The game's size in screenshot pixels.
    public var pixelSize: CGSize { CGSize(width: content.width * scale, height: content.height * scale) }

    /// Content ratio -> global point (for a click).
    public func point(x: Double, y: Double) -> CGPoint {
        let c = content
        return CGPoint(x: c.minX + c.width * CGFloat(x), y: c.minY + c.height * CGFloat(y))
    }

    /// Global point -> content ratio. nil when the point is outside the game, unless `clamp` is set.
    public func ratio(of p: CGPoint, clamp: Bool = false) -> (x: Double, y: Double)? {
        let c = content
        guard c.width > 1, c.height > 1 else { return nil }
        let x = Double((p.x - c.minX) / c.width), y = Double((p.y - c.minY) / c.height)
        if clamp { return (min(1, max(0, x)), min(1, max(0, y))) }
        guard x >= 0, x <= 1, y >= 0, y <= 1 else { return nil }
        return (x, y)
    }

    /// A pixel of a screenshot of the content -> global point.
    public func point(pixelX: CGFloat, pixelY: CGFloat) -> CGPoint {
        let c = content
        return CGPoint(x: c.minX + pixelX / scale, y: c.minY + pixelY / scale)
    }

    /// The rows of a screenshot of the WHOLE window that hold the game. The screenshot's own size is used, so
    /// it does not matter how many pixels per point it was taken at.
    public func contentCrop(inCapture size: CGSize) -> CGRect {
        guard window.height > 0 else { return CGRect(origin: .zero, size: size) }
        let top = (titleBar / window.height * size.height).rounded()
        return CGRect(x: 0, y: top, width: size.width, height: max(1, size.height - top))
    }

    /// A region given as content ratios, as ratios of the whole window (for a video of the whole window).
    public func windowRegion(fromContent r: CGRect) -> CGRect {
        guard window.height > 0 else { return r }
        let k = content.height / window.height, t = titleBar / window.height
        return CGRect(x: r.minX, y: t + r.minY * k, width: r.width, height: r.height * k)
    }
}

public enum GameChrome {
    /// The window the fixed regions (chat, player list, item bar) were first measured on: 953 points tall
    /// including a 32-point title bar. Measured 2026-11-19: the window server said 960×953 while the Roblox
    /// log said the game was drawn 960×921.
    public static let referenceWindowHeight: CGFloat = 953
    public static let referenceTitleBar: CGFloat = 32

    /// How tall the title bar is.
    ///
    /// The Roblox log says how large the game is drawn ("resizing main targets to WxH"); the window server says
    /// how large the window is. The window's extra height is the title bar. That works whatever macOS draws
    /// title bars at and at any pixel density, because only the proportions are used. Without a usable log
    /// line: none in full screen, otherwise the height the system gives a standard title bar.
    public static func titleBar(window: CGSize, render: (width: Int, height: Int)?, fullScreen: Bool, systemTitleBar: CGFloat) -> CGFloat {
        if let render, render.width > 0, render.height > 0, window.width > 0 {
            let contentHeight = CGFloat(render.height) * window.width / CGFloat(render.width)
            let bar = window.height - contentHeight
            if bar >= -1, bar <= 60 { return max(0, (bar * 2).rounded() / 2) }
        }
        return fullScreen ? 0 : systemTitleBar
    }

    /// A height measured as a ratio of the whole window -> the same place as a ratio of the content.
    public static func contentY(fromWindow y: Double, windowHeight: Double, titleBar: Double) -> Double {
        guard windowHeight > titleBar else { return y }
        return (y * windowHeight - titleBar) / (windowHeight - titleBar)
    }

    /// A region that was measured as ratios of the whole reference window, as ratios of its content. On a
    /// window like the reference one the region covers exactly the same pixels as before.
    public static func contentRegion(fromLegacyWindow r: CGRect, windowHeight: CGFloat = referenceWindowHeight, titleBar: CGFloat = referenceTitleBar) -> CGRect {
        let top = contentY(fromWindow: Double(r.minY), windowHeight: Double(windowHeight), titleBar: Double(titleBar))
        let bottom = contentY(fromWindow: Double(r.maxY), windowHeight: Double(windowHeight), titleBar: Double(titleBar))
        let y = max(0, top)
        return CGRect(x: r.minX, y: y, width: r.width, height: max(0, min(1, bottom) - y))
    }
}
