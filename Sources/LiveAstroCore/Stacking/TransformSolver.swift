import Foundation

/// RANSAC similarity-transform estimation over matched star pairs (spec §4.2).
public enum TransformSolver {
    /// Closed-form least-squares similarity fit (Umeyama) over the given pair indices.
    static func fit(source: [Star], target: [Star],
                    pairs: ArraySlice<(source: Int, target: Int)>) -> SimilarityTransform? {
        let n = Double(pairs.count)
        guard pairs.count >= 2 else { return nil }
        var pcx = 0.0, pcy = 0.0, qcx = 0.0, qcy = 0.0
        for pr in pairs {
            pcx += source[pr.source].x; pcy += source[pr.source].y
            qcx += target[pr.target].x; qcy += target[pr.target].y
        }
        pcx /= n; pcy /= n; qcx /= n; qcy /= n
        var a = 0.0, b = 0.0, d = 0.0
        for pr in pairs {
            let x = source[pr.source].x - pcx, y = source[pr.source].y - pcy
            let u = target[pr.target].x - qcx, v = target[pr.target].y - qcy
            a += x * u + y * v
            b += x * v - y * u
            d += x * x + y * y
        }
        guard d > 1e-9 else { return nil }
        let scale = (a * a + b * b).squareRoot() / d
        guard scale > 1e-6 else { return nil }
        let rotation = atan2(b, a)
        let c = cos(rotation) * scale, s = sin(rotation) * scale
        return SimilarityTransform(scale: scale, rotation: rotation,
                                   tx: qcx - (c * pcx - s * pcy),
                                   ty: qcy - (s * pcx + c * pcy))
    }

    static func inliers(_ t: SimilarityTransform, source: [Star], target: [Star],
                        pairs: [(source: Int, target: Int)], tolerance: Double) -> [(source: Int, target: Int)] {
        pairs.filter { pr in
            let q = t.apply(x: source[pr.source].x, y: source[pr.source].y)
            let dx = q.x - target[pr.target].x, dy = q.y - target[pr.target].y
            return (dx * dx + dy * dy).squareRoot() < tolerance
        }
    }

    public static func solve(source: [Star], target: [Star],
                             pairs: [(source: Int, target: Int)],
                             minMatches: Int = 8, inlierTolerance: Double = 2.0,
                             iterations: Int = 500, seed: UInt64 = 0x5EED) -> SimilarityTransform? {
        guard pairs.count >= minMatches else { return nil }
        var rng = seed
        func randIndex(_ bound: Int) -> Int {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Int(rng >> 33) % bound
        }
        var best: [(source: Int, target: Int)] = []
        for _ in 0..<iterations {
            let i = randIndex(pairs.count)
            var j = randIndex(pairs.count)
            if j == i { j = (j + 1) % pairs.count }
            guard let candidate = fit(source: source, target: target, pairs: [pairs[i], pairs[j]][...])
            else { continue }
            let ins = inliers(candidate, source: source, target: target,
                              pairs: pairs, tolerance: inlierTolerance)
            if ins.count > best.count { best = ins }
        }
        guard best.count >= minMatches,
              let refined = fit(source: source, target: target, pairs: best[...])
        else { return nil }
        return refined
    }
}
