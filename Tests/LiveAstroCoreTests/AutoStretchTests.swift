import XCTest
@testable import LiveAstroCore

final class AutoStretchTests: XCTestCase {
    func testMTFEndpointsAndIdentity() {
        XCTAssertEqual(AutoStretch.mtf(0, 0.3), 0)
        XCTAssertEqual(AutoStretch.mtf(1, 0.3), 1)
        XCTAssertEqual(AutoStretch.mtf(0.42, 0.5), 0.42, accuracy: 1e-9) // m=0.5 is identity
        XCTAssertEqual(AutoStretch.mtf(0.25, 0.25), 0.5, accuracy: 1e-9) // maps m to 0.5? No: MTF(m, m)=0.5
    }

    func testStretchPutsMedianNearTarget() {
        // Skewed dark linear image: background ~0.02 with noise, a few bright pixels.
        var rng = SystemRandomNumberGenerator()
        var px = (0..<10_000).map { _ in Float(0.02 + Double.random(in: -0.005...0.005, using: &rng)) }
        for i in 0..<20 { px[i * 500] = 0.8 }
        let img = AstroImage(width: 100, height: 100, channels: 1, pixels: px, sourceIsLinear: true)
        let out = AutoStretch.stretch(img)
        XCTAssertEqual(out.stats[0].median, 0.25, accuracy: 0.05)
        XCTAssertTrue(out.stats[0].median > img.stats[0].median * 3, "should brighten dramatically")
    }

    func testStretchIsMonotonic() {
        let px: [Float] = [0.0, 0.01, 0.02, 0.05, 0.2, 1.0] + [Float](repeating: 0.02, count: 94)
        let img = AstroImage(width: 10, height: 10, channels: 1, pixels: px, sourceIsLinear: true)
        let out = AutoStretch.stretch(img)
        for i in 1..<6 { XCTAssertGreaterThanOrEqual(out.pixels[i], out.pixels[i - 1]) }
        XCTAssertEqual(out.pixels[5], 1.0, accuracy: 1e-5)
    }

    func testLinkedChannelsPreserveRatios() {
        // Red channel brighter than blue everywhere; after linked stretch red stays >= blue.
        let plane = 100
        var px = [Float](repeating: 0.04, count: plane)        // R
        px += [Float](repeating: 0.02, count: plane)           // G
        px += [Float](repeating: 0.01, count: plane)           // B
        let img = AstroImage(width: 10, height: 10, channels: 3, pixels: px, sourceIsLinear: true)
        let out = AutoStretch.stretch(img)
        XCTAssertGreaterThan(out.pixels[0], out.pixels[plane])       // R > G
        XCTAssertGreaterThan(out.pixels[plane], out.pixels[2*plane]) // G > B
    }

    func testMakeCGImage() {
        let img = AstroImage(width: 4, height: 2, channels: 3,
                             pixels: [Float](repeating: 0.5, count: 24), sourceIsLinear: false)
        let cg = AutoStretch.makeCGImage(img)
        XCTAssertEqual(cg?.width, 4)
        XCTAssertEqual(cg?.height, 2)
    }
}
