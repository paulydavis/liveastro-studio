import Foundation

/// Near-solve plate solver: recovers a frame's WCS by matching its detected stars against the
/// catalog, given an approximate center + known pixel scale. Reuses TriangleMatcher + TransformSolver
/// (plate-solving = registering the frame against the catalog instead of the previous frame).
public enum PlateSolver {
    static let arcsecPerRad = 206264.806247
    /// Candidates kept after brightest-first (global flux) selection on BOTH the frame and the grid.
    /// TriangleMatcher uses only the first ~20, but keeping the brightest 60 gives it a comfortable
    /// margin of corresponding stars on crowded fields.
    static let catalogSelectionCap = 60
    /// Triangle-vote stars for the plate-solve match. Larger than TriangleMatcher's frame-to-frame
    /// default (20) because plate-solving matches PARTIALLY-overlapping sets: the frame detects stars
    /// fainter than the catalog's depth, so its brightest-N (by flux) and the catalog's brightest-N (by
    /// magnitude) share only a fraction of stars. Measured on a real sparse-field M63 sub, that shared
    /// count rises 9→16 going from N=20→30 — 30 clears the minInliers floor with margin where 20 didn't.
    /// Cost is O(N^3)² per parity, ≈98M triangle-pair compares at 40 — acceptable off the hot path
    /// (solve runs once at seed). 40 is needed, not optional: on the real M63 sub the grid is built
    /// around the APPROXIMATE center (mount pointing, ~0.64° off true), which shifts which catalog
    /// stars land in the brightest-N; at N=30 the brightest-30 lost enough true correspondences that
    /// the solve returned nil, at N=40 it recovers 9 inliers and solves.
    static let triangleStars = 40
    /// Invariant match tolerance for the plate-solve triangle vote — TIGHTER than TriangleMatcher's
    /// frame-to-frame default (0.02). Plate-solving matches partially-overlapping sets with many
    /// unmatched distractor stars, so coincidental triangle collisions are rife; at 0.02 the spurious
    /// pairs out-VOTE the real ones (283 vs ~200 on a real M63 sub) and win the greedy assignment,
    /// leaving only 3 correct pairs. At 0.01 the coincidences fall off faster than the true matches, so
    /// all real correspondences survive. Frame-to-frame registration (near-identical sets) keeps 0.02.
    static let triangleTolerance = 0.01
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
    /// would keep) despite gnomonic nonlinearity near the edge. Additive so the query always tracks
    /// `frameReachFactor` with a fixed extra margin — no hand-tuned ratio to drift. Any value > 0
    /// keeps query > clip.
    static let querySlack = 0.1   // frameReachFactor(1.1) + this = 1.2 query radius

    public static func solve(stars: [Star], width: Int, height: Int, pixelScaleArcsec: Double,
                             approxCenterRA: Double, approxCenterDec: Double,
                             catalog: StarCatalog, minInliers: Int = 8) -> WCS? {
        guard stars.count >= minInliers, pixelScaleArcsec > 0, width > 0, height > 0 else { return nil }
        // FOV radius: frame half-diagonal × (clip reach + query slack) — a superset of the pixel clip below.
        let radiusDeg = 0.5 * (Double(width * width + height * height)).squareRoot()
            * pixelScaleArcsec / 3600 * (frameReachFactor + querySlack)
        let catStars = catalog.stars(nearRA: approxCenterRA, dec: approxCenterDec, radiusDegrees: radiusDeg)
        guard catStars.count >= minInliers else { return nil }

        // Order BOTH the frame and the grid candidates by GLOBAL brightness (rotation-invariant),
        // so TriangleMatcher's first-maxTriangleStars pick the SAME physical stars on both source and
        // target regardless of the frame's rotation. The catalog arrives declination-sorted and the
        // frame stars arrive in StarDetector's spatially-distributed order — neither is rotation-
        // invariant, so on a crowded field their first-20 wouldn't correspond and the solve fails
        // (regression: testSolvesCrowdedFieldWithDetectorOrderedFrame). Brightest-N is the invariant
        // that makes the match robust; the fit then uses all inliers, which span the field anyway.
        let frameStars = Array(stars.sorted { $0.flux > $1.flux }.prefix(catalogSelectionCap))

        // The catalog query is a CIRCLE, but the frame is a RECTANGLE: a candidate farther than the
        // frame's half-diagonal from center can never appear in-frame at ANY rotation (distance from
        // center is rotation-invariant). Clip those out BEFORE the brightest-N selection, else bright
        // off-frame stars (in the circular query's corners) would fill the candidate list with
        // un-matchable targets (regression: testDropsOffFrameBrightCandidates). See frameReachFactor.
        let maxReachPx = 0.5 * Double(width * width + height * height).squareRoot() * frameReachFactor

        // ALL in-frame catalog stars projected to grid pixels for a parity (no brightest cap). The
        // triangle match uses only the brightest `catalogSelectionCap` of these; the refinement pass
        // below uses the full set to match every detected star.
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
            let g = Array(gridStars(mirrored: mirrored).sorted { $0.flux > $1.flux }.prefix(catalogSelectionCap))
            let pairs = TriangleMatcher.correspondences(source: frameStars, target: g,
                                                        maxTriangleStars: triangleStars,
                                                        invariantTolerance: triangleTolerance)
            guard let t = TransformSolver.solve(source: frameStars, target: g, pairs: pairs) else { continue }
            let n = TransformSolver.inliers(t, source: frameStars, target: g, pairs: pairs, tolerance: 3.0).count
            if best == nil || n > best!.inliers { best = (t, n, mirrored) }
        }
        guard var win = best, win.inliers >= minInliers else { return nil }

        // Refinement pass (one ICP iteration seeded by the triangle-match transform). The triangle
        // match locks the transform from only the brightest `triangleStars` stars, so its inlier count
        // is thin on a sparse field (≈9 on the real M63 sub). Map EVERY detected star through that
        // transform, nearest-neighbour it to the FULL in-frame catalog, and re-fit — this recovers the
        // fainter true matches the brightest-N triangle set missed, lifting the inlier count and
        // tightening center/rotation. Guarded both ways (`> win.inliers`) so it can only improve the
        // solution, never regress it.
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
}
