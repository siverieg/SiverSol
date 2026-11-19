import AVFoundation
import AppKit
import SiverCore
import SiverEngine
import SiverNotify
import SiverSky
import SwiftUI

/// The clips on disk, loaded off the main thread.
@MainActor
final class MomentsModel: ObservableObject {
    static let shared = MomentsModel()
    @Published private(set) var moments: [Moment] = []
    @Published private(set) var totalBytes = 0
    @Published private(set) var loaded = false

    /// The design review keeps its made-up clips in its scratch folder.
    var store: MomentsStore {
        var s = MomentsStore(directory: DesignReview.isOn ? SiverSol.supportDirectory.appendingPathComponent("moments", isDirectory: true) : MomentsStore.defaultDirectory)
        s.capBytes = Int(max(0.1, AppModel.shared.extras.momentsCapGB) * 1_073_741_824)
        return s
    }

    func reload() {
        let store = self.store
        Task {
            let all = await Task.detached(priority: .userInitiated) { store.all() }.value
            self.moments = all
            self.totalBytes = all.reduce(0) { $0 + $1.bytes }
            self.loaded = true
        }
    }

    /// A clip goes to the Trash, never straight to nothing, and only if it is one of SiverSol's own files.
    func trash(_ moment: Moment) {
        let store = self.store
        guard MomentsStore.isOurs("\(moment.id).\(MomentsStore.videoExtension)") else { return }
        for url in [store.videoURL(moment.id), store.noteURL(moment.id), store.thumbnailURL(moment.id)] where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        reload()
    }
}

/// Moments: short clips of rolls and rare biomes, kept on this Mac.
struct MomentsView: View {
    enum Filter: String, CaseIterable, Identifiable { case all = "All", rolls = "Rolls", rares = "Rare biomes"; var id: String { rawValue } }

    @EnvironmentObject var model: AppModel
    @ObservedObject private var library = MomentsModel.shared
    @State private var filter: Filter = .all
    @State private var toTrash: Moment?

    var body: some View {
        let shown = library.moments.filter { filter == .all || (filter == .rolls) == ($0.kind == .roll) }
        Page {
            SectionHeader(title: "Moments", subtitle: "Short clips of your rolls and rare biomes, recorded from the Roblox window and kept on this Mac. No sound; the chat and the player list are covered.")
            if !model.extras.moments { turnOn }
            ControlStrip {
                Picker("Show", selection: $filter) { ForEach(Filter.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                Spacer(minLength: 8)
                let cap = library.store.capBytes
                ProgressView(value: min(1, Double(library.totalBytes) / Double(max(1, cap))))
                    .frame(width: 110)
                    .accessibilityLabel("Space used")
                Text("\(Self.size(library.totalBytes)) of \(Self.size(cap))").font(Sky.mono(11.5)).foregroundStyle(.secondary)
                Button { NSWorkspace.shared.open(library.store.directory) } label: { Label("Open folder", systemImage: "folder") }
                    .disabled(!FileManager.default.fileExists(atPath: library.store.directory.path))
            }
            if shown.isEmpty {
                ContentUnavailableView {
                    Label(library.moments.isEmpty ? "No moments yet" : "Nothing here", systemImage: "film.stack")
                } description: {
                    Text(library.moments.isEmpty ? "When a roll plays its cutscene or a rare biome rolls in, the clip lands here." : "No clips match this filter.")
                }
                .frame(maxWidth: .infinity, minHeight: 240)
                .card()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                    ForEach(shown) { moment in
                        MomentCard(moment: moment, store: library.store) { toTrash = moment }
                    }
                }
            }
        }
        .onAppear { library.reload() }
        .confirmationDialog("Move “\(toTrash?.title ?? "")” to the Trash?", isPresented: Binding(get: { toTrash != nil }, set: { if !$0 { toTrash = nil } })) {
            Button("Move to Trash", role: .destructive) { if let m = toTrash { library.trash(m) }; toTrash = nil }
        } message: { Text("You can put it back from the Trash.") }
    }

    private var turnOn: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "Moments are off", symbol: "film.stack")
            Text("Turn Moments on and SiverSol records a clip of the Roblox window when the game plays a roll cutscene (for as long as the cutscene lasts) and for 12 seconds when a rare biome starts. It uses the Screen Recording permission SiverSol already has, records no sound, and keeps at most \(String(format: "%.0f", model.extras.momentsCapGB)) GB in Movies/SiverSol Moments, removing the oldest clips first.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button {
                model.extras.moments = true
                model.saveSettings(restartIfRunning: true)
            } label: { Label("Turn on Moments", systemImage: "record.circle") }
                .buttonStyle(.skyProminent)
        }
        .card()
    }

    static func size(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1000 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
}

/// One clip: its still picture, which turns into the clip itself under the pointer (move across to scrub).
struct MomentCard: View {
    let moment: Moment
    let store: MomentsStore
    let onTrash: () -> Void
    @State private var hover: CGFloat?
    @State private var still: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let still {
                        Image(nsImage: still).resizable().scaledToFill()
                    } else {
                        LinearGradient(colors: [Color(hex: 0x1B1F5E), Color(hex: 0x6B3FA0)], startPoint: .top, endPoint: .bottom)
                            .overlay(Image(systemName: "film").font(.largeTitle).foregroundStyle(.white.opacity(0.5)))
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 150).clipped()
                if let hover, moment.bytes > 0 {
                    ScrubPlayer(url: store.videoURL(moment.id), fraction: hover).frame(height: 150)
                    // A thin line under the picture shows where in the clip the pointer is.
                    GeometryReader { geo in
                        Capsule().fill(.white).frame(width: max(3, geo.size.width * hover), height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .allowsHitTesting(false)
                }
                Label(moment.kind == .roll ? "Roll" : "Rare biome", systemImage: moment.kind == .roll ? "sparkles" : "cloud.bolt.fill")
                    .font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule()).foregroundStyle(.white).padding(8)
                    .opacity(hover == nil ? 1 : 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = min(1, max(0, p.x / 250))
                case .ended: hover = nil
                }
            }
            .accessibilityLabel("Clip: \(moment.title)")

            VStack(alignment: .leading, spacing: 2) {
                Text(moment.title).font(.headline).lineLimit(1)
                Text([moment.detail, moment.at.formatted(date: .abbreviated, time: .shortened)].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 8) {
                    Text("\(DiscordTime.duration(moment.seconds)) · \(MomentsView.size(moment.bytes))").font(Sky.mono(11)).foregroundStyle(.secondary)
                    Spacer()
                    Button { NSWorkspace.shared.open(store.videoURL(moment.id)) } label: { Image(systemName: "play.fill") }
                        .help("Play").accessibilityLabel("Play \(moment.title)")
                    Button { NSWorkspace.shared.activateFileViewerSelecting([store.videoURL(moment.id)]) } label: { Image(systemName: "magnifyingglass") }
                        .help("Reveal in Finder").accessibilityLabel("Reveal \(moment.title) in Finder")
                    Button(action: onTrash) { Image(systemName: "trash") }
                        .help("Move to Trash").accessibilityLabel("Move \(moment.title) to the Trash")
                }
                .buttonStyle(.skyIcon)
            }
        }
        .card(padding: 10)
        .task(id: moment.id) {
            let url = store.thumbnailURL(moment.id)
            still = await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value
        }
    }
}

/// Shows one frame of a clip, at the point the pointer is over. Made when the pointer arrives, gone when it leaves.
private struct ScrubPlayer: NSViewRepresentable {
    let url: URL
    let fraction: CGFloat

    final class PlayerView: NSView {
        let player = AVPlayer()
        var seconds = 0.0
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            self.layer = layer
            player.isMuted = true
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        let item = AVPlayerItem(url: url)
        view.player.replaceCurrentItem(with: item)
        Task { @MainActor in
            if let d = try? await item.asset.load(.duration) { view.seconds = d.seconds }
            seek(view)
        }
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) { seek(view) }

    private func seek(_ view: PlayerView) {
        guard view.seconds > 0 else { return }
        let t = CMTime(seconds: Double(fraction) * view.seconds, preferredTimescale: 600)
        view.player.seek(to: t, toleranceBefore: CMTime(value: 1, timescale: 10), toleranceAfter: CMTime(value: 1, timescale: 10))
    }

    static func dismantleNSView(_ view: PlayerView, coordinator: ()) { view.player.replaceCurrentItem(with: nil) }
}

/// Moments settings, shown on the Automation page.
struct MomentsSettingsCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "Moments", symbol: "film.stack")
            HelpToggle(title: "Record Moments", help: "Short video clips of the Roblox window for rolls and rare biomes. Kept on this Mac in Movies/SiverSol Moments. No sound.", isOn: $model.extras.moments)
            Group {
                HelpToggle(title: "Rolls with a cutscene", help: "From the roll until the game's own cutscene length has passed, so the whole cutscene is caught.", isOn: $model.extras.momentsOnRolls)
                HelpToggle(title: "Rare biomes", help: "12 seconds when a rare biome starts.", isOn: $model.extras.momentsOnRareBiomes)
                HelpToggle(title: "Also post clips to Discord", help: "Only to your Rich routes, and only when the clip is under Discord's 20 MB limit. A larger clip stays on the Mac and Discord gets a still picture and a note instead.", isOn: $model.extras.momentsUpload)
                HStack {
                    Text("Keep at most")
                    Stepper("\(String(format: "%.0f", model.extras.momentsCapGB)) GB", value: $model.extras.momentsCapGB, in: 1...20, step: 1).fixedSize()
                    Text("The oldest clips are removed first, and only from that folder.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .disabled(!model.extras.moments)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
