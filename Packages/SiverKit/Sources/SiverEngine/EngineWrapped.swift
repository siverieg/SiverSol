import Foundation
import SiverCore
import SiverNotify
import SiverSky

extension SiverEngine {
    /// Hours watched today and this week, from the timeline. Reading seven days of events is not free, so the
    /// answer is kept for five minutes.
    public func huntCoverage(now: Date = Date()) -> HuntCoverage {
        if let raw = outbox.meta("coverage.cache"), let at = outbox.meta("coverage.at").flatMap(Double.init), now.timeIntervalSince1970 - at < 300 {
            let parts = raw.split(separator: "|").compactMap { Double($0) }
            if parts.count == 2 { return HuntCoverage(todaySeconds: parts[0], weekSeconds: parts[1]) }
        }
        let catalog = self.catalog
        let c = HuntCoverage.compute(timeline: timeline, now: now, open: isRunning, isRare: { catalog.isRare($0) })
        outbox.setMeta("coverage.cache", "\(c.todaySeconds)|\(c.weekSeconds)")
        outbox.setMeta("coverage.at", String(now.timeIntervalSince1970))
        return c
    }

    public static var wrappedDirectory: URL { SiverSol.supportDirectory.appendingPathComponent("wrapped", isDirectory: true) }

    /// The numbers for a stretch of time, from the timeline.
    public func sessionWrap(start: Date, end: Date) -> SessionWrap {
        var events: [SiverEvent] = []
        var day = start
        var days = Set([TimelineStore.day(start), TimelineStore.day(end)])
        while day < end { days.insert(TimelineStore.day(day)); day = day.addingTimeInterval(43_200) }
        // The day before as well: the biome that was on when the stretch began started earlier.
        days.insert(TimelineStore.day(start.addingTimeInterval(-86_400)))
        for d in days.sorted() { events += timeline.events(day: d) }
        let stats = macros.stats
        let runs = days.reduce(0) { $0 + (stats.days[$1]?.runs ?? 0) }
        let catalog = self.catalog, auras = self.auras
        return SessionWrap.build(events: events, start: start, end: end, isRare: { catalog.isRare($0) }, chance: { auras.chance(for: $0) },
                                 auraName: { auras.info(for: $0)?.display ?? AuraName.display($0) }, macroRuns: runs)
    }

    /// Draw a Session Wrapped card and save it under `wrapped/` in SiverSol's folder. Returns the file.
    @discardableResult
    public func makeWrapped(start: Date, end: Date = Date(), post: Bool = false, origin: EventOrigin = .live) async -> URL? {
        let wrap = sessionWrap(start: start, end: end)
        guard let image = WrappedCard.render(wrap, catalog: catalog, auras: auras, sky: SkyRenderer.shared, foil: FoilRenderer.shared),
              let data = WrappedCard.png(image) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmm"
        let dir = options.supportDirectory.appendingPathComponent("wrapped", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Wrapped-\(f.string(from: end)).png")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        onLog?("wrapped: saved \(url.lastPathComponent)")
        onWrapped?(url)
        if post {
            // Discord gets a smaller copy; the full picture stays on the Mac.
            var toPost = url
            if data.count > SkyCardArt.maxBytes, let small = SkyCardArt.encode(image, opaque: true, text: []), small.fileExtension == "jpg" {
                let copy = dir.appendingPathComponent("Wrapped-\(f.string(from: end))-post.jpg")
                if (try? small.data.write(to: copy, options: .atomic)) != nil { toPost = copy }
            }
            await mesh.postWrapped(wrap, image: toPost.path, id: "wrapped-\(Int(end.timeIntervalSince1970))", origin: origin)
        }
        return url
    }

    /// At the end of a session of ten minutes or more: one card, kept on this Mac, posted only if the user asked.
    func wrapUpSession() async {
        guard options.extras.wrappedOnStop else { return }
        let now = Date()
        guard now.timeIntervalSince(sessionStartedAt) >= 600 else { return }
        await makeWrapped(start: sessionStartedAt, end: now, post: options.extras.wrappedPost)
    }

    /// The card for one UTC day, to go with the daily report. Nil when nothing was watched that day.
    func wrappedForDay(_ day: String) async -> String? {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let start = cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        let end = min(Date(), start.addingTimeInterval(86_400))
        let wrap = sessionWrap(start: start, end: end)
        guard wrap.watchedSeconds > 60,
              let image = WrappedCard.render(wrap, catalog: catalog, auras: auras, sky: SkyRenderer.shared, foil: FoilRenderer.shared),
              let data = WrappedCard.png(image) else { return nil }
        let url = options.supportDirectory.appendingPathComponent("reports/wrapped-\(day).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil ? url.path : nil
    }
}
