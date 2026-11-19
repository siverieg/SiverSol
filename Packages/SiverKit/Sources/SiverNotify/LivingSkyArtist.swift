import Foundation
import SiverCore
import SiverSky

/// Draws card pictures with the Living Sky renderer: the same sky, glyphs and Sol Dex cards the app shows.
public struct LivingSkyArtist: SkyArtist {
    private let catalog: BiomeCatalog
    private let auras: AuraCatalog

    public init(catalog: BiomeCatalog? = nil, auras: AuraCatalog = .bundled()) {
        self.catalog = catalog ?? ((try? BiomeCatalog.bundled(learnedURL: BiomeCatalog.defaultLearnedURL)) ?? BiomeCatalog(builtIn: []))
        self.auras = auras
    }

    private func file(_ picture: SkyPicture?, _ base: String) -> FileAttachment? {
        picture.map { FileAttachment(name: "\(base).\($0.fileExtension)", contentType: $0.fileExtension == "png" ? "image/png" : "image/jpeg", data: $0.data) }
    }

    /// The same pictures with the words drawn into them, for checks.
    public func picture(thumb: SkyArt.Thumb, art: SkyArt) -> SkyPicture? {
        switch thumb {
        case .biome(let key): return SkyCardArt.biomeThumb(catalog.info(for: BiomeKey(key)), hour: art.hour)
        case .aura(let name): return SkyCardArt.auraThumb(name: name, auras: auras)
        case .symbol(let symbol, let tint): return SkyCardArt.symbolThumb(symbol, tint: RGB(hex: tint))
        }
    }

    public func picture(card: SkyArt.Card, art: SkyArt) -> SkyPicture? {
        switch card {
        case .biome(let key, let eyebrow, let title, let line):
            return SkyCardArt.banner(palette: catalog.info(for: BiomeKey(key)).palette, key: key, eyebrow: eyebrow, title: title, line: line, hour: art.hour, preview: art.preview)
        case .aura(let name):
            return SkyCardArt.auraCard(name: name, auras: auras, preview: art.preview)
        case .banner(let title, let line, let biome):
            let key = biome ?? "NORMAL"
            return SkyCardArt.banner(palette: catalog.info(for: BiomeKey(key)).palette, key: key, eyebrow: "SiverSol", title: title, line: line, hour: art.hour, preview: art.preview)
        }
    }

    public func thumbnail(_ thumb: SkyArt.Thumb, art: SkyArt) -> FileAttachment? { file(picture(thumb: thumb, art: art), "sky-thumb") }
    public func card(_ card: SkyArt.Card, art: SkyArt) -> FileAttachment? { file(picture(card: card, art: art), "sky-card") }
}
