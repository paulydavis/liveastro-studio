import XCTest
@testable import LiveAstroCore

final class DebayerTests: XCTestCase {
    func testPatternParse() {
        XCTAssertEqual(BayerPattern(headerValue: " grbg "), .grbg)
        XCTAssertEqual(BayerPattern(headerValue: "RGGB"), .rggb)
        XCTAssertNil(BayerPattern(headerValue: "XTRANS"))
        XCTAssertNil(BayerPattern(headerValue: nil))
    }

    func testConstantCFAGivesConstantRGB() {
        let cfa = AstroImage(width: 6, height: 6, channels: 1,
                             pixels: [Float](repeating: 0.25, count: 36), sourceIsLinear: true)
        let rgb = Debayer.bilinear(cfa: cfa, pattern: .grbg)
        XCTAssertEqual(rgb.channels, 3)
        XCTAssertEqual(rgb.width, 6); XCTAssertEqual(rgb.height, 6)
        for v in rgb.pixels { XCTAssertEqual(v, 0.25, accuracy: 1e-6) }
    }

    func testGRBGSiteValuesPreserved() {
        // 4x4 CFA: distinct per-channel constants — R=0.8, G=0.4, B=0.2
        // GRBG rows: [G R G R], [B G B G], ...
        var px = [Float](repeating: 0, count: 16)
        for y in 0..<4 { for x in 0..<4 {
            let isR = (y % 2 == 0 && x % 2 == 1)
            let isB = (y % 2 == 1 && x % 2 == 0)
            px[y * 4 + x] = isR ? 0.8 : (isB ? 0.2 : 0.4)
        }}
        let rgb = Debayer.bilinear(cfa: AstroImage(width: 4, height: 4, channels: 1,
                                                   pixels: px, sourceIsLinear: true), pattern: .grbg)
        let plane = 16
        // Every output pixel of each channel equals that channel's constant
        for i in 0..<plane {
            XCTAssertEqual(rgb.pixels[i], 0.8, accuracy: 1e-5)             // R
            XCTAssertEqual(rgb.pixels[plane + i], 0.4, accuracy: 1e-5)     // G
            XCTAssertEqual(rgb.pixels[2 * plane + i], 0.2, accuracy: 1e-5) // B
        }
    }

    func testRGGBPhase() {
        // Single bright red site at (0,0) under RGGB — R channel peaks there
        var px = [Float](repeating: 0, count: 16)
        px[0] = 1.0
        let rgb = Debayer.bilinear(cfa: AstroImage(width: 4, height: 4, channels: 1,
                                                   pixels: px, sourceIsLinear: true), pattern: .rggb)
        XCTAssertEqual(rgb.pixels[0], 1.0, accuracy: 1e-5)      // R at its own site
        XCTAssertEqual(rgb.pixels[16], 0.0, accuracy: 1e-5)     // G(0,0) interpolates zero neighbors
    }
}
