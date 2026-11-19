import SiverCore
import SwiftUI

/// A live feed of what SiverSol understood from the Roblox log. Parsed facts only: a raw log line is never shown.
struct LogLabView: View {
    @EnvironmentObject var model: AppModel
    @State private var kinds: Set<LogLabEntry.Kind> = Set(LogLabEntry.Kind.allCases)
    @State private var search = ""
    @State private var paused = false
    @State private var frozen: [LogLabEntry] = []

    var body: some View {
        let source = paused ? frozen : model.reading.logLab
        let entries = source.filter { kinds.contains($0.kind) && (search.isEmpty || $0.summary.localizedCaseInsensitiveContains(search)) }
        Page {
            SectionHeader(title: "Log Lab", subtitle: "What the Roblox log is telling SiverSol right now. Each row is rebuilt from parsed fields, so usernames, ids, join tickets and IP addresses never appear here.")
            ControlStrip {
                TextField("Filter", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
                Menu("Signals (\(kinds.count) of \(LogLabEntry.Kind.allCases.count))") {
                    Button("Show all") { kinds = Set(LogLabEntry.Kind.allCases) }
                    Button("Hide heartbeats") { kinds.remove(.heartbeat) }
                    Divider()
                    ForEach(LogLabEntry.Kind.allCases, id: \.self) { kind in
                        Toggle(kind.rawValue.capitalized, isOn: Binding(get: { kinds.contains(kind) },
                                                                     set: { on in if on { kinds.insert(kind) } else { kinds.remove(kind) } }))
                    }
                }
                .fixedSize()
                Spacer()
                Toggle(isOn: $paused) { Label(paused ? "Paused" : "Live", systemImage: paused ? "pause.fill" : "dot.radiowaves.left.and.right") }
                    .toggleStyle(.button)
                    .onChange(of: paused) { _, now in if now { frozen = model.reading.logLab } }
            }
            if !model.isRunning {
                ContentUnavailableView("Not watching", systemImage: "moon.zzz", description: Text("Start SiverSol to follow the log."))
                    .frame(maxWidth: .infinity, minHeight: 260).card()
            } else if entries.isEmpty {
                ContentUnavailableView("No signals yet", systemImage: "waveform.slash",
                                       description: Text(source.isEmpty ? "The feed fills in as the game writes to its log." : "Nothing matches the filter."))
                    .frame(maxWidth: .infinity, minHeight: 260).card()
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entries.suffix(300).reversed()) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(e.at.formatted(date: .omitted, time: .standard)).monospacedDigit().foregroundStyle(.secondary)
                            Text(e.kind.rawValue).font(.caption.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2)
                                .background(tint(e.kind).opacity(0.2), in: Capsule())
                            Text(e.summary).textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
            if !model.reading.unknownSignals.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    CardTitle(title: "Seen but not understood yet", symbol: "questionmark.diamond")
                    ForEach(model.reading.unknownSignals.sorted { $0.value > $1.value }, id: \.key) { key, n in
                        KeyValueRow(label: key, value: "× \(n)")
                    }
                    Text("Only the kind of signal is counted. Its contents are not kept.").font(.caption).foregroundStyle(.secondary)
                }
                .card()
            }
        }
    }

    private func tint(_ kind: LogLabEntry.Kind) -> Color {
        switch kind {
        case .presence: return .blue
        case .roll: return .purple
        case .heartbeat: return .gray
        case .join, .session: return .green
        case .reset: return .teal
        case .update, .window: return .indigo
        case .disconnect: return .red
        case .merchant: return .orange
        case .unknown: return .yellow
        }
    }
}
