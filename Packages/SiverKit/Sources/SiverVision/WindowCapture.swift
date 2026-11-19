import Foundation
import CoreGraphics
import ScreenCaptureKit
import SiverCore

public enum CaptureError: Error, CustomStringConvertible {
    case noPermission
    case windowNotFound(CGWindowID)
    case failed(String)

    public var description: String {
        switch self {
        case .noPermission: return "Screen Recording is not allowed for this app (System Settings → Privacy & Security → Screen Recording)."
        case .windowNotFound(let id): return "Window \(id) is not on screen (minimized, closed or on another Space)."
        case .failed(let why): return "Capture failed: \(why)"
        }
    }
}

/// F10/F14: capture one window with ScreenCaptureKit. Silent, no shadow, works when the window is covered.
public enum WindowCapture {
    /// Returns the window's pixels (points × the display's scale), without the top `titleBar` points: pass the
    /// height of the window's title bar and the picture holds the game only, so a position in it is a ratio of
    /// the game area whether the window has a title bar or is in full screen.
    public static func capture(windowId: CGWindowID, titleBar: CGFloat = 0) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.noPermission }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw CaptureError.failed(error.localizedDescription) }
        guard let window = content.windows.first(where: { $0.windowID == windowId }) else { throw CaptureError.windowNotFound(windowId) }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let image: CGImage
        do { image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) }
        catch { throw CaptureError.failed(error.localizedDescription) }
        return cropped(image, titleBar: titleBar, windowHeight: window.frame.height)
    }

    /// The picture without its title bar rows. The picture's own height is used, whatever its pixel density.
    public static func cropped(_ image: CGImage, titleBar: CGFloat, windowHeight: CGFloat) -> CGImage {
        guard titleBar > 0, windowHeight > titleBar else { return image }
        let crop = GameFrame(window: CGRect(x: 0, y: 0, width: 1, height: windowHeight), titleBar: titleBar)
            .contentCrop(inCapture: CGSize(width: image.width, height: image.height))
        return image.cropping(to: crop) ?? image
    }
}
