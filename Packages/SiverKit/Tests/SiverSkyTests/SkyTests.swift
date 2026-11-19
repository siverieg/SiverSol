import CoreGraphics
import SiverCore
import XCTest
@testable import SiverSky

final class SkyTests: XCTestCase {
    private let catalog = try! BiomeCatalog.bundled()
    private let hours: [Double] = DayPhase.allCases.map(SkyClock.hour(for:)) + [0, 3, 5.5, 7.2, 12, 17.5, 20, 22]

    func testEveryCatalogBiomeHasAPaletteAndAKnownWeather() {
        for info in catalog.all {
            XCTAssertNotNil(info.skyTop, "\(info.key) has no skyTop")
            XCTAssertNotNil(info.skyBottom, "\(info.key) has no skyBottom")
            XCTAssertNotNil(info.accent, "\(info.key) has no accent")
            XCTAssertNotNil(info.particle, "\(info.key) has no particle colour")
            XCTAssertNotNil(info.weather.flatMap(SkyWeather.init(rawValue:)), "\(info.key) has an unknown weather")
        }
    }

    func testAnUnknownBiomeGetsThePlainSceneTintedWithItsColour() {
        let p = catalog.info(for: "SOMETHING NEW").palette
        XCTAssertEqual(p.weather, .clouds)
        XCTAssertEqual(p.accent, RGB(hex: 0x99AAB5))
        XCTAssertNotEqual(p.skyTop, BiomePalette.clear.skyTop)
    }

    func testClockPhases() {
        XCTAssertEqual(SkyClock(hour: 13).phase, .day)
        XCTAssertEqual(SkyClock(hour: 13).daylight, 1, accuracy: 0.001)
        XCTAssertEqual(SkyClock(hour: 23).phase, .night)
        XCTAssertEqual(SkyClock(hour: 23).daylight, 0, accuracy: 0.001)
        XCTAssertEqual(SkyClock(hour: 6.5).phase, .dawn)
        XCTAssertEqual(SkyClock(hour: 6.5).warmth, 1, accuracy: 0.001)
        XCTAssertEqual(SkyClock(hour: 18.75).phase, .dusk)
        XCTAssertTrue(SkyClock(hour: 2).isNight)
    }

    /// The legibility rule: text on the sky and text on cards must stay readable over the brightest scene
    /// (HEAVEN at noon) and the darkest (NULL at night), and everything in between.
    func testTextStaysReadableOverEverySky() {
        for info in catalog.all + [catalog.info(for: "SOMETHING NEW")] {
            for hour in hours {
                for dark in [false, true] {
                    let look = SkyModel.look(info.palette, hour: hour, dark: dark)
                    let scrim = look.inkIsLight ? RGB.black : RGB.white
                    for sky in [look.top, look.top.mix(look.bottom, 0.5), look.bottom] {
                        let name = "\(info.key) at \(hour) \(dark ? "dark" : "light")"
                        XCTAssertGreaterThanOrEqual(look.ink.contrast(sky.mix(scrim, look.veil)), SkyModel.minimumContrast, "hero text, \(name)")
                        let card = SkyModel.cardContrast(over: sky, tint: look.accent, dark: dark)
                        XCTAssertGreaterThanOrEqual(card.primary, 7, "card text, \(name)")
                        XCTAssertGreaterThanOrEqual(card.secondary, 4.5, "secondary card text, \(name)")
                    }
                    XCTAssertLessThanOrEqual(look.veil, 0.5, "\(info.key) at \(hour): the scrim should stay light")
                }
            }
        }
    }

    func testBrightestAndDarkestScenes() {
        let heaven = SkyModel.look(catalog.info(for: "HEAVEN").palette, hour: 12, dark: false)
        let null = SkyModel.look(catalog.info(for: "NULL").palette, hour: 23, dark: true)
        XCTAssertFalse(heaven.inkIsLight, "dark ink on a bright sky")
        XCTAssertTrue(null.inkIsLight, "light ink on a dark sky")
        XCTAssertGreaterThan(heaven.top.luminance, 0.6)
        XCTAssertLessThan(null.bottom.luminance, 0.01)
    }

    func testArcProgress() {
        XCTAssertEqual(SkyModel.arcProgress(elapsed: 30, duration: 120), 0.25, accuracy: 0.0001)
        XCTAssertEqual(SkyModel.arcProgress(elapsed: 500, duration: 120), 1)
        let drift = SkyModel.arcProgress(elapsed: 192, duration: nil)
        XCTAssertTrue((0.25...0.75).contains(drift), "with no known length the body stays near the top")
    }

    func testArcGeometry() throws {
        let arc = try XCTUnwrap(SkyArc.fitting(CGRect(x: 100, y: 50, width: 600, height: 150)))
        XCTAssertEqual(arc.point(0).x, 100, accuracy: 0.5)
        XCTAssertEqual(arc.point(0).y, 200, accuracy: 0.5)
        XCTAssertEqual(arc.point(0.5).x, 400, accuracy: 0.5)
        XCTAssertEqual(arc.point(0.5).y, 50, accuracy: 0.5)
        XCTAssertEqual(arc.point(1).x, 700, accuracy: 0.5)
    }

    func testWeatherIndexMatchesTheShaderOrder() {
        // The shader's `switch` uses these numbers.
        XCTAssertEqual(SkyWeather.clouds.index, 0)
        XCTAssertEqual(SkyWeather.rain.index, 2)
        XCTAssertEqual(SkyWeather.glitch.index, 10)
        XCTAssertEqual(SkyWeather.pumpkin.index, 14)
        XCTAssertEqual(SkyWeather.bloodRain.index, 16)
        XCTAssertEqual(SkyWeather.sun.index, 19)
    }

    func testShaderCompilesAndDrawsEveryWeather() throws {
        guard let renderer = SkyRenderer() else {
            if SkyRenderer.lastError.isEmpty { throw XCTSkip("no Metal device on this machine") }
            return XCTFail("the sky shader does not compile: \(SkyRenderer.lastError)")
        }
        for info in catalog.all {
            let look = SkyModel.look(info.palette, hour: 23, dark: true)
            var scene = SkyScene(look: look)
            scene.arc = SkyArc.fitting(CGRect(x: 40, y: 20, width: 240, height: 60))
            scene.body = .moon
            let image = try XCTUnwrap(renderer.image(scene, size: CGSize(width: 320, height: 200), scale: 1), "\(info.key)")
            XCTAssertEqual(image.width, 320)
        }
    }

    /// Reduce Motion: with motion off the picture must not depend on the clock.
    func testStillSkyDoesNotMove() throws {
        guard let renderer = SkyRenderer() else { throw XCTSkip("no Metal device on this machine") }
        for key in ["RAINY", "GLITCHED", "SNOWY", "PUMPKIN MOON"] {
            let scene = SkyScene(look: SkyModel.look(catalog.info(for: BiomeKey(key)).palette, hour: 23, dark: true), motion: false)
            let a = try XCTUnwrap(renderer.image(scene, time: 1, size: CGSize(width: 160, height: 100), scale: 1))
            let b = try XCTUnwrap(renderer.image(scene, time: 77, size: CGSize(width: 160, height: 100), scale: 1))
            let da = a.dataProvider?.data as Data?, db = b.dataProvider?.data as Data?
            let differing = zip(da ?? Data(), db ?? Data()).filter { abs(Int($0) - Int($1)) > 2 }.count
            XCTAssertEqual(differing, 0, "\(key): the still sky changed between two moments")
        }
    }
}

final class FoilTests: XCTestCase {
    private func luminance(_ image: CGImage) -> Double {
        let data = image.dataProvider?.data as Data? ?? Data()
        var sum = 0.0
        var i = 0
        while i + 3 < data.count { sum += Double(data[i]) + Double(data[i + 1]) + Double(data[i + 2]); i += 4 }
        return sum / Double(max(1, data.count / 4) * 3 * 255)
    }

    func testFoilShaderCompilesAndDrawsEveryLevel() throws {
        guard let renderer = FoilRenderer() else {
            if FoilRenderer.lastError.isEmpty { throw XCTSkip("no Metal device on this machine") }
            return XCTFail("the foil shader does not compile: \(FoilRenderer.lastError)")
        }
        var previous = 0.0
        for level in FoilLevel.allCases {
            let card = FoilCard(level: level, top: DexTier.glorious.color, bottom: RGB(hex: 0x1E2F8F), seed: SolDex.seed("abyssalhunter"))
            let image = try XCTUnwrap(renderer.image(card, size: CGSize(width: 110, height: 150), scale: 1), level.name)
            let l = luminance(image)
            if level >= .satin { XCTAssertGreaterThan(l, previous * 0.95, "\(level.name) should not be duller than the level below") }
            previous = l
        }
    }

    func testAnUnseenCardIsADarkSilhouette() throws {
        guard let renderer = FoilRenderer() else { throw XCTSkip("no Metal device on this machine") }
        let seen = FoilCard(level: .holographic, top: DexTier.legendary.color, bottom: DexTier.legendary.color, seed: 7)
        var unseen = seen; unseen.seen = false
        let a = try XCTUnwrap(renderer.image(seen, size: CGSize(width: 110, height: 150), scale: 1))
        let b = try XCTUnwrap(renderer.image(unseen, size: CGSize(width: 110, height: 150), scale: 1))
        XCTAssertLessThan(luminance(b), 0.12)
        XCTAssertLessThan(luminance(b), luminance(a) * 0.6)
    }

    /// Reduce Motion: a still card face must not depend on the clock.
    func testAStillCardDoesNotMove() throws {
        guard let renderer = FoilRenderer() else { throw XCTSkip("no Metal device on this machine") }
        let card = FoilCard(level: .prismatic, top: DexTier.glorious.color, bottom: DexTier.glorious.color, seed: 99, animated: false)
        let a = try XCTUnwrap(renderer.image(card, time: 1, size: CGSize(width: 80, height: 110), scale: 1))
        let b = try XCTUnwrap(renderer.image(card, time: 55, size: CGSize(width: 80, height: 110), scale: 1))
        XCTAssertEqual(a.dataProvider?.data as Data?, b.dataProvider?.data as Data?)
    }

    func testEveryAuraGetsItsOwnEmblem() throws {
        guard let renderer = FoilRenderer() else { throw XCTSkip("no Metal device on this machine") }
        func face(_ id: String) throws -> Data? {
            let card = FoilCard(level: .matte, top: DexTier.basic.color, bottom: DexTier.basic.color, seed: SolDex.seed(id))
            return try XCTUnwrap(renderer.image(card, size: CGSize(width: 80, height: 110), scale: 1)).dataProvider?.data as Data?
        }
        XCTAssertNotEqual(try face("starlight"), try face("symphony"))
        XCTAssertEqual(try face("starlight"), try face("starlight"))
    }
}

final class WrappedCardTests: XCTestCase {
    func testCardIsDrawnWithAndWithoutMetal() throws {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let catalog = try BiomeCatalog.bundled(), auras = AuraCatalog.bundled()
        let events = DemoDay.events(endingAt: end, hours: 6)
        let wrap = SessionWrap.build(events: events, start: end.addingTimeInterval(-6 * 3600), end: end, isRare: { catalog.isRare($0) },
                                     chance: { auras.chance(for: $0) }, auraName: { auras.info(for: $0)?.display ?? $0 }, macroRuns: 4)
        XCTAssertEqual(wrap.rares, ["GLITCHED"])
        // Without Metal the card still comes out (plain sky, plain card).
        let plain = try XCTUnwrap(WrappedCard.render(wrap, catalog: catalog, auras: auras, sky: nil, foil: nil))
        XCTAssertEqual(plain.width, 1080); XCTAssertEqual(plain.height, 1350)
        let png = try XCTUnwrap(WrappedCard.png(plain))
        XCTAssertGreaterThan(png.count, 50_000)
        if let sky = SkyRenderer(), let foil = FoilRenderer() {
            let full = try XCTUnwrap(WrappedCard.render(wrap, catalog: catalog, auras: auras, sky: sky, foil: foil))
            XCTAssertEqual(full.width, 1080)
        }
        // A session with nothing in it is still a card.
        let empty = SessionWrap.build(events: [], start: end.addingTimeInterval(-600), end: end, isRare: { _ in false }, chance: { _ in nil })
        XCTAssertNotNil(WrappedCard.render(empty, catalog: catalog, auras: auras, sky: nil, foil: nil))
    }
}
