import AppKit
import SiverCore
import SiverEngine
import SiverMacro
import SiverNotify
import SiverSky
import SwiftUI

/// The design review: the app shows made-up data and takes its page, biome, hour and appearance from a small
/// file, so every page can be photographed under every sky.
///
/// Started with `--design-review <folder>` and `SIVERSOL_HOME` pointing at a scratch folder. In this mode nothing
/// real is touched: no engine, no Keychain, no saved settings, no shortcuts, no Discord, no status file.
struct ReviewScenario: Codable, Equatable {
    var id = 0
    var page = "dashboard"
    /// Empty means "not running".
    var biome = "NORMAL"
    var hour = 13.0
    var dark = false
    var still = false
    var progress = 0.35
    var width = 1120.0
    var height = 740.0
    /// A plain note passed through to the pages that understand it (for example a Sol Dex filter).
    var note = ""
    /// A made-up MacBook screen (air13, air15, pro14, pro16): the island lays itself out around its notch and
    /// the window is placed on it. Empty: this Mac's own screen.
    var laptop = ""
    /// Pretend the Mac is in Low Power Mode (the sky stands still, the island stops animating).
    var lowPower = false
}

@MainActor
final class DesignReview {
    static let folder: URL? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--design-review"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }()
    static var isOn: Bool { folder != nil }
    static let shared = DesignReview()

    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var last = -1
    private(set) var scenario = ReviewScenario()

    func start() {
        guard let folder = Self.folder else { return }
        guard ProcessInfo.processInfo.environment["SIVERSOL_HOME"]?.isEmpty == false else {
            print("design review needs SIVERSOL_HOME so it cannot touch real data"); exit(2)
        }
        IslandController.shared.modeOverride = .off
        IslandController.shared.introOverride = false
        seed()
        seedMoments()
        seedMacro()
        AppModel.shared.reloadMacros()
        // Stay out of the way: no Dock icon, never the front app, and no App Nap while pictures are being taken.
        NSApp.setActivationPolicy(.accessory)
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "design review")
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll(folder) }
        }
    }

    /// A made-up day in the scratch folder, so Timeline, Sky Ribbon and Sol Dex have something to show.
    private func seed() {
        let store = TimelineStore(directory: TimelineStore.defaultDirectory)
        guard store.availableDays.isEmpty else { return }
        for event in DemoDay.events(endingAt: Date()) { store.record(event) }
    }

    /// Made-up clips for the Moments page: stills painted by the sky renderer, no video behind them.
    private func seedMoments() {
        let store = MomentsModel.shared.store
        guard store.all().isEmpty, let renderer = SkyMetalView.renderer else { return }
        try? store.createDirectory()
        let catalog = AppModel.shared.catalog
        let auras = AppModel.shared.auras
        func roll(_ name: String, _ biome: String, _ seconds: Double, _ bytes: Int) -> (Moment.Kind, String, String, String, Double, Int) {
            (.roll, "Rolled \(name)", auras.rarityText(for: name), biome, seconds, bytes)
        }
        let demo: [(Moment.Kind, String, String, String, Double, Int)] = [
            (.rareBiome, "GLITCHED", "rare biome", "GLITCHED", 12, 4_300_000), roll("Symphony", "STARFALL", 34, 11_800_000),
            roll("Abyssal Hunter", "RAINY", 41, 14_200_000), (.rareBiome, "DREAMSPACE", "rare biome", "DREAMSPACE", 12, 3_900_000),
            roll("Twilight", "HELL", 28, 9_100_000), (.rareBiome, "CYBERSPACE", "rare biome", "CYBERSPACE", 12, 4_600_000),
        ]
        for (i, d) in demo.enumerated() {
            let at = Date().addingTimeInterval(-Double(i) * 5400 - 600)
            let id = MomentsStore.baseName(kind: d.0, title: d.1, at: at)
            let look = SkyModel.look(catalog.info(for: BiomeKey(d.3)).palette, hour: 22, dark: true)
            if let image = renderer.image(SkyScene(look: look), time: 5, size: CGSize(width: 640, height: 384), scale: 1) {
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])?.write(to: store.thumbnailURL(id))
            }
            try? Data(count: d.5).write(to: store.videoURL(id))
            try? store.save(Moment(id: id, kind: d.0, title: d.1, detail: d.2, biome: d.3, at: at, seconds: d.4, bytes: d.5, eventId: nil))
        }
    }

    /// A made-up macro, so the piano roll has something to show.
    private func seedMacro() {
        let library = MacroLibrary()
        guard library.load("Demo walk") == nil else { return }
        let w: UInt16 = 13, a: UInt16 = 0, d: UInt16 = 2, space: UInt16 = 49, shift: UInt16 = 56
        var steps: [MacroStep] = []
        func add(_ delay: Double, _ action: MacroAction) { steps.append(MacroStep(delay: delay, action)) }
        add(0.3, .keyDown(code: w)); add(0.8, .keyDown(code: shift)); add(0.7, .keyDown(code: space)); add(0.12, .keyUp(code: space))
        add(0.9, .keyDown(code: a)); add(0.6, .keyUp(code: a)); add(0.3, .keyUp(code: shift)); add(0.4, .keyUp(code: w))
        add(0.3, .mouseDown(button: .right, x: 0.4, y: 0.5))
        for i in 1...8 { add(0.08, .mouseMove(x: 0.4 + Double(i) * 0.03, y: 0.5)) }
        add(0.05, .mouseUp(button: .right, x: 0.64, y: 0.5))
        add(0.4, .keyDown(code: d)); add(1.1, .keyUp(code: d))
        add(0.2, .wait(seconds: 1.5))
        add(0.3, .mouseDown(button: .left, x: 0.5, y: 0.82)); add(0.08, .mouseUp(button: .left, x: 0.5, y: 0.82))
        add(0.5, .keyDown(code: space)); add(0.1, .keyUp(code: space)); add(0.4, .keyDown(code: w)); add(1.4, .keyUp(code: w))
        var macro = Macro(name: "Demo walk", steps: steps)
        macro.note = "A made-up macro for pictures."
        _ = try? library.save(macro)
    }

    private func poll(_ folder: URL) {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("scenario.json")),
              let s = try? JSONDecoder().decode(ReviewScenario.self, from: data), s.id != last else { return }
        last = s.id
        scenario = s
        StallMeter.shared.start()
        StallMeter.shared.reset()
        SkyMetalView.resetGap()
        let framesBefore = SkyMetalView.framesDrawn
        let ticksBefore = SkyMetalView.ticks
        let began = CACurrentMediaTime()
        apply(s)
        // Give the window a moment to lay out and the sky to paint, then say it is ready.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            let window = NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true } ?? NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) }
            var ack: [String: Any] = ["id": s.id, "window": window?.windowNumber ?? 0, "frames": SkyMetalView.framesDrawn, "at": Date().timeIntervalSince1970]
            // Performance notes for this scenario: the longest the main thread was busy in one go while the
            // page came up, and how evenly the sky kept drawing meanwhile.
            ack["stallMs"] = (StallMeter.shared.worst * 1000).rounded()
            ack["skyFps"] = (Double(SkyMetalView.framesDrawn - framesBefore) / max(0.001, CACurrentMediaTime() - began) * 10).rounded() / 10
            ack["skyWorstGapMs"] = (SkyMetalView.worstGap * 1000).rounded()
            ack["linkHz"] = (Double(SkyMetalView.ticks - ticksBefore) / max(0.001, CACurrentMediaTime() - began) * 10).rounded() / 10
            // Every window of ours that is showing (the main window, the island, popovers), with its place on
            // the screen measured from the top-left, so a picture of all of them can be put together.
            let height = NSScreen.screens.first?.frame.height ?? 0
            ack["windows"] = NSApp.windows.filter { $0.isVisible && $0.frame.width > 1 && $0.frame.height > 1 && $0.windowNumber > 0 && $0.windowNumber < 1_000_000_000 && !($0 is FakeNotchWindow) }.map { w -> [String: Any] in
                let kind = w === window ? "main" : (w is IslandPanel ? "island" : "other")
                return ["id": w.windowNumber, "kind": kind, "x": w.frame.minX, "y": height - w.frame.maxY, "w": w.frame.width, "h": w.frame.height]
            }
            if let profile = Screens.fake, let shape = Screens.all().first, let notch = Screens.geometry(shape).notch {
                ack["laptop"] = ["id": profile.id, "name": profile.name, "x": shape.frame.minX, "y": height - shape.frame.maxY, "w": shape.frame.width, "h": shape.frame.height,
                                 "safeTop": shape.safeTop, "notchX": notch.minX, "notchW": notch.width, "dock": profile.dock] as [String: Any]
            }
            if let out = try? JSONSerialization.data(withJSONObject: ack) { try? out.write(to: folder.appendingPathComponent("ack.json"), options: .atomic) }
        }
    }

    private func apply(_ s: ReviewScenario) {
        // "perf": nothing but the page switch itself, exactly what a click in the sidebar does.
        if s.note == "perf" {
            if let page = AppSection(rawValue: s.page) { AppModel.shared.selection = page }
            return
        }
        NSApp.appearance = NSAppearance(named: s.dark ? .darkAqua : .aqua)
        let sky = SkyState.shared
        sky.hourOverride = s.hour
        sky.forceStill = s.still
        sky.progressOverride = s.progress
        let model = AppModel.shared
        model.reviewNote = s.note
        model.applyDemo(biome: s.biome)
        if let page = AppSection(rawValue: s.page) { model.selection = page }
        if s.note.hasPrefix("macro") {
            model.reloadMacros()
            model.selectedMacro = "Demo walk"
            UserDefaults.standard.set(s.note == "macro-inspector", forKey: "macroInspectorOpen")
        }
        Screens.fake = LaptopProfile.named(s.laptop)
        PowerWatch.shared.simulate = s.lowPower ? true : nil
        let island = IslandController.shared
        let restingNotes = ["island-resting", "island-intro"]
        island.restingOverride = nil
        island.introOverride = s.note == "island-intro"
        island.modeOverride = s.note == "island-always" ? .always : .off
        if restingNotes.contains(s.note) || s.note == "egg:islandComet" {
            let info = model.catalog.info(for: BiomeKey(s.biome))
            island.restingOverride = IslandResting(biome: s.biome.isEmpty ? nil : BiomeKey(s.biome), title: s.biome.isEmpty ? "Watching" : info.display,
                                                   endsAt: info.durationS == nil ? nil : Date().addingTimeInterval(86), startedAt: Date().addingTimeInterval(-754), rare: info.isRare)
        }
        if s.note == "island-rare" { island.preview(rare: true, catalog: model.catalog) }
        if s.note == "island" { island.preview(rare: false, catalog: model.catalog) }
        if s.note == "island-battery" {
            island.modeOverride = .always
            island.offer(IslandItem(id: "battery-\(s.id)", kind: .notice, title: BatteryGuard.Alert.onBattery(percent: 18, minutesLeft: 40).short, detail: "about 40 min left",
                                    biome: nil, rare: false, at: Date()))
        }
        // Rare sky surprises, forced for a picture: "egg:<name>". Nothing is recorded as found.
        let eggs = EggDirector.shared
        if s.note.hasPrefix("egg:") { eggs.force(String(s.note.dropFirst(4))) } else { eggs.clearForced() }
        if s.note == "eggs-some" {
            eggs.foundOverride = [.shootingStar: Date().addingTimeInterval(-86_400 * 3), .doubleRainbow: Date().addingTimeInterval(-86_400)]
        } else if s.note == "eggs-all" {
            eggs.foundOverride = Dictionary(uniqueKeysWithValues: SkyEgg.allCases.enumerated().map { ($1, Date().addingTimeInterval(-86_400 * Double($0 + 1))) })
        } else {
            eggs.foundOverride = [:]
        }
        island.refresh()
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
            var size = NSSize(width: s.width, height: s.height)
            var origin = window.frame.origin
            if let shape = Screens.all().first, Screens.fake != nil {
                // On the made-up laptop: under its menu bar, no larger than what that screen leaves free.
                let room = CGRect(x: shape.frame.minX, y: shape.visibleFrame.minY, width: shape.frame.width, height: shape.visibleFrame.height)
                size = NSSize(width: min(size.width, room.width), height: min(size.height, room.height))
                origin = NSPoint(x: room.midX - size.width / 2, y: room.maxY - size.height)
            }
            let frame = NSRect(origin: origin, size: size)
            if window.frame != frame { window.setFrame(frame, display: true) }
        }
        sky.refresh(animated: false)
        NSApp.windows.forEach { $0.contentView?.needsDisplay = true }
    }
}
