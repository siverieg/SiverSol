import Foundation

/// One bar in the piano roll: a key held down, or a mouse button held down (a click is a very short bar).
public struct RollNote: Equatable, Identifiable, Sendable {
    public enum Lane: Hashable, Sendable {
        case key(UInt16)
        case mouse
    }

    /// The id of the step that presses the key or button. It stays the same while the note is moved about.
    public var id: UUID
    public var lane: Lane
    /// Seconds from the start of the macro.
    public var start: Double
    /// How long it is held. A press that is never released has no length.
    public var duration: Double
    public var button: MouseButton?
    /// Where a click lands, as ratios of the Roblox window.
    public var x: Double?
    public var y: Double?
    /// True for a mouse press that moves before it is released (a drag).
    public var isDrag = false

    public var end: Double { start + duration }
}

/// A wait step, shown as a flag on the ruler.
public struct RollWait: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var time: Double
    public var label: String
}

/// A macro laid out in time, the way a music editor shows notes: one lane per key, one lane for the mouse.
public struct PianoRoll: Equatable, Sendable {
    public var notes: [RollNote]
    /// Key lanes from top to bottom, in the order the keys are first pressed.
    public var keyLanes: [UInt16]
    /// How much the mouse moves in each slice of time, 0 (still) to 1 (the busiest slice).
    public var motion: [Double]
    public var bucket: Double
    public var waits: [RollWait]
    public var duration: Double

    public var hasMouse: Bool { notes.contains { $0.lane == .mouse } || motion.contains { $0 > 0 } }

    /// The seconds a step itself takes (only a plain wait has a length of its own).
    static func fixed(_ step: MacroStep) -> Double {
        if case .wait(let s) = step.action { return s }
        return 0
    }

    /// When each step happens, in seconds from the start.
    public static func times(_ steps: [MacroStep]) -> [Double] {
        var out: [Double] = []
        var t = 0.0
        for step in steps {
            t += step.delay
            out.append(t)
            t += fixed(step)
        }
        return out
    }

    public static func build(_ steps: [MacroStep], bucket: Double = 0.1) -> PianoRoll {
        let times = Self.times(steps)
        let duration = (times.last ?? 0) + (steps.last.map(fixed) ?? 0)
        var notes: [RollNote] = []
        var lanes: [UInt16] = []
        var openKeys: [UInt16: Int] = [:]          // key code -> index into notes
        var openButtons: [MouseButton: Int] = [:]
        var motion = [Double](repeating: 0, count: max(1, Int((duration / bucket).rounded(.up)) + 1))
        var waits: [RollWait] = []
        var last: (x: Double, y: Double)?

        for (i, step) in steps.enumerated() {
            let t = times[i]
            switch step.action {
            case .keyDown(let code):
                if !lanes.contains(code) { lanes.append(code) }
                guard openKeys[code] == nil else { continue }   // a repeat of a key that is already down
                openKeys[code] = notes.count
                notes.append(RollNote(id: step.id, lane: .key(code), start: t, duration: 0))
            case .keyUp(let code):
                if let n = openKeys.removeValue(forKey: code) { notes[n].duration = max(0, t - notes[n].start) }
            case .mouseDown(let button, let x, let y):
                guard openButtons[button] == nil else { continue }
                openButtons[button] = notes.count
                notes.append(RollNote(id: step.id, lane: .mouse, start: t, duration: 0, button: button, x: x, y: y))
                last = (x, y)
            case .mouseUp(let button, let x, let y):
                if let n = openButtons.removeValue(forKey: button) {
                    notes[n].duration = max(0, t - notes[n].start)
                    if let sx = notes[n].x, let sy = notes[n].y, abs(sx - x) + abs(sy - y) > 0.01 { notes[n].isDrag = true }
                }
                last = (x, y)
            case .mouseMove(let x, let y):
                if let l = last { motion[min(motion.count - 1, Int(t / bucket))] += abs(x - l.x) + abs(y - l.y) }
                last = (x, y)
                for n in openButtons.values { notes[n].isDrag = true }
            case .mouseDelta(let dx, let dy):
                motion[min(motion.count - 1, Int(t / bucket))] += (abs(dx) + abs(dy)) / 600
                for n in openButtons.values { notes[n].isDrag = true }
            case .scroll(let dx, let dy):
                motion[min(motion.count - 1, Int(t / bucket))] += (abs(dx) + abs(dy)) / 40
            case .wait(let s):
                waits.append(RollWait(id: step.id, time: t, label: String(format: "wait %.1f s", s)))
            case .waitText(let text, _):
                waits.append(RollWait(id: step.id, time: t, label: "wait for “\(text)”"))
            case .waitBiome(let biome, _):
                waits.append(RollWait(id: step.id, time: t, label: "wait for \(biome)"))
            case .waitInGame:
                waits.append(RollWait(id: step.id, time: t, label: "wait until in the game"))
            }
        }
        // Whatever is still held when the macro ends is held to the end.
        for n in Array(openKeys.values) + Array(openButtons.values) { notes[n].duration = max(0, duration - notes[n].start) }
        let peak = motion.max() ?? 0
        if peak > 0 { motion = motion.map { min(1, $0 / peak) } }
        return PianoRoll(notes: notes, keyLanes: lanes, motion: motion, bucket: bucket, waits: waits, duration: duration)
    }
}

/// Edits made in the piano roll. Each one returns the whole list of steps again; everything that was not
/// touched keeps its moment in time.
public enum PianoRollEdit {
    /// Give the steps new moments in time. Steps are put in order of time (two at the same moment keep their
    /// order) and their delays are worked out again.
    static func retime(_ steps: [MacroStep], times: [Double]) -> [MacroStep] {
        let order = zip(steps, times).enumerated().sorted { a, b in a.element.1 != b.element.1 ? a.element.1 < b.element.1 : a.offset < b.offset }
        var out: [MacroStep] = []
        var cursor = 0.0
        for item in order {
            var step = item.element.0
            let t = max(0, item.element.1)
            step.delay = min(3600, max(0, t - cursor))
            out.append(step)
            cursor = max(cursor, t) + PianoRoll.fixed(step)
        }
        return out
    }

    /// The steps that belong to a note: its press, its release, and for a mouse note everything the mouse does in between.
    static func span(of id: UUID, in steps: [MacroStep]) -> [Int] {
        guard let down = steps.firstIndex(where: { $0.id == id }) else { return [] }
        switch steps[down].action {
        case .keyDown(let code):
            let up = steps[(down + 1)...].firstIndex { if case .keyUp(let c) = $0.action { return c == code }; return false }
            return [down] + (up.map { [$0] } ?? [])
        case .mouseDown(let button, _, _):
            guard let up = steps[(down + 1)...].firstIndex(where: { if case .mouseUp(let b, _, _) = $0.action { return b == button }; return false }) else { return [down] }
            return [down] + ((down + 1)..<up).filter { steps[$0].action.isMouse } + [up]
        default:
            return [down]
        }
    }

    /// Slide notes earlier or later. Nothing can start before the beginning of the macro.
    public static func move(_ ids: Set<UUID>, by seconds: Double, in steps: [MacroStep]) -> [MacroStep] {
        var times = PianoRoll.times(steps)
        let indexes = Set(ids.flatMap { span(of: $0, in: steps) })
        guard let earliest = indexes.map({ times[$0] }).min() else { return steps }
        let shift = max(seconds, -earliest)
        for i in indexes { times[i] += shift }
        return retime(steps, times: times)
    }

    /// Change how long a key or button is held, by moving its release.
    public static func trim(_ id: UUID, toDuration seconds: Double, in steps: [MacroStep]) -> [MacroStep] {
        let indexes = span(of: id, in: steps)
        guard indexes.count >= 2, let down = indexes.first, let up = indexes.last else { return steps }
        var times = PianoRoll.times(steps)
        let old = max(0.0001, times[up] - times[down])
        let new = max(0.02, seconds)
        // What the mouse does during a drag is squeezed or stretched with it.
        for i in indexes.dropFirst() { times[i] = times[down] + (times[i] - times[down]) / old * new }
        return retime(steps, times: times)
    }

    /// Remove notes (each with its release). What is left stays where it was in time.
    public static func delete(_ ids: Set<UUID>, in steps: [MacroStep]) -> [MacroStep] {
        let times = PianoRoll.times(steps)
        let gone = Set(ids.flatMap { span(of: $0, in: steps) })
        let keep = steps.indices.filter { !gone.contains($0) }
        return retime(keep.map { steps[$0] }, times: keep.map { times[$0] })
    }
}
