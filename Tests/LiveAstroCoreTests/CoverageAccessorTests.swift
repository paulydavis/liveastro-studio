import XCTest
@testable import LiveAstroCore

final class CoverageAccessorTests: XCTestCase {
    private func img(_ w: Int, _ h: Int, _ v: Float) -> AstroImage {
        AstroImage(width: w, height: h, channels: 1, pixels: [Float](repeating: v, count: w*h), sourceIsLinear: true)
    }

    func testCoverageCountsMaskContributions() {
        let acc = StackAccumulator(width: 2, height: 2, channels: 1)
        acc.add(img(2,2,0.5), mask: [1,1,0,0])
        acc.add(img(2,2,0.5), mask: [1,0,0,0])
        // pixel0 covered twice, pixel1 once, pixels 2&3 never
        XCTAssertEqual(acc.coverage(), [2, 1, 0, 0])
    }

    // Regression (cold-review Critical, 2026-07-12): coverage() must report the
    // GEOMETRIC frame count, never the quality-weighted mean denominator. Two
    // halves covered by the SAME number of frames but very different frame
    // weights must yield uniform coverage, so CoverageCrop keeps the full frame
    // instead of trimming the low-weight half.
    func testCoverageIsFrameCountNotWeightedSum() {
        let w = 8, h = 8
        let acc = StackAccumulator(width: w, height: h, channels: 1)
        func half(left: Bool) -> [Float] {
            (0..<w*h).map { i in ((i % w) < w/2) == left ? 1 : 0 }
        }
        let f = img(w, h, 0.5)
        for _ in 0..<10 { acc.add(f, mask: half(left: true),  frameWeight: 4.0) }
        for _ in 0..<10 { acc.add(f, mask: half(left: false), frameWeight: 0.25) }
        let cov = acc.coverage()
        // every pixel is covered by exactly 10 frames — weight must not leak in
        XCTAssertTrue(cov.allSatisfy { abs($0 - 10) < 1e-4 },
                      "coverage must be frame count 10, got values \(Set(cov.map { ($0*100).rounded()/100 }))")
        // and the crop must therefore keep the whole frame, not trim the low-weight half
        XCTAssertEqual(CoverageCrop.rect(coverage: cov, width: w, height: h),
                       CropRect(x0: 0, y0: 0, x1: w-1, y1: h-1))
    }

    func testCoverageIsACopy_doesNotAffectMean() {
        let acc = StackAccumulator(width: 2, height: 2, channels: 1)
        acc.add(img(2,2,0.4), mask: [1,1,1,1])
        let meanBefore = acc.mean().pixels
        var cov = acc.coverage()
        cov[0] = 999                       // mutate the returned copy
        acc.add(img(2,2,0.6), mask: [1,1,1,1])
        // mean must reflect real accumulation, unaffected by mutating the copy
        let meanAfter = acc.mean().pixels
        XCTAssertEqual(meanBefore, [0.4, 0.4, 0.4, 0.4])
        for (actual, expected) in zip(meanAfter, [0.5, 0.5, 0.5, 0.5]) {
            XCTAssertEqual(Double(actual), Double(expected), accuracy: 1e-6)
        }
    }
}
