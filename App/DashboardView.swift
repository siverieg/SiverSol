import Charts
import SiverCore
import SiverEngine
import SiverNotify
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // The top of the Dashboard is the sky itself: no card.
                    SunArcHero(height: max(250, min(380, geo.size.height * 0.40)))
                    banners
                    SkyRibbonCard()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                        ServerCard()
                        AuraCard()
                        TodayCard()
                        WrappedCardPanel()
                    }
                    ResourceCard()
                    recentEvents
                    TipOfDayCard()
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    @AppStorage("laptopLidNoteSeen") private var lidNoteSeen = false

    @ViewBuilder private var banners: some View {
        // Once, on a MacBook: what closing the lid does.
        if !lidNoteSeen, PowerWatch.isLaptop || model.reviewNote == "lid-note" {
            Banner(symbol: "laptopcomputer", text: "\(LaptopNotes.lidTitle): \(LaptopNotes.lid)", tint: .blue, actionTitle: "Got it") { lidNoteSeen = true }
        }
        if case .attention(let why) = model.runState {
            Banner(symbol: "exclamationmark.triangle.fill", text: model.lastLog.isEmpty ? why : "\(why). \(model.lastLog)", tint: .orange)
        }
        if model.isRunning && model.automationPaused {
            Banner(symbol: "hand.raised.fill", text: "Input is paused (\(model.pauseReason)). No keys or clicks are sent; the sky is still being watched and Discord still hears about it.",
                   tint: .orange, actionTitle: "Resume") { model.resumeAutomation() }
        }
        if model.isRunning, let warning = model.reading.windowWarning {
            Banner(symbol: "macwindow.badge.plus", text: warning, tint: .orange)
        }
        if model.isRunning, model.reading.session.updatePending {
            Banner(symbol: "arrow.down.circle", text: "A Roblox update is waiting. It installs the next time Roblox starts.", tint: .blue)
        }
        if model.isRunning, model.permissions.screenRecording, model.reading.screenCaptured == false || model.reading.screenBlank {
            Banner(symbol: "display.trianglebadge.exclamationmark",
                   text: "SiverSol cannot see the Roblox window right now (is the display off or asleep?). Biome detection and Discord alerts are not affected. Key presses and clicks wait until it can see again, and Roblox is never restarted because of this.",
                   tint: .orange)
        }
        if !model.permissions.allGranted {
            Banner(symbol: "lock.shield", text: "A permission is missing. Detection and alerts still work; key presses and screenshots do not.", tint: .orange,
                   actionTitle: "Open Settings") { model.selection = .settings }
        }
        if !model.reading.dead.isEmpty {
            Banner(symbol: "exclamationmark.triangle", text: "Discord stopped accepting: \(model.reading.dead.joined(separator: ", ")). Messages are kept in the queue.", tint: .red,
                   actionTitle: "Fix") { model.selection = .notifications }
        }
    }

    private var recentEvents: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "Recent events", symbol: "list.bullet.rectangle")
            if model.recent.isEmpty {
                ContentUnavailableView {
                    Label(model.isRunning ? "Clear skies so far" : "Not watching", systemImage: model.isRunning ? "binoculars" : "moon.zzz")
                } description: {
                    Text(model.isRunning ? "Biomes, auras and merchants appear here as they roll in." : "Press Start and SiverSol begins watching the sky.")
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(spacing: 6) {
                    ForEach(model.recent.prefix(12)) { EventRowView(row: $0) }
                }
                .motion(Sky.spring, value: model.recent.first?.id)
            }
        }
        .card()
    }
}

struct Banner: View {
    let symbol: String
    let text: String
    let tint: Color
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let actionTitle, let action { Button(actionTitle, action: action) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.45)))
    }
}

/// What the log says about the server, with nothing personal in it.
struct ServerCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let s = model.reading.session
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(title: "Server", symbol: "server.rack")
            if model.isRunning {
                KeyValueRow(label: "Kind", value: s.joinKind?.label ?? "unknown")
                KeyValueRow(label: "Server", value: s.shortJobId ?? model.snapshot.serverJobId.map { String($0.prefix(8)) } ?? "unknown")
                KeyValueRow(label: "Joined", value: s.joinedAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "unknown")
                KeyValueRow(label: "Server changes", value: "\(s.teleports) by the game · \(s.joins) joins")
                KeyValueRow(label: "Roblox", value: (s.clientVersion ?? model.snapshot.clientVersion).map { "v\($0)" } ?? "unknown")
                if let reset = model.reading.nextReset, model.extras.dailyResetCountdown {
                    Ticker { context in
                        KeyValueRow(label: "Daily reset in", value: AppModel.clock(reset.timeIntervalSince(context.date)))
                    }
                }
                Ticker { context in
                    KeyValueRow(label: "Watching for", value: model.reading.sessionStartedAt.map { DiscordTime.duration(context.date.timeIntervalSince($0)) } ?? "0s")
                }
            } else {
                Text("Server details appear while SiverSol is running.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct AuraCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(title: "Latest aura", symbol: "sparkles")
            if let equipped = model.isRunning ? model.snapshot.equippedAura : nil {
                Text(model.auras.display(for: equipped)).font(Sky.display(22, .bold)).lineLimit(2)
                    .contentTransition(.opacity)
                Text(model.auras.rarityText(for: equipped)).foregroundStyle(.secondary)
                if let boost = model.auras.nativeBoost(for: equipped, in: model.snapshot.current?.biome.key) {
                    Text(boost).font(.callout).foregroundStyle(.secondary)
                }
                Divider()
                if let roll = model.reading.lastRoll, let at = model.reading.lastRollAt {
                    KeyValueRow(label: "Last cutscene roll", value: "\(roll) · \(at.formatted(date: .omitted, time: .shortened))")
                }
                if let m = model.reading.lastMerchant, let at = model.reading.lastMerchantAt {
                    KeyValueRow(label: "Last merchant", value: "\(m) · \(at.formatted(date: .omitted, time: .shortened))")
                }
            } else {
                Text(model.isRunning ? "No aura equipped yet." : "The aura you have equipped shows here.").foregroundStyle(.secondary)
            }
            Button("All auras") { model.selection = .auras }.controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .motion(Sky.spring, value: model.snapshot.equippedAura)
    }
}

struct TodayCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(title: "Today (UTC)", symbol: "calendar")
            if model.reading.todayCounts.isEmpty {
                Text("No biomes recorded yet today.").foregroundStyle(.secondary)
            } else {
                let sorted = model.reading.todayCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                ForEach(sorted.prefix(6), id: \.key) { key, n in
                    HStack(spacing: 8) {
                        BiomeGlyph(info: model.catalog.info(for: BiomeKey(key)), size: 14).foregroundStyle(.secondary)
                        KeyValueRow(label: key, value: "× \(n)")
                    }
                }
                if let intel = model.reading.intel, model.extras.biomeIntelligence {
                    Divider()
                    if let streak = intel.streakKey, intel.streakCount > 1 {
                        KeyValueRow(label: "Streak", value: "\(streak) × \(intel.streakCount)")
                    }
                    if intel.longestNormalSeconds > 0 {
                        KeyValueRow(label: "Longest NORMAL", value: DiscordTime.duration(intel.longestNormalSeconds))
                    }
                }
            }
            if let coverage = model.reading.coverage {
                KeyValueRow(label: "Hunt coverage", value: coverage.line)
                    .help("How long SiverSol was actually watching the sky, today and over the last seven days (UTC).")
            }
            KeyValueRow(label: "Sent to Discord", value: "\(model.reading.sent)")
            KeyValueRow(label: "Waiting to send", value: model.reading.outboxDepth == 0 ? "nothing" : "\(model.reading.outboxDepth)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// Roblox memory and CPU over the last samples, measured from process statistics (no permission needed).
struct ResourceCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let samples = Array(model.reading.resources.suffix(120))
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "Roblox resources", symbol: "memorychip")
            if !model.extras.resourceMonitor {
                Text("The resource monitor is off. Turn it on in Automation.").foregroundStyle(.secondary)
            } else if samples.count < 2 {
                Text(model.isRunning ? "Collecting the first readings…" : "Memory and CPU of Roblox are charted while SiverSol is running.").foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 18) {
                    miniChart(title: "Memory", value: String(format: "%.2f GB", samples.last!.memoryGB), samples: samples, tint: .blue) { $0.memoryGB }
                    miniChart(title: "CPU", value: String(format: "%.0f%%", samples.last!.cpuPercent), samples: samples, tint: .orange) { $0.cpuPercent }
                }
                if let last = samples.last, last.memoryGB >= model.extras.memoryAlertGB {
                    Text("Memory is above your \(String(format: "%.0f", model.extras.memoryAlertGB)) GB limit.").font(.callout).foregroundStyle(Sky.warning)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func miniChart(title: String, value: String, samples: [ResourceSample], tint: Color, _ y: @escaping (ResourceSample) -> Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.headline).monospacedDigit().contentTransition(.numericText())
            }
            Chart(samples) { s in
                AreaMark(x: .value("Time", s.at), y: .value(title, y(s)))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", s.at), y: .value(title, y(s)))
                    .foregroundStyle(tint)
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
            .frame(height: 84)
            .accessibilityLabel("\(title) chart, now \(value)")
        }
        .frame(maxWidth: .infinity)
    }
}
