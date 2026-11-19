// Print on-screen windows of an app by owner name: `swift Tools/appwin.swift SiverSol`
import AppKit
import CoreGraphics
let owner = CommandLine.arguments.dropFirst().first ?? "SiverSol"
let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == owner {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print("windowId=\(w[kCGWindowNumber as String] ?? 0) layer=\(w[kCGWindowLayer as String] ?? 0) x=\(b["X"] ?? 0) y=\(b["Y"] ?? 0) w=\(b["Width"] ?? 0) h=\(b["Height"] ?? 0) name=\(w[kCGWindowName as String] ?? "")")
}
