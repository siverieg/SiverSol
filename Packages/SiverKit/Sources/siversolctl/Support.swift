import Foundation
import SiverCore

/// Minimal argument reader: positionals, `--flag`, `--key value`.
struct Args {
    private(set) var positionals: [String] = []
    private var options: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ raw: [String], valueOptions: Set<String>) {
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if valueOptions.contains(name), i + 1 < raw.count {
                    options[name] = raw[i + 1]; i += 1
                } else {
                    flags.insert(name)
                }
            } else {
                positionals.append(a)
            }
            i += 1
        }
    }

    func flag(_ name: String) -> Bool { flags.contains(name) }
    func value(_ name: String) -> String? { options[name] }
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let clock: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "HH:mm:ss.SSS'Z'"
    return f
}()

func duration(_ t: TimeInterval) -> String {
    let s = Int(t.rounded())
    if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m \(s % 60)s" }
    return s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
}

func shortJob(_ id: String?) -> String { id.map { String($0.prefix(8)) } ?? "?" }

/// One human-readable line per event. Never prints raw log text.
func describe(_ event: SiverEvent, catalog: BiomeCatalog) -> String {
    let t = clock.string(from: event.at)
    switch event {
    case .biomeStarted(let e):
        let info = catalog.info(for: e.biome.key)
        var notes: [String] = []
        if let p = e.previous { notes.append("after \(p)") }
        if e.wasRunning { notes.append("already running") }
        if !e.observedStart { notes.append("start not observed") }
        if let d = info.durationS, e.observedStart { notes.append("usually \(duration(TimeInterval(d)))") }
        if info.isRare { notes.append("RARE") }
        return "\(t)  BIOME START  \(info.emoji) \(e.biome.key)" + (notes.isEmpty ? "" : "  (\(notes.joined(separator: ", ")))")
    case .biomeEnded(let e):
        let why = e.reason == .changed ? "" : "  [\(e.reason.rawValue): may still be running on the server]"
        return "\(t)  BIOME END    \(catalog.info(for: e.biome.key).emoji) \(e.biome.key)  lasted \(duration(e.duration))\(e.startObserved ? "" : "+")" + why
    case .auraEquipped(let e):
        return "\(t)  AURA         ✨ \(e.internalName)\(e.initial ? "  (restored on join)" : "")  in \(e.biome?.key.value ?? "?")"
    case .serverJoined(let e):
        return "\(t)  JOINED       server \(shortJob(e.jobId)) place \(e.placeId)\(e.placeId == SiverSol.solsRNGPlaceId ? " (Sol's RNG)" : " (NOT Sol's RNG)")"
    case .disconnected(let e):
        return "\(t)  DISCONNECT   \(e.kind) reason=\(e.reason.map(String.init) ?? "?")"
    case .auraRolled(let e):
        return "\(t)  AURA ROLL    🎉 \(e.name)  clip at \(e.captureDelayMs.map { String(format: "%.1f s", Double($0) / 1000) } ?? "?"), cutscene \(duration(e.cutsceneSeconds))  in \(e.biome?.key.value ?? "?")"
    case .merchantArrived(let e):
        return "\(t)  MERCHANT     🛒 \(e.name) arrived (seen in the \(e.source ?? "log"))  in \(e.biome?.key.value ?? "?")"
    case .newBiomeSeen(let e):
        return "\(t)  NEW BIOME    🆕 \(e.biome.raw) (assetId \(e.biome.assetId.map(String.init) ?? "?"))"
    }
}

func loadCatalog(learn: Bool) -> BiomeCatalog {
    do { return try BiomeCatalog.bundled(learnedURL: learn ? BiomeCatalog.defaultLearnedURL : nil) }
    catch { fail("cannot load biomes.json: \(error)") }
}

/// Run a whole log through a fresh tracker. Returns every event in order.
func eventsInLog(_ text: String, sessionId: String) -> [SiverEvent] {
    var tracker = BiomeTracker(sessionId: sessionId)
    var events: [SiverEvent] = []
    for line in text.split(whereSeparator: \.isNewline) {
        if let e = LogLineParser.parse(String(line)) { events += tracker.ingest(e) }
    }
    return events
}

/// Independent list of biome changes, done with plain string matching instead of the parser and tracker.
/// This is the `grep BloxstrapRPC` side of the F1 acceptance check.
func grepTransitionsTimed(_ text: String) -> [(at: String, biome: String)] {
    var out: [(String, String)] = []
    var last: String?
    for line in text.split(whereSeparator: \.isNewline) {
        if line.contains("! Joining game") { last = nil; continue }   // a new server: the next biome counts again
        guard line.contains("[BloxstrapRPC]"), !line.contains("\"state\":\"In Main Menu\""),
              let r = line.range(of: "\"largeImage\":{\"hoverText\":\"") else { continue }
        let rest = line[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { continue }
        let biome = BiomeKey.normalize(String(rest[..<end]))
        if last != biome {
            last = biome
            out.append((String(line.prefix { $0 != "," }), biome))
        }
    }
    return out
}

func grepTransitions(_ text: String) -> [String] { grepTransitionsTimed(text).map(\.biome) }
