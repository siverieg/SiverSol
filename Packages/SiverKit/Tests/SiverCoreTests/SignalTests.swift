import XCTest
@testable import SiverCore

final class SignalTests: XCTestCase {
    private func signal(_ text: String) -> LogSignal? {
        guard case .signal(let s, _)? = LogLineParser.parse("2026-11-18T17:47:36.151Z,1.0,0,6,Info \(text)") else { return nil }
        return s
    }

    /// The payload of the real roll event from 2026-11-18, exactly as the game wrote it.
    static let symphony = #"{"gameEvent":{"eventId":"aura_rolled","eventName":"Aura Rolled: \"Symphony\"","triggerActions":["SaveClip"],"clipOptions":{"captureDelayMs":15000,"duration":34.230000000000007}},"universeId":5361032378}"#

    func testRealAuraRolledEventDecodes() throws {
        let b64 = Data(Self.symphony.utf8).base64EncodedString()
        guard case .gameEvent(let e)? = signal("[FLog::CreatorOutput] [_MAPIEvent][v1/event/invoke] \(b64)") else { return XCTFail("not parsed") }
        XCTAssertEqual(e.eventId, "aura_rolled")
        XCTAssertEqual(e.rolledAuraName, "Symphony")
        XCTAssertEqual(e.captureDelayMs, 15000)
        XCTAssertEqual(try XCTUnwrap(e.durationS), 34.23, accuracy: 0.001)
    }

    func testGameEventDecodingIsDefensive() {
        func b64(_ json: String, strip: Bool = false) -> String {
            let s = Data(json.utf8).base64EncodedString()
            return strip ? s.replacingOccurrences(of: "=", with: "") : s
        }
        // Missing padding, as some encoders write it.
        XCTAssertEqual(LogLineParser.decodeGameEvent(base64: b64(#"{"gameEvent":{"eventId":"aura_rolled","eventName":"Aura Rolled: \"X\""}}"#, strip: true))?.rolledAuraName, "X")
        // No clip options: still a roll, the lock falls back to 35 s.
        let bare = LogLineParser.decodeGameEvent(base64: b64(#"{"gameEvent":{"eventId":"aura_rolled","eventName":"Aura Rolled: \"Abyssal Hunter\""}}"#))
        XCTAssertEqual(bare?.rolledAuraName, "Abyssal Hunter"); XCTAssertNil(bare?.captureDelayMs)
        XCTAssertEqual(AuraRolled(id: "x", name: "y", at: Date()).cutsceneSeconds, 35)
        // An event id we do not know yet is kept as a game event, but is not a roll.
        let other = LogLineParser.decodeGameEvent(base64: b64(#"{"gameEvent":{"eventId":"boss_defeated","eventName":"Boss"}}"#))
        XCTAssertEqual(other?.eventId, "boss_defeated"); XCTAssertNil(other?.rolledAuraName)
        // Absurd numbers are dropped, not trusted.
        let wild = LogLineParser.decodeGameEvent(base64: b64(#"{"gameEvent":{"eventId":"aura_rolled","eventName":"Aura Rolled: \"X\"","clipOptions":{"captureDelayMs":-5,"duration":999999}}}"#))
        XCTAssertNil(wild?.captureDelayMs); XCTAssertNil(wild?.durationS)
        for junk in ["", "%%%%", "aGVsbG8=", b64("{}"), b64(#"{"gameEvent":{}}"#), b64("[1,2,3]"), String(repeating: "A", count: 30_000)] {
            XCTAssertNil(LogLineParser.decodeGameEvent(base64: junk), junk.prefix(20).description)
        }
        XCTAssertNil(signal("[FLog::CreatorOutput] [_MAPIEvent][v1/event/invoke] not-base64!!"))
    }

    func testOtherSignals() {
        XCTAssertEqual(signal("[FLog::Output] Settings Date timestamp is 1795004117"), .heartbeat)
        XCTAssertEqual(signal("[FLog::CreatorOutput] daily reset time 1795046400"), .dailyReset(Date(timeIntervalSince1970: 1_795_046_400)))
        XCTAssertEqual(signal(#"[FLog::GameJoinUtil] GameJoinUtil::joinGamePostPrivateServer: URL: https://gamejoin.roblox.com/v1/join-private-game BODY: {"placeId":1,"accessCode":"secret"}"#), .joinRequest(.privateServer))
        XCTAssertEqual(signal("[FLog::GameJoinUtil] GameJoinUtil::initiateTeleportToReservedServer: URL: https://gamejoin.roblox.com/v1/join-reserved-game POST Body: {}"), .joinRequest(.reserved))
        XCTAssertEqual(signal("[FLog::SessionTransitionFSM] Entered play session."), .session(.enteredPlay))
        XCTAssertEqual(signal("[FLog::SessionTransitionFSM] Teleported."), .session(.teleported))
        XCTAssertEqual(signal("[FLog::SessionTransitionFSM] Tearing down."), .session(.tearingDown))
        XCTAssertNil(signal("[FLog::SessionTransitionFSM] Session history: IASPT"))
        XCTAssertEqual(signal("[FLog::UpdateController] Update check thread: updateRequired FALSE"), .updateRequired(false))
        XCTAssertEqual(signal("[FLog::UpdateController] Update check thread: updateRequired TRUE"), .updateRequired(true))
        XCTAssertEqual(signal(#"[FLog::UpdateController] version response: {"version":"0.745.100.7450979","clientVersionUpload":"version-abc","bootstrapperVersion":""}"#), .offeredVersion("0.745.100.7450979"))
        XCTAssertEqual(signal("[FLog::Graphics] SceneManager: resizing main targets to 960x921"), .windowSize(width: 960, height: 921))
        XCTAssertNil(signal("[FLog::AppMemUsageStatus] 923286370"), "not a memory reading; not used")
    }

    func testRollBecomesAnEventWithBiomeAndTiming() throws {
        var tracker = BiomeTracker(sessionId: "s")
        var events: [SiverEvent] = []
        let b64 = Data(Self.symphony.utf8).base64EncodedString()
        for line in [rpc("2026-11-18T17:40:00.000Z", "WINDY"),
                     "2026-11-18T17:47:36.151Z,1,0,6,Info [FLog::CreatorOutput] [_MAPIEvent][v1/event/invoke] \(b64)"] {
            if let e = LogLineParser.parse(line) { events += tracker.ingest(e) }
        }
        guard case .auraRolled(let roll)? = events.last else { return XCTFail("\(events)") }
        XCTAssertEqual(roll.name, "Symphony")
        XCTAssertEqual(roll.biome?.key, "WINDY")
        XCTAssertEqual(roll.captureDelayMs, 15000)
        XCTAssertEqual(roll.cutsceneSeconds, 34.23, accuracy: 0.001)
        XCTAssertEqual(roll.at, date("2026-11-18T17:47:36.151Z"))
    }

    /// QA check from the brief: replay the fixture that holds today's real aura_rolled line.
    func testFixtureWithTheRealRollLine() throws {
        let events = track(try Fixture.lines("session-c-2026-11-18.log")).events
        let rolls = events.compactMap { e -> AuraRolled? in if case .auraRolled(let r) = e { return r }; return nil }
        XCTAssertEqual(rolls.map(\.name), ["Symphony"])
        XCTAssertEqual(rolls[0].at, date("2026-11-18T17:47:36.151Z"))
        XCTAssertEqual(rolls[0].captureDelayMs, 15000)
        // The equip line for the rolled aura follows about four seconds later.
        let equip = try XCTUnwrap(events.auras.first { $0.internalName == "Symphony" })
        XCTAssertEqual(equip.at.timeIntervalSince(rolls[0].at), 4.07, accuracy: 0.1)
        // The fixture went through the sanitizer and stays stable under it.
        let text = try Fixture.text("session-c-2026-11-18.log")
        XCTAssertEqual(LogSanitizer.sanitize(text), text)
        XCTAssertFalse(text.contains("accessCode")); XCTAssertFalse(text.contains("universeId"))
    }

    func testSanitizerRebuildsSignalLinesFromFieldsOnly() {
        let raw = [
            #"2026-11-18T15:04:45.000Z,1,0,6 [FLog::GameJoinUtil] GameJoinUtil::joinGamePostPrivateServer: URL: https://gamejoin.roblox.com/v1/join-private-game BODY: {"placeId":15532962292,"accessCode":"11111111-2222-3333-4444-555555555555","gameJoinAttemptId":"x"}"#,
            "2026-11-18T15:04:45.977Z,1,0,6 [FLog::Output] ! Joining game 'abcdef01-2222-3333-4444-555555555555' place 15532962292 at 10.1.2.3",
            "2026-11-18T15:04:46.000Z,1,0,6 [FLog::Network] serverId: 10.1.2.3|59032",
            "2026-11-18T15:04:47.000Z,1,0,6 [FLog::GameJoinLoadTime] Report game_join_loadtime: sid:x, userid:123456789, join_time:1.4",
            "2026-11-18T15:06:00.000Z,1,0,6 [FLog::Output] Settings Date timestamp is 1795014360",
        ].joined(separator: "\n")
        let clean = LogSanitizer.sanitize(raw)
        XCTAssertEqual(clean.split(separator: "\n").count, 3, "join request, join, heartbeat; the rest is dropped")
        for secret in ["11111111-2222", "abcdef01", "10.1.2.3", "123456789", "59032", "1795014360"] { XCTAssertFalse(clean.contains(secret), secret) }
        XCTAssertTrue(clean.contains("join-private-game BODY: {}"))
    }

    func testSessionInspector() {
        var inspector = SessionInspector()
        inspector.setClientVersion("0.745.100.7450979")
        var entries: [LogLabEntry] = []
        func feed(_ line: String) { if let e = LogLineParser.parse(line), let entry = inspector.note(e) { entries.append(entry) } }
        feed("2026-11-18T15:04:45.000Z,1,0,6 [FLog::GameJoinUtil] GameJoinUtil::joinGamePostPrivateServer: URL: https://gamejoin.roblox.com/v1/join-private-game BODY: {\"accessCode\":\"secret-code\"}")
        feed(joinLine("2026-11-18T15:04:45.977Z", job: "abcdef01-2222-3333-4444-555555555555"))
        feed("2026-11-18T15:04:46.500Z,1,0,6 [FLog::SessionTransitionFSM] Entered play session.")
        feed("2026-11-18T15:05:00.000Z,1,0,6,Info [FLog::CreatorOutput] daily reset time 1795046400")
        feed("2026-11-18T15:06:00.000Z,1,0,6 [FLog::Output] Settings Date timestamp is 1795014360")
        feed("2026-11-18T15:06:01.000Z,1,0,6 [FLog::Graphics] SceneManager: resizing main targets to 960x921")
        feed(#"2026-11-18T15:06:02.000Z,1,0,6 [FLog::UpdateController] version response: {"version":"0.748.0.7481526"}"#)
        XCTAssertEqual(inspector.info.joinKind, .privateServer)
        XCTAssertEqual(inspector.info.shortJobId, "abcdef01")
        XCTAssertEqual(inspector.info.joinedAt, date("2026-11-18T15:04:45.977Z"))
        XCTAssertEqual(inspector.info.dailyResetAt, Date(timeIntervalSince1970: 1_795_046_400))
        XCTAssertEqual(inspector.info.windowWidth, 960)
        XCTAssertTrue(inspector.info.inPlaySession)
        XCTAssertTrue(inspector.info.updatePending, "the update server offers a different version than the one running")
        // The game's own timed move to a reserved server.
        feed("2026-11-18T15:30:00.000Z,1,0,6 [FLog::GameJoinUtil] GameJoinUtil::initiateTeleportToReservedServer: URL: https://gamejoin.roblox.com/v1/join-reserved-game POST Body: {}")
        feed("2026-11-18T15:30:01.000Z,1,0,6 [FLog::SessionTransitionFSM] Teleported.")
        feed(joinLine("2026-11-18T15:30:02.000Z", job: "99999999-2222-3333-4444-555555555555"))
        XCTAssertEqual(inspector.info.teleports, 1)
        XCTAssertEqual(inspector.info.joins, 2)
        XCTAssertEqual(inspector.info.joinKind, .reserved)
        // A join with no request line before it is a public join.
        feed(joinLine("2026-11-18T16:00:00.000Z", job: "77777777-2222-3333-4444-555555555555"))
        XCTAssertEqual(inspector.info.joinKind, .publicServer)
        // Log Lab entries describe parsed fields only: never the access code, the full server id or an address.
        let text = entries.map(\.summary).joined(separator: "\n")
        for secret in ["secret-code", "2222-3333", "0.0.0.0", "1795014360"] { XCTAssertFalse(text.contains(secret), secret) }
        XCTAssertTrue(text.contains("joined a private server · server abcdef01 · Sol's RNG"))
        XCTAssertTrue(text.contains("render size 960×921"))
        // Unknown things are counted, not shown.
        feed(rpc("2026-11-18T16:01:00.000Z", "NORMAL", state: "Fishing at SomePlayer99's dock"))
        XCTAssertEqual(inspector.unknown.values.reduce(0, +), 1)
        XCTAssertFalse(inspector.unknown.keys.joined().contains("SomePlayer99"))
    }
}
