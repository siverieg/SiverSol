import XCTest
@testable import SiverCore
@testable import SiverEngine
@testable import SiverInput
@testable import SiverMacro
@testable import SiverNotify
@testable import SiverVision

final class MacroRulesTests: XCTestCase {
    func macro(_ name: String, _ triggers: [MacroTrigger], reviewed: Bool = true) -> Macro {
        var m = Macro(name: name, steps: [MacroStep(delay: 0.1, .keyDown(code: 13)), MacroStep(delay: 0.1, .keyUp(code: 13))])
        m.settings.triggers = triggers; m.reviewed = reviewed
        return m
    }

    func testNotifySettingPerMacro() {
        XCTAssertFalse(MacroRules.shouldNotify(.started, setting: .none, isError: false))
        XCTAssertFalse(MacroRules.shouldNotify(.stopped, setting: .none, isError: true))
        XCTAssertFalse(MacroRules.shouldNotify(.started, setting: .errors, isError: false))
        XCTAssertFalse(MacroRules.shouldNotify(.finished, setting: .errors, isError: false))
        XCTAssertTrue(MacroRules.shouldNotify(.stopped, setting: .errors, isError: true), "Guardian, panic, rare biome…")
        XCTAssertFalse(MacroRules.shouldNotify(.stopped, setting: .errors, isError: false), "you pressed Stop yourself")
        XCTAssertTrue(MacroRules.shouldNotify(.started, setting: .startEnd, isError: false))
        XCTAssertTrue(MacroRules.shouldNotify(.finished, setting: .startEnd, isError: false))
        XCTAssertTrue(MacroRules.shouldNotify(.recorded, setting: .none, isError: false))
        XCTAssertFalse(MacroStopReason.user.isError); XCTAssertTrue(MacroStopReason.guardian("x").isError); XCTAssertTrue(MacroStopReason.rareBiome.isError)
    }

    func testTriggersPickTheRightMacros() {
        let lib = [macro("windy walk", [.biomeStarted("WINDY")]), macro("after windy", [.biomeEnded("WINDY")]), macro("rejoin setup", [.afterRejoin]),
                   macro("daily", [.dailyReset]), macro("imported, not reviewed", [.biomeStarted("WINDY")], reviewed: false), macro("manual only", [])]
        XCTAssertEqual(MacroRules.macros(for: .biomeStarted("WINDY"), in: lib), ["windy walk"], "an imported macro never runs before it was reviewed")
        XCTAssertEqual(MacroRules.macros(for: .biomeEnded("WINDY"), in: lib), ["after windy"])
        XCTAssertEqual(MacroRules.macros(for: .afterRejoin, in: lib), ["rejoin setup"])
        XCTAssertEqual(MacroRules.macros(for: .dailyReset, in: lib), ["daily"])
        XCTAssertTrue(MacroRules.macros(for: .biomeStarted("RAINY"), in: lib).isEmpty)
    }

    func testSchedules() {
        let t = Date(timeIntervalSince1970: 1_795_000_000)
        let lib = [macro("every 15", [.everyMinutes(15)]), macro("every 60", [.everyMinutes(60)])]
        var last = ["every 15|15.0": t, "every 60|60.0": t]
        XCTAssertTrue(MacroRules.dueSchedules(in: lib, lastRun: last, now: t.addingTimeInterval(14 * 60)).isEmpty)
        XCTAssertEqual(MacroRules.dueSchedules(in: lib, lastRun: last, now: t.addingTimeInterval(15 * 60)).map(\.name), ["every 15"])
        last["every 15|15.0"] = t.addingTimeInterval(15 * 60)
        XCTAssertEqual(MacroRules.dueSchedules(in: lib, lastRun: last, now: t.addingTimeInterval(61 * 60)).map(\.name), ["every 15", "every 60"])
        XCTAssertEqual(MacroTrigger.everyMinutes(15).label, "every 15 min")
        XCTAssertEqual(MacroTrigger.biomeStarted("WINDY").label, "when WINDY starts")
    }
}

final class MacroWebhookTests: XCTestCase {
    func ctx(links: [String: MessageRef] = [:]) -> RenderContext {
        RenderContext(catalog: try! BiomeCatalog.bundled(), route: RouteConfig(name: "main", profile: .rich), link: { links[$0] })
    }
    let at = Date(timeIntervalSince1970: 1_795_000_000)

    func testTemplates() {
        var started = MacroEvent(id: "m1", kind: .started, name: "Windy walk", at: at, trigger: "when WINDY starts", biomeEventId: "bs1")
        started.steps = 42
        let ref = MessageRef(messageId: "777", channelId: "5", guildId: "9")
        let s = RichTemplates.macro(started, ctx(links: ["bs1": ref])).embeds[0]
        XCTAssertEqual(s.title, "▶️ Macro started · Windy walk")
        let sf = Dictionary(uniqueKeysWithValues: (s.fields ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(sf["Trigger"], "when WINDY starts")
        XCTAssertEqual(sf["Triggered by"], "[↗ biome message](https://discord.com/channels/9/5/777)", "linked to the biome message that started it")

        var finished = MacroEvent(id: "m2", kind: .finished, name: "Windy walk", at: at); finished.loops = 3; finished.durationS = 95; finished.steps = 126
        let f = RichTemplates.macro(finished, ctx()).embeds[0]
        XCTAssertEqual(f.title, "🏁 Macro finished · Windy walk")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: (f.fields ?? []).map { ($0.name, $0.value) })["Took"], "1m 35s")

        var stopped = MacroEvent(id: "m3", kind: .stopped, name: "Windy walk", at: at); stopped.reason = MacroStopReason.guardian("purchase dialog (\"robux\" on screen)").label; stopped.guardianStop = true
        let g = RichTemplates.macro(stopped, ctx(), hasProof: true).embeds[0]
        XCTAssertEqual(g.title, "⏹️ Macro stopped · Windy walk")
        XCTAssertTrue(g.description?.contains("Every key and button was released") ?? false)
        XCTAssertTrue(g.fields?.contains { $0.name == "Why" && $0.value.contains("stopped by Guardian") } ?? false)

        var rec = MacroEvent(id: "m4", kind: .recorded, name: "New one", at: at); rec.steps = 300; rec.durationS = 61
        XCTAssertEqual(RichTemplates.macro(rec, ctx()).embeds[0].title, "⏺️ Macro recorded · New one")
        for e in [started, finished, stopped, rec] {
            let m = RichTemplates.macro(e, ctx())
            XCTAssertEqual(m.allowedMentions, .none)
            XCTAssertFalse(HuntFormat.looksLikeHuntEvent(m))
        }
    }

    func testMacroEventsOnlyReachRichRoutesWithTheMacrosFilter() async throws {
        final class Transport: HTTPTransport, @unchecked Sendable {
            var posts: [(String, String)] = []
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                if request.httpMethod == "POST" { posts.append((request.url!.path, String(decoding: request.httpBody ?? Data(), as: UTF8.self))) }
                let json = request.httpMethod == "GET" ? #"{"id":"1","guild_id":"9","channel_id":"5"}"# : #"{"id":"77","channel_id":"5"}"#
                return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let transport = Transport()
        var noMacros = RouteConfig(name: "quiet", profile: .rich); noMacros.events = [.biome, .aura]
        let mesh = NotifyMesh(config: NotifyConfig(routes: [RouteConfig(name: "main", profile: .rich), noMacros, RouteConfig(name: "hunt", profile: .huntCompat)], messageStyle: .classic),
                              secrets: Secrets(discordWebhooks: ["main": "https://discord.com/api/webhooks/111/a", "quiet": "https://discord.com/api/webhooks/333/c", "hunt": "https://discord.com/api/webhooks/222/b"]),
                              catalog: try BiomeCatalog.bundled(), store: OutboxStore(directory: nil), transport: transport)
        var stopped = MacroEvent(id: "m9", kind: .stopped, name: "Farm", at: Date()); stopped.reason = "stopped by Guardian: trade window"; stopped.guardianStop = true
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("proof-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: png)
        await mesh.postMacro(stopped, proof: png.path)
        _ = await mesh.flush(timeout: 10)
        XCTAssertEqual(transport.posts.count, 1)
        XCTAssertTrue(transport.posts[0].0.contains("/111/"), "not the route without the macros filter, and never the hunt route")
        XCTAssertTrue(transport.posts[0].1.contains("attachment://\(png.lastPathComponent)"), "Guardian's screenshot rides along")
        XCTAssertTrue(RouteConfig(name: "x", profile: .rich).events.contains(.macros), "new Rich routes get macro events by default")
        XCTAssertFalse(RouteConfig(name: "h", profile: .huntCompat).wants(.macros))
    }

    func testDailyReportShowsMacroTotals() {
        var r = DailyReport(day: "2026-11-18", counts: ["NORMAL": 3], seconds: ["NORMAL": 600], rares: [], uptimeS: 600, auras: 0)
        XCTAssertFalse(RichTemplates.dailyReport(r, ctx()).embeds[0].fields?.contains { $0.name == "Macros" } ?? true)
        r.macroRuns = 4; r.autoClicks = 1200
        XCTAssertEqual(RichTemplates.dailyReport(r, ctx()).embeds[0].fields?.first { $0.name == "Macros" }?.value, "4 runs · 1200 auto clicks")
    }

    func testLettingGoOfTheStartShortcutDoesNotStopAMouseMacro() {
        // ⌃⌥⌘M starts a macro; the three modifiers and M come up a moment later. That is not "taking over".
        XCTAssertFalse(MacroCoordinator.countsAsTakingOver(RawInput(.keyUp, time: 0, keyCode: 46)))
        XCTAssertFalse(MacroCoordinator.countsAsTakingOver(RawInput(.keyUp, time: 0, keyCode: 55)))
        XCTAssertFalse(MacroCoordinator.countsAsTakingOver(RawInput(.mouseUp(.left), time: 0)))
        var shortcut = RawInput(.keyDown, time: 0, keyCode: 46); shortcut.isShortcut = true
        XCTAssertFalse(MacroCoordinator.countsAsTakingOver(shortcut))
        // Real use of the Mac still stops it.
        XCTAssertTrue(MacroCoordinator.countsAsTakingOver(RawInput(.keyDown, time: 0, keyCode: 13)))
        XCTAssertTrue(MacroCoordinator.countsAsTakingOver(RawInput(.mouseDown(.left), time: 0)))
        XCTAssertTrue(MacroCoordinator.countsAsTakingOver(RawInput(.mouseMove, time: 0)))
        XCTAssertTrue(MacroCoordinator.countsAsTakingOver(RawInput(.scroll, time: 0)))
    }

    func testAnOpenInventoryBlocksMacroClicksUnlessTheMacroWasAllowed() async {
        // Seen on a real session: the Inventory open in the middle of the window, a "Use" button next to an item.
        func box(_ t: String, x: Double, y: Double) -> TextBox { TextBox(text: t, box: CGRect(x: x, y: y, width: 0.08, height: 0.015)) }
        let inventory = [box("Inventory", x: 0.458, y: 0.386), box("Items", x: 0.648, y: 0.407), box("Use", x: 0.344, y: 0.532), box("Roll", x: 0.479, y: 0.916)]
        let policy = GuardianPolicy()
        guard case .blocked(let why, let forbidden) = policy.evaluate(.macroClick(x: 0.36, y: 0.54), screen: inventory) else { return XCTFail("a click on Use must not be approved") }
        XCTAssertFalse(forbidden, "an open Inventory is not an alarm: no Escape, no pause, the click is simply refused")
        XCTAssertTrue(why.contains("Inventory"))
        // The title alone or the button alone is enough.
        XCTAssertNotEqual(policy.evaluate(.macroClick(x: 0.5, y: 0.2), screen: [box("Use", x: 0.344, y: 0.532)]), .approved)
        XCTAssertNotEqual(policy.evaluate(.macroClick(x: 0.5, y: 0.2), screen: [box("Inventory", x: 0.458, y: 0.386)]), .approved)
        // Keys still pass (anti-AFK keeps working), and a macro that was allowed item clicks may click.
        XCTAssertEqual(policy.evaluate(.key("space"), screen: inventory), .approved)
        XCTAssertEqual(policy.evaluate(.macroItemClick(x: 0.36, y: 0.54), screen: inventory), .approved)
        // The word in chat, or as part of a sentence, does not count.
        XCTAssertEqual(policy.evaluate(.macroClick(x: 0.5, y: 0.5), screen: [box("use", x: 0.02, y: 0.3), box("Use the portal to travel", x: 0.4, y: 0.3)]), .approved)
        // Guardian remembers that the last look had an item panel, so allowed clicks can be counted.
        let guardian = Guardian(log: ActionLog(url: nil)) { Guardian.Look(text: inventory, frameHash: 1) }
        XCTAssertFalse(guardian.itemPanelOnLastLook)
        _ = await guardian.approve(.macroItemClick(x: 0.36, y: 0.54), maxLookAge: 1)
        XCTAssertTrue(guardian.itemPanelOnLastLook)
    }

    func testGuardianTreatsMacroClicksLikeAnyOtherInput() async {
        let policy = GuardianPolicy()
        func box(_ t: String) -> TextBox { TextBox(text: t, box: CGRect(x: 0.45, y: 0.49, width: 0.1, height: 0.02)) }
        XCTAssertEqual(policy.evaluate(.macroClick(x: 0.5, y: 0.5), screen: [box("Roll")]), .approved)
        for danger in ["Buy 400 Robux?", "Delete Aura?", "Trade Request", "Aura Storage"] {
            XCTAssertNotEqual(policy.evaluate(.macroClick(x: 0.5, y: 0.5), screen: [box(danger)]), .approved, danger)
        }
        XCTAssertNotEqual(policy.evaluate(.macroClick(x: 0.5, y: 0.5), screen: nil), .approved, "no click without seeing the screen")
        // The one-second look cache: many clicks, one screenshot per second.
        final class Counter: @unchecked Sendable { var looks = 0 }
        let counter = Counter()
        let guardian = Guardian(log: ActionLog(url: nil)) { counter.looks += 1; return Guardian.Look(text: [], frameHash: 1) }
        for _ in 0..<20 { _ = await guardian.approve(.macroClick(x: 0.5, y: 0.5), maxLookAge: 1) }
        XCTAssertEqual(counter.looks, 1)
        _ = await guardian.approve(.key("space"))
        XCTAssertEqual(counter.looks, 2, "everything else still takes a fresh look every time")
    }
}
