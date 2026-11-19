// Draws SiverSol's app icon (original artwork: a silver-rimmed crescent moon cradling a small sun, over a dusk sky)
// and writes every size macOS wants: `swift Tools/make_icon.swift App/Assets.xcassets/AppIcon.appiconset`
import AppKit
import CoreGraphics

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "App/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func star(_ ctx: CGContext, center: CGPoint, radius: CGFloat, waist: CGFloat) {
    // Four points, with sides that curve inwards.
    let path = CGMutablePath()
    for i in 0..<4 {
        let a = CGFloat(i) * .pi / 2 - .pi / 2
        let tip = CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
        let next = a + .pi / 2
        let nextTip = CGPoint(x: center.x + cos(next) * radius, y: center.y + sin(next) * radius)
        let mid = a + .pi / 4
        let control = CGPoint(x: center.x + cos(mid) * radius * waist, y: center.y + sin(mid) * radius * waist)
        if i == 0 { path.move(to: tip) }
        path.addQuadCurve(to: nextTip, control: control)
    }
    path.closeSubpath()
    ctx.addPath(path)
    ctx.fillPath()
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // The standard macOS icon shape: a rounded square with a margin around it.
    let inset = s * 0.098
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.2237, cornerHeight: rect.width * 0.2237, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape); ctx.setFillColor(rgb(0x1B1F5E)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()

    // Dusk: indigo at the top, violet, amber at the horizon.
    let dusk = CGGradient(colorsSpace: srgb, colors: [rgb(0x15174F), rgb(0x3B2A86), rgb(0x8A4AA8), rgb(0xE98A5B), rgb(0xF7B45E)] as CFArray,
                          locations: [0, 0.34, 0.62, 0.86, 1])!
    ctx.drawLinearGradient(dusk, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])

    // A few stars high up (left out at the smallest sizes, where they would only be noise).
    if px >= 64 {
        ctx.setFillColor(rgb(0xFFFFFF, 0.9)); star(ctx, center: CGPoint(x: s * 0.27, y: s * 0.76), radius: s * 0.032, waist: 0.2)
        ctx.setFillColor(rgb(0xFFFFFF, 0.75)); star(ctx, center: CGPoint(x: s * 0.74, y: s * 0.80), radius: s * 0.022, waist: 0.2)
        ctx.setFillColor(rgb(0xFFFFFF, 0.6)); star(ctx, center: CGPoint(x: s * 0.80, y: s * 0.30), radius: s * 0.018, waist: 0.2)
    }

    // The sun, small and warm, sitting in the crescent's cradle.
    let sun = CGPoint(x: s * 0.575, y: s * 0.505)
    let sunR = s * 0.105
    let halo = CGGradient(colorsSpace: srgb, colors: [rgb(0xFFE7A3, 0.75), rgb(0xFFC56B, 0.28), rgb(0xFFC56B, 0)] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(halo, startCenter: sun, startRadius: sunR * 0.6, endCenter: sun, endRadius: sunR * 3.1, options: [])

    // The crescent moon: a disc with a smaller disc taken out, opening towards the sun.
    let moonC = CGPoint(x: s * 0.47, y: s * 0.50), moonR = s * 0.292
    let big = CGPath(ellipseIn: CGRect(x: moonC.x - moonR, y: moonC.y - moonR, width: moonR * 2, height: moonR * 2), transform: nil)
    let cutC = CGPoint(x: s * 0.585, y: s * 0.535), cutR = s * 0.238
    let cut = CGPath(ellipseIn: CGRect(x: cutC.x - cutR, y: cutC.y - cutR, width: cutR * 2, height: cutR * 2), transform: nil)
    let crescent = big.subtracting(cut)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.035, color: rgb(0x0B0A2E, 0.55))
    ctx.addPath(crescent); ctx.setFillColor(rgb(0xE9EDF4)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(crescent); ctx.clip()
    let body = CGGradient(colorsSpace: srgb, colors: [rgb(0xFFFFFF), rgb(0xDDE3EC), rgb(0xA9B4C6)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(body, start: CGPoint(x: moonC.x - moonR, y: moonC.y + moonR), end: CGPoint(x: moonC.x + moonR * 0.4, y: moonC.y - moonR), options: [])
    // Warm light from the sun on the inner edge.
    let warm = CGGradient(colorsSpace: srgb, colors: [rgb(0xFFD79A, 0.55), rgb(0xFFD79A, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(warm, startCenter: sun, startRadius: sunR, endCenter: sun, endRadius: moonR * 1.15, options: [])
    ctx.restoreGState()
    // The silver rim.
    ctx.saveGState()
    ctx.addPath(crescent)
    ctx.setLineWidth(max(1, s * 0.012))
    ctx.replacePathWithStrokedPath(); ctx.clip()
    let rim = CGGradient(colorsSpace: srgb, colors: [rgb(0xFFFFFF), rgb(0xC9D1DC), rgb(0x8E9AAE), rgb(0xE8ECF2)] as CFArray, locations: [0, 0.4, 0.75, 1])!
    ctx.drawLinearGradient(rim, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    ctx.restoreGState()

    // The sun's disc, drawn last so it sits in front of the moon's inner edge.
    let disc = CGGradient(colorsSpace: srgb, colors: [rgb(0xFFF6D6), rgb(0xFFD36B), rgb(0xF7A63A)] as CFArray, locations: [0, 0.6, 1])!
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: sun.x - sunR, y: sun.y - sunR, width: sunR * 2, height: sunR * 2)); ctx.clip()
    ctx.drawRadialGradient(disc, startCenter: CGPoint(x: sun.x - sunR * 0.25, y: sun.y + sunR * 0.3), startRadius: 0, endCenter: sun, endRadius: sunR * 1.05, options: [])
    ctx.restoreGState()

    ctx.restoreGState()
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(points * scale).write(to: out.appendingPathComponent(name))
        images.append(["size": "\(points)x\(points)", "idiom": "mac", "filename": name, "scale": "\(scale)x"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("Contents.json"))
print("wrote \(images.count) images to \(out.path)")
