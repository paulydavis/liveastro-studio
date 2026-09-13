import XCTest
@testable import LiveAstroCore

/// spatiallyDistributed picks the star budget across the whole frame instead of the
/// brightest-N globally, so a similarity registration fit is constrained at the corners
/// too (2026-08-16 M63: brightest-60 clustered on the galaxy → field-rotation smear at
/// the corners while the center stayed round).
final class StarDetectorDistributionTests: XCTestCase {

    func testDistributionIncludesCornersBrightestNWouldDrop() {
        // 40 bright stars packed into the top-left cell + one dimmer star in each far corner.
        // Brightest-N (N=20) would keep only the central cluster; distribution must reach corners.
        var stars: [Star] = []
        for i in 0..<40 { stars.append(Star(x: Double(10 + i % 5), y: Double(10 + i / 5), flux: 1000 - Double(i))) }
        let corners = [(1990.0, 10.0), (10.0, 1990.0), (1990.0, 1990.0)]   // TR, BL, BR
        for (x, y) in corners { stars.append(Star(x: x, y: y, flux: 5.0)) }   // dim → last by flux

        let picked = StarDetector.spatiallyDistributed(stars, width: 2000, height: 2000, maxStars: 20)
        XCTAssertEqual(picked.count, 20)
        func has(_ x: Double, _ y: Double) -> Bool {
            for s in picked {
                let dx: Double = s.x - x
                let dy: Double = s.y - y
                if abs(dx) < 1.0 && abs(dy) < 1.0 { return true }
            }
            return false
        }
        for (x, y) in corners {
            XCTAssertTrue(has(x, y), "distributed selection must include the far-corner star at (\(x),\(y))")
        }
    }

    func testFirst20SpanAllQuadrantsWhenEveryBucketOccupied() {
        // One star in each of the 8×8 grid cells over a 2000×2000 frame. The triangle
        // matcher only uses the first maxTriangleStars (20), so a row-major fill would put
        // them all in the top rows. A prefix-balanced (Bayer) order must spread the first 20
        // across all four quadrants.
        let W = 2000, H = 2000, g = 8
        var stars: [Star] = []
        var flux = 1000.0
        for cy in 0..<g { for cx in 0..<g {
            let x = (Double(cx) + 0.5) * Double(W) / Double(g)
            let y = (Double(cy) + 0.5) * Double(H) / Double(g)
            stars.append(Star(x: x, y: y, flux: flux)); flux -= 1.0
        } }
        let picked = StarDetector.spatiallyDistributed(stars, width: W, height: H, maxStars: 60)
        let first20 = picked.prefix(20)
        func quad(_ s: Star) -> Int { (s.x < Double(W)/2 ? 0 : 1) + (s.y < Double(H)/2 ? 0 : 2) }
        let quadrants = Set(first20.map(quad))
        XCTAssertEqual(quadrants, Set([0, 1, 2, 3]),
                       "the first 20 stars (the triangle-matcher budget) must cover all four quadrants, not cluster in one region")
    }

    func testDispersedBucketOrderIsAPermutationOfAllCells() {
        let order = StarDetector.dispersedBucketOrder(8)
        XCTAssertEqual(Set(order), Set(0..<64))
        XCTAssertEqual(order.count, 64)
    }

    func testFewerThanBudgetReturnedWhole() {
        var stars: [Star] = []
        for i in 0..<5 {
            let d = Double(i) * 100.0
            stars.append(Star(x: d, y: d, flux: 100.0 - Double(i)))
        }
        XCTAssertEqual(StarDetector.spatiallyDistributed(stars, width: 1000, height: 1000, maxStars: 60).count, 5)
    }
}
