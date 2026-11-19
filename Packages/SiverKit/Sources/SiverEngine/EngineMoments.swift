import CoreGraphics
import Foundation
import SiverCore
import SiverInput
import SiverNotify
import SiverVision

/// What Moments does about an event: nothing, or a clip of some length.
public struct MomentPlan: Equatable, Sendable {
    public var kind: Moment.Kind
    public var title: String
    public var detail: String
    public var biome: String?
    public var eventId: String
    public var at: Date
    /// How long to record from now.
    public var seconds: Double

    public static let rareBiomeSeconds = 12.0
    public static let longest = 60.0
    public static let shortestWorthKeeping = 4.0

    /// - A roll the game plays a cutscene for: from the event until the game's own `clipOptions.duration` has
    ///   passed, so the whole cutscene is caught (12 s when the game gives no length, at most a minute).
    /// - A rare biome starting: 12 seconds.
    /// An event found late (the Mac slept, SiverSol started mid-cutscene) gets only what is left, or nothing.
    public static func plan(for event: SiverEvent, extras: ExtrasConfig, catalog: BiomeCatalog, auras: AuraCatalog, now: Date) -> MomentPlan? {
        guard extras.moments else { return nil }
        switch event {
        case .auraRolled(let r) where extras.momentsOnRolls:
            let total = min(longest, max(6, r.durationS ?? 12))
            let left = total - max(0, now.timeIntervalSince(r.at))
            guard left >= shortestWorthKeeping else { return nil }
            let rarity = auras.rarityText(for: r.name)
            return MomentPlan(kind: .roll, title: "Rolled \(auras.info(for: r.name)?.display ?? r.name)", detail: rarity == "unknown" ? "" : rarity,
                              biome: r.biome?.key.value, eventId: r.id, at: r.at, seconds: left)
        case .biomeStarted(let s) where extras.momentsOnRareBiomes && !s.wasRunning && catalog.isRare(s.biome.key):
            let left = rareBiomeSeconds - max(0, now.timeIntervalSince(s.at))
            guard left >= shortestWorthKeeping else { return nil }
            return MomentPlan(kind: .rareBiome, title: s.biome.key.value, detail: "rare biome", biome: s.biome.key.value, eventId: s.id, at: s.at, seconds: left)
        default:
            return nil
        }
    }
}

/// Records one planned clip, files it, and keeps the folder under its cap.
struct MomentsDirector: Sendable {
    struct Outcome: Sendable {
        var moment: Moment?
        /// True when the clip is small enough to be posted.
        var uploadable = false
        var trimmed: [Moment] = []
        var problem: String?
    }

    var store: MomentsStore
    /// The largest clip that may be uploaded; nil when uploads are off.
    var uploadLimit: Int?
    var window: @Sendable () -> CGWindowID?
    var record: @Sendable (MomentRecorder.Request) async throws -> MomentRecorder.Result
    /// Height of the Roblox window's title bar, so the chat and player list are covered in the right place.
    var titleBar: @Sendable () -> CGFloat = { 0 }

    func run(_ plan: MomentPlan) async -> Outcome {
        guard let windowId = window() else { return Outcome(problem: "no Roblox window on screen") }
        do { try store.createDirectory() } catch { return Outcome(problem: "cannot create \(store.directory.path)") }
        let id = MomentsStore.baseName(kind: plan.kind, title: plan.title, at: plan.at)
        let request = MomentRecorder.Request(windowId: windowId, seconds: plan.seconds,
                                             bitrate: MomentsStore.bitrate(seconds: plan.seconds, maxBytes: uploadLimit),
                                             output: store.videoURL(id), thumbnail: store.thumbnailURL(id), titleBar: titleBar())
        do {
            let result = try await record(request)
            let moment = Moment(id: id, kind: plan.kind, title: plan.title, detail: plan.detail, biome: plan.biome, at: plan.at,
                                seconds: result.seconds, bytes: result.bytes, eventId: plan.eventId)
            try? store.save(moment)
            let gone = store.trim(keeping: id)
            return Outcome(moment: moment, uploadable: uploadLimit.map { result.bytes <= $0 } ?? false, trimmed: gone)
        } catch {
            return Outcome(problem: "\(error)")
        }
    }
}

extension SiverEngine {
    var momentsStore: MomentsStore {
        MomentsStore(directory: options.momentsDirectory ?? MomentsStore.defaultDirectory,
                     capBytes: Int(max(0.1, options.extras.momentsCapGB) * 1_073_741_824))
    }

    /// Called for every event as it is delivered. One clip at a time: an event that arrives while a clip is being
    /// recorded does not get its own.
    func considerMoment(_ event: SiverEvent) {
        guard let plan = MomentPlan.plan(for: event, extras: options.extras, catalog: catalog, auras: auras, now: Date()) else { return }
        guard extra.raise("moment-busy") else { onLog?("moment: \(plan.title) not recorded, another clip is still being made"); return }
        tasks.append(Task { [weak self] in
            guard let self else { return }
            await self.makeMoment(plan)
            self.extra.lower("moment-busy")
        })
    }

    func makeMoment(_ plan: MomentPlan, origin: EventOrigin = .live) async {
        let recorder = options.momentRecorder ?? { try await MomentRecorder.record($0) }
        let director = MomentsDirector(store: momentsStore, uploadLimit: options.extras.momentsUpload ? DiscordLimits.webhookFileBytes : nil,
                                       window: { RobloxWindowFinder.mainWindow()?.windowId }, record: recorder,
                                       titleBar: { RobloxWindowFinder.mainWindow()?.titleBar ?? 0 })
        let outcome = await director.run(plan)
        guard let moment = outcome.moment else {
            onLog?("moment: \(plan.title) not saved (\(outcome.problem ?? "unknown"))")
            return
        }
        let megabytes = String(format: "%.1f MB", Double(moment.bytes) / 1_048_576)
        onLog?("moment: saved \(plan.title), \(String(format: "%.0f", moment.seconds)) s, \(megabytes)" + (outcome.trimmed.isEmpty ? "" : "; removed \(outcome.trimmed.count) old clip(s) to stay under the cap"))
        onMoment?(moment)
        if options.extras.momentsUpload {
            let store = momentsStore
            let still = FileManager.default.fileExists(atPath: store.thumbnailURL(moment.id).path) ? store.thumbnailURL(moment.id).path : nil
            await mesh.postMoment(moment, video: outcome.uploadable ? store.videoURL(moment.id).path : nil, still: still, origin: origin)
        }
    }
}
