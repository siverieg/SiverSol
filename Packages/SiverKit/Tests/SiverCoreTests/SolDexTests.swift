import XCTest
@testable import SiverCore

final class SolDexTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let catalog = AuraCatalog.bundled()

    func testTierMappingUsesTheGamesOwnNames() {
        XCTAssertEqual(DexTier(catalog: "Basic"), .basic)
        XCTAssertEqual(DexTier(catalog: "Glorious"), .glorious)
        XCTAssertEqual(DexTier(catalog: "Transcendent"), .transcendent)
        XCTAssertEqual(DexTier(catalog: "Dimensional"), .dimensional)
        XCTAssertEqual(DexTier(catalog: "Challenged+"), .challenged, "Challenged+ is shown with Challenged")
        XCTAssertEqual(DexTier(catalog: "Event"), .event)
        XCTAssertEqual(DexTier(catalog: "Unobtainable"), .unobtainable)
        XCTAssertEqual(DexTier(catalog: nil), .unknown)
        XCTAssertEqual(DexTier(catalog: "Something New"), .unknown)
        XCTAssertEqual(DexTier.allCases.prefix(9).map(\.rawValue),
                       ["Basic", "Epic", "Unique", "Legendary", "Mythic", "Exalted", "Glorious", "Transcendent", "Dimensional"])
        XCTAssertLessThan(DexTier.basic, .glorious)
        XCTAssertFalse(DexTier.unobtainable.collectable)
    }

    func testEveryCatalogTierIsKnown() {
        let unknown = catalog.entries.filter { DexTier(catalog: $0.info.tier) == .unknown }.map { "\($0.info.display): \($0.info.tier ?? "nil")" }
        XCTAssertEqual(unknown, [], "a tier name in auras.json that the Sol Dex does not know")
    }

    func testFoilClimbsWithTheTier() {
        XCTAssertEqual(FoilLevel.of(tier: .basic, chance: 2), .matte)
        XCTAssertEqual(FoilLevel.of(tier: .epic, chance: 1000), .satin)
        XCTAssertEqual(FoilLevel.of(tier: .unique, chance: 50_000), .shimmer)
        XCTAssertEqual(FoilLevel.of(tier: .legendary, chance: 200_000), .holographic)
        XCTAssertEqual(FoilLevel.of(tier: .exalted, chance: 30_000_000), .glitter)
        for tier in [DexTier.glorious, .transcendent, .dimensional] {
            XCTAssertEqual(FoilLevel.of(tier: tier, chance: nil), .prismatic, "Glorious and up get the animated prismatic foil")
        }
        let ladder = [DexTier.basic, .epic, .unique, .legendary, .mythic, .exalted, .glorious, .transcendent, .dimensional].map { FoilLevel.of(tier: $0, chance: nil) }
        XCTAssertEqual(ladder, ladder.sorted(), "foil never gets plainer as the tier goes up")
        // Event auras follow their odds.
        XCTAssertEqual(FoilLevel.of(tier: .event, chance: 5_000), .matte)
        XCTAssertEqual(FoilLevel.of(tier: .event, chance: 120_000_000), .prismatic)
    }

    func testCollectionFromEvents() throws {
        let rainy = BiomeRef(raw: "RAINY")
        let events: [SiverEvent] = [
            .auraEquipped(AuraEquipped(id: "a", internalName: "Starlight", at: t0, biome: nil, biomeEventId: nil, initial: true, serverJobId: nil)),
            .auraRolled(AuraRolled(id: "b", name: "Abyssal Hunter", at: t0.addingTimeInterval(100), biome: rainy)),
            .auraEquipped(AuraEquipped(id: "c", internalName: "AbyssalHunter", at: t0.addingTimeInterval(140), biome: rainy, biomeEventId: nil, initial: false, serverJobId: nil)),
            .auraEquipped(AuraEquipped(id: "d", internalName: "Starlight", at: t0.addingTimeInterval(900), biome: BiomeRef(raw: "STARFALL"), biomeEventId: nil, initial: false, serverJobId: nil)),
            .auraEquipped(AuraEquipped(id: "e", internalName: "TotallyNewAura", at: t0.addingTimeInterval(950), biome: nil, biomeEventId: nil, initial: false, serverJobId: nil)),
        ]
        let dex = SolDex.build(catalog: catalog, events: events)
        XCTAssertEqual(dex.cards.count, catalog.count + 1, "every catalog aura has a card, and so does one the catalog does not know")

        let hunter = try XCTUnwrap(dex.cards.first { $0.display == "Abyssal Hunter" })
        XCTAssertTrue(hunter.seen)
        XCTAssertEqual(hunter.count, 1, "the equip line after a roll is the same aura, not a second one")
        XCTAssertEqual(hunter.biome, "RAINY")
        XCTAssertEqual(hunter.tier, .glorious)
        XCTAssertEqual(hunter.foil, .prismatic)
        XCTAssertEqual(hunter.odds, "1 in 400,000,000")
        XCTAssertEqual(hunter.firstSeen, t0.addingTimeInterval(100))

        let star = try XCTUnwrap(dex.cards.first { $0.display == "Starlight" })
        XCTAssertEqual(star.count, 2, "owned on join, then equipped again later")
        XCTAssertEqual(star.firstSeen, t0)

        let new = try XCTUnwrap(dex.cards.first { $0.id == "totallynewaura" })
        XCTAssertEqual(new.tier, .unknown)
        XCTAssertEqual(new.display, "Totally New Aura")

        XCTAssertEqual(dex.rarest?.display, "Abyssal Hunter")
        XCTAssertEqual(dex.collected, 2, "the unknown aura is shown but not counted")
        XCTAssertEqual(dex.completion, 2 / Double(dex.collectable.count), accuracy: 0.0001)
        XCTAssertFalse(dex.cards.first { $0.display == "Symphony" }?.seen ?? true, "an aura not yet seen stays a silhouette")
    }

    func testSeedIsStable() {
        XCTAssertEqual(SolDex.seed("starlight"), SolDex.seed("starlight"))
        XCTAssertNotEqual(SolDex.seed("starlight"), SolDex.seed("symphony"))
    }
}
