import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import SiverCore

/// Marker written into every event SiverSol posts, so its own playback is never mistaken for the user,
/// and never recorded.
public let siverSolEventMarker: Int64 = 0x5356_534F   // "SVSO"

/// Posts a macro's steps as real input through CGEvent. Needs Accessibility, nothing else.
public final class LiveMacroOutput: MacroOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var heldKeys: Set<UInt16> = []
    private var heldButtons: Set<MouseButton> = []
    private var flags: CGEventFlags = []
    private let window: @Sendable () -> CGRect?
    private let pid: @Sendable () -> pid_t?
    private let heldFile: URL?
    /// Keyboard-only macros go straight to the Roblox process, so they play without Roblox being frontmost.
    public var keyboardToProcess = false
    /// Is Roblox the front app right now? Everything that is not sent straight to the Roblox process goes to
    /// whichever app is in front, so presses, clicks and moves are dropped unless this says yes.
    private let robloxFrontmost: (@Sendable () -> Bool)?
    private var frontCache: (value: Bool, at: TimeInterval)?
    private var lostFocus = false
    private var lostWindow = false

    public init(window: @escaping @Sendable () -> CGRect?, pid: @escaping @Sendable () -> pid_t?, heldFile: URL? = nil,
                robloxFrontmost: (@Sendable () -> Bool)? = nil) {
        self.window = window; self.pid = pid; self.heldFile = heldFile; self.robloxFrontmost = robloxFrontmost
    }

    /// True once an event was dropped because Roblox was not in front. The player stops the macro when it sees this.
    public var focusLost: Bool { lock.lock(); defer { lock.unlock() }; return lostFocus }
    public func resetFocusLost() { lock.lock(); lostFocus = false; lostWindow = false; frontCache = nil; lock.unlock() }
    /// True once a mouse step had nowhere to go because the Roblox window could not be found (closed, minimised,
    /// or on a display that was unplugged). The player stops the macro when it sees this; nothing is ever sent
    /// to where the window used to be.
    public var windowLost: Bool { lock.lock(); defer { lock.unlock() }; return lostWindow }

    /// `fresh`: ask the window server now (presses and clicks). Otherwise an answer up to 0.1 s old will do (moves).
    private func mayPostToFrontApp(fresh: Bool) -> Bool {
        guard let robloxFrontmost else { return true }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if !fresh, let c = frontCache, now - c.at < 0.1 { let v = c.value; lock.unlock(); return v }
        lock.unlock()
        let front = robloxFrontmost()
        lock.lock()
        frontCache = (front, now)
        if !front { lostFocus = true }
        lock.unlock()
        return front
    }

    static let modifierFlags: [UInt16: CGEventFlags] = [56: .maskShift, 60: .maskShift, 59: .maskControl, 62: .maskControl,
                                                         58: .maskAlternate, 61: .maskAlternate, 55: .maskCommand, 54: .maskCommand]

    /// `press`: a key or button going down, a move or a scroll. Releases are always let through: letting go of
    /// something is harmless wherever it lands, and a key must never stay down.
    private func post(_ event: CGEvent?, keyboard: Bool, press: Bool = true, fresh: Bool = true) {
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: siverSolEventMarker)
        if keyboard, keyboardToProcess, let pid = pid() { event.postToPid(pid); return }
        if press, !mayPostToFrontApp(fresh: fresh) { return }
        event.post(tap: .cghidEventTap)
    }

    private func key(_ code: UInt16, down: Bool) {
        lock.lock()
        if down { heldKeys.insert(code) } else { heldKeys.remove(code) }
        if let flag = Self.modifierFlags[code] { if down { flags.insert(flag) } else { flags.remove(flag) } }
        let current = flags
        let snapshot = heldKeys
        lock.unlock()
        let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: down)
        if Self.modifierFlags[code] != nil { event?.type = .flagsChanged }
        event?.flags = current
        post(event, keyboard: true, press: down)
        persist(snapshot)
    }

    public func keyDown(_ code: UInt16) { key(code, down: true) }
    public func keyUp(_ code: UInt16) { key(code, down: false) }

    /// Ratio of the game area -> global point. The window is looked up again every time, so a window that
    /// moved (to another display, say) is followed and one that is gone is never clicked.
    private func point(_ x: Double, _ y: Double) -> CGPoint? {
        guard let w = window(), w.width > 1, w.height > 1 else {
            lock.lock(); lostWindow = true; lock.unlock()
            return nil
        }
        return CGPoint(x: w.minX + w.width * x, y: w.minY + w.height * y)
    }

    private func cgButton(_ b: MouseButton) -> CGMouseButton { b == .left ? .left : b == .right ? .right : .center }
    private var dragging: MouseButton? { lock.lock(); defer { lock.unlock() }; return MouseButton.allCases.first { heldButtons.contains($0) } }

    private func moveType() -> (CGEventType, CGMouseButton) {
        switch dragging {
        case .left?: return (.leftMouseDragged, .left)
        case .right?: return (.rightMouseDragged, .right)
        case .middle?: return (.otherMouseDragged, .center)
        case nil: return (.mouseMoved, .left)
        }
    }

    public func mouseMove(x: Double, y: Double) {
        guard let p = point(x, y) else { return }
        let (type, button) = moveType()
        post(CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type, mouseCursorPosition: p, mouseButton: button), keyboard: false, fresh: false)
    }

    public func mouseDown(_ b: MouseButton, x: Double, y: Double) {
        guard let p = point(x, y) else { return }
        lock.lock(); heldButtons.insert(b); lock.unlock()
        let type: CGEventType = b == .left ? .leftMouseDown : b == .right ? .rightMouseDown : .otherMouseDown
        post(CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type, mouseCursorPosition: p, mouseButton: cgButton(b)), keyboard: false)
    }

    public func mouseUp(_ b: MouseButton, x: Double, y: Double) {
        lock.lock(); let was = heldButtons.remove(b) != nil; lock.unlock()
        guard was else { return }
        let p = point(x, y) ?? (CGEvent(source: nil)?.location ?? .zero)
        let type: CGEventType = b == .left ? .leftMouseUp : b == .right ? .rightMouseUp : .otherMouseUp
        post(CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type, mouseCursorPosition: p, mouseButton: cgButton(b)), keyboard: false, press: false)
    }

    /// A camera turn: movement without a target position, the way a locked cursor reports it.
    public func mouseDelta(dx: Double, dy: Double) {
        let here = CGEvent(source: nil)?.location ?? .zero
        let (type, button) = moveType()
        let event = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type, mouseCursorPosition: here, mouseButton: button)
        event?.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        event?.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        post(event, keyboard: false, fresh: false)
    }

    public func scroll(dx: Double, dy: Double) {
        post(CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .line, wheelCount: 2,
                     wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0), keyboard: false)
    }

    public func releaseAll() {
        lock.lock()
        let keys = heldKeys, buttons = heldButtons
        heldKeys = []; heldButtons = []; flags = []
        lock.unlock()
        for code in keys {
            // Released through both paths: a key pressed in the background must not stay down because the mode changed.
            let up = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: false)
            if Self.modifierFlags[code] != nil { up?.type = .flagsChanged }
            up?.setIntegerValueField(.eventSourceUserData, value: siverSolEventMarker)
            up?.post(tap: .cghidEventTap)
            if let pid = pid() { up?.postToPid(pid) }
        }
        let here = CGEvent(source: nil)?.location ?? .zero
        for b in buttons {
            let type: CGEventType = b == .left ? .leftMouseUp : b == .right ? .rightMouseUp : .otherMouseUp
            post(CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type, mouseCursorPosition: here, mouseButton: cgButton(b)), keyboard: false, press: false)
        }
        persist([])
    }

    public var hasHeldInput: Bool { lock.lock(); defer { lock.unlock() }; return !heldKeys.isEmpty || !heldButtons.isEmpty }

    // Crash protection: the keys currently held are written to a small file. If SiverSol dies with keys down,
    // the next launch reads the file and releases them.
    private func persist(_ keys: Set<UInt16>) {
        guard let heldFile else { return }
        if keys.isEmpty { try? FileManager.default.removeItem(at: heldFile); return }
        try? Data(keys.sorted().map(String.init).joined(separator: ",").utf8).write(to: heldFile, options: .atomic)
    }

    /// Release keys a previous run left down (after a crash). Returns how many were released.
    @discardableResult
    public static func releaseLeftovers(file: URL, pid: pid_t?) -> Int {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return 0 }
        let codes = text.split(separator: ",").compactMap { UInt16($0) }.filter { $0 <= 127 }
        for code in codes {
            let up = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: false)
            up?.setIntegerValueField(.eventSourceUserData, value: siverSolEventMarker)
            up?.post(tap: .cghidEventTap)
            if let pid { up?.postToPid(pid) }
        }
        try? FileManager.default.removeItem(at: file)
        return codes.count
    }
}

/// A pass-through event tap: it sees keyboard and mouse events and lets every one of them continue unchanged.
/// It is an *active* session tap, which macOS allows with the Accessibility permission (a listen-only tap would
/// need Input Monitoring instead). It runs only while a recording is in progress or a mouse macro is playing.
public final class InputTap: @unchecked Sendable {
    public typealias Handler = @Sendable (_ event: RawInput, _ isOwn: Bool) -> Void

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let handler: Handler
    private let lock = NSLock()

    public init(handler: @escaping Handler) { self.handler = handler }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return port != nil }

    /// What this process is allowed to do, without prompting. `listenAccess` is the Input Monitoring grant.
    public static func permissions() -> (accessibility: Bool, listenAccess: Bool) {
        (AXIsProcessTrusted(), CGPreflightListenEventAccess())
    }

    static let mask: CGEventMask = {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                    .rightMouseDown, .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    }()

    /// Create the tap. False when macOS refuses (Accessibility not granted).
    @discardableResult
    public func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if port != nil { return true }
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: Self.mask,
                                          callback: { _, type, event, info in
                                              guard let info else { return Unmanaged.passUnretained(event) }
                                              Unmanaged<InputTap>.fromOpaque(info).takeUnretainedValue().handle(type, event)
                                              return Unmanaged.passUnretained(event)   // always passed on, never changed
                                          }, userInfo: info) else { return false }
        port = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        source = src
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
            self?.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        t.name = "siversol.inputtap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        ready.wait()
        return true
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard let tap = port else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoop { CFRunLoopStop(runLoop) }
        CFMachPortInvalidate(tap)
        port = nil; source = nil; thread = nil; runLoop = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return
        }
        let own = event.getIntegerValueField(.eventSourceUserData) == siverSolEventMarker
        let time = Double(event.timestamp) / 1_000_000_000
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        var raw: RawInput
        switch type {
        case .keyDown: raw = RawInput(.keyDown, time: time, keyCode: code, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        case .keyUp: raw = RawInput(.keyUp, time: time, keyCode: code)
        case .flagsChanged:
            // A modifier went down if its flag is now set.
            guard let flag = LiveMacroOutput.modifierFlags[code] else { return }
            raw = RawInput(event.flags.contains(flag) ? .keyDown : .keyUp, time: time, keyCode: code)
        case .mouseMoved: raw = RawInput(.mouseMove, time: time)
        case .leftMouseDragged: raw = RawInput(.mouseDrag(.left), time: time)
        case .rightMouseDragged: raw = RawInput(.mouseDrag(.right), time: time)
        case .otherMouseDragged: raw = RawInput(.mouseDrag(.middle), time: time)
        case .leftMouseDown: raw = RawInput(.mouseDown(.left), time: time)
        case .leftMouseUp: raw = RawInput(.mouseUp(.left), time: time)
        case .rightMouseDown: raw = RawInput(.mouseDown(.right), time: time)
        case .rightMouseUp: raw = RawInput(.mouseUp(.right), time: time)
        case .otherMouseDown: raw = RawInput(.mouseDown(.middle), time: time)
        case .otherMouseUp: raw = RawInput(.mouseUp(.middle), time: time)
        case .scrollWheel:
            raw = RawInput(.scroll, time: time, dx: Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)),
                           dy: Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)))
        default: return
        }
        raw.location = event.location
        raw.isShortcut = event.flags.isSuperset(of: [.maskControl, .maskAlternate, .maskCommand])
        if type != .scrollWheel, type != .keyDown, type != .keyUp, type != .flagsChanged {
            raw.dx = Double(event.getIntegerValueField(.mouseEventDeltaX))
            raw.dy = Double(event.getIntegerValueField(.mouseEventDeltaY))
        }
        handler(raw, own)
    }
}
