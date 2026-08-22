import XCTest
@testable import LiveAstroCore

final class PlateSolverTests: XCTestCase {
    private let ARCSEC_PER_RAD = 206264.806247

    /// Inverse of PlateSolver's grid mapping: where a camera with this WCS sees a catalog star.
    /// north-up grid px: gx = w/2 + xiArcsec/scale (parity flips x), gy = h/2 - etaArcsec/scale;
    /// then rotate the frame by -rotationDegrees about the center (frame is the grid rotated by +rot).
    private func projectThroughWCS(ra: Double, dec: Double, w: Int, h: Int,
                                   wcs: (cra: Double, cdec: Double, rotDeg: Double, scale: Double, parity: Bool))
        -> (x: Double, y: Double) {
        let p = GnomonicProjection.project(ra: ra, dec: dec, centerRA: wcs.cra, centerDec: wcs.cdec)
        var gx = Double(w)/2 + (p.xi * ARCSEC_PER_RAD) / wcs.scale
        let gy = Double(h)/2 - (p.eta * ARCSEC_PER_RAD) / wcs.scale
        if wcs.parity { gx = Double(w) - gx }
        // frame = grid rotated by +rotDeg about center → invert to place the star in frame coords
        let cx = Double(w)/2, cy = Double(h)/2
        let th = -wcs.rotDeg * .pi/180
        let dx = gx - cx, dy = gy - cy
        return (cx + cos(th)*dx - sin(th)*dy, cy + sin(th)*dx + cos(th)*dy)
    }

    // Angular half-spread of the synthetic catalog. Sized to the FOV: at scale=2"/px a 1000x800
    // frame spans ~0.55x0.44deg, so the catalog must be spread over a comparable field for a useful
    // number of stars to land in-frame. (The brief's 3.0deg spread put only ~1-2 of 40 stars inside
    // the FOV -> frames of <8 stars -> solve always nil; that made the round-trip oracle vacuous.)
    private static let catalogSpreadDeg = 0.6

    private func syntheticCatalog(cra: Double, cdec: Double, n: Int) -> StarCatalog {
        var stars: [CatalogStar] = []
        var seed: UInt64 = 0xABCDEF
        for _ in 0..<n {
            seed = seed &* 6364136223846793005 &+ 1
            let dra = (Double((seed >> 33) & 0xFFFF)/65535 - 0.5) * Self.catalogSpreadDeg / cos(cdec * .pi/180)
            seed = seed &* 6364136223846793005 &+ 1
            let ddec = (Double((seed >> 33) & 0xFFFF)/65535 - 0.5) * Self.catalogSpreadDeg
            seed = seed &* 6364136223846793005 &+ 1
            let mag = 5.0 + Double((seed >> 40) & 0xFF)/255 * 3.0
            stars.append(CatalogStar(ra: Float(cra + dra), dec: Float(cdec + ddec), mag: Float(mag)))
        }
        return try! StarCatalog(data: StarCatalog.encode(stars))
    }

    private func runSynthetic(rotDeg: Double, parity: Bool) {
        let w = 1000, h = 800, scale = 2.0, cra = 198.8, cdec = 41.35
        let cat = syntheticCatalog(cra: cra, cdec: cdec, n: 40)
        let wcs = (cra: cra, cdec: cdec, rotDeg: rotDeg, scale: scale, parity: parity)
        // Build the "frame" stars: each catalog star seen through the WCS, + noise; keep in-bounds.
        var frame: [Star] = []
        for cs in cat.stars {
            let p = projectThroughWCS(ra: Double(cs.ra), dec: Double(cs.dec), w: w, h: h, wcs: wcs)
            if p.x < 0 || p.x >= Double(w) || p.y < 0 || p.y >= Double(h) { continue }
            frame.append(Star(x: p.x + 0.15, y: p.y - 0.1, flux: pow(10, -0.4 * Double(cs.mag))))
        }
        frame.append(Star(x: 50, y: 60, flux: 5))    // a spurious non-catalog detection
        guard let got = PlateSolver.solve(stars: frame, width: w, height: h, pixelScaleArcsec: scale,
                                          approxCenterRA: cra + 0.05, approxCenterDec: cdec - 0.03,
                                          catalog: cat, minInliers: 8) else {
            return XCTFail("solve returned nil for rot=\(rotDeg) parity=\(parity)")
        }
        // recovered center within ~1 arcmin, rotation within 0.2°, parity correct
        let sep = 3600 * hypot((got.centerRA - cra) * cos(cdec * .pi/180), got.centerDec - cdec)
        XCTAssertLessThan(sep, 60, "center off by \(sep)\" (rot=\(rotDeg) parity=\(parity))")
        let dRot = ((got.rotationDegrees - rotDeg + 540).truncatingRemainder(dividingBy: 360)) - 180
        XCTAssertLessThan(abs(dRot), 0.2, "rotation off by \(dRot)° (rot=\(rotDeg) parity=\(parity))")
        XCTAssertEqual(got.parity, parity, "parity mismatch (rot=\(rotDeg))")
    }

    func testSolvesSyntheticNormalParity()   { runSynthetic(rotDeg: 27.0, parity: false) }
    func testSolvesSyntheticMirroredParity() { runSynthetic(rotDeg: -63.0, parity: true) }

    /// The triangle match locks the transform from only the brightest ~`triangleStars` stars, so its
    /// inlier count is capped near that (≈9 on the real sparse M63 field — thin over the floor). The
    /// refinement pass re-matches ALL detected stars against ALL in-frame catalog stars through that
    /// transform and re-fits, lifting the inlier count well beyond the triangle cap. This field has
    /// ~90 in-frame stars; a solve that only triangle-matched would report ≤ `triangleStars` inliers,
    /// so an inlier count far above that proves refinement engaged.
    func testRefinementLiftsInlierCountBeyondTriangleCap() {
        let w = 1500, h = 1300, scale = 2.0, cra = 150.0, cdec = 22.0, rotDeg = 33.0
        let cat = syntheticCatalog(cra: cra, cdec: cdec, n: 120)
        let wcs = (cra: cra, cdec: cdec, rotDeg: rotDeg, scale: scale, parity: false)
        var frame: [Star] = []
        for cs in cat.stars {
            let p = projectThroughWCS(ra: Double(cs.ra), dec: Double(cs.dec), w: w, h: h, wcs: wcs)
            if p.x < 0 || p.x >= Double(w) || p.y < 0 || p.y >= Double(h) { continue }
            frame.append(Star(x: p.x + 0.12, y: p.y - 0.08, flux: pow(10, -0.4 * Double(cs.mag))))
        }
        XCTAssertGreaterThan(frame.count, 60, "test needs many in-frame stars to exercise refinement")
        guard let got = PlateSolver.solve(stars: frame, width: w, height: h, pixelScaleArcsec: scale,
                                          approxCenterRA: cra + 0.05, approxCenterDec: cdec - 0.03,
                                          catalog: cat, minInliers: 8) else {
            return XCTFail("solve returned nil")
        }
        XCTAssertGreaterThan(got.inlierCount, PlateSolver.triangleStars + 10,
                             "inliers \(got.inlierCount) should exceed the triangle cap \(PlateSolver.triangleStars) after refinement")
        let sep = 3600 * hypot((got.centerRA - cra) * cos(cdec * .pi/180), got.centerDec - cdec)
        XCTAssertLessThan(sep, 60, "center off by \(sep)\" after refinement")
    }

    func testTooFewStarsReturnsNil() {
        let cat = syntheticCatalog(cra: 10, cdec: 20, n: 3)
        let stars = [Star(x: 100, y: 100, flux: 1), Star(x: 200, y: 150, flux: 1)]
        XCTAssertNil(PlateSolver.solve(stars: stars, width: 500, height: 500, pixelScaleArcsec: 2,
                                       approxCenterRA: 10, approxCenterDec: 20, catalog: cat))
    }

    /// Real M63 sub: detect stars, near-solve, and check the recovered center against the frame's
    /// CRVAL (the ASIAIR's own plate-solve). Needs the real bundled catalog + a frame; skips otherwise.
    /// Reliability regression: on a CROWDED field (many catalog stars in the FOV), the catalog
    /// arrives declination-sorted, but the frame's stars come from StarDetector (flux-sorted +
    /// spatially distributed). TriangleMatcher only uses the first ~20 of each list, so the grid
    /// must be selected by the SAME brightest/spatial criterion — otherwise the grid's first-20 is
    /// an arbitrary low-dec slice that won't overlap the frame's brightest, and the solve fails.
    /// This test presents the frame in the real detector order; it fails if the solver feeds the
    /// matcher dec-sorted catalog candidates.
    func testSolvesCrowdedFieldWithDetectorOrderedFrame() {
        let w = 1000, h = 800, scale = 2.0, cra = 150.0, cdec = 22.0, rotDeg = 15.0
        let cat = syntheticCatalog(cra: cra, cdec: cdec, n: 120)   // crowds the ~0.56°×0.44° FOV (>>20 in frame)
        let wcs = (cra: cra, cdec: cdec, rotDeg: rotDeg, scale: scale, parity: false)
        // Frame = in-FOV catalog seen through the WCS, then presented exactly as StarDetector would:
        // flux-sorted then spatially distributed (NOT dec order).
        var raw: [Star] = []
        for cs in cat.stars {
            let p = projectThroughWCS(ra: Double(cs.ra), dec: Double(cs.dec), w: w, h: h, wcs: wcs)
            if p.x < 0 || p.x >= Double(w) || p.y < 0 || p.y >= Double(h) { continue }
            raw.append(Star(x: p.x + 0.12, y: p.y - 0.08, flux: pow(10, -0.4 * Double(cs.mag))))
        }
        raw.sort { $0.flux > $1.flux }
        let frame = StarDetector.spatiallyDistributed(raw, width: w, height: h, maxStars: 60)
        guard let got = PlateSolver.solve(stars: frame, width: w, height: h, pixelScaleArcsec: scale,
                                          approxCenterRA: cra, approxCenterDec: cdec, catalog: cat) else {
            return XCTFail("crowded-field solve returned nil — grid candidates not brightest/spatial-matched to the frame")
        }
        let sep = 3600 * hypot((got.centerRA - cra) * cos(cdec * .pi/180), got.centerDec - cdec)
        XCTAssertLessThan(sep, 60, "crowded center off by \(sep)\"")
        let dRot = ((got.rotationDegrees - rotDeg + 540).truncatingRemainder(dividingBy: 360)) - 180
        XCTAssertLessThan(abs(dRot), 0.2, "crowded rotation off by \(dRot)°")
    }

    /// Reliability regression: the catalog query is a CIRCLE (half-diagonal + margin) but the frame
    /// is a RECTANGLE. Catalog stars projecting beyond the frame's half-diagonal reach can never be
    /// in-frame at any rotation. If such stars are BRIGHT they dominate the flux-sorted candidate
    /// selection with un-matchable targets. The solver must clip candidates to the frame's max reach.
    /// Here 50 bright stars sit in the query margin (never in-frame) among 40 fainter in-frame stars;
    /// without clipping, the matcher's brightest-20 are all off-frame → no correspondence → nil.
    func testDropsOffFrameBrightCandidates() {
        let w = 1000, h = 800, scale = 2.0, cra = 40.0, cdec = -12.0, rotDeg = 20.0
        let d2r = Double.pi / 180
        let wcs = (cra: cra, cdec: cdec, rotDeg: rotDeg, scale: scale, parity: false)
        var seed: UInt64 = 0x77AA55
        func u() -> Double { seed = seed &* 6364136223846793005 &+ 1; return Double((seed >> 33) & 0xFFFF)/65535 }
        var cs: [CatalogStar] = []
        // 40 in-frame stars (angular radius ≤ 0.18° → well inside the ~0.356° half-diagonal), fainter.
        for _ in 0..<40 {
            let rho = 0.02 + u() * 0.16, az = u() * 2 * .pi
            cs.append(CatalogStar(ra: Float(cra + rho * sin(az) / cos(cdec * d2r)),
                                  dec: Float(cdec + rho * cos(az)), mag: Float(7.0 + u())))
        }
        // 50 BRIGHT stars in the query margin (0.40–0.42° → beyond 0.356° reach, inside 0.427° query).
        for _ in 0..<50 {
            let rho = 0.40 + u() * 0.02, az = u() * 2 * .pi
            cs.append(CatalogStar(ra: Float(cra + rho * sin(az) / cos(cdec * d2r)),
                                  dec: Float(cdec + rho * cos(az)), mag: Float(4.0 + u() * 0.5)))
        }
        let cat = try! StarCatalog(data: StarCatalog.encode(cs))
        var raw: [Star] = []
        for c in cat.stars {   // frame = in-bounds projections only (off-frame bright stars undetected)
            let p = projectThroughWCS(ra: Double(c.ra), dec: Double(c.dec), w: w, h: h, wcs: wcs)
            if p.x < 0 || p.x >= Double(w) || p.y < 0 || p.y >= Double(h) { continue }
            raw.append(Star(x: p.x, y: p.y, flux: pow(10, -0.4 * Double(c.mag))))
        }
        guard let got = PlateSolver.solve(stars: raw, width: w, height: h, pixelScaleArcsec: scale,
                                          approxCenterRA: cra, approxCenterDec: cdec, catalog: cat) else {
            return XCTFail("solve nil — bright off-frame candidates polluted the brightest-N selection")
        }
        let sep = 3600 * hypot((got.centerRA - cra) * cos(cdec * d2r), got.centerDec - cdec)
        XCTAssertLessThan(sep, 60, "center off by \(sep)\"")
    }

    func testSolvesRealM63Frame() throws {
        guard ProcessInfo.processInfo.environment["LAS_SOLVE_FRAME"] != nil,
              let catalog = StarCatalog.installed() else {
            throw XCTSkip("set LAS_SOLVE_FRAME + generate the real catalog to run the real-frame solve")
        }
        let dir = URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/M63-import"))
        let subs = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "fit" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let first = subs.first else { throw XCTSkip("no M63 frames") }
        let data = try Data(contentsOf: first)
        let img = try FITSReader.read(data, normalizeRowOrder: false)
        // Solver inputs from the header: approximate center (mount pointing RA/DEC) + pixel scale.
        let hdr = try FITSReader.readHeader(data).keywords
        func kv(_ k: String) -> Double? { hdr[k].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
        guard let ra = kv("RA"), let dec = kv("DEC"), let fl = kv("FOCALLEN"), let px = kv("XPIXSZ"),
              let cra = kv("CRVAL1"), let cdec = kv("CRVAL2"),
              let crpix1 = kv("CRPIX1"), let crpix2 = kv("CRPIX2"),
              let cd11 = kv("CD1_1"), let cd12 = kv("CD1_2"),
              let cd21 = kv("CD2_1"), let cd22 = kv("CD2_2") else { throw XCTSkip("frame missing WCS keywords") }
        let scale = px / fl * 206.264806
        // grayscale for detection: FITSImage is planar (channel-major); average the planes.
        let n = img.width * img.height
        var lum = [Float](repeating: 0, count: n)
        let ch = max(1, img.channels)
        for c in 0..<ch {
            let base = c * n
            for i in 0..<n { lum[i] += img.pixels[base + i] }
        }
        if ch > 1 { for i in 0..<n { lum[i] /= Float(ch) } }
        let det = StarDetector.detectWithStats(luminance: lum, width: img.width, height: img.height, maxStars: 80)
        guard let wcs = PlateSolver.solve(stars: det.stars, width: img.width, height: img.height,
                                          pixelScaleArcsec: scale, approxCenterRA: ra, approxCenterDec: dec,
                                          catalog: catalog) else { return XCTFail("real solve returned nil") }
        // `PlateSolver` returns the sky position of the IMAGE CENTER (pixel W/2, H/2). The ASIAIR's own
        // solution is anchored at CRPIX (≠ image center here), so compare against the image center's
        // true sky position derived from the header's full linear WCS: intermediate coords
        // (CD · (imageCenter − CRPIX0)) in degrees, then gnomonic-deprojected about CRVAL. Comparing
        // directly to CRVAL would be wrong by the CRPIX-to-center offset (~43′ on this frame).
        let dx = Double(img.width) / 2 - (crpix1 - 1), dy = Double(img.height) / 2 - (crpix2 - 1)
        let xi = (cd11 * dx + cd12 * dy) * .pi / 180, eta = (cd21 * dx + cd22 * dy) * .pi / 180
        let ref = GnomonicProjection.deproject(xi: xi, eta: eta, centerRA: cra, centerDec: cdec)
        let sepArcmin = 60 * hypot((wcs.centerRA - ref.ra) * cos(ref.dec * .pi / 180), wcs.centerDec - ref.dec)
        XCTAssertLessThan(sepArcmin, 5, "solved center \(sepArcmin)′ from header image-center (\(ref.ra),\(ref.dec)); inliers=\(wcs.inlierCount) rot=\(wcs.rotationDegrees)")
        // Refinement pass should lift the thin triangle-match inlier count (~9 on this sparse field)
        // by re-matching all detected stars against the full catalog — a robustness floor well above
        // the 8-inlier minimum.
        XCTAssertGreaterThan(wcs.inlierCount, 18, "expected refinement to recover many inliers, got \(wcs.inlierCount)")
    }
}
