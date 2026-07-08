import XCTest
@testable import LiveAstroCore

final class SimilarityTransformTests: XCTestCase {
    func testApplyKnownTransform() {
        // 90° rotation, scale 2, translate (10, -5): (1,0) -> s·(0,1) + t = (10, -3)
        let t = SimilarityTransform(scale: 2, rotation: .pi / 2, tx: 10, ty: -5)
        let p = t.apply(x: 1, y: 0)
        XCTAssertEqual(p.x, 10, accuracy: 1e-12)
        XCTAssertEqual(p.y, -3, accuracy: 1e-12)
    }

    func testInverseRoundTrip() {
        let t = SimilarityTransform(scale: 1.02, rotation: 0.03, tx: 14.5, ty: -8.25)
        let inv = t.inverse()
        for (x, y) in [(0.0, 0.0), (100.0, 50.0), (-3.5, 999.0)] {
            let q = t.apply(x: x, y: y)
            let back = inv.apply(x: q.x, y: q.y)
            XCTAssertEqual(back.x, x, accuracy: 1e-9)
            XCTAssertEqual(back.y, y, accuracy: 1e-9)
        }
    }

    func testLiftExactness() {
        // Half-res point p maps to q; full-res point (2p+0.5) must map to (2q+0.5).
        let t = SimilarityTransform(scale: 0.998, rotation: 0.05, tx: 3.2, ty: -1.7)
        let lifted = t.liftedToFullResolution()
        for (x, y) in [(10.0, 20.0), (500.25, 301.5)] {
            let q = t.apply(x: x, y: y)
            let full = lifted.apply(x: 2 * x + 0.5, y: 2 * y + 0.5)
            XCTAssertEqual(full.x, 2 * q.x + 0.5, accuracy: 1e-9)
            XCTAssertEqual(full.y, 2 * q.y + 0.5, accuracy: 1e-9)
        }
    }
}
