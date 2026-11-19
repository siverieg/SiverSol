import Foundation

/// A colour as three numbers from 0 to 1 (sRGB). Plain data, so the sky can be reasoned about and tested
/// without drawing anything.
public struct RGB: Equatable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

    public init(hex: Int) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    /// "#RRGGBB" or "RRGGBB". Anything else gives the fallback grey.
    public init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        self.init(hex: s.count == 6 ? (Int(s, radix: 16) ?? 0x99AAB5) : 0x99AAB5)
    }

    public static let white = RGB(1, 1, 1)
    public static let black = RGB(0, 0, 0)

    public func mix(_ o: RGB, _ t: Double) -> RGB {
        let t = min(1, max(0, t))
        return RGB(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t)
    }

    public func scaled(_ k: Double) -> RGB { RGB(min(1, r * k), min(1, g * k), min(1, b * k)) }

    /// WCAG relative luminance.
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast ratio, 1 (none) to 21 (black on white).
    public func contrast(_ o: RGB) -> Double {
        let a = luminance, b = o.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// 0xRRGGBB, the form Discord takes colours in.
    public var int: Int { (Int((r * 255).rounded()) << 16) | (Int((g * 255).rounded()) << 8) | Int((b * 255).rounded()) }

    public var hex: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

/// The weather a biome brings to the sky. The raw value is what `biomes.json` says; `index` is what the
/// renderer's shader switches on, so the order here must not change without changing the shader.
public enum SkyWeather: String, Codable, CaseIterable, Sendable {
    case clouds, wind, rain, snow, sand, embers, starfall, godrays, spores, void, glitch, dream, cyber, swirl
    case pumpkin, graveyard, bloodRain, aurora, forest, sun

    public var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// A biome's colours as the catalog gives them: the sky by day, an accent, and the colour of what falls or drifts.
public struct BiomePalette: Equatable, Sendable {
    public var skyTop: RGB
    public var skyBottom: RGB
    public var accent: RGB
    public var particle: RGB
    public var weather: SkyWeather
    /// How much the biome takes over the sky: 0 leaves the plain time-of-day sky, 1 ignores the time of day.
    public var skyBlend: Double

    public init(skyTop: RGB, skyBottom: RGB, accent: RGB, particle: RGB, weather: SkyWeather, skyBlend: Double) {
        self.skyTop = skyTop; self.skyBottom = skyBottom; self.accent = accent; self.particle = particle
        self.weather = weather; self.skyBlend = skyBlend
    }

    /// The plain sky: what shows when nothing is running, and what an unknown biome is tinted from.
    public static let clear = BiomePalette(skyTop: RGB(hex: 0x3F8FE0), skyBottom: RGB(hex: 0xBFE3FA), accent: RGB(hex: 0xF7C948),
                                           particle: .white, weather: .clouds, skyBlend: 0)

    /// A biome nobody has described yet: the plain scene, tinted with its catalog colour.
    public static func tinted(_ color: RGB) -> BiomePalette {
        BiomePalette(skyTop: clear.skyTop.mix(color, 0.45), skyBottom: clear.skyBottom.mix(color, 0.35), accent: color,
                     particle: .white, weather: .clouds, skyBlend: 0.4)
    }
}

extension BiomeInfo {
    /// The catalog's palette for this biome, or the plain scene tinted with its colour.
    public var palette: BiomePalette {
        guard let skyTop, let skyBottom else { return key.value == "NORMAL" ? .clear : .tinted(RGB(hex: color)) }
        let own = RGB(hex: color)
        return BiomePalette(skyTop: RGB(hex: skyTop), skyBottom: RGB(hex: skyBottom),
                            accent: accent.map(RGB.init(hex:)) ?? own, particle: particle.map(RGB.init(hex:)) ?? .white,
                            weather: weather.flatMap(SkyWeather.init(rawValue:)) ?? .clouds, skyBlend: skyBlend ?? 0.8)
    }
}

public enum DayPhase: String, Sendable, CaseIterable { case dawn, day, dusk, night }

/// Where the local clock puts the sky.
public struct SkyClock: Equatable, Sendable {
    /// 0 at night, 1 in full daylight, in between at dawn and dusk.
    public var daylight: Double
    /// How strongly the horizon glows warm: 1 at the middle of dawn or dusk, 0 otherwise.
    public var warmth: Double
    public var phase: DayPhase

    public var isNight: Bool { daylight < 0.5 }

    private static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// `hour` is the local time as a number, 0 up to 24 (18.5 is half past six in the evening).
    public init(hour: Double) {
        let h = hour.truncatingRemainder(dividingBy: 24) < 0 ? hour.truncatingRemainder(dividingBy: 24) + 24 : hour.truncatingRemainder(dividingBy: 24)
        let rise = Self.smooth(5, 8, h), set = 1 - Self.smooth(17, 20.5, h)
        daylight = min(rise, set)
        let dawn = max(0, 1 - abs(h - 6.5) / 1.5), dusk = max(0, 1 - abs(h - 18.75) / 1.75)
        warmth = max(dawn, dusk)
        if h >= 5, h < 8 { phase = .dawn } else if h >= 8, h < 17 { phase = .day } else if h >= 17, h < 20.5 { phase = .dusk } else { phase = .night }
    }

    public init(date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        self.init(hour: Double(c.hour ?? 12) + Double(c.minute ?? 0) / 60)
    }

    /// A fixed hour that stands for each phase, for previews and snapshots.
    public static func hour(for phase: DayPhase) -> Double {
        switch phase {
        case .dawn: return 6.5
        case .day: return 13
        case .dusk: return 18.75
        case .night: return 23
        }
    }
}

/// The sky as it should be painted right now: a biome's palette seen at a time of day, in light or dark mode.
public struct SkyLook: Equatable, Sendable {
    public var top: RGB
    public var bottom: RGB
    public var accent: RGB
    public var particle: RGB
    public var weather: SkyWeather
    /// 0 by day, 1 at night.
    public var night: Double
    /// The colour of text that sits directly on the sky (the Dashboard's hero).
    public var ink: RGB
    public var inkIsLight: Bool
    /// How strong a scrim (black under light ink, white under dark ink) the hero text needs to stay readable.
    public var veil: Double
}

public enum SkyModel {
    static let nightTop = RGB(hex: 0x070B1E), nightBottom = RGB(hex: 0x1B2148)
    static let dayTop = RGB(hex: 0x3F8FE0), dayBottom = RGB(hex: 0xBFE3FA)
    static let warmTop = RGB(hex: 0x4A3F86), warmBottom = RGB(hex: 0xF29A64)
    public static let lightInk = RGB.white
    public static let darkInk = RGB(hex: 0x0B1026)
    /// Text on the sky must reach this contrast (WCAG AA for normal text).
    public static let minimumContrast = 4.5

    /// - Parameters:
    ///   - hour: local time, 0 up to 24.
    ///   - dark: the app's appearance. Light mode leans towards a daytime sky, dark mode towards a night sky.
    public static func look(_ p: BiomePalette, hour: Double, dark: Bool) -> SkyLook {
        let clock = SkyClock(hour: hour)
        let d = clock.daylight, w = clock.warmth

        // The plain sky for this time of day.
        var timeTop = nightTop.mix(dayTop, d), timeBottom = nightBottom.mix(dayBottom, d)
        timeTop = timeTop.mix(warmTop, w * 0.55)
        timeBottom = timeBottom.mix(warmBottom, w * 0.8)

        // The biome's own sky: as the catalog gives it by day, the same hues sunk into the dark at night.
        func atNight(_ c: RGB) -> RGB { c.scaled(0.34).mix(nightTop, 0.25) }
        let biomeTop = atNight(p.skyTop).mix(p.skyTop, d), biomeBottom = atNight(p.skyBottom).mix(p.skyBottom, d)

        var top = timeTop.mix(biomeTop, p.skyBlend), bottom = timeBottom.mix(biomeBottom, p.skyBlend)
        if dark {
            // Dark mode: the same sky, deeper.
            top = top.scaled(0.6).mix(nightTop, 0.18)
            bottom = bottom.scaled(0.62).mix(nightBottom, 0.14)
        } else if d < 1 {
            // Light mode at night: a pale, moonlit night instead of a black one.
            let lift = (1 - d) * 0.22
            top = top.mix(RGB(hex: 0x3A4A8C), lift)
            bottom = bottom.mix(RGB(hex: 0x6F7FC0), lift)
        }

        let night = 1 - d
        let particle = p.particle.mix(p.particle.scaled(0.75), night * 0.5)

        // Text on the sky: light or dark ink, whichever reads better over the middle of the gradient, and a scrim
        // only as strong as needed. The sky keeps its colours; the scrim is what gives way.
        let middle = top.mix(bottom, 0.5)
        let light = lightInk.contrast(middle) >= darkInk.contrast(middle)
        let ink = light ? lightInk : darkInk
        let scrim = light ? RGB.black : RGB.white
        var veil = 0.0
        func worst(_ v: Double) -> Double {
            [top, middle, bottom].map { ink.contrast($0.mix(scrim, v)) }.min() ?? 1
        }
        while worst(veil) < minimumContrast, veil < 0.9 { veil += 0.02 }
        return SkyLook(top: top, bottom: bottom, accent: p.accent, particle: particle, weather: p.weather, night: night,
                       ink: ink, inkIsLight: light, veil: veil)
    }

    // MARK: cards

    /// The base colour laid over the material of a content card, and how opaque it is. Together with the text
    /// colours below this is what keeps a card readable over the brightest and the darkest sky.
    public static func cardBase(dark: Bool) -> (color: RGB, opacity: Double) {
        dark ? (RGB(hex: 0x14161C), 0.74) : (RGB(hex: 0xFFFFFF), 0.78)
    }

    public static func cardInk(dark: Bool) -> (primary: RGB, secondaryOpacity: Double) {
        dark ? (RGB(hex: 0xFFFFFF), 0.62) : (RGB(hex: 0x000000), 0.62)
    }

    /// The colour a card ends up with over a patch of sky, in the worst case (the material adds nothing).
    public static func cardColor(over sky: RGB, tint: RGB, dark: Bool) -> RGB {
        let base = cardBase(dark: dark)
        return sky.mix(base.color, base.opacity).mix(tint, 0.06)
    }

    /// Contrast of primary and secondary text on a card over a patch of sky.
    public static func cardContrast(over sky: RGB, tint: RGB, dark: Bool) -> (primary: Double, secondary: Double) {
        let card = cardColor(over: sky, tint: tint, dark: dark)
        let ink = cardInk(dark: dark)
        return (ink.primary.contrast(card), card.mix(ink.primary, ink.secondaryOpacity).contrast(card))
    }

    // MARK: the sun-arc

    /// Where the sun or moon sits on its arc, 0 (left end) to 1 (right end).
    /// With a known length it is the share of the biome that has passed; without one it drifts slowly around the top.
    public static func arcProgress(elapsed: TimeInterval, duration: TimeInterval?) -> Double {
        if let duration, duration > 0 { return min(1, max(0, elapsed / duration)) }
        return 0.5 + 0.22 * sin(elapsed / 38)
    }
}
