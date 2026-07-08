import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import AppKit // NSAttributedString text drawing only — no UI

public struct ReplaySettings {
    // 45 s coincides with FrameSelector.defaultMaxKeyframes but is an
    // independent knob (seconds of video, not a frame count).
    public var duration: Double = 45
    public var fps: Int = 30
    public var width: Int = 1920
    public var height: Int = 1080
    public var crossfade: Double = 0.5
    public init() {}
}

public struct ReplayKeyframe {
    public let imageURL: URL
    public let caption: String
    public init(imageURL: URL, caption: String) {
        self.imageURL = imageURL; self.caption = caption
    }
}

public enum ReplayError: Error {
    case noKeyframes
    case decodeFailed(String)
    case writerFailed(String)
}

public final class ReplayGenerator {
    private let settings: ReplaySettings

    public init(settings: ReplaySettings = .init()) { self.settings = settings }

    public static func aspectFitRect(image: CGSize, in canvas: CGSize) -> CGRect {
        let scale = min(canvas.width / image.width, canvas.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (canvas.width - size.width) / 2,
                      y: (canvas.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    public func render(keyframes: [ReplayKeyframe], to outputURL: URL) throws {
        guard !keyframes.isEmpty else { throw ReplayError.noKeyframes }
        try? FileManager.default.removeItem(at: outputURL)

        let images: [CGImage] = try keyframes.map {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(settings.width, settings.height),
            ]
            guard let src = CGImageSourceCreateWithURL($0.imageURL as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
                throw ReplayError.decodeFailed($0.imageURL.lastPathComponent)
            }
            return cg
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: settings.width,
            AVVideoHeightKey: settings.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: settings.width,
                kCVPixelBufferHeightKey as String: settings.height,
            ])
        writer.add(input)
        guard writer.startWriting() else {
            throw ReplayError.writerFailed(writer.error?.localizedDescription ?? "startWriting")
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = max(1, Int(settings.duration * Double(settings.fps)))
        let segSeconds = settings.duration / Double(keyframes.count)
        let fadeStartFraction = max(0, 1 - settings.crossfade / segSeconds)

        for f in 0..<totalFrames {
            let pos = Double(f) / Double(totalFrames) * Double(keyframes.count)
            let i = min(Int(pos), keyframes.count - 1)
            let frac = pos - Double(i)
            let j = min(i + 1, keyframes.count - 1)
            let blend = (i == j || frac < fadeStartFraction)
                ? 0.0 : (frac - fadeStartFraction) / max(1e-9, 1 - fadeStartFraction)
            let caption = blend < 0.5 ? keyframes[i].caption : keyframes[j].caption
            let buffer = try makeFrame(base: images[i], next: images[j],
                                       blend: blend, caption: caption, pool: adaptor.pixelBufferPool)
            // Encoder back-pressure spin: when/why the encoder stalls is unspecified
            // by AVFoundation, so this loop can't be exercised deterministically.
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else {
                    throw ReplayError.writerFailed(writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)")
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
            let appended = adaptor.append(buffer, withPresentationTime:
                CMTime(value: CMTimeValue(f), timescale: CMTimeScale(settings.fps)))
            if !appended {
                throw ReplayError.writerFailed(writer.error?.localizedDescription ?? "pixel buffer append failed at frame \(f)")
            }
        }

        input.markAsFinished()
        // AVFoundation contract: finishWriting completes asynchronously; block until
        // its callback so the file is fully written before we return.
        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting { sema.signal() }
        sema.wait()
        guard writer.status == .completed else {
            throw ReplayError.writerFailed(writer.error?.localizedDescription ?? "\(writer.status)")
        }
    }

    private func makeFrame(base: CGImage, next: CGImage, blend: Double,
                           caption: String, pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) }
        if pixelBuffer == nil {
            CVPixelBufferCreate(nil, settings.width, settings.height, kCVPixelFormatType_32ARGB,
                                [kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
                                &pixelBuffer)
        }
        // Both pool and direct allocation failing happens only under memory pressure.
        guard let buffer = pixelBuffer else { throw ReplayError.writerFailed("pixel buffer") }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                  width: settings.width, height: settings.height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue) else {
            throw ReplayError.writerFailed("frame context")
        }
        let canvas = CGSize(width: settings.width, height: settings.height)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: canvas))

        let baseRect = Self.aspectFitRect(
            image: CGSize(width: base.width, height: base.height), in: canvas)
        ctx.draw(base, in: baseRect)
        if blend > 0 {
            let nextRect = Self.aspectFitRect(
                image: CGSize(width: next.width, height: next.height), in: canvas)
            ctx.setAlpha(CGFloat(blend))
            ctx.draw(next, in: nextRect)
            ctx.setAlpha(1)
        }

        // Caption bottom-left, safe margin, scaled to canvas height.
        let fontSize = CGFloat(settings.height) * 0.040
        let margin = CGFloat(settings.height) * 0.045
        let attr = NSAttributedString(string: caption, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ])
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        attr.draw(at: NSPoint(x: margin, y: margin))
        NSGraphicsContext.restoreGraphicsState()

        return buffer
    }
}
