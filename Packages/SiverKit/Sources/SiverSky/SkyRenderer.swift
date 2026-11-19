import CoreGraphics
import Foundation
import Metal
import SiverCore

/// The arc the sun or moon travels in the Dashboard's hero: a shallow piece of a circle, in points.
public struct SkyArc: Equatable, Sendable {
    public var center: CGPoint
    public var radius: CGFloat
    /// Half the angle the arc spans, in radians, measured from straight up.
    public var halfAngle: CGFloat

    public init(center: CGPoint, radius: CGFloat, halfAngle: CGFloat) {
        self.center = center; self.radius = radius; self.halfAngle = halfAngle
    }

    /// The arc that starts at the bottom-left of `rect`, peaks at its top centre and ends at the bottom-right.
    public static func fitting(_ rect: CGRect) -> SkyArc? {
        let a = rect.width / 2, s = rect.height
        guard a > 20, s > 10 else { return nil }
        let r = (a * a + s * s) / (2 * s)
        return SkyArc(center: CGPoint(x: rect.midX, y: rect.minY + r), radius: r, halfAngle: asin(min(1, a / r)))
    }

    /// The point at `progress` (0 = left end, 1 = right end).
    public func point(_ progress: Double) -> CGPoint {
        let angle = (2 * CGFloat(progress) - 1) * halfAngle
        return CGPoint(x: center.x + radius * sin(angle), y: center.y - radius * cos(angle))
    }
}

public enum SkyBody: Int, Sendable { case none = 0, sun, moon, marker }

/// Everything that decides one frame of the sky, apart from the clock.
public struct SkyScene: Equatable, Sendable {
    /// The sky being left behind, and how far the change has come (0 = still the old sky, 1 = the new one).
    public var from: SkyLook
    public var to: SkyLook
    public var mix: Double
    public var arc: SkyArc?
    public var body: SkyBody
    public var bodyProgress: Double
    public var bodyRadius: Double
    public var rare: Bool
    /// 0...1 while the ring that greets a rare biome is spreading; nil otherwise.
    public var shock: Double?
    /// False draws the still, painted sky: no particles, nothing moving.
    public var motion: Bool
    /// Rare sky surprises. `.none` (the default) draws exactly the ordinary sky; only the app's window ever
    /// sets anything else, so no picture made for Discord can carry one.
    public var eggs = EggSky.none

    public init(look: SkyLook, motion: Bool = true) {
        from = look; to = look; mix = 1; arc = nil; body = .none; bodyProgress = 0.5; bodyRadius = 13
        rare = false; shock = nil; self.motion = motion
    }
}

/// Draws the Living Sky with Metal. One instance serves the window, the Biome Island and still pictures.
public final class SkyRenderer: @unchecked Sendable {
    struct Uniforms {
        var sizeTime = SIMD4<Float>(repeating: 0)
        var topA = SIMD4<Float>(repeating: 0), botA = SIMD4<Float>(repeating: 0)
        var topB = SIMD4<Float>(repeating: 0), botB = SIMD4<Float>(repeating: 0)
        var accA = SIMD4<Float>(repeating: 0), accB = SIMD4<Float>(repeating: 0)
        var parA = SIMD4<Float>(repeating: 0), parB = SIMD4<Float>(repeating: 0)
        var misc = SIMD4<Float>(repeating: 0)
        var arc = SIMD4<Float>(repeating: 0)
        var body = SIMD4<Float>(repeating: 0)
        var fx = SIMD4<Float>(repeating: 0)
        var ink = SIMD4<Float>(repeating: 0)
        var eggA = SIMD4<Float>(-1, 0, 0, 0)
        var eggB = SIMD4<Float>(0, 0, 0, -1)
    }

    public static let pixelFormat = MTLPixelFormat.bgra8Unorm
    public let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let queue: MTLCommandQueue

    /// Nil when this Mac has no Metal device or the shader does not compile; callers fall back to a plain gradient.
    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: SkyShader.source, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "sky_vertex")
            d.fragmentFunction = library.makeFunction(name: "sky_fragment")
            d.colorAttachments[0].pixelFormat = Self.pixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: d)
        } catch {
            Self.lastError = "\(error)"
            return nil
        }
        self.device = device
        self.queue = queue
    }

    /// One renderer for the whole process (compiling the shader takes a moment). Nil without Metal.
    public static let shared = SkyRenderer()

    /// Why the last `init` failed, for the command-line tool and tests.
    public nonisolated(unsafe) static var lastError = ""

    private static func v(_ c: RGB) -> SIMD4<Float> { SIMD4(Float(c.r), Float(c.g), Float(c.b), 1) }

    static func uniforms(_ s: SkyScene, time: Double, pixels: CGSize, scale: CGFloat) -> Uniforms {
        var u = Uniforms()
        // Time is wrapped so the shader's 32-bit floats keep their precision however long the app runs.
        u.sizeTime = SIMD4(Float(pixels.width), Float(pixels.height), Float(time.truncatingRemainder(dividingBy: 3600)), Float(min(1, max(0, s.mix))))
        u.topA = v(s.from.top); u.botA = v(s.from.bottom); u.topB = v(s.to.top); u.botB = v(s.to.bottom)
        u.accA = v(s.from.accent); u.accB = v(s.to.accent); u.parA = v(s.from.particle); u.parB = v(s.to.particle)
        let night = s.from.night + (s.to.night - s.from.night) * s.mix
        u.misc = SIMD4(Float(s.from.weather.index), Float(s.to.weather.index), Float(night), s.motion ? 1 : 0)
        if let a = s.arc {
            u.arc = SIMD4(Float(a.center.x), Float(a.center.y), Float(a.radius), Float(a.halfAngle))
        }
        u.body = SIMD4(Float(s.bodyProgress), Float(s.body.rawValue), Float(s.bodyRadius), s.rare ? 1 : 0)
        u.fx = SIMD4(Float(s.shock ?? -1), Float(scale), 0, 0)
        u.ink = v(s.to.ink)
        let e = s.eggs
        u.eggA = SIMD4(Float(e.star ?? -1), Float(e.rainbow), Float(e.aurora), Float(e.retro))
        u.eggB = SIMD4(Float(e.gold), Float(e.twinMoon), Float(e.bats), Float(e.fireworks ?? -1))
        return u
    }

    /// Draw one frame into a render pass (the window's view calls this with its drawable).
    public func encode(_ scene: SkyScene, time: Double, pixels: CGSize, scale: CGFloat, pass: MTLRenderPassDescriptor, into buffer: MTLCommandBuffer) {
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = Self.uniforms(scene, time: time, pixels: pixels, scale: scale)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    public func makeCommandBuffer() -> MTLCommandBuffer? { queue.makeCommandBuffer() }

    /// A still picture of the sky. `size` is in points; the picture has `size × scale` pixels.
    public func image(_ scene: SkyScene, time: Double = 12.34, size: CGSize, scale: CGFloat = 2) -> CGImage? {
        let w = max(1, Int(size.width * scale)), h = max(1, Int(size.height * scale))
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: td), let buffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        encode(scene, time: time, pixels: CGSize(width: w, height: h), scale: scale, pass: pass, into: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
