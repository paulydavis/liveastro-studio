import Foundation

/// Near-solve plate solver: recovers a frame's WCS by matching its detected stars against the
/// catalog, given an approximate center + known pixel scale. Reuses TriangleMatcher + TransformSolver
/// (plate-solving = registering the frame against the catalog instead of the previous frame).
public enum PlateSolver {
    static let arcsecPerRad = 206264.806247

    public static func solve(stars: [Star], width: Int, height: Int, pixelScaleArcsec: Double,
                             approxCenterRA: Double, approxCenterDec: Double,
                             catalog: StarCatalog, minInliers: Int = 8) -> WCS? {
        guard stars.count >= minInliers, pixelScaleArcsec > 0, width > 0, height > 0 else { return nil }
        // FOV radius (diagonal half-FOV + 20% margin), in degrees.
        let radiusDeg = 0.5 * (Double(width * width + height * height)).squareRoot()
            * pixelScaleArcsec / 3600 * 1.2
        let catStars = catalog.stars(nearRA: approxCenterRA, dec: approxCenterDec, radiusDegrees: radiusDeg)
        guard catStars.count >= minInliers else { return nil }

        // Project catalog → a north-up pixel grid at the frame's scale. brightness→flux (brighter=lower mag).
        func grid(mirrored: Bool) -> [Star] {
            catStars.map { cs in
                let p = GnomonicProjection.project(ra: Double(cs.ra), dec: Double(cs.dec),
                                                   centerRA: approxCenterRA, centerDec: approxCenterDec)
                var gx = Double(width)/2 + (p.xi * arcsecPerRad) / pixelScaleArcsec
                let gy = Double(height)/2 - (p.eta * arcsecPerRad) / pixelScaleArcsec
                if mirrored { gx = Double(width) - gx }
                return Star(x: gx, y: gy, flux: pow(10, -0.4 * Double(cs.mag)))
            }
        }

        // Try both parities; keep the transform with more inliers.
        var best: (t: SimilarityTransform, inliers: Int, mirrored: Bool)?
        for mirrored in [false, true] {
            let g = grid(mirrored: mirrored)
            let pairs = TriangleMatcher.correspondences(source: stars, target: g)
            guard let t = TransformSolver.solve(source: stars, target: g, pairs: pairs) else { continue }
            let n = TransformSolver.inliers(t, source: stars, target: g, pairs: pairs, tolerance: 3.0).count
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
