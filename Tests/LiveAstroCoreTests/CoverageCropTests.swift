import XCTest
@testable import LiveAstroCore

final class CoverageCropTests: XCTestCase {
    // Build a width×height coverage map from a closure.
    private func cov(_ w: Int, _ h: Int, _ f: (Int, Int) -> Float) -> [Float] {
        var a = [Float](repeating: 0, count: w*h)
        for y in 0..<h { for x in 0..<w { a[y*w + x] = f(x, y) } }
        return a
    }

    func testCenteredCoreYieldsInnerRect() {
        // 10x10: coverage 10 in the inner 2..7 box, 1 (low) at the border.
        let w = 10, h = 10
        let c = cov(w, h) { x, y in (x >= 2 && x <= 7 && y >= 2 && y <= 7) ? 10 : 1 }
        let r = CoverageCrop.rect(coverage: c, width: w, height: h)
        XCTAssertEqual(r, CropRect(x0: 2, y0: 2, x1: 7, y1: 7))
    }

    func testUniformCoverageIsFullFrame() {
        let w = 6, h = 5
        let c = cov(w, h) { _, _ in 8 }
        XCTAssertEqual(CoverageCrop.rect(coverage: c, width: w, height: h),
                       CropRect(x0: 0, y0: 0, x1: w-1, y1: h-1))
    }

    func testTaperedCornerExcludesLowCoverageEdges() {
        // left/top few columns/rows are under-covered; inscribed rect starts inside them.
        let w = 12, h = 12
        let c = cov(w, h) { x, y in (x >= 3 && y >= 2) ? 20 : 1 }
        let r = CoverageCrop.rect(coverage: c, width: w, height: h)!
        XCTAssertEqual(r.x0, 3); XCTAssertEqual(r.y0, 2)
        XCTAssertEqual(r.x1, 11); XCTAssertEqual(r.y1, 11)
    }

    func testAllZeroCoverageReturnsNil() {
        XCTAssertNil(CoverageCrop.rect(coverage: [Float](repeating: 0, count: 16), width: 4, height: 4))
    }

    // MARK: - cropToCoverage (shared image-crop util, parity with SessionPipeline.cropToCoverage)

    private func image(_ w: Int, _ h: Int) -> AstroImage {
        AstroImage(width: w, height: h, channels: 1,
                   pixels: (0..<(w*h)).map { Float($0) }, sourceIsLinear: true)
    }

    func testCropToCoverageNilCoverageIsNoOp() {
        let img = image(10, 10)
        let out = CoverageCrop.cropToCoverage(img, coverage: nil)
        XCTAssertEqual(out.width, 10); XCTAssertEqual(out.height, 10)
    }

    func testCropToCoverageFullFrameIsNoOp() {
        // Uniform coverage → full-frame rect → returns the image unchanged.
        let img = image(6, 5)
        let c = cov(6, 5) { _, _ in 8 }
        let out = CoverageCrop.cropToCoverage(img, coverage: c)
        XCTAssertEqual(out.width, 6); XCTAssertEqual(out.height, 5)
    }

    func testCropToCoverageValidRectCrops() {
        // Tapered corner: well-covered region is x>=3, y>=2 in a 12x12 → rect (3,2,11,11) =
        // 9x10 = 90px, 62.5% of the 144px frame (above the 60% keep floor) → crops.
        let w = 12, h = 12
        let img = image(w, h)
        let c = cov(w, h) { x, y in (x >= 3 && y >= 2) ? 20 : 1 }
        let out = CoverageCrop.cropToCoverage(img, coverage: c)
        XCTAssertEqual(out.width, 9); XCTAssertEqual(out.height, 10)   // cols 3...11, rows 2...11
    }

    func testCropToCoverageTooAggressiveKeepsFullFrame() {
        // A tiny 3x3 well-covered core in a 10x10 removes >40% → keep full frame.
        let w = 10, h = 10
        let img = image(w, h)
        let c = cov(w, h) { x, y in (x >= 4 && x <= 6 && y >= 4 && y <= 6) ? 10 : 1 }
        let out = CoverageCrop.cropToCoverage(img, coverage: c)
        XCTAssertEqual(out.width, 10, "cropped area <60% must keep full frame")
        XCTAssertEqual(out.height, 10)
    }
}
