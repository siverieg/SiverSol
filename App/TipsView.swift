import SiverCore
import SwiftUI

/// What the app remembers about tips: whether they are wanted, and which were dismissed. Nothing leaves the Mac.
@MainActor
final class TipsModel: ObservableObject {
    static let shared = TipsModel()
    @AppStorage("tipsEnabled") var enabled = true
    @AppStorage("tipsDismissed") private var dismissedList = ""
    @AppStorage("tipsDismissedOn") private var dismissedOn = -1

    var dismissed: Set<String> { Set(dismissedList.split(separator: ",").map(String.init)) }

    /// Today's tip, or nil: tips are off, a rare biome is on, a macro is busy, or today's tip was dismissed.
    func tipOfDay(model: AppModel, now: Date = Date()) -> Tip? {
        let status = model.macroStatus
        let busy = status.recording != .idle || status.playing != nil || status.autoClicking
        guard TipRules.mayShow(enabled: enabled, rareBiome: model.isRunning && model.currentBiome?.isRare == true, macroBusy: busy) else { return nil }
        return TipRules.tipOfDay(day: TipRules.day(now), dismissed: dismissed, dismissedOn: dismissedOn < 0 ? nil : dismissedOn)
    }

    func dismiss(_ tip: Tip, now: Date = Date()) {
        dismissedList = (dismissed.union([tip.id])).sorted().joined(separator: ",")
        dismissedOn = TipRules.day(now)
        objectWillChange.send()
    }

    func reset() {
        dismissedList = ""
        dismissedOn = -1
        objectWillChange.send()
    }
}

/// The Tips page: every tip, grouped, each with a button that goes to the page it is about.
struct TipsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Page(scrollTarget: model.reviewNote.hasPrefix("eggs-") ? "secrets" : nil) {
            SectionHeader(title: "Tips", subtitle: "Small things worth knowing. Each one is true of this version of SiverSol.")
            ForEach(Tip.Group.allCases, id: \.self) { group in
                VStack(alignment: .leading, spacing: 10) {
                    CardTitle(title: group.rawValue, symbol: Self.symbol(group))
                    ForEach(TipCatalog.tips(in: group)) { tip in
                        HStack(alignment: .center, spacing: 12) {
                            Text(tip.text).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 12)
                            Button("Show me") { model.selection = tip.page }
                                .controlSize(.small)
                                .accessibilityLabel("Show me: \(tip.page.title)")
                        }
                        .padding(.vertical, 2)
                    }
                }
                .card()
            }
            SecretsCard().id("secrets")
        }
    }

    static func symbol(_ group: Tip.Group) -> String {
        switch group {
        case .start: return "flag"
        case .sky: return "sun.horizon"
        case .collection: return "rectangle.stack"
        case .discord: return "bubble.left.and.bubble.right"
        case .macros: return "pianokeys"
        case .laptops: return "laptopcomputer"
        case .privacy: return "lock.shield"
        }
    }
}

/// One tip at the foot of the Dashboard, a new one each day. Hidden during rare biomes and while a macro runs.
struct TipOfDayCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var tips = TipsModel.shared

    var body: some View {
        if let tip = tips.tipOfDay(model: model) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "lightbulb").font(.title3).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tip of the day").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(tip.text).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Show me") { model.selection = tip.page }.controlSize(.small)
                Button { tips.dismiss(tip) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.skyIcon).help("Dismiss this tip").accessibilityLabel("Dismiss this tip")
            }
            .card()
            .accessibilityElement(children: .contain)
        }
    }
}

/// Settings › Tips.
struct TipsSettingsCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var tips = TipsModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "Tips", symbol: "lightbulb")
            HelpToggle(title: "Show tips", help: "One tip a day at the foot of the Dashboard. Never during a rare biome or while a macro runs. Tips stay on this Mac.", isOn: $tips.enabled)
            HStack(spacing: 8) {
                Button("All tips") { model.selection = .tips }
                Button("Reset tips") { tips.reset() }.help("Show the tips you dismissed again")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
