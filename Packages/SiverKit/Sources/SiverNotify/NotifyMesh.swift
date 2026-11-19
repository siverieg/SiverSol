import Foundation
import SiverCore

/// F2 Notify Mesh: turns events into queued jobs per route, then delivers them in order with rate limiting,
/// retries, interlinked messages and the Discord safety rules (only the user's own webhooks, no test content in hunt format, mentions always set explicitly).
public actor NotifyMesh {
    public struct Environment: Sendable {
        public var now: @Sendable () -> Date = { Date() }
        public var sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }
        public init() {}
    }

    /// A rare biome older than this no longer pings anyone (delivered late after being offline).
    static let stalePingAfter: TimeInterval = 15 * 60
    /// Discord can overwrite an edit that lands within a moment of the message being created
    /// (seen live on 2026-11-18 with a 0.5 s gap), so edits wait at least this long after the post.
    static let minEditGap: TimeInterval = 2

    public let config: NotifyConfig
    private let secrets: Secrets
    private let catalog: BiomeCatalog
    private let auras = AuraCatalog.bundled()
    public nonisolated let store: OutboxStore
    private let transport: HTTPTransport
    private let env: Environment

    private var limiters: [String: RateLimiter] = [:]
    private var deadRoutes: [String: Int] = [:]
    private var noComponents: Set<String> = []
    /// Routes on which Discord refused the Sky Cards layout: they get classic embeds from then on.
    private var noSky: Set<String> = []
    /// Draws a card's pictures. nil sends cards without pictures.
    private var artist: SkyArtist? = LivingSkyArtist()
    private var artCache: [String: (thumb: FileAttachment?, card: FileAttachment?)] = [:]
    private var stats: [String: RouteStats] = [:]
    private var postedAt: [String: Date] = [:]
    private var processing = false
    private var again = false
    private var runner: Task<Void, Never>?

    private var todayCount: @Sendable (BiomeKey) -> Int? = { _ in nil }
    private var sessionStartedAt: Date?
    private var sessionKey: String?
    private var log: @Sendable (String) -> Void = { _ in }
    private var routeDied: @Sendable (String, Int) -> Void = { _, _ in }
    public private(set) var sentCount = 0

    public init(config: NotifyConfig, secrets: Secrets, catalog: BiomeCatalog, store: OutboxStore,
                transport: HTTPTransport = URLSessionTransport(), environment: Environment = Environment()) {
        self.config = config; self.secrets = secrets; self.catalog = catalog
        self.store = store; self.transport = transport; self.env = environment
    }

    // MARK: configuration

    /// Replace (or remove) the artist that draws card pictures.
    public func setArtist(_ artist: SkyArtist?) { self.artist = artist }
    /// Routes that fell back to classic embeds because Discord refused the Sky Cards layout.
    public var classicFallbackRoutes: [String] { noSky.sorted() }

    public func setLogger(_ log: @escaping @Sendable (String) -> Void) { self.log = log }
    public func setRouteDiedHandler(_ handler: @escaping @Sendable (String, Int) -> Void) { routeDied = handler }
    public func setStats(todayCount: @escaping @Sendable (BiomeKey) -> Int?) { self.todayCount = todayCount }
    /// A session groups uptime, the live card and (on forum routes) one thread.
    public func setSession(key: String, startedAt: Date) { sessionKey = key; sessionStartedAt = startedAt }
    public var deadRouteNames: [String] { deadRoutes.keys.sorted() }

    /// Delivery health per route, for the Webhook Doctor.
    public struct RouteStats: Equatable, Sendable {
        public var delivered = 0
        public var rateLimited = 0
        public var failures = 0
        public var lastLatencyMs: Int?
        public var lastDeliveredAt: Date?
        public var lastError: String?
        public var dead = false
        public init() {}
    }

    public func routeStats() -> [String: RouteStats] {
        var out = stats
        for (name, _) in deadRoutes { out[name, default: RouteStats()].dead = true }
        return out
    }

    private func noteDelivery(route: String, startedAt: Date) {
        var s = stats[route] ?? RouteStats()
        s.delivered += 1
        s.lastLatencyMs = Int((Date().timeIntervalSince(startedAt) * 1000).rounded())
        s.lastDeliveredAt = env.now()
        s.lastError = nil
        stats[route] = s
    }

    // MARK: enqueue

    /// Queue a batch that came out of one log read. When a biome change arrives as (Ended X, Started Y) at the
    /// same instant, Started Y is queued first: it is the time-critical message, and the order in the channel
    /// stays truthful because both happened at once.
    /// `attachments`: event id -> files to attach to that event's post (proof shots, F10).
    public func handle(batch: [SiverEvent], origin: EventOrigin = .live, attachments: [String: [String]] = [:]) {
        var events = batch
        var i = 0
        while i + 1 < events.count {
            if case .biomeEnded(let e) = events[i], case .biomeStarted(let s) = events[i + 1], e.at == s.at, e.reason == .changed {
                events.swapAt(i, i + 1)
                i += 2
            } else {
                i += 1
            }
        }
        for e in events { enqueue(e, origin: origin, files: attachments[e.id]) }
        kick()
    }

    /// Queue whatever this event means for each route.
    public func handle(_ event: SiverEvent, origin: EventOrigin = .live) {
        enqueue(event, origin: origin)
        kick()
    }

    private func enqueue(_ event: SiverEvent, origin: EventOrigin, files: [String]? = nil) {
        for route in config.routes where route.enabled {
            // Anything that is not a real live event only goes to Rich routes that accept tests (hard rule 8).
            if origin != .live && !route.isTestTarget { continue }
            let base = "\(route.name)|\(event.id)"
            let key = OutboxStore.ledgerKey(route: route.name, eventId: event.id)
            switch event {
            case .biomeStarted(let e):
                guard route.wants(biome: e.biome.key) else { continue }
                let rare = catalog.isRare(e.biome.key)
                if route.digests(e.biome.key, isRare: rare) {
                    noteForDigest(route: route.name, origin: origin) { $0.append(DigestEntry(id: e.id, biome: e.biome.key.value, at: e.at, endedAt: nil)) }
                    continue
                }
                store.enqueue(OutboxItem(id: base + "|post", route: route.name, priority: rare, createdAt: env.now(),
                                         job: .event(event, origin: origin), ledgerKey: key, files: route.profile == .rich ? files : nil))
            case .biomeEnded(let e):
                guard route.wants(biome: e.biome.key) else { continue }
                let rare = catalog.isRare(e.biome.key)
                if route.digests(e.biome.key, isRare: rare) {
                    noteForDigest(route: route.name, at: e.startedAt, origin: origin) { entries in
                        if let i = entries.firstIndex(where: { $0.id == e.startedEventId }) { entries[i].endedAt = e.at }
                    }
                    continue
                }
                if route.profile == .huntCompat || route.endedMessages {
                    store.enqueue(OutboxItem(id: base + "|post", route: route.name, priority: rare, createdAt: env.now(),
                                             job: .event(event, origin: origin), ledgerKey: key))
                }
                if route.profile == .rich {
                    // Hunt-Compat messages are immutable; only Rich Started messages get edited.
                    // The edit goes last: it is the least urgent part of a biome change.
                    store.enqueue(OutboxItem(id: base + "|patch", route: route.name, priority: rare, createdAt: env.now(),
                                             job: .patchStarted(e, origin: origin)))
                }
            case .auraEquipped(let e):
                // The aura the game restores on join is not a roll; stay quiet about it.
                guard !e.initial, route.wants(.aura) else { continue }
                store.enqueue(OutboxItem(id: base + "|post", route: route.name, createdAt: env.now(),
                                         job: .event(event, origin: origin), ledgerKey: key, files: files))
            case .auraRolled:
                guard route.wants(.aura) else { continue }
                store.enqueue(OutboxItem(id: base + "|post", route: route.name, createdAt: env.now(),
                                         job: .event(event, origin: origin), ledgerKey: key, files: files))
            case .merchantArrived:
                guard route.wants(.merchant) else { continue }
                store.enqueue(OutboxItem(id: base + "|post", route: route.name, createdAt: env.now(),
                                         job: .event(event, origin: origin), ledgerKey: key, files: files))
            case .newBiomeSeen:
                guard route.wants(.newBiome) else { continue }
                store.enqueue(OutboxItem(id: base + "|post", route: route.name, createdAt: env.now(),
                                         job: .event(event, origin: origin), ledgerKey: key))
            case .serverJoined, .disconnected:
                continue   // reported through incident timelines (F8)
            }
        }
    }

    // MARK: digest

    static func digestHour(_ date: Date) -> String { String(Int(date.timeIntervalSince1970) / 3600) }

    func digestEntries(route: String, hour: String) -> [DigestEntry] {
        guard let raw = store.meta("digest|\(route)|\(hour)"), let entries = try? JSONDecoder().decode([DigestEntry].self, from: Data(raw.utf8)) else { return [] }
        return entries
    }

    /// Change what is gathered for the hour a biome began in, and make sure that hour's feed message gets
    /// posted or edited. Edits do not pile up: while one is waiting, it will carry whatever came after it.
    private func noteForDigest(route: String, at: Date? = nil, origin: EventOrigin, _ change: (inout [DigestEntry]) -> Void) {
        let hour = Self.digestHour(at ?? env.now())
        var entries = digestEntries(route: route, hour: hour)
        let before = entries
        change(&entries)
        guard entries != before else { return }
        if let data = try? JSONEncoder().encode(entries) { store.setMeta("digest|\(route)|\(hour)", String(decoding: data, as: UTF8.self)) }
        // Yesterday's hours are of no use any more.
        if let old = Int(hour).map({ String($0 - 30) }) { store.setMeta("digest|\(route)|\(old)", nil); store.setMeta("digestrev|\(route)|\(old)", nil) }
        let prefix = "\(route)|digest|\(hour)|"
        guard !store.all.contains(where: { $0.id.hasPrefix(prefix) }) else { return }
        let revision = (store.meta("digestrev|\(route)|\(hour)").flatMap(Int.init) ?? 0) + 1
        store.setMeta("digestrev|\(route)|\(hour)", String(revision))
        store.enqueue(OutboxItem(id: prefix + String(revision), route: route, createdAt: env.now(), job: .digest(hour: hour, origin: origin),
                                 ledgerKey: OutboxStore.ledgerKey(route: route, eventId: "digest-\(hour)")))
    }

    /// Queue a ready-made message (build log, test render, simulated biome).
    @discardableResult
    public func post(_ message: DiscordMessage, route: String, id: String, origin: EventOrigin = .live,
                     files: [String] = [], priority: Bool = false) -> Bool {
        guard let r = config.route(route), r.enabled else { return false }
        if origin != .live && !r.isTestTarget { log("refused: \(origin.rawValue) message for route \(route)"); return false }
        let added = store.enqueue(OutboxItem(id: "\(route)|\(id)|post", route: route, priority: priority, createdAt: env.now(),
                                             job: .message(message, origin: origin, files: files),
                                             ledgerKey: OutboxStore.ledgerKey(route: route, eventId: id)))
        kick()
        return added
    }

    // MARK: delivery

    public func start() {
        guard runner == nil else { return }
        runner = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wake = await self.process()
                await self.env.sleep(min(max(wake ?? 1, 0.05), 1))
            }
        }
    }

    public func stop() { runner?.cancel(); runner = nil }

    private func kick() {
        guard runner != nil else { return }
        Task { _ = await self.process() }
    }

    /// Deliver until the queue is empty. Returns false when it gives up (dead route or timeout).
    @discardableResult
    public func flush(timeout: TimeInterval = 120) async -> Bool {
        let deadline = env.now().addingTimeInterval(timeout)
        while true {
            let wake = await process()
            let live = config.routes.filter { deadRoutes[$0.name] == nil && secrets.webhook($0.name) != nil }.map(\.name)
            if live.allSatisfy({ store.depth(route: $0) == 0 }) { return store.depth == 0 }
            guard let wake, env.now() < deadline else { return false }
            await env.sleep(max(wake, 0.01))
        }
    }

    /// Send everything that may go out right now. Returns seconds until the next attempt makes sense, or nil if idle.
    public func process() async -> TimeInterval? {
        if processing { again = true; return 0.05 }
        processing = true
        defer { processing = false }
        var nextWake: TimeInterval?
        repeat {
            again = false
            nextWake = nil
            for route in config.routes where route.enabled && deadRoutes[route.name] == nil {
                guard let url = secrets.webhook(route.name) else { continue }
                let client = WebhookClient(url: url, transport: transport)
                while let item = store.next(route: route.name) {
                    var limiter = limiters[route.name] ?? RateLimiter()
                    let wait = limiter.delay(now: env.now())
                    limiters[route.name] = limiter
                    if wait > 0 { nextWake = min(nextWake ?? wait, wait); break }
                    if !(await deliver(item, route: route, client: client)) {
                        var l = limiters[route.name] ?? RateLimiter()
                        let w = max(l.delay(now: env.now()), 0.05)
                        limiters[route.name] = l
                        if deadRoutes[route.name] == nil { nextWake = min(nextWake ?? w, w) }
                        break
                    }
                }
            }
        } while again
        return nextWake
    }

    /// One attempt for one item. True = the item left the queue (sent or dropped); false = try again later.
    private func deliver(_ item: OutboxItem, route: RouteConfig, client: WebhookClient) async -> Bool {
        await learnGuild(route: route.name, client: client)
        let request = render(item, route: route)
        let startedAt = Date()
        var limiter = limiters[route.name] ?? RateLimiter()
        defer { limiters[route.name] = limiter }
        do {
            switch request {
            case .drop(let why):
                log("drop \(item.id): \(why)")
                store.complete(item.id)
            case .post(var message, let files):
                if noComponents.contains(route.name) { message.components = nil; message.sky?.button = nil }
                var threadId: String?
                if route.sessionThreads, let sessionKey {
                    threadId = store.meta("thread|\(route.name)|\(sessionKey)")
                    if threadId == nil { message.threadName = Self.threadName(sessionStartedAt ?? env.now()) }
                }
                if let sky = message.sky {
                    // A ping goes out as a tiny classic message right before the card: mentions in message
                    // content are known to notify, and the card itself then mentions nobody.
                    if let ping = message.content, !ping.isEmpty, message.allowedMentions.pingsAnyone, store.meta("pinged|\(item.id)") == nil {
                        var tiny = DiscordMessage(content: "\(ping) \(sky.headline)", username: message.username, allowedMentions: message.allowedMentions)
                        tiny.threadName = message.threadName
                        let pinged = try await client.execute(tiny, threadId: threadId)
                        store.setMeta("pinged|\(item.id)", pinged.messageId)
                        if route.sessionThreads, let sessionKey, threadId == nil {
                            threadId = pinged.channelId
                            store.setMeta("thread|\(route.name)|\(sessionKey)", pinged.channelId)
                            message.threadName = nil
                        }
                        sentCount += 1
                    }
                    message.content = nil
                    message.allowedMentions = .none
                }
                let sent = try await client.execute(message, files: files, threadId: threadId)
                if let sky = message.sky, item.ledgerKey != nil { rememberCard(sent.messageId, sky) }
                store.setMeta("pinged|\(item.id)", nil)
                limiter.recordSuccess(now: env.now(), info: sent.limit)
                if route.sessionThreads, let sessionKey, threadId == nil {
                    store.setMeta("thread|\(route.name)|\(sessionKey)", sent.channelId)
                }
                sentCount += 1
                noteDelivery(route: route.name, startedAt: startedAt)
                notePosted(sent.messageId)
                if let eventAt = item.liveEventAt {
                    log(String(format: "delivered %@ %.2fs after its log line", item.id, env.now().timeIntervalSince(eventAt)))
                }
                store.complete(item.id, ref: MessageRef(messageId: sent.messageId, channelId: sent.channelId,
                                                        guildId: store.meta("guild|\(route.name)")), ledgerKey: item.ledgerKey)
            case .patch(let ref, var message):
                if let posted = postedAt[ref.messageId], env.now().timeIntervalSince(posted) < Self.minEditGap {
                    limiter.hold(until: posted.addingTimeInterval(Self.minEditGap))
                    return false
                }
                if noComponents.contains(route.name) { message.components = nil }
                let info = try await client.edit(messageId: ref.messageId, message, threadId: route.sessionThreads ? ref.channelId : nil)
                limiter.recordSuccess(now: env.now(), info: info)
                sentCount += 1
                noteDelivery(route: route.name, startedAt: startedAt)
                store.complete(item.id)
            }
            return true
        } catch let error as WebhookError {
            switch error {
            case .rateLimited(let retryAfter):
                stats[route.name, default: RouteStats()].rateLimited += 1
                limiter.recordRateLimited(now: env.now(), retryAfter: retryAfter)
                log("429 on \(route.name): waiting \(retryAfter)s")
            case .server, .transport, .badResponse:
                stats[route.name, default: RouteStats()].failures += 1
                stats[route.name, default: RouteStats()].lastError = "\(error)"
                store.noteAttempt(item.id)
                let wait = limiter.recordFailure(now: env.now())
                log("\(route.name): \(error), retry in \(Int(wait))s")
            case .routeDead(let status):
                deadRoutes[route.name] = status
                log("route \(route.name) is dead (HTTP \(status)); its queue is kept")
                routeDied(route.name, status)
            case .unknownMessage:
                log("drop \(item.id): the message to edit no longer exists")
                store.complete(item.id)
                return true
            case .rejected(let status, let body):
                if requestIsSkyCard(request), !noSky.contains(route.name) {
                    // Fall back once: the same message as a classic embed, on this route from now on.
                    noSky.insert(route.name)
                    log("\(route.name): Discord refused the Sky Cards layout (HTTP \(status)); sending classic embeds on this route from now on")
                    return false
                }
                if case .drop = request {} else if !noComponents.contains(route.name), requestHasComponents(request) {
                    // Link buttons on plain webhooks are new; fall back to embeds-only once and keep going.
                    noComponents.insert(route.name)
                    log("\(route.name): HTTP \(status) with components, retrying without the button")
                    return false
                }
                log("drop \(item.id): Discord rejected it (HTTP \(status)) \(body)")
                store.complete(item.id)
                return true
            }
            return false
        } catch {
            store.noteAttempt(item.id)
            limiter.recordFailure(now: env.now())
            return false
        }
    }

    private func notePosted(_ messageId: String) {
        let now = env.now()
        postedAt = postedAt.filter { now.timeIntervalSince($0.value) < 30 }
        postedAt[messageId] = now
    }

    private func requestIsSkyCard(_ r: Request) -> Bool {
        switch r {
        case .post(let m, _): return m.isSkyCard
        case .patch(_, let m): return m.isSkyCard
        case .drop: return false
        }
    }

    /// Which pictures a card message carries, kept so that a later edit can show the same ones.
    private func rememberCard(_ messageId: String, _ sky: SkyCard) {
        store.setMeta("v2|\(messageId)", ([sky.thumbnail ?? "-"] + sky.gallery).joined(separator: ","))
        var recent = (store.meta("v2.recent") ?? "").split(separator: ",").map(String.init)
        recent.append(messageId)
        while recent.count > 120 { store.setMeta("v2|\(recent.removeFirst())", nil) }
        store.setMeta("v2.recent", recent.joined(separator: ","))
    }

    /// Decide the form a message goes out in, and draw a card's pictures.
    /// - A Hunt-Compat route, the "Classic embeds" style, or a message with no card: the classic message, untouched.
    /// - A route where Discord refused cards: the card's own words as a classic embed.
    /// - Otherwise: the Sky Card, with its pictures attached.
    func dress(_ request: Request, item: OutboxItem?, route: RouteConfig) -> Request {
        switch request {
        case .drop:
            return request
        case .post(let message, let files):
            guard route.profile == .rich, config.messageStyle == .skyCards, var sky = message.sky else { return .post(message.classic, files) }
            var all = files
            if let art = sky.art, let artist {
                let key = item?.id ?? UUID().uuidString
                let drawn = artCache[key] ?? (art.thumb.flatMap { artist.thumbnail($0, art: art) }, art.card.flatMap { artist.card($0, art: art) })
                if artCache.count > 24 { artCache.removeAll() }
                artCache[key] = drawn
                if let t = drawn.thumb { sky.thumbnail = t.name; all.append(t) }
                if let c = drawn.card { sky.gallery.append(c.name); all.insert(c, at: 0) }
            }
            // Pictures and clips that came with the message (a proof shot, a chart, a Moment) join the gallery.
            for f in files where ["image/png", "image/jpeg", "video/mp4"].contains(f.contentType) { sky.gallery.append(f.name) }
            if noSky.contains(route.name) {
                var fallback = sky.asEmbed(username: message.username, allowedMentions: message.allowedMentions, timestamp: nil)
                fallback.content = message.content
                fallback.embeds[0].timestamp = message.embeds.first?.timestamp
                return .post(fallback, all)
            }
            var m = message
            m.sky = sky
            return .post(m, all)
        case .patch(let ref, let message):
            // An edit keeps the form the message was sent in, and the pictures it was sent with.
            guard route.profile == .rich, var sky = message.sky, let kept = store.meta("v2|\(ref.messageId)") else { return .patch(ref, message.classic) }
            let names = kept.split(separator: ",").map(String.init)
            sky.thumbnail = names.first.flatMap { $0 == "-" ? nil : $0 }
            sky.gallery = Array(names.dropFirst())
            var m = message
            m.sky = sky
            m.content = nil
            m.allowedMentions = .none
            return .patch(ref, m)
        }
    }

    private func requestHasComponents(_ r: Request) -> Bool {
        switch r {
        case .post(let m, _): return m.components != nil
        case .patch(_, let m): return m.components != nil
        case .drop: return false
        }
    }

    private func learnGuild(route: String, client: WebhookClient) async {
        guard store.meta("guild|\(route)") == nil, store.meta("guildTried|\(route)") != sessionKey ?? "-" else { return }
        store.setMeta("guildTried|\(route)", sessionKey ?? "-")
        if let info = try? await client.info(), let guild = info.guildId {
            store.setMeta("guild|\(route)", guild)
            if let channel = info.channelId { store.setMeta("channel|\(route)", channel) }
        }
    }

    static func threadName(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return "SiverSol session · \(f.string(from: date))"
    }

    // MARK: rendering

    enum Request {
        case post(DiscordMessage, [FileAttachment])
        case patch(MessageRef, DiscordMessage)
        case drop(String)
    }

    /// Render context for a route, for callers that build their own messages (CLI test renders).
    public func renderContext(route name: String, origin: EventOrigin) -> RenderContext? {
        config.route(name).map { context(route: $0, origin: origin) }
    }

    func context(route: RouteConfig, origin: EventOrigin, eventAt: Date? = nil) -> RenderContext {
        var route = route
        let now = env.now()
        // Late delivery (we were offline): still post, but do not ping people about something long over.
        if let eventAt, now.timeIntervalSince(eventAt) > Self.stalePingAfter { route.pingsEnabled = false }
        if origin != .live { route.pingsEnabled = false }
        let store = self.store
        let name = route.name
        var ctx = RenderContext(catalog: catalog, route: route, origin: origin, serverLink: secrets.serverLink,
                                link: { store.ref(OutboxStore.ledgerKey(route: name, eventId: $0)) },
                                todayCount: todayCount, sessionStartedAt: sessionStartedAt, now: now)
        ctx.auras = auras
        ctx.profileName = config.profileName
        return ctx
    }

    func render(_ item: OutboxItem, route: RouteConfig) -> Request {
        let request: Request
        let origin: EventOrigin
        switch item.job {
        case .event(let event, let o):
            origin = o
            var ctx = context(route: route, origin: o, eventAt: event.at)
            // Quiet Hours: the message still goes out, the ping does not (except for the listed biomes).
            if case .biomeStarted(let s) = event, !config.quietHours.allowsPing(for: s.biome.key, at: env.now()) {
                ctx.route.pingsEnabled = false
            }
            var message: DiscordMessage?
            switch (event, route.profile) {
            case (.biomeStarted(let e), .rich): message = RichTemplates.biomeStarted(e, ctx)
            case (.biomeStarted(let e), .huntCompat): message = HuntTemplates.biomeStarted(e, ctx)
            case (.biomeEnded(let e), .rich): message = RichTemplates.biomeEnded(e, ctx)
            case (.biomeEnded(let e), .huntCompat): message = HuntTemplates.biomeEnded(e, ctx)
            case (.auraEquipped(let e), .rich): message = RichTemplates.aura(e, ctx)
            case (.newBiomeSeen(let e), .rich): message = RichTemplates.newBiome(e, ctx)
            case (.merchantArrived(let m), .rich): message = RichTemplates.merchant(m, ctx)
            case (.auraRolled(let r), .rich): message = RichTemplates.auraRolled(r, ctx)
            default: message = nil
            }
            // Proof shot: attach the files and show the first PNG inside the embed.
            let files = Self.attachments(item.files ?? [])
            if var m = message, let image = files.first(where: { $0.contentType == "image/png" }), !m.embeds.isEmpty {
                m.embeds[0].image = .init(url: "attachment://\(image.name)")
                message = m
            }
            request = message.map { .post($0, files) } ?? .drop("nothing to send for this event on a \(route.profile.rawValue) route")
        case .patchStarted(let ended, let o):
            origin = o
            guard route.profile == .rich else { return .drop("Hunt-Compat messages are never edited") }
            guard let ref = store.ref(OutboxStore.ledgerKey(route: route.name, eventId: ended.startedEventId)) else {
                return .drop("no Started message on record for this biome")
            }
            request = .patch(ref, RichTemplates.startedMessageAfterEnd(ended, context(route: route, origin: o)))
        case .message(let message, let o, let paths):
            origin = o
            let files = Self.attachments(paths)
            request = .post(message, files)
        case .digest(let hour, let o):
            origin = o
            guard route.profile == .rich else { return .drop("a Hunt-Compat route is never digested") }
            let entries = digestEntries(route: route.name, hour: hour)
            guard !entries.isEmpty else { return .drop("nothing gathered for this hour") }
            let start = Date(timeIntervalSince1970: (Double(hour) ?? 0) * 3600)
            let message = RichTemplates.biomeFeed(entries, hourStart: start, context(route: route, origin: o))
            if let ref = store.ref(OutboxStore.ledgerKey(route: route.name, eventId: "digest-\(hour)")) {
                request = .patch(ref, message)
            } else {
                request = .post(message, [])
            }
        }
        return dress(Self.guarded(request, origin: origin, route: route), item: item, route: route)
    }

    static func attachments(_ paths: [String]) -> [FileAttachment] {
        paths.compactMap { path in
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            let url = URL(fileURLWithPath: path)
            let type = ["png": "image/png", "json": "application/json", "txt": "text/plain", "jpg": "image/jpeg", "mp4": "video/mp4"][url.pathExtension.lowercased()] ?? "application/octet-stream"
            return FileAttachment(name: url.lastPathComponent, contentType: type, data: data)
        }
    }

    /// Last line of defense for hard rules 8 and 9, applied to every outgoing request.
    static func guarded(_ request: Request, origin: EventOrigin, route: RouteConfig) -> Request {
        func check(_ m: DiscordMessage) -> String? {
            if origin != .live {
                if !route.isTestTarget { return "rule 7/8: \(origin.rawValue) content is only allowed on a Rich route that accepts tests" }
                if route.profile == .huntCompat { return "rule 8: \(origin.rawValue) content never goes out in hunt format" }
                if HuntFormat.looksLikeHuntEvent(m) { return "rule 8: \(origin.rawValue) message would parse as a real biome event" }
                if m.allowedMentions.pingsAnyone { return "rule 9: \(origin.rawValue) message tried to ping" }
            }
            if m.allowedMentions.pingsAnyone && !route.pingsEnabled { return "rule 9: pings are off on route \(route.name)" }
            return nil
        }
        switch request {
        case .post(let m, _): if let why = check(m) { return .drop(why) }
        case .patch(_, let m): if let why = check(m) { return .drop(why) }
        case .drop: break
        }
        return request
    }

    // MARK: live card (F4)

    /// Create or edit the one card message for this session. Skipped (false) when the route is busy or down;
    /// a stale card edit is worthless, so it is never queued.
    public func upsertCard(_ message: DiscordMessage, route routeName: String, metaKey: String) async -> Bool {
        guard let route = config.route(routeName), route.enabled, deadRoutes[routeName] == nil,
              let url = secrets.webhook(routeName), store.depth(route: routeName) == 0 else { return false }
        var limiter = limiters[routeName] ?? RateLimiter()
        let wait = limiter.delay(now: env.now())
        limiters[routeName] = limiter
        if wait > 1.5 { return false }
        if wait > 0 { await env.sleep(wait) }
        let client = WebhookClient(url: url, transport: transport)
        var message = message
        if noComponents.contains(routeName) { message.components = nil; message.sky?.button = nil }
        let wantsSky = route.profile == .rich && config.messageStyle == .skyCards && message.sky != nil && !noSky.contains(routeName)
        limiter = limiters[routeName] ?? RateLimiter()
        defer { limiters[routeName] = limiter }
        do {
            if let id = store.meta(metaKey) {
                if let posted = postedAt[id] {
                    let gap = Self.minEditGap - env.now().timeIntervalSince(posted)
                    if gap > 0 { await env.sleep(gap) }
                }
                do {
                    // A card keeps the form it was created in for as long as it lives.
                    let edit = wantsSky && store.meta("v2|\(id)") != nil ? message : message.classic
                    let info = try await client.edit(messageId: id, edit)
                    limiter.recordSuccess(now: env.now(), info: info)
                    return true
                } catch WebhookError.unknownMessage {
                    log("live card \(id) no longer exists in Discord (deleted?); posting a new one")
                    store.setMeta(metaKey, nil)   // someone deleted the card: make a new one below
                }
            }
            let sent = try await client.execute(wantsSky ? message : message.classic)
            limiter.recordSuccess(now: env.now(), info: sent.limit)
            notePosted(sent.messageId)
            log("live card created: message \(sent.messageId) for \(metaKey)")
            store.setMeta(metaKey, sent.messageId)
            if wantsSky, let sky = message.sky { rememberCard(sent.messageId, sky) }
            return true
        } catch WebhookError.rejected(let status, _) where wantsSky {
            noSky.insert(routeName)
            log("\(routeName): Discord refused the Sky Cards layout (HTTP \(status)); sending classic embeds on this route from now on")
        } catch WebhookError.rateLimited(let retryAfter) {
            limiter.recordRateLimited(now: env.now(), retryAfter: retryAfter)
        } catch WebhookError.routeDead(let status) {
            deadRoutes[routeName] = status
            routeDied(routeName, status)
        } catch {
            // Transient: the next tick tries again.
        }
        return false
    }

    /// Macro Studio events go to Rich routes that carry the "macros" filter. Hunt-Compat routes never get them.
    public func postMacro(_ event: MacroEvent, proof: String? = nil) {
        for route in config.routes where route.enabled && route.profile == .rich && route.events.contains(.macros) {
            let message = RichTemplates.macro(event, context(route: route, origin: .live, eventAt: event.at), hasProof: proof != nil)
            var m = message
            if let proof, !m.embeds.isEmpty { m.embeds[0].image = .init(url: "attachment://\(URL(fileURLWithPath: proof).lastPathComponent)") }
            store.enqueue(OutboxItem(id: "\(route.name)|\(event.id)|post", route: route.name, createdAt: env.now(),
                                     job: .message(m, origin: .live, files: proof.map { [$0] } ?? []),
                                     ledgerKey: OutboxStore.ledgerKey(route: route.name, eventId: event.id)))
        }
        kick()
    }

    /// A Moment (a short clip of a roll or a rare biome) goes to the Rich routes that carry that kind of event.
    /// Hunt-Compat routes never get one. With `video` the clip itself is attached; without it the message says
    /// the clip is on the Mac, and shows the still picture if there is one.
    public func postMoment(_ moment: Moment, video: String?, still: String?, origin: EventOrigin = .live) {
        let wanted: EventKind = moment.kind == .roll ? .aura : .biome
        for route in config.routes where route.enabled && route.profile == .rich && route.events.contains(wanted) {
            if origin != .live && !route.isTestTarget { continue }
            let ctx = context(route: route, origin: origin, eventAt: moment.at)
            let stillName = video == nil ? still.map { URL(fileURLWithPath: $0).lastPathComponent } : nil
            let message = RichTemplates.moment(moment, ctx, hasVideo: video != nil, stillFileName: stillName)
            let files = video.map { [$0] } ?? (still.map { [$0] } ?? [])
            let eventId = "moment-\(moment.id)"
            store.enqueue(OutboxItem(id: "\(route.name)|\(eventId)|post", route: route.name, createdAt: env.now(),
                                     job: .message(message, origin: origin, files: files),
                                     ledgerKey: OutboxStore.ledgerKey(route: route.name, eventId: eventId)))
        }
        kick()
    }

    /// A Session Wrapped card goes to the Rich routes that carry the daily report. Hunt-Compat routes never get one.
    public func postWrapped(_ wrap: SessionWrap, image: String, id: String, origin: EventOrigin = .live) {
        for route in config.routes where route.enabled && route.profile == .rich && route.events.contains(.daily) {
            if origin != .live && !route.isTestTarget { continue }
            let ctx = context(route: route, origin: origin, eventAt: wrap.end)
            let message = RichTemplates.wrapped(wrap, ctx, imageFileName: URL(fileURLWithPath: image).lastPathComponent)
            store.enqueue(OutboxItem(id: "\(route.name)|\(id)|post", route: route.name, createdAt: env.now(),
                                     job: .message(message, origin: origin, files: [image]),
                                     ledgerKey: OutboxStore.ledgerKey(route: route.name, eventId: id)))
        }
        kick()
    }

    /// Send the connection test for a route. Refused for anything that is not a Rich route that accepts tests.
    /// Returns nil on success, or a sentence saying what went wrong.
    public func sendConnectionTest(route name: String) async -> String? {
        guard let route = config.route(name) else { return "There is no route called \(name)." }
        guard route.isTestTarget else { return "Test messages are never sent to a Hunt-Compat route. Use Check instead: it asks Discord about the webhook without posting." }
        guard let url = secrets.webhook(name) else { return "No valid webhook URL is saved for \(name)." }
        let diagnosis = await WebhookDoctor.examine(url.base, transport: transport)
        guard diagnosis.ok else { return diagnosis.problem ?? "The webhook could not be reached." }
        let message = RichTemplates.connected(route: route, webhookName: diagnosis.webhookName, channelId: diagnosis.channelId, catalog: catalog, now: env.now(), profile: config.profileName)
        // Same last line of defense as every other outgoing message (rules 8 and 9), checked per embed.
        for embed in message.embeds {
            var single = message; single.embeds = [embed]
            if case .drop(let why) = Self.guarded(.post(single, []), origin: .test, route: route) { return "Not sent: \(why)." }
        }
        let client = WebhookClient(url: url, transport: transport)
        do {
            if case .post(let dressed, let files) = dress(.post(message, []), item: nil, route: route) {
                do {
                    _ = try await client.execute(dressed, files: files)
                    return nil
                } catch WebhookError.rejected where dressed.isSkyCard {
                    noSky.insert(route.name)
                    log("\(route.name): Discord refused the Sky Cards layout; sending classic embeds on this route from now on")
                }
            }
            if case .post(let fallback, let files) = dress(.post(message, []), item: nil, route: route) {
                _ = try await client.execute(fallback, files: files)
            }
            return nil
        } catch {
            return "Discord accepted the webhook but refused the message (\(error)). Try again in a moment."
        }
    }

    /// Guild and channel for a route (cached after the first lookup).
    public func webhookInfo(route: String) async throws -> WebhookInfo {
        guard let url = secrets.webhook(route) else { throw WebhookError.badResponse }
        let info = try await WebhookClient(url: url, transport: transport).info()
        if let g = info.guildId { store.setMeta("guild|\(route)", g) }
        return info
    }
}
