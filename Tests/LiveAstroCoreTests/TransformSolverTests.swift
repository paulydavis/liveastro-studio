import XCTest
@testable import LiveAstroCore

final class TransformSolverTests: XCTestCase {
    let truth = SimilarityTransform(scale: 1.003, rotation: 0.021, tx: 8.4, ty: -3.9)

    func makePairs(n: Int, outliers: Int = 0) -> (src: [Star], dst: [Star], pairs: [(source: Int, target: Int)]) {
        var seed: UInt64 = 42
        func rand() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(UInt32.max)
        }
        var src: [Star] = [], dst: [Star] = [], pairs: [(source: Int, target: Int)] = []
        for i in 0..<n {
            let x = rand() * 900, y = rand() * 500
            src.append(Star(x: x, y: y, flux: 1))
            let q = truth.apply(x: x, y: y)
            let isOutlier = i < outliers
            dst.append(Star(x: q.x + (isOutlier ? 80 + rand() * 50 : (rand() - 0.5) * 0.6),
                            y: q.y + (isOutlier ? -60 - rand() * 40 : (rand() - 0.5) * 0.6), flux: 1))
            pairs.append((source: i, target: i))
        }
        return (src, dst, pairs)
    }

    func testExactRecoveryFromCleanPairs() throws {
        let (src, dst, pairs) = makePairs(n: 20)
        let t = try XCTUnwrap(TransformSolver.solve(source: src, target: dst, pairs: pairs))
        XCTAssertEqual(t.rotation, truth.rotation, accuracy: 0.1 * .pi / 180)   // 0.1°
        XCTAssertEqual(t.scale, truth.scale, accuracy: 1e-3)
        XCTAssertEqual(t.tx, truth.tx, accuracy: 0.5)
        XCTAssertEqual(t.ty, truth.ty, accuracy: 0.5)
    }

    func testRobustToThirtyPercentOutliers() throws {
        let (src, dst, pairs) = makePairs(n: 20, outliers: 6)
        let t = try XCTUnwrap(TransformSolver.solve(source: src, target: dst, pairs: pairs))
        XCTAssertEqual(t.rotation, truth.rotation, accuracy: 0.1 * .pi / 180)
        XCTAssertEqual(t.tx, truth.tx, accuracy: 0.5)
    }

    func testNilWhenTooFewInliers() {
        let (src, dst, pairs) = makePairs(n: 7)   // 7 < minMatches 8
        XCTAssertNil(TransformSolver.solve(source: src, target: dst, pairs: pairs))
    }

    func testDeterministic() {
        let (src, dst, pairs) = makePairs(n: 20, outliers: 4)
        let a = TransformSolver.solve(source: src, target: dst, pairs: pairs)
        let b = TransformSolver.solve(source: src, target: dst, pairs: pairs)
        XCTAssertEqual(a, b)
    }
}
