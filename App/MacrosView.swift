import SiverCore
import SiverEngine
import SiverMacro
import SiverNotify
import SwiftUI

/// Macro Studio: record your own macros, edit them, play them back, and the auto clicker.
struct MacrosView: View {
    static let autoClickerTag = "\u{1}auto-clicker"
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // The library is content: one card on the sky.
            library
                .card(padding: 0)
                .frame(width: 262)
                .padding(.leading, 16).padding(.vertical, 16)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $model.pendingImport) { macro in ImportPreview(macro: macro).environmentObject(model) }
        .confirmationDialog("Move “\(model.macroToDelete ?? "")” to the Trash?", isPresented: Binding(get: { model.macroToDelete != nil }, set: { if !$0 { model.macroToDelete = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let name = model.macroToDelete { model.deleteMacro(name) }
                model.macroToDelete = nil
            }
        } message: { Text("You can put it back from the Trash.") }
        .onAppear { model.reloadMacros() }
    }

    // MARK: left column

    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecorderCard().padding(12)
            Divider()
            List(selection: $model.selectedMacro) {
                Section("Tools") {
                    Label("Auto clicker", systemImage: "cursorarrow.click.2").tag(Self.autoClickerTag)
                }
                Section("Your macros") {
                    ForEach(model.macroList) { macro in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(macro.name).lineLimit(1)
                                if model.macroStatus.playing?.name == macro.name {
                                    Image(systemName: "play.fill").foregroundStyle(.green).font(.caption).accessibilityLabel("playing")
                                }
                                if !macro.reviewed {
                                    Image(systemName: "eye.trianglebadge.exclamationmark").foregroundStyle(Sky.warning).font(.caption).accessibilityLabel("not reviewed")
                                }
                            }
                            Text("\(DiscordTime.duration(macro.duration)) · \(macro.steps.count) steps · \(macro.isKeyboardOnly ? "keys" : "mouse")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(macro.name)
                        .contextMenu {
                            Button("Play") { model.playMacro(macro.name) }
                            Button("Duplicate") { model.duplicateMacro(macro.name) }
                            Button("Export…") { model.exportMacro(macro.name) }
                            Divider()
                            Button("Move to Trash", role: .destructive) { model.macroToDelete = macro.name }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .overlay(alignment: .center) {
                if model.macroList.isEmpty {
                    Text("No macros yet.\nPress Record to make one.").multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary).padding(.top, 90)
                }
            }
            Divider()
            HStack {
                Button { model.chooseMacroToImport() } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                Spacer()
                Button { NSWorkspace.shared.open(MacroLibrary().directory) } label: { Image(systemName: "folder") }
                    .help("Show the Macros folder").accessibilityLabel("Show the Macros folder")
            }
            .buttonStyle(.skyIcon).padding(10)
        }
    }

    // MARK: right column

    @ViewBuilder private var detail: some View {
        if model.selectedMacro == Self.autoClickerTag {
            Page { statusLine; AutoClickerCard() }
        } else if let name = model.selectedMacro, let macro = model.macroList.first(where: { $0.name == name }) {
            MacroDetail(macro: macro, statusLine: AnyView(statusLine)).id(name)
        } else {
            ContentUnavailableView {
                Label("Macro Studio", systemImage: "record.circle")
            } description: {
                Text("Record what you do in Roblox and play it back. Recording keeps only keys and clicks made inside Roblox, and every click is checked by Guardian before it is played.")
            } actions: {
                Button("Record a macro") { model.startRecording() }.buttonStyle(.skyProminent)
                Button("Import a .svmacro file…") { model.chooseMacroToImport() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .card()
            .padding(16)
        }
    }

    @ViewBuilder private var statusLine: some View {
        if let p = model.macroStatus.playing {
            Banner(symbol: "play.circle.fill", text: "Playing “\(p.name)” · loop \(p.loop + 1)\(p.totalLoops == 0 ? "" : " of \(p.totalLoops)") · step \(p.step) of \(p.totalSteps)", tint: .green, actionTitle: "Stop") { model.stopMacro() }
        } else if !model.macroStatus.queued.isEmpty {
            Banner(symbol: "hourglass", text: "Waiting to play: \(model.macroStatus.queued.joined(separator: ", "))", tint: .blue, actionTitle: "Cancel") { model.stopMacro() }
        } else if !model.macroMessage.isEmpty {
            Banner(symbol: "info.circle", text: model.macroMessage, tint: .secondary)
        }
        if model.automationPaused {
            Banner(symbol: "hand.raised.fill", text: "Input is paused (\(model.pauseReason)). Macros will not play until you resume.", tint: .orange, actionTitle: "Resume") { model.resumeAutomation() }
        }
    }
}

/// Record, pause, stop. The same controls are on the floating bar and on ⌃⌥⌘R / ⌃⌥⌘E.
struct RecorderCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let s = model.macroStatus
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if s.recording == .idle {
                    Button { model.startRecording() } label: { Label("Record", systemImage: "record.circle") }
                        .buttonStyle(.skyProminent(Sky.stop))
                        .disabled(s.playing != nil || s.autoClicking)
                        .help("Brings Roblox to the front and starts recording (⌃⌥⌘R)")
                } else {
                    Button { model.pauseOrResumeRecording() } label: { Label(s.recording == .paused ? "Resume" : "Pause", systemImage: s.recording == .paused ? "play.fill" : "pause.fill") }
                    Button { model.stopRecording() } label: { Label("Stop", systemImage: "stop.fill") }.buttonStyle(.skyProminent)
                }
            }
            if s.recording != .idle {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle.fill").foregroundStyle(s.recording == .paused ? Color.orange : Color.red)
                        .symbolEffect(.pulse, isActive: s.recording == .recording).accessibilityHidden(true)
                    Text("\(s.recording == .paused ? "Paused" : "Recording") · \(AppModel.clock(s.recordedSeconds)) · \(s.recordedSteps) steps").monospacedDigit().font(.callout)
                }
            } else {
                Text("Only keys and clicks made while Roblox is the front app are kept.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Skip chat typing", isOn: $model.recorderOptions.skipChatTyping)
                .help("Keys typed after pressing / (until Return or Escape) are left out of the recording.")
                .disabled(s.recording != .idle)
            Toggle("Show the floating bar", isOn: $model.showRecorderBar)
                .help("A small bar with Pause and Stop that floats over Roblox while recording or playing.")
        }
        .font(.callout)
    }
}

/// One macro: playback settings, triggers and the step editor.
struct MacroDetail: View {
    @EnvironmentObject var model: AppModel
    let macro: Macro
    let statusLine: AnyView
    @State private var draft: Macro
    @State private var selected: Set<Int> = []
    @State private var newStep = NewStep()
    @State private var showAddStep = false
    @State private var newTriggerMinutes = 30.0
    @State private var newTriggerBiome = "GLITCHED"

    struct NewStep {
        enum Kind: String, CaseIterable, Identifiable { case wait = "Wait", text = "Wait for text on screen", biome = "Wait for a biome", inGame = "Wait until in the game"
            var id: String { rawValue } }
        var kind: Kind = .wait
        var seconds = 2.0
        var text = "Play"
        var biome = "NORMAL"
        var timeout = 60.0
    }

    init(macro: Macro, statusLine: AnyView) {
        self.macro = macro
        self.statusLine = statusLine
        _draft = State(initialValue: macro)
    }

    private var dirty: Bool { draft != macro }
    private var isPlaying: Bool { model.macroStatus.playing?.name == macro.name }

    /// Notes selected in the piano roll.
    @State private var rollSelection: Set<UUID> = []
    @AppStorage("macroInspectorOpen") private var inspectorOpen = false
    @AppStorage("macroStepListOpen") private var stepListOpen = false

    /// Where playback is in this macro, in seconds.
    private var playhead: Double? {
        guard isPlaying, let p = model.macroStatus.playing else { return nil }
        let times = PianoRoll.times(macro.steps)
        return times.indices.contains(p.step - 1) ? times[p.step - 1] : nil
    }

    var body: some View {
        // The roll is the page. Settings wait in an inspector that slides in over the right edge; the plain step
        // list is one click away.
        Page {
            statusLine
            header
            if !draft.reviewed { reviewBanner }
            PianoRollView(steps: $draft.steps, selection: $rollSelection, playhead: playhead).card()
            ControlStrip {
                Toggle(isOn: $stepListOpen) { Label("Step list", systemImage: "list.number") }.toggleStyle(.button)
                    .help("Every step with its exact delay, and the tools for waits and trimming")
                Toggle(isOn: $inspectorOpen) { Label("Inspector", systemImage: "sidebar.right") }.toggleStyle(.button)
                    .help("Speed, loops, triggers and the other settings of this macro")
                Spacer(minLength: 0)
                Text("Drag a bar to move it, its right edge to change the hold. Shift-click or drag a box to select several.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if stepListOpen { steps }
        }
        .overlay(alignment: .topTrailing) {
            if inspectorOpen {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Inspector").font(Sky.display(17, .bold))
                            Spacer()
                            Button { inspectorOpen = false } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.skyIcon).accessibilityLabel("Close the inspector")
                        }
                        playback
                        triggers
                    }
                    .padding(14)
                }
                .frame(width: 400)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.separator.opacity(0.6)))
                .shadow(color: .black.opacity(0.25), radius: 18, x: -4, y: 6)
                .padding(.vertical, 14).padding(.trailing, 14)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Sky.spring, value: inspectorOpen)
        // The file changed underneath (saved, or edited outside the app): follow it, unless there are unsaved edits here.
        .onChange(of: macro) { old, new in
            if draft == old { draft = new; selected = [] }
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Name", text: $draft.name).textFieldStyle(.plain).font(.title2.weight(.semibold)).accessibilityLabel("Macro name")
                Spacer()
                if dirty {
                    Button("Revert") { draft = macro; selected = [] }
                    Button("Save changes") { save() }.buttonStyle(.skyProminent).keyboardShortcut("s", modifiers: .command)
                }
                Button {
                    if isPlaying { model.stopMacro() } else { model.playMacro(macro.name) }
                } label: { Label(isPlaying ? "Stop" : "Play", systemImage: isPlaying ? "stop.fill" : "play.fill").frame(minWidth: 56) }
                    .buttonStyle(.skyProminent(isPlaying ? Sky.stop : Sky.go))
                    .disabled(dirty || !macro.reviewed || model.macroStatus.recording != .idle)
                    .help(dirty ? "Save your changes first" : (macro.reviewed ? "Play (⌃⌥⌘M)" : "Review the steps first"))
                Menu {
                    Button("Duplicate") { model.duplicateMacro(macro.name) }
                    Button("Export…") { model.exportMacro(macro.name) }
                    Divider()
                    Button("Move to Trash", role: .destructive) { model.macroToDelete = macro.name }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More actions")
            }
            HStack(spacing: 8) {
                chip(DiscordTime.duration(draft.duration), "clock")
                chip("\(draft.steps.count) steps", "list.number")
                chip(draft.isKeyboardOnly ? "Keys only: plays in the background" : "\(draft.clickCount) clicks: needs Roblox in front", draft.isKeyboardOnly ? "keyboard" : "cursorarrow.click")
            }
            if !draft.isKeyboardOnly {
                Text("A macro that uses the mouse brings Roblox to the front, and stops the moment you touch the mouse or keyboard or another app comes to the front.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            TextField("Note (optional)", text: $draft.note).textFieldStyle(.roundedBorder)
        }
        .card()
    }

    private func chip(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.callout).padding(.horizontal, 9).padding(.vertical, 4).background(.quaternary, in: Capsule())
    }

    private var reviewBanner: some View {
        Banner(symbol: "eye.trianglebadge.exclamationmark", text: "This macro came from a file and will not play until you have looked at its steps below.", tint: .orange,
               actionTitle: "I have looked: allow it") { draft.reviewed = true; save() }
    }

    private func save() {
        var m = draft
        m.name = m.name.trimmingCharacters(in: .whitespaces)
        guard !m.name.isEmpty else { model.macroMessage = "A macro needs a name."; return }
        if m.name != macro.name, model.macroList.contains(where: { $0.name == m.name }) { model.macroMessage = "There is already a macro called “\(m.name)”."; return }
        model.saveMacro(m, renamedFrom: m.name == macro.name ? nil : macro.name)
    }

    // MARK: playback settings

    private var playback: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "Playback", symbol: "play.circle")
            HStack {
                Text("Speed")
                Picker("Speed", selection: $draft.settings.speed) {
                    ForEach([0.25, 0.5, 1.0, 2.0, 5.0, 10.0], id: \.self) { v in
                        Text(v == 1 ? "Real time" : (v < 1 ? String(format: "%.2g×", v) : String(format: "%.0f×", v))).tag(v)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
            }
            HStack(spacing: 16) {
                Toggle("Loop forever", isOn: Binding(get: { draft.settings.loops == 0 }, set: { draft.settings.loops = $0 ? 0 : 1 }))
                if draft.settings.loops != 0 {
                    Stepper("Play \(draft.settings.loops) time\(draft.settings.loops == 1 ? "" : "s")", value: $draft.settings.loops, in: 1...10_000).fixedSize()
                }
                Stepper("Wait \(String(format: "%.1f", draft.settings.loopDelayS)) s between loops", value: $draft.settings.loopDelayS, in: 0...3600, step: 0.5).fixedSize()
            }
            HelpToggle(title: "Humanize", help: "Vary each delay by a few milliseconds and each click by a hair, so playback is not perfectly identical.", isOn: $draft.settings.humanize)
            HelpToggle(title: "Stop when a rare biome starts", help: "GLITCHED, DREAMSPACE, CYBERSPACE and SINGULARITY stop this macro, and it will not start while one is running.", isOn: $draft.settings.pauseDuringRareBiomes)
            HelpToggle(title: "Allow clicks on the item bar and the menu buttons",
                       help: "Off by default. Those clicks, and any click while the Inventory or a crafting window is open, can use an item or open a menu. So each macro needs your say-so, and they are limited per hour. Guardian still blocks Aura Storage, trades and Robux prompts.",
                       isOn: $draft.settings.allowItemAndMenuClicks)
            if draft.settings.allowItemAndMenuClicks {
                Stepper("At most \(draft.settings.itemClickHourlyCap) such clicks per hour", value: $draft.settings.itemClickHourlyCap, in: 1...600).fixedSize()
            }
            HStack {
                Picker("Tell Discord", selection: $draft.settings.notify) {
                    ForEach(MacroNotify.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .frame(maxWidth: 320)
                Text("Posts go to Rich routes that have Macros switched on, while SiverSol is running.").font(.caption).foregroundStyle(.secondary)
            }
            Picker("When it finishes, play", selection: Binding(get: { draft.settings.chainTo ?? "" }, set: { draft.settings.chainTo = $0.isEmpty ? nil : $0 })) {
                Text("Nothing").tag("")
                ForEach(model.macroList.filter { $0.name != macro.name }) { Text($0.name).tag($0.name) }
            }
            .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: triggers

    private var triggers: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "Start by itself", symbol: "bolt.badge.clock")
            if draft.settings.triggers.isEmpty {
                Text("Only when you press Play. Add a trigger to start it on a schedule or with a biome. Triggers work while SiverSol is running; one macro plays at a time and the rest wait their turn.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(draft.settings.triggers.enumerated()), id: \.offset) { index, trigger in
                HStack {
                    Image(systemName: "bolt").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(trigger.label.prefix(1).uppercased() + trigger.label.dropFirst())
                    Spacer()
                    Button { draft.settings.triggers.remove(at: index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.skyIcon).accessibilityLabel("Remove trigger: \(trigger.label)")
                }
            }
            HStack {
                Menu("Add a trigger") {
                    Button("Every \(Int(newTriggerMinutes)) minutes") { add(.everyMinutes(newTriggerMinutes)) }
                    Button("When \(newTriggerBiome) starts") { add(.biomeStarted(newTriggerBiome)) }
                    Button("When \(newTriggerBiome) ends") { add(.biomeEnded(newTriggerBiome)) }
                    Button("After a successful rejoin") { add(.afterRejoin) }
                    Button("At the daily reset") { add(.dailyReset) }
                }
                .fixedSize()
                Stepper("\(Int(newTriggerMinutes)) min", value: $newTriggerMinutes, in: 1...1440, step: 5).fixedSize()
                Picker("Biome", selection: $newTriggerBiome) {
                    ForEach(model.catalog.all, id: \.key) { Text($0.key.value).tag($0.key.value) }
                }
                .frame(maxWidth: 220)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func add(_ trigger: MacroTrigger) {
        if !draft.settings.triggers.contains(trigger) { draft.settings.triggers.append(trigger) }
    }

    // MARK: steps

    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardTitle(title: "Steps", symbol: "list.number")
                Spacer()
                Button("Trim to selection") { trimToSelection() }.disabled(selected.count < 1)
                    .help("Keep only the selected steps and everything between them")
                Button("Delete") { deleteSelection() }.disabled(selected.isEmpty)
                    .help("Delete the selected steps. The time they took is kept, so the rest stays in rhythm.")
                Button("Merge mouse moves") { draft.steps = MacroEditing.mergeMouseMoves(draft.steps); selected = [] }
                    .help("Turn each run of mouse moves into a single move. Total time is unchanged.")
                Button("Add a step…") { showAddStep = true }
                    .popover(isPresented: $showAddStep, arrowEdge: .bottom) { addStepForm }
            }
            if selected.count == 1, let i = selected.first, draft.steps.indices.contains(i) {
                HStack {
                    Text("Step \(i + 1): \(draft.steps[i].summary)").lineLimit(1)
                    Spacer()
                    Text("Delay before it")
                    TextField("seconds", value: Binding(get: { draft.steps.indices.contains(i) ? draft.steps[i].delay : 0 },
                                                         set: { if draft.steps.indices.contains(i) { draft.steps[i].delay = min(3600, max(0, $0)) } }), format: .number.precision(.fractionLength(0...3)))
                        .textFieldStyle(.roundedBorder).frame(width: 90).accessibilityLabel("Delay before this step, in seconds")
                    Text("s")
                }
                .font(.callout)
            } else {
                Text(selected.isEmpty ? "Select a step to change its delay. Shift-click or ⌘-click selects several." : "\(selected.count) steps selected")
                    .font(.callout).foregroundStyle(.secondary)
            }
            List(draft.steps.indices, id: \.self, selection: $selected) { i in
                let step = draft.steps[i]
                HStack(spacing: 10) {
                    Text("\(i + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                    Text(String(format: "+%.3f s", step.delay)).monospacedDigit().foregroundStyle(.secondary).frame(width: 86, alignment: .leading)
                    Image(systemName: symbol(for: step.action)).frame(width: 18).foregroundStyle(step.action.isSmart ? Color.purple : Color.secondary).accessibilityHidden(true)
                    Text(step.summary)
                    Spacer()
                    if case .mouseDown(_, let x, let y) = step.action, MacroZones.isItemOrMenu(x: x, y: y) {
                        Text("item bar or menu").font(.caption).foregroundStyle(Sky.warning)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            .frame(height: 340)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            if draft.steps.isEmpty { Text("This macro has no steps.").foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func symbol(for action: MacroAction) -> String {
        switch action {
        case .keyDown: return "arrowtriangle.down.square"
        case .keyUp: return "arrowtriangle.up.square"
        case .mouseMove: return "cursorarrow.motionlines"
        case .mouseDown, .mouseUp: return "cursorarrow.click"
        case .mouseDelta: return "arrow.triangle.2.circlepath.camera"
        case .scroll: return "arrow.up.and.down"
        case .wait: return "hourglass"
        case .waitText: return "text.viewfinder"
        case .waitBiome: return "cloud.sun"
        case .waitInGame: return "gamecontroller"
        }
    }

    private func trimToSelection() {
        guard let lo = selected.min(), let hi = selected.max() else { return }
        draft.steps = MacroEditing.trim(draft.steps, to: lo..<(hi + 1))
        selected = []
    }

    private func deleteSelection() {
        // Runs of neighbouring steps are removed from the end backwards, so earlier indexes stay valid.
        var steps = draft.steps
        var run: [Int] = []
        for i in selected.sorted(by: >) {
            if let last = run.last, last - 1 != i {
                steps = MacroEditing.delete(steps, range: run.last!..<(run.first! + 1))
                run = []
            }
            run.append(i)
        }
        if let lo = run.last, let hi = run.first, lo >= 0, hi < steps.count { steps = MacroEditing.delete(steps, range: lo..<(hi + 1)) }
        draft.steps = steps
        selected = []
    }

    private var addStepForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a step").font(.headline)
            Picker("Kind", selection: $newStep.kind) {
                ForEach(NewStep.Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            switch newStep.kind {
            case .wait:
                Stepper("Wait \(String(format: "%.1f", newStep.seconds)) seconds", value: $newStep.seconds, in: 0.1...3600, step: 0.5)
            case .text:
                TextField("Text to wait for, for example Play", text: $newStep.text).textFieldStyle(.roundedBorder)
                Text("SiverSol reads the Roblox window once a second until the text is there.").font(.caption).foregroundStyle(.secondary)
            case .biome:
                Picker("Biome", selection: $newStep.biome) {
                    ForEach(model.catalog.all, id: \.key) { Text($0.key.value).tag($0.key.value) }
                }
            case .inGame:
                Text("Waits until the log says you are in the game (not on the start menu).").font(.caption).foregroundStyle(.secondary)
            }
            if newStep.kind != .wait {
                Stepper("Give up after \(Int(newStep.timeout)) seconds", value: $newStep.timeout, in: 5...3600, step: 5)
            }
            Text(selected.isEmpty ? "It is added at the end." : "It is added after the last selected step.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showAddStep = false }
                Button("Add") { insertStep(); showAddStep = false }.buttonStyle(.skyProminent)
                    .disabled(newStep.kind == .text && newStep.text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16).frame(width: 340)
    }

    private func insertStep() {
        let action: MacroAction
        switch newStep.kind {
        case .wait: action = .wait(seconds: newStep.seconds)
        case .text: action = .waitText(text: newStep.text.trimmingCharacters(in: .whitespaces), timeoutS: newStep.timeout)
        case .biome: action = .waitBiome(biome: newStep.biome, timeoutS: newStep.timeout)
        case .inGame: action = .waitInGame(timeoutS: newStep.timeout)
        }
        let index = (selected.max().map { $0 + 1 }) ?? draft.steps.count
        draft.steps.insert(MacroStep(delay: 0, action), at: min(index, draft.steps.count))
        selected = []
    }
}

/// The auto clicker: clicks where the pointer is, inside the Roblox window only, each click checked by Guardian.
struct AutoClickerCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let running = model.macroStatus.autoClicking
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "Auto clicker", subtitle: "Clicks where your pointer is, only inside the Roblox window and only while Roblox is the front app. It never clicks the item bar or the menu buttons, stops if the Inventory or a crafting window is open, and Guardian checks the screen while it runs.")
                Button { model.toggleAutoClicker() } label: { Label(running ? "Stop" : "Start", systemImage: running ? "stop.fill" : "play.fill").frame(minWidth: 60) }
                    .buttonStyle(.skyProminent(running ? Sky.stop : Sky.go)).controlSize(.large)
                    .help("⌃⌥⌘K")
            }
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(title: "How it clicks", symbol: "cursorarrow.click.2")
                Toggle("Random interval", isOn: $model.autoClicker.randomize)
                if model.autoClicker.randomize {
                    HStack {
                        Stepper("Between \(Int(model.autoClicker.minMs)) ms", value: $model.autoClicker.minMs, in: 10...10_000, step: 10).fixedSize()
                        Stepper("and \(Int(model.autoClicker.maxMs)) ms", value: $model.autoClicker.maxMs, in: 10...10_000, step: 10).fixedSize()
                    }
                } else {
                    Stepper("Every \(Int(model.autoClicker.intervalMs)) ms (\(String(format: "%.1f", 1000 / max(1, model.autoClicker.intervalMs))) clicks a second)", value: $model.autoClicker.intervalMs, in: 10...10_000, step: 10).fixedSize()
                }
                Picker("Button", selection: $model.autoClicker.button) {
                    ForEach(MouseButton.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented).frame(maxWidth: 300)
                Picker("⌃⌥⌘K", selection: $model.autoClicker.mode) {
                    Text("Press to start, press to stop").tag(AutoClickerConfig.Mode.toggle)
                    Text("Clicks while held").tag(AutoClickerConfig.Mode.hold)
                }
                .frame(maxWidth: 380)
                HStack(spacing: 16) {
                    Toggle("Stop after", isOn: Binding(get: { model.autoClicker.stopAfterClicks != nil }, set: { model.autoClicker.stopAfterClicks = $0 ? 1000 : nil }))
                    if model.autoClicker.stopAfterClicks != nil {
                        Stepper("\(model.autoClicker.stopAfterClicks ?? 0) clicks", value: Binding(get: { model.autoClicker.stopAfterClicks ?? 1000 }, set: { model.autoClicker.stopAfterClicks = $0 }), in: 1...1_000_000, step: 100).fixedSize()
                    }
                    Toggle("Stop after", isOn: Binding(get: { model.autoClicker.stopAfterMinutes != nil }, set: { model.autoClicker.stopAfterMinutes = $0 ? 5 : nil }))
                    if model.autoClicker.stopAfterMinutes != nil {
                        Stepper("\(Int(model.autoClicker.stopAfterMinutes ?? 0)) minutes", value: Binding(get: { model.autoClicker.stopAfterMinutes ?? 5 }, set: { model.autoClicker.stopAfterMinutes = $0 }), in: 1...1440).fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            .disabled(running)

            VStack(alignment: .leading, spacing: 8) {
                CardTitle(title: "Totals", symbol: "chart.bar")
                let a = model.macroStats.autoClicker
                KeyValueRow(label: "Clicks", value: "\(a.totalClicks)")
                KeyValueRow(label: "Runs", value: "\(a.runs)")
                KeyValueRow(label: "Average speed", value: a.totalSeconds > 0 ? String(format: "%.1f clicks a second", a.averageCPS) : "no runs yet")
                let today = model.macroStats.days[TimelineStore.day(Date())]
                KeyValueRow(label: "Today", value: "\(today?.autoClicks ?? 0) clicks · \(today?.runs ?? 0) macro runs · \(today?.recordings ?? 0) recordings")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }
}

/// Shown before an imported macro is added: what it is and every step it would play.
struct ImportPreview: View {
    @EnvironmentObject var model: AppModel
    let macro: Macro

    var body: some View {
        let risky = macro.steps.filter { if case .mouseDown(_, let x, let y) = $0.action { return MacroZones.isItemOrMenu(x: x, y: y) }; return false }.count
        VStack(alignment: .leading, spacing: 12) {
            Label("Add this macro?", systemImage: "square.and.arrow.down").font(.title2.weight(.semibold))
            Text("“\(macro.name)” came from a file. Look through what it does before adding it. A macro can only press keys and click inside Roblox, and Guardian checks every click.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                KeyValueRow(label: "Length", value: DiscordTime.duration(macro.duration))
                KeyValueRow(label: "Steps", value: "\(macro.steps.count)")
                KeyValueRow(label: "Key presses", value: "\(macro.keyCount)")
                KeyValueRow(label: "Clicks", value: "\(macro.clickCount)")
            }
            if risky > 0 {
                Label("\(risky) click\(risky == 1 ? "" : "s") on the item bar or the menu buttons. They stay blocked unless you allow them in this macro's settings.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Sky.warning).fixedSize(horizontal: false, vertical: true)
            }
            Text("Its triggers and its “play another macro afterwards” setting were removed. You can add your own.").font(.callout).foregroundStyle(.secondary)
            List(macro.steps.indices.prefix(2000), id: \.self) { i in
                HStack(spacing: 10) {
                    Text("\(i + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                    Text(String(format: "+%.3f s", macro.steps[i].delay)).monospacedDigit().foregroundStyle(.secondary).frame(width: 86, alignment: .leading)
                    Text(macro.steps[i].summary)
                }
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            if macro.steps.count > 2000 { Text("Showing the first 2,000 steps of \(macro.steps.count).").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") { model.pendingImport = nil }.keyboardShortcut(.cancelAction)
                Button("I have looked: add it") { model.confirmImport() }.buttonStyle(.skyProminent)
            }
        }
        .padding(22)
        .frame(width: 600)
    }
}
