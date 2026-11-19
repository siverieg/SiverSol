import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import SiverCore

/// Keys SiverSol may press. Deliberately short: movement, jump, camera zoom, escape.
public enum Key: String, CaseIterable, Sendable {
    case space, escape, i, o, w, a, s, d

    public var code: CGKeyCode {
        switch self {
        case .space: return CGKeyCode(kVK_Space)
        case .escape: return CGKeyCode(kVK_Escape)
        case .i: return CGKeyCode(kVK_ANSI_I)
        case .o: return CGKeyCode(kVK_ANSI_O)
        case .w: return CGKeyCode(kVK_ANSI_W)
        case .a: return CGKeyCode(kVK_ANSI_A)
        case .s: return CGKeyCode(kVK_ANSI_S)
        case .d: return CGKeyCode(kVK_ANSI_D)
        }
    }
}

/// How long since the user last touched the keyboard or mouse (hardware events only).
public enum UserActivity {
    public static func secondsSinceLastInput() -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .leftMouseDragged, .flagsChanged]
        return types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
    }
}

/// Synthetic keyboard and mouse input through CGEvent. Needs Accessibility. Tracks what it holds so a panic can release it.
public final class InputDriver: @unchecked Sendable {
    public enum Delivery: String, Codable, Sendable {
        /// `CGEvent.postToPid`: goes straight to Roblox, no focus change.
        case toProcess
        /// HID event tap: goes to whichever app is frontmost, so Roblox must be brought forward first.
        case hid
    }

    private let lock = NSLock()
    private var held: Set<Key> = []
    private var lastOwnInput = Date.distantPast
    public private(set) var aborted = false

    public init() {}

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Seconds since a real person used the Mac.
    /// Our own synthetic events reset the system's idle counter too (seen in the soak: the counter read exactly
    /// "time since the last anti-AFK press"). When the two agree, the last event was ours, so the user counts as idle.
    public func userIdleSeconds() -> TimeInterval {
        let idle = UserActivity.secondsSinceLastInput()
        let own = secondsSinceOwnInput()
        return abs(idle - own) < 1.5 || own < 0.3 ? max(idle, 10_000) : idle
    }

    private func post(_ key: Key, down: Bool, delivery: Delivery, pid: pid_t?) {
        guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: key.code, keyDown: down) else { return }
        // The system input path delivers to whichever app is in front. A press only goes out when that is Roblox;
        // a release always goes out, so a key can never stay down.
        let toProcess = delivery == .toProcess && pid != nil
        if down, !toProcess, !FocusManager.robloxIsFrontmost { return }
        lock.lock()
        if down { held.insert(key) } else { held.remove(key) }
        lastOwnInput = Date()
        lock.unlock()
        if delivery == .toProcess, let pid { event.postToPid(pid) } else { event.post(tap: .cghidEventTap) }
    }

    /// Press and release one key. Returns false if it was cut short because the user touched the Mac (F11).
    @discardableResult
    public func tap(_ key: Key, delivery: Delivery, pid: pid_t?, hold: TimeInterval = 0.06, yieldToUser: Bool = true) async -> Bool {
        post(key, down: true, delivery: delivery, pid: pid)
        try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
        post(key, down: false, delivery: delivery, pid: pid)
        if yieldToUser, UserActivity.secondsSinceLastInput() < hold, secondsSinceOwnInput() > 0.3 {
            aborted = true
            return false
        }
        return true
    }

    /// Left click at a global point (display points). HID only: mouse clicks cannot be targeted at a process reliably.
    /// Nothing is clicked unless Roblox is the front app at that moment. Returns whether the click went out.
    @discardableResult
    public func click(at point: CGPoint) async -> Bool {
        guard FocusManager.robloxIsFrontmost else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        markOwnInput()
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 60_000_000)
        guard FocusManager.robloxIsFrontmost else { return false }
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 50_000_000)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        markOwnInput()
        return true
    }

    private func markOwnInput() {
        lock.lock(); lastOwnInput = Date(); lock.unlock()
    }

    private func secondsSinceOwnInput() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastOwnInput)
    }

    /// Panic: let go of everything we might be holding, through both delivery paths.
    public func releaseAll(pid: pid_t? = nil) {
        lock.lock(); let keys = held; held.removeAll(); lock.unlock()
        for key in keys {
            let up = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: key.code, keyDown: false)
            up?.post(tap: .cghidEventTap)
            if let pid { up?.postToPid(pid) }
        }
        let source = CGEventSource(stateID: .hidSystemState)
        if CGEventSource.buttonState(.hidSystemState, button: .left) {
            let p = CGEvent(source: nil)?.location ?? .zero
            CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    public var heldKeys: Set<Key> { lock.lock(); defer { lock.unlock() }; return held }
}

/// Bring Roblox forward for a moment, then give focus back to whatever the user was using (F7).
public enum FocusManager {
    public static func robloxApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: RobloxWindowFinder.bundleId).first
    }

    /// The process that owns the frontmost normal window, read from the window server.
    /// (`NSWorkspace.frontmostApplication` goes stale in a process without a run loop, such as the command-line tool.)
    public static func frontmostPID() -> pid_t? {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            if let pid = w[kCGWindowOwnerPID as String] as? Int { return pid_t(pid) }
        }
        return nil
    }

    public static var robloxIsFrontmost: Bool {
        guard let front = frontmostPID() else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: RobloxWindowFinder.bundleId).contains { $0.processIdentifier == front }
    }

    /// Bring an app to the front. macOS often ignores a plain activation request from a background process, so
    /// if that does not work within a moment the Accessibility API is used (same permission SiverSol already has).
    @discardableResult
    public static func bringToFront(_ app: NSRunningApplication, timeout: TimeInterval = 1.2) async -> Bool {
        func isFront() -> Bool { frontmostPID() == app.processIdentifier }
        if isFront() { return true }
        app.activate(options: [])
        let firstTry = Date().addingTimeInterval(min(0.35, timeout))
        while !isFront() && Date() < firstTry { try? await Task.sleep(nanoseconds: 20_000_000) }
        if !isFront() {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXMainWindowAttribute as CFString, &window) == .success, let window {
                AXUIElementPerformAction(window as! AXUIElement, kAXRaiseAction as CFString)
            }
            let deadline = Date().addingTimeInterval(timeout)
            while !isFront() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        return isFront()
    }

    @discardableResult
    public static func bringRobloxToFront(timeout: TimeInterval = 1.2) async -> Bool {
        guard let roblox = robloxApp() else { return false }
        return await bringToFront(roblox, timeout: timeout)
    }

    /// Runs `body` with Roblox frontmost and restores the previous app afterwards. Returns nil if Roblox would not come forward.
    public static func withRobloxFrontmost<T>(timeout: TimeInterval = 1.2, _ body: () async -> T) async -> T? {
        guard robloxApp() != nil else { return nil }
        let previous = frontmostPID().flatMap { NSRunningApplication(processIdentifier: $0) }
        if !robloxIsFrontmost {
            guard await bringRobloxToFront(timeout: timeout) else { return nil }
            try? await Task.sleep(nanoseconds: 80_000_000)   // let the window become key
        }
        let result = await body()
        if let previous, previous.bundleIdentifier != RobloxWindowFinder.bundleId { await bringToFront(previous, timeout: 0.8) }
        return result
    }
}

/// A system-wide hotkey through Carbon. Works without Accessibility. Default: ⌃⌥⌘P (panic, F11).
public final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private let action: () -> Void
    private let released: (() -> Void)?
    private static var registry: [UInt32: GlobalHotKey] = [:]
    private static var nextId: UInt32 = 1
    private static var handler: EventHandlerRef?
    private let id: UInt32

    /// One handler serves every shortcut. (Installing the same handler a second time is refused by the system,
    /// which is why each shortcut cannot bring its own.)
    private static func installHandler() -> Bool {
        if handler != nil { return true }
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard let key = GlobalHotKey.registry[hotKeyID.id] else { return OSStatus(eventNotHandledErr) }
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) { key.released?() } else { key.action() }
            return noErr
        }, 2, &specs, nil, &handler)
        return status == noErr
    }

    /// `released` is called when the keys are let go (for hold-to-run shortcuts).
    /// Returns nil when macOS refuses the combination (another app owns it).
    public init?(keyCode: UInt32 = UInt32(kVK_ANSI_P), modifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey),
                 released: (() -> Void)? = nil, action: @escaping () -> Void) {
        self.action = action
        self.released = released
        id = Self.nextId; Self.nextId += 1
        guard Self.installHandler() else { return nil }
        let hotKeyID = EventHotKeyID(signature: OSType(0x53565253), id: id)   // 'SVRS'
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
        Self.registry[id] = self
    }

    public func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.registry[id] = nil
    }

    deinit { unregister() }
}
