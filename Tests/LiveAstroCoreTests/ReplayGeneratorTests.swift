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

    private func writePNG(to url: URL, gray: Double, width: Int, height: Int) throws {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }
}
