import SiverCore
import SiverSky
import SwiftUI

extension Color {
    /// 0xRRGGBB
    init(hex: Int) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension BiomeInfo {
    var tint: Color { Color(hex: colorValue) }
}

/// Living Sky design tokens: one place for the fonts, springs and brand colours every page uses.
enum Sky {
    /// The default spring for things that move in the interface.
    static let spring = Animation.spring(response: 0.4, dampingFraction: 0.85)
    /// One sky giving way to another.
    static let front = Animation.easeInOut(duration: SkyState.frontSeconds)

    /// SF Pro Rounded: display text and big numbers.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .heavy) -> Font { .system(size: size, weight: weight, design: .rounded) }
    /// SF Mono: timers and ids. Per-second clocks use it with plain digits, never a rolling transition.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font { .system(size: size, weight: weight, design: .monospaced) }

    /// Brand silver: the moon's rim, the wordmark, rings and fine lines.
    static let silver = Color(hex: 0xC9D1DC)
    static let silverGradient = LinearGradient(colors: [Color(hex: 0xF6F8FB), Color(hex: 0xAEB8C6), Color(hex: 0xE8ECF2)], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// The steel tone controls are tinted with: silver, deep enough to carry white text.
    static let steel = Color(hex: 0x5B6E8C)
    /// Record and stop; play and start. White text on either keeps better than 4.5:1.
    static let stop = Color(red: 0.80, green: 0.18, blue: 0.16)
    static let go = Color(red: 0.10, green: 0.50, blue: 0.24)
    /// Warning text: an orange deep enough to read on a light card, bright enough on a dark one.
    static let warning = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 1.0, green: 0.72, blue: 0.30, alpha: 1) : NSColor(red: 0.66, green: 0.30, blue: 0.0, alpha: 1)
    })
    /// The icon's dusk: indigo, violet, amber.
    static let dusk = LinearGradient(colors: [Color(hex: 0x1B1F5E), Color(hex: 0x6B3FA0), Color(hex: 0xF2A65A)], startPoint: .top, endPoint: .bottom)
}

/// The app's mark, drawn (not loaded): a silver crescent moon cradling a small sun on a dusk sky. The same picture
/// as the app icon, sharp at any size.
struct BrandMark: View {
    var size: CGFloat = 22
    var body: some View {
        Canvas { ctx, canvas in
            let s = min(canvas.width, canvas.height)
            let rect = CGRect(x: 0, y: 0, width: s, height: s)
            let tile = Path(roundedRect: rect, cornerRadius: s * 0.24, style: .continuous)
            ctx.fill(tile, with: .linearGradient(Gradient(colors: [Color(hex: 0x15174F), Color(hex: 0x3B2A86), Color(hex: 0x8A4AA8), Color(hex: 0xF2A65A)]),
                                                 startPoint: CGPoint(x: s / 2, y: 0), endPoint: CGPoint(x: s / 2, y: s)))
            // The sun and its glow.
            let sun = CGPoint(x: s * 0.60, y: s * 0.50), sr = s * 0.13
            ctx.fill(Path(ellipseIn: CGRect(x: sun.x - sr * 2.2, y: sun.y - sr * 2.2, width: sr * 4.4, height: sr * 4.4)),
                     with: .radialGradient(Gradient(colors: [Color(hex: 0xFFE7A3).opacity(0.7), Color(hex: 0xFFC56B).opacity(0)]), center: sun, startRadius: sr * 0.5, endRadius: sr * 2.2))
            // The crescent: a disc with a smaller disc taken out, opening towards the sun.
            let moon = Path(ellipseIn: CGRect(x: s * 0.14, y: s * 0.17, width: s * 0.66, height: s * 0.66))
            let cut = Path(ellipseIn: CGRect(x: s * 0.33, y: s * 0.20, width: s * 0.54, height: s * 0.54))
            ctx.fill(moon.subtracting(cut), with: .linearGradient(Gradient(colors: [.white, Color(hex: 0xC9D1DC)]), startPoint: .zero, endPoint: CGPoint(x: s * 0.6, y: s)))
            ctx.fill(Path(ellipseIn: CGRect(x: sun.x - sr, y: sun.y - sr, width: sr * 2, height: sr * 2)),
                     with: .linearGradient(Gradient(colors: [Color(hex: 0xFFF6D6), Color(hex: 0xF7A63A)]), startPoint: CGPoint(x: sun.x, y: sun.y - sr), endPoint: CGPoint(x: sun.x, y: sun.y + sr)))
            ctx.stroke(tile, with: .color(.white.opacity(0.18)), lineWidth: 0.75)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The wordmark: "SiverSol" in SF Pro Rounded, in brand silver.
struct Wordmark: View {
    @Environment(\.colorScheme) private var scheme
    var size: CGFloat = 20
    /// On the sky or a dark surface the mark is bright silver; on a light surface it is the same silver, deepened.
    var onLight: Bool?
    var body: some View {
        let light = onLight ?? (scheme == .light)
        Text("SiverSol").font(Sky.display(size, .bold))
            .foregroundStyle(light ? LinearGradient(colors: [Color(hex: 0x34415C), Color(hex: 0x73839F), Color(hex: 0x3F4D69)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                   : Sky.silverGradient)
            .shadow(color: light ? .white.opacity(0.5) : .black.opacity(0.3), radius: 1, y: 0.5)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A content card: a standard material with a faint tint of the current biome, a soft inner highlight and a
/// hairline border. Content cards never use Liquid Glass (that belongs to the sidebar, the toolbar and controls).
///
/// Legibility rule: the base layer over the material is what keeps text readable over the brightest and the
/// darkest sky (`SkyModel.cardBase`, checked by the sky tests). If a sky is hard to read on, this layer changes,
/// not the sky. Reduce Transparency gives a solid card; Increase Contrast a stronger border.
struct CardBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var sky = SkyState.shared
    var radius: CGFloat = 16
    var padding: CGFloat = 16
    var thin = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dark = scheme == .dark
        let base = SkyModel.cardBase(dark: dark)
        let ink = SkyModel.cardInk(dark: dark)
        content.frame(maxWidth: .infinity, alignment: .leading)
            // Secondary text on a card is a little stronger than the system's, so it keeps a 4.5:1 contrast
            // even when a bright or a dark sky shows through (measured in the design review).
            .foregroundStyle(Color.primary, Color.primary.opacity(ink.secondaryOpacity))
            .padding(padding)
            .background {
                ZStack {
                    // The shadow hangs off the card's own plain shape. (Casting it from the whole card meant
                    // flattening the card and everything in it into one picture first, on every page switch.)
                    let drop = ShadowStyle.drop(color: .black.opacity(dark ? 0.28 : 0.10), radius: 10, y: 4)
                    if reduceTransparency || contrast == .increased {
                        shape.fill(Color(nsColor: .windowBackgroundColor).shadow(drop))
                    } else {
                        shape.fill(thin ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.regularMaterial))
                        // The system material already hides most of the sky; this adds what is still missing.
                        shape.fill(base.color.color.opacity(thin ? 0.22 : 0.34).shadow(drop))
                    }
                    shape.fill(sky.look.accent.color.opacity(dark ? 0.07 : 0.06))
                        .animation(reduceMotion ? nil : Sky.front, value: sky.look.accent)
                    // Inner highlight: light catching the top edge.
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.16 : 0.55), .white.opacity(dark ? 0.02 : 0.08)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    // Hairline border.
                    shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.7 : 0.10), lineWidth: contrast == .increased ? 1.5 : 0.5)
                }
            }
    }
}

/// A press that feels like one: the control gives a little.
struct PressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.965 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Sky.spring, value: configuration.isPressed)
    }
}

extension View {
    func card(radius: CGFloat = 16, padding: CGFloat = 16, thin: Bool = false) -> some View {
        modifier(CardBackground(radius: radius, padding: padding, thin: thin))
    }

    /// An animation that is dropped when Reduce Motion is on.
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View { modifier(MotionModifier(animation: animation, value: value)) }

    /// A control that floats on the sky: Liquid Glass where the system has it, a material capsule before that.
    @ViewBuilder func skyGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}

struct MotionModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V
    func body(content: Content) -> some View { content.animation(reduceMotion ? nil : animation, value: value) }
}

/// Green when on, grey when off. The state is also spoken, never colour alone.
struct StatusDot: View {
    let on: Bool
    var onLabel = "On"
    var offLabel = "Off"
    var body: some View {
        Circle().fill(on ? Color.green : Color.secondary.opacity(0.45))
            .frame(width: 10, height: 10)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
            .accessibilityLabel(on ? onLabel : offLabel)
    }
}

/// A switch with one short line that says what it does.
struct HelpToggle: View {
    let title: String
    let help: String
    @Binding var isOn: Bool
    var note: String?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(help).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let note { Text(note).font(.caption).foregroundStyle(Sky.warning) }
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
                .accessibilityLabel(title)
                .accessibilityHint(help)
        }
    }
}

/// A page's title. It sits directly on the sky, so it takes the sky's ink colour and the same soft scrim the
/// Dashboard's hero uses.
struct SectionHeader: View {
    @ObservedObject private var sky = SkyState.shared
    let title: String
    var subtitle: String?
    var body: some View {
        let light = sky.look.inkIsLight
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Sky.display(26, .bold))
            if let subtitle { Text(subtitle).opacity(0.92).fixedSize(horizontal: false, vertical: true) }
        }
        .foregroundStyle(sky.look.ink.color)
        .shadow(color: (light ? Color.black : Color.white).opacity(0.25), radius: 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 30).fill((light ? Color.black : Color.white).opacity(max(0.10, sky.look.veil)))
                .blur(radius: 26).padding(-18).allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Controls that float on the sky (filters, pickers) belong to the control layer: one strip of Liquid Glass on
/// macOS 26 and later, a material strip before that. Never put this inside a card.
struct ControlStrip<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder var content: Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let row = HStack(spacing: 10) { content }.padding(.horizontal, 12).padding(.vertical, 8)
        if reduceTransparency {
            row.background(Color(nsColor: .windowBackgroundColor), in: shape).overlay(shape.strokeBorder(.separator))
        } else if #available(macOS 26.0, *) {
            row.glassEffect(.regular, in: shape)
        } else {
            row.background(.regularMaterial, in: shape).overlay(shape.strokeBorder(.separator.opacity(0.5)))
        }
    }
}

struct CardTitle: View {
    let title: String
    let symbol: String
    var body: some View {
        Label(title, systemImage: symbol).font(.headline).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

struct KeyValueRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).monospacedDigit().lineLimit(1).truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }
}

struct EventRowView: View {
    let row: EventRow
    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let biome = row.biome {
                    BiomeGlyph(info: biome, size: 16).foregroundStyle(biome.isRare ? AnyShapeStyle(biome.tint) : AnyShapeStyle(.secondary))
                } else {
                    Image(systemName: row.icon).symbolRenderingMode(.hierarchical).foregroundStyle(row.tint ?? Color.secondary)
                }
            }
            .frame(width: 26)
            .accessibilityHidden(true)
            Text(row.time.formatted(date: .omitted, time: .standard)).font(Sky.mono(12, .regular)).foregroundStyle(.secondary)
            Text(row.title).fontWeight(.medium)
            Spacer()
            Text(row.detail).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A page: a scrolling column with a comfortable reading width.
/// `scrollTarget` is the id of a row to bring into view when it changes.
struct Page<Content: View>: View {
    var scrollTarget: String?
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(scrollTarget: String? = nil, @ViewBuilder content: () -> Content) {
        self.scrollTarget = scrollTarget
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }
                    .padding(24)
                    .frame(maxWidth: 980, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                // After the list has laid out.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(reduceMotion ? nil : Sky.spring) { proxy.scrollTo(target, anchor: .center) }
                }
            }
        }
    }
}


// MARK: buttons

/// Every action on a page is one of two buttons. Both are at least 28 points tall, and their text keeps a
/// contrast of 4.5:1 or better over every sky, in light and dark (`SkyTests` checks the colours).
///
/// - `SkyButtonStyle` (the default on every page): a tinted, bordered button with the card's own strong ink.
/// - `SkyProminentButtonStyle`: the one primary action of a card, filled with the biome's accent.
struct SkyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration, prominent: false) }

    struct Face: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        var tint: Color?
        @ObservedObject private var sky = SkyState.shared
        @Environment(\.colorScheme) private var scheme
        @Environment(\.isEnabled) private var enabled
        @Environment(\.controlSize) private var size
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            let dark = scheme == .dark
            let colors = SkyModel.buttonFill(sky.look, dark: dark)
            let destructive = configuration.role == .destructive
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            let small = size == .small || size == .mini
            let accent = tint ?? colors.fill.color
            configuration.label
                .font(.system(size: small ? 12 : 13, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, small ? 10 : 12)
                .frame(minHeight: 28)
                .foregroundStyle(foreground(colors.text.color, destructive: destructive, dark: dark))
                .background {
                    if prominent {
                        shape.fill(tint ?? colors.fill.color)
                    } else {
                        shape.fill(Color.primary.opacity(dark ? 0.12 : 0.07))
                        shape.fill(accent.opacity(0.14))
                    }
                }
                .overlay {
                    if !prominent { shape.strokeBorder(destructive ? Color.red.opacity(0.6) : accent.opacity(contrast == .increased ? 1 : 0.6), lineWidth: 1) }
                }
                .contentShape(shape)
                .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.45)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }

        private func foreground(_ onFill: Color, destructive: Bool, dark: Bool) -> Color {
            if prominent { return tint == nil ? onFill : .white }
            if destructive { return dark ? Color(red: 1.0, green: 0.56, blue: 0.52) : Color(red: 0.70, green: 0.10, blue: 0.08) }
            return .primary
        }
    }
}

struct SkyProminentButtonStyle: ButtonStyle {
    /// A fixed colour for the few buttons whose colour means something (record and stop: red, play: green).
    var tint: Color?
    func makeBody(configuration: Configuration) -> some View { SkyButtonStyle.Face(configuration: configuration, prominent: true, tint: tint) }
}

extension ButtonStyle where Self == SkyButtonStyle {
    static var sky: SkyButtonStyle { SkyButtonStyle() }
}

extension ButtonStyle where Self == SkyProminentButtonStyle {
    static var skyProminent: SkyProminentButtonStyle { SkyProminentButtonStyle() }
    static func skyProminent(_ tint: Color) -> SkyProminentButtonStyle { SkyProminentButtonStyle(tint: tint) }
}

/// A button that is only a symbol (reveal, trash, close, "?"). The symbol is in the card's strong ink and the
/// button is 28 points square however small the symbol is, so it is easy to see and to hit.
struct SkyIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration) }

    struct Face: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(configuration.role == .destructive ? AnyShapeStyle(Sky.warning) : AnyShapeStyle(Color.primary.opacity(0.86)))
                .frame(minWidth: 28, minHeight: 28)
                .background(shape.fill(Color.primary.opacity(configuration.isPressed ? 0.18 : (hovering ? 0.10 : 0))))
                .contentShape(shape)
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == SkyIconButtonStyle {
    static var skyIcon: SkyIconButtonStyle { SkyIconButtonStyle() }
}

/// Toggles, pickers and links on a page take the biome's accent (the same colour as the filled buttons).
struct AccentTint: ViewModifier {
    @ObservedObject private var sky = SkyState.shared
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.tint(SkyModel.buttonFill(sky.look, dark: scheme == .dark).fill.color)
    }
}

// MARK: clocks

/// Is the main window where it can be seen? A minimised, closed, hidden or fully covered window does not need
/// its clocks to tick.
@MainActor
final class WindowWatch: ObservableObject {
    static let shared = WindowWatch()
    @Published private(set) var visible = true
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.willCloseNotification, NSWindow.didBecomeMainNotification, NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // After the window server has settled (a closing window is still "visible" in its own notification).
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
            })
        }
        update()
    }

    private func update() {
        let now = DesignReview.isOn || NSApp.windows.contains { w in
            w.styleMask.contains(.titled) && w.canBecomeMain && w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible)
        } && !NSApp.isHidden
        if now != visible { visible = now }
    }
}

/// A clock in the main window: ticks once a second while the window can be seen, and not at all otherwise.
/// (SwiftUI keeps updating a `TimelineView` in a minimised window; five of them cost about 1% of a core.)
struct Tick { let date: Date }

struct Ticker<Content: View>: View {
    @ObservedObject private var watch = WindowWatch.shared
    private let content: (Tick) -> Content

    init(@ViewBuilder content: @escaping (Tick) -> Content) { self.content = content }

    var body: some View {
        if watch.visible {
            TimelineView(.periodic(from: .now, by: 1)) { context in content(Tick(date: context.date)) }
        } else {
            content(Tick(date: Date()))
        }
    }
}
