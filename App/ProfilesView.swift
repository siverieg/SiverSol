import SiverCore
import SiverEngine
import SiverNotify
import SwiftUI

extension AppModel {
    /// The built-in profiles and the user's own.
    var profiles: [Profile] { Profiles.all(custom: extras.profiles) }
    var activeProfile: String? { config.profileName }

    /// Switch to a profile: its settings go on top of the current ones, are saved, and take effect at once.
    func applyProfile(_ profile: Profile) {
        var toggles = ProfileToggles(antiAFK: antiAFKEnabled, rejoin: rejoinEnabled, island: IslandController.shared.mode)
        Profiles.apply(profile, to: &config, extras: &extras, toggles: &toggles)
        antiAFKEnabled = toggles.antiAFK
        rejoinEnabled = toggles.rejoin
        IslandController.shared.mode = toggles.island
        saveSettings(restartIfRunning: true)
        settingsMessage = "Profile: \(profile.name)."
    }

    func applyProfile(named name: String) -> Bool {
        guard let p = profiles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return false }
        applyProfile(p)
        return true
    }

    /// Keep the current settings as a profile of the user's own.
    func saveCurrentAsProfile(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !Profiles.isBuiltIn(trimmed) else { settingsMessage = "Pick a name that is not one of the built-in profiles."; return }
        let toggles = ProfileToggles(antiAFK: antiAFKEnabled, rejoin: rejoinEnabled, island: IslandController.shared.mode)
        let profile = Profiles.capture(name: trimmed, config: config, extras: extras, toggles: toggles)
        extras.profiles.removeAll { $0.name == trimmed }
        extras.profiles.append(profile)
        config.profileName = trimmed
        saveSettings(restartIfRunning: false)
    }

    func deleteProfile(_ name: String) {
        extras.profiles.removeAll { $0.name == name }
        if config.profileName == name { config.profileName = nil }
        saveSettings(restartIfRunning: false)
    }
}

/// Profiles: named presets that switch routes, pings, quiet hours, macros, anti-AFK, Moments and the island together.
struct ProfilesCard: View {
    @EnvironmentObject var model: AppModel
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "Profiles", symbol: "square.stack.3d.up.fill")
            Text("One click changes pings, quiet hours, macros, anti-AFK, Moments and the Biome Island together. A profile only touches what it is about; everything else stays as you set it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                ForEach(model.profiles) { profile in tile(profile) }
            }
            HStack {
                TextField("Name for your current settings", text: $newName).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Button("Save as profile") { model.saveCurrentAsProfile(name: newName); newName = "" }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .card()
    }

    private func tile(_ profile: Profile) -> some View {
        let active = model.activeProfile == profile.name
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: profile.symbol).symbolRenderingMode(.hierarchical).font(.title3).foregroundStyle(active ? Sky.steel : Color.secondary)
                    .accessibilityHidden(true)
                Text(profile.name).font(Sky.display(15, .bold))
                Spacer()
                if active {
                    Text("Active").font(.caption.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2).background(Sky.steel.opacity(0.25), in: Capsule())
                }
            }
            Text(profile.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if active {
                    Button("Apply again") { model.applyProfile(profile) }
                } else {
                    Button("Switch to this") { model.applyProfile(profile) }.buttonStyle(.skyProminent)
                }
                if !Profiles.isBuiltIn(profile.name) {
                    Button("Delete", role: .destructive) { model.deleteProfile(profile.name) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(active ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(active ? Sky.steel.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: active ? 1.5 : 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(profile.name)\(active ? ", active" : ""). \(profile.summary)")
    }
}

/// A compact profile switcher for the menu bar popover and the island.
struct ProfileMenu: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Menu {
            ForEach(model.profiles) { profile in
                Button { model.applyProfile(profile) } label: {
                    Label(profile.name, systemImage: model.activeProfile == profile.name ? "checkmark" : profile.symbol)
                }
            }
        } label: {
            Label(model.activeProfile ?? "Profile", systemImage: "square.stack.3d.up")
        }
        .help("Switch profile")
    }
}
