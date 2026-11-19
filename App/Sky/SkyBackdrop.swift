import AppKit
import MetalKit
import SiverCore
import SiverSky
import SwiftUI

/// The sky layer: one Metal view behind everything else in the window.
///
/// It draws at most 30 times a second, and only while its window is really on screen: a hidden, covered or
/// minimised window stops it completely. With Reduce Motion on it paints a still sky (no particles) and repaints
/// only when something changes.
struct SkyBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var sky = SkyState.shared

    var body: some View {
        Group {
            if SkyMetalView.renderer != nil {
                SkyMetalBackdrop(reduceMotion: reduceMotion, powerStill: sky.powerStill, stamp: sky.look)
            } else {
                // No Metal on this Mac: a plain painted sky.
                LinearGradient(colors: [sky.look.top.color, sky.look.bottom.color], startPoint: .top, endPoint: .bottom)
            }
        }
        .onAppear { sky.setDark(scheme == .dark) }
        .onChange(of: scheme) { _, new in sky.setDark(new == .dark) }
        .accessibilityHidden(true)
    }
}

private struct SkyMetalBackdrop: NSViewRepresentable {
    let reduceMotion: Bool
    /// Low Power Mode or a hot Mac: the view is asked again whether it may animate.
    let powerStill: Bool
    /// Changes whenever the sky's colours do, so the still sky is repainted.
    let stamp: SkyLook

    func makeNSView(context: Context) -> SkyMetalView { SkyMetalView() }

    func updateNSView(_ view: SkyMetalView, context: Context) {
        view.reduceMotion = reduceMotion
        view.refresh()
    }
}

/// The sky's view: a Metal layer that is drawn from its own thread.
///
/// Drawing never waits for the main thread, so building a page, a menu or a sheet cannot make the sky skip a
/// frame. The view itself only decides WHEN the sky may move (the window is on screen, motion is allowed) and
/// keeps the drawing thread told about the view's size; `SkyPump` does the drawing.
final class SkyMetalView: NSView {
    static let renderer = SkyRenderer.shared
    static let framesPerSecond = 30

    var reduceMotion = false
    private let metal = CAMetalLayer()
    private let pump: SkyPump
    private var stillTimer: Timer?
    private var link: CADisplayLink?
    private var observers: [NSObjectProtocol] = []

    // Performance notes (read by the design review).
    static var framesDrawn: Int { SkyPump.stats.frames }
    static var ticks: Int { SkyPump.stats.ticks }
    static var worstGap: CFTimeInterval { SkyPump.stats.worstGap }
    static func resetGap() { SkyPump.stats.resetGap() }

    init() {
        pump = SkyPump(layer: metal)
        super.init(frame: .zero)
        metal.device = Self.renderer?.device
        metal.pixelFormat = SkyRenderer.pixelFormat
        metal.framebufferOnly = true
        metal.isOpaque = true
        layer = metal
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        link?.invalidate()
        pump.stop()
    }

    // The sky is scenery: clicks go to whatever is in front of it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else {
            stillTimer?.invalidate()
            link?.invalidate()
            link = nil
            pump.setActive(false)
            return
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeBackingPropertiesNotification, NSWindow.didChangeScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.refresh() })
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        refresh()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resizeDrawable()
        pump.drawSoon()
    }

    /// The sky is soft: one pixel per point is enough on an ordinary display, and 1.5 on a Retina one.
    private var renderScale: CGFloat { min(window?.backingScaleFactor ?? 1, 1.5) }

    /// Tell the layer and the drawing thread how large the view is and where it sits in the window (the
    /// hero's arc is reported in window coordinates).
    private func resizeDrawable() {
        let s = renderScale
        let size = CGSize(width: max(1, (bounds.width * s).rounded()), height: max(1, (bounds.height * s).rounded()))
        if size != metal.drawableSize { metal.drawableSize = size }
        var origin = CGPoint.zero
        if let content = window?.contentView {
            let r = convert(bounds, to: content)
            origin = CGPoint(x: r.minX, y: content.isFlipped ? r.minY : content.bounds.height - r.maxY)
        }
        pump.setGeometry(points: bounds.size, origin: origin)
    }

    private var onScreen: Bool {
        guard let window else { return false }
        if DesignReview.isOn { return true }
        return window.occlusionState.contains(.visible) && !window.isMiniaturized && !NSApp.isHidden
    }

    /// Decide whether to animate, paint once, or stop.
    func refresh() {
        resizeDrawable()
        let still = reduceMotion || SkyFeed.shared.still
        stillTimer?.invalidate()
        stillTimer = nil
        pump.setActive(onScreen)
        pump.setMotion(!still)
        if !onScreen {
            link?.isPaused = true
        } else if still {
            // A painted sky. The sun still crosses its arc, so it is repainted once a second.
            link?.isPaused = true
            pump.drawSoon()
            stillTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.pump.drawSoon() }
        } else {
            if link == nil {
                // Made here (a display link belongs to a view's screen), run on the drawing thread.
                let l = displayLink(target: pump, selector: #selector(SkyPump.step(_:)))
                pump.schedule(l)
                link = l
            }
            // An even cadence at or under 30: every 2nd refresh at 60 Hz, every 4th at 120 Hz (30 fps), every
            // 3rd at 75 Hz (25 fps). Evenly spaced frames look smoother than a nominal 30 that alternates
            // between short and long gaps.
            let refresh = Double(window?.screen?.maximumFramesPerSecond ?? 60)
            let rate = Float(SkyPacing.rate(refresh: refresh, cap: Double(Self.framesPerSecond)))
            link?.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
            pump.setInterval(1.0 / Double(rate))
            link?.isPaused = false
        }
    }
}

/// Draws the sky on a thread of its own.
final class SkyPump: NSObject, @unchecked Sendable {
    /// Counters for the performance notes.
    final class Stats: @unchecked Sendable {
        private let lock = NSLock()
        private var _frames = 0, _ticks = 0
        private var _worst: CFTimeInterval = 0, last: CFTimeInterval = 0
        var frames: Int { lock.lock(); defer { lock.unlock() }; return _frames }
        var ticks: Int { lock.lock(); defer { lock.unlock() }; return _ticks }
        var worstGap: CFTimeInterval { lock.lock(); defer { lock.unlock() }; return _worst }
        func resetGap() { lock.lock(); _worst = 0; last = 0; lock.unlock() }
        func tick() { lock.lock(); _ticks += 1; lock.unlock() }
        func frame(moving: Bool) {
            let now = CACurrentMediaTime()
            lock.lock()
            _frames += 1
            if moving, last > 0 { _worst = max(_worst, now - last) }
            last = moving ? now : 0
            lock.unlock()
        }
    }
    static let stats = Stats()

    private let layer: CAMetalLayer
    private let lock = NSLock()
    private let drawing = NSLock()
    private var points = CGSize.zero
    private var origin = CGPoint.zero
    private var active = false
    private var motion = true
    private var interval: CFTimeInterval = 1.0 / 30
    private var nextFrameDue: CFTimeInterval = 0
    private let started = CACurrentMediaTime()
    private var thread: Thread?
    private var runLoop: RunLoop?
    private let ready = DispatchSemaphore(value: 0)

    init(layer: CAMetalLayer) {
        self.layer = layer
        super.init()
        let t = Thread { [weak self] in
            // A run loop of its own for the display link; the port keeps it alive between frames.
            let loop = RunLoop.current
            loop.add(Port(), forMode: .default)
            self?.runLoop = loop
            self?.ready.signal()
            while !Thread.current.isCancelled { loop.run(mode: .default, before: Date(timeIntervalSinceNow: 1)) }
        }
        t.name = "SiverSol sky"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        ready.wait()
    }

    func stop() { thread?.cancel() }

    func setGeometry(points: CGSize, origin: CGPoint) { lock.lock(); self.points = points; self.origin = origin; lock.unlock() }
    func setActive(_ on: Bool) { lock.lock(); active = on; lock.unlock() }
    func setMotion(_ on: Bool) { lock.lock(); motion = on; lock.unlock() }
    func setInterval(_ seconds: CFTimeInterval) { lock.lock(); interval = seconds; lock.unlock() }

    /// Run the display link on the drawing thread.
    func schedule(_ link: CADisplayLink) {
        guard let thread else { return }
        perform(#selector(add(_:)), on: thread, with: link, waitUntilDone: false)
    }

    @objc private func add(_ link: CADisplayLink) { link.add(to: .current, forMode: .default) }

    /// One frame as soon as the drawing thread is free (a resize, a still sky that changed).
    func drawSoon() {
        guard let thread else { return }
        perform(#selector(drawOnce), on: thread, with: nil, waitUntilDone: false)
    }

    @objc private func drawOnce() { draw() }

    /// The display link fires here, on the drawing thread. When the system calls at the rate asked for, every
    /// call draws; when it calls faster, calls are skipped so that frames stay evenly spaced.
    @objc func step(_ link: CADisplayLink) {
        Self.stats.tick()
        let now = link.timestamp
        let tick = max(0.001, link.targetTimestamp - link.timestamp)
        lock.lock()
        let due = nextFrameDue, every = interval
        lock.unlock()
        guard now + tick * 0.5 >= due else { return }
        lock.lock(); nextFrameDue = now + every; lock.unlock()
        draw()
    }

    private func draw() {
        lock.lock()
        let size = points, at = origin, on = active, moving = motion
        lock.unlock()
        guard on, size.width > 1, let renderer = SkyMetalView.renderer else { return }
        drawing.lock(); defer { drawing.unlock() }
        guard let scene = SkyFeed.shared.scene(at: Date(), origin: at, motion: moving),
              let drawable = layer.nextDrawable(), let buffer = renderer.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        let pixels = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        renderer.encode(scene, time: CACurrentMediaTime() - started, pixels: pixels, scale: pixels.width / max(1, size.width), pass: pass, into: buffer)
        buffer.present(drawable)
        buffer.commit()
        Self.stats.frame(moving: moving && scene.motion)
    }
}

enum SkyPacing {
    /// The fastest rate at or under `cap` that divides the display's refresh rate evenly.
    static func rate(refresh: Double, cap: Double) -> Double {
        guard refresh > 0 else { return cap }
        let every = max(1, (refresh / (cap + 0.5)).rounded(.up))
        return refresh / every
    }
}

/// Measures how long the main thread ever kept something waiting: a background timer asks the main queue to
/// answer every few milliseconds, and the longest wait for an answer is the longest the window could not
/// react. Used by the design review only.
final class StallMeter: @unchecked Sendable {
    static let shared = StallMeter()
    private let lock = NSLock()
    private var _worst: CFTimeInterval = 0
    private var timer: DispatchSourceTimer?
    private var pending = false

    var worst: CFTimeInterval { lock.lock(); defer { lock.unlock() }; return _worst }
    func reset() { lock.lock(); _worst = 0; lock.unlock() }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "siversol.stall", qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.pending { self.lock.unlock(); return }   // still waiting for the last answer
            self.pending = true
            self.lock.unlock()
            let asked = CACurrentMediaTime()
            DispatchQueue.main.async {
                let waited = CACurrentMediaTime() - asked
                self.lock.lock()
                self._worst = max(self._worst, waited)
                self.pending = false
                self.lock.unlock()
            }
        }
        t.resume()
        timer = t
    }
}
