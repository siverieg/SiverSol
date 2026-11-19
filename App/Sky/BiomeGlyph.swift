import SiverCore
import SiverSky
import SwiftUI

/// A biome's mark in the app: an SF Symbol where a good one exists, a small drawing where none does.
/// (Emoji are for Discord; the app itself uses symbols.)
struct BiomeGlyph: View {
    let info: BiomeInfo
    var size: CGFloat = 18
    /// Night shows a moon for the plain sky.
    var night = false

    var body: some View {
        Group {
            switch info.key.value {
            case "GLITCHED": GlitchGlyph().fill(style: FillStyle(eoFill: false))
            case "PUMPKIN MOON": PumpkinGlyph().fill(style: FillStyle(eoFill: true))
            case "GRAVEYARD": TombstoneGlyph().fill(style: FillStyle(eoFill: true))
            case "AURORA": AuroraGlyph().stroke(style: StrokeStyle(lineWidth: max(1.4, size * 0.09), lineCap: .round))
            default:
                Image(systemName: symbolName)
                    .resizable().scaledToFit()
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// A plain SF Symbol for places that cannot draw a shape (the menu bar).
    static func menuSymbol(_ info: BiomeInfo, night: Bool) -> String {
        switch info.key.value {
        case "NORMAL": return night ? "moon.stars.fill" : "sun.max.fill"
        case "GLITCHED": return "square.stack.3d.forward.dottedline.fill"
        case "PUMPKIN MOON": return "moon.fill"
        case "GRAVEYARD": return "moon.haze.fill"
        case "AURORA": return "water.waves"
        default: return info.symbol ?? "cloud.fill"
        }
    }

    private var symbolName: String {
        if info.key.value == "NORMAL" { return night ? "moon.stars.fill" : "sun.max.fill" }
        return info.symbol ?? (info.category == .unknown ? "questionmark.circle.fill" : "cloud.fill")
    }
}

// The drawn glyphs live in SiverSky (`BiomeGlyphPaths`), so the app and the Discord pictures use the same shapes.

struct GlitchGlyph: Shape {
    func path(in r: CGRect) -> Path { Path(BiomeGlyphPaths.glitch(in: r)) }
}

struct PumpkinGlyph: Shape {
    func path(in r: CGRect) -> Path { Path(BiomeGlyphPaths.pumpkin(in: r)) }
}

struct TombstoneGlyph: Shape {
    func path(in r: CGRect) -> Path { Path(BiomeGlyphPaths.tombstone(in: r)) }
}

struct AuroraGlyph: Shape {
    func path(in r: CGRect) -> Path { Path(BiomeGlyphPaths.aurora(in: r)) }
}
