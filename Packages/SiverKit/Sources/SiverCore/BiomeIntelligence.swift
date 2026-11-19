import Foundation

/// Biome Intelligence: what the timeline says about each biome, computed from recorded events only.
public struct BiomeIntel: Equatable, Sendable {
    public struct Stat: Equatable, Sendable, Identifiable {
        public var key: String
        public var count = 0
        public var totalSeconds: TimeInterval = 0
        public var longestSeconds: TimeInterval = 0
        public var lastStartedAt: Date?
        /// Average time from one start of this biome to its next start. nil with fewer than two starts.
        public var averageGapSeconds: TimeInterval?
        public var id: String { key }
    }

    public var stats: [Stat] = []
    /// The longest unbroken stretch of NORMAL (a "drought" of anything interesting).
    public var longestNormalSeconds: TimeInterval = 0
    /// How long the current NORMAL has lasted, if NORMAL is running now.
    public var currentNormalSeconds: TimeInterval?
    /// The same special biome several times in a row (only NORMAL in between), most recent run.
    public var streakKey: String?
    public var streakCount = 0
    public var watchedSeconds: TimeInterval = 0

    public func stat(_ key: String) -> Stat? { stats.first { $0.key == key } }

    public static func compute(events: [SiverEvent], now: Date = Date()) -> BiomeIntel {
        var by: [String: Stat] = [:]
        var starts: [String: [Date]] = [:]
        var open: BiomeStarted?
        var intel = BiomeIntel()
        var specials: [String] = []

        func close(_ key: String, from: Date, to: Date) {
            let d = max(0, to.timeIntervalSince(from))
            by[key, default: Stat(key: key)].totalSeconds += d
            by[key]!.longestSeconds = max(by[key]!.longestSeconds, d)
            if key == "NORMAL" { intel.longestNormalSeconds = max(intel.longestNormalSeconds, d) }
        }

        for event in events.sorted(by: { $0.at < $1.at }) {
            switch event {
            case .biomeStarted(let s):
                let key = s.biome.key.value
                by[key, default: Stat(key: key)].count += 1
                by[key]!.lastStartedAt = s.at
                starts[key, default: []].append(s.at)
                if key != "NORMAL" { specials.append(key) }
                open = s
            case .biomeEnded(let e):
                close(e.biome.key.value, from: e.startedAt, to: e.at)
                if open?.id == e.startedEventId { open = nil }
            default: break
            }
        }
        if let o = open {
            close(o.biome.key.value, from: o.at, to: now)
            if o.biome.key.value == "NORMAL" { intel.currentNormalSeconds = max(0, now.timeIntervalSince(o.at)) }
        }
        for (key, times) in starts where times.count >= 2 {
            by[key]?.averageGapSeconds = times.last!.timeIntervalSince(times.first!) / Double(times.count - 1)
        }
        if let last = specials.last {
            intel.streakKey = last
            intel.streakCount = specials.reversed().prefix { $0 == last }.count
        }
        intel.stats = by.values.sorted { $0.totalSeconds != $1.totalSeconds ? $0.totalSeconds > $1.totalSeconds : $0.key < $1.key }
        intel.watchedSeconds = intel.stats.reduce(0) { $0 + $1.totalSeconds }
        return intel
    }
}

/// Export of the recorded history (CSV for spreadsheets, JSON for everything else). Holds no log text and no ids
/// beyond the first 8 characters of a server instance id.
public enum TimelineExport {
    static func field(_ s: String) -> String {
        s.contains(",") || s.contains("\"") || s.contains("\n") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    static func row(_ event: SiverEvent) -> [String] {
        let iso = event.at.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        switch event {
        case .biomeStarted(let e): return [iso, "biome_started", e.biome.key.value, "", e.wasRunning ? "already running" : "", String((e.serverJobId ?? "").prefix(8))]
        case .biomeEnded(let e): return [iso, "biome_ended", e.biome.key.value, String(format: "%.0f", e.duration), e.reason.rawValue, String((e.serverJobId ?? "").prefix(8))]
        case .auraEquipped(let e): return [iso, "aura_equipped", e.internalName, "", e.initial ? "restored on join" : "", String((e.serverJobId ?? "").prefix(8))]
        case .auraRolled(let e): return [iso, "aura_rolled", e.name, e.durationS.map { String(format: "%.0f", $0) } ?? "", e.biome?.key.value ?? "", ""]
        case .merchantArrived(let e): return [iso, "merchant", e.name, "", e.biome?.key.value ?? "", ""]
        case .serverJoined(let e): return [iso, "server_joined", "", "", "", String(e.jobId.prefix(8))]
        case .disconnected(let e): return [iso, "disconnect", e.kind, "", e.reason.map(String.init) ?? "", ""]
        case .newBiomeSeen(let e): return [iso, "new_biome", e.biome.key.value, "", "", ""]
        }
    }

    public static func csv(_ events: [SiverEvent]) -> String {
        (["time_utc,event,name,seconds,note,server"] + events.map { row($0).map(field).joined(separator: ",") }).joined(separator: "\n") + "\n"
    }

    public static func json(_ events: [SiverEvent]) -> Data {
        let rows = events.map { e -> [String: String] in
            let r = row(e)
            var d = ["time_utc": r[0], "event": r[1]]
            if !r[2].isEmpty { d["name"] = r[2] }
            if !r[3].isEmpty { d["seconds"] = r[3] }
            if !r[4].isEmpty { d["note"] = r[4] }
            if !r[5].isEmpty { d["server"] = r[5] }
            return d
        }
        return (try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])) ?? Data("[]".utf8)
    }
}
