import SiverCore
import SiverEngine
import SwiftUI

/// What SiverSol does by itself. Every switch says what it does in one line.
struct AutomationView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Page {
            SectionHeader(title: "Automation", subtitle: "Nothing here uses, buys, sells or crafts an item, and nothing touches your auras. Every key press and click is checked against the screen first.")
            group("Keeping the session alive", "figure.walk") {
                HelpToggle(title: "Anti-AFK", help: "Presses Space in Roblox every 12 to 17 minutes. The key goes straight to Roblox in the background, so your typing is never interrupted.", isOn: $model.antiAFKEnabled)
                HelpToggle(title: "Auto-rejoin", help: "If Roblox disconnects, closes or freezes, reopen your private server and click Play. Never during a rare biome unless it is already disconnected.", isOn: $model.rejoinEnabled)
                HelpToggle(title: "Main-menu watch", help: "If the game sits on its start menu, click Play, and tell you if that fails for 2 minutes.", isOn: $model.extras.menuSentinel)
                HelpToggle(title: "Freeze watchdog", help: "No log activity for 6 minutes while Roblox is open counts as frozen: alert, then recover.", isOn: $model.extras.freezeWatchdog)
                HelpToggle(title: "Network watch", help: "Adds “network dropped” and “network back” to disconnect reports. Sends nothing.", isOn: $model.extras.networkSentinel)
            }
            group("Auras and rolls", "sparkles") {
                HelpToggle(title: "Aura roll feed", help: "Announces “Rolled <aura>” from the game's own roll event, with a screenshot at the cutscene's best moment.", isOn: $model.extras.auraRollFeed)
                HelpToggle(title: "Cutscene lock", help: "No key presses or clicks while a roll cutscene is playing.", isOn: $model.extras.cutsceneLock)
                HelpToggle(title: "Proof screenshots", help: "Attach a screenshot on rare biomes, very rare auras and merchants. The chat and the player list are covered first.", isOn: $model.proofEnabled)
                HelpToggle(title: "Sound cue", help: "Play a sound on this Mac for a rare biome or a rare aura.", isOn: $model.extras.soundCue)
            }
            MomentsSettingsCard()
            group("Session facts", "server.rack") {
                HelpToggle(title: "Session inspector", help: "Shows private or public server, a short server id and join times. Nothing personal is kept.", isOn: $model.extras.sessionInspector)
                HelpToggle(title: "Daily reset countdown", help: "Shows the time until the game's daily reset (00:00 UTC).", isOn: $model.extras.dailyResetCountdown)
                HelpToggle(title: "Daily reset reminder", help: "A Discord message 10 minutes before the daily reset.", isOn: $model.extras.dailyResetPing)
                HelpToggle(title: "Biome statistics", help: "Streaks, longest NORMAL stretch and average gaps, from your own timeline.", isOn: $model.extras.biomeIntelligence)
                HelpToggle(title: "Roblox update watch", help: "Tells you when Roblox updated or an update is waiting.", isOn: $model.extras.updateWatch)
                HelpToggle(title: "Window guard", help: "Warns when the Roblox window is too small for text on screen to be read reliably.", isOn: $model.extras.windowGuard)
            }
            group("Roblox resources", "memorychip") {
                HelpToggle(title: "Resource monitor", help: "Charts Roblox memory and CPU from process statistics. No permission needed.", isOn: $model.extras.resourceMonitor)
                HStack {
                    Text("Alert when memory passes")
                    Stepper("\(Int(model.extras.memoryAlertGB)) GB", value: $model.extras.memoryAlertGB, in: 2...32, step: 1).fixedSize()
                }
                .disabled(!model.extras.resourceMonitor)
                HelpToggle(title: "Rejoin when memory is too high", help: "Restart Roblox through a rejoin when memory is over the limit. Never during a rare biome.", isOn: $model.extras.memoryAutoRejoin)
                    .disabled(!model.extras.resourceMonitor)
            }
            group("Macros", "record.circle") {
                Picker("Macros that may play", selection: $model.extras.macroPolicy) {
                    ForEach(MacroPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .frame(maxWidth: 460)
                Text("“Only macros that cannot leave the server” keeps out any macro that presses Escape or clicks. Glitch Hunt Mode sets this, so a macro can never take you out of a shared server.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            group("Starting and ending", "power") {
                HelpToggle(title: "Start when SiverSol opens", help: "Begin watching as soon as the app launches.", isOn: $model.autoStart)
                HelpToggle(title: "Session Wrapped card", help: "Draw a recap card when a session of ten minutes or more ends. It is saved on this Mac.", isOn: $model.extras.wrappedOnStop)
                HelpToggle(title: "Post the card to Discord", help: "Send the card to the Rich routes that get the daily report. The day's card also rides along with the daily report.", isOn: $model.extras.wrappedPost)
                    .disabled(!model.extras.wrappedOnStop)
            }
            ControlStrip {
                Button("Save") { model.saveSettings(restartIfRunning: true) }.buttonStyle(.skyProminent)
                Button("Check what Guardian would allow now") { model.guardianDryRun() }
                    .help("Looks at the Roblox window and lists what would be allowed. Presses nothing.")
                Text(model.settingsMessage.isEmpty ? "Panic key: ⌃⌥⌘P releases every key and pauses all input, from anywhere." : model.settingsMessage)
                    .font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    private func group(_ title: String, _ symbol: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: title, symbol: symbol)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// The Biome Island's settings (Settings › Island).
struct IslandSettingsCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var island = IslandController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "Island", symbol: IslandGuide.symbol)
            Text("A small live view of the biome and its timer, beside the notch or at the top of the screen. It opens up for a rare biome or a rare roll.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Picker("Show", selection: Binding(get: { island.mode }, set: { island.mode = $0 })) {
                    ForEach(IslandMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu).frame(maxWidth: 300)
                ExplainerButton(label: "About the Biome Island", startOpen: model.reviewNote == "island-help") {
                    Explainer(title: IslandGuide.title, symbol: IslandGuide.symbol, parts: IslandGuide.parts, button: IslandGuide.button) { island.previewResting() }
                }
                .marker("island-help")
                Spacer(minLength: 0)
            }
            HelpToggle(title: "Also over full-screen Roblox", help: "Off: the island stays away while Roblox fills the screen.", isOn: $island.overFullScreen)
            HelpToggle(title: "Keep it out of screenshots and recordings",
                       help: "On: the island is left out of screenshots, screen recordings and shared screens where macOS allows that, and it hides while the display is mirrored.",
                       isOn: $island.outOfCaptures)
            HStack(spacing: 8) {
                Button("Show an example") { island.previewResting() }
                Button("Show a rare example") { island.preview(rare: true, catalog: model.catalog) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
