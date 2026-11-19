import AppKit
import Charts
import Foundation
import SiverCore
import SiverInput
import SiverNotify
import SiverVision
import SwiftUI

/// F10 settings.
public struct ProofConfig: Codable, Equatable, Sendable {
    public var enabled = true
    public var onRareBiome = true
    public var onMerchant = true
    /// Auras at least this rare (1 in N) get a screenshot.
    public var auraChanceAtLeast = 1_000_000
    public init() {}
}

/// F6 fallback: read the chat area of the Roblox window for "[Merchant]: Mari has arrived on the island...".
/// Pure decision logic; the engine feeds it OCR lines.
public struct MerchantScreenWatcher: Sendable {
    private var visible: Set<String> = []
    public init() {}

    /// Merchant names whose arrival notice just appeared in the chat (it was not there on the previous look).
    public mutating func newArrivals(in chatLines: [String]) -> [String] {
        var now: Set<String> = []
        for line in chatLines {
            if let name = LogLineParser.merchantName(in: line) { now.insert(name) }
        }
        let fresh = now.subtracting(visible)
        visible = now
        return fresh.sorted()
    }
}

/// The daily heat strip: one row per biome, one cell per UTC hour, brighter = more of that hour spent there.
@MainActor
public enum DailyChart {
    struct Cell: Identifiable {
        let id: String
        let biome: String
        let hour: Int
        let fraction: Double
        let color: Color
    }

    static func color(_ info: BiomeInfo) -> Color {
        let v = info.colorValue
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    public static func png(report: DailyReport, catalog: BiomeCatalog) -> Data? {
        let hourly = report.hourly ?? [:]
        let order = report.seconds.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key).filter { hourly[$0] != nil }
        guard !order.isEmpty else { return nil }
        var cells: [Cell] = []
        for key in order {
            let info = catalog.info(for: BiomeKey(key))
            for (hour, seconds) in (hourly[key] ?? []).enumerated() where seconds > 0 {
                cells.append(Cell(id: "\(key)-\(hour)", biome: "\(info.emoji) \(key)", hour: hour, fraction: min(1, seconds / 3600), color: color(info)))
            }
        }
        let labels = order.map { "\(catalog.info(for: BiomeKey($0)).emoji) \($0)" }
        let view = VStack(alignment: .leading, spacing: 10) {
            Text("Biome time per hour · \(report.day) (UTC)").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
            Chart(cells) { cell in
                BarMark(xStart: .value("Hour", Double(cell.hour) + 0.04), xEnd: .value("Hour", Double(cell.hour) + 0.96), y: .value("Biome", cell.biome), height: .ratio(0.78))
                    .foregroundStyle(cell.color.opacity(0.25 + 0.75 * cell.fraction))
                    .cornerRadius(3)
            }
            .chartXScale(domain: 0...24)
            .chartYScale(domain: labels)
            .chartXAxis {
                AxisMarks(values: Array(stride(from: 0, through: 24, by: 3))) { value in
                    AxisGridLine().foregroundStyle(.white.opacity(0.12))
                    AxisValueLabel { if let h = value.as(Int.self) { Text(String(format: "%02d:00", h % 24)).foregroundStyle(.white.opacity(0.7)) } }
                }
            }
            .chartYAxis {
                // Labels outside the plot, on the left, centered on their row.
                AxisMarks(preset: .aligned, position: .leading) { _ in
                    AxisValueLabel(centered: true).foregroundStyle(.white.opacity(0.9)).font(.system(size: 13))
                }
            }
            .frame(width: 860, height: CGFloat(max(3, order.count)) * 34 + 30)
            Text("Brighter cell = more of that hour in the biome. SiverSol v\(SiverSol.version)")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
        }
        .padding(20)
        .background(Color(red: 0.09, green: 0.10, blue: 0.13))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return SiverVision.pngData(image)
    }
}

extension SiverEngine {
    // MARK: proof shots (F10)

    func wantsProof(_ event: SiverEvent) -> Bool {
        guard options.proof.enabled else { return false }
        switch event {
        case .biomeStarted(let s): return options.proof.onRareBiome && catalog.isRare(s.biome.key)
        case .auraEquipped(let a): return !a.initial && (auras.chance(for: a.internalName) ?? 0) >= options.proof.auraChanceAtLeast
        case .merchantArrived: return options.proof.onMerchant
        default: return false
        }
    }

    /// Capture the Roblox window, cover the chat and the player list, save a PNG. nil when it cannot be seen.
    func takeProofShot(name: String) async -> String? {
        guard SiverVision.hasScreenRecordingAccess, let window = RobloxWindowFinder.mainWindow(),
              let image = try? await WindowCapture.capture(windowId: window.windowId, titleBar: window.titleBar) else { return nil }
        let safe = String(name.map { $0.isLetter || $0.isNumber ? $0 : "-" }.suffix(60))
        let url = options.supportDirectory.appendingPathComponent("proof/proof-\(safe).png")
        return SiverVision.savePNG(ProofShot.masked(image), to: url) ? url.path : nil
    }

    func attachments(for batch: [SiverEvent]) async -> [String: [String]] {
        let wanted = batch.filter(wantsProof)
        guard let first = wanted.first, let path = await takeProofShot(name: first.id) else { return [:] }
        return Dictionary(uniqueKeysWithValues: wanted.map { ($0.id, [path]) })
    }

    /// Proof shots are only needed until they are posted; keep a week of them.
    func pruneProofShots() {
        let dir = options.supportDirectory.appendingPathComponent("proof")
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, d < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: merchants from the screen (F6)

    func watchMerchantsOnScreen() async {
        var watcher = MerchantScreenWatcher()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(options.merchantScanIntervalS * 1_000_000_000))
            guard SiverVision.hasScreenRecordingAccess, let window = RobloxWindowFinder.mainWindow(),
                  let image = try? await WindowCapture.capture(windowId: window.windowId, titleBar: window.titleBar),
                  let chat = SiverVision.crop(image, to: ProofShot.chatRegion),
                  let lines = try? OCR.recognize(chat) else { continue }   // accurate mode: fast mode garbles chat-sized text
            let now = Date()
            for name in watcher.newArrivals(in: lines.map(\.text)) {
                let snap = radar.snapshot
                let event = SiverEvent.merchantArrived(MerchantArrived(
                    id: "\(snap.sessionId ?? sessionKey)|\(Int64(now.timeIntervalSince1970 * 1000))|mc|\(name)", name: name, at: now,
                    biome: snap.current?.biome, biomeEventId: snap.current?.startEventId, source: "screen"))
                await deliver([event])
            }
        }
    }

    // MARK: daily report (F12)

    public func dailyReport(day: String, now: Date = Date()) -> DailyReport {
        var report = DailyReport.build(day: day, events: timeline.events(day: day), isRare: { self.catalog.isRare($0) }, now: now)
        let totals = macros.stats.days[day]
        report.macroRuns = totals?.runs
        report.autoClicks = totals?.autoClicks
        return report
    }

    /// Render the chart PNG for a report into Application Support. Returns the file path.
    @MainActor
    public func renderDailyChart(_ report: DailyReport) -> String? {
        guard let data = DailyChart.png(report: report, catalog: catalog) else { return nil }
        let url = options.supportDirectory.appendingPathComponent("reports/daily-\(report.day).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil ? url.path : nil
    }

    /// Post the report for a finished UTC day, once.
    func postDailyReport(day: String) async {
        guard outbox.meta("daily|\(day)") == nil else { return }
        let report = dailyReport(day: day)
        guard !report.counts.isEmpty else { return }
        let chart = await renderDailyChart(report)
        // The day's Wrapped card rides along with the report, as a second picture under it.
        let wrapped = await wrappedForDay(day)
        for route in config.routes where route.wants(.daily) && route.profile == .rich {
            guard let ctx = await mesh.renderContext(route: route.name, origin: .live) else { continue }
            let message = RichTemplates.dailyReport(report, ctx, chartFileName: chart.map { URL(fileURLWithPath: $0).lastPathComponent })
            await mesh.post(message, route: route.name, id: "daily-\(day)", files: [chart, wrapped].compactMap { $0 })
        }
        outbox.setMeta("daily|\(day)", "posted")
    }

    func runDailyReports() async {
        // Catch up first: the Mac may have been asleep at midnight.
        await postDailyReport(day: TimelineStore.day(Date().addingTimeInterval(-86400)))
        while !Task.isCancelled {
            var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
            let nextMidnight = cal.startOfDay(for: Date()).addingTimeInterval(86400)
            let wait = nextMidnight.timeIntervalSinceNow + 5
            try? await Task.sleep(nanoseconds: UInt64(max(1, wait) * 1_000_000_000))
            if Task.isCancelled { break }
            await postDailyReport(day: TimelineStore.day(nextMidnight.addingTimeInterval(-3600)))
        }
    }
}
