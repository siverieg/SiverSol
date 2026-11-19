import SiverCore
import SwiftUI

/// Names of the parts of the permission UI that were really drawn. Each part adds its own name where it is
/// built, so if a "?" button or an explainer section is removed, its name disappears with it. The UI test
/// reads this; the same name is also the accessibility identifier.
struct UIMarkerKey: PreferenceKey {
    static let defaultValue: Set<String> = []
    static func reduce(value: inout Set<String>, nextValue: () -> Set<String>) { value.formUnion(nextValue()) }
}

extension View {
    func marker(_ id: String) -> some View {
        accessibilityIdentifier(id).transformPreference(UIMarkerKey.self) { $0.insert(id) }
    }
}

/// One permission, wherever it is shown: a live status dot, what it is for, the "?" explainer, and the button
/// that grants it. Every permission row in the app is this view, so every row has its "?".
struct PermissionRow: View {
    let topic: PermissionTopic
    @EnvironmentObject var model: AppModel
    @State private var showHelp = false

    var body: some View {
        let granted = model.isGranted(topic)
        HStack(spacing: 12) {
            StatusDot(on: granted, onLabel: "\(topic.title) is on", offLabel: "\(topic.title) is off")
            Image(systemName: topic.symbol).font(.title3).frame(width: 28).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(topic.title).font(.headline)
                    if topic.kind == .optional { Text("optional").font(.caption).foregroundStyle(.secondary) }
                }
                Text(topic.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button { showHelp = true } label: {
                Image(systemName: "questionmark.circle").font(.title3)
            }
            .buttonStyle(.skyIcon)
            .help("Why SiverSol asks for \(topic.title)")
            .accessibilityLabel("About \(topic.title)")
            .popover(isPresented: $showHelp, arrowEdge: .bottom) { PermissionExplainer(topic: topic).environmentObject(model) }
            .marker("permission-help-\(topic.id)")
            control(granted)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .marker("permission-row-\(topic.id)")
    }

    @ViewBuilder private func control(_ granted: Bool) -> some View {
        if topic.id == PermissionGuide.launchAtLogin.id {
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .labelsHidden().toggleStyle(.switch)
        } else if granted {
            Label("Allowed", systemImage: "checkmark").foregroundStyle(.green).font(.callout)
        } else {
            Button("Allow…") { model.request(topic) }
        }
    }
}

/// The same five parts for every permission: why, never, without it, how to turn it off, and the Settings button.
struct PermissionExplainer: View {
    let topic: PermissionTopic
    @EnvironmentObject var model: AppModel

    var body: some View {
        Explainer(title: topic.title, symbol: topic.symbol, parts: Array(topic.parts.dropLast()), button: topic.settingsButton, buttonMarker: "explainer-settings") {
            model.openSettings(topic)
        }
    }
}

/// What every "?" in SiverSol opens: a title, a few short headed paragraphs, one button. The permission
/// explainers and the island's explainer are both this view, so they look and behave the same.
struct Explainer: View {
    let title: String
    let symbol: String
    let parts: [(id: String, heading: String, text: String)]
    let button: String
    var buttonMarker = "explainer-button"
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.title3.weight(.semibold))
            ForEach(parts, id: \.id) { part in
                VStack(alignment: .leading, spacing: 3) {
                    Text(part.heading).font(.subheadline.weight(.semibold))
                    Text(part.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .marker("explainer-\(part.id)")
            }
            Button(button, action: action)
                .marker(buttonMarker)
        }
        .padding(18)
        .frame(width: 400)
    }
}

/// The "?" button itself, wherever an explainer hangs off a setting.
struct ExplainerButton<Content: View>: View {
    let label: String
    var startOpen = false
    @ViewBuilder var content: () -> Content
    @State private var show = false

    var body: some View {
        Button { show = true } label: { Image(systemName: "questionmark.circle").font(.title3) }
            .buttonStyle(.skyIcon)
            .help(label)
            .accessibilityLabel(label)
            .popover(isPresented: $show, arrowEdge: .bottom, content: content)
            .onAppear { if startOpen { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { show = true } } }
    }
}

/// A list of permission rows. Onboarding, Settings and the Privacy page all use it.
struct PermissionList: View {
    let topics: [PermissionTopic]
    var body: some View {
        VStack(spacing: 8) { ForEach(topics) { PermissionRow(topic: $0) } }
    }
}
