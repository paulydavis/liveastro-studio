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

    func testTooFewStarsReturnsNil() {
        let cat = syntheticCatalog(cra: 10, cdec: 20, n: 3)
        let stars = [Star(x: 100, y: 100, flux: 1), Star(x: 200, y: 150, flux: 1)]
        XCTAssertNil(PlateSolver.solve(stars: stars, width: 500, height: 500, pixelScaleArcsec: 2,
                                       approxCenterRA: 10, approxCenterDec: 20, catalog: cat))
    }

    /// Real M63 sub: detect stars, near-solve, and check the recovered center against the frame's
    /// CRVAL (the ASIAIR's own plate-solve). Needs the real bundled catalog + a frame; skips otherwise.
    func testSolvesRealM63Frame() throws {
        guard ProcessInfo.processInfo.environment["LAS_SOLVE_FRAME"] != nil,
              let catalog = StarCatalog.bundled() else {
            throw XCTSkip("set LAS_SOLVE_FRAME + generate the real catalog to run the real-frame solve")
        }
        let dir = URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/M63-import"))
        let subs = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "fit" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let first = subs.first else { throw XCTSkip("no M63 frames") }
        let data = try Data(contentsOf: first)
        let img = try FITSReader.read(data, normalizeRowOrder: false)
        // approx center + scale + CRVAL from the header
        let hdr = try FITSReader.readHeader(data).keywords
        func kv(_ k: String) -> Double? { hdr[k].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
        guard let ra = kv("RA"), let dec = kv("DEC"), let fl = kv("FOCALLEN"), let px = kv("XPIXSZ"),
              let cra = kv("CRVAL1"), let cdec = kv("CRVAL2") else { throw XCTSkip("frame missing WCS keywords") }
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
        let sepArcmin = 60 * hypot((wcs.centerRA - cra) * cos(cdec * .pi/180), wcs.centerDec - cdec)
        XCTAssertLessThan(sepArcmin, 10, "solved center \(sepArcmin)′ from CRVAL (\(cra),\(cdec))")
    }
}
