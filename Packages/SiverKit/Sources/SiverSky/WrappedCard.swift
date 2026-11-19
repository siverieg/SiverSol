import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SiverCore
import UniformTypeIdentifiers

/// Session Wrapped: one picture that sums a session up, in the Living Sky style. Drawn entirely in code: the sky
/// of the session's signature biome, the biome mix as a ring, the rarest roll as its Sol Dex card, and a few numbers.
public enum WrappedCard {
    public static let size = CGSize(width: 1080, height: 1350)

    static func font(_ size: CGFloat, _ weight: NSFont.Weight, rounded: Bool = false, mono: Bool = false) -> NSFont {
        if mono { return NSFont.monospacedSystemFont(ofSize: size, weight: weight) }
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard rounded, let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: d, size: size) ?? base
    }

    static func color(_ c: RGB, _ alpha: CGFloat = 1) -> NSColor { NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha) }

    static func text(_ s: String, _ f: NSFont, _ c: NSColor, kern: CGFloat = 0) -> NSAttributedString {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        return NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c, .kern: kern, .shadow: shadow])
    }

    /// Draw text so that it fits `width`, shrinking the type a little before cutting it short.
    static func draw(_ s: String, at p: CGPoint, width: CGFloat, font f: NSFont, color c: NSColor, kern: CGFloat = 0, align: NSTextAlignment = .left) {
        var font = f
        var attributed = text(s, font, c, kern: kern)
        while attributed.size().width > width, font.pointSize > f.pointSize * 0.6 {
            font = NSFont(descriptor: font.fontDescriptor, size: font.pointSize - 1) ?? font
            attributed = text(s, font, c, kern: kern)
        }
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineBreakMode = .byTruncatingTail
        let m = NSMutableAttributedString(attributedString: attributed)
        m.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: m.length))
        m.draw(in: CGRect(x: p.x, y: p.y, width: width, height: font.pointSize * 1.4))
    }

    static func panel(_ rect: CGRect, radius: CGFloat = 34) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.black.withAlphaComponent(0.46).setFill(); path.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke(); path.lineWidth = 1.5; path.stroke()
    }

    public static func duration(_ t: Double) -> String {
        let s = Int(t.rounded())
        if s >= 3600 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        if s >= 60 { return "\(s / 60)m" }
        return "\(s)s"
    }

    /// The colour a biome gets in the ring.
    static func ringColor(_ key: String, catalog: BiomeCatalog) -> RGB {
        if key == "NORMAL" { return RGB(hex: 0x6FA8DC) }
        if key == "OTHER" { return RGB(hex: 0x8A93A3) }
        return catalog.info(for: BiomeKey(key)).palette.accent
    }

    public static func render(_ wrap: SessionWrap, catalog: BiomeCatalog, auras: AuraCatalog, sky: SkyRenderer?, foil: FoilRenderer?,
                              calendar: Calendar = .current) -> CGImage? {
        let W = size.width, H = size.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        // Top-left origin for layout.
        ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.current = previous }

        func drawImage(_ image: CGImage, in rect: CGRect) {
            ctx.saveGState()
            ctx.translateBy(x: rect.minX, y: rect.maxY); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
            ctx.restoreGState()
        }

        // The sky of the session's signature biome, at the hour the session was half over.
        let info = catalog.info(for: BiomeKey(wrap.signatureBiome))
        let middle = wrap.start.addingTimeInterval(wrap.duration / 2)
        let look = SkyModel.look(info.palette, hour: SkyClock(date: middle, calendar: calendar).daylight > 0.5 ? 16 : 22, dark: true)
        if let sky, let image = sky.image(SkyScene(look: look), time: 6.5, size: CGSize(width: W / 2, height: H / 2), scale: 2) {
            drawImage(image, in: CGRect(x: 0, y: 0, width: W, height: H))
        } else {
            let g = NSGradient(starting: color(look.top), ending: color(look.bottom))
            g?.draw(in: CGRect(x: 0, y: 0, width: W, height: H), angle: 90)
        }
        NSGradient(colors: [NSColor.black.withAlphaComponent(0.10), NSColor.black.withAlphaComponent(0.50)])?.draw(in: CGRect(x: 0, y: 0, width: W, height: H), angle: 90)

        let white = NSColor.white, soft = NSColor.white.withAlphaComponent(0.82), dim = NSColor.white.withAlphaComponent(0.62)
        let m: CGFloat = 64

        // Header.
        draw("SiverSol", at: CGPoint(x: m, y: 56), width: 400, font: font(46, .bold, rounded: true), color: NSColor(srgbRed: 0.90, green: 0.92, blue: 0.95, alpha: 1))
        let day = DateFormatter(); day.calendar = calendar; day.timeZone = calendar.timeZone; day.locale = Locale(identifier: "en_GB"); day.dateFormat = "d MMM yyyy"
        draw(day.string(from: wrap.end), at: CGPoint(x: W - m - 400, y: 68), width: 400, font: font(26, .medium, mono: true), color: soft, align: .right)

        // The headline: how long the sky was watched.
        draw("SESSION WRAPPED", at: CGPoint(x: m, y: 158), width: W - 2 * m, font: font(26, .bold), color: soft, kern: 6)
        draw(duration(wrap.duration), at: CGPoint(x: m - 4, y: 186), width: W - 2 * m, font: font(150, .heavy, rounded: true), color: white)
        let clock = DateFormatter(); clock.calendar = calendar; clock.timeZone = calendar.timeZone; clock.locale = Locale(identifier: "en_US"); clock.dateFormat = "h:mm a"
        draw("under the sky · \(clock.string(from: wrap.start)) to \(clock.string(from: wrap.end))", at: CGPoint(x: m, y: 372), width: W - 2 * m, font: font(30, .regular), color: soft)

        // Left: the biome mix as a ring.
        let left = CGRect(x: m, y: 452, width: 456, height: 500)
        panel(left)
        draw("BIOME MIX", at: CGPoint(x: left.minX + 30, y: left.minY + 26), width: 300, font: font(22, .bold), color: soft, kern: 3)
        let mix = wrap.mix(top: 5)
        let c = CGPoint(x: left.midX, y: left.minY + 208), outer: CGFloat = 118, inner: CGFloat = 74
        var angle = -CGFloat.pi / 2
        if mix.isEmpty {
            let ring = NSBezierPath(ovalIn: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
            NSColor.white.withAlphaComponent(0.12).setFill(); ring.fill()
        }
        for slice in mix {
            let sweep = CGFloat(slice.share) * 2 * .pi
            let path = CGMutablePath()
            path.addArc(center: c, radius: outer, startAngle: angle, endAngle: angle + sweep, clockwise: false)
            path.addArc(center: c, radius: inner, startAngle: angle + sweep, endAngle: angle, clockwise: true)
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(color(ringColor(slice.key, catalog: catalog)).cgColor)
            ctx.fillPath()
            ctx.addPath(path); ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor); ctx.setLineWidth(2); ctx.strokePath()
            angle += sweep
        }
        let starts = wrap.biomeCounts.values.reduce(0, +)
        draw("\(starts)", at: CGPoint(x: c.x - inner, y: c.y - 44), width: inner * 2, font: font(54, .heavy, rounded: true), color: white, align: .center)
        draw(starts == 1 ? "biome" : "biomes", at: CGPoint(x: c.x - inner, y: c.y + 18), width: inner * 2, font: font(20, .medium), color: dim, align: .center)
        for (i, slice) in mix.prefix(6).enumerated() {
            let x = left.minX + 30 + CGFloat(i % 2) * 206, y = left.minY + 362 + CGFloat(i / 2) * 42
            ctx.setFillColor(color(ringColor(slice.key, catalog: catalog)).cgColor)
            ctx.fillEllipse(in: CGRect(x: x, y: y + 8, width: 16, height: 16))
            draw(slice.key.capitalized, at: CGPoint(x: x + 24, y: y), width: 118, font: font(21, .medium), color: white)
            draw("\(Int((slice.share * 100).rounded()))%", at: CGPoint(x: x + 138, y: y + 2), width: 58, font: font(19, .medium, mono: true), color: dim, align: .right)
        }

        // Right: the rarest roll, as its Sol Dex card.
        let right = CGRect(x: left.maxX + 40, y: 452, width: 456, height: 500)
        panel(right)
        draw("RAREST ROLL", at: CGPoint(x: right.minX + 30, y: right.minY + 26), width: 300, font: font(22, .bold), color: soft, kern: 3)
        if let name = wrap.rarestRoll {
            let entry = auras.info(for: name)
            let tier = DexTier(catalog: entry?.tier)
            let face = FoilCard(level: FoilLevel.of(tier: tier, chance: wrap.rarestRollChance), top: tier.color, bottom: tier.color.mix(RGB(hex: 0x1E2F8F), 0.5),
                                seed: SolDex.seed(AuraCatalog.key(name)))
            let cardRect = CGRect(x: right.midX - 112, y: right.minY + 72, width: 224, height: 306)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: color(tier.color, 0.6).cgColor)
            let clip = CGPath(roundedRect: cardRect, cornerWidth: 18, cornerHeight: 18, transform: nil)
            ctx.addPath(clip); ctx.setFillColor(color(tier.color.scaled(0.4)).cgColor); ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(clip); ctx.clip()
            if let foil, let image = foil.image(face, size: CGSize(width: 190, height: 260), scale: 2) { drawImage(image, in: cardRect) }
            ctx.restoreGState()
            ctx.addPath(clip); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.3).cgColor); ctx.setLineWidth(1.5); ctx.strokePath()
            draw(entry?.display ?? name, at: CGPoint(x: right.minX + 24, y: right.minY + 392), width: right.width - 48, font: font(34, .bold, rounded: true), color: white, align: .center)
            let odds = wrap.rarestRollChance.map { "1 in \(AuraCatalog.grouped($0))" } ?? "odds unknown"
            draw([odds, entry?.tier].compactMap { $0 }.joined(separator: " · "), at: CGPoint(x: right.minX + 24, y: right.minY + 440), width: right.width - 48,
                 font: font(22, .medium, mono: true), color: soft, align: .center)
        } else {
            draw("No rolls caught", at: CGPoint(x: right.minX + 24, y: right.midY - 40), width: right.width - 48, font: font(34, .bold, rounded: true), color: white, align: .center)
            draw("The next one lands here.", at: CGPoint(x: right.minX + 24, y: right.midY + 8), width: right.width - 48, font: font(24, .regular), color: dim, align: .center)
        }

        // The numbers.
        let tiles: [(String, String, String)] = [
            ("\(wrap.rares.count)", wrap.rares.count == 1 ? "rare biome" : "rare biomes", wrap.rares.isEmpty ? "none this time" : Array(Set(wrap.rares)).sorted().joined(separator: ", ").capitalized),
            (duration(wrap.longestNormalSeconds), "longest NORMAL", "without a break"),
            ("\(wrap.merchants)", wrap.merchants == 1 ? "merchant visit" : "merchant visits", "\(wrap.rolls) roll\(wrap.rolls == 1 ? "" : "s") caught"),
            ("\(wrap.macroRuns)", wrap.macroRuns == 1 ? "macro run" : "macro runs", "Macro Studio"),
        ]
        let tw = (W - 2 * m - 3 * 20) / 4
        for (i, t) in tiles.enumerated() {
            let r = CGRect(x: m + CGFloat(i) * (tw + 20), y: 984, width: tw, height: 226)
            panel(r, radius: 28)
            draw(t.0, at: CGPoint(x: r.minX + 16, y: r.minY + 30), width: r.width - 32, font: font(62, .heavy, rounded: true), color: white, align: .center)
            draw(t.1, at: CGPoint(x: r.minX + 12, y: r.minY + 118), width: r.width - 24, font: font(23, .semibold), color: soft, align: .center)
            draw(t.2, at: CGPoint(x: r.minX + 12, y: r.minY + 160), width: r.width - 24, font: font(18, .regular), color: dim, align: .center)
        }

        // Footer.
        draw("github.com/siverieg/SiverSol", at: CGPoint(x: m, y: 1256), width: 520, font: font(20, .medium, mono: true), color: dim)
        draw("drawn in code · nothing taken from the game", at: CGPoint(x: W - m - 520, y: 1256), width: 520, font: font(20, .regular), color: dim, align: .right)

        return ctx.makeImage()
    }

    /// A copy small enough to post (under 400 KB): the same card as a JPEG.
    public static func jpegForPosting(_ image: CGImage) -> Data? {
        SkyCardArt.encode(image, opaque: true, text: [])?.data
    }

    public static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
