import Foundation

extension BiomeRadar.Snapshot {
    func with(version: String?, menuSince: Date?) -> BiomeRadar.Snapshot {
        var s = self; s.clientVersion = version; s.menuSince = menuSince; return s
    }
}

/// F1 Biome Radar: log discovery + tailer + parser + state machine, behind one object.
/// `step()` does one synchronous poll and is what the tests drive; `events()` runs it on a timer and on file changes.
public final class BiomeRadar: @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable {
        public var logFile: String?
        public var sessionId: String?
        public var current: BiomeTracker.Current?
        public var serverJobId: String?
        public var equippedAura: String?
        public var phase: BiomeTracker.Phase = .unknown
        /// Timestamp of the newest parsed log line.
        public var lastEventAt: Date?
        /// Wall-clock time we last received new bytes (frozen-log detection, F8).
        public var lastBytesAt: Date?
        public var linesRead = 0
        public var presenceLines = 0
        /// Client version, from the log file name.
        public var clientVersion: String?

        public init(logFile: String? = nil, sessionId: String? = nil, current: BiomeTracker.Current? = nil,
                    serverJobId: String? = nil, equippedAura: String? = nil, phase: BiomeTracker.Phase = .unknown,
                    lastEventAt: Date? = nil, lastBytesAt: Date? = nil, linesRead: Int = 0, presenceLines: Int = 0) {
            self.logFile = logFile; self.sessionId = sessionId; self.current = current; self.serverJobId = serverJobId
            self.equippedAura = equippedAura; self.phase = phase; self.lastEventAt = lastEventAt
            self.lastBytesAt = lastBytesAt; self.linesRead = linesRead; self.presenceLines = presenceLines
        }

        /// When the player has been sitting on the title screen since (nil when in the world).
        public var menuSince: Date?
    }

    public let logsDirectory: URL
    public let catalog: BiomeCatalog
    /// Raw relevant log events, for consumers that need more than biome state (health monitor).
    public var onLogEvent: ((LogEvent) -> Void)?

    private let queue = DispatchQueue(label: "siversol.radar")
    private var log: PlayerLog?
    private var tailer: LogTailer?
    private var tracker = BiomeTracker(sessionId: "none")
    private var firstStepDone = false
    private var linesRead = 0
    private var lastBytesAt: Date?

    private var timer: DispatchSourceTimer?
    private var dirWatcher: DispatchSourceFileSystemObject?
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var continuation: AsyncStream<[SiverEvent]>.Continuation?

    public init(logsDirectory: URL = SiverSol.logsDirectory, catalog: BiomeCatalog) {
        self.logsDirectory = logsDirectory
        self.catalog = catalog
    }

    public var snapshot: Snapshot { queue.sync { makeSnapshot() } }

    /// One poll: find the newest log, read appended lines, return the events they produced.
    /// The first call that finds an existing log scans it silently and reports only the biome in progress.
    public func step(now: Date = Date()) -> [SiverEvent] { queue.sync { stepLocked(now: now) } }

    /// Start watching. Events arrive in log order. Call `stop()` to finish the stream.
    public func events(pollInterval: TimeInterval = 1.0) -> AsyncStream<SiverEvent> {
        let batches = eventBatches(pollInterval: pollInterval)
        return AsyncStream { continuation in
            let task = Task {
                for await batch in batches { for e in batch { continuation.yield(e) } }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Like `events()`, but everything produced by one log read arrives together (a biome change is one batch).
    public func eventBatches(pollInterval: TimeInterval = 1.0) -> AsyncStream<[SiverEvent]> {
        AsyncStream { continuation in
            queue.async { [weak self] in
                guard let self else { return }
                self.continuation = continuation
                self.watchDirectory()
                let t = DispatchSource.makeTimerSource(queue: self.queue)
                t.schedule(deadline: .now(), repeating: pollInterval, leeway: .milliseconds(100))
                t.setEventHandler { [weak self] in self?.pump() }
                self.timer = t
                t.resume()
            }
            continuation.onTermination = { [weak self] _ in self?.stop() }
        }
    }

    public func stop() {
        queue.async {
            self.timer?.cancel(); self.timer = nil
            self.dirWatcher?.cancel(); self.dirWatcher = nil
            self.fileWatcher?.cancel(); self.fileWatcher = nil
            self.continuation?.finish(); self.continuation = nil
        }
    }

    /// Re-read now (sleep/wake, or a caller that wants the freshest state).
    public func reconcile() { queue.async { self.pump() } }

    // MARK: private (all on `queue`)

    private func pump() {
        let events = stepLocked(now: Date())
        if !events.isEmpty { continuation?.yield(events) }
    }

    private func makeSnapshot() -> Snapshot {
        Snapshot(logFile: log?.url.lastPathComponent, sessionId: log?.sessionId, current: tracker.current,
                 serverJobId: tracker.serverJobId, equippedAura: tracker.equippedAura, phase: tracker.phase,
                 lastEventAt: tracker.lastEventAt, lastBytesAt: lastBytesAt, linesRead: linesRead,
                 presenceLines: tracker.presenceLines).with(version: log?.version, menuSince: tracker.menuSince)
    }

    /// True while the silent startup scan is replaying old lines (side effects should wait).
    public private(set) var isCatchingUp = false

    private func stepLocked(now: Date) -> [SiverEvent] {
        var events: [SiverEvent] = []
        let newest = LogDiscovery.newest(in: logsDirectory)
        let isFirst = !firstStepDone
        firstStepDone = true

        if let newest, newest.url != log?.url, log == nil || newest.launchedAt >= log!.launchedAt {
            if log != nil {
                // Read what is left of the old log before leaving it, then close its biome.
                events += drain(now: now)
                // The old session ended when Roblox relaunched: no later than the new log's launch stamp, and not
                // before the last line we read. (The last status line can be minutes old, so it is a poor "last seen".)
                let lastSeen = max(tracker.lastEventAt ?? .distantPast, min(now, newest.launchedAt))
                events += tracker.endSession(at: lastSeen)
            }
            log = newest
            tailer = LogTailer(url: newest.url)
            tracker = BiomeTracker(sessionId: newest.sessionId)
            watchFile(newest.url)
            if isFirst {
                // Startup scan: the log already existed. Replay it silently to learn the state…
                isCatchingUp = true
                _ = drain(now: now)
                isCatchingUp = false
                // …and report only what is in progress right now.
                if let started = tracker.startedEvent(wasRunning: true) { events.append(started) }
                return decorate(events)
            }
        }
        events += drain(now: now)
        return decorate(events)
    }

    private func drain(now: Date) -> [SiverEvent] {
        guard let tailer else { return [] }
        var events: [SiverEvent] = []
        let read = tailer.poll()
        if read.didReset, let log {
            // Same path, new contents: treat it as a fresh session.
            events += tracker.endSession(at: tracker.lastEventAt ?? now)
            tracker = BiomeTracker(sessionId: log.sessionId + "r")
        }
        if read.bytes > 0 { lastBytesAt = now }
        linesRead += read.lines.count
        for line in read.lines {
            guard let event = LogLineParser.parse(line, fallbackDate: now) else { continue }
            onLogEvent?(event)
            events += tracker.ingest(event)
        }
        return events
    }

    /// Insert a NewBiomeSeen in front of the first BiomeStarted of a biome the catalog has never heard of.
    private func decorate(_ events: [SiverEvent]) -> [SiverEvent] {
        var out: [SiverEvent] = []
        for e in events {
            if case .biomeStarted(let s) = e, catalog.learn(s.biome, at: s.at) {
                out.append(.newBiomeSeen(NewBiomeSeen(id: s.id + "|new", biome: s.biome, at: s.at)))
            }
            out.append(e)
        }
        return out
    }

    private func watchDirectory() {
        dirWatcher?.cancel()
        dirWatcher = makeWatcher(logsDirectory, mask: [.write])
    }

    private func watchFile(_ url: URL) {
        fileWatcher?.cancel()
        fileWatcher = continuation == nil ? nil : makeWatcher(url, mask: [.extend, .write, .delete, .rename])
    }

    private func makeWatcher(_ url: URL, mask: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: queue)
        src.setEventHandler { [weak self] in self?.pump() }
        src.setCancelHandler { close(fd) }
        src.resume()
        return src
    }
}
