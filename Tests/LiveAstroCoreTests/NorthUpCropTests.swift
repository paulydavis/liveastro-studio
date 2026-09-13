import XCTest
@testable import LiveAstroCore

/// A north-up rotated frame used to keep the full rotated bounding box, leaving black wedges in
/// the corners. On a broadcast those look like a broken feed, and to anything MEASURING the image
/// they are indistinguishable from crushed shadows — the histogram's clipping indicator counted
/// them as destroyed data and reported "clipped 5.2%" on a frame that clipped nothing.
final class NorthUpCropTests: XCTestCase {

    private func wcs(_ rotation: Double) -> WCS {
        WCS(centerRA: 202.47, centerDec: 47.2, rotationDegrees: rotation,
            pixelScaleArcsec: 2.0, parity: false, inlierCount: 30)
    }

    private func white(_ w: Int, _ h: Int) throws -> CGImage {
        try XCTUnwrap(AutoStretch.makeCGImage(AstroImage(width: w, height: h, channels: 1,
            pixels: [Float](repeating: 1.0, count: w * h), sourceIsLinear: false)))
    }

    /// Counts pixels that are pure black — i.e. rotation padding, since the source is all white.
    private func blackFraction(_ cg: CGImage) -> Double {
        guard let data = cg.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return 1 }
        let bpp = max(1, cg.bitsPerPixel / 8), len = CFDataGetLength(data)
        var black = 0, total = 0
        for y in 0..<cg.height {
            for x in 0..<cg.width {
                let i = y * cg.bytesPerRow + x * bpp
                guard i < len else { continue }
                total += 1
                if p[i] < 8 { black += 1 }
            }
        }
        return total == 0 ? 1 : Double(black) / Double(total)
    }

    /// The case that motivated this: a large rotation (Paul's M51 solves near -95 degrees).
    func testLargeRotationLeavesNoBlackPadding() throws {
        let out = NorthUpRotation.apply(try white(600, 400), wcs: wcs(-95), autoZoom: true)
        XCTAssertLessThan(blackFraction(out), 0.01,
                          "a rotated frame must be cropped to fully-covered pixels — black wedges "
                          + "read as clipped shadows and look like a broken feed on stream")
    }

    /// A 45-degree rotation is the worst case for inscribed area, so it is the sharpest test that
    /// the geometry is right rather than merely generous.
    func testFortyFiveDegreesLeavesNoBlackPadding() throws {
        let out = NorthUpRotation.apply(try white(600, 400), wcs: wcs(45), autoZoom: true)
        XCTAssertLessThan(blackFraction(out), 0.01)
    }

    /// Cropping must not be so aggressive that it throws the image away.
    func testCropKeepsAUsefulPortionOfTheFrame() throws {
        let out = NorthUpRotation.apply(try white(600, 400), wcs: wcs(-95), autoZoom: true)
        XCTAssertGreaterThan(out.width * out.height, (600 * 400) / 4,
                             "the inscribed crop should retain a substantial part of the frame")
    }

    /// Small rotations still take the crop-to-fill path and are unaffected.
    func testSmallRotationStillFillsTheOriginalCanvas() throws {
        let out = NorthUpRotation.apply(try white(600, 400), wcs: wcs(5), autoZoom: true)
        XCTAssertEqual(out.width, 600)
        XCTAssertEqual(out.height, 400)
        XCTAssertLessThan(blackFraction(out), 0.01)
    }
}
