import SiverCore
import SiverNotify
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Page {
            SectionHeader(title: "Settings")
            ProfilesCard()
            IslandSettingsCard()
            server
            SetupSection()
            shortcuts
            TipsSettingsCard()
            FunSettingsCard()
            data
            ControlStrip {
                Button("Save") { model.saveSettings(restartIfRunning: true) }
                    .keyboardShortcut("s", modifiers: .command).buttonStyle(.skyProminent)
                Text(model.settingsMessage).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    private var server: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(title: "Private server", symbol: "link")
            SecureField("https://www.roblox.com/share?code=…&type=Server", text: Binding(
                get: { model.secrets.privateServerLink ?? "" },
                set: { model.secrets.privateServerLink = $0.isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Private server link")
            HStack {
                Text(model.secrets.serverLink == nil ? "Not set, or not a roblox.com link. Auto-rejoin and the Join button need it."
                                                     : "Kept in your Keychain. Used for the Join button and to rejoin your own server, nothing else.")
                    .font(.callout).foregroundStyle(model.secrets.serverLink == nil ? AnyShapeStyle(Sky.warning) : AnyShapeStyle(.secondary))
                Spacer()
                Button("Copy link") { model.copyServerLink() }.disabled(model.secrets.serverLink == nil)
            }
        }
        .card()
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(title: "Shortcuts that work from any app", symbol: "keyboard")
            ForEach(AppModel.shortcutHelp, id: \.keys) { s in
                HStack {
                    Text(s.keys).fontWeight(.medium).frame(width: 76, alignment: .leading)
                    Text(s.what).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Divider()
            HelpToggle(title: "Let siversol:// links control SiverSol without asking",
                       help: "Links such as siversol://macro/play?name=… can come from anywhere. While this is off, SiverSol asks you each time before it acts on one.",
                       isOn: $model.linkCommandsAllowed)
        }
        .card()
    }

    private var data: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(title: "Your data", symbol: "folder")
            Text("The timeline, the queue of unsent messages, your macros and recent proof shots live in one folder on this Mac.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Show the folder") { model.revealDataFolder() }
                Button("Import a secrets file…") { model.chooseSecretsFile() }
                    .help("For people who built SiverSol from source: copies a secrets JSON file into the Keychain.")
                Button("Run setup again") { model.showOnboarding = true }
            }
        }
        .card()
    }
}

/// Permissions and the basics SiverSol needs, each with a live status and its "?".
struct SetupSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "Setup and permissions", symbol: "lock.shield")
            Text("SiverSol asks macOS for exactly two permissions. Biome detection and Discord alerts work without either of them.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            PermissionList(topics: PermissionGuide.topics)
            HStack(spacing: 12) {
                StatusDot(on: model.permissions.robloxInstalled, onLabel: "Roblox is installed", offLabel: "Roblox is not installed")
                Text(model.permissions.robloxInstalled ? (model.permissions.robloxRunning ? "Roblox is open." : "Roblox is installed. Open it and join your private server.")
                                                      : "Roblox is not installed on this Mac.")
                Spacer()
                Button("Take a test screenshot") { model.testScreenshot() }.disabled(!model.permissions.screenRecording)
            }
            if !model.testShotMessage.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Text(model.testShotMessage).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if let shot = model.testShot {
                        Image(nsImage: shot).resizable().aspectRatio(contentMode: .fit).frame(height: 110)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .accessibilityLabel("Test screenshot of the Roblox window")
                    }
                }
            }
            if !model.permissions.allGranted {
                Text("After you switch a permission on, macOS may ask you to quit and reopen SiverSol. If SiverSol appears twice in the list, remove both entries with – and allow it again.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button("Privacy & Permissions in full") { model.selection = .about; model.aboutShowsPrivacy = true }
        }
        .card()
    }
}
