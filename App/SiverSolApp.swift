import AppKit
import SiverCore
import SiverInput
import SiverNotify
import SwiftUI

@main
struct SiverSolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        Window("SiverSol", id: "main") {
            MainWindow()
                .environmentObject(model)
                .frame(minWidth: 940, minHeight: 600)
        }
        .defaultSize(width: 1120, height: 740)
        .commands { SiverCommands(model: model) }

        MenuBarExtra(isInserted: .constant(!DesignReview.isOn)) {
            MenuPopover().environmentObject(model)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar item's text. It watches only the small menu bar model, so a ticking countdown redraws nothing else.
struct MenuBarLabel: View {
    @ObservedObject private var bar = MenuBarModel.shared
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: bar.symbol)
            if !bar.title.isEmpty { Text(bar.title).monospacedDigit() }
        }
        .accessibilityLabel("SiverSol")
    }
}

/// Files (`.svmacro`) and `siversol://` links arrive here, and keys are let go when the app quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls { AppModel.shared.handle(url: url) }
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Global shortcuts are registered once the app is up: registered earlier (while the app object is
        // still being created) they are accepted but never fire.
        MainActor.assumeIsolated {
            guard !AppModel.isTestHost else { return }
            AppModel.shared.installHotKeys()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            let model = AppModel.shared
            model.engine?.macros.shutdown(.user)
            model.standaloneMacros?.shutdown(.user)
            InputDriver().releaseAll()
        }
    }
}

struct SiverCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .printItem) {}
        CommandMenu("Go") {
            ForEach(AppSection.allCases) { section in
                if let key = section.shortcut {
                    Button(section.title) { model.selection = section }.keyboardShortcut(key, modifiers: .command)
                } else {
                    Button(section.title) { model.selection = section }
                }
            }
        }
        CommandMenu("Control") {
            Button(model.isRunning ? "Pause" : "Start") { model.toggle() }
                .keyboardShortcut("p", modifiers: .command)
            Button("Send Test Message to Discord") { model.sendTestMessage() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(model.testRoute == nil)
            Divider()
            if model.automationPaused {
                Button("Resume Automation") { model.resumeAutomation() }
            } else {
                Button("Panic: Pause All Input (⌃⌥⌘P)") { model.panic() }
            }
            Button("Rejoin Private Server Now") { model.rejoinNow() }.disabled(!model.isRunning)
            Button("Check What Guardian Would Allow…") { model.guardianDryRun() }
            Divider()
            Button(model.macroStatus.recording == .idle ? "Record a Macro (⌃⌥⌘R)" : "Stop Recording (⌃⌥⌘R)") { model.toggleRecording() }
            Button("Play or Stop the Selected Macro (⌃⌥⌘M)") { model.togglePlaySelected() }
        }
    }
}

struct MainWindow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columns = NavigationSplitViewVisibility.automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 290)
        } detail: {
            Group {
                switch model.selection {
                case .dashboard: DashboardView()
                case .timeline: TimelinePage()
                case .auras: AurasView()
                case .moments: MomentsView()
                case .notifications: NotificationsView()
                case .automation: AutomationView()
                case .logLab: LogLabView()
                case .settings: SettingsView()
                case .about: AboutView()
                case .tips: TipsView()
                case .macros: MacrosView()
                }
            }
            .id(model.selection)
            .transition(.opacity)
            // Every action on a page is a real button with legible text; a page opts a button into
            // `.skyProminent` for its one primary action.
            .buttonStyle(.sky)
            .modifier(AccentTint())
            // A rare visitor (see App/Eggs). It takes no clicks.
            .overlay { GlimmerOverlay() }
            .navigationTitle(model.selection.title)
            .scrollContentBackground(.hidden)
            .toolbar { toolbar }
            .modifier(NoToolbarTitle())
        }
        // The three layers: the sky at the back, content cards on it, and the system's glass (sidebar, toolbar,
        // controls) in front.
        .skyWindowBackground()
        .tint(Sky.steel)
        .onAppear { if DesignReview.isOn { columns = .all } }
        .onChange(of: model.reviewNote) { _, note in
            // Design review: photograph the collapsed sidebar.
            if DesignReview.isOn { columns = note == "sidebar-collapsed" ? .detailOnly : .all }
        }
        .animation(reduceMotion ? nil : Sky.spring, value: model.selection)
        .sheet(isPresented: $model.showOnboarding) { OnboardingView().environmentObject(model) }
        .alert("What Guardian would allow right now", isPresented: Binding(get: { model.guardianReport != nil }, set: { if !$0 { model.guardianReport = nil } })) {
            Button("OK") { model.guardianReport = nil }
        } message: {
            Text(model.guardianReport ?? "")
        }
        .alert("A link wants SiverSol to \(model.pendingLink.map(model.describe(link:)) ?? "")",
               isPresented: Binding(get: { model.pendingLink != nil }, set: { if !$0 { model.pendingLink = nil } })) {
            Button("Allow once") { if let url = model.pendingLink { model.run(link: url) }; model.pendingLink = nil }
            Button("Always allow links") { model.linkCommandsAllowed = true; if let url = model.pendingLink { model.run(link: url) }; model.pendingLink = nil }
            Button("Don't", role: .cancel) { model.pendingLink = nil }
        } message: {
            Text("Links like this can come from a web page or a message. Only allow it if you opened it on purpose.")
        }
    }

    /// The control layer: system toolbar items, which are Liquid Glass on macOS 26 and later.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .status) {
            HStack(spacing: 6) {
                StatusDot(on: model.runState == .running && !model.automationPaused, onLabel: "Running", offLabel: "Not running")
                Text(statusWord).font(.callout.weight(.medium))
            }
            .padding(.horizontal, 6)
            .accessibilityElement(children: .combine)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.toggle() } label: {
                Label(model.isRunning ? "Pause" : "Start", systemImage: model.isRunning ? "pause.fill" : "play.fill")
            }
            .labelStyle(.titleAndIcon)
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
            .help(model.isRunning ? "Stop watching and stop all input (⌘P)" : "Start watching the Roblox log (⌘P)")
        }
    }

    private var statusWord: String {
        if model.isRunning && model.automationPaused { return "Input paused" }
        switch model.runState {
        case .running: return "Watching"
        case .starting: return "Starting…"
        case .stopped: return "Resting"
        case .attention: return "Needs a look"
        }
    }

}

extension View {
    /// Put the Living Sky behind the whole window, sidebar and toolbar included.
    ///
    /// The sky is the window's own background, so the real sky (not a mirrored copy) is what shows through the
    /// sidebar's glass. On macOS 26 the backdrop also takes `backgroundExtensionEffect()`, which lets the system
    /// carry it under the sidebar and inspectors wherever a layout would otherwise stop it at a safe-area edge.
    @ViewBuilder func skyWindowBackground() -> some View {
        if #available(macOS 26.0, *) {
            self.containerBackground(for: .window) { SkyBackdrop().ignoresSafeArea().backgroundExtensionEffect() }
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else if #available(macOS 15.0, *) {
            self.containerBackground(for: .window) { SkyBackdrop().ignoresSafeArea() }
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self.background { SkyBackdrop().ignoresSafeArea() }
        }
    }
}

/// The menu bar popover: a small dashboard and the handful of actions you want without opening the window.
struct MenuPopover: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            biome
            if model.macroStatus.recording != .idle {
                Label("Recording a macro · \(AppModel.clock(model.macroStatus.recordedSeconds))", systemImage: "record.circle.fill").foregroundStyle(.red).monospacedDigit()
            } else if let p = model.macroStatus.playing {
                Label("Playing “\(p.name)”", systemImage: "play.circle.fill").foregroundStyle(.green)
            }
            if case .attention(let why) = model.runState {
                Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Sky.warning).fixedSize(horizontal: false, vertical: true)
            }
            if model.reading.outboxDepth > 0 { Text("\(model.reading.outboxDepth) messages waiting to send").font(.callout).foregroundStyle(.secondary) }
            Divider()
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                action(model.isRunning ? "Pause" : "Start", model.isRunning ? "pause.fill" : "play.fill", prominent: true) { model.toggle() }
                if model.automationPaused {
                    action("Resume input", "hand.raised.slash") { model.resumeAutomation() }
                } else {
                    action("Panic", "hand.raised.fill") { model.panic() }
                }
                action("Copy server link", "link") { model.copyServerLink() }.disabled(model.secrets.serverLink == nil)
                action("Test webhook", "paperplane") { model.sendTestMessage() }.disabled(model.testRoute == nil)
                action("Open channel", "arrow.up.forward.app") { model.openChannel() }.disabled(!model.hasWebhook)
                action("Open SiverSol", "macwindow") {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            }
            ProfileMenu().environmentObject(model).frame(maxWidth: .infinity, alignment: .leading)
            if !model.settingsMessage.isEmpty { Text(model.settingsMessage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Divider()
            HStack {
                Text("SiverSol \(SiverSol.version)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") {
                    model.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { NSApplication.shared.terminate(nil) }
                }
                .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    @ViewBuilder private var biome: some View {
        if let c = model.isRunning ? model.snapshot.current : nil {
            let info = model.catalog.info(for: c.biome.key)
            HStack(spacing: 12) {
                BiomeGlyph(info: info, size: 30, night: SkyState.shared.isNight).foregroundStyle(info.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.biome.key.value).font(Sky.display(17, .bold))
                    Ticker { context in
                        let elapsed = context.date.timeIntervalSince(c.since)
                        if let d = info.durationS, c.observedStart {
                            let left = Double(d) - elapsed
                            Text(left > 0 ? "\(AppModel.clock(left)) left" : "any moment now").font(Sky.mono(12)).foregroundStyle(.secondary)
                        } else {
                            Text("running \(AppModel.clock(elapsed))").font(Sky.mono(12)).foregroundStyle(.secondary)
                        }
                    }
                    if let aura = model.snapshot.equippedAura { Label(model.auras.display(for: aura), systemImage: "sparkles").font(.callout).lineLimit(1) }
                }
                Spacer()
            }
            .padding(12)
            .background(LinearGradient(colors: [info.tint.opacity(0.4), info.tint.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 12) {
                Image(systemName: model.isRunning ? "hourglass" : "pause.circle").font(.system(size: 30)).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isRunning ? (model.automationPaused ? "Input paused" : "Waiting for the game") : "Paused").font(.title3.weight(.bold))
                    Text(model.isRunning ? "Open Sol's RNG in Roblox." : (model.hasWebhook ? "Press Start to watch the Roblox log." : "Open SiverSol to set it up.")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private func action(_ title: String, _ symbol: String, prominent: Bool = false, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(prominent ? .accentColor : nil)
        .controlSize(.large)
    }
}


/// Every page carries its own title, so the window's toolbar does not repeat it (the window keeps its name
/// for Mission Control and the Window menu).
struct NoToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { content.toolbar(removing: .title) } else { content }
    }
}
