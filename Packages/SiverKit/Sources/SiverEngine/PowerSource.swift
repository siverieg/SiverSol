import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import SiverCore

/// The Mac's power source, from IOKit. No permission is needed for any of this.
public enum PowerSource {
    public static func read() -> PowerReading {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return .desktop }
        let sources = list.compactMap { IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
        return PowerReading.parse(sources)
    }
}

/// Keeps the Mac from going to sleep by itself while SiverSol is watching. This is an IOKit power assertion
/// (the kind `pmset -g assertions` lists): it needs no permission, it does not keep the display on, and it
/// cannot keep a MacBook awake with its lid closed.
public final class StayAwake: @unchecked Sendable {
    private let lock = NSLock()
    private var id: IOPMAssertionID = 0
    private var held = false

    public init() {}

    public var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return held }

    public func hold(reason: String = "SiverSol is watching Roblox") {
        lock.lock(); defer { lock.unlock() }
        guard !held else { return }
        var new: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &new)
        if result == kIOReturnSuccess { id = new; held = true }
    }

    public func release() {
        lock.lock(); defer { lock.unlock() }
        guard held else { return }
        IOPMAssertionRelease(id)
        held = false
        id = 0
    }

    deinit { if held { IOPMAssertionRelease(id) } }
}
