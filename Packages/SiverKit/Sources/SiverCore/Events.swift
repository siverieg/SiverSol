import Foundation

public enum BiomeEndReason: String, Codable, Sendable {
    /// The game switched to another biome. The only reason that proves the biome is over.
    case changed
    /// We joined another server; the biome may still be running where we left.
    case leftServer
    /// Roblox started a new log (quit, crash or relaunch); the biome may still be running on the server.
    case sessionEnded
}

public struct BiomeStarted: Codable, Equatable, Sendable {
    public let id: String
    public let biome: BiomeRef
    /// Time of the log line that first showed this biome.
    public let at: Date
    /// True when we saw the switch happen, so `at` is the real start. False for the first biome after joining a server.
    public let observedStart: Bool
    /// True when emitted from the startup scan: the biome was already in progress when SiverSol started.
    public var wasRunning: Bool
    public let serverJobId: String?
    public let previous: BiomeKey?

    public init(id: String, biome: BiomeRef, at: Date, observedStart: Bool, wasRunning: Bool, serverJobId: String?, previous: BiomeKey?) {
        self.id = id; self.biome = biome; self.at = at; self.observedStart = observedStart
        self.wasRunning = wasRunning; self.serverJobId = serverJobId; self.previous = previous
    }
}

public struct BiomeEnded: Codable, Equatable, Sendable {
    public let id: String
    public let biome: BiomeRef
    public let startedAt: Date
    public let at: Date
    /// Event id of the matching BiomeStarted, for message interlinking.
    public let startedEventId: String
    public let startObserved: Bool
    public let reason: BiomeEndReason
    public let next: BiomeKey?
    public let serverJobId: String?
    public var duration: TimeInterval { at.timeIntervalSince(startedAt) }

    public init(id: String, biome: BiomeRef, startedAt: Date, at: Date, startedEventId: String, startObserved: Bool,
                reason: BiomeEndReason, next: BiomeKey?, serverJobId: String?) {
        self.id = id; self.biome = biome; self.startedAt = startedAt; self.at = at; self.startedEventId = startedEventId
        self.startObserved = startObserved; self.reason = reason; self.next = next; self.serverJobId = serverJobId
    }
}

public struct AuraEquipped: Codable, Equatable, Sendable {
    public let id: String
    public let internalName: String
    public let at: Date
    public let biome: BiomeRef?
    public let biomeEventId: String?
    /// True for the aura the game re-equips right after joining; not a fresh roll.
    public let initial: Bool
    public let serverJobId: String?

    public init(id: String, internalName: String, at: Date, biome: BiomeRef?, biomeEventId: String?, initial: Bool, serverJobId: String?) {
        self.id = id; self.internalName = internalName; self.at = at; self.biome = biome
        self.biomeEventId = biomeEventId; self.initial = initial; self.serverJobId = serverJobId
    }
}

public struct ServerJoined: Codable, Equatable, Sendable {
    public let id: String
    public let jobId: String
    public let placeId: Int64
    public let at: Date

    public init(id: String, jobId: String, placeId: Int64, at: Date) {
        self.id = id; self.jobId = jobId; self.placeId = placeId; self.at = at
    }
}

public struct Disconnected: Codable, Equatable, Sendable {
    public let id: String
    public let reason: Int?
    public let kind: String
    public let at: Date

    public init(id: String, reason: Int?, kind: String, at: Date) {
        self.id = id; self.reason = reason; self.kind = kind; self.at = at
    }
}

public struct NewBiomeSeen: Codable, Equatable, Sendable {
    public let id: String
    public let biome: BiomeRef
    public let at: Date

    public init(id: String, biome: BiomeRef, at: Date) { self.id = id; self.biome = biome; self.at = at }
}

/// A travelling merchant (Mari, Jester, Rin) showed up (F6).
public struct MerchantArrived: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var at: Date
    public var biome: BiomeRef?
    public var biomeEventId: String?
    /// "log" or "screen": which detector saw it.
    public var source: String?

    public init(id: String, name: String, at: Date, biome: BiomeRef? = nil, biomeEventId: String? = nil, source: String? = nil) {
        self.id = id; self.name = name; self.at = at; self.biome = biome; self.biomeEventId = biomeEventId; self.source = source
    }
}

/// The game reported a roll that plays a cutscene (`aura_rolled`). Rarer than an equip change, and certain.
public struct AuraRolled: Codable, Equatable, Sendable {
    public var id: String
    /// Display name as the game wrote it ("Symphony").
    public var name: String
    public var at: Date
    public var captureDelayMs: Int?
    public var durationS: Double?
    public var biome: BiomeRef?
    public var biomeEventId: String?

    public init(id: String, name: String, at: Date, captureDelayMs: Int? = nil, durationS: Double? = nil,
                biome: BiomeRef? = nil, biomeEventId: String? = nil) {
        self.id = id; self.name = name; self.at = at; self.captureDelayMs = captureDelayMs
        self.durationS = durationS; self.biome = biome; self.biomeEventId = biomeEventId
    }

    /// How long the cutscene plays. 35 s when the game did not say.
    public var cutsceneSeconds: TimeInterval { durationS ?? 35 }
}

/// Something Macro Studio did, for Discord and the daily report. Carries names and numbers only.
public struct MacroEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case started, finished, stopped, recorded }
    public var id: String
    public var kind: Kind
    public var name: String
    /// "manual", "every 15 min", "when WINDY starts"…
    public var trigger: String?
    public var loops = 0
    public var steps = 0
    public var durationS: Double = 0
    /// Why it stopped, in words.
    public var reason: String?
    /// True when Guardian stopped it (a screenshot is attached to the message).
    public var guardianStop = false
    public var at: Date
    /// The biome message that triggered it, for a link.
    public var biomeEventId: String?

    public init(id: String, kind: Kind, name: String, at: Date, trigger: String? = nil, biomeEventId: String? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.at = at; self.trigger = trigger; self.biomeEventId = biomeEventId
    }
}

/// One alert per merchant per 3 minutes, whichever detector fires (F6).
public struct MerchantGate: Sendable {
    public var window: TimeInterval = 180
    private var last: [String: Date] = [:]
    public init() {}

    public mutating func shouldAlert(_ name: String, at: Date) -> Bool {
        let key = name.lowercased()
        if let l = last[key], abs(at.timeIntervalSince(l)) < window { return false }
        last[key] = at
        return true
    }
}

/// Everything the radar can tell the rest of the app. Ids are stable across restarts (log session + line time),
/// so the outbox can dedupe.
public enum SiverEvent: Codable, Equatable, Sendable {
    case biomeStarted(BiomeStarted)
    case biomeEnded(BiomeEnded)
    case auraEquipped(AuraEquipped)
    case serverJoined(ServerJoined)
    case disconnected(Disconnected)
    case newBiomeSeen(NewBiomeSeen)
    case merchantArrived(MerchantArrived)
    case auraRolled(AuraRolled)

    public var id: String {
        switch self {
        case .biomeStarted(let e): return e.id
        case .biomeEnded(let e): return e.id
        case .auraEquipped(let e): return e.id
        case .serverJoined(let e): return e.id
        case .disconnected(let e): return e.id
        case .newBiomeSeen(let e): return e.id
        case .merchantArrived(let e): return e.id
        case .auraRolled(let e): return e.id
        }
    }

    public var at: Date {
        switch self {
        case .biomeStarted(let e): return e.at
        case .biomeEnded(let e): return e.at
        case .auraEquipped(let e): return e.at
        case .serverJoined(let e): return e.at
        case .disconnected(let e): return e.at
        case .newBiomeSeen(let e): return e.at
        case .merchantArrived(let e): return e.at
        case .auraRolled(let e): return e.at
        }
    }
}
