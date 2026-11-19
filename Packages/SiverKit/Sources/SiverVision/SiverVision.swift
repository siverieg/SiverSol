import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SiverCore

/// Screen capture + OCR namespace.
public enum SiverVision {
    /// True when this process may capture other apps' windows.
    public static var hasScreenRecordingAccess: Bool { CGPreflightScreenCaptureAccess() }

    public static func loadImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    public static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    @discardableResult
    public static func savePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let data = pngData(image) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Crop by window-relative ratios (0…1, top-left origin).
    public static func crop(_ image: CGImage, to ratio: CGRect) -> CGImage? {
        let r = CGRect(x: ratio.minX * CGFloat(image.width), y: ratio.minY * CGFloat(image.height),
                       width: ratio.width * CGFloat(image.width), height: ratio.height * CGFloat(image.height)).integral
        return image.cropping(to: r)
    }
}
