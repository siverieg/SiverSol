import CoreGraphics
import Foundation

/// One raw input event as the event tap saw it. Times are seconds on a monotonic clock.
public struct RawInput: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case keyDown, keyUp
        case mouseMove
        case mouseDrag(MouseButton)
        case mouseDown(MouseButton)
        case mouseUp(MouseButton)
        case scroll
    }
    public var kind: Kind
    public var time: TimeInterval
    public var keyCode: UInt16 = 0
    public var isRepeat = false
    /// Global display points, top-left origin.
    public var location: CGPoint = .zero
    public var dx: Double = 0
    public var dy: Double = 0
    /// Control, Option and Command were all held: this key is one of SiverSol's own shortcuts, not part of the macro.
    public var isShortcut = false

    public init(_ kind: Kind, time: TimeInterval, keyCode: UInt16 = 0, isRepeat: Bool = false, location: CGPoint = .zero, dx: Double = 0, dy: Double = 0) {
        self.kind = kind; self.time = time; self.keyCode = keyCode; self.isRepeat = isRepeat; self.location = location; self.dx = dx; self.dy = dy
    }
}

public struct RecorderOptions: Equatable, Sendable, Codable {
    /// After "/" opens the chat, ignore keys until Return or Escape closes it. Nothing typed in chat is stored.
    public var skipChatTyping = true
    /// Mouse moves are thinned to about this many per second.
    public var moveHz: Double = 120
    public init() {}
}

/// Turns raw input into macro steps. Pure logic: no event tap, no clock of its own, so it can be tested with
/// synthetic events. It records nothing unless Roblox is the frontmost app, and nothing outside the Roblox window.
public final class MacroRecorder: @unchecked Sendable {
    public enum State: Equatable, Sendable { case idle, recording, paused }

    private let lock = NSLock()
    private let options: RecorderOptions
    private let window: @Sendable () -> CGRect?
    private let robloxFrontmost: @Sendable () -> Bool

    private var stateValue = State.idle
    private var steps: [MacroStep] = []
    private var startTime: TimeInterval = 0
    private var pausedTotal: TimeInterval = 0
    private var pausedAt: TimeInterval = 0
    private var lastStepTime: TimeInterval = 0
    private var keysDown: Set<UInt16> = []
    private var buttonsDown: Set<MouseButton> = []
    private var droppedKeys: Set<UInt16> = []
    private var chatOpen = false
    private var pendingMove: (t: TimeInterval, x: Double, y: Double)?
    private var pendingDelta: (t: TimeInterval, dx: Double, dy: Double)?
    private var lastMoveEmit: TimeInterval = -1
    private var lastDeltaEmit: TimeInterval = -1
    private var lastLocation: CGPoint?
    private var windowAtStart: CGRect = .zero
    public private(set) var droppedFromOtherApps = 0

    public init(options: RecorderOptions = RecorderOptions(), window: @escaping @Sendable () -> CGRect?, robloxFrontmost: @escaping @Sendable () -> Bool) {
        self.options = options; self.window = window; self.robloxFrontmost = robloxFrontmost
    }

    public var state: State { lock.lock(); defer { lock.unlock() }; return stateValue }
    public var stepCount: Int { lock.lock(); defer { lock.unlock() }; return steps.count }
    public var recordedWindow: CGRect { lock.lock(); defer { lock.unlock() }; return windowAtStart }

    /// Seconds recorded so far (pauses excluded).
    public func elapsed(now: TimeInterval) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        switch stateValue {
        case .idle: return lastStepTime
        case .recording: return now - startTime - pausedTotal
        case .paused: return pausedAt - startTime - pausedTotal
        }
    }

    public func start(at time: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        steps = []; startTime = time; pausedTotal = 0; lastStepTime = 0
        keysDown = []; buttonsDown = []; droppedKeys = []; chatOpen = false
        pendingMove = nil; pendingDelta = nil; lastMoveEmit = -1; lastDeltaEmit = -1; lastLocation = nil
        droppedFromOtherApps = 0
        windowAtStart = window() ?? .zero
        stateValue = .recording
    }

    public func pause(at time: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard stateValue == .recording else { return }
        flushPending()
        // A key held across a pause would otherwise stay "down" for the whole pause when replayed.
        releaseEverything(at: time - startTime - pausedTotal)
        pausedAt = time
        stateValue = .paused
    }

    public func resume(at time: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard stateValue == .paused else { return }
        pausedTotal += time - pausedAt
        stateValue = .recording
    }

    /// Stop and return the steps. Keys and buttons still held get their release appended, so a macro never ends with a stuck key.
    @discardableResult
    public func stop(at time: TimeInterval) -> [MacroStep] {
        lock.lock(); defer { lock.unlock() }
        guard stateValue != .idle else { return steps }
        if stateValue == .recording {
            flushPending()
            releaseEverything(at: time - startTime - pausedTotal)
        }
        stateValue = .idle
        return steps
    }

    public func ingest(_ e: RawInput) {
        lock.lock(); defer { lock.unlock() }
        guard stateValue == .recording else { return }
        guard robloxFrontmost() else { droppedFromOtherApps += 1; return }   // privacy: other apps are never recorded
        let t = e.time - startTime - pausedTotal
        guard t >= 0 else { return }

        switch e.kind {
        case .keyDown:
            if e.isRepeat { return }
            // ⌃⌥⌘ + a key is one of SiverSol's shortcuts (pause, stop): never part of the recording.
            if e.isShortcut, !KeyNames.modifiers.contains(e.keyCode) { droppedKeys.insert(e.keyCode); return }
            if options.skipChatTyping {
                if chatOpen {
                    if e.keyCode == KeyNames.returnKey || e.keyCode == KeyNames.escape { chatOpen = false }
                    droppedKeys.insert(e.keyCode)
                    return
                }
                if e.keyCode == KeyNames.slash { chatOpen = true; droppedKeys.insert(e.keyCode); return }
            }
            guard !keysDown.contains(e.keyCode) else { return }
            flushPending()
            keysDown.insert(e.keyCode)
            append(.keyDown(code: e.keyCode), at: t)
        case .keyUp:
            if droppedKeys.remove(e.keyCode) != nil { return }
            guard keysDown.remove(e.keyCode) != nil else { return }   // pressed before recording began
            flushPending()
            append(.keyUp(code: e.keyCode), at: t)
        case .mouseMove, .mouseDrag:
            var dragging: MouseButton?
            if case .mouseDrag(let b) = e.kind { dragging = b }
            // Camera turns: right-drag, or a locked cursor (shift lock) that reports movement without moving.
            let locked = lastLocation.map { $0 == e.location } ?? false
            lastLocation = e.location
            if dragging == .right || (locked && (e.dx != 0 || e.dy != 0)) {
                if let p = pendingMove { emitMove(p); pendingMove = nil }
                pendingDelta = (t, (pendingDelta?.dx ?? 0) + e.dx, (pendingDelta?.dy ?? 0) + e.dy)
                if t - lastDeltaEmit >= 1 / options.moveHz { flushDelta() }
                return
            }
            guard let r = ratio(e.location) else { return }
            if pendingDelta != nil { flushDelta() }
            pendingMove = (t, r.x, r.y)
            if t - lastMoveEmit >= 1 / options.moveHz, let p = pendingMove { emitMove(p); pendingMove = nil }
        case .mouseDown(let button):
            guard let r = ratio(e.location) else { return }
            flushPending()
            buttonsDown.insert(button)
            append(.mouseDown(button: button, x: r.x, y: r.y), at: t)
        case .mouseUp(let button):
            guard buttonsDown.remove(button) != nil else { return }
            flushPending()
            let r = ratio(e.location, clamp: true) ?? (0.5, 0.5)
            append(.mouseUp(button: button, x: r.x, y: r.y), at: t)
        case .scroll:
            guard ratio(e.location) != nil else { return }
            flushPending()
            append(.scroll(dx: e.dx, dy: e.dy), at: t)
        }
    }

    // MARK: private (lock held)

    private func append(_ action: MacroAction, at t: TimeInterval) {
        steps.append(MacroStep(delay: max(0, t - lastStepTime), action))
        lastStepTime = max(lastStepTime, t)
    }

    private func emitMove(_ p: (t: TimeInterval, x: Double, y: Double)) {
        append(.mouseMove(x: p.x, y: p.y), at: p.t)
        lastMoveEmit = p.t
    }

    private func flushDelta() {
        guard let d = pendingDelta else { return }
        pendingDelta = nil
        if d.dx != 0 || d.dy != 0 { append(.mouseDelta(dx: d.dx, dy: d.dy), at: d.t) }
        lastDeltaEmit = d.t
    }

    /// Write out the latest thinned mouse position or camera turn, so the cursor is where it really was before a click or key.
    private func flushPending() {
        if let p = pendingMove { emitMove(p); pendingMove = nil }
        flushDelta()
    }

    private func releaseEverything(at t: TimeInterval) {
        for code in keysDown.sorted() { append(.keyUp(code: code), at: t) }
        keysDown = []
        for button in MouseButton.allCases where buttonsDown.contains(button) { append(.mouseUp(button: button, x: 0.5, y: 0.5), at: t) }
        buttonsDown = []
    }

    /// Global point -> window ratio. nil when there is no Roblox window or the point is outside it.
    private func ratio(_ p: CGPoint, clamp: Bool = false) -> (x: Double, y: Double)? {
        guard let w = window(), w.width > 1, w.height > 1 else { return nil }
        let x = Double((p.x - w.minX) / w.width), y = Double((p.y - w.minY) / w.height)
        if clamp { return (min(1, max(0, x)), min(1, max(0, y))) }
        guard x >= 0, x <= 1, y >= 0, y <= 1 else { return nil }
        return (x, y)
    }
}

/// Editing helpers for the timeline editor.
public enum MacroEditing {
    /// Remove a range of steps. The delay of the step after the gap absorbs the removed time, so the rest keeps its timing,
    /// unless `closeGap` is set (trim).
    public static func delete(_ steps: [MacroStep], range: Range<Int>, closeGap: Bool = false) -> [MacroStep] {
        guard range.lowerBound >= 0, range.upperBound <= steps.count, !range.isEmpty else { return steps }
        var out = steps
        let removed = steps[range].reduce(0) { $0 + $1.delay }
        out.removeSubrange(range)
        if !closeGap, range.lowerBound < out.count { out[range.lowerBound].delay += removed }
        return balance(out)
    }

    /// Keep only the steps in the range (trim both ends).
    public static func trim(_ steps: [MacroStep], to range: Range<Int>) -> [MacroStep] {
        guard range.lowerBound >= 0, range.upperBound <= steps.count else { return steps }
        var out = Array(steps[range])
        if !out.isEmpty { out[0].delay = 0 }
        return balance(out)
    }

    /// Collapse runs of consecutive mouse moves (or camera turns) into one step each. Total time is unchanged.
    public static func mergeMouseMoves(_ steps: [MacroStep]) -> [MacroStep] {
        var out: [MacroStep] = []
        for step in steps {
            if let last = out.last {
                switch (last.action, step.action) {
                case (.mouseMove, .mouseMove(let x, let y)):
                    out[out.count - 1] = MacroStep(delay: last.delay + step.delay, .mouseMove(x: x, y: y)); continue
                case (.mouseDelta(let a, let b), .mouseDelta(let dx, let dy)):
                    out[out.count - 1] = MacroStep(delay: last.delay + step.delay, .mouseDelta(dx: a + dx, dy: b + dy)); continue
                default: break
                }
            }
            out.append(step)
        }
        return out
    }

    /// Remove SiverSol's own shortcuts from a recording, wherever they are. Pressing ⌃⌥⌘E to pause or ⌃⌥⌘R to
    /// stop is not part of the macro: the three modifier presses that make up the chord go, and so does any key
    /// pressed while Control, Option and Command were all held. Other modifiers (Shift for sprinting) stay.
    /// The time the removed steps took is handed to the next step, so the rest keeps its rhythm.
    public static func dropShortcutChords(_ steps: [MacroStep]) -> [MacroStep] {
        let control: Set<UInt16> = [59, 62], option: Set<UInt16> = [58, 61], command: Set<UInt16> = [54, 55]
        let chordKeys = control.union(option).union(command)
        func isChord(_ held: Dictionary<UInt16, Int>.Keys) -> Bool {
            let h = Set(held)
            return !h.isDisjoint(with: control) && !h.isDisjoint(with: option) && !h.isDisjoint(with: command)
        }
        var remove = Set<Int>()
        var heldAt: [UInt16: Int] = [:]          // chord modifier -> index of its key-down
        var members = Set<UInt16>()              // modifiers whose press was removed: their release goes too
        var droppedKeys = Set<UInt16>()
        for (i, step) in steps.enumerated() {
            switch step.action {
            case .keyDown(let c) where chordKeys.contains(c):
                heldAt[c] = i
                if isChord(heldAt.keys) { for (code, index) in heldAt { remove.insert(index); members.insert(code) } }
            case .keyUp(let c) where chordKeys.contains(c):
                heldAt[c] = nil
                if members.remove(c) != nil { remove.insert(i) }
            case .keyDown(let c) where !KeyNames.modifiers.contains(c):
                if isChord(heldAt.keys) { remove.insert(i); droppedKeys.insert(c) }
            case .keyUp(let c) where !KeyNames.modifiers.contains(c):
                if droppedKeys.remove(c) != nil { remove.insert(i) }
            default: break
            }
        }
        guard !remove.isEmpty else { return steps }
        var out: [MacroStep] = []
        var carried = 0.0
        for (i, step) in steps.enumerated() {
            if remove.contains(i) { carried += step.delay; continue }
            var s = step; s.delay += carried; carried = 0
            out.append(s)
        }
        return balance(out)
    }

    /// The older name, kept for callers that only cared about the end of a recording.
    public static func dropTrailingShortcut(_ steps: [MacroStep]) -> [MacroStep] { dropShortcutChords(steps) }

    /// Make sure every key and button that goes down also comes up (edits can remove one half of a pair).
    /// A removed half hands its delay to the next step, so the overall timing is kept.
    public static func balance(_ steps: [MacroStep]) -> [MacroStep] {
        var keys: Set<UInt16> = [], buttons: Set<MouseButton> = []
        var out: [MacroStep] = []
        var carried = 0.0
        for step in steps {
            var keep = true
            switch step.action {
            case .keyDown(let c): keep = keys.insert(c).inserted
            case .keyUp(let c): keep = keys.remove(c) != nil
            case .mouseDown(let b, _, _): keep = buttons.insert(b).inserted
            case .mouseUp(let b, _, _): keep = buttons.remove(b) != nil
            default: break
            }
            guard keep else { carried += step.delay; continue }
            var s = step
            s.delay += carried
            carried = 0
            out.append(s)
        }
        for c in keys.sorted() { out.append(MacroStep(delay: 0, .keyUp(code: c))) }
        for b in MouseButton.allCases where buttons.contains(b) { out.append(MacroStep(delay: 0, .mouseUp(button: b, x: 0.5, y: 0.5))) }
        return out
    }
}
