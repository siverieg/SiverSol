import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit
import SiverCore
import UniformTypeIdentifiers

/// Moments: a short video of the Roblox window, and only that window.
///
/// It uses the Screen Recording permission SiverSol already has. No sound is ever captured. Before a frame is
/// written, the chat and the player list are painted over (the same regions as proof shots), so other players'
/// names are never in the file. The video is HEVC at 720p or smaller with a capped bitrate.
public final class MomentRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public struct Request: Sendable {
        public var windowId: CGWindowID
        public var seconds: Double
        public var bitrate: Int
        public var output: URL
        public var thumbnail: URL?
        /// Regions to paint over, as ratios of the game area (the window without its title bar).
        public var masks: [CGRect]
        public var framesPerSecond: Int
        /// Height of the window's title bar in points. The clip shows the whole window, so the masks are moved
        /// down by this much.
        public var titleBar: CGFloat

        public init(windowId: CGWindowID, seconds: Double, bitrate: Int, output: URL, thumbnail: URL? = nil,
                    masks: [CGRect] = ProofShot.defaultMasks, framesPerSecond: Int = 30, titleBar: CGFloat = 0) {
            self.windowId = windowId; self.seconds = seconds; self.bitrate = bitrate; self.output = output
            self.thumbnail = thumbnail; self.masks = masks; self.framesPerSecond = framesPerSecond; self.titleBar = titleBar
        }
    }

    public struct Result: Sendable {
        public var url: URL
        public var seconds: Double
        public var bytes: Int
        public var frames: Int
        public var width: Int
        public var height: Int
    }

    private let request: Request
    private let queue = DispatchQueue(label: "siversol.moments")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var firstTime: CMTime?
    private var lastSeconds = 0.0
    private var frames = 0
    private var size = (width: 1280, height: 720)
    private var masks: [CGRect] = []
    private var finished = false
    private var thumbnailDone = false
    private var continuation: CheckedContinuation<Result, Error>?

    private init(_ request: Request) { self.request = request }

    /// Record one clip. Returns when the file is closed.
    public static func record(_ request: Request) async throws -> Result {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.noPermission }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw CaptureError.failed(error.localizedDescription) }
        guard let window = content.windows.first(where: { $0.windowID == request.windowId }) else { throw CaptureError.windowNotFound(request.windowId) }
        let recorder = MomentRecorder(request)
        return try await recorder.run(window)
    }

    private func run(_ window: SCWindow) async throws -> Result {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        size = MomentsStore.videoSize(windowPixels: CGSize(width: window.frame.width * scale, height: window.frame.height * scale))
        let frame = GameFrame(window: CGRect(origin: .zero, size: window.frame.size), titleBar: request.titleBar)
        masks = request.masks.map(frame.windowRegion(fromContent:))

        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(request.framesPerSecond))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true
        config.queueDepth = 5

        try? FileManager.default.removeItem(at: request.output)
        let writer = try AVAssetWriter(outputURL: request.output, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: request.bitrate,
                AVVideoExpectedSourceFrameRateKey: request.framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: request.framesPerSecond * 2,
            ] as [String: Any],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
        ])
        guard writer.canAdd(input) else { throw CaptureError.failed("this Mac cannot write HEVC video") }
        writer.add(input)
        guard writer.startWriting() else { throw CaptureError.failed(writer.error?.localizedDescription ?? "could not start the video file") }
        self.writer = writer; self.input = input; self.adaptor = adaptor

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream

        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Result, Error>) in
            queue.async { self.continuation = c }
            stream.startCapture { error in
                if let error { self.queue.async { self.finish(error: CaptureError.failed(error.localizedDescription)) } }
            }
            // Whatever happens to the frames, the clip ends: a window that stops drawing must not hold the file open.
            queue.asyncAfter(deadline: .now() + request.seconds + 3) { self.finish(error: nil) }
        }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !finished, sample.isValid, let source = sample.imageBuffer else { return }
        // Only complete frames; an idle or blank frame carries no new picture.
        if let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
           let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw), status != .complete { return }
        guard let writer, let input, let adaptor else { return }
        let time = sample.presentationTimeStamp
        if firstTime == nil {
            firstTime = time
            writer.startSession(atSourceTime: .zero)
        }
        let at = CMTimeSubtract(time, firstTime!)
        let seconds = at.seconds
        if seconds >= request.seconds { finish(error: nil); return }
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return }
        Self.copyMasked(from: source, to: out, masks: masks)
        if adaptor.append(out, withPresentationTime: at) {
            frames += 1
            lastSeconds = seconds
        }
        if !thumbnailDone, let url = request.thumbnail, seconds >= min(1.0, request.seconds * 0.3) {
            thumbnailDone = true
            Self.writeJPEG(out, to: url)
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.finish(error: self.frames > 0 ? nil : CaptureError.failed(error.localizedDescription)) }
    }

    /// Called on `queue`. Closes the file once and answers the caller once.
    private func finish(error: Error?) {
        guard !finished else { return }
        finished = true
        let stream = self.stream
        self.stream = nil
        stream?.stopCapture { _ in }
        guard let writer, let input else { continuation?.resume(throwing: error ?? CaptureError.failed("no writer")); continuation = nil; return }
        let c = continuation
        continuation = nil
        if frames == 0 || error != nil {
            input.markAsFinished()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: request.output)
            c?.resume(throwing: error ?? CaptureError.failed("no picture arrived from the Roblox window (is the display asleep?)"))
            return
        }
        input.markAsFinished()
        let url = request.output, frames = self.frames, seconds = lastSeconds, size = self.size
        writer.finishWriting {
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
            if writer.status == .completed {
                c?.resume(returning: Result(url: url, seconds: seconds, bytes: bytes, frames: frames, width: size.width, height: size.height))
            } else {
                c?.resume(throwing: CaptureError.failed(writer.error?.localizedDescription ?? "the video file could not be finished"))
            }
        }
    }

    /// Copy a frame and paint the masked regions (ratios of the picture, top-left origin) a solid dark colour.
    static func copyMasked(from source: CVPixelBuffer, to out: CVPixelBuffer, masks: [CGRect]) {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []); CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard let src = CVPixelBufferGetBaseAddress(source), let dst = CVPixelBufferGetBaseAddress(out) else { return }
        let w = min(CVPixelBufferGetWidth(source), CVPixelBufferGetWidth(out)), h = min(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(out))
        let srcRow = CVPixelBufferGetBytesPerRow(source), dstRow = CVPixelBufferGetBytesPerRow(out)
        for y in 0..<h { memcpy(dst + y * dstRow, src + y * srcRow, w * 4) }
        var fill: UInt32 = 0xFF12_141A   // BGRA in memory: a dark blue-grey, fully opaque
        for m in masks {
            let x0 = max(0, Int(m.minX * CGFloat(w))), x1 = min(w, Int((m.maxX * CGFloat(w)).rounded(.up)))
            let y0 = max(0, Int(m.minY * CGFloat(h))), y1 = min(h, Int((m.maxY * CGFloat(h)).rounded(.up)))
            guard x1 > x0, y1 > y0 else { continue }
            for y in y0..<y1 {
                let row = (dst + y * dstRow + x0 * 4).assumingMemoryBound(to: UInt32.self)
                for x in 0..<(x1 - x0) { row[x] = fill }
            }
        }
        _ = fill
    }

    static func writeJPEG(_ buffer: CVPixelBuffer, to url: URL) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let ctx = CGContext(data: base, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer), bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space, bitmapInfo: info),
              let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}
