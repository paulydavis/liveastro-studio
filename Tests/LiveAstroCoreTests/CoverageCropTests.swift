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
}
