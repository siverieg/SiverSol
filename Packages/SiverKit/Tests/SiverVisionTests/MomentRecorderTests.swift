import CoreVideo
import XCTest
@testable import SiverVision

final class MomentRecorderTests: XCTestCase {
    private func buffer(_ w: Int, _ h: Int, fill: UInt32) -> CVPixelBuffer {
        var b: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &b)
        CVPixelBufferLockBaseAddress(b!, [])
        let base = CVPixelBufferGetBaseAddress(b!)!, row = CVPixelBufferGetBytesPerRow(b!)
        for y in 0..<h { let p = (base + y * row).assumingMemoryBound(to: UInt32.self); for x in 0..<w { p[x] = fill } }
        CVPixelBufferUnlockBaseAddress(b!, [])
        return b!
    }

    private func pixel(_ b: CVPixelBuffer, _ x: Int, _ y: Int) -> UInt32 {
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        return (CVPixelBufferGetBaseAddress(b)! + y * CVPixelBufferGetBytesPerRow(b)).assumingMemoryBound(to: UInt32.self)[x]
    }

    /// Every frame of a clip has the chat and the player list painted over, like a proof shot.
    func testFramesAreMaskedLikeProofShots() {
        let white: UInt32 = 0xFFFF_FFFF
        let source = buffer(200, 100, fill: white), out = buffer(200, 100, fill: 0)
        MomentRecorder.copyMasked(from: source, to: out, masks: ProofShot.defaultMasks)
        // Inside the chat region (left side, a tenth to two thirds of the way down).
        XCTAssertNotEqual(pixel(out, 20, 30), white)
        XCTAssertEqual(pixel(out, 20, 30), 0xFF12_141A)
        // Inside the player list (top right).
        XCTAssertNotEqual(pixel(out, 180, 8), white)
        // The middle of the picture is untouched.
        XCTAssertEqual(pixel(out, 120, 50), white)
        XCTAssertEqual(pixel(out, 199, 99), white)
    }

    func testAMaskLargerThanThePictureIsClamped() {
        let source = buffer(40, 20, fill: 0xFFFF_FFFF), out = buffer(40, 20, fill: 0)
        MomentRecorder.copyMasked(from: source, to: out, masks: [CGRect(x: -1, y: -1, width: 3, height: 3)])
        XCTAssertEqual(pixel(out, 0, 0), 0xFF12_141A)
        XCTAssertEqual(pixel(out, 39, 19), 0xFF12_141A)
    }
}
