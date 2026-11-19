import Foundation
import SiverCore

/// What an outbox item will do when it reaches the front. Rendering happens at send time, so an Ended
/// message can link to a Started message that was itself still queued when the Ended was created.
public enum OutboxJob: Codable, Equatable, Sendable {
    /// Render the event with the route's profile and POST it.
    case event(SiverEvent, origin: EventOrigin)
    /// PATCH this route's Started message for the biome that just ended (Rich only).
    case patchStarted(BiomeEnded, origin: EventOrigin)
    /// A ready-made message (build log, test, simulated…). `files` are paths read at send time.
    case message(DiscordMessage, origin: EventOrigin, files: [String])
    /// Post or edit the "Biome feed" message for one hour (Digest), from what has been gathered for it so far.
    case digest(hour: String, origin: EventOrigin)
}

public struct OutboxItem: Codable, Equatable, Identifiable, Sendable {
    /// Dedupe key: `<route>|<event id>|<action>`.
    public var id: String
    public var route: String
    /// Rare-biome lane: sent before anything else waiting on the same route.
    public var priority: Bool
    public var createdAt: Date
    public var attempts: Int
    public var job: OutboxJob
    /// Ledger key to store the sent message under (for links and later edits).
    public var ledgerKey: String?
    /// Files to attach to an event post (proof shots). The first PNG becomes the embed image.
    public var files: [String]?

    public init(id: String, route: String, priority: Bool = false, createdAt: Date = Date(), job: OutboxJob, ledgerKey: String? = nil, files: [String]? = nil) {
        self.id = id; self.route = route; self.priority = priority; self.createdAt = createdAt
        self.attempts = 0; self.job = job; self.ledgerKey = ledgerKey; self.files = files
    }
}

extension OutboxItem {
    /// For a live event job: the time of the log line behind it (to measure log-to-Discord latency).
    var liveEventAt: Date? {
        if case .event(let e, let origin) = job, origin == .live { return e.at }
        return nil
    }
}

/// Persistent queue + sent-message ledger in Application Support. Survives quits, sleep and being offline.
/// Thread-safe. Files: `outbox.jsonl` (one item per line) and `ledger.json`.
public final class OutboxStore: @unchecked Sendable {
    private struct Ledger: Codable {
        var messages: [String: MessageRef] = [:]
        var order: [String] = []
        var done: [String] = []
        var meta: [String: String] = [:]
    }

    private let lock = NSLock()
    private var items: [OutboxItem] = []
    private var ledger = Ledger()
    private var doneSet: Set<String> = []
    private let queueURL: URL?
    private let ledgerURL: URL?
    static let maxLedger = 4000

    /// `directory == nil` keeps everything in memory (tests, dry runs).
    public init(directory: URL?) {
        queueURL = directory?.appendingPathComponent("outbox.jsonl")
        ledgerURL = directory?.appendingPathComponent("ledger.json")
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        if let queueURL, let text = try? String(contentsOf: queueURL, encoding: .utf8) {
            items = text.split(separator: "\n").compactMap { try? Self.decoder.decode(OutboxItem.self, from: Data($0.utf8)) }
        }
        if let ledgerURL, let data = try? Data(contentsOf: ledgerURL), let l = try? Self.decoder.decode(Ledger.self, from: data) {
            ledger = l
            doneSet = Set(l.done)
        }
    }

    public static var defaultDirectory: URL { SiverSol.supportDirectory.appendingPathComponent("outbox", isDirectory: true) }

    public var depth: Int { lock.lock(); defer { lock.unlock() }; return items.count }
    public func depth(route: String) -> Int { lock.lock(); defer { lock.unlock() }; return items.filter { $0.route == route }.count }
    public var all: [OutboxItem] { lock.lock(); defer { lock.unlock() }; return items }

    /// Add an item unless the same id is already queued or was already delivered. Returns true when added.
    @discardableResult
    public func enqueue(_ item: OutboxItem) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !doneSet.contains(item.id), !items.contains(where: { $0.id == item.id }) else { return false }
        items.append(item)
        saveQueue()
        return true
    }

    /// Next item for a route: the oldest priority item if any, else the oldest item.
    public func next(route: String) -> OutboxItem? {
        lock.lock(); defer { lock.unlock() }
        let mine = items.filter { $0.route == route }
        return mine.first(where: \.priority) ?? mine.first
    }

    /// Delivered (or deliberately dropped): remove it and remember the id so it is never sent twice.
    public func complete(_ id: String, ref: MessageRef? = nil, ledgerKey: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        items.removeAll { $0.id == id }
        doneSet.insert(id)
        ledger.done.append(id)
        if let ref, let ledgerKey {
            if ledger.messages[ledgerKey] == nil { ledger.order.append(ledgerKey) }
            ledger.messages[ledgerKey] = ref
        }
        trim()
        saveQueue(); saveLedger()
    }

    public func noteAttempt(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].attempts += 1; saveQueue() }
    }

    public func ref(_ ledgerKey: String) -> MessageRef? {
        lock.lock(); defer { lock.unlock() }
        return ledger.messages[ledgerKey]
    }

    public func setRef(_ ledgerKey: String, _ ref: MessageRef?) {
        lock.lock(); defer { lock.unlock() }
        if ref != nil, ledger.messages[ledgerKey] == nil { ledger.order.append(ledgerKey) }
        ledger.messages[ledgerKey] = ref
        if ref == nil { ledger.order.removeAll { $0 == ledgerKey } }
        saveLedger()
    }

    /// Small string facts that must survive restarts (guild id per route, live card id, session thread).
    public func meta(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return ledger.meta[key] }
    public func setMeta(_ key: String, _ value: String?) {
        lock.lock(); defer { lock.unlock() }
        ledger.meta[key] = value
        saveLedger()
    }

    public static func ledgerKey(route: String, eventId: String) -> String { "\(route)|\(eventId)" }

    private func trim() {
        if ledger.order.count > Self.maxLedger {
            for key in ledger.order.prefix(ledger.order.count - Self.maxLedger) { ledger.messages[key] = nil }
            ledger.order.removeFirst(ledger.order.count - Self.maxLedger)
        }
        if ledger.done.count > Self.maxLedger {
            for id in ledger.done.prefix(ledger.done.count - Self.maxLedger) { doneSet.remove(id) }
            ledger.done.removeFirst(ledger.done.count - Self.maxLedger)
        }
    }

    private func saveQueue() {
        guard let queueURL else { return }
        let lines = items.compactMap { try? Self.encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        try? Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).utf8).write(to: queueURL, options: .atomic)
    }

    private func saveLedger() {
        guard let ledgerURL, let data = try? Self.encoder.encode(ledger) else { return }
        try? data.write(to: ledgerURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .millisecondsSince1970; e.outputFormatting = [.sortedKeys]; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970; return d }()
}
