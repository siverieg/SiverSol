import AppKit
import Carbon.HIToolbox
import SiverCore
import SiverEngine
import SiverInput
import SiverMacro
import SiverNotify
import SwiftUI
import UniformTypeIdentifiers

/// Macro Studio: recording, playing, the library and the auto clicker.
extension AppModel {
    // MARK: the coordinator

    /// The engine brings its own coordinator (wired to Discord and the live biome). While the engine is stopped,
    /// a standalone one lets Macro Studio work without a webhook.
    var macroCoordinator: MacroCoordinator {
        if let engine { return engine.macros }
        if let existing = standaloneMacros { return existing }
        let radar = BiomeRadar(logsDirectory: SiverSol.logsDirectory, catalog: catalog)
        let guardian = Guardian(log: ActionLog(url: ActionLog.defaultURL)) { await Guardian.robloxLook() }
        let flag = panicFlag
        // Hard rule 2 holds here too: a purchase, delete or trade dialog means Escape once, then no more input.
        guardian.onForbidden = { [weak self] _, reason in
            if let pid = FocusManager.robloxApp()?.processIdentifier {
                _ = await InputDriver().tap(.escape, delivery: .toProcess, pid: pid, yieldToUser: false)
            }
            await MainActor.run { [weak self] in
                self?.setPauseReason("Guardian: \(reason)")
                self?.panic()
            }
        }
        let coordinator = MacroCoordinator(supportDirectory: SiverSol.supportDirectory, guardian: guardian, radar: radar,
                                           catalog: catalog, inputPaused: { flag.value })
        coordinator.log = { [weak self] line in Task { @MainActor in self?.noteLog(line) } }
        wire(coordinator)
        standaloneMacros = coordinator
        standaloneRadar = radar
        // Keep its view of the current biome fresh, so "stop during rare biomes" works without the engine.
        standaloneRadarTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                _ = radar.step()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        return coordinator
    }

    func wire(_ coordinator: MacroCoordinator) {
        let frame = recorderBar.frameBox
        coordinator.ignoreInputIn = { frame.value }
    }

    func setPauseReason(_ reason: String) { if !automationPaused { setPause(reason) } }

    /// 4 Hz, and only does work while something is recording, playing or clicking.
    func macroTick() {
        guard let coordinator = engine?.macros ?? standaloneMacros else { return }
        let status = coordinator.status
        guard status != macroStatus else { return }
        let wasRecording = macroStatus.recording != .idle
        let wasBusy = wasRecording || macroStatus.playing != nil || macroStatus.autoClicking
        macroStatus = status
        let busy = status.recording != .idle || status.playing != nil || status.autoClicking
        if wasBusy && !busy {
            macroStats = coordinator.stats
            if !status.lastResult.isEmpty { macroMessage = status.lastResult }
            if wasRecording { reloadMacros() }
        }
        recorderBar.update(visible: showRecorderBar && busy)
    }

    func reloadMacros() {
        let library = MacroLibrary()
        let stats = (engine?.macros ?? standaloneMacros)?.stats
        Task {
            let all = await Task.detached(priority: .userInitiated) { library.all() }.value
            self.macroList = all
            if let stats { self.macroStats = stats }
            if let selected = self.selectedMacro, !all.contains(where: { $0.name == selected }) { self.selectedMacro = all.first?.name }
            if self.selectedMacro == nil { self.selectedMacro = all.first?.name }
        }
    }

    // MARK: recording

    func toggleRecording() {
        if macroStatus.recording == .idle { startRecording() } else { stopRecording() }
    }

    func startRecording() {
        guard permissions.accessibility else { macroMessage = "Recording needs the Accessibility permission. Open Settings to allow it."; return }
        let coordinator = macroCoordinator
        let options = recorderOptions
        macroMessage = "Bringing Roblox to the front…"
        Task {
            // Only what happens in Roblox is recorded, so Roblox has to be the front app.
            _ = await FocusManager.bringRobloxToFront(timeout: 1.5)
            if let problem = coordinator.startRecording(options: options) {
                self.macroMessage = problem
            } else {
                let p = InputTap.permissions()
                // macOS reports "listen access" as available to any app that has Accessibility, so that flag cannot tell
                // the two apart. What is certain: the tap is an active one, which macOS ties to Accessibility, and
                // SiverSol never calls the Input Monitoring request.
                self.recorderCheck = "the recorder started with Accessibility \(p.accessibility ? "on" : "off"); SiverSol did not ask for Input Monitoring"
                self.macroMessage = "Recording. Only keys and clicks made in Roblox are kept. Press ⌃⌥⌘R to stop."
                self.macroTick()
                self.writeStatusFile()
            }
        }
    }

    func pauseOrResumeRecording() {
        let coordinator = macroCoordinator
        switch macroStatus.recording {
        case .recording: coordinator.pauseRecording()
        case .paused: coordinator.resumeRecording()
        case .idle: break
        }
        macroTick()
    }

    func stopRecording(name: String? = nil) {
        let coordinator = macroCoordinator
        Task {
            let saved = await Task.detached { coordinator.stopRecording(name: name) }.value
            self.macroTick()
            self.macroMessage = coordinator.status.lastResult
            if let saved { self.selectedMacro = saved.name; self.selection = .macros }
            self.reloadMacros()
        }
    }

    // MARK: playing

    func playMacro(_ name: String) {
        guard !automationPaused else { macroMessage = "Input is paused. Choose Resume automation first."; return }
        if let problem = macroCoordinator.enqueue(name) { macroMessage = problem } else { macroMessage = "Starting “\(name)”…" }
        macroTick()
    }

    func stopMacro() {
        macroCoordinator.stopCurrent(.user)
        macroCoordinator.stopAutoClicker()
    }

    func togglePlaySelected() {
        if macroStatus.playing != nil || !macroStatus.queued.isEmpty { stopMacro() } else if let name = selectedMacro { playMacro(name) }
    }

    // MARK: library

    func saveMacro(_ macro: Macro, renamedFrom old: String? = nil) {
        let library = MacroLibrary()
        Task {
            let problem: String? = await Task.detached {
                do {
                    try library.save(macro)
                    if let old, MacroLibrary.fileName(for: old) != MacroLibrary.fileName(for: macro.name) { library.delete(old) }
                    return nil
                } catch { return "\(error)" }
            }.value
            self.macroMessage = problem.map { "Could not save: \($0)" } ?? "Saved “\(macro.name)”."
            if problem == nil { self.selectedMacro = macro.name }
            self.reloadMacros()
        }
    }

    /// Deleting moves the file to the Trash, so it can be put back.
    func deleteMacro(_ name: String) {
        let url = MacroLibrary().url(for: name)
        Task {
            let ok = await Task.detached { (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil }.value
            self.macroMessage = ok ? "Moved “\(name)” to the Trash." : "Could not move “\(name)” to the Trash."
            self.reloadMacros()
        }
    }

    func duplicateMacro(_ name: String) {
        let library = MacroLibrary()
        guard var copy = library.load(name) else { return }
        copy.name = library.uniqueName(name)
        copy.settings.triggers = []
        saveMacro(copy)
    }

    func exportMacro(_ name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MacroLibrary.fileName(for: name)
        panel.message = "Export this macro as a file you can share."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try MacroLibrary().export(name, to: url); macroMessage = "Exported “\(name)”." } catch { macroMessage = "Export failed: \(error)" }
    }

    func chooseMacroToImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: Macro.fileExtension) ?? .json, .json]
        panel.message = "Choose a .svmacro file. You will see its steps before it is added."
        if panel.runModal() == .OK, let url = panel.url { previewImport(url) }
    }

    /// Read and check a macro file. Nothing is saved, and nothing can run, until the user has seen the steps.
    func previewImport(_ url: URL) {
        do {
            pendingImport = try MacroLibrary().previewImport(url)
            selection = .macros
        } catch {
            macroMessage = "That file was not added: \(error)"
            selection = .macros
        }
    }

    func confirmImport() {
        guard var macro = pendingImport else { return }
        macro.reviewed = true      // the user has just been shown every step
        pendingImport = nil
        saveMacro(macro)
    }

    // MARK: auto clicker

    func toggleAutoClicker() {
        if macroStatus.autoClicking { macroCoordinator.stopAutoClicker(); return }
        guard !automationPaused else { macroMessage = "Input is paused. Choose Resume automation first."; return }
        if let data = try? JSONEncoder().encode(autoClicker) { UserDefaults.standard.set(data, forKey: "autoClicker") }
        if let problem = macroCoordinator.startAutoClicker(autoClicker) { macroMessage = problem } else { macroMessage = "Auto clicker running. It clicks where the pointer is, inside Roblox only." }
        macroTick()
    }

    func loadAutoClickerConfig() {
        if let data = UserDefaults.standard.data(forKey: "autoClicker"), let saved = try? JSONDecoder().decode(AutoClickerConfig.self, from: data) { autoClicker = saved }
    }

    // MARK: global shortcuts (Carbon hot keys: no permission needed)

    static let shortcutHelp: [(keys: String, what: String)] = [
        ("⌃⌥⌘P", "Panic: release every key and pause all input"),
        ("⌃⌥⌘R", "Start or stop recording a macro"),
        ("⌃⌥⌘E", "Pause or resume the recording"),
        ("⌃⌥⌘M", "Play or stop the selected macro"),
        ("⌃⌥⌘K", "Auto clicker (press to toggle, or hold in hold mode)")
    ]

    func installHotKeys() {
        guard hotKeys.isEmpty else { return }
        loadAutoClickerConfig()
        func key(_ code: Int, released: (@MainActor (AppModel) -> Void)? = nil, _ action: @escaping @MainActor (AppModel) -> Void) {
            let up: (() -> Void)? = released.map { r in { Task { @MainActor in r(AppModel.shared) } } }
            if let k = GlobalHotKey(keyCode: UInt32(code), released: up, action: { Task { @MainActor in action(AppModel.shared) } }) {
                hotKeys.append(k)
            } else {
                hotKeyProblems.append(code)
            }
        }
        key(kVK_ANSI_P) { $0.panic() }
        key(kVK_ANSI_R) { $0.toggleRecording() }
        key(kVK_ANSI_E) { $0.pauseOrResumeRecording() }
        key(kVK_ANSI_M) { $0.togglePlaySelected() }
        key(kVK_ANSI_K, released: { m in
            if m.autoClicker.mode == .hold, m.macroStatus.autoClicking { m.macroCoordinator.stopAutoClicker() }
        }) { m in
            if m.autoClicker.mode == .hold { if !m.macroStatus.autoClicking { m.toggleAutoClicker() } } else { m.toggleAutoClicker() }
        }
    }
}
