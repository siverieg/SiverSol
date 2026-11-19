import Foundation
import CoreGraphics
import SiverCore

/// F10: a screenshot fit to post in a hunt server. Other players' names are painted over before it leaves the Mac.
public enum ProofShot {
    /// Regions of the game area (ratios, top-left origin) that can show other people's names: the chat, and the
    /// player list. They were measured on a whole window with a title bar and are converted here, so on such a
    /// window they cover exactly what they always did.
    public static let chatRegion = GameChrome.contentRegion(fromLegacyWindow: CGRect(x: 0, y: 0.10, width: 0.42, height: 0.55))
    public static let playerListRegion = GameChrome.contentRegion(fromLegacyWindow: CGRect(x: 0.72, y: 0.035, width: 0.28, height: 0.14))
    public static let defaultMasks = [chatRegion, playerListRegion]

    /// The image with each region covered by a solid dark panel.
    public static func masked(_ image: CGImage, masks: [CGRect] = defaultMasks) -> CGImage {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1))
        for m in masks {
            // Ratios use a top-left origin; CoreGraphics draws from the bottom-left.
            let rect = CGRect(x: m.minX * CGFloat(w), y: (1 - m.maxY) * CGFloat(h), width: m.width * CGFloat(w), height: m.height * CGFloat(h))
            ctx.fill(rect.integral)
        }
        return ctx.makeImage() ?? image
    }
}
