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
