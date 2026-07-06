import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LiveAstroCore

final class ImageLoaderTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ilt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testLoadsFITSAsLinear() throws {
        let url = tmp.appendingPathComponent("stack.fit")
        try FITSWriter.float32(width: 4, height: 4, channels: 1,
                               pixels: [Float](repeating: 0.25, count: 16)).write(to: url)
        let img = try ImageLoader.load(url: url)
        XCTAssertTrue(img.sourceIsLinear)
        XCTAssertEqual(img.width, 4)
        XCTAssertEqual(img.stats[0].mean, 0.25, accuracy: 1e-4)
    }

    func testLoadsPNGAsDisplayReady() throws {
        let url = tmp.appendingPathComponent("stack.png")
        try writePNG(to: url, gray: 128, width: 8, height: 8)
        let img = try ImageLoader.load(url: url)
        XCTAssertFalse(img.sourceIsLinear)
        XCTAssertEqual(img.channels, 3)
        XCTAssertEqual(img.stats[0].mean, 128.0 / 255.0, accuracy: 0.02)
    }

    func testUnsupportedExtensionThrows() {
        XCTAssertThrowsError(try ImageLoader.load(url: tmp.appendingPathComponent("x.xisf")))
    }

    private func writePNG(to url: URL, gray: UInt8, width: Int, height: Int) throws {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let g = CGFloat(gray) / 255.0
        ctx.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 components: [g, g, g, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }
}
