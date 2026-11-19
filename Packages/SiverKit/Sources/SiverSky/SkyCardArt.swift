import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SiverCore
import UniformTypeIdentifiers

/// The drawn glyphs for biomes that have no good SF Symbol. One source for the app and for Discord pictures.
/// Paths are built in a rectangle with a top-left origin.
public enum BiomeGlyphPaths {
    public static func custom(for key: String, in r: CGRect) -> CGPath? {
        switch key {
        case "GLITCHED": return glitch(in: r)
        case "PUMPKIN MOON": return pumpkin(in: r)
        case "GRAVEYARD": return tombstone(in: r)
        case "AURORA": return aurora(in: r)
        default: return nil
        }
    }

    /// True for the glyphs that are drawn as lines, not filled shapes.
    public static func isStroked(_ key: String) -> Bool { key == "AURORA" }
    /// True for the glyphs whose cut-outs need the even-odd rule.
    public static func usesEvenOdd(_ key: String) -> Bool { key == "PUMPKIN MOON" || key == "GRAVEYARD" }

    /// Offset bars with a notch: a picture that has slipped.
    public static func glitch(in r: CGRect) -> CGPath {
        let p = CGMutablePath()
        let u = r.width / 10, v = r.height / 10
        func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            p.addRoundedRect(in: CGRect(x: r.minX + x * u, y: r.minY + y * v, width: w * u, height: h * v), cornerWidth: min(u * 0.3, w * u / 2), cornerHeight: min(u * 0.3, h * v / 2))
        }
        bar(1.0, 1.0, 6.0, 1.8); bar(7.6, 1.0, 1.4, 1.8)
        bar(2.6, 3.4, 6.4, 1.8); bar(0.4, 3.4, 1.4, 1.8)
        bar(0.4, 5.8, 5.0, 1.8); bar(6.2, 5.8, 3.0, 1.8)
        bar(3.2, 8.2, 5.8, 1.4)
        return p
    }

    /// A pumpkin with a stalk and a carved face (the face is cut out with the even-odd rule).
    public static func pumpkin(in r: CGRect) -> CGPath {
        let p = CGMutablePath()
        let w = r.width, h = r.height
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * w, y: r.minY + y * h) }
        p.addEllipse(in: CGRect(x: r.minX + 0.04 * w, y: r.minY + 0.26 * h, width: 0.92 * w, height: 0.70 * h))
        p.addRoundedRect(in: CGRect(x: r.minX + 0.44 * w, y: r.minY + 0.06 * h, width: 0.12 * w, height: 0.24 * h), cornerWidth: 0.04 * w, cornerHeight: 0.04 * w)
        p.move(to: pt(0.24, 0.56)); p.addLine(to: pt(0.34, 0.42)); p.addLine(to: pt(0.44, 0.56)); p.closeSubpath()
        p.move(to: pt(0.56, 0.56)); p.addLine(to: pt(0.66, 0.42)); p.addLine(to: pt(0.76, 0.56)); p.closeSubpath()
        p.move(to: pt(0.24, 0.68)); p.addLine(to: pt(0.38, 0.74)); p.addLine(to: pt(0.50, 0.68)); p.addLine(to: pt(0.62, 0.74))
        p.addLine(to: pt(0.76, 0.68)); p.addLine(to: pt(0.62, 0.86)); p.addLine(to: pt(0.38, 0.86)); p.closeSubpath()
        return p
    }

    /// A round-topped stone with a cross cut into it, on a strip of ground.
    public static func tombstone(in r: CGRect) -> CGPath {
        let p = CGMutablePath()
        let w = r.width, h = r.height
        let stone = CGRect(x: r.minX + 0.22 * w, y: r.minY + 0.08 * h, width: 0.56 * w, height: 0.76 * h)
        let rad = 0.28 * w
        p.move(to: CGPoint(x: stone.minX, y: stone.maxY))
        p.addLine(to: CGPoint(x: stone.minX, y: stone.minY + rad))
        p.addArc(center: CGPoint(x: stone.minX + rad, y: stone.minY + rad), radius: rad, startAngle: .pi, endAngle: 1.5 * .pi, clockwise: false)
        p.addArc(center: CGPoint(x: stone.maxX - rad, y: stone.minY + rad), radius: rad, startAngle: 1.5 * .pi, endAngle: 0, clockwise: false)
        p.addLine(to: CGPoint(x: stone.maxX, y: stone.maxY))
        p.closeSubpath()
        p.addRect(CGRect(x: r.minX + 0.46 * w, y: r.minY + 0.26 * h, width: 0.08 * w, height: 0.34 * h))
        p.addRect(CGRect(x: r.minX + 0.36 * w, y: r.minY + 0.36 * h, width: 0.28 * w, height: 0.08 * h))
        p.addRoundedRect(in: CGRect(x: r.minX + 0.06 * w, y: r.minY + 0.84 * h, width: 0.88 * w, height: 0.10 * h), cornerWidth: 0.05 * h, cornerHeight: 0.05 * h)
        return p
    }

    /// Three hanging ribbons of light.
    public static func aurora(in r: CGRect) -> CGPath {
        let p = CGMutablePath()
        for i in 0..<3 {
            let x = r.minX + r.width * (0.2 + 0.3 * CGFloat(i))
            let top = r.minY + r.height * (0.10 + 0.08 * CGFloat(i % 2))
            let bottom = r.minY + r.height * (0.86 - 0.14 * CGFloat(i % 2))
            p.move(to: CGPoint(x: x, y: top))
            p.addCurve(to: CGPoint(x: x, y: bottom),
                       control1: CGPoint(x: x + r.width * 0.18, y: top + (bottom - top) * 0.3),
                       control2: CGPoint(x: x - r.width * 0.18, y: top + (bottom - top) * 0.7))
        }
        return p
    }
}

/// A picture for a Discord message, with the words that were drawn into it (so they can be checked for anything private).
public struct SkyPicture: Sendable {
    public var data: Data
    public var fileExtension: String
    public var width: Int
    public var height: Int
    public var text: [String]
}

/// The pictures that go with Sky Cards: the same sky, glyphs and Sol Dex cards the app shows, drawn off screen.
/// Nothing here looks at the screen, so it needs no permission.
public enum SkyCardArt {
    public static let bannerSize = CGSize(width: 1100, height: 400)
    public static let auraCardSize = CGSize(width: 600, height: 840)
    public static let thumbSize = CGSize(width: 192, height: 192)
    /// Pictures stay under this many bytes; a banner that would be larger as a PNG is saved as a JPEG.
    public static let maxBytes = 400 * 1024

    private static let lock = NSLock()
    private nonisolated(unsafe) static var backgrounds: [String: CGImage] = [:]

    private static func context(_ size: CGSize) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
        return ctx
    }

    private static func drawing<T>(_ ctx: CGContext, _ body: () -> T) -> T {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.current = previous }
        return body()
    }

    private static func drawImage(_ image: CGImage, in rect: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// PNG when it fits the size limit, JPEG otherwise (opaque pictures only).
    public static func encode(_ image: CGImage, opaque: Bool, text: [String]) -> SkyPicture? {
        func write(_ type: UTType, _ options: [CFString: Any]) -> Data? {
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, image, options as CFDictionary)
            return CGImageDestinationFinalize(dest) ? data as Data : nil
        }
        if let png = write(.png, [:]), png.count <= maxBytes || !opaque {
            return SkyPicture(data: png, fileExtension: "png", width: image.width, height: image.height, text: text)
        }
        for quality in [0.88, 0.8, 0.7, 0.6] {
            if let jpeg = write(.jpeg, [kCGImageDestinationLossyCompressionQuality: quality]), jpeg.count <= maxBytes {
                return SkyPicture(data: jpeg, fileExtension: "jpg", width: image.width, height: image.height, text: text)
            }
        }
        return nil
    }

    /// A still patch of a biome's sky, cached per biome, size and time of day (the sky is the slow part).
    static func sky(_ palette: BiomePalette, key: String, hour: Double, size: CGSize, arc: SkyArc? = nil, rare: Bool = false) -> CGImage? {
        let night = SkyClock(hour: hour).isNight
        let cacheKey = "\(key)|\(night)|\(Int(size.width))x\(Int(size.height))|\(arc != nil)|\(rare)"
        lock.lock()
        if let hit = backgrounds[cacheKey] { lock.unlock(); return hit }
        lock.unlock()
        // Always the deeper rendition of the sky, so white words read on every biome.
        let look = SkyModel.look(palette, hour: night ? 22 : 15, dark: true)
        var scene = SkyScene(look: look)
        if let arc {
            scene.arc = arc
            scene.body = night ? .moon : .sun
            scene.bodyProgress = 0.16
            scene.rare = false
        }
        guard let image = SkyRenderer.shared?.image(scene, time: 6.5, size: size, scale: 1) else { return nil }
        lock.lock()
        if backgrounds.count > 60 { backgrounds.removeAll() }
        backgrounds[cacheKey] = image
        lock.unlock()
        return image
    }

    private static func fillGradient(_ ctx: CGContext, _ rect: CGRect, top: RGB, bottom: RGB) {
        NSGradient(starting: WrappedCard.color(top), ending: WrappedCard.color(bottom))?.draw(in: rect, angle: 90)
    }

    /// The glyph for a biome, in white, centred in `rect`.
    static func drawGlyph(_ info: BiomeInfo, night: Bool, in rect: CGRect, _ ctx: CGContext) {
        let key = info.key.value
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: rect.width * 0.08, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        if let path = BiomeGlyphPaths.custom(for: key, in: rect) {
            ctx.addPath(path)
            if BiomeGlyphPaths.isStroked(key) {
                ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(max(2, rect.width * 0.09)); ctx.setLineCap(.round); ctx.strokePath()
            } else {
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fillPath(using: BiomeGlyphPaths.usesEvenOdd(key) ? .evenOdd : .winding)
            }
        } else {
            let name = key == "NORMAL" ? (night ? "moon.stars.fill" : "sun.max.fill") : (info.symbol ?? (info.category == .unknown ? "questionmark.circle.fill" : "cloud.fill"))
            drawSymbol(name, in: rect)
        }
        ctx.restoreGState()
    }

    static func drawSymbol(_ name: String, in rect: CGRect, color: NSColor = .white) {
        let config = NSImage.SymbolConfiguration(pointSize: rect.height * 0.8, weight: .semibold).applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let s = image.size
        let scale = min(rect.width / s.width, rect.height / s.height)
        let target = CGRect(x: rect.midX - s.width * scale / 2, y: rect.midY - s.height * scale / 2, width: s.width * scale, height: s.height * scale)
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// The diagonal "Preview" ribbon on anything that is not a real event.
    private static func previewRibbon(_ ctx: CGContext, size: CGSize) {
        ctx.saveGState()
        let band: CGFloat = max(34, size.height * 0.11)
        ctx.translateBy(x: size.width - band * 2.6, y: band * 2.6)
        ctx.rotate(by: .pi / 4)
        let rect = CGRect(x: -size.width, y: -band / 2 - band * 2.2, width: size.width * 2, height: band)
        ctx.setFillColor(NSColor(srgbRed: 0.98, green: 0.76, blue: 0.20, alpha: 0.96).cgColor)
        ctx.fill(rect)
        let font = WrappedCard.font(band * 0.5, .heavy, rounded: true)
        let text = NSAttributedString(string: "PREVIEW", attributes: [.font: font, .foregroundColor: NSColor(srgbRed: 0.12, green: 0.10, blue: 0.02, alpha: 1), .kern: band * 0.12])
        let w = text.size().width
        text.draw(at: CGPoint(x: -w / 2, y: rect.minY + (band - font.pointSize * 1.25) / 2))
        ctx.restoreGState()
    }

    // MARK: thumbnails

    /// A small tile of the biome's own sky with its glyph.
    public static func biomeThumb(_ info: BiomeInfo, hour: Double) -> SkyPicture? {
        let size = thumbSize
        guard let ctx = context(size) else { return nil }
        let rect = CGRect(origin: .zero, size: size)
        return drawing(ctx) {
            let clip = CGPath(roundedRect: rect, cornerWidth: 44, cornerHeight: 44, transform: nil)
            ctx.addPath(clip); ctx.clip()
            if let image = sky(info.palette, key: info.key.value, hour: hour, size: CGSize(width: size.width * 2, height: size.height * 2)) {
                drawImage(image, in: rect, ctx)
            } else {
                let look = SkyModel.look(info.palette, hour: hour, dark: true)
                fillGradient(ctx, rect, top: look.top, bottom: look.bottom)
            }
            NSColor.black.withAlphaComponent(0.12).setFill(); rect.fill()
            drawGlyph(info, night: SkyClock(hour: hour).isNight, in: rect.insetBy(dx: 46, dy: 46), ctx)
            ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 43, cornerHeight: 43, transform: nil))
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor); ctx.setLineWidth(3); ctx.strokePath()
            return ctx.makeImage().flatMap { encode($0, opaque: false, text: []) }
        }
    }

    /// The aura's emblem, cut from its Sol Dex card.
    public static func auraThumb(name: String, auras: AuraCatalog) -> SkyPicture? {
        let size = thumbSize
        guard let ctx = context(size) else { return nil }
        let entry = auras.info(for: name)
        let tier = DexTier(catalog: entry?.tier)
        let face = FoilCard(level: FoilLevel.of(tier: tier, chance: entry?.chance), top: tier.color, bottom: tier.color.mix(RGB(hex: 0x1E2F8F), 0.5),
                            seed: SolDex.seed(AuraCatalog.key(name)))
        let rect = CGRect(origin: .zero, size: size)
        return drawing(ctx) {
            ctx.addPath(CGPath(ellipseIn: rect.insetBy(dx: 2, dy: 2), transform: nil)); ctx.clip()
            if let image = FoilRenderer.shared?.image(face, size: CGSize(width: 190, height: 260), scale: 2),
               // The emblem sits at (0.5, 0.40) of the card; take a square around it.
               let crop = image.cropping(to: CGRect(x: 380 * 0.5 - 132, y: 520 * 0.40 - 132, width: 264, height: 264)) {
                drawImage(crop, in: rect, ctx)
            } else {
                fillGradient(ctx, rect, top: tier.color.scaled(0.6), bottom: tier.color.scaled(0.25))
                drawSymbol("sparkles", in: rect.insetBy(dx: 52, dy: 52))
            }
            ctx.addPath(CGPath(ellipseIn: rect.insetBy(dx: 3.5, dy: 3.5), transform: nil))
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor); ctx.setLineWidth(3); ctx.strokePath()
            return ctx.makeImage().flatMap { encode($0, opaque: false, text: []) }
        }
    }

    /// An SF Symbol on a tile of one colour, for messages that are not about a biome or an aura.
    public static func symbolThumb(_ symbol: String, tint: RGB) -> SkyPicture? {
        let size = thumbSize
        guard let ctx = context(size) else { return nil }
        let rect = CGRect(origin: .zero, size: size)
        return drawing(ctx) {
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 44, cornerHeight: 44, transform: nil)); ctx.clip()
            fillGradient(ctx, rect, top: tint.mix(RGB(hex: 0x1B1F5E), 0.35), bottom: tint.mix(RGB(hex: 0x0B1026), 0.72))
            drawSymbol(symbol, in: rect.insetBy(dx: 50, dy: 50))
            ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 43, cornerHeight: 43, transform: nil))
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor); ctx.setLineWidth(3); ctx.strokePath()
            return ctx.makeImage().flatMap { encode($0, opaque: false, text: []) }
        }
    }

    // MARK: cards

    /// The sky banner: a biome's sky with the Sun-Arc, its name, and one line that never goes stale.
    public static func banner(palette: BiomePalette, key: String, eyebrow: String, title: String, line: String, hour: Double, preview: Bool) -> SkyPicture? {
        let size = bannerSize
        guard let ctx = context(size) else { return nil }
        let rect = CGRect(origin: .zero, size: size)
        let words = [eyebrow.uppercased(), title, line, "SiverSol"] + (preview ? ["PREVIEW"] : [])
        return drawing(ctx) {
            let arc = SkyArc.fitting(CGRect(x: 600, y: 64, width: 440, height: 130))
            if let image = sky(palette, key: key, hour: hour, size: size, arc: arc) {
                drawImage(image, in: rect, ctx)
            } else {
                let look = SkyModel.look(palette, hour: hour, dark: true)
                fillGradient(ctx, rect, top: look.top, bottom: look.bottom)
            }
            // A soft shade on the left, behind the words.
            NSGradient(colors: [NSColor.black.withAlphaComponent(0.42), NSColor.black.withAlphaComponent(0.0)])?.draw(in: CGRect(x: 0, y: 0, width: 820, height: size.height), angle: 0)
            let white = NSColor.white
            WrappedCard.draw(eyebrow.uppercased(), at: CGPoint(x: 56, y: 70), width: 600, font: WrappedCard.font(27, .bold), color: white.withAlphaComponent(0.88), kern: 5)
            WrappedCard.draw(title, at: CGPoint(x: 52, y: 104), width: 700, font: WrappedCard.font(118, .heavy, rounded: true), color: white)
            WrappedCard.draw(line, at: CGPoint(x: 56, y: 262), width: 760, font: WrappedCard.font(36, .medium, mono: true), color: white.withAlphaComponent(0.92))
            WrappedCard.draw("SiverSol", at: CGPoint(x: size.width - 56 - 300, y: 318), width: 300, font: WrappedCard.font(32, .bold, rounded: true),
                             color: NSColor(srgbRed: 0.90, green: 0.92, blue: 0.95, alpha: 0.9), align: .right)
            if preview { previewRibbon(ctx, size: size) }
            return ctx.makeImage().flatMap { encode($0, opaque: true, text: words) }
        }
    }

    /// The aura's Sol Dex card, with what never changes about it: name, tier and odds.
    public static func auraCard(name: String, auras: AuraCatalog, preview: Bool) -> SkyPicture? {
        let size = auraCardSize
        guard let ctx = context(size) else { return nil }
        let entry = auras.info(for: name)
        let display = entry?.display ?? AuraName.display(name)
        let tier = DexTier(catalog: entry?.tier)
        let level = FoilLevel.of(tier: tier, chance: entry?.chance)
        let face = FoilCard(level: level, top: tier.color, bottom: tier.color.mix(RGB(hex: 0x1E2F8F), 0.5), seed: SolDex.seed(AuraCatalog.key(name)))
        let rect = CGRect(origin: .zero, size: size)
        let tierLabel = (entry?.tier ?? "Aura").uppercased()
        let odds = entry?.chance.map { "1 in \(AuraCatalog.grouped($0))" } ?? "odds unknown"
        var words = [tierLabel, odds, display, "SiverSol · Sol Dex"]
        if let native = entry?.nativeBiome { words.append("native to \(native.capitalized)") }
        if let only = entry?.onlyIn { words.append("only in \(only.capitalized)") }
        if preview { words.append("PREVIEW") }
        return drawing(ctx) {
            // A full rectangle (Discord rounds the corners of pictures itself), so the card can be a JPEG when
            // its foil is too busy to stay small as a PNG.
            if let image = FoilRenderer.shared?.image(face, size: CGSize(width: 190, height: 266), scale: size.width / 190) {
                drawImage(image, in: rect, ctx)
            } else {
                fillGradient(ctx, rect, top: tier.color.scaled(0.46), bottom: tier.color.scaled(0.18))
            }
            let white = NSColor.white
            WrappedCard.draw(tierLabel, at: CGPoint(x: 62, y: 64), width: 300, font: WrappedCard.font(27, .heavy), color: white.withAlphaComponent(0.95), kern: 4)
            WrappedCard.draw(odds, at: CGPoint(x: size.width - 62 - 360, y: 64), width: 360, font: WrappedCard.font(25, .semibold, mono: true), color: white.withAlphaComponent(0.95), align: .right)
            WrappedCard.draw(display, at: CGPoint(x: 62, y: 632), width: size.width - 124, font: WrappedCard.font(64, .bold, rounded: true), color: white)
            let sub = entry?.nativeBiome.map { "native to \($0.capitalized)" } ?? entry?.onlyIn.map { "only in \($0.capitalized)" } ?? "\(level.name) foil"
            WrappedCard.draw(sub, at: CGPoint(x: 64, y: 716), width: size.width - 128, font: WrappedCard.font(28, .medium), color: white.withAlphaComponent(0.85))
            WrappedCard.draw("SiverSol · Sol Dex", at: CGPoint(x: 64, y: 760), width: size.width - 128, font: WrappedCard.font(22, .medium, mono: true), color: white.withAlphaComponent(0.6))
            if preview { previewRibbon(ctx, size: size) }
            return ctx.makeImage().flatMap { encode($0, opaque: true, text: words) }
        }
    }
}
