import Foundation

/// Near-solve plate solver: recovers a frame's WCS by matching its detected stars against the
/// catalog, given an approximate center + known pixel scale. The match is a rotation-vote that USES
/// the known scale (plate-solving = registering the frame against the catalog instead of a prior frame).
public enum PlateSolver {
    static let arcsecPerRad = 206264.806247
    /// Candidates kept after brightest-first (global flux) selection on BOTH the frame and the grid.
    static let catalogSelectionCap = 60
    /// Nearest-neighbour gate (grid pixels) for the refinement pass: a detected star mapped through the
    /// coarse transform is accepted as a match to a catalog star only within this radius. Matches the
    /// 3px inlier tolerance used elsewhere — tight enough to reject wrong pairings, loose enough for the
    /// coarse transform's residual.
    static let refineTolerancePx = 3.0
    /// A candidate farther than the frame's half-diagonal from center can never be in-frame at any
    /// rotation (distance from center is rotation-invariant). `frameReachFactor` = that half-diagonal
    /// plus slack for the approximate-center (mount pointing) offset — the exact pixel-space clip.
    static let frameReachFactor = 1.1
    /// The catalog query is an APPROXIMATE angular circle; it reaches `frameReachFactor + querySlack`,
    /// a guaranteed SUPERSET of the exact pixel clip (never dropping a real edge candidate the clip
    /// would keep) despite gnomonic nonlinearity near the edge.
    static let querySlack = 0.1   // frameReachFactor(1.1) + this = 1.2 query radius

    // --- Robust known-scale near-solve (rotation-vote) tuning ---
    /// Brightest stars from each side used for the rotation + translation vote.
    static let voteStars = 50
    /// Ignore inter-star baselines shorter than this (px): short vectors have noise-dominated angles.
    static let minBaselinePx = 40.0
    /// Length-match tolerance for a source/target baseline to vote a rotation: an absolute floor …
    static let baseLenTolPx = 5.0
    /// … plus a relative term (covers a small header-vs-true scale error over long baselines).
    static let lenTolFrac = 0.01
    /// Translation-vote bucket size (px), and the NN gate applied under the coarse (θ + translation)
    /// transform before the least-squares fit.
    static let translationBinPx = 12.0
    static let coarseMatchTolPx = 20.0
    /// How many of the strongest rotation-histogram peaks to evaluate. The true rotation is a strong
    /// peak, but a noisy field can briefly out-vote it, so evaluate a few and keep the best-fitting.
    static let rotationPeaksToTry = 6

    public static func solve(stars: [Star], width: Int, height: Int, pixelScaleArcsec: Double,
                             approxCenterRA: Double, approxCenterDec: Double,
                             catalog: StarCatalog, minInliers: Int = 8) -> WCS? {
        guard stars.count >= minInliers, pixelScaleArcsec > 0, width > 0, height > 0 else { return nil }
        // FOV radius: frame half-diagonal × (clip reach + query slack) — a superset of the pixel clip below.
        let radiusDeg = 0.5 * (Double(width * width + height * height)).squareRoot()
            * pixelScaleArcsec / 3600 * (frameReachFactor + querySlack)
        let catStars = catalog.stars(nearRA: approxCenterRA, dec: approxCenterDec, radiusDegrees: radiusDeg)
        guard catStars.count >= minInliers else { return nil }

        // Order the frame candidates by GLOBAL brightness (flux). The rotation vote uses the brightest
        // `voteStars`; brightest-first makes that subset the stars most likely to have a catalog match.
        let frameStars = Array(stars.sorted { $0.flux > $1.flux }.prefix(catalogSelectionCap))

        // The catalog query is a CIRCLE, but the frame is a RECTANGLE: a candidate farther than the
        // frame's half-diagonal from center can never appear in-frame at ANY rotation (distance from
        // center is rotation-invariant). Clip those out before selection, else bright off-frame stars
        // (in the circular query's corners) fill the candidate list with un-matchable targets.
        let maxReachPx = 0.5 * Double(width * width + height * height).squareRoot() * frameReachFactor

        // ALL in-frame catalog stars projected to grid pixels for a parity (no brightest cap). The
        // rotation vote uses the brightest `catalogSelectionCap` of these; the refinement pass below
        // uses the full set to match every detected star.
        func gridStars(mirrored: Bool) -> [Star] {
            catStars.compactMap { cs -> Star? in
                let p = GnomonicProjection.project(ra: Double(cs.ra), dec: Double(cs.dec),
                                                   centerRA: approxCenterRA, centerDec: approxCenterDec)
                var gx = Double(width)/2 + (p.xi * arcsecPerRad) / pixelScaleArcsec
                let gy = Double(height)/2 - (p.eta * arcsecPerRad) / pixelScaleArcsec
                if mirrored { gx = Double(width) - gx }
                guard hypot(gx - Double(width)/2, gy - Double(height)/2) <= maxReachPx else { return nil }
                return Star(x: gx, y: gy, flux: pow(10, -0.4 * Double(cs.mag)))
            }
        }

        // Try both parities; keep the transform with more inliers.
        var best: (t: SimilarityTransform, inliers: Int, mirrored: Bool)?
        for mirrored in [false, true] {
            // FULL in-field grid: the rotation/translation vote uses its brightest subset, but the NN
            // match + fit use the full set — the frame's detected stars often correspond to catalog stars
            // fainter than the vote subset, so matching against only the brightest misses most of them.
            let full = gridStars(mirrored: mirrored)
            guard let (t, n) = coarseSolve(source: frameStars, target: full, minInliers: minInliers) else { continue }
            if best == nil || n > best!.inliers { best = (t, n, mirrored) }
        }
        guard var win = best, win.inliers >= minInliers else { return nil }

        // Refinement pass (one ICP iteration seeded by the coarse transform). Map EVERY detected star
        // through the coarse transform, nearest-neighbour it to the FULL in-frame catalog, and re-fit —
        // this recovers fainter true matches the brightest-N vote missed and tightens center/rotation.
        // Guarded both ways (`> win.inliers`) so it can only improve the solution, never regress it.
        let fullGrid = gridStars(mirrored: win.mirrored)
        var refinedPairs: [StarPair] = []
        for (si, s) in stars.enumerated() {
            let p = win.t.apply(x: s.x, y: s.y)
            var bestJ = -1, bestD = refineTolerancePx
            for (ti, g) in fullGrid.enumerated() {
                let d = hypot(p.x - g.x, p.y - g.y)
                if d < bestD { bestD = d; bestJ = ti }
            }
            if bestJ >= 0 { refinedPairs.append(StarPair(source: si, target: bestJ)) }
        }
        if refinedPairs.count > win.inliers,
           let refined = TransformSolver.solve(source: stars, target: fullGrid, pairs: refinedPairs,
                                               minMatches: minInliers) {
            let rn = TransformSolver.inliers(refined, source: stars, target: fullGrid,
                                             pairs: refinedPairs, tolerance: 3.0).count
            if rn > win.inliers { win = (refined, rn, win.mirrored) }
        }

        // Frame center → grid position → (xi,eta) → deproject → refined center.
        let gc = win.t.apply(x: Double(width)/2, y: Double(height)/2)
        var gx = gc.x
        if win.mirrored { gx = Double(width) - gx }
        let xi = ((gx - Double(width)/2) * pixelScaleArcsec) / arcsecPerRad
        let eta = ((Double(height)/2 - gc.y) * pixelScaleArcsec) / arcsecPerRad
        let center = GnomonicProjection.deproject(xi: xi, eta: eta,
                                                  centerRA: approxCenterRA, centerDec: approxCenterDec)
        // The frame is the north-up grid rotated by +rotationDegrees about its center, so the fitted
        // frame→grid transform IS that same +rotationDegrees rotation. The mirror is baked into the
        // target grid on both parities (source→target stays a pure rotation, no reflection between
        // them), so the rotation reads out the same way for both — no parity-dependent sign flip.
        var rotDeg = win.t.rotation * 180 / .pi
        rotDeg = (rotDeg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        if rotDeg > 180 { rotDeg -= 360 }
        return WCS(centerRA: center.ra, centerDec: center.dec, rotationDegrees: rotDeg,
                   pixelScaleArcsec: pixelScaleArcsec, parity: win.mirrored, inlierCount: win.inliers)
    }

    /// Robust known-scale coarse match: source (frame) ≈ target (grid) under a rotation + translation
    /// (scale ≈ 1, since the grid is projected at the frame's known pixel scale). Unlike scale-invariant
    /// triangle matching, this USES the known scale: corresponding inter-star baselines have equal
    /// LENGTH, so each length-matched source/target baseline votes one rotation. The true rotation
    /// accumulates votes from every real baseline while distractor pairs scatter — so it stays robust
    /// when the catalog is far deeper than the frame (many un-matchable distractor stars). Returns the
    /// fitted frame→grid transform and its inlier count, or nil if no rotation yields `minInliers`.
    static func coarseSolve(source: [Star], target: [Star], minInliers: Int) -> (SimilarityTransform, Int)? {
        // `target` is the FULL in-field grid. Vote with the brightest subset of each side; NN + fit
        // against the full grid (below, inside fitAtRotation and the inlier count).
        let s = Array(source.prefix(voteStars))
        let t = Array(target.sorted { $0.flux > $1.flux }.prefix(voteStars))
        guard s.count >= 3, t.count >= 3 else { return nil }

        // Target baselines (both directions, to cover correspondence orientation), for rotation voting.
        var tLen: [Double] = [], tAng: [Double] = []
        for k in 0..<t.count { for l in 0..<t.count where l != k {
            let dx = t[l].x - t[k].x, dy = t[l].y - t[k].y
            let len = (dx*dx + dy*dy).squareRoot()
            if len >= minBaselinePx { tLen.append(len); tAng.append(atan2(dy, dx)) }
        }}
        guard !tLen.isEmpty else { return nil }

        // Rotation histogram (1° bins, ±1-bin smoothing): a length-matched (source,target) baseline
        // votes rotation = angle(target vec) − angle(source vec).
        var hist = [Double](repeating: 0, count: 360)
        for i in 0..<s.count { for j in (i+1)..<s.count {
            let dx = s[j].x - s[i].x, dy = s[j].y - s[i].y
            let len = (dx*dx + dy*dy).squareRoot()
            if len < minBaselinePx { continue }
            let angS = atan2(dy, dx)
            let tol = max(baseLenTolPx, len * lenTolFrac)
            for vi in 0..<tLen.count where abs(tLen[vi] - len) <= tol {
                var deg = (tAng[vi] - angS) * 180 / .pi
                deg = (deg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
                let b = Int(deg) % 360
                hist[b] += 1; hist[(b + 1) % 360] += 0.5; hist[(b + 359) % 360] += 0.5
            }
        }}

        // Evaluate the strongest rotation peaks; keep the transform with the most inliers.
        var best: (SimilarityTransform, Int)?
        for deg in topPeaks(hist, count: rotationPeaksToTry) {
            guard let cand = fitAtRotation(Double(deg) * .pi / 180, source: source, targetVote: t,
                                           targetFull: target, minInliers: minInliers) else { continue }
            let n = TransformSolver.inliers(cand, source: source, target: target,
                                            pairs: nnPairs(cand, source: source, target: target, tol: 3.0),
                                            tolerance: 3.0).count
            if best == nil || n > best!.1 { best = (cand, n) }
        }
        return best
    }

    /// Local-maxima bins of the (circular) rotation histogram, strongest first, up to `count`.
    static func topPeaks(_ h: [Double], count: Int) -> [Int] {
        let n = h.count
        var maxima: [(Int, Double)] = []
        for b in 0..<n where h[b] > 0 && h[b] >= h[(b + 1) % n] && h[b] >= h[(b + n - 1) % n] {
            maxima.append((b, h[b]))
        }
        return maxima.sorted { $0.1 > $1.1 }.prefix(count).map { $0.0 }
    }

    /// For a fixed rotation: vote the translation (2-D histogram of target − R·source over the brightest
    /// stars), take the peak, build the coarse transform, NN-match ALL stars under it, and least-squares
    /// fit. Returns the fitted transform or nil if it can't reach `minInliers`.
    static func fitAtRotation(_ theta: Double, source: [Star], targetVote: [Star], targetFull: [Star],
                              minInliers: Int) -> SimilarityTransform? {
        let c = cos(theta), sn = sin(theta)
        let sv = Array(source.prefix(voteStars)), tv = targetVote
        func key(_ tx: Double, _ ty: Double) -> Int64 {
            Int64((tx / translationBinPx).rounded(.down)) &* 1_000_003
                &+ Int64((ty / translationBinPx).rounded(.down))
        }
        var buckets: [Int64: Int] = [:]
        for a in sv { let rx = c*a.x - sn*a.y, ry = sn*a.x + c*a.y
            for b in tv { buckets[key(b.x - rx, b.y - ry), default: 0] += 1 } }
        guard let peak = buckets.max(by: { $0.value < $1.value })?.key else { return nil }
        // Sub-bin translation: mean of the (target − R·source) offsets that fell in the winning bucket.
        var sx = 0.0, sy = 0.0, cnt = 0
        for a in sv { let rx = c*a.x - sn*a.y, ry = sn*a.x + c*a.y
            for b in tv { let tx = b.x - rx, ty = b.y - ry
                if key(tx, ty) == peak { sx += tx; sy += ty; cnt += 1 } } }
        guard cnt >= 2 else { return nil }
        let t0 = SimilarityTransform(scale: 1, rotation: theta, tx: sx / Double(cnt), ty: sy / Double(cnt))
        let pairs = nnPairs(t0, source: source, target: targetFull, tol: coarseMatchTolPx)
        guard pairs.count >= minInliers else { return nil }
        return TransformSolver.solve(source: source, target: targetFull, pairs: pairs,
                                     minMatches: minInliers, inlierTolerance: 3.0)
    }

    /// Nearest-neighbour source→target pairs under a transform, within `tol` px (one target per source).
    static func nnPairs(_ t: SimilarityTransform, source: [Star], target: [Star], tol: Double) -> [StarPair] {
        var pairs: [StarPair] = []
        for (si, a) in source.enumerated() {
            let p = t.apply(x: a.x, y: a.y)
            var bj = -1, bd = tol
            for (tj, b) in target.enumerated() {
                let d = hypot(p.x - b.x, p.y - b.y)
                if d < bd { bd = d; bj = tj }
            }
            if bj >= 0 { pairs.append(StarPair(source: si, target: bj)) }
        }
        return pairs
    }
}
