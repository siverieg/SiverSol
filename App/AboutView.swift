import SiverCore
import SwiftUI

struct AboutView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Page {
            ControlStrip {
                Picker("", selection: $model.aboutShowsPrivacy) {
                    Text("About").tag(false)
                    Text("Privacy & Permissions").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 340)
            }
            if model.aboutShowsPrivacy { PrivacyPage() } else { about }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                BrandMark(size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("SiverSol").font(.largeTitle.weight(.bold))
                    Text("Version \(SiverSol.version)").foregroundStyle(.secondary)
                    Text("Made by siverieg")
                    if EggDirector.shared.hunter {
                        Label("Egg Hunter", systemImage: "rosette").font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3).background(Color.primary.opacity(0.10), in: Capsule())
                            .help("You have seen every rare sky surprise.")
                    }
                }
            }
            Text("An AFK macro and Discord notifier for Sol's RNG on the Mac. It reads the Roblox log to know the biome and your aura, posts to your own Discord webhooks, keeps the session alive and brings Roblox back after a disconnect.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Not affiliated with Roblox or Sol's RNG.")
                Text("Aura names and odds, biome durations and merchant wording: Sol's RNG Wiki, licensed CC BY-SA.")
            }
            .font(.callout).foregroundStyle(.secondary)
            HStack {
                Link("Source code on GitHub", destination: URL(string: SiverSol.sourceURL)!)
                Button("Privacy & Permissions") { model.aboutShowsPrivacy = true }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// Everything SiverSol asks for and everything people reasonably worry about, in one place, with live status.
struct PrivacyPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: "Privacy & Permissions",
                          subtitle: "SiverSol asks macOS for exactly two permissions. A green dot means it is on right now; grey means off. Press ? on any row for the full answer.")
            PermissionList(topics: PermissionGuide.topics)
                .accessibilityIdentifier("privacy-permission-list")

            ForEach(PermissionGuide.topics) { topic in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        StatusDot(on: model.isGranted(topic), onLabel: "\(topic.title) is on", offLabel: "\(topic.title) is off")
                        Label(topic.title, systemImage: topic.symbol).font(.headline)
                    }
                    ForEach(topic.parts.dropLast(), id: \.id) { part in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(part.heading).font(.subheadline.weight(.semibold))
                            Text(part.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button(topic.settingsButton) { model.openSettings(topic) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }

            VStack(alignment: .leading, spacing: 6) {
                CardTitle(title: "What SiverSol does not ask for", symbol: "hand.raised")
                Text(PermissionGuide.notRequested.joined(separator: " · ")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !model.recorderCheck.isEmpty {
                    Text("Last recording on this Mac: \(model.recorderCheck).").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            ForEach(PermissionGuide.notes) { note in
                VStack(alignment: .leading, spacing: 6) {
                    CardTitle(title: note.title, symbol: note.symbol)
                    Text(note.text).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }

            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal").foregroundStyle(.secondary).accessibilityHidden(true)
                Text("Verify it yourself:")
                Link("source code on GitHub", destination: URL(string: SiverSol.sourceURL)!)
            }
        }
    }
}
