import Foundation

/// F12 storage core: every event, once, in an append-only JSONL file per UTC day
/// (`timeline/2026-11-18.jsonl`). Counts and history are derived from it. Thread-safe.
public final class TimelineStore: @unchecked Sendable {
    private struct Day {
        var events: [SiverEvent] = []
        var ids: Set<String> = []
        var counts: [String: Int] = [:]
    }

    private let lock = NSLock()
    private let directory: URL?
    private var days: [String: Day] = [:]
    public private(set) var lastAura: (name: String, at: Date)?
    public private(set) var lastMerchant: (name: String, at: Date)?
    public private(set) var lastRoll: (name: String, at: Date)?

    /// `directory == nil` keeps everything in memory.
    public init(directory: URL?) {
        self.directory = directory
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }

    public static var defaultDirectory: URL { SiverSol.supportDirectory.appendingPathComponent("timeline", isDirectory: true) }

    public static func day(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Store an event. Returns false when this id was already recorded (restart, startup scan).
    @discardableResult
    public func record(_ event: SiverEvent) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let key = Self.day(event.at)
        load(key)
        guard days[key]?.ids.contains(event.id) == false else { return false }
        apply(event, to: key)
        if let directory, let data = try? Self.encoder.encode(event) {
            let url = directory.appendingPathComponent("\(key).jsonl")
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            if let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data + Data("\n".utf8))
                try? h.close()
            }
        }
        return true
    }

    public func events(day: String) -> [SiverEvent] {
        lock.lock(); defer { lock.unlock() }
        load(day)
        return days[day]?.events ?? []
    }

    /// Biome starts per key for the UTC day containing `date`.
    public func counts(on date: Date) -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        let key = Self.day(date)
        load(key)
        return days[key]?.counts ?? [:]
    }

    /// How many events were recorded on the UTC day containing `date`.
    public func eventCount(on date: Date) -> Int {
        lock.lock(); defer { lock.unlock() }
        let key = Self.day(date)
        load(key)
        return days[key]?.events.count ?? 0
    }

    public func count(_ biome: BiomeKey, on date: Date) -> Int { counts(on: date)[biome.value] ?? 0 }

    public var availableDays: [String] {
        guard let directory else { lock.lock(); defer { lock.unlock() }; return days.keys.sorted() }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".jsonl") }.map { String($0.dropLast(6)) }.sorted()
    }

    private func load(_ key: String) {
        guard days[key] == nil else { return }
        days[key] = Day()
        guard let directory, let text = try? String(contentsOf: directory.appendingPathComponent("\(key).jsonl"), encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            if let e = try? Self.decoder.decode(SiverEvent.self, from: Data(line.utf8)), days[key]?.ids.contains(e.id) == false {
                apply(e, to: key)
            }
        }
    }

    private func apply(_ event: SiverEvent, to key: String) {
        days[key]?.events.append(event)
        days[key]?.ids.insert(event.id)
        switch event {
        case .biomeStarted(let s): days[key]?.counts[s.biome.key.value, default: 0] += 1
        case .auraEquipped(let a):
            if !a.initial, a.at >= (lastAura?.at ?? .distantPast) { lastAura = (a.internalName, a.at) }
        case .auraRolled(let r):
            if r.at >= (lastRoll?.at ?? .distantPast) { lastRoll = (r.name, r.at) }
        case .merchantArrived(let m):
            if m.at >= (lastMerchant?.at ?? .distantPast) { lastMerchant = (m.name, m.at) }
        default: break
        }
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .millisecondsSince1970; e.outputFormatting = [.sortedKeys]; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970; return d }()
}
