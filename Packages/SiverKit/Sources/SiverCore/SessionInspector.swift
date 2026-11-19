import Foundation

/// What the log says about the current play session, with nothing personal in it (Session Inspector).
public struct SessionInfo: Equatable, Sendable, Codable {
    public var joinedAt: Date?
    public var joinKind: JoinKind?
    /// First 8 characters of the server instance id. Enough to tell servers apart, not enough to join one.
    public var shortJobId: String?
    /// Server changes made by the game itself (its timed move to a fresh reserved server).
    public var teleports = 0
    /// Server joins seen since SiverSol started watching, teleports included.
    public var joins = 0
    public var clientVersion: String?
    public var offeredVersion: String?
    public var updateRequired: Bool?
    public var dailyResetAt: Date?
    public var windowWidth: Int?
    public var windowHeight: Int?
    public var lastHeartbeatAt: Date?
    public var inPlaySession = false

    public init() {}

    /// A newer client is waiting: the server offers a different version than the one running, or says so outright.
    public var updatePending: Bool {
        if updateRequired == true { return true }
        if let offered = offeredVersion, let running = clientVersion { return offered != running }
        return false
    }
}

/// One line of the Log Lab feed: a parsed signal, described from its fields. Never raw log text.
public struct LogLabEntry: Identifiable, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable { case presence, roll, heartbeat, join, session, reset, update, window, disconnect, merchant, unknown }
    public let id: Int
    public let at: Date
    public let kind: Kind
    public let summary: String
}

/// Folds log events into `SessionInfo` and into redacted Log Lab entries. Pure value type.
public struct SessionInspector: Sendable {
    public private(set) var info = SessionInfo()
    /// Rich Presence states and game event ids that are not one of the known shapes: "seen, not used yet".
    public private(set) var unknown: [String: Int] = [:]
    private var pendingKind: JoinKind?
    private var nextId = 0

    public init() {}

    public mutating func setClientVersion(_ version: String?) { info.clientVersion = version }

    /// Update the session facts and return how the Log Lab should show this event (nil = not shown).
    @discardableResult
    public mutating func note(_ event: LogEvent) -> LogLabEntry? {
        var kind = LogLabEntry.Kind.unknown
        var summary = ""
        switch event {
        case .presence(let p):
            kind = .presence
            let state: String
            switch p.state {
            case .mainMenu?: state = "on the title screen"
            case .equipped(let name?)?: state = "equipped \(name)"
            case .equipped(nil)?: state = "no aura equipped"
            case .other(let raw)?:
                // Unknown state text is counted by length only: it could contain anything.
                unknown["presence state (\(raw.count) chars)", default: 0] += 1
                state = "unknown state"
            case nil: state = "no state"
            }
            summary = "biome \(p.biome?.key.value ?? "unchanged") · \(state)"
        case .joined(let jobId, let placeId, let at):
            kind = .join
            info.joinedAt = at
            info.shortJobId = String(jobId.prefix(8))
            info.joinKind = pendingKind ?? .publicServer
            info.joins += 1
            pendingKind = nil
            summary = "joined a \(info.joinKind!.label) · server \(info.shortJobId!) · \(placeId == SiverSol.solsRNGPlaceId ? "Sol's RNG" : "another experience")"
        case .disconnected(let reason, let k, _):
            kind = .disconnect
            summary = "disconnect line (\(k))" + (reason.map { ", reason \($0)" } ?? "")
        case .merchant(let name, _):
            kind = .merchant
            summary = "\(name) arrived"
        case .signal(let signal, let at):
            switch signal {
            case .gameEvent(let e):
                kind = .roll
                if let aura = e.rolledAuraName {
                    summary = "rolled \(aura)" + (e.captureDelayMs.map { String(format: " · clip at %.1f s", Double($0) / 1000) } ?? "")
                        + (e.durationS.map { String(format: " · cutscene %.1f s", $0) } ?? "")
                } else {
                    unknown["game event \(e.eventId)", default: 0] += 1
                    summary = "game event \(e.eventId) (not used yet)"
                }
            case .heartbeat:
                kind = .heartbeat
                info.lastHeartbeatAt = at
                summary = "client heartbeat"
            case .dailyReset(let date):
                kind = .reset
                info.dailyResetAt = date
                summary = "daily reset at \(date.formatted(.iso8601))"
            case .joinRequest(let k):
                kind = .join
                pendingKind = k
                summary = "asking to join a \(k.label)"
            case .session(let s):
                kind = .session
                switch s {
                case .enteredPlay: info.inPlaySession = true; summary = "entered the play session"
                case .teleported: info.teleports += 1; summary = "teleported to another server"
                case .tearingDown: info.inPlaySession = false; summary = "play session ended"
                }
            case .updateRequired(let required):
                kind = .update
                info.updateRequired = required
                summary = required ? "a client update is required" : "no client update required"
            case .offeredVersion(let v):
                kind = .update
                info.offeredVersion = v
                summary = "update server offers \(v)"
            case .windowSize(let w, let h):
                kind = .window
                info.windowWidth = w; info.windowHeight = h
                summary = "render size \(w)×\(h)"
            }
        }
        nextId += 1
        return LogLabEntry(id: nextId, at: event.timestamp, kind: kind, summary: summary)
    }
}
