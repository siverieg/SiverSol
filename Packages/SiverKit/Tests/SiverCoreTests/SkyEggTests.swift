import XCTest
@testable import SiverCore

/// Rare sky surprises: the dice, the rules about when they may be rolled, and what is remembered.
final class SkyEggTests: XCTestCase {
    func defaults() -> (UserDefaults, String) {
        let name = "siversol-eggs-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    let seeing = EggConditions(windowVisible: true, islandVisible: true)

    func testTheSameSeedGivesTheSameLuck() {
        var a = EggRoller(generator: SeededGenerator(seed: 42)), b = EggRoller(generator: SeededGenerator(seed: 42))
        let first = (0..<5000).map { _ in a.hit(oneIn: 40) }, second = (0..<5000).map { _ in b.hit(oneIn: 40) }
        XCTAssertEqual(first, second)
        var c = EggRoller(generator: SeededGenerator(seed: 43))
        XCTAssertNotEqual(first, (0..<5000).map { _ in c.hit(oneIn: 40) })
    }

    func testTheOddsAreWhatTheySay() {
        // Over many rolls a 1-in-N surprise comes up about once in N.
        for (oneIn, rolls) in [(40, 400_000), (200, 1_000_000), (1_500, 3_000_000)] {
            var r = EggRoller(generator: SeededGenerator(seed: 7))
            var hits = 0
            for _ in 0..<rolls where r.hit(oneIn: oneIn) { hits += 1 }
            let expected = Double(rolls) / Double(oneIn)
            XCTAssertEqual(Double(hits), expected, accuracy: expected * 0.08, "1 in \(oneIn)")
        }
        var r = EggRoller(generator: SeededGenerator(seed: 1))
        XCTAssertFalse(r.hit(oneIn: 0))
        XCTAssertEqual(SkyEgg.allCases.map(\.oneIn), [90, 8, 300, 250, 600, 600, 50, 3_000], "star, rainbow, aurora, Glimmer, retro, golden sun, comet, twin moons")
    }

    func testEachSurpriseIsRolledAtItsOwnMoment() {
        XCTAssertEqual(SkyEgg.shootingStar.moment, .presentMinute)
        XCTAssertEqual(SkyEgg.doubleRainbow.moment, .rainyEnded)
        XCTAssertEqual(SkyEgg.auroraNight.moment, .nightMinute); XCTAssertEqual(SkyEgg.twinMoons.moment, .nightMinute)
        XCTAssertEqual(SkyEgg.glimmer.moment, .biomeChange); XCTAssertEqual(SkyEgg.retroFrame.moment, .biomeChange)
        XCTAssertEqual(SkyEgg.goldenSun.moment, .eveningMinute)
        XCTAssertEqual(SkyEgg.islandComet.moment, .islandExpanded)
        // Rolling one moment can only ever give that moment's surprises.
        var r = EggRoller(generator: SeededGenerator(seed: 3))
        for _ in 0..<50_000 {
            for egg in r.roll(.rainyEnded, conditions: seeing) { XCTAssertEqual(egg, .doubleRainbow) }
            for egg in r.roll(.nightMinute, conditions: seeing) { XCTAssertTrue([.auroraNight, .twinMoons].contains(egg)) }
        }
        // A surprise that is already playing is not rolled again while it plays, and no number is drawn for it.
        var busy = EggRoller(generator: SeededGenerator(seed: 4)), same = SeededGenerator(seed: 4)
        for _ in 0..<2000 { XCTAssertTrue(busy.roll(.presentMinute, conditions: seeing, skipping: [.shootingStar]).isEmpty) }
        XCTAssertEqual(busy.generator.next(), same.next())
    }

    func testNoHiddenRolls() {
        // Nobody could see the sky: nothing is rolled, and not even a number is drawn.
        var hidden = EggRoller(generator: SeededGenerator(seed: 9)), untouched = SeededGenerator(seed: 9)
        for _ in 0..<1000 { XCTAssertTrue(hidden.roll(.biomeChange, conditions: EggConditions(windowVisible: false, islandVisible: true)).isEmpty) }
        XCTAssertEqual(hidden.generator.next(), untouched.next(), "the generator was never asked")
        // The island's surprise needs the island; the sky's surprises need the window.
        XCTAssertTrue(EggConditions(windowVisible: false, islandVisible: true).allows(.islandComet))
        XCTAssertFalse(EggConditions(windowVisible: true, islandVisible: false).allows(.islandComet))
        XCTAssertTrue(EggConditions(windowVisible: true, islandVisible: false).allows(.shootingStar))
        XCTAssertFalse(EggConditions(windowVisible: false, islandVisible: true).allows(.shootingStar))
    }

    func testSkippedDuringRareBiomesAndMacrosAndNotKeptForLater() {
        for blocked in [EggConditions(windowVisible: true, islandVisible: true, rareBiome: true), EggConditions(windowVisible: true, islandVisible: true, macroBusy: true),
                        EggConditions(enabled: false, windowVisible: true, islandVisible: true),
                        EggConditions(windowVisible: true, islandVisible: true, awakeAndUsed: false)] {
            for egg in SkyEgg.allCases { XCTAssertFalse(blocked.allows(egg)) }
            var r = EggRoller(generator: SeededGenerator(seed: 5)), same = SeededGenerator(seed: 5)
            for moment in [EggMoment.presentMinute, .nightMinute, .eveningMinute, .rainyEnded, .biomeChange, .islandExpanded] {
                for _ in 0..<500 { XCTAssertTrue(r.roll(moment, conditions: blocked).isEmpty) }
            }
            // Skipped, not queued: afterwards the dice are exactly where they were.
            XCTAssertEqual(r.generator.next(), same.next())
        }
    }

    func testOnlyWhileSomeoneIsPresent() {
        // Present: something of SiverSol's on screen, the display awake, the Mac used in the last ten minutes.
        XCTAssertTrue(EggPresence.isPresent(windowVisible: true, islandVisible: false, displayAsleep: false, idleSeconds: 30))
        XCTAssertTrue(EggPresence.isPresent(windowVisible: false, islandVisible: true, displayAsleep: false, idleSeconds: 599))
        XCTAssertFalse(EggPresence.isPresent(windowVisible: false, islandVisible: false, displayAsleep: false, idleSeconds: 5), "nothing on screen")
        XCTAssertFalse(EggPresence.isPresent(windowVisible: true, islandVisible: true, displayAsleep: true, idleSeconds: 5), "the display is asleep")
        XCTAssertFalse(EggPresence.isPresent(windowVisible: true, islandVisible: true, displayAsleep: false, idleSeconds: 600), "nobody touched the Mac for ten minutes")
        XCTAssertFalse(EggPresence.isPresent(windowVisible: true, islandVisible: true, displayAsleep: false, idleSeconds: 86_400))
        XCTAssertEqual(EggPresence.idleLimit, 600)
        XCTAssertTrue(EggConditions(windowVisible: false, islandVisible: true).present)
        XCTAssertFalse(EggConditions(windowVisible: true, islandVisible: true, awakeAndUsed: false).present)
        XCTAssertFalse(EggConditions(windowVisible: false, islandVisible: false).present)
    }

    func testAPresentMinuteIsOneRollAndAbsentTimeDoesNotCount() {
        var clock = EggClock()
        XCTAssertEqual(clock.advance(by: 20, present: true, hour: 14), [])
        XCTAssertEqual(clock.advance(by: 20, present: true, hour: 14), [], "40 seconds: not yet")
        XCTAssertEqual(clock.advance(by: 20, present: true, hour: 14), [.presentMinute], "the minute is up: one roll")
        // Time with nobody present does not count, however much of it there is.
        var idle = EggClock()
        for _ in 0..<5000 { XCTAssertEqual(idle.advance(by: 20, present: false, hour: 14), []) }
        XCTAssertEqual(idle.presentSeconds, 0)
        XCTAssertEqual(idle.advance(by: 60, present: true, hour: 14), [.presentMinute], "and it does not pile up to be paid out later")
        // A night minute (10 PM to 5 AM) is also a night roll; an evening minute (5 PM to 9 PM) an evening roll.
        var night = EggClock()
        XCTAssertEqual(night.advance(by: 60, present: true, hour: 23), [.presentMinute, .nightMinute])
        XCTAssertEqual(night.advance(by: 60, present: true, hour: 3), [.presentMinute, .nightMinute])
        XCTAssertEqual(night.advance(by: 60, present: true, hour: 18), [.presentMinute, .eveningMinute])
        XCTAssertEqual(night.advance(by: 60, present: true, hour: 21), [.presentMinute], "9 PM is neither")
        // A long gap between two looks at the clock is still one roll per minute.
        var late = EggClock()
        XCTAssertEqual(late.advance(by: 120, present: true, hour: 14), [.presentMinute, .presentMinute])
        XCTAssertTrue(EggClock.isNight(hour: 22)); XCTAssertTrue(EggClock.isNight(hour: 4)); XCTAssertFalse(EggClock.isNight(hour: 5)); XCTAssertFalse(EggClock.isNight(hour: 21))
        XCTAssertTrue(EggClock.isEvening(hour: 17)); XCTAssertTrue(EggClock.isEvening(hour: 20)); XCTAssertFalse(EggClock.isEvening(hour: 21)); XCTAssertFalse(EggClock.isEvening(hour: 16))
    }

    /// How long it takes to find each surprise, with the real clock and the real dice (seeded): on average,
    /// as many of its moments as its odds say. A shooting star about every 90 present minutes, and so on.
    func testTheExpectedTimeToFindEachSurpriseMatchesItsOdds() {
        for egg in SkyEgg.allCases {
            let trials = 400
            var roller = EggRoller(generator: SeededGenerator(seed: UInt64(1000 + (SkyEgg.allCases.firstIndex(of: egg) ?? 0))))
            var total = 0
            for _ in 0..<trials {
                var clock = EggClock()
                var count = 0
                search: while true {
                    // One of its moments comes: a present minute at the right time of day, or one event seen.
                    var moments: [EggMoment]
                    switch egg.moment {
                    case .presentMinute: moments = clock.advance(by: 60, present: true, hour: 14)
                    case .nightMinute: moments = clock.advance(by: 60, present: true, hour: 23)
                    case .eveningMinute: moments = clock.advance(by: 60, present: true, hour: 18)
                    case .rainyEnded, .biomeChange, .islandExpanded: moments = [egg.moment]
                    }
                    count += 1
                    for moment in moments where roller.roll(moment, conditions: seeing).contains(egg) { break search }
                    if count > egg.oneIn * 60 { XCTFail("\(egg) never came up"); break }
                }
                total += count
            }
            let mean = Double(total) / Double(trials)
            // The mean of 400 tries is within about 5% of the true figure one time in three; 15% leaves room.
            XCTAssertEqual(mean, Double(egg.oneIn), accuracy: Double(egg.oneIn) * 0.15, "\(egg.name): expected about \(egg.oneIn) of its moments, took \(mean)")
        }
        // In plain time: a shooting star about every hour and a half at the Mac, twin moons about every 50 night hours.
        XCTAssertEqual(Double(SkyEgg.shootingStar.oneIn) / 60, 1.5)
        XCTAssertEqual(Double(SkyEgg.auroraNight.oneIn) / 60, 5)
        XCTAssertEqual(Double(SkyEgg.goldenSun.oneIn) / 60, 10)
        XCTAssertEqual(Double(SkyEgg.twinMoons.oneIn) / 60, 50)
    }

    func testFoundSurprisesPersistAcrossLaunches() {
        let (d, name) = defaults()
        defer { d.removePersistentDomain(forName: name) }
        let when = Date(timeIntervalSince1970: 1_795_000_000)
        XCTAssertTrue(EggStore(defaults: d).record(.shootingStar, at: when))
        XCTAssertFalse(EggStore(defaults: d).record(.shootingStar, at: when.addingTimeInterval(999)), "the first sighting is the one that counts")
        // A new launch: a new store over the same preferences.
        let later = EggStore(defaults: UserDefaults(suiteName: name)!)
        XCTAssertEqual(later.found, [.shootingStar: when])
        XCTAssertEqual(later.foundCount, 1)
        XCTAssertFalse(later.hunter)
        for egg in SkyEgg.allCases { later.record(egg, at: when.addingTimeInterval(60)) }
        XCTAssertTrue(EggStore(defaults: d).hunter, "all eight: Egg Hunter")
        XCTAssertEqual(EggStore(defaults: d).hunterSince, when.addingTimeInterval(60))
    }

    func testOnByDefaultAndTheSwitchSticks() {
        let (d, name) = defaults()
        defer { d.removePersistentDomain(forName: name) }
        XCTAssertTrue(EggStore(defaults: d).enabled)
        EggStore(defaults: d).enabled = false
        XCTAssertFalse(EggStore(defaults: UserDefaults(suiteName: name)!).enabled)
    }

    func testTheSecretsListGivesNothingAwayUntilFound() {
        let when = Date(timeIntervalSince1970: 1_795_000_000)
        let rows = EggRow.rows(found: [.doubleRainbow: when])
        XCTAssertEqual(rows.count, 8)
        XCTAssertEqual(rows.filter { $0.foundAt != nil }.map(\.name), ["Double rainbow"])
        XCTAssertEqual(rows.first { $0.foundAt != nil }?.odds, "1 in 8 per Rainy ending seen")
        for row in rows where row.foundAt == nil {
            XCTAssertEqual(row.name, "???"); XCTAssertEqual(row.odds, "1 in ?"); XCTAssertEqual(row.symbol, "questionmark")
        }
        XCTAssertEqual(EggRow.summary(found: 2), "Found 2 of 8")
        XCTAssertEqual(EggRow.disclaimer, "Just for fun · doesn't change your in-game luck")
        XCTAssertEqual(EggRow.cardLabel, "Sky surprise · not a real aura")
        XCTAssertEqual(SkyEgg.twinMoons.odds, "1 in 3,000 per minute at the Mac, 10 PM to 5 AM")
        XCTAssertEqual(SkyEgg.shootingStar.odds, "1 in 90 per minute at the Mac")
        XCTAssertEqual(SkyEgg.auroraNight.odds, "1 in 300 per minute at the Mac, 10 PM to 5 AM")
        XCTAssertEqual(SkyEgg.goldenSun.odds, "1 in 600 per minute at the Mac in the evening")
        XCTAssertEqual(SkyEgg.glimmer.odds, "1 in 250 per biome change seen")
        XCTAssertEqual(SkyEgg.retroFrame.odds, "1 in 600 per biome change seen")
        XCTAssertEqual(SkyEgg.islandComet.odds, "1 in 50 each time the island opens")
        // Nothing claims to affect the game.
        for egg in SkyEgg.allCases { XCTAssertFalse(egg.odds.lowercased().contains("luck")); XCTAssertFalse(egg.name.lowercased().contains("luck")) }
    }

    func testSeasonalDates() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date { cal.date(from: DateComponents(year: 2027, month: m, day: d, hour: h, minute: min))! }
        XCTAssertEqual(SeasonalEgg.active(at: at(10, 31), calendar: cal), [.halloweenBats])
        XCTAssertEqual(SeasonalEgg.active(at: at(10, 25), calendar: cal), [.halloweenBats], "the week before")
        XCTAssertEqual(SeasonalEgg.active(at: at(10, 24), calendar: cal), [])
        XCTAssertEqual(SeasonalEgg.active(at: at(11, 1), calendar: cal), [])
        XCTAssertEqual(SeasonalEgg.active(at: at(1, 1, 0, 0), calendar: cal), [.newYearFireworks], "local midnight")
        XCTAssertEqual(SeasonalEgg.active(at: at(1, 1, 0, 6), calendar: cal), [])
        XCTAssertEqual(SeasonalEgg.active(at: at(12, 31, 23, 59), calendar: cal), [], "not before the stroke")
        XCTAssertEqual(SeasonalEgg.active(at: at(4, 1), calendar: cal), [.aprilFirst])
        XCTAssertEqual(SeasonalEgg.sidebarLine("Watching · Normal", on: at(4, 1), calendar: cal), "Watching · Normal (probably)")
        XCTAssertEqual(SeasonalEgg.sidebarLine("Watching · Normal", on: at(4, 2), calendar: cal), "Watching · Normal")
        XCTAssertEqual(SeasonalEgg.sidebarLine("Paused", on: at(4, 1), calendar: cal), "Paused", "only the watching line")
    }

    func testWhatTheSkyShowsFadesInAndOut() {
        let t = Date(timeIntervalSince1970: 1_795_000_000)
        var board = EggBoard()
        XCTAssertTrue(board.isIdle)
        XCTAssertTrue(board.sky(at: t).isNone, "nothing playing: exactly the ordinary sky")
        board.start(.doubleRainbow, at: t)
        XCTAssertEqual(board.sky(at: t).rainbow, 0, "it fades in")
        XCTAssertEqual(board.sky(at: t.addingTimeInterval(10)).rainbow, 1)
        XCTAssertEqual(board.sky(at: t.addingTimeInterval(19)).rainbow, 0.5, accuracy: 0.001, "and out, over its last two seconds")
        XCTAssertFalse(board.isShowing(.doubleRainbow, at: t.addingTimeInterval(21)), "20 seconds")
        XCTAssertTrue(board.tidy(now: t.addingTimeInterval(21)))
        XCTAssertTrue(board.isIdle)
        // The shooting star crosses once; the calm version stays where it is and only fades.
        board.start(.shootingStar, at: t)
        XCTAssertEqual(board.sky(at: t.addingTimeInterval(0.9)).star ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(board.sky(at: t.addingTimeInterval(0.2), motion: false).star, 0.5)
        XCTAssertNil(board.sky(at: t.addingTimeInterval(2)).star)
        // The golden sun and the twin moons stay until they are told to go.
        board.start(.goldenSun, at: t); board.start(.twinMoons, at: t)
        XCTAssertEqual(board.sky(at: t.addingTimeInterval(3600)).gold, 1)
        board.stop(.goldenSun)
        XCTAssertEqual(board.sky(at: t.addingTimeInterval(3600)).gold, 0)
        XCTAssertEqual(board.sky(at: t.addingTimeInterval(3600)).twinMoon, 1)
        XCTAssertEqual(SkyEgg.auroraNight.seconds, 60); XCTAssertEqual(SkyEgg.retroFrame.seconds, 15); XCTAssertEqual(SkyEgg.doubleRainbow.seconds, 20)
    }

    func testGlimmerIsCalmAndKnowsNothingAboutYou() {
        XCTAssertEqual(Glimmer.lines.count, 15)
        XCTAssertEqual(Set(Glimmer.lines).count, 15)
        for line in Glimmer.lines {
            let words = line.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init)
            XCTAssertFalse(words.contains("you") || words.contains("your") || words.contains("you're"), "never about the person looking: \(line)")
            XCTAssertFalse(line.contains("!"), line)
            XCTAssertLessThanOrEqual(line.count, 30, line)
            XCTAssertFalse(words.contains("luck") || words.contains("lucky") || words.contains("roll"), "never about the game: \(line)")
        }
        var g = SeededGenerator(seed: 11)
        XCTAssertTrue(Glimmer.lines.contains(Glimmer.line(using: &g)))
    }

    /// The code boundary: nothing in the surprise code may reach the Discord side.
    func testSurpriseCodeNeverTouchesTheNotifier() throws {
        let here = URL(fileURLWithPath: #filePath)
        let kit = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()       // Packages/SiverKit
        let repo = kit.deletingLastPathComponent().deletingLastPathComponent()
        var files = [kit.appendingPathComponent("Sources/SiverCore/SkyEggs.swift")]
        let appEggs = repo.appendingPathComponent("App/Eggs", isDirectory: true)
        files += try FileManager.default.contentsOfDirectory(at: appEggs, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(files.count, 3)
        let forbidden = ["import SiverNotify", "import SiverEngine", "NotifyMesh", "WebhookClient", "DiscordMessage", "Outbox", "RichTemplates", "HuntTemplates", "postStatus", "webhook"]
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            // Comments may say what the code must not do; code may not do it.
            let code = source.split(separator: "\n").map { line -> String in
                if let i = line.range(of: "//") { return String(line[..<i.lowerBound]) }
                return String(line)
            }.joined(separator: "\n")
            for word in forbidden { XCTAssertFalse(code.contains(word), "\(file.lastPathComponent) mentions \(word)") }
        }
    }
}
