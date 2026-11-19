import AppKit
import SiverCore
import SiverInput
import SiverMacro
import SwiftUI

/// A rectangle that can be read from any thread (the event tap asks where the bar is).
final class FrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var rect: CGRect?
    var value: CGRect? {
        get { lock.lock(); defer { lock.unlock() }; return rect }
        set { lock.lock(); rect = newValue; lock.unlock() }
    }
}

/// The small floating bar shown while a macro is recording or playing.
/// It is a non-activating panel: clicking it does not take focus away from Roblox, so the recording carries on.
@MainActor
final class RecorderBarController {
    /// The bar's frame in global screen coordinates (top-left origin), or nil while hidden.
    nonisolated let frameBox = FrameBox()
    private var panel: NSPanel?
    private var observer: NSObjectProtocol?

    func update(visible: Bool) {
        if visible { show() } else { hide() }
    }

    private func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 52),
                            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless], backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = true
            p.isMovableByWindowBackground = true
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: RecorderBarView().environmentObject(AppModel.shared))
            // On the screen Roblox is on, under the menu bar (and so under a notch), clear of the island.
            if let shape = Screens.forRoblox(RobloxWindowFinder.mainWindow()?.bounds) {
                let f = shape.visibleFrame
                p.setFrameOrigin(NSPoint(x: f.midX - 180, y: min(f.maxY, shape.frame.maxY - shape.safeTop) - 64 - 44))
            }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publishFrame() }
            }
            panel = p
        }
        if panel?.isVisible != true { panel?.orderFrontRegardless() }
        publishFrame()
    }

    private func hide() {
        guard panel?.isVisible == true else { return }
        panel?.orderOut(nil)
        frameBox.value = nil
    }

    /// Cocoa measures from the bottom-left of the main screen; input events measure from its top-left.
    private func publishFrame() {
        guard let panel, panel.isVisible, let primary = NSScreen.screens.first else { frameBox.value = nil; return }
        let f = panel.frame
        frameBox.value = CGRect(x: f.minX, y: primary.frame.height - f.maxY, width: f.width, height: f.height)
    }
}

struct RecorderBarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let s = model.macroStatus
        HStack(spacing: 10) {
            if s.recording != .idle {
                Image(systemName: s.recording == .paused ? "pause.circle.fill" : "record.circle.fill")
                    .foregroundStyle(s.recording == .paused ? Color.orange : Color.red)
                    .symbolEffect(.pulse, isActive: s.recording == .recording)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 0) {
                    Text(s.recording == .paused ? "Paused" : "Recording").font(.callout.weight(.semibold))
                    Text("\(AppModel.clock(s.recordedSeconds)) · \(s.recordedSteps) steps").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button { model.pauseOrResumeRecording() } label: { Image(systemName: s.recording == .paused ? "play.fill" : "pause.fill") }
                    .help(s.recording == .paused ? "Resume (⌃⌥⌘E)" : "Pause (⌃⌥⌘E)")
                    .accessibilityLabel(s.recording == .paused ? "Resume recording" : "Pause recording")
                Button { model.stopRecording() } label: { Image(systemName: "stop.fill") }
                    .help("Stop and save (⌃⌥⌘R)")
                    .accessibilityLabel("Stop recording and save")
            } else if let p = s.playing {
                Image(systemName: "play.circle.fill").foregroundStyle(.green).font(.title3)
                VStack(alignment: .leading, spacing: 0) {
                    Text(p.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text("loop \(p.loop + 1)\(p.totalLoops == 0 ? "" : " of \(p.totalLoops)") · step \(p.step) of \(p.totalSteps)")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button { model.stopMacro() } label: { Image(systemName: "stop.fill") }
                    .help("Stop (⌃⌥⌘M)").accessibilityLabel("Stop the macro")
            } else if s.autoClicking {
                Image(systemName: "cursorarrow.click.2").foregroundStyle(.green).font(.title3)
                Text("Auto clicker running").font(.callout.weight(.semibold))
                Spacer(minLength: 4)
                Button { model.stopMacro() } label: { Image(systemName: "stop.fill") }
                    .help("Stop (⌃⌥⌘K)").accessibilityLabel("Stop the auto clicker")
            }
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 14)
        .frame(width: 360, height: 52)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
    }
}
