import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LiveAstroCore

final class ReplayGeneratorTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testAspectFit() {
        // Wide image in 16:9 canvas: full width, letterboxed height.
        let r = ReplayGenerator.aspectFitRect(image: CGSize(width: 200, height: 50),
                                              in: CGSize(width: 160, height: 90))
        XCTAssertEqual(r.width, 160, accuracy: 0.01)
        XCTAssertEqual(r.height, 40, accuracy: 0.01)
        XCTAssertEqual(r.midY, 45, accuracy: 0.01)
        // Tall image: full height, pillarboxed.
        let r2 = ReplayGenerator.aspectFitRect(image: CGSize(width: 50, height: 200),
                                               in: CGSize(width: 160, height: 90))
        XCTAssertEqual(r2.height, 90, accuracy: 0.01)
        XCTAssertEqual(r2.midX, 80, accuracy: 0.01)
    }

    func testRendersValidMP4() throws {
        var urls: [URL] = []
        for (i, shade) in [0.1, 0.5, 0.9].enumerated() {
            let url = tmp.appendingPathComponent("kf\(i).png")
            try writePNG(to: url, gray: shade, width: 320, height: 180)
            urls.append(url)
        }
        var settings = ReplaySettings()
        settings.duration = 2; settings.fps = 10
        settings.width = 320; settings.height = 180; settings.crossfade = 0.2
        let out = tmp.appendingPathComponent("replay.mp4")
        try ReplayGenerator(settings: settings).render(
            keyframes: urls.enumerated().map {
                ReplayKeyframe(imageURL: $0.element, caption: "\($0.offset + 1) × 20s")
            }, to: out)

        let asset = AVURLAsset(url: out)
        let exp = expectation(description: "load")
        Task {
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            XCTAssertEqual(CMTimeGetSeconds(duration), 2.0, accuracy: 0.25)
            XCTAssertEqual(tracks.count, 1)
            let size = try await tracks[0].load(.naturalSize)
            XCTAssertEqual(size.width, 320); XCTAssertEqual(size.height, 180)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
    }

    func testEmptyKeyframesThrows() {
        XCTAssertThrowsError(try ReplayGenerator().render(
            keyframes: [], to: tmp.appendingPathComponent("x.mp4")))
    }

    func testNonexistentKeyframeImageThrowsDecodeFailed() {
        let missing = tmp.appendingPathComponent("missing.png")
        XCTAssertThrowsError(try ReplayGenerator().render(
            keyframes: [ReplayKeyframe(imageURL: missing, caption: "x")],
            to: tmp.appendingPathComponent("y.mp4"))) {
            guard case ReplayError.decodeFailed = $0 else {
                return XCTFail("expected decodeFailed, got \($0)")
            }
        }
    }

    func testColorChannelsNotSwapped() throws {
        let url = tmp.appendingPathComponent("red.png")
        try writePNG(to: url, r: 1.0, g: 0.0, b: 0.0, width: 320, height: 180)

        var settings = ReplaySettings()
        settings.duration = 1; settings.fps = 10
        settings.width = 320; settings.height = 180; settings.crossfade = 0.2
        let out = tmp.appendingPathComponent("red-replay.mp4")
        try ReplayGenerator(settings: settings).render(
            keyframes: [ReplayKeyframe(imageURL: url, caption: "Red")],
            to: out)

        let asset = AVURLAsset(url: out)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        // Sample near frame 5 (middle of clip) to stay away from the caption margin.
        let sampleTime = CMTime(value: 5, timescale: 10)
        let cgImage = try gen.copyCGImage(at: sampleTime, actualTime: nil)

        // Draw a centered 64×64 crop (well away from caption at bottom-left) into an
        // RGBA8 sRGB context so we can read raw pixel values.
        let sampleW = 64, sampleH = 64
        let cropX = (cgImage.width - sampleW) / 2
        let cropY = (cgImage.height - sampleH) / 2
        let cropRect = CGRect(x: cropX, y: cropY, width: sampleW, height: sampleH)
        let cropped = cgImage.cropping(to: cropRect)!

        var pixelData = [UInt8](repeating: 0, count: sampleW * sampleH * 4)
        let sampleCtx = CGContext(data: &pixelData,
                                  width: sampleW, height: sampleH,
                                  bitsPerComponent: 8,
                                  bytesPerRow: sampleW * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        sampleCtx.draw(cropped, in: CGRect(x: 0, y: 0, width: sampleW, height: sampleH))

        var sumR: Double = 0, sumB: Double = 0
        let pixelCount = sampleW * sampleH
        for i in 0..<pixelCount {
            sumR += Double(pixelData[i * 4 + 0])
            sumB += Double(pixelData[i * 4 + 2])
        }
        let meanR = sumR / Double(pixelCount)
        let meanB = sumB / Double(pixelCount)
        XCTAssertGreaterThan(meanR, meanB * 3.0,
            "Mean red (\(meanR)) should be > 3× mean blue (\(meanB)); channels may be swapped")
    }

    private func writePNG(to url: URL, gray: Double, width: Int, height: Int) throws {
        try writePNG(to: url, r: gray, g: gray, b: gray, width: width, height: height)
    }

    private func writePNG(to url: URL, r: Double, g: Double, b: Double, width: Int, height: Int) throws {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }
}
