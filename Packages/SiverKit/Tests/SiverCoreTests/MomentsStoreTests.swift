import XCTest
@testable import SiverCore

final class MomentsStoreTests: XCTestCase {
    private var dir: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("siversol-moments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func add(_ store: MomentsStore, _ title: String, minutesAgo: Double, bytes: Int) throws -> Moment {
        let at = t0.addingTimeInterval(-minutesAgo * 60)
        let id = MomentsStore.baseName(kind: .roll, title: title, at: at)
        try Data(count: bytes).write(to: store.videoURL(id))
        try Data(count: 10).write(to: store.thumbnailURL(id))
        let m = Moment(id: id, kind: .roll, title: title, detail: "1 in 50,000", biome: "NORMAL", at: at, seconds: 8, bytes: bytes, eventId: "e")
        try store.save(m)
        return m
    }

    func testFileNamesAreSafeAndSortable() {
        let name = MomentsStore.baseName(kind: .roll, title: "Rolled Flushed : Pumpkinity / \"x\"", at: t0)
        XCTAssertTrue(name.hasPrefix("Moment-"))
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertFalse(name.contains(" "))
        XCTAssertTrue(name.hasSuffix("Rolled-Flushed-Pumpkinity-x"))
        XCTAssertTrue(MomentsStore.isOurs(name + ".mp4"))
        XCTAssertFalse(MomentsStore.isOurs("holiday.mp4"))
        XCTAssertFalse(MomentsStore.isOurs("Moment-notes.txt"))
    }

    func testListingIsNewestFirstAndIgnoresOtherFiles() throws {
        let store = MomentsStore(directory: dir)
        _ = try add(store, "Rolled Ruby", minutesAgo: 30, bytes: 100)
        _ = try add(store, "Rolled Symphony", minutesAgo: 5, bytes: 200)
        try Data(count: 999).write(to: dir.appendingPathComponent("my own video.mp4"))
        let all = store.all()
        XCTAssertEqual(all.map(\.title), ["Rolled Symphony", "Rolled Ruby"])
        XCTAssertEqual(store.totalBytes(), 300, "a file SiverSol did not make is not counted")
    }

    func testTrimDeletesOldestFirstUntilUnderTheCap() throws {
        var store = MomentsStore(directory: dir)
        store.capBytes = 1000
        let old = try add(store, "Rolled Ruby", minutesAgo: 90, bytes: 400)
        let mid = try add(store, "Rolled Wind", minutesAgo: 60, bytes: 400)
        let new = try add(store, "Rolled Symphony", minutesAgo: 1, bytes: 400)
        let other = dir.appendingPathComponent("my own video.mp4")
        try Data(count: 5000).write(to: other)

        let gone = store.trim()
        XCTAssertEqual(gone.map(\.id), [old.id], "one clip is enough to get back under the cap")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.videoURL(old.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.noteURL(old.id).path), "the note goes with its clip")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.thumbnailURL(old.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.videoURL(mid.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.videoURL(new.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "a file SiverSol did not make is never deleted")
        XCTAssertLessThanOrEqual(store.totalBytes(), 1000)
    }

    func testTrimNeverDeletesTheClipJustMade() {
        let a = Moment(id: "Moment-a", kind: .roll, title: "a", detail: "", biome: nil, at: t0, seconds: 1, bytes: 900, eventId: nil)
        let b = Moment(id: "Moment-b", kind: .roll, title: "b", detail: "", biome: nil, at: t0.addingTimeInterval(10), seconds: 1, bytes: 900, eventId: nil)
        XCTAssertEqual(MomentsStore.toTrim([a, b], capBytes: 1000).map(\.id), ["Moment-a"])
        XCTAssertEqual(MomentsStore.toTrim([a], capBytes: 100, keeping: "Moment-a"), [], "a single clip larger than the cap is kept")
        XCTAssertEqual(MomentsStore.toTrim([a, b], capBytes: 5000), [], "under the cap nothing goes")
    }

    func testDeleteOnlyTouchesOurOwnNames() throws {
        let store = MomentsStore(directory: dir)
        let other = dir.appendingPathComponent("holiday.mp4")
        try Data(count: 5).write(to: other)
        store.delete("holiday")
        store.delete("../holiday")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testALinkOutOfTheFolderIsNotFollowed() throws {
        let store = MomentsStore(directory: dir)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("siversol-outside-\(UUID().uuidString).mp4")
        try Data(count: 50).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: store.videoURL("Moment-20260101-000000-link"), withDestinationURL: outside)
        XCTAssertTrue(store.all().isEmpty)
    }

    func testBitrateFitsTheUploadLimit() {
        XCTAssertEqual(MomentsStore.bitrate(seconds: 12, maxBytes: nil), 3_500_000)
        XCTAssertEqual(MomentsStore.bitrate(seconds: 12, maxBytes: 10_000_000), 3_500_000, "a short clip can use the full rate")
        let long = MomentsStore.bitrate(seconds: 34.23, maxBytes: 10_000_000)
        XCTAssertLessThan(long, 3_500_000)
        XCTAssertLessThanOrEqual(Double(long) * 34.23 / 8, 10_000_000 * 0.9 + 1)
        XCTAssertEqual(MomentsStore.bitrate(seconds: 600, maxBytes: 10_000_000), 600_000, "never below a watchable floor")
    }

    func testVideoSize() {
        let hd = MomentsStore.videoSize(windowPixels: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(hd.width, 1280); XCTAssertEqual(hd.height, 720)
        let small = MomentsStore.videoSize(windowPixels: CGSize(width: 801, height: 601))
        XCTAssertEqual(small.width, 800); XCTAssertEqual(small.height, 600)
    }
}
