import SiverCore
import SiverNotify
import SwiftUI

extension EventKind {
    var label: String {
        switch self {
        case .biome: return "Biomes"
        case .aura: return "Auras"
        case .merchant: return "Merchants"
        case .incident: return "Disconnects and rejoins"
        case .status: return "Status and alerts"
        case .newBiome: return "New biomes"
        case .liveCard: return "Live session card"
        case .daily: return "Daily report"
        case .macros: return "Macros"
        }
    }
}

/// Routes (one Discord webhook each), what goes to them, and a live preview of every message.
struct NotificationsView: View {
    @EnvironmentObject var model: AppModel
    @State private var newRouteName = ""
    @State private var newRouteProfile: FormatProfile = .rich
    @State private var previewRoute = ""
    @State private var previewKind: PreviewSamples.Kind = .biomeStarted
    @State private var routeToRemove: String?

    var body: some View {
        Page {
            SectionHeader(title: "Notifications", subtitle: "Each route is one Discord webhook with its own filters and format. Webhook URLs are kept in your Keychain.")
            ForEach($model.config.routes, id: \.name) { $route in routeCard($route) }
            addRoute
            general
            preview
            HStack {
                Button("Save") { model.saveSettings(restartIfRunning: true) }
                    .keyboardShortcut("s", modifiers: .command).buttonStyle(.skyProminent)
                Text(model.settingsMessage).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Remove the route “\(routeToRemove ?? "")”?", isPresented: Binding(get: { routeToRemove != nil }, set: { if !$0 { routeToRemove = nil } })) {
            Button("Remove route and its webhook", role: .destructive) {
                if let r = routeToRemove { model.removeRoute(r) }
                routeToRemove = nil
            }
        } message: {
            Text("Its webhook URL is removed from your Keychain when you press Save. Messages already in Discord stay there.")
        }
    }

    // MARK: one route

    private func routeCard(_ route: Binding<RouteConfig>) -> some View {
        let name = route.wrappedValue.name
        let isHunt = route.wrappedValue.profile == .huntCompat
        let valid = model.secrets.webhook(name) != nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(name, systemImage: isHunt ? "scope" : "bubble.left.and.text.bubble.right").font(.headline)
                Text(isHunt ? "Hunt-Compat" : "Rich").font(.caption).padding(.horizontal, 7).padding(.vertical, 2).background(.quaternary, in: Capsule())
                Spacer()
                Toggle("Enabled", isOn: route.enabled).toggleStyle(.switch).labelsHidden().accessibilityLabel("Route \(name) enabled")
            }
            SecureField("Discord webhook URL (https://discord.com/api/webhooks/…)", text: webhookBinding(name))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Webhook URL for \(name)")
            HStack(spacing: 10) {
                Button { model.diagnose(name) } label: { Label("Check webhook", systemImage: "stethoscope") }
                    .disabled(model.diagnosing.contains(name))
                    .help("Webhook Doctor: asks Discord about this URL. Nothing is posted.")
                if route.wrappedValue.isTestTarget {
                    Button { model.sendTestMessage(route: name) } label: { Label("Send test", systemImage: "paperplane") }.disabled(!valid)
                }
                if model.diagnoses[name]?.channelURL != nil {
                    Button { model.openChannel(name) } label: { Label("Open channel", systemImage: "arrow.up.forward.app") }
                }
                Spacer()
                Button(role: .destructive) { routeToRemove = name } label: { Image(systemName: "trash") }
                    .buttonStyle(.skyIcon).help("Remove this route").accessibilityLabel("Remove route \(name)")
            }
            diagnosis(name, valid: valid)
            Divider()
            Picker("Format", selection: route.profile) {
                Text("Rich: edits, links, live card").tag(FormatProfile.rich)
                Text("Hunt-Compat: plain, for glitch-hunt bots").tag(FormatProfile.huntCompat)
            }
            .frame(maxWidth: 420)
            if isHunt {
                Text("Hunt-Compat sends only real biome starts and ends, titled exactly “Biome Started - NAME”, never edited. Test and simulated messages never go to this route.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HelpToggle(title: "Include NORMAL", help: "Hunt bots use NORMAL messages to see that your macro is active.", isOn: route.includeNormal)
            } else {
                Text("What to send").font(.subheadline.weight(.semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(EventKind.allCases, id: \.self) { kind in
                        Toggle(kind.label, isOn: eventBinding(route, kind))
                    }
                }
                HelpToggle(title: "Include NORMAL biome messages", help: "Off keeps the channel quiet between the interesting biomes.", isOn: route.includeNormal)
                HelpToggle(title: "Post a message when a biome ends", help: "The Started message is always edited when its biome ends; this adds a separate Ended message.", isOn: route.endedMessages)
                HelpToggle(title: "Digest: one biome feed an hour", help: "Ordinary biomes are gathered into one message an hour, edited in place, instead of a post each. Rare biomes, rolls and merchants still post on their own.", isOn: route.digest)
                HelpToggle(title: "Accept test messages", help: "Test, replay and simulated messages may go to this route. They are always marked 🧪.", isOn: route.acceptsTests)
            }
            HelpToggle(title: "Ping on rare biomes", help: "Real GLITCHED, DREAMSPACE, CYBERSPACE and SINGULARITY starts ping @everyone on this route. Tests never ping.",
                       isOn: route.pingsEnabled, note: route.wrappedValue.pingsEnabled ? "Pings are on for this route." : nil)
        }
        .card()
    }

    @ViewBuilder private func diagnosis(_ name: String, valid: Bool) -> some View {
        if model.diagnosing.contains(name) {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Asking Discord…").foregroundStyle(.secondary) }
        } else if let d = model.diagnoses[name] {
            if d.ok {
                Label("Working: webhook “\(d.webhookName ?? "unnamed")”\(d.latencyMs.map { ", answered in \($0) ms" } ?? "")", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green).font(.callout)
            } else {
                Label(d.problem ?? "Something is wrong with this webhook.", systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(valid ? "Stored in your Keychain." : "Paste the webhook URL from Discord: channel settings → Integrations → Webhooks.")
                .font(.callout).foregroundStyle(valid ? Color.secondary : Sky.warning)
        }
    }

    // MARK: add, general, preview

    private var addRoute: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(title: "Add a route", symbol: "plus.circle")
            HStack {
                TextField("Name, for example hunt", text: $newRouteName).textFieldStyle(.roundedBorder).frame(width: 220)
                Picker("Format", selection: $newRouteProfile) {
                    Text("Rich").tag(FormatProfile.rich)
                    Text("Hunt-Compat").tag(FormatProfile.huntCompat)
                }
                .frame(width: 220)
                Button("Add") { model.addRoute(name: newRouteName, profile: newRouteProfile); newRouteName = "" }
                    .disabled(newRouteName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("For a glitch-hunt server: add a Hunt-Compat route and paste that server's webhook. Check it once with a real normal biome, never with a simulated rare one.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "Message style, live card and quiet hours", symbol: "moon.zzz")
            Picker("Message style", selection: $model.config.messageStyle) {
                ForEach(MessageStyle.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).frame(maxWidth: 360)
            Text(model.config.messageStyle == .skyCards
                 ? "Sky cards: messages in the Living Sky style, with a small picture of the biome or aura and times that never go stale. If Discord ever refuses the layout, the same words are sent as a classic embed. Hunt-Compat routes are not affected: they always send the exact v1.0 format hunt bots read."
                 : "Classic embeds: the messages SiverSol v1.0 sent. Hunt-Compat routes always use their own fixed format.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Live session card goes to", selection: Binding(get: { model.config.liveCardRoute ?? "" }, set: { model.config.liveCardRoute = $0.isEmpty ? nil : $0 })) {
                Text("Nowhere").tag("")
                ForEach(model.config.routes.filter { $0.profile == .rich }, id: \.name) { Text($0.name).tag($0.name) }
            }
            .frame(maxWidth: 360)
            HelpToggle(title: "Quiet hours", help: "No pings between these hours (your local time). The exceptions still ping.", isOn: $model.config.quietHours.enabled)
            if model.config.quietHours.enabled {
                HStack {
                    Stepper("From \(model.config.quietHours.startHour):00", value: $model.config.quietHours.startHour, in: 0...23)
                    Stepper("until \(model.config.quietHours.endHour):00", value: $model.config.quietHours.endHour, in: 0...23)
                }
                Text("Still pings for: \(model.config.quietHours.exceptions.joined(separator: ", "))").font(.callout).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var preview: some View {
        let route = model.config.route(previewRoute) ?? model.config.routes.first
        let kinds = route.map(PreviewSamples.kinds) ?? []
        let kind = kinds.contains(previewKind) ? previewKind : (kinds.first ?? .biomeStarted)
        return VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "Preview", symbol: "eye")
            if let route {
                HStack {
                    Picker("Route", selection: Binding(get: { route.name }, set: { previewRoute = $0 })) {
                        ForEach(model.config.routes, id: \.name) { Text($0.name).tag($0.name) }
                    }
                    .frame(width: 220)
                    Picker("Message", selection: Binding(get: { kind }, set: { previewKind = $0 })) {
                        ForEach(kinds) { Text($0.rawValue).tag($0) }
                    }
                    .frame(width: 300)
                }
                if kinds.isEmpty {
                    Text("This route is set to receive nothing.").foregroundStyle(.secondary)
                } else if let message = PreviewSamples.message(kind, route: route, catalog: model.catalog, auras: model.auras, hasServerLink: model.secrets.serverLink != nil) {
                    EmbedPreview(message: message)
                        .id("\(route.name)-\(kind.rawValue)")
                        .transition(.opacity)
                    Text("Drawn here from made-up sample data with the real templates. Nothing is sent.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Add a route to see what its messages look like.").foregroundStyle(.secondary)
            }
        }
        .card()
        .motion(.easeInOut(duration: 0.2), value: "\(previewRoute)-\(previewKind.rawValue)")
    }

    // MARK: bindings

    private func webhookBinding(_ route: String) -> Binding<String> {
        Binding(get: { model.secrets.discordWebhooks[route] ?? "" },
                set: { model.secrets.discordWebhooks[route] = $0.isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) })
    }

    private func eventBinding(_ route: Binding<RouteConfig>, _ kind: EventKind) -> Binding<Bool> {
        Binding(get: { route.wrappedValue.events.contains(kind) },
                set: { on in
                    if on { if !route.wrappedValue.events.contains(kind) { route.wrappedValue.events.append(kind) } }
                    else { route.wrappedValue.events.removeAll { $0 == kind } }
                })
    }
}
