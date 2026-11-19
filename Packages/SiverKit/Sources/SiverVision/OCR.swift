import Foundation
import CoreGraphics
import Vision
import CoreText

/// One recognized line of text. `box` is normalized 0…1 with a top-left origin, so it maps straight to window ratios.
public struct TextBox: Equatable, Sendable, Codable {
    public var text: String
    public var box: CGRect
    public var confidence: Float

    public init(text: String, box: CGRect, confidence: Float = 1) {
        self.text = text; self.box = box; self.confidence = confidence
    }

    public var center: CGPoint { CGPoint(x: box.midX, y: box.midY) }
}

public enum OCR {
    /// Vision text recognition. `fast` trades accuracy for speed (fine for large UI text).
    public static func recognize(_ image: CGImage, fast: Bool = false) throws -> [TextBox] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            let b = obs.boundingBox   // normalized, bottom-left origin
            return TextBox(text: top.string, box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height), confidence: top.confidence)
        }
        .sorted { $0.box.minY != $1.box.minY ? $0.box.minY < $1.box.minY : $0.box.minX < $1.box.minX }
    }

    /// Vision prepares its text model the first time a new build asks for accurate recognition, which can take
    /// half a minute. Doing that once at startup, on a picture SiverSol draws itself, keeps the first real look fast.
    /// Returns how long it took. Safe to call more than once; later calls return quickly.
    @discardableResult
    public static func warmUp() -> TimeInterval {
        let began = Date()
        let width = 320, height = 80
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 36, nil)
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                         NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Warm up 123", attributes: attributes))
        ctx.textPosition = CGPoint(x: 20, y: 26)
        CTLineDraw(line, ctx)
        if let image = ctx.makeImage() { _ = try? recognize(image) }
        return Date().timeIntervalSince(began)
    }

    /// First line containing the text (case-insensitive), optionally inside a region. For OCR anchors like "Play" or "Skip".
    public static func find(_ needle: String, in boxes: [TextBox], region: CGRect? = nil) -> TextBox? {
        boxes.first { b in
            b.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil && (region?.contains(b.center) ?? true)
        }
    }
}

/// Perceptual fingerprint of a frame, for frozen-screen detection (F8) and the action log (F15).
public enum FrameHash {
    /// 8×8 average hash of the grayscale image.
    public static func average(_ image: CGImage) -> UInt64 {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let mean = pixels.reduce(0) { $0 + Int($1) } / pixels.count
        var hash: UInt64 = 0
        for (i, p) in pixels.enumerated() where Int(p) > mean { hash |= 1 << UInt64(i) }
        return hash
    }

    public static func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    /// Mean brightness of the frame, 0 (black) to 255. A capture taken while the display is off can come back black.
    public static func brightness(_ image: CGImage) -> Double {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count)
    }

    /// Mean absolute difference (0…255) between two frames, compared at low resolution inside a region.
    /// Used to tell "the picture changed because of our input" from normal animation noise.
    public static func difference(_ a: CGImage, _ b: CGImage, region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), side: Int = 64) -> Double {
        func sample(_ image: CGImage) -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: side * side)
            guard let cropped = SiverVision.crop(image, to: region),
                  let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return pixels }
            ctx.interpolationQuality = .low
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
            return pixels
        }
        let x = sample(a), y = sample(b)
        var total = 0
        for i in 0..<x.count { total += abs(Int(x[i]) - Int(y[i])) }
        return Double(total) / Double(x.count)
    }
}
