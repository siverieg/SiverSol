import SiverMacro
import SwiftUI

/// The piano roll: a macro laid out in time like a piece of music. One lane per key (a bar is as long as the key
/// is held), one lane for the mouse (dots for clicks, bars for drags, a faint band for how much it moves), wait
/// steps as flags on the ruler. Drag a bar to move it, drag its right edge to change the hold, select several
/// (shift-click, or drag a box) and press Delete.
struct PianoRollView: View {
    @Binding var steps: [MacroStep]
    @Binding var selection: Set<UUID>
    /// Where playback is, in seconds, while this macro plays.
    var playhead: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("pianoRollZoom") private var zoom = 90.0          // points per second
    @State private var scrub: Double?
    @State private var moveBy = 0.0                               // seconds, while dragging bars
    @State private var trim: (id: UUID, duration: Double)?
    @State private var marquee: CGRect?
    @State private var zoomAtPinchStart: Double?

    private static let laneHeight: CGFloat = 26
    private static let mouseHeight: CGFloat = 44
    private static let ruler: CGFloat = 24
    private static let gutter: CGFloat = 78
    private static let editableLimit = 900

    var body: some View {
        let roll = PianoRoll.build(steps)
        let lanes = roll.keyLanes
        let height = Self.ruler + CGFloat(lanes.count) * Self.laneHeight + (roll.hasMouse ? Self.mouseHeight : 0) + 6
        let width = max(420, CGFloat(roll.duration) * zoom + 120)

        VStack(alignment: .leading, spacing: 8) {
            toolbar(roll)
            if steps.isEmpty {
                Text("Nothing recorded yet. Press Record, do it once in Roblox, and it appears here as bars.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 90)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    gutter(lanes, roll)
                    ScrollView(.horizontal, showsIndicators: true) {
                        ZStack(alignment: .topLeading) {
                            grid(roll, lanes: lanes, width: width, height: height)
                            marqueeLayer(roll, lanes: lanes)
                            notes(roll, lanes: lanes)
                            waits(roll, height: height)
                            line(at: playhead, color: .green, height: height, label: nil)
                            line(at: scrub, color: .primary, height: height, label: scrub.map { held(roll, at: $0) })
                        }
                        .frame(width: width, height: height, alignment: .topLeading)
                        .coordinateSpace(name: "roll")
                    }
                    .simultaneousGesture(MagnifyGesture()
                        .onChanged { g in
                            if zoomAtPinchStart == nil { zoomAtPinchStart = zoom }
                            zoom = min(600, max(12, (zoomAtPinchStart ?? zoom) * g.magnification))
                        }
                        .onEnded { _ in zoomAtPinchStart = nil })
                }
                .frame(height: height + 14)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .focusable()
                .onDeleteCommand { deleteSelection() }
                if roll.notes.count > Self.editableLimit {
                    Text("This macro has \(roll.notes.count) notes. It is shown here, and edited in the step list below.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: toolbar

    private func toolbar(_ roll: PianoRoll) -> some View {
        HStack(spacing: 10) {
            CardTitle(title: "Piano roll", symbol: "pianokeys").fixedSize()
            Text(String(format: "%.1f s · %d key%@ · %d note%@", roll.duration, roll.keyLanes.count, roll.keyLanes.count == 1 ? "" : "s", roll.notes.count, roll.notes.count == 1 ? "" : "s"))
                .font(Sky.mono(11.5)).foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1)
            Spacer(minLength: 4)
            if !selection.isEmpty {
                Text("\(selection.count) selected").font(.callout).foregroundStyle(.secondary)
                Button(role: .destructive) { deleteSelection() } label: { Label("Delete", systemImage: "trash") }
                    .help("Delete the selected notes (Delete key). Everything else stays where it is in time.")
                Button("Deselect") { selection = [] }
            }
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            Slider(value: $zoom, in: 12...600).frame(width: 130).accessibilityLabel("Zoom").help("Zoom (or pinch on the trackpad)")
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            Button("Fit") { zoom = min(600, max(12, 620 / max(0.5, roll.duration))) }.help("Show the whole macro")
        }
    }

    // MARK: lanes

    private func gutter(_ lanes: [UInt16], _ roll: PianoRoll) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Color.clear.frame(height: Self.ruler)
            ForEach(lanes, id: \.self) { code in
                Text(KeyNames.name(code))
                    .font(Sky.mono(11, .semibold)).lineLimit(1)
                    .padding(.horizontal, 7).frame(height: Self.laneHeight - 6)
                    .background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .frame(height: Self.laneHeight)
            }
            if roll.hasMouse {
                Label("Mouse", systemImage: "cursorarrow").font(.system(size: 11, weight: .semibold)).frame(height: Self.mouseHeight)
            }
        }
        .frame(width: Self.gutter, alignment: .trailing)
        .padding(.trailing, 6)
    }

    private func laneY(_ lane: RollNote.Lane, lanes: [UInt16]) -> CGFloat {
        switch lane {
        case .key(let code): return Self.ruler + CGFloat(lanes.firstIndex(of: code) ?? 0) * Self.laneHeight
        case .mouse: return Self.ruler + CGFloat(lanes.count) * Self.laneHeight
        }
    }

    /// Ruler, lane stripes and the mouse's movement band: one drawing, redrawn only when the macro or the zoom changes.
    private func grid(_ roll: PianoRoll, lanes: [UInt16], width: CGFloat, height: CGFloat) -> some View {
        let step = [0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60, 300].first { $0 * zoom >= 64 } ?? 600
        return Canvas { ctx, size in
            for i in lanes.indices where i % 2 == 1 {
                ctx.fill(Path(CGRect(x: 0, y: Self.ruler + CGFloat(i) * Self.laneHeight, width: size.width, height: Self.laneHeight)), with: .color(.primary.opacity(0.04)))
            }
            var t = 0.0
            while t * zoom < size.width {
                let x = CGFloat(t) * zoom
                ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.primary.opacity(0.10)))
                ctx.draw(Text(label(t, step: step)).font(.system(size: 9.5, weight: .medium, design: .monospaced)).foregroundStyle(.secondary),
                         at: CGPoint(x: x + 4, y: Self.ruler / 2), anchor: .leading)
                t += step
            }
            ctx.fill(Path(CGRect(x: 0, y: Self.ruler - 1, width: size.width, height: 1)), with: .color(.primary.opacity(0.18)))
            if roll.hasMouse {
                let y0 = Self.ruler + CGFloat(lanes.count) * Self.laneHeight
                ctx.fill(Path(CGRect(x: 0, y: y0, width: size.width, height: 1)), with: .color(.primary.opacity(0.14)))
                // How much the mouse moves, slice by slice.
                for (i, v) in roll.motion.enumerated() where v > 0.01 {
                    let h = CGFloat(v) * (Self.mouseHeight - 8)
                    ctx.fill(Path(CGRect(x: CGFloat(Double(i) * roll.bucket) * zoom, y: y0 + Self.mouseHeight - 2 - h, width: max(1, CGFloat(roll.bucket) * zoom - 0.5), height: h)),
                             with: .color(.teal.opacity(0.35)))
                }
            }
        }
        .frame(width: width, height: height)
        // The ruler is where the playhead is scrubbed; the lanes are where a box is dragged to select.
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("roll"))
            .onChanged { g in
                if g.startLocation.y <= Self.ruler {
                    scrub = max(0, min(roll.duration, Double(g.location.x / zoom)))
                } else {
                    marquee = CGRect(x: min(g.startLocation.x, g.location.x), y: min(g.startLocation.y, g.location.y),
                                     width: abs(g.location.x - g.startLocation.x), height: abs(g.location.y - g.startLocation.y))
                }
            }
            .onEnded { g in
                if let box = marquee, box.width > 3 || box.height > 3 {
                    let hit = roll.notes.filter { frame(of: $0, lanes: lanes).intersects(box) }.map(\.id)
                    selection = NSEvent.modifierFlags.contains(.shift) ? selection.union(hit) : Set(hit)
                } else if g.startLocation.y > Self.ruler {
                    selection = []
                }
                marquee = nil
            })
    }

    private func label(_ t: Double, step: Double) -> String {
        if step < 1 { return String(format: "%.2fs", t) }
        return t >= 60 ? String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) : String(format: "%.0fs", t)
    }

    @ViewBuilder private func marqueeLayer(_ roll: PianoRoll, lanes: [UInt16]) -> some View {
        if let box = marquee {
            Rectangle().fill(Sky.steel.opacity(0.18)).overlay(Rectangle().strokeBorder(Sky.steel, lineWidth: 1))
                .frame(width: box.width, height: box.height).offset(x: box.minX, y: box.minY).allowsHitTesting(false)
        }
    }

    // MARK: notes

    private func frame(of note: RollNote, lanes: [UInt16]) -> CGRect {
        let y = laneY(note.lane, lanes: lanes)
        let x = CGFloat(note.start) * zoom
        if note.lane == .mouse {
            let w = note.isDrag ? max(10, CGFloat(note.duration) * zoom) : 12
            return CGRect(x: x, y: y + 6, width: w, height: 12)
        }
        return CGRect(x: x, y: y + 4, width: max(5, CGFloat(note.duration) * zoom), height: Self.laneHeight - 8)
    }

    private static let palette: [Color] = [.blue, .purple, .orange, .pink, .mint, .indigo, .yellow, .cyan, .red, .green]

    private func color(_ note: RollNote, lanes: [UInt16]) -> Color {
        switch note.lane {
        case .key(let code): return Self.palette[(lanes.firstIndex(of: code) ?? 0) % Self.palette.count]
        case .mouse: return .teal
        }
    }

    @ViewBuilder private func notes(_ roll: PianoRoll, lanes: [UInt16]) -> some View {
        let editable = roll.notes.count <= Self.editableLimit
        ForEach(roll.notes) { note in
            let selected = selection.contains(note.id)
            let base = frame(of: note, lanes: lanes)
            let width = trim?.id == note.id ? max(5, CGFloat(trim!.duration) * zoom) : base.width
            let dx = selected ? CGFloat(moveBy) * zoom : 0
            let tint = color(note, lanes: lanes)
            Group {
                if note.lane == .mouse && !note.isDrag {
                    Circle().fill(note.button == .right ? Color.clear : tint).overlay(Circle().strokeBorder(tint, lineWidth: 2))
                } else {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(tint.gradient)
                        .overlay(alignment: .trailing) {
                            // The right edge is the handle that changes how long the key is held.
                            if editable && note.lane != .mouse {
                                Rectangle().fill(Color.white.opacity(0.001)).frame(width: 8)
                                    .overlay(alignment: .trailing) { Capsule().fill(.white.opacity(0.7)).frame(width: 2, height: 10).padding(.trailing, 2) }
                                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("roll"))
                                        .onChanged { g in trim = (note.id, max(0.02, snap(note.duration + Double(g.translation.width / zoom)))) }
                                        .onEnded { _ in
                                            if let t = trim { steps = PianoRollEdit.trim(t.id, toDuration: t.duration, in: steps) }
                                            trim = nil
                                        })
                                    .help("Drag to change how long the key is held")
                            }
                        }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: note.lane == .mouse && !note.isDrag ? 6 : 4, style: .continuous).strokeBorder(.white, lineWidth: selected ? 2 : 0))
            .shadow(color: selected ? tint.opacity(0.8) : .clear, radius: 4)
            .frame(width: width, height: base.height)
            .offset(x: base.minX + dx, y: base.minY)
            .animation(reduceMotion ? nil : Sky.spring, value: selected)
            .gesture(editable ? DragGesture(minimumDistance: 2, coordinateSpace: .named("roll"))
                .onChanged { g in
                    if !selection.contains(note.id) { selection = [note.id] }
                    moveBy = snap(Double(g.translation.width / zoom))
                }
                .onEnded { _ in
                    if moveBy != 0 { steps = PianoRollEdit.move(selection, by: moveBy, in: steps) }
                    moveBy = 0
                } : nil)
            .onTapGesture {
                let flags = NSEvent.modifierFlags
                if flags.contains(.shift) || flags.contains(.command) {
                    if selected { selection.remove(note.id) } else { selection.insert(note.id) }
                } else {
                    selection = [note.id]
                }
            }
            .help(describe(note))
            .accessibilityElement()
            .accessibilityLabel(describe(note))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAdjustableAction { direction in
                guard editable else { return }
                steps = PianoRollEdit.move([note.id], by: direction == .increment ? 0.1 : -0.1, in: steps)
            }
            .accessibilityAction(named: "Delete") { steps = PianoRollEdit.delete([note.id], in: steps); selection.remove(note.id) }
        }
    }

    private func snap(_ seconds: Double) -> Double { (seconds * 100).rounded() / 100 }

    private func describe(_ note: RollNote) -> String {
        switch note.lane {
        case .key(let code):
            return String(format: "%@ held for %.2f s, starting at %.2f s", KeyNames.name(code), note.duration, note.start)
        case .mouse:
            let what = note.isDrag ? "drag" : "click"
            return String(format: "%@ %@ at %.2f s", (note.button ?? .left).rawValue.capitalized, what, note.start)
        }
    }

    private func deleteSelection() {
        guard !selection.isEmpty else { return }
        steps = PianoRollEdit.delete(selection, in: steps)
        selection = []
    }

    // MARK: flags and lines

    @ViewBuilder private func waits(_ roll: PianoRoll, height: CGFloat) -> some View {
        ForEach(roll.waits) { wait in
            VStack(alignment: .leading, spacing: 0) {
                Label(wait.label, systemImage: "hourglass").font(.system(size: 9.5, weight: .semibold)).lineLimit(1).fixedSize()
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.purple.opacity(0.85), in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.white)
                Rectangle().fill(Color.purple.opacity(0.6)).frame(width: 1.5, height: height - Self.ruler)
            }
            .offset(x: CGFloat(wait.time) * zoom, y: Self.ruler - 13)
            .allowsHitTesting(false)
            .accessibilityLabel(String(format: "%@ at %.1f seconds", wait.label, wait.time))
        }
    }

    @ViewBuilder private func line(at time: Double?, color: Color, height: CGFloat, label: String?) -> some View {
        if let time {
            Rectangle().fill(color).frame(width: 1.5, height: height).offset(x: CGFloat(time) * zoom).allowsHitTesting(false)
            if let label {
                Text(label).font(Sky.mono(10, .semibold)).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4)).fixedSize()
                    .offset(x: CGFloat(time) * zoom + 5, y: Self.ruler + 2).allowsHitTesting(false)
            }
        }
    }

    /// What is held at a moment: "1.25 s · W + Space".
    private func held(_ roll: PianoRoll, at time: Double) -> String {
        let names = roll.notes.filter { $0.start <= time && time <= $0.end }.map { note -> String in
            if case .key(let code) = note.lane { return KeyNames.name(code) }
            return "mouse"
        }
        return String(format: "%.2f s", time) + (names.isEmpty ? "" : " · " + names.joined(separator: " + "))
    }
}
