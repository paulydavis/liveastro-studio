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

        func grid(mirrored: Bool) -> [Star] {
            let g = catStars.compactMap { cs -> Star? in
                let p = GnomonicProjection.project(ra: Double(cs.ra), dec: Double(cs.dec),
                                                   centerRA: approxCenterRA, centerDec: approxCenterDec)
                var gx = Double(width)/2 + (p.xi * arcsecPerRad) / pixelScaleArcsec
                let gy = Double(height)/2 - (p.eta * arcsecPerRad) / pixelScaleArcsec
                if mirrored { gx = Double(width) - gx }
                guard hypot(gx - Double(width)/2, gy - Double(height)/2) <= maxReachPx else { return nil }
                return Star(x: gx, y: gy, flux: pow(10, -0.4 * Double(cs.mag)))
            }
            return Array(g.sorted { $0.flux > $1.flux }.prefix(catalogSelectionCap))
        }

        // Try both parities; keep the transform with more inliers.
        var best: (t: SimilarityTransform, inliers: Int, mirrored: Bool)?
        for mirrored in [false, true] {
            let g = grid(mirrored: mirrored)
            let pairs = TriangleMatcher.correspondences(source: frameStars, target: g)
            guard let t = TransformSolver.solve(source: frameStars, target: g, pairs: pairs) else { continue }
            let n = TransformSolver.inliers(t, source: frameStars, target: g, pairs: pairs, tolerance: 3.0).count
            if best == nil || n > best!.inliers { best = (t, n, mirrored) }
        }
        guard let win = best, win.inliers >= minInliers else { return nil }

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
