import XCTest
@testable import SiverCore

final class SidebarLogicTests: XCTestCase {
    func testSectionsGroupEveryPageOnce() {
        XCTAssertEqual(SidebarSection.allCases.map(\.rawValue), ["Sky", "Collection", "Control", "Tools"])
        XCTAssertEqual(SidebarSection.sky.pages, [.dashboard, .timeline])
        XCTAssertEqual(SidebarSection.collection.pages, [.auras, .moments])
        XCTAssertEqual(SidebarSection.control.pages, [.notifications, .automation, .macros], "Macro Studio lives with the other controls")
        XCTAssertEqual(SidebarSection.tools.pages, [.logLab, .settings, .tips, .about], "Tips sits above About")
        let all = SidebarSection.allCases.flatMap(\.pages)
        XCTAssertEqual(all.filter { $0.shortcutDigit != nil }, Array(AppPage.allCases.prefix(10)), "the sidebar order is the page order, so ⌘1 to ⌘0 run top to bottom")
        XCTAssertEqual(Set(all), Set(AppPage.allCases), "every page is in the sidebar")
        XCTAssertEqual(Set(all).count, AppPage.allCases.count)
        XCTAssertEqual(SidebarSection.of(.macros), .control)
    }

    func testShortcutsRunFromOneToZero() {
        XCTAssertEqual(AppPage.allCases.map(\.shortcutDigit), [1, 2, 3, 4, 5, 6, 7, 8, 9, 0, nil], "Tips came later and has no shortcut")
        XCTAssertEqual(AppPage.tips.shortcutLabel, "")
        XCTAssertEqual(AppPage.dashboard.shortcutLabel, "⌘1")
        XCTAssertEqual(AppPage.about.shortcutLabel, "⌘0")
        XCTAssertEqual(AppPage.auras.title, "Sol Dex")
        XCTAssertEqual(AppPage(rawValue: "auras"), .auras, "links keep working")
    }

    func testAccessoryText() {
        XCTAssertEqual(SidebarFormat.dex(found: 48, total: 212), .text("48/212", spoken: "48 of 212 found"))
        XCTAssertEqual(SidebarFormat.dex(found: 0, total: 0), .none)
        XCTAssertEqual(SidebarFormat.eventsToday(0), .none, "nothing to say, nothing shown")
        XCTAssertEqual(SidebarFormat.eventsToday(1), .text("1", spoken: "1 event today"))
        XCTAssertEqual(SidebarFormat.eventsToday(128), .text("128", spoken: "128 events today"))
        XCTAssertEqual(SidebarFormat.eventsToday(1240), .text("1.2k", spoken: "1240 events today"))
        XCTAssertEqual(SidebarFormat.clock(72), "1:12")
        XCTAssertEqual(SidebarFormat.clock(3723), "1:02:03")
        XCTAssertEqual(SidebarFormat.clock(-5), "0:00")
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)        // 2027-01-15 08:00 UTC
        XCTAssertEqual(SidebarFormat.nextRun(now.addingTimeInterval(1800), now: now, calendar: utc), .text("08:30", spoken: "next run at 08:30"))
        XCTAssertEqual(SidebarFormat.nextRun(nil, now: now), .none)
        XCTAssertEqual(SidebarFormat.nextRun(now.addingTimeInterval(-60), now: now), .none, "a time that has passed is not a next run")
        XCTAssertEqual(SidebarFormat.playhead(step: 5, of: 20, name: "QA walk"), .playhead(0.25, spoken: "playing QA walk"))
        XCTAssertEqual(SidebarAccessory.health(.failing).spoken, "a webhook is failing")
        XCTAssertEqual(SidebarAccessory.none.spoken, "")
    }

    func testNotifyHealth() {
        XCTAssertEqual(NotifyHealth.of(hasWebhook: true, deadRoutes: 0, waiting: 0), .healthy)
        XCTAssertEqual(NotifyHealth.of(hasWebhook: true, deadRoutes: 0, waiting: 3), .retrying)
        XCTAssertEqual(NotifyHealth.of(hasWebhook: true, deadRoutes: 1, waiting: 3), .failing)
        XCTAssertEqual(NotifyHealth.of(hasWebhook: false, deadRoutes: 0, waiting: 0), .notSetUp)
    }

    func testStatusCardStates() {
        XCTAssertEqual(StatusCardState.of(watching: true, inputPaused: false, robloxRunning: true, rareBiome: false), .resting)
        XCTAssertEqual(StatusCardState.of(watching: true, inputPaused: false, robloxRunning: true, rareBiome: true), .rare)
        XCTAssertEqual(StatusCardState.of(watching: false, inputPaused: false, robloxRunning: true, rareBiome: true), .paused, "not watching is paused, whatever was on")
        XCTAssertEqual(StatusCardState.of(watching: true, inputPaused: true, robloxRunning: true, rareBiome: true), .paused)
        XCTAssertEqual(StatusCardState.of(watching: true, inputPaused: false, robloxRunning: false, rareBiome: false), .noRoblox)
    }

    func testStatusLine() {
        XCTAssertEqual(SidebarStatus.line(watching: true, inputPaused: false, robloxRunning: true, biome: "Pumpkin Moon"), "Watching · Pumpkin Moon")
        XCTAssertEqual(SidebarStatus.line(watching: false, inputPaused: false, robloxRunning: true, biome: "Pumpkin Moon"), "Paused")
        XCTAssertEqual(SidebarStatus.line(watching: true, inputPaused: false, robloxRunning: false, biome: nil), "Waiting for Roblox")
        XCTAssertEqual(SidebarStatus.line(watching: true, inputPaused: false, robloxRunning: true, biome: nil), "Watching the horizon")
        XCTAssertEqual(SidebarStatus.line(watching: true, inputPaused: true, robloxRunning: true, biome: "Rainy"), "Input paused · Rainy")
        XCTAssertEqual(SidebarStatus.line(watching: true, needsAttention: true, inputPaused: false, robloxRunning: true, biome: nil), "Needs a look")
    }

    /// The biome tint must be visible as an icon and a selection on the sidebar over that biome's own sky.
    func testTheTintReadsOverEverySky() throws {
        let catalog = try BiomeCatalog.bundled()
        for info in catalog.all {
            for hour in [13.0, 23.0, 6.5, 18.75] {
                for dark in [false, true] {
                    let look = SkyModel.look(info.palette, hour: hour, dark: dark)
                    let tint = SkyModel.legibleAccent(look, dark: dark)
                    let surface = SkyModel.sidebarSurface(over: look.top.mix(look.bottom, 0.4), dark: dark)
                    XCTAssertGreaterThanOrEqual(tint.contrast(surface), 3.0, "\(info.key) at \(hour) \(dark ? "dark" : "light")")
                }
            }
        }
        // A tint that already reads is left exactly as the catalog has it.
        let glitched = SkyModel.look(catalog.info(for: "GLITCHED").palette, hour: 23, dark: true)
        XCTAssertEqual(SkyModel.legibleAccent(glitched, dark: true), glitched.accent)
    }

    func testButtonTextKeepsItsContrastOverEverySky() throws {
        // A filled button: the biome's accent, with black or white text on it. Never less than 4.5:1.
        let catalog = try BiomeCatalog.bundled()
        for info in catalog.all + [catalog.info(for: "NORMAL")] {
            for hour in stride(from: 0.0, to: 24.0, by: 1.5) {
                for dark in [false, true] {
                    let look = SkyModel.look(info.palette, hour: hour, dark: dark)
                    let b = SkyModel.buttonFill(look, dark: dark)
                    XCTAssertGreaterThanOrEqual(b.text.contrast(b.fill), 4.5, "\(info.key.value) at \(hour), dark \(dark)")
                    XCTAssertGreaterThanOrEqual(b.fill.contrast(SkyModel.cardBase(dark: dark).color), 2.2, "the button stands out from its card: \(info.key.value)")
                }
            }
        }
    }

    // MARK: tips

    func testEveryShowMeLinkLeadsToARealPage() {
        XCTAssertGreaterThanOrEqual(TipCatalog.all.count, 15)
        XCTAssertEqual(Set(TipCatalog.all.map(\.id)).count, TipCatalog.all.count, "ids are unique")
        for tip in TipCatalog.all {
            XCTAssertTrue(AppPage.allCases.contains(tip.page), tip.id)
            XCTAssertNotNil(AppPage(rawValue: tip.page.rawValue))
            XCTAssertFalse(SidebarSection.of(tip.page).pages.isEmpty, "\(tip.id) leads to a page the sidebar shows")
            XCTAssertFalse(tip.text.contains("!"), "calm words: \(tip.id)")
            XCTAssertLessThanOrEqual(tip.text.components(separatedBy: ". ").count, 2, "one or two sentences: \(tip.id)")
        }
        for group in Tip.Group.allCases { XCTAssertFalse(TipCatalog.tips(in: group).isEmpty, group.rawValue) }
        // Features that are not in this build have no tip.
        XCTAssertFalse(TipCatalog.all.contains { $0.text.contains("⌘K") || $0.text.contains("Night Shift") })
    }

    func testTipsAreSuppressedDuringRareBiomesAndMacros() {
        XCTAssertTrue(TipRules.mayShow(enabled: true, rareBiome: false, macroBusy: false))
        XCTAssertFalse(TipRules.mayShow(enabled: true, rareBiome: true, macroBusy: false))
        XCTAssertFalse(TipRules.mayShow(enabled: true, rareBiome: false, macroBusy: true))
        XCTAssertFalse(TipRules.mayShow(enabled: false, rareBiome: false, macroBusy: false), "Show tips is off")
    }

    func testAtMostOneTipADay() {
        let a = TipRules.tipOfDay(day: 100, dismissed: [], dismissedOn: nil)
        XCTAssertNotNil(a)
        XCTAssertEqual(TipRules.tipOfDay(day: 100, dismissed: [], dismissedOn: nil), a, "the same tip all day")
        XCTAssertNotEqual(TipRules.tipOfDay(day: 101, dismissed: [], dismissedOn: nil), a, "a new one tomorrow")
        // Dismissed today: nothing more today, the next one tomorrow, and never the dismissed one again.
        XCTAssertNil(TipRules.tipOfDay(day: 100, dismissed: [a!.id], dismissedOn: 100))
        let next = TipRules.tipOfDay(day: 101, dismissed: [a!.id], dismissedOn: 100)
        XCTAssertNotNil(next); XCTAssertNotEqual(next, a)
        for day in 0..<200 { XCTAssertNotEqual(TipRules.tipOfDay(day: day, dismissed: [a!.id], dismissedOn: nil)?.id, a!.id) }
        XCTAssertNil(TipRules.tipOfDay(day: 5, dismissed: Set(TipCatalog.all.map(\.id)), dismissedOn: nil), "all seen: quiet")
        // Days are whole local days.
        let cal = Calendar(identifier: .gregorian)
        let noon = cal.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 12))!
        XCTAssertEqual(TipRules.day(noon, calendar: cal), TipRules.day(noon.addingTimeInterval(3 * 3600), calendar: cal))
        XCTAssertEqual(TipRules.day(noon.addingTimeInterval(86_400), calendar: cal), TipRules.day(noon, calendar: cal) + 1)
    }
}
