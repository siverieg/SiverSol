import Foundation

/// F1 state machine. Pure value type: feed it `LogEvent`s in log order, get `SiverEvent`s back.
/// No I/O and no clock, so fixtures replay deterministically.
public struct BiomeTracker: Sendable {
    public enum Phase: String, Codable, Sendable { case unknown, menu, inGame }

    public struct Current: Codable, Equatable, Sendable {
        public let biome: BiomeRef
        public let since: Date
        public let observedStart: Bool
        public let startEventId: String
        public let previous: BiomeKey?

        public init(biome: BiomeRef, since: Date, observedStart: Bool, startEventId: String, previous: BiomeKey?) {
            self.biome = biome; self.since = since; self.observedStart = observedStart
            self.startEventId = startEventId; self.previous = previous
        }
    }

    /// Identifies the log file (one Roblox launch); the prefix of every event id.
    public let sessionId: String
    public private(set) var current: Current?
    public private(set) var serverJobId: String?
    public private(set) var placeId: Int64?
    public private(set) var equippedAura: String?
    public private(set) var phase: Phase = .unknown
    public private(set) var lastEventAt: Date?
    public private(set) var presenceLines = 0
    /// Since when the player has been on the title screen (nil when in the world).
    public private(set) var menuSince: Date?

    private var enteredGameAt: Date?
    private var auraSeenSinceJoin = false
    /// How long after entering the game an equip still counts as the game restoring the saved aura.
    static let initialAuraWindow: TimeInterval = 10

    public init(sessionId: String) { self.sessionId = sessionId }

    public mutating func ingest(_ event: LogEvent) -> [SiverEvent] {
        lastEventAt = event.timestamp
        switch event {
        case .presence(let p): return ingest(p)
        case .joined(let jobId, let place, let at): return join(jobId: jobId, placeId: place, at: at)
        case .disconnected(let reason, let kind, let at):
            return [.disconnected(Disconnected(id: makeId(at, "dc", kind), reason: reason, kind: kind, at: at))]
        case .signal(let signal, let at):
            // Only the roll event becomes an app event here; the Session Inspector reads the other signals.
            guard case .gameEvent(let game) = signal, let name = game.rolledAuraName else { return [] }
            return [.auraRolled(AuraRolled(id: makeId(at, "ar", name), name: name, at: at, captureDelayMs: game.captureDelayMs,
                                           durationS: game.durationS, biome: current?.biome, biomeEventId: current?.startEventId))]
        case .merchant(let name, let at):
            return [.merchantArrived(MerchantArrived(id: makeId(at, "mc", name), name: name, at: at, biome: current?.biome,
                                                     biomeEventId: current?.startEventId, source: "log"))]
        }
    }

    /// Roblox moved on to a new log file (quit, crash, relaunch). We lose track of the biome.
    public mutating func endSession(at: Date) -> [SiverEvent] {
        let events = endCurrent(at: at, reason: .sessionEnded, next: nil)
        resetServerState()
        return events
    }

    /// The BiomeStarted for whatever is current, used once after the startup scan.
    public func startedEvent(wasRunning: Bool) -> SiverEvent? {
        guard let c = current else { return nil }
        return .biomeStarted(BiomeStarted(id: c.startEventId, biome: c.biome, at: c.since,
                                          observedStart: c.observedStart, wasRunning: wasRunning,
                                          serverJobId: serverJobId, previous: c.previous))
    }

    // MARK: private

    private mutating func ingest(_ p: RichPresence) -> [SiverEvent] {
        // Another game can use BloxstrapRPC too. Only trust lines while we know we are in Sol's RNG.
        if let placeId, placeId != SiverSol.solsRNGPlaceId { return [] }
        presenceLines += 1
        let state = p.state
        if state == .mainMenu {
            // The menu reports a placeholder biome; wait until the player is actually in the world.
            if phase != .menu { menuSince = p.timestamp }
            phase = .menu
            return []
        }
        menuSince = nil
        if phase != .inGame {
            phase = .inGame
            enteredGameAt = p.timestamp
        }
        var events: [SiverEvent] = []

        if let biome = p.biome, biome.key != current?.biome.key {
            let previous = current?.biome.key
            events += endCurrent(at: p.timestamp, reason: .changed, next: biome.key)
            let c = Current(biome: biome, since: p.timestamp, observedStart: previous != nil,
                            startEventId: makeId(p.timestamp, "bs", biome.key.value), previous: previous)
            current = c
            events.append(.biomeStarted(BiomeStarted(id: c.startEventId, biome: biome, at: p.timestamp,
                                                     observedStart: c.observedStart, wasRunning: false,
                                                     serverJobId: serverJobId, previous: previous)))
        }

        if case .equipped(let name) = state, name != equippedAura {
            equippedAura = name
            if let name {
                let sinceEnter = enteredGameAt.map { p.timestamp.timeIntervalSince($0) } ?? .infinity
                let initial = !auraSeenSinceJoin && sinceEnter <= Self.initialAuraWindow
                auraSeenSinceJoin = true
                events.append(.auraEquipped(AuraEquipped(id: makeId(p.timestamp, "au", name), internalName: name,
                                                         at: p.timestamp, biome: current?.biome,
                                                         biomeEventId: current?.startEventId, initial: initial,
                                                         serverJobId: serverJobId)))
            }
        }
        return events
    }

    private mutating func join(jobId: String, placeId: Int64, at: Date) -> [SiverEvent] {
        var events: [SiverEvent] = []
        if jobId != serverJobId {
            events += endCurrent(at: at, reason: .leftServer, next: nil)
            resetServerState()
        }
        serverJobId = jobId
        self.placeId = placeId
        events.append(.serverJoined(ServerJoined(id: makeId(at, "sj", jobId), jobId: jobId, placeId: placeId, at: at)))
        return events
    }

    private mutating func endCurrent(at: Date, reason: BiomeEndReason, next: BiomeKey?) -> [SiverEvent] {
        guard let c = current else { return [] }
        current = nil
        // A log stamp can never run backwards; clamp so a duration is never negative.
        let end = max(at, c.since)
        return [.biomeEnded(BiomeEnded(id: makeId(end, "be", c.biome.key.value), biome: c.biome, startedAt: c.since,
                                       at: end, startedEventId: c.startEventId, startObserved: c.observedStart,
                                       reason: reason, next: next, serverJobId: serverJobId))]
    }

    private mutating func resetServerState() {
        current = nil
        equippedAura = nil
        phase = .unknown
        menuSince = nil
        enteredGameAt = nil
        auraSeenSinceJoin = false
    }

    private func makeId(_ at: Date, _ kind: String, _ detail: String) -> String {
        "\(sessionId)|\(Int64((at.timeIntervalSince1970 * 1000).rounded()))|\(kind)|\(detail)"
    }
}
