import XCTest
@testable import SiverCore

enum Fixture {
    /// Repo root, found from this file's path: Packages/SiverKit/Tests/SiverCoreTests/TestSupport.swift.
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }()

    /// Maintainer-only: personal terms that must never appear in a fixture, read from the gitignored
    /// `private/scan-terms.txt` when it exists. Public checkouts have no such file and skip the check.
    static let privateTerms: [String] = {
        guard let text = try? String(contentsOf: repoRoot.appendingPathComponent("private/scan-terms.txt"), encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("re:") }
    }()

    static func text(_ name: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("Fixtures/\(name)"), encoding: .utf8)
    }

    static func lines(_ name: String) throws -> [String] {
        try text(name).split(whereSeparator: \.isNewline).map(String.init)
    }
}

func date(_ iso: String) -> Date {
    try! Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(iso)
}

/// A Rich Presence line in the exact shape the macOS Roblox client writes.
func rpc(_ iso: String, _ biome: String, state: String = "Equipped \\\"Enchanted\\\"", tag: String = "FLog::CreatorOutput") -> String {
    "\(iso),1.000000,00000000,6,Info [\(tag)] [BloxstrapRPC] {\"command\":\"SetRichPresence\",\"data\":{\"state\":\"\(state)\",\"smallImage\":{\"hoverText\":\"Sol's RNG\",\"assetId\":131439921277342},\"largeImage\":{\"hoverText\":\"\(biome)\",\"assetId\":42}}}"
}

func joinLine(_ iso: String, job: String = "00000000-0000-4000-8000-000000000001", place: Int64 = 15_532_962_292) -> String {
    "\(iso),1.000000,00000000,6 [FLog::Output] ! Joining game '\(job)' place \(place) at 0.0.0.0"
}

extension Array where Element == SiverEvent {
    var starts: [BiomeStarted] { compactMap { if case .biomeStarted(let e) = $0 { return e }; return nil } }
    var ends: [BiomeEnded] { compactMap { if case .biomeEnded(let e) = $0 { return e }; return nil } }
    var auras: [AuraEquipped] { compactMap { if case .auraEquipped(let e) = $0 { return e }; return nil } }
    var newBiomes: [NewBiomeSeen] { compactMap { if case .newBiomeSeen(let e) = $0 { return e }; return nil } }
    var startKeys: [String] { starts.map(\.biome.key.value) }
}

func track(_ lines: [String], session: String = "t") -> (events: [SiverEvent], tracker: BiomeTracker) {
    var tracker = BiomeTracker(sessionId: session)
    var events: [SiverEvent] = []
    for l in lines { if let e = LogLineParser.parse(l) { events += tracker.ingest(e) } }
    return (events, tracker)
}

/// A throwaway folder that looks like ~/Library/Logs/Roblox.
final class TempLogs {
    let dir: URL
    init() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("siversol-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: dir) }

    func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    func write(_ name: String, _ text: String) { try! Data(text.utf8).write(to: url(name)) }

    func append(_ name: String, _ text: String) {
        let u = url(name)
        if !FileManager.default.fileExists(atPath: u.path) { FileManager.default.createFile(atPath: u.path, contents: nil) }
        let h = try! FileHandle(forWritingTo: u)
        try! h.seekToEnd(); try! h.write(contentsOf: Data(text.utf8)); try! h.close()
    }
}

func testCatalog(learnedURL: URL? = nil) -> BiomeCatalog { try! BiomeCatalog.bundled(learnedURL: learnedURL) }
