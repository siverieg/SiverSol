import Foundation

/// What `data.state` in a Rich Presence line means (three shapes verified on Mac, see docs/VERIFIED.md).
public enum PresenceState: Equatable, Sendable {
    /// `In Main Menu`: game loaded, start menu still showing.
    case mainMenu
    /// `Equipped "<InternalName>"`, or `Equipped _None_` (nil).
    case equipped(String?)
    case other(String)

    public init(raw: String) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s == "In Main Menu" { self = .mainMenu; return }
        if s.hasPrefix("Equipped") {
            var name = String(s.dropFirst("Equipped".count)).trimmingCharacters(in: .whitespaces)
            if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") {
                name = String(name.dropFirst().dropLast())
            }
            self = (name.isEmpty || name == "_None_") ? .equipped(nil) : .equipped(name)
            return
        }
        self = .other(raw)
    }
}

/// One `[BloxstrapRPC] SetRichPresence` line.
public struct RichPresence: Equatable, Sendable {
    public let timestamp: Date
    /// nil when the message carried no `largeImage.hoverText` (a partial update: keep the current biome).
    public let biome: BiomeRef?
    public let stateRaw: String?
    public var state: PresenceState? { stateRaw.map(PresenceState.init(raw:)) }

    public init(timestamp: Date, biome: BiomeRef?, stateRaw: String?) {
        self.timestamp = timestamp; self.biome = biome; self.stateRaw = stateRaw
    }
}

/// A game event the experience reports to Roblox (`[_MAPIEvent][v1/event/invoke] <base64 JSON>`).
public struct GameEvent: Equatable, Sendable, Codable {
    public var eventId: String
    public var eventName: String
    /// When the game saves its own clip: the cutscene's best moment, in milliseconds after the event.
    public var captureDelayMs: Int?
    /// Cutscene length in seconds.
    public var durationS: Double?

    public init(eventId: String, eventName: String, captureDelayMs: Int? = nil, durationS: Double? = nil) {
        self.eventId = eventId; self.eventName = eventName; self.captureDelayMs = captureDelayMs; self.durationS = durationS
    }

    /// `Aura Rolled: "Symphony"` -> `Symphony`
    public var rolledAuraName: String? {
        guard eventId == "aura_rolled" else { return nil }
        if let m = eventName.firstMatch(of: #/"(.+)"/#) { return String(m.1) }
        let rest = eventName.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return rest.isEmpty ? nil : rest
    }
}

public enum JoinKind: String, Codable, Sendable {
    case privateServer, reserved, publicServer
    public var label: String {
        switch self {
        case .privateServer: return "private server"
        case .reserved: return "reserved server (teleport)"
        case .publicServer: return "public server"
        }
    }
}

public enum SessionState: String, Codable, Sendable { case enteredPlay, teleported, tearingDown }

/// Facts from the log beyond biome, aura and joins. See docs/LOG_SIGNALS.md for the exact lines.
public enum LogSignal: Equatable, Sendable {
    case gameEvent(GameEvent)
    /// `Settings Date timestamp is N`, every 120 s while the client is alive.
    case heartbeat
    case dailyReset(Date)
    case joinRequest(JoinKind)
    case session(SessionState)
    case updateRequired(Bool)
    case offeredVersion(String)
    case windowSize(width: Int, height: Int)
}

/// A log line SiverSol cares about. Everything else parses to nil.
public enum LogEvent: Equatable, Sendable {
    case presence(RichPresence)
    case joined(jobId: String, placeId: Int64, at: Date)
    case disconnected(reason: Int?, kind: String, at: Date)
    /// `[Merchant]: Mari has arrived on the island...` if the game ever writes its chat notice to the log.
    case merchant(name: String, at: Date)
    case signal(LogSignal, at: Date)

    public var timestamp: Date {
        switch self {
        case .presence(let p): return p.timestamp
        case .joined(_, _, let at): return at
        case .disconnected(_, _, let at): return at
        case .merchant(_, let at): return at
        case .signal(_, let at): return at
        }
    }
}

public enum LogLineParser {
    public static let rpcMarker = "[BloxstrapRPC]"

    /// Parse one complete log line. `fallbackDate` is used when the line has no leading ISO8601 stamp.
    public static func parse(_ line: String, fallbackDate: Date = Date()) -> LogEvent? {
        if let r = line.range(of: rpcMarker) {
            return parsePresence(line, after: r.upperBound, fallbackDate: fallbackDate).map(LogEvent.presence)
        }
        if line.contains("Joining game") { return parseJoin(line, fallbackDate: fallbackDate) }
        if let signal = parseSignal(line) { return .signal(signal, at: timestamp(of: line) ?? fallbackDate) }
        if line.contains("has arrived"), let name = merchantName(in: line) {
            return .merchant(name: name, at: timestamp(of: line) ?? fallbackDate)
        }
        if line.contains("isconnect") || line.contains("Connection lost") {
            return parseDisconnect(line, fallbackDate: fallbackDate)
        }
        return nil
    }

    // MARK: timestamp

    /// Leading `2026-11-18T12:13:19.517Z,` (UTC) of a Roblox log line.
    public static func timestamp(of line: String) -> Date? {
        guard let comma = line.firstIndex(of: ",") else { return nil }
        let s = line[..<comma]
        guard s.count >= 20, s.count <= 35, s.last == "Z" else { return nil }
        let text = String(s)
        if let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return d }
        return try? Date.ISO8601FormatStyle().parse(text)
    }

    // MARK: rich presence

    private struct RPCMessage: Decodable {
        let command: String?
        let data: Body?
        struct Body: Decodable {
            let state: String?
            let largeImage: Image?
        }
        struct Image: Decodable {
            let hoverText: String?
            let assetId: Int64?
            enum CodingKeys: String, CodingKey { case hoverText, assetId }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                hoverText = try? c.decodeIfPresent(String.self, forKey: .hoverText)
                if let n = try? c.decodeIfPresent(Int64.self, forKey: .assetId) {
                    assetId = n
                } else if let s = try? c.decodeIfPresent(String.self, forKey: .assetId) {
                    assetId = Int64(s)
                } else {
                    assetId = nil
                }
            }
        }
    }

    private static func parsePresence(_ line: String, after idx: String.Index, fallbackDate: Date) -> RichPresence? {
        guard let json = firstJSONObject(in: line[idx...]),
              let msg = try? JSONDecoder().decode(RPCMessage.self, from: Data(json.utf8)),
              msg.command == "SetRichPresence", let data = msg.data
        else { return nil }
        var biome: BiomeRef?
        if let text = data.largeImage?.hoverText, !BiomeKey(text).isEmpty {
            biome = BiomeRef(raw: text, assetId: data.largeImage?.assetId)
        }
        if biome == nil && data.state == nil { return nil }
        return RichPresence(timestamp: timestamp(of: line) ?? fallbackDate, biome: biome, stateRaw: data.state)
    }

    /// First balanced `{…}` in the text, honoring string literals and escapes, so trailing junk can't break decoding.
    static func firstJSONObject(in text: Substring) -> Substring? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        var i = start
        while i < text.endIndex {
            let ch = text[i]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 { return text[start...i] }
            }
            i = text.index(after: i)
        }
        return nil
    }

    // MARK: other signals

    public static let gameEventMarker = "[_MAPIEvent]"

    static func parseSignal(_ line: String) -> LogSignal? {
        if let r = line.range(of: gameEventMarker) {
            let payload = line[r.upperBound...].split(separator: " ").last.map(String.init) ?? ""
            return decodeGameEvent(base64: payload).map(LogSignal.gameEvent)
        }
        if line.contains("Settings Date timestamp is") { return .heartbeat }
        if let m = line.firstMatch(of: #/daily reset time (\d{9,11})/#), let t = TimeInterval(m.1) {
            return .dailyReset(Date(timeIntervalSince1970: t))
        }
        if line.contains("GameJoinUtil::joinGamePostPrivateServer") { return .joinRequest(.privateServer) }
        if line.contains("GameJoinUtil::initiateTeleportToReservedServer") { return .joinRequest(.reserved) }
        if line.contains("[FLog::SessionTransitionFSM]") {
            if line.contains("Entered play session") { return .session(.enteredPlay) }
            if line.contains("Teleported") { return .session(.teleported) }
            if line.contains("Tearing down") { return .session(.tearingDown) }
            return nil
        }
        if let m = line.firstMatch(of: #/updateRequired (TRUE|FALSE)/#) { return .updateRequired(m.1 == "TRUE") }
        if line.contains("[FLog::UpdateController] version response:"),
           let m = line.firstMatch(of: #/"version":"([0-9.]{3,40})"/#) { return .offeredVersion(String(m.1)) }
        if let m = line.firstMatch(of: #/resizing main targets to (\d{2,5})x(\d{2,5})/#), let w = Int(m.1), let h = Int(m.2) {
            return .windowSize(width: w, height: h)
        }
        return nil
    }

    private struct MAPIPayload: Decodable {
        struct Event: Decodable {
            struct Clip: Decodable { let captureDelayMs: Double?; let duration: Double? }
            let eventId: String?
            let eventName: String?
            let clipOptions: Clip?
        }
        let gameEvent: Event?
    }

    /// Decode the game event payload. Tolerant: missing padding, URL-safe alphabet, missing fields.
    public static func decodeGameEvent(base64 raw: String) -> GameEvent? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard text.count >= 8, text.count <= 20_000 else { return nil }
        while text.count % 4 != 0 { text.append("=") }
        guard let data = Data(base64Encoded: text, options: [.ignoreUnknownCharacters]),
              let payload = try? JSONDecoder().decode(MAPIPayload.self, from: data),
              let event = payload.gameEvent, let id = event.eventId, !id.isEmpty else { return nil }
        let delay = event.clipOptions?.captureDelayMs.flatMap { $0 >= 0 && $0 < 600_000 ? Int($0) : nil }
        let duration = event.clipOptions?.duration.flatMap { $0 > 0 && $0 < 600 ? $0 : nil }
        return GameEvent(eventId: String(id.prefix(64)), eventName: String((event.eventName ?? "").prefix(200)),
                         captureDelayMs: delay, durationS: duration)
    }

    // MARK: merchants

    public static let merchants = ["Mari", "Jester", "Rin"]

    /// The merchant named in an arrival notice. Works on log lines and on OCR text, which may drop brackets or
    /// misread a letter: the name must be followed by "has arrived", and a "Merchant" tag or a known name is required.
    public static func merchantName(in text: String) -> String? {
        guard let m = text.firstMatch(of: #/(?i)([A-Za-z]{3,12})\s+has\s+arrived/#) else { return nil }
        let word = String(m.1)
        if let known = merchants.first(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) { return known }
        // Text recognition sometimes gets one letter wrong ("Marf" for "Mari"). One letter off a known name is that name;
        // otherwise each misreading would count as a new merchant and be announced again.
        if let near = merchants.first(where: { oneLetterApart($0.lowercased(), word.lowercased()) }) { return near }
        // An unknown name counts only with the game's own tag in front (a new merchant added by an update).
        return text.range(of: "[Merchant]", options: .caseInsensitive) != nil ? word.prefix(1).uppercased() + word.dropFirst().lowercased() : nil
    }

    /// True when the two words differ by exactly one substituted, missing or extra letter.
    static func oneLetterApart(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        if x.count == y.count { return zip(x, y).filter { $0 != $1 }.count == 1 }
        guard abs(x.count - y.count) == 1 else { return false }
        let (long, short) = x.count > y.count ? (x, y) : (y, x)
        return long.indices.contains { i in var l = long; l.remove(at: i); return l == short }
    }

    // MARK: join / disconnect

    private static func parseJoin(_ line: String, fallbackDate: Date) -> LogEvent? {
        guard let m = line.firstMatch(of: #/! Joining game '([^']+)' place (\d+)/#),
              let place = Int64(m.2) else { return nil }
        return .joined(jobId: String(m.1), placeId: place, at: timestamp(of: line) ?? fallbackDate)
    }

    /// Disconnect wording comes from other macros and is not yet confirmed on Mac (docs/VERIFIED.md).
    /// `SignalRCoreError … Disconnected - stop() called` shows up in every healthy launch, so it is excluded.
    private static func parseDisconnect(_ line: String, fallbackDate: Date) -> LogEvent? {
        if line.contains("SignalR") || line.contains("FaceAnimatorService") { return nil }
        let at = timestamp(of: line) ?? fallbackDate
        if let m = line.firstMatch(of: #/Disconnect reason received: (\d+)/#) {
            return .disconnected(reason: Int(m.1), kind: "reason-received", at: at)
        }
        if let m = line.firstMatch(of: #/Disconnection Notification\. Reason: (\d+)/#) {
            return .disconnected(reason: Int(m.1), kind: "notification", at: at)
        }
        if let m = line.firstMatch(of: #/Sending disconnect with reason: (\d+)/#) {
            return .disconnected(reason: Int(m.1), kind: "sending", at: at)
        }
        if line.contains("Connection lost") {
            return .disconnected(reason: nil, kind: "connection-lost", at: at)
        }
        return nil
    }
}
