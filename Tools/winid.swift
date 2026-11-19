// Phase 0 helper: print Roblox windows (id, bounds in points, layer) and screen scale factors.
import AppKit
import CoreGraphics

let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let list = (CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]) ?? []
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    guard owner.lowercased().contains("roblox") else { continue }
    let id = w[kCGWindowNumber as String] as? Int ?? 0
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let name = w[kCGWindowName as String] as? String ?? "<no name / no Screen Recording>"
    print("owner=\(owner) pid=\(pid) windowId=\(id) layer=\(layer) bounds=\(b) name=\(name)")
}
for (i, s) in NSScreen.screens.enumerated() {
    print("screen[\(i)] frame=\(s.frame) scale=\(s.backingScaleFactor) name=\(s.localizedName)")
}
print("screenCapturePreflight=\(CGPreflightScreenCaptureAccess()) axTrusted=\(AXIsProcessTrusted())")
