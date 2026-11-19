import CoreGraphics
import Foundation
import Metal
import SiverCore

/// Everything that decides how one Sol Dex card face looks.
public struct FoilCard: Equatable, Hashable, Sendable {
    public var level: FoilLevel
    public var top: RGB
    public var bottom: RGB
    /// From `SolDex.seed`: picks the emblem and the foil pattern.
    public var seed: UInt32
    public var seen: Bool
    /// Where the pointer is over the card, -1...1 on each axis (0, 0 when it is elsewhere).
    public var tiltX: Double
    public var tiltY: Double
    /// False draws a still face that does not depend on the clock.
    public var animated: Bool

    public init(level: FoilLevel, top: RGB, bottom: RGB, seed: UInt32, seen: Bool = true, tiltX: Double = 0, tiltY: Double = 0, animated: Bool = false) {
        self.level = level; self.top = top; self.bottom = bottom; self.seed = seed; self.seen = seen
        self.tiltX = tiltX; self.tiltY = tiltY; self.animated = animated
    }
}

/// Draws Sol Dex card faces with Metal: still pictures for the grid, live frames for the card under the pointer.
public final class FoilRenderer: @unchecked Sendable {
    struct Uniforms {
        var sizeTime = SIMD4<Float>(repeating: 0)
        var tintA = SIMD4<Float>(repeating: 0)
        var tintB = SIMD4<Float>(repeating: 0)
        var tilt = SIMD4<Float>(repeating: 0)
    }

    public static let pixelFormat = MTLPixelFormat.bgra8Unorm
    public let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let queue: MTLCommandQueue
    public nonisolated(unsafe) static var lastError = ""
    public static let shared = FoilRenderer()

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: FoilShader.source, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "foil_vertex")
            d.fragmentFunction = library.makeFunction(name: "foil_fragment")
            d.colorAttachments[0].pixelFormat = Self.pixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: d)
        } catch {
            Self.lastError = "\(error)"
            return nil
        }
        self.device = device
        self.queue = queue
    }

    static func uniforms(_ c: FoilCard, time: Double, pixels: CGSize, scale: CGFloat) -> Uniforms {
        var u = Uniforms()
        u.sizeTime = SIMD4(Float(pixels.width), Float(pixels.height), Float(time.truncatingRemainder(dividingBy: 3600)), Float(c.level.rawValue))
        u.tintA = SIMD4(Float(c.top.r), Float(c.top.g), Float(c.top.b), c.seen ? 1 : 0)
        u.tintB = SIMD4(Float(c.bottom.r), Float(c.bottom.g), Float(c.bottom.b), Float(c.seed % 100_003) / 100_003)
        u.tilt = SIMD4(Float(c.tiltX), Float(c.tiltY), Float(scale), c.animated ? 1 : 0)
        return u
    }

    public func makeCommandBuffer() -> MTLCommandBuffer? { queue.makeCommandBuffer() }

    public func encode(_ card: FoilCard, time: Double, pixels: CGSize, scale: CGFloat, pass: MTLRenderPassDescriptor, into buffer: MTLCommandBuffer) {
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = Self.uniforms(card, time: time, pixels: pixels, scale: scale)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// A still card face. `size` is in points.
    public func image(_ card: FoilCard, time: Double = 3.7, size: CGSize, scale: CGFloat = 2) -> CGImage? {
        let w = max(1, Int(size.width * scale)), h = max(1, Int(size.height * scale))
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: td), let buffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        encode(card, time: time, pixels: CGSize(width: w, height: h), scale: scale, pass: pass, into: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

extension DexTier {
    /// The colour a tier's cards are tinted with.
    public var color: RGB {
        switch self {
        case .basic: return RGB(hex: 0x8D99AE)
        case .epic: return RGB(hex: 0xA06CD5)
        case .unique: return RGB(hex: 0x3FA7D6)
        case .legendary: return RGB(hex: 0xF5B841)
        case .mythic: return RGB(hex: 0xEF476F)
        case .exalted: return RGB(hex: 0x2EC4B6)
        case .glorious: return RGB(hex: 0xFF7B00)
        case .transcendent: return RGB(hex: 0xC738BD)
        case .dimensional: return RGB(hex: 0x4F6DFF)
        case .challenged: return RGB(hex: 0xE63946)
        case .event: return RGB(hex: 0x57C785)
        case .unobtainable: return RGB(hex: 0x7B8494)
        case .unknown: return RGB(hex: 0x99AAB5)
        }
    }
}
