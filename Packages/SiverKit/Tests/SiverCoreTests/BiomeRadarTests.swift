import XCTest
@testable import SiverCore

final class BiomeRadarTests: XCTestCase {
    let logA = "0.745.100.7450979_20261118T100000Z_Player_aaaaa_last.log"
    let logB = "0.745.100.7450979_20261118T110000Z_Player_bbbbb_last.log"

    func testStartupScanReportsOnlyTheBiomeInProgress() {
        let logs = TempLogs()
        logs.write(logA, [joinLine("2026-11-18T10:00:00.000Z"), rpc("2026-11-18T10:00:10.000Z", "NORMAL"),
                          rpc("2026-11-18T10:05:00.000Z", "WINDY"), rpc("2026-11-18T10:07:00.000Z", "NORMAL"),
                          rpc("2026-11-18T10:09:00.000Z", "STARFALL")].joined(separator: "\n") + "\n")
        let radar = BiomeRadar(logsDirectory: logs.dir, catalog: testCatalog())
        let first = radar.step()
        XCTAssertEqual(first.count, 1)
        let started = first.starts[0]
        XCTAssertEqual(started.biome.key, "STARFALL")
        XCTAssertTrue(started.wasRunning)
        XCTAssertTrue(started.observedStart)
        XCTAssertEqual(started.at, date("2026-11-18T10:09:00.000Z"), "the real start time, not the scan time")
        XCTAssertTrue(radar.step().isEmpty, "emitted once")
        XCTAssertEqual(radar.snapshot.current?.biome.key, "STARFALL")
        XCTAssertEqual(radar.snapshot.equippedAura, "Enchanted")
    }

    func testLiveAppendsIncludingAPartialLine() {
        let logs = TempLogs()
        logs.write(logA, joinLine("2026-11-18T10:00:00.000Z") + "\n" + rpc("2026-11-18T10:00:10.000Z", "NORMAL") + "\n")
        let radar = BiomeRadar(logsDirectory: logs.dir, catalog: testCatalog())
        _ = radar.step()
        let line = rpc("2026-11-18T10:05:00.000Z", "RAINY") + "\n"
        let cut = line.index(line.startIndex, offsetBy: 90)
        logs.append(logA, String(line[..<cut]))
        XCTAssertTrue(radar.step().isEmpty, "half a line is not an event")
        logs.append(logA, String(line[cut...]))
        let events = radar.step()
        XCTAssertEqual(events.ends.map(\.biome.key.value), ["NORMAL"])
        XCTAssertEqual(events.startKeys, ["RAINY"])
        XCTAssertFalse(events.starts[0].wasRunning)
        // The same id the startup scan would produce, so a restart cannot double-send.
        let again = BiomeRadar(logsDirectory: logs.dir, catalog: testCatalog()).step()
        XCTAssertEqual(again.starts.first?.id, events.starts[0].id)
    }

    func testNewLogFileEndsSessionAndStartsLive() {
        let logs = TempLogs()
        logs.write(logA, joinLine("2026-11-18T10:00:00.000Z") + "\n" + rpc("2026-11-18T10:00:10.000Z", "GLITCHED") + "\n")
        let radar = BiomeRadar(logsDirectory: logs.dir, catalog: testCatalog())
        XCTAssertEqual(radar.step().startKeys, ["GLITCHED"])
        // A late line lands in the old log, then Roblox relaunches into a new one.
        logs.append(logA, rpc("2026-11-18T10:01:00.000Z", "GLITCHED", state: "Equipped \\\"Oblivion\\\"") + "\n")
        logs.write(logB, joinLine("2026-11-18T11:00:01.000Z", job: "00000000-0000-4000-8000-000000000002") + "\n"
                   + rpc("2026-11-18T11:00:03.000Z", "NORMAL", state: "In Main Menu") + "\n")
        let events = radar.step()
        XCTAssertEqual(events.auras.map(\.internalName), ["Oblivion"], "old log is drained before switching")
        XCTAssertEqual(events.ends.map(\.reason), [.sessionEnded])
        XCTAssertEqual(events.ends[0].at, date("2026-11-18T11:00:00.000Z"), "last seen = when Roblox relaunched (the new log's stamp)")
        XCTAssertEqual(events.ends[0].duration, 3590, accuracy: 0.01)
        XCTAssertTrue(events.starts.isEmpty, "still in the menu")
        XCTAssertEqual(radar.snapshot.sessionId, "20261118T110000Z_bbbbb")
        XCTAssertEqual(radar.snapshot.phase, .menu)

        logs.append(logB, rpc("2026-11-18T11:00:20.000Z", "SNOWY") + "\n")
        let next = radar.step()
        XCTAssertEqual(next.startKeys, ["SNOWY"])
        XCTAssertFalse(next.starts[0].wasRunning, "a log that appears while we are running is live, not a startup scan")
    }

    func testRobloxStartedAfterSiverSol() {
        let logs = TempLogs()
        let radar = BiomeRadar(logsDirectory: logs.dir, catalog: testCatalog())
        XCTAssertTrue(radar.step().isEmpty)
        logs.write(logA, joinLine("2026-11-18T10:00:00.000Z") + "\n" + rpc("2026-11-18T10:00:10.000Z", "HELL") + "\n")
        let events = radar.step()
        XCTAssertEqual(events.startKeys, ["HELL"])
        XCTAssertFalse(events.starts[0].wasRunning)
    }

    func testUnknownBiomeIsLearnedOnceAndKeepsWorking() throws {
        let logs = TempLogs()
        let learnedURL = logs.dir.appendingPathComponent("support/learned_biomes.json")
        let catalog = testCatalog(learnedURL: learnedURL)
        logs.write(logA, joinLine("2026-11-18T10:00:00.000Z") + "\n" + rpc("2026-11-18T10:00:10.000Z", "NORMAL") + "\n")
        let radar = BiomeRadar(logsDirectory: logs.dir, catalog: catalog)
        _ = radar.step()
        logs.append(logA, rpc("2026-11-18T10:05:00.000Z", "GargantuaBiome") + "\n")
        let events = radar.step()
        XCTAssertEqual(events.newBiomes.map(\.biome.raw), ["GargantuaBiome"])
        XCTAssertEqual(events.startKeys, ["GARGANTUABIOME"])
        logs.append(logA, rpc("2026-11-18T10:07:00.000Z", "NORMAL") + "\n" + rpc("2026-11-18T10:09:00.000Z", "gargantuabiome") + "\n")
        let later = radar.step()
        XCTAssertTrue(later.newBiomes.isEmpty, "announced only the first time")
        XCTAssertEqual(later.startKeys, ["NORMAL", "GARGANTUABIOME"])
        // Persisted, so a restart does not announce it again.
        let reloaded = testCatalog(learnedURL: learnedURL)
        XCTAssertTrue(reloaded.isKnown("GARGANTUABIOME"))
        XCTAssertEqual(reloaded.info(for: "GARGANTUABIOME").category, .unknown)
        XCTAssertEqual(reloaded.info(for: "GARGANTUABIOME").assetId, 42)
    }

    func testEventStreamDeliversLiveEvents() async {
        let logs = TempLogs()
        logs.write(logA, joinLine("2026-11-18T10:00:00.000Z") + "\n" + rpc("2026-11-18T10:00:10.000Z", "NORMAL") + "\n")
        let radar = BiomeRadar(logsDirectory: logs.dir, catalog: testCatalog())
        let stream = radar.events(pollInterval: 0.05)
        let writer = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            logs.append(self.logA, rpc("2026-11-18T10:05:00.000Z", "CORRUPTION") + "\n")
        }
        var keys: [String] = []
        for await e in stream {
            if case .biomeStarted(let s) = e { keys.append(s.biome.key.value) }
            if keys.count == 2 { break }
        }
        await writer.value
        radar.stop()
        XCTAssertEqual(keys, ["NORMAL", "CORRUPTION"])
    }
}

final class BiomeCatalogTests: XCTestCase {
    func testBundledCatalog() {
        let c = testCatalog()
        for rare in ["GLITCHED", "DREAMSPACE", "CYBERSPACE", "SINGULARITY"] { XCTAssertTrue(c.isRare(BiomeKey(rare)), rare) }
        XCTAssertFalse(c.isRare("WINDY"))
        XCTAssertFalse(c.isRare("PUMPKIN MOON"))
        XCTAssertEqual(c.info(for: "GLITCHED").colorValue, 6619088, "the color in SPEC F3's example")
        XCTAssertEqual(c.info(for: BiomeKey("sand  storm")).durationS, 650)
        XCTAssertNil(c.info(for: "NORMAL").durationS)
        // Every biome seen on the test Mac on 2026-11-18 is in the catalog.
        for seen in ["NORMAL", "WINDY", "RAINY", "SNOWY", "STARFALL", "HEAVEN", "PUMPKIN MOON"] { XCTAssertTrue(c.isKnown(BiomeKey(seen)), seen) }
        XCTAssertEqual(Set(c.all.map(\.key)).count, c.all.count, "no duplicate keys")
    }

    func testUnknownBiomeGetsAPlaceholder() {
        let info = testCatalog().info(for: "SOMETHING NEW")
        XCTAssertEqual(info.category, .unknown)
        XCTAssertEqual(info.emoji, "🆕")
        XCTAssertFalse(info.isRare)
    }
}

final class AuraCatalogTests: XCTestCase {
    let auras = AuraCatalog.bundled()

    func testInternalNamesFromARealLogResolve() {
        XCTAssertGreaterThan(auras.count, 400)
        // The three internal names seen in the real log on 2026-11-18.
        XCTAssertEqual(auras.display(for: "SeekerOfTheCrimsonMoon"), "Seeker of the Crimson Moon")
        XCTAssertEqual(auras.display(for: "Enchanted"), "Enchanted")
        XCTAssertEqual(auras.display(for: ":Flushed:_Pumpkinity"), "Flushed : Pumpkinity")
        XCTAssertEqual(auras.rarityText(for: ":Flushed:_Pumpkinity"), "1 in 69,000 · Event")
        XCTAssertEqual(auras.rarityText(for: "Enchanted"), "1 in 445,000 · Event")
        XCTAssertEqual(auras.chance(for: "SeekerOfTheCrimsonMoon"), 666_666)
    }

    func testUnknownAuraFallsBackToSplitWords() {
        XCTAssertNil(auras.info(for: "TotallyNewAura2027"))
        XCTAssertEqual(auras.display(for: "TotallyNewAura2027"), "Totally New Aura 2027")
        XCTAssertEqual(auras.rarityText(for: "TotallyNewAura2027"), "unknown")
    }

    func testNativeBiomeBoost() {
        XCTAssertEqual(auras.nativeBoost(for: "Wind", in: "WINDY"), "native biome: 1 in 300 here")
        XCTAssertNil(auras.nativeBoost(for: "Wind", in: "RAINY"))
        XCTAssertNil(auras.nativeBoost(for: "Wind", in: nil))
        // The wiki writes SANDSTORM, the game writes SAND STORM.
        XCTAssertNotNil(auras.nativeBoost(for: "Gilded", in: "SAND STORM"))
    }
}
