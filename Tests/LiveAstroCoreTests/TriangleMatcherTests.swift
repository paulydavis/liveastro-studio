import XCTest
@testable import LiveAstroCore

final class TriangleMatcherTests: XCTestCase {
    func stars(_ pts: [(Double, Double)]) -> [Star] {
        pts.enumerated().map { Star(x: $1.0, y: $1.1, flux: Double(100 - $0)) }
    }

    func testExactCorrespondenceUnderSimilarity() {
        let src = stars([(10, 10), (200, 40), (60, 180), (150, 150), (30, 90), (220, 200)])
        let t = SimilarityTransform(scale: 1.01, rotation: 0.04, tx: 12, ty: -7)
        let dst = src.map { s -> Star in
            let p = t.apply(x: s.x, y: s.y); return Star(x: p.x, y: p.y, flux: s.flux)
        }
        let pairs = TriangleMatcher.correspondences(source: src, target: dst)
        XCTAssertGreaterThanOrEqual(pairs.count, 5)
        for p in pairs { XCTAssertEqual(p.source, p.target) }   // same ordering by construction
    }

    func testRobustToSpuriousAndMissingStars() {
        let src = stars([(10, 10), (200, 40), (60, 180), (150, 150), (30, 90), (220, 200), (120, 60)])
        var dstPts: [(Double, Double)] = [(10, 10), (200, 40), (60, 180), (150, 150), (30, 90)]
        dstPts.append((300, 300))   // spurious star not in source
        let dst = stars(dstPts)
        let pairs = TriangleMatcher.correspondences(source: src, target: dst)
        XCTAssertGreaterThanOrEqual(pairs.count, 4)
        for p in pairs where p.target < 5 { XCTAssertEqual(p.source, p.target) }
        XCTAssertFalse(pairs.contains { $0.target == 5 })   // spurious star matched nothing
    }

    func testTooFewStarsReturnsEmpty() {
        XCTAssertTrue(TriangleMatcher.correspondences(
            source: stars([(1, 1), (2, 2)]), target: stars([(1, 1), (2, 2), (3, 1)])).isEmpty)
    }
}
