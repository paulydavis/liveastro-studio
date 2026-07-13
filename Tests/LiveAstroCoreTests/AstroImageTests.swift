import XCTest
@testable import LiveAstroCore

final class AstroImageTests: XCTestCase {
    func testStatsUniform() {
        let img = AstroImage(width: 10, height: 10, channels: 1,
                             pixels: [Float](repeating: 0.5, count: 100), sourceIsLinear: true)
        XCTAssertEqual(img.stats[0].mean, 0.5, accuracy: 1e-6)
        XCTAssertEqual(img.stats[0].median, 0.5, accuracy: 1e-6)
        XCTAssertEqual(img.stats[0].stddev, 0.0, accuracy: 1e-6)
    }
    func testStatsPerChannel() {
        var px = [Float](repeating: 0.1, count: 4)   // channel 0
        px += [Float](repeating: 0.9, count: 4)       // channel 1
        px += [Float](repeating: 0.5, count: 4)       // channel 2
        let img = AstroImage(width: 2, height: 2, channels: 3, pixels: px, sourceIsLinear: true)
        XCTAssertEqual(img.stats[0].mean, 0.1, accuracy: 1e-6)
        XCTAssertEqual(img.stats[1].mean, 0.9, accuracy: 1e-6)
        XCTAssertEqual(img.stats[2].mean, 0.5, accuracy: 1e-6)
    }
    func testMedianOddSpread() {
        let img = AstroImage(width: 5, height: 1, channels: 1,
                             pixels: [0.0, 0.1, 0.2, 0.9, 1.0], sourceIsLinear: true)
        XCTAssertEqual(img.stats[0].median, 0.2, accuracy: 1e-6)
    }
    func testMedianEvenLength() {
        let img = AstroImage(width: 4, height: 1, channels: 1,
                             pixels: [0.0, 0.2, 0.8, 1.0], sourceIsLinear: true)
        XCTAssertEqual(img.stats[0].median, 0.5, accuracy: 1e-6)
    }
    // Regression (cold-review Critical, 2026-07-12): a zero-pixel plane has no
    // samples; computeStats' median indexing used to trap. It now returns neutral
    // stats so a degenerate image constructed via the public init cannot crash.
    func testZeroPixelImageYieldsNeutralStatsNoCrash() {
        let img = AstroImage(width: 0, height: 0, channels: 1, pixels: [], sourceIsLinear: true)
        XCTAssertEqual(img.stats.count, 1)
        XCTAssertEqual(img.stats[0], ChannelStats(mean: 0, median: 0, stddev: 0))
    }
}
