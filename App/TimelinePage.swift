import Charts
import SiverCore
import SiverNotify
import SwiftUI
import UniformTypeIdentifiers

/// Everything SiverSol recorded, per UTC day, with filters, totals, the biome mix and export.
struct TimelinePage: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "Everything", biomes = "Biomes", rares = "Rare biomes", auras = "Auras", merchants = "Merchants"
        var id: String { rawValue }
    }

    @EnvironmentObject var model: AppModel
    @State private var day = TimelineStore.day(Date())
    @State private var filter: Filter = .all
    @State private var events: [SiverEvent] = []
    @State private var days: [String] = [TimelineStore.day(Date())]
    @State private var exportMessage = ""
    /// The row nearest to the moment the Sky Ribbon asked for.
    @State private var focusId: String?

    var body: some View {
        Page(scrollTarget: focusId) {
            HStack(alignment: .center) {
                SectionHeader(title: "Timeline", subtitle: "Every biome, aura and merchant SiverSol saw, kept on this Mac.")
                ControlStrip {
                    Picker("Day (UTC)", selection: $day) {
                        ForEach(days, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 190)
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .frame(width: 180)
                }
            }
            if events.isEmpty {
                ContentUnavailableView("Clear skies so far", systemImage: "binoculars",
                                       description: Text(day == TimelineStore.day(Date()) ? "Biomes will appear here as they roll in." : "Nothing was recorded on \(day)."))
                    .frame(maxWidth: .infinity, minHeight: 260)
                    .card()
            } else {
                summary
                mix
                list
            }
        }
        .task(id: day) { await reload(); applyFocus() }
        .onAppear { if let f = model.timelineFocus { day = TimelineStore.day(f); filter = .all } }
        .onChange(of: model.timelineFocus) { _, f in if let f { day = TimelineStore.day(f); filter = .all; applyFocus() } }
        .task(id: model.recent.first?.id) { if day == TimelineStore.day(Date()) { await reload() } }
    }

    private var report: DailyReport {
        DailyReport.build(day: day, events: events, isRare: { model.catalog.isRare($0) })
    }

    private var summary: some View {
        let r = report
        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Watched \(DiscordTime.duration(r.uptimeS))").font(.title3.weight(.semibold))
                Text("\(r.counts.values.reduce(0, +)) biome starts · \(r.auras) auras · \(r.merchants ?? 0) merchants").foregroundStyle(.secondary)
                Text(r.rares.isEmpty ? "No rare biomes" : "Rare: \(r.rares.joined(separator: ", "))")
                    .foregroundStyle(r.rares.isEmpty ? Color.secondary : Sky.warning)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                HStack {
                    Button("Export CSV…") { export(csv: true) }
                    Button("Export JSON…") { export(csv: false) }
                }
                Text(exportMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var mix: some View {
        let r = report
        let rows = r.seconds.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        let longest = max(1, rows.first?.value ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            CardTitle(title: "Biome mix", symbol: "chart.bar.xaxis")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                ForEach(rows, id: \.key) { key, seconds in
                    let info = model.catalog.info(for: BiomeKey(key))
                    GridRow {
                        HStack(spacing: 7) {
                            BiomeGlyph(info: info, size: 14).foregroundStyle(.secondary)
                            Text(key).lineLimit(1)
                        }
                        .gridColumnAlignment(.leading)
                        GeometryReader { geo in
                            Capsule().fill(info.palette.accent.color.gradient)
                                .frame(width: max(4, geo.size.width * seconds / longest))
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(height: 9)
                        Text("\(DiscordTime.duration(seconds)) · × \(r.counts[key] ?? 0)").font(Sky.mono(11.5, .regular)).foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(key): \(DiscordTime.duration(seconds)), \(r.counts[key] ?? 0) times")
                }
            }
        }
        .card()
    }

    private var list: some View {
        let rows = self.rows
        return VStack(alignment: .leading, spacing: 6) {
            CardTitle(title: "\(rows.count) events", symbol: "list.bullet")
            if rows.isEmpty {
                Text("Nothing matches this filter.").foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(rows) { row in
                        EventRowView(row: row)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(row.id == focusId ? Sky.steel.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .id(row.id)
                    }
                }
            }
        }
        .card()
    }

    private var rows: [EventRow] {
        events.reversed().compactMap { event -> EventRow? in
            switch (filter, event) {
            case (.all, _): break
            case (.biomes, .biomeStarted), (.biomes, .biomeEnded): break
            case (.rares, .biomeStarted(let s)) where model.catalog.isRare(s.biome.key): break
            case (.rares, .biomeEnded(let e)) where model.catalog.isRare(e.biome.key): break
            case (.auras, .auraEquipped), (.auras, .auraRolled): break
            case (.merchants, .merchantArrived): break
            default: return nil
            }
            return AppModel.row(for: event, catalog: model.catalog, auras: model.auras)
        }
    }

    /// Find the event nearest to the moment asked for and scroll to it.
    private func applyFocus() {
        guard let focus = model.timelineFocus, day == TimelineStore.day(focus), !events.isEmpty else { return }
        let nearest = rows.min { abs($0.time.timeIntervalSince(focus)) < abs($1.time.timeIntervalSince(focus)) }
        focusId = nearest?.id
        model.timelineFocus = nil
    }

    /// Files are read off the main thread.
    private func reload() async {
        let wanted = day
        let result = await Task.detached(priority: .userInitiated) { () -> ([String], [SiverEvent]) in
            let store = TimelineStore(directory: TimelineStore.defaultDirectory)
            let days = Array(Set(store.availableDays + [TimelineStore.day(Date())])).sorted(by: >)
            return (days, store.events(day: wanted))
        }.value
        guard wanted == day else { return }
        days = result.0
        events = result.1
    }

    private func export(csv: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "siversol-\(day).\(csv ? "csv" : "json")"
        panel.allowedContentTypes = [csv ? .commaSeparatedText : .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let events = self.events
        Task {
            let ok = await Task.detached { () -> Bool in
                let data = csv ? Data(TimelineExport.csv(events).utf8) : TimelineExport.json(events)
                return (try? data.write(to: url, options: .atomic)) != nil
            }.value
            exportMessage = ok ? "Saved \(url.lastPathComponent)" : "Could not save the file."
        }
    }
}
