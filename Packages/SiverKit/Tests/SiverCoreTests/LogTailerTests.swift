import XCTest
@testable import SiverCore

final class LogTailerTests: XCTestCase {
    func testLineBufferHoldsPartialLine() {
        var b = LineBuffer()
        XCTAssertEqual(b.append(Data("one\ntw".utf8)), ["one"])
        XCTAssertTrue(b.hasPartialLine)
        XCTAssertEqual(b.append(Data("o\nthree\n".utf8)), ["two", "three"])
        XCTAssertFalse(b.hasPartialLine)
        XCTAssertEqual(b.append(Data()), [])
    }

    func testLineBufferCRLFAndSplitUTF8() {
        var b = LineBuffer()
        XCTAssertEqual(b.append(Data("a\r\nb\r\n".utf8)), ["a", "b"])
        let bytes = Array("biome 🌠 ok\n".utf8)
        // Cut in the middle of the 4-byte emoji.
        XCTAssertEqual(b.append(Data(bytes[..<8])), [])
        XCTAssertEqual(b.append(Data(bytes[8...])), ["biome 🌠 ok"])
    }

    func testTailerReadsAppendsAndBuffersPartialLastLine() {
        let logs = TempLogs()
        logs.write("x.log", "first\nsecond\npart")
        let tailer = LogTailer(url: logs.url("x.log"))
        XCTAssertEqual(tailer.poll().lines, ["first", "second"])
        XCTAssertEqual(tailer.poll().lines, [], "nothing new")
        logs.append("x.log", "ial\nthird\n")
        let read = tailer.poll()
        XCTAssertEqual(read.lines, ["partial", "third"])
        XCTAssertFalse(read.didReset)
    }

    func testTailerResetsWhenFileShrinks() {
        let logs = TempLogs()
        logs.write("x.log", "a long first line\nand another\n")
        let tailer = LogTailer(url: logs.url("x.log"))
        _ = tailer.poll()
        // Truncate in place (same inode, smaller size).
        let h = try! FileHandle(forWritingTo: logs.url("x.log"))
        try! h.truncate(atOffset: 0); try! h.write(contentsOf: Data("new\n".utf8)); try! h.close()
        let read = tailer.poll()
        XCTAssertTrue(read.didReset)
        XCTAssertEqual(read.lines, ["new"])
    }

    func testTailerResetsWhenFileIsReplaced() {
        let logs = TempLogs()
        logs.write("x.log", "old\n")
        let tailer = LogTailer(url: logs.url("x.log"))
        XCTAssertEqual(tailer.poll().lines, ["old"])
        try! FileManager.default.removeItem(at: logs.url("x.log"))
        XCTAssertEqual(tailer.poll().lines, [], "missing file is not an error")
        logs.write("x.log", "replacement that is longer than before\n")
        let read = tailer.poll()
        XCTAssertTrue(read.didReset)
        XCTAssertEqual(read.lines, ["replacement that is longer than before"])
    }
}

final class LogDiscoveryTests: XCTestCase {
    func testPicksNewestPlayerLogByLaunchStampNotMtime() {
        let logs = TempLogs()
        // Real file name shapes from a macOS client.
        logs.write("0.748.0.7481526_20261118T114022Z_Player_3e336_last.log", "")
        logs.write("0.745.100.7450979_20261118T121315Z_Player_6a2e9_last.log", "")
        logs.write("0.745.100.7450979_20261118T121315Z_Player_a35c0_CrashHandler_last.log", "")
        logs.write("RobloxPlayerInstaller_2026-11-18_17:42:57.log", "")
        logs.write("notes.txt", "")
        // Touch the old log last, so its mtime is the newest.
        logs.append("0.748.0.7481526_20261118T114022Z_Player_3e336_last.log", "late write\n")
        let all = LogDiscovery.playerLogs(in: logs.dir)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first?.sessionId, "20261118T121315Z_6a2e9")
        XCTAssertEqual(all.first?.version, "0.745.100.7450979")
        XCTAssertEqual(LogDiscovery.newest(in: logs.dir)?.launchedAt, date("2026-11-18T12:13:15.000Z"))
    }

    func testEmptyOrMissingFolder() {
        XCTAssertNil(LogDiscovery.newest(in: TempLogs().dir))
        XCTAssertNil(LogDiscovery.newest(in: URL(fileURLWithPath: "/nonexistent/siversol")))
    }
}
