import XCTest
@testable import LiveAstroCore

/// `downsampled` is size-agnostic, so these exercise the logic with small images + a small
/// cap (fast in debug); SnapshotRecorderTests + the import E2E cover the real 26MP→2560 path.
final class AstroImageDownsampleTests: XCTestCase {
    func testCapsLongEdgeAndPreservesConstant() {
        let img = AstroImage(width: 600, height: 400, channels: 3,
                             pixels: [Float](repeating: 0.3, count: 600 * 400 * 3), sourceIsLinear: true)
        let ds = img.downsampled(maxLongEdge: 256)
        XCTAssertEqual(ds.width, 256); XCTAssertEqual(ds.height, 171)   // 256 * 400/600
        XCTAssertEqual(ds.channels, 3)
        XCTAssertEqual(ds.pixels.min()!, 0.3, accuracy: 1e-4)           // constant stays constant
        XCTAssertEqual(ds.pixels.max()!, 0.3, accuracy: 1e-4)
    }

    func testPreservesPerChannelLevels() {
        let w = 600, h = 400, plane = w * h
        var px = [Float](repeating: 0, count: plane * 3)
        for c in 0..<3 { for i in 0..<plane { px[c * plane + i] = Float(c + 1) * 0.2 } }
        let ds = AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
            .downsampled(maxLongEdge: 256)
        let dp = ds.width * ds.height
        for c in 0..<3 {
            let sum = ds.pixels[(c * dp)..<((c + 1) * dp)].reduce(0.0) { $0 + Double($1) }
            XCTAssertEqual(sum / Double(dp), Double(c + 1) * 0.2, accuracy: 1e-3, "channel \(c) preserved")
        }
    }

    func testBelowCapReturnsUnchanged() {
        let img = AstroImage(width: 200, height: 150, channels: 3,
                             pixels: [Float](repeating: 0.1, count: 200 * 150 * 3), sourceIsLinear: true)
        let ds = img.downsampled(maxLongEdge: 256)
        XCTAssertEqual(ds.width, 200); XCTAssertEqual(ds.height, 150)
    }
}
