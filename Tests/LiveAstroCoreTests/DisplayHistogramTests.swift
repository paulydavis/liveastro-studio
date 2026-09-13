import XCTest
@testable import LiveAstroCore

final class DisplayHistogramTests: XCTestCase {

    private func rendered(_ value: Float, w: Int = 64, h: Int = 64) throws -> CGImage {
        try XCTUnwrap(AutoStretch.makeCGImage(AstroImage(width: w, height: h, channels: 1,
            pixels: [Float](repeating: value, count: w * h), sourceIsLinear: false)))
    }

    /// A flat image puts every sample in ONE bin — the basic sanity that binning works at all.
    func testFlatImageOccupiesASingleBin() throws {
        let counts = DisplayHistogram.of(try rendered(0.5))
        XCTAssertFalse(counts.isEmpty)
        XCTAssertEqual(counts.filter { $0 > 0 }.count, 1, "a constant image has one luminance")
    }

    /// Brighter input must land in a HIGHER bin. Catches an inverted or mis-scaled mapping, which
    /// would draw a histogram that is a mirror image of the truth — worse than none, because it
    /// looks plausible.
    func testBrighterImageLandsInAHigherBin() throws {
        func peak(_ v: Float) throws -> Int {
            let c = DisplayHistogram.of(try rendered(v))
            return c.firstIndex(of: c.max() ?? 0) ?? -1
        }
        let dark = try peak(0.1), mid = try peak(0.5), bright = try peak(0.9)
        XCTAssertLessThan(dark, mid)
        XCTAssertLessThan(mid, bright)
    }

    /// A two-tone image must produce exactly two populated bins, with the counts split as the
    /// pixels are — proving it counts pixels rather than, say, unique values.
    func testCountsReflectPixelPopulations() throws {
        let w = 64, h = 64
        var px = [Float](repeating: 0.2, count: w * h)
        for i in 0..<(w * h / 4) { px[i] = 0.9 }          // a quarter of the frame is bright
        let img = AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: false)
        let counts = DisplayHistogram.of(try XCTUnwrap(AutoStretch.makeCGImage(img)))
        let populated = counts.enumerated().filter { $0.element > 0 }
        XCTAssertEqual(populated.count, 2, "two distinct luminances")
        let total = counts.reduce(0, +)
        let brightShare = Double(populated.last!.element) / Double(total)
        XCTAssertEqual(brightShare, 0.25, accuracy: 0.02, "a quarter of the pixels are bright")
    }
}
