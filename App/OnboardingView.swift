import SiverCore
import SiverNotify
import SwiftUI

/// First run: welcome, webhook, private server link, permissions, done.
struct OnboardingView: View {
    enum Step: Int, CaseIterable { case welcome, webhook, server, permissions, done }

    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step = {
        // `--onboarding-step 3` opens the wizard on a given step (for screenshots and checks).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--onboarding-step"), i + 1 < args.count, let n = Int(args[i + 1]), let s = Step(rawValue: n) { return s }
        return .welcome
    }()

    /// The route the wizard fills in: the first Rich route (a fresh install has one, called "main").
    private var routeName: String { model.config.routes.first { $0.profile == .rich }?.name ?? "main" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Capsule().fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25)).frame(height: 4)
                }
            }
            .padding(.horizontal, 28).padding(.top, 22)
            .accessibilityElement().accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")

            Group {
                switch step {
                case .welcome: welcome
                case .webhook: webhook
                case .server: server
                case .permissions: permissions
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(28)
            .id(step)
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))

            Divider()
            HStack {
                if step != .welcome && step != .done { Button("Back") { go(Step(rawValue: step.rawValue - 1) ?? .welcome) } }
                Button("Skip setup") { finish(start: false) }.buttonStyle(.link).opacity(step == .done ? 0 : 1)
                Spacer()
                if step == .done {
                    Button("Open the dashboard") { finish(start: false) }
                    Button("Start now") { finish(start: true) }.buttonStyle(.skyProminent).disabled(!model.hasWebhook).keyboardShortcut(.defaultAction)
                } else {
                    Button(step == .welcome ? "Get started" : "Continue") { go(Step(rawValue: step.rawValue + 1) ?? .done) }
                        .buttonStyle(.skyProminent).keyboardShortcut(.defaultAction)
                        .disabled(step == .webhook && !webhookOK && !(model.secrets.discordWebhooks[routeName] ?? "").isEmpty && model.diagnosing.contains(routeName))
                }
            }
            .padding(18)
        }
        .frame(width: 640, height: 560)
    }

    private func go(_ next: Step) {
        withAnimation(reduceMotion ? nil : Sky.spring) { step = next }
    }

    private func finish(start: Bool) {
        model.onboardingDone = true
        model.saveSettings()
        model.showOnboarding = false
        if start { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { model.start() } }
    }

    private var webhookOK: Bool { model.diagnoses[routeName]?.ok == true }

    // MARK: steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "sparkles").font(.system(size: 40)).foregroundStyle(.tint).symbolEffect(.bounce, value: step).accessibilityHidden(true)
            Text("Welcome to SiverSol").font(.largeTitle.weight(.bold))
            Text("SiverSol watches Sol's RNG while you are away and tells your Discord what happened.")
            VStack(alignment: .leading, spacing: 10) {
                point("cloud.sun.rain", "Knows the biome and your aura from the Roblox log, about a second after the game does.")
                point("bell.badge", "Posts to your own Discord webhook. Rare biomes can ping you.")
                point("arrow.triangle.2.circlepath", "Keeps the session alive and rejoins your private server after a disconnect.")
                point("lock.shield", "Never touches your auras, never spends Robux, and checks the screen before every key press.")
            }
            Text("Setup takes about two minutes. You can change everything later.").foregroundStyle(.secondary)
        }
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).frame(width: 24).foregroundStyle(.tint).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var webhook: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where should alerts go?").font(.title.weight(.bold))
            Text("In Discord: open the channel's settings → Integrations → Webhooks → New Webhook → Copy Webhook URL. Paste it here.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("https://discord.com/api/webhooks/…", text: Binding(
                get: { model.secrets.discordWebhooks[routeName] ?? "" },
                set: { model.secrets.discordWebhooks[routeName] = $0.isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
                .textFieldStyle(.roundedBorder).accessibilityLabel("Discord webhook URL")
            HStack {
                Button { model.diagnose(routeName) } label: { Label("Check it", systemImage: "stethoscope") }
                    .disabled((model.secrets.discordWebhooks[routeName] ?? "").isEmpty || model.diagnosing.contains(routeName))
                if webhookOK { Button { model.sendTestMessage(route: routeName) } label: { Label("Send a test message", systemImage: "paperplane") } }
            }
            if model.diagnosing.contains(routeName) {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Asking Discord…").foregroundStyle(.secondary) }
            } else if let d = model.diagnoses[routeName] {
                if d.ok {
                    Label("Working: webhook “\(d.webhookName ?? "unnamed")”\(d.latencyMs.map { ", answered in \($0) ms" } ?? "").", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Label(d.problem ?? "That did not work.", systemImage: "xmark.octagon.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !model.settingsMessage.isEmpty && webhookOK { Text(model.settingsMessage).font(.callout).foregroundStyle(.secondary) }
            Spacer()
            Text("The URL is kept in this Mac's Keychain and is only used to talk to Discord. Checking it posts nothing.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var server: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your private server").font(.title.weight(.bold))
            Text("In Roblox: open your Sol's RNG private server's settings and copy its share link. SiverSol uses it for the Join button in Discord and to bring you back after a disconnect. It only ever rejoins this link.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("https://www.roblox.com/share?code=…&type=Server", text: Binding(
                get: { model.secrets.privateServerLink ?? "" },
                set: { model.secrets.privateServerLink = $0.isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
                .textFieldStyle(.roundedBorder).accessibilityLabel("Private server link")
            if model.secrets.privateServerLink != nil {
                if model.secrets.serverLink != nil {
                    Label("Looks like a roblox.com link.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Label("That is not a roblox.com link.", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }
            Spacer()
            Text("Optional. Without it, alerts still work; auto-rejoin and the Join button do not.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Two permissions").font(.title.weight(.bold))
            Text("macOS asks before an app may look at a window or press a key. SiverSol needs both to press the anti-AFK key safely. Press ? on a row to see exactly what it is used for, and what it is never used for.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            PermissionList(topics: PermissionGuide.prompts)
            if model.permissions.allGranted {
                Label("Both are on.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            } else {
                Text("The dots turn green by themselves once a permission is on. macOS may ask you to quit and reopen SiverSol after Screen Recording; setup carries on where you left it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text("You can skip this. Biome detection and Discord alerts work without either permission.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green).symbolEffect(.bounce, value: step).accessibilityHidden(true)
            Text("Ready").font(.largeTitle.weight(.bold))
            summaryRow(model.hasWebhook, "Discord webhook", model.hasWebhook ? "set" : "missing: add one in Notifications before starting")
            summaryRow(model.secrets.serverLink != nil, "Private server link", model.secrets.serverLink != nil ? "set" : "not set: no auto-rejoin")
            summaryRow(model.permissions.screenRecording, "Screen Recording", model.permissions.screenRecording ? "on" : "off: no screenshots, no key presses")
            summaryRow(model.permissions.accessibility, "Accessibility", model.permissions.accessibility ? "on" : "off: no anti-AFK, no macros")
            Text("Open Sol's RNG in your private server, then press Start. SiverSol lives in the menu bar; the panic key ⌃⌥⌘P stops all input from anywhere.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func summaryRow(_ ok: Bool, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            StatusDot(on: ok, onLabel: "\(title) ready", offLabel: "\(title) not ready")
            Text(title).fontWeight(.medium)
            Text(detail).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
