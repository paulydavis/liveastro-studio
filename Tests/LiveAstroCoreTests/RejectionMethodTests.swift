import XCTest
@testable import LiveAstroCore

final class RejectionMethodTests: XCTestCase {
    func img(_ px: [Float], w: Int = 2, h: Int = 1, c: Int = 1) -> AstroImage {
        AstroImage(width: w, height: h, channels: c, pixels: px, sourceIsLinear: true)
    }

    func testNoRejectionIsIdentity() {
        let f = img([0.1, 0.9])                     // 0.9 would be an outlier, but NoRejection keeps it
        let out = NoRejection().apply(f, mask: [1, 1])
        XCTAssertEqual(out.pixels, [0.1, 0.9])
    }

    func testNoRejectionResetIsNoOp() {
        let r = NoRejection(); r.reset()            // must not crash
        XCTAssertEqual(r.apply(img([0.2, 0.3]), mask: [1, 1]).pixels, [0.2, 0.3])
    }

    func testStrengthKappaMapping() {
        XCTAssertEqual(RejectionStrength.low.kappa, 3.5)
        XCTAssertEqual(RejectionStrength.medium.kappa, 3.0)
        XCTAssertEqual(RejectionStrength.high.kappa, 2.5)
        XCTAssertEqual(RejectionStrength.allCases.count, 3)
    }
}
