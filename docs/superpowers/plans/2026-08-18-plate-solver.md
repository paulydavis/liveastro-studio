# Plate-Solver (plate-solve sub-project 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recover a reference frame's WCS (center RA/Dec + rotation + parity) by matching its detected stars against the bundled Gaia catalog, using the FITS approximate center + known pixel scale (near-solve).

**Architecture:** Reuse the stacker's registration machinery. Project catalog stars (near the approx center) onto a north-up pixel grid at the frame's pixel scale; `TriangleMatcher.correspondences` (rotation/scale-invariant) matches frame stars to that grid; `TransformSolver.solve` (Umeyama) recovers the similarity transform; derive the WCS from it. Try both parities (the transform is rotation-only). The gnomonic projection is exact and independently tested; the synthetic known-WCS round-trip is the correctness oracle for the solve's sign/orientation conventions.

**Tech Stack:** Swift 5.10, `LiveAstroCore`, XCTest.

## Global Constraints

- Branch `feature/plate-solver` (off main). NEVER commit to / base on / rebase onto `main`. Commit trailer `Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j`, NO `Co-Authored-By`.
- Near-solve ONLY (require an approx center + pixel scale). No blind solve, no distortion/SIP, no pipeline wiring, no rotation/UI (those are sub-project 3). Solve the reference once (not per frame).
- Reuse existing types: `Star {x,y,flux}` (`Stacking/StarDetector.swift`), `StarPair` + `TriangleMatcher.correspondences(source:target:...) -> [StarPair]`, `TransformSolver.solve(source:target:pairs:...) -> SimilarityTransform?` and (internal, same-module) `TransformSolver.inliers(_:source:target:pairs:tolerance:) -> [StarPair]`, `SimilarityTransform {scale,rotation,tx,ty}.apply(x:y:)`, `StarCatalog.stars(nearRA:dec:radiusDegrees:)`.
- **The synthetic round-trip test in Task 2 is the correctness oracle.** The gnomonic project/deproject (Task 1) are pinned by their own round-trip test and are FIXED; if the synthetic solve test fails on a sign/orientation/rotation convention, reconcile by adjusting ONLY the grid-orientation / rotation-sign lines in `solve` (and the matching lines in the test's `projectThroughWCS` helper) until the round-trip closes — do not weaken the tolerances.
- Run only ONE `swift test` / `swift build` at a time.

---

## File Structure

- `Sources/LiveAstroCore/PlateSolve/WCS.swift` — the `WCS` value type (Task 1).
- `Sources/LiveAstroCore/PlateSolve/GnomonicProjection.swift` — TAN project/deproject (Task 1).
- `Sources/LiveAstroCore/PlateSolve/PlateSolver.swift` — `solve(...)` (Task 2).
- `Tests/LiveAstroCoreTests/GnomonicProjectionTests.swift` — round-trip (Task 1).
- `Tests/LiveAstroCoreTests/PlateSolverTests.swift` — synthetic gate + degenerate + gated real (Task 2).

Constant: arcsec per radian = `206264.806247`.

---

### Task 1: `WCS` + `GnomonicProjection`

**Files:** Create `WCS.swift`, `GnomonicProjection.swift`, `Tests/.../GnomonicProjectionTests.swift`.

**Interfaces:**
- Produces: `struct WCS: Equatable { let centerRA, centerDec, rotationDegrees, pixelScaleArcsec: Double; let parity: Bool; let inlierCount: Int }`.
- `enum GnomonicProjection`: `static func project(ra: Double, dec: Double, centerRA: Double, centerDec: Double) -> (xi: Double, eta: Double)` (radians) and `static func deproject(xi: Double, eta: Double, centerRA: Double, centerDec: Double) -> (ra: Double, dec: Double)` (degrees, ra in [0,360)).

- [ ] **Step 1: Write the failing test**

Create `Tests/LiveAstroCoreTests/GnomonicProjectionTests.swift`:

```swift
import XCTest
@testable import LiveAstroCore

final class GnomonicProjectionTests: XCTestCase {
    func testProjectDeprojectRoundTrip() {
        // Centers incl. mid-sky, near-pole, and RA-seam; offsets within a few degrees (a FOV).
        let centers: [(Double, Double)] = [(198.8, 41.35), (10.0, 85.0), (0.5, -3.0)]
        for (ra0, dec0) in centers {
            for dra in [-1.5, 0.0, 1.7] {
                for ddec in [-1.2, 0.0, 1.3] {
                    let ra = (ra0 + dra / cos(dec0 * .pi/180) + 360).truncatingRemainder(dividingBy: 360)
                    let dec = dec0 + ddec
                    let p = GnomonicProjection.project(ra: ra, dec: dec, centerRA: ra0, centerDec: dec0)
                    let b = GnomonicProjection.deproject(xi: p.xi, eta: p.eta, centerRA: ra0, centerDec: dec0)
                    XCTAssertEqual(b.dec, dec, accuracy: 1e-7, "dec round-trip @\(ra0),\(dec0)")
                    let dRA = ((b.ra - ra + 540).truncatingRemainder(dividingBy: 360)) - 180
                    XCTAssertEqual(dRA, 0, accuracy: 1e-7, "ra round-trip @\(ra0),\(dec0)")
                }
            }
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GnomonicProjectionTests`
Expected: FAIL to compile — no `GnomonicProjection`.

- [ ] **Step 3: Implement `WCS` + `GnomonicProjection`**

Create `Sources/LiveAstroCore/PlateSolve/WCS.swift`:

```swift
import Foundation

/// World Coordinate System solution for a frame: where it points, how it's rotated, its scale.
public struct WCS: Equatable {
    public let centerRA: Double          // degrees [0,360)
    public let centerDec: Double         // degrees [-90,90]
    public let rotationDegrees: Double   // position angle of image +y ("up") relative to north
    public let pixelScaleArcsec: Double
    public let parity: Bool              // true = mirrored (sky flipped left-right)
    public let inlierCount: Int          // matched catalog stars supporting the solve
    public init(centerRA: Double, centerDec: Double, rotationDegrees: Double,
                pixelScaleArcsec: Double, parity: Bool, inlierCount: Int) {
        self.centerRA = centerRA; self.centerDec = centerDec; self.rotationDegrees = rotationDegrees
        self.pixelScaleArcsec = pixelScaleArcsec; self.parity = parity; self.inlierCount = inlierCount
    }
}
```

Create `Sources/LiveAstroCore/PlateSolve/GnomonicProjection.swift`:

```swift
import Foundation

/// Standard gnomonic (TAN) tangent-plane projection about a center. `project` returns standard
/// coordinates (xi, eta) in RADIANS; `deproject` is its inverse, returning degrees.
public enum GnomonicProjection {
    static let d2r = Double.pi / 180, r2d = 180 / Double.pi

    public static func project(ra: Double, dec: Double,
                               centerRA: Double, centerDec: Double) -> (xi: Double, eta: Double) {
        let r = ra * d2r, d = dec * d2r, r0 = centerRA * d2r, d0 = centerDec * d2r
        let cosc = sin(d0) * sin(d) + cos(d0) * cos(d) * cos(r - r0)
        let xi = cos(d) * sin(r - r0) / cosc
        let eta = (cos(d0) * sin(d) - sin(d0) * cos(d) * cos(r - r0)) / cosc
        return (xi, eta)
    }

    public static func deproject(xi: Double, eta: Double,
                                 centerRA: Double, centerDec: Double) -> (ra: Double, dec: Double) {
        let r0 = centerRA * d2r, d0 = centerDec * d2r
        let rho = (xi * xi + eta * eta).squareRoot()
        if rho < 1e-12 { return (centerRA, centerDec) }
        let c = atan(rho)
        let dec = asin(cos(c) * sin(d0) + eta * sin(c) * cos(d0) / rho)
        let ra = r0 + atan2(xi * sin(c), rho * cos(d0) * cos(c) - eta * sin(d0) * sin(c))
        let raDeg = (ra * r2d).truncatingRemainder(dividingBy: 360)
        return ((raDeg + 360).truncatingRemainder(dividingBy: 360), dec * r2d)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GnomonicProjectionTests`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/PlateSolve/WCS.swift Sources/LiveAstroCore/PlateSolve/GnomonicProjection.swift Tests/LiveAstroCoreTests/GnomonicProjectionTests.swift
git commit -m "feat: WCS type + gnomonic (TAN) projection with round-trip test

Standard tangent-plane project/deproject for the plate-solver; round-trip
holds to 1e-7 deg across mid-sky, near-pole, and RA-seam centers.

Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j"
```

---

### Task 2: `PlateSolver.solve` + synthetic gate

**Files:** Create `PlateSolver.swift`, `Tests/.../PlateSolverTests.swift`.

**Interfaces:**
- Consumes: `GnomonicProjection`, `WCS` (Task 1); `StarCatalog.stars(nearRA:dec:radiusDegrees:)`, `StarCatalog.encode` (sub-project 1); `Star`, `TriangleMatcher.correspondences`, `TransformSolver.solve`/`.inliers`, `SimilarityTransform.apply`.
- Produces: `enum PlateSolver { static func solve(stars: [Star], width: Int, height: Int, pixelScaleArcsec: Double, approxCenterRA: Double, approxCenterDec: Double, catalog: StarCatalog, minInliers: Int = 8) -> WCS? }`.

**The synthetic round-trip is the oracle.** `projectThroughWCS` (in the test) is the exact inverse of `solve`'s grid step: it places a catalog star at the pixel where a camera with that WCS would see it. `solve` must recover the WCS that generated the frame.

- [ ] **Step 1: Write the failing synthetic-gate test**

Create `Tests/LiveAstroCoreTests/PlateSolverTests.swift`:

```swift
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

    private func syntheticCatalog(cra: Double, cdec: Double, n: Int) -> StarCatalog {
        var stars: [CatalogStar] = []
        var seed: UInt64 = 0xABCDEF
        for _ in 0..<n {
            seed = seed &* 6364136223846793005 &+ 1
            let dra = (Double((seed >> 33) & 0xFFFF)/65535 - 0.5) * 3.0 / cos(cdec * .pi/180)
            seed = seed &* 6364136223846793005 &+ 1
            let ddec = (Double((seed >> 33) & 0xFFFF)/65535 - 0.5) * 3.0
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
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PlateSolverTests`
Expected: FAIL to compile — no `PlateSolver`.

- [ ] **Step 3: Implement `PlateSolver.solve`**

Create `Sources/LiveAstroCore/PlateSolve/PlateSolver.swift`:

```swift
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
        // Frame is the grid rotated by +rotationDegrees; the frame→grid transform rotates by -that.
        var rotDeg = -win.t.rotation * 180 / .pi
        if win.mirrored { rotDeg = -rotDeg }
        rotDeg = (rotDeg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        if rotDeg > 180 { rotDeg -= 360 }
        return WCS(centerRA: center.ra, centerDec: center.dec, rotationDegrees: rotDeg,
                   pixelScaleArcsec: pixelScaleArcsec, parity: win.mirrored, inlierCount: win.inliers)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PlateSolverTests`
Expected: PASS (3 tests: normal parity, mirrored parity, too-few-stars).
NOTE (research reconciliation): if `testSolvesSynthetic*` fails on center/rotation/parity, the gnomonic project/deproject are FIXED (Task 1, tested) — reconcile ONLY the grid-orientation (`gx`/`gy` sign, mirror), and rotation-sign (`rotDeg = ±...`, and the `if win.mirrored` flip) lines between `solve` and the test's `projectThroughWCS` so the round-trip closes. Do NOT loosen the 60″/0.2° tolerances. If after honest reconciliation the round-trip still won't close within tolerance, STOP and report BLOCKED — that is the feasibility gate failing and must be escalated, not hidden.

- [ ] **Step 5: Add the gated real-frame test**

Add to `PlateSolverTests`:

```swift
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
        let raw = try FITSReader.read(Data(contentsOf: first), normalizeRowOrder: false)
        // approx center + scale + CRVAL from the header
        let hdr = try FITSReader.readHeader(Data(contentsOf: first)).keywords
        func kv(_ k: String) -> Double? { hdr[k].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
        guard let ra = kv("RA"), let dec = kv("DEC"), let fl = kv("FOCALLEN"), let px = kv("XPIXSZ"),
              let cra = kv("CRVAL1"), let cdec = kv("CRVAL2") else { throw XCTSkip("frame missing WCS keywords") }
        let scale = px / fl * 206.264806
        let lum = raw.luminance()   // grayscale for detection
        let det = StarDetector.detectWithStats(luminance: lum, width: raw.width, height: raw.height, maxStars: 80)
        guard let wcs = PlateSolver.solve(stars: det.stars, width: raw.width, height: raw.height,
                                          pixelScaleArcsec: scale, approxCenterRA: ra, approxCenterDec: dec,
                                          catalog: catalog) else { return XCTFail("real solve returned nil") }
        let sepArcmin = 60 * hypot((wcs.centerRA - cra) * cos(cdec * .pi/180), wcs.centerDec - cdec)
        XCTAssertLessThan(sepArcmin, 10, "solved center \(sepArcmin)′ from CRVAL (\(cra),\(cdec))")
    }
```

(Uses `RawFrame.luminance()` if present; if the grayscale accessor differs, use the frame's channel-0 pixels. Adjust to the actual `FITSReader.read` return + luminance API — this test is env-gated and won't run in CI, so wire it to the real APIs during implementation.)

- [ ] **Step 6: Run the full suite**

Run: `swift test 2>&1 | tail -15`
Expected: all pass; the gated real-frame test XCTSkips (no `LAS_SOLVE_FRAME`).

- [ ] **Step 7: Commit**

```bash
git add Sources/LiveAstroCore/PlateSolve/PlateSolver.swift Tests/LiveAstroCoreTests/PlateSolverTests.swift
git commit -m "feat: PlateSolver near-solve (WCS from catalog match) + synthetic gate

Projects catalog to a north-up grid, matches via TriangleMatcher, fits with
TransformSolver (both parities), derives WCS. Synthetic known-WCS round-trip
recovers center to <1' and rotation to <0.2deg (normal + mirrored); gated
real-M63 check vs CRVAL. Reuses the stacker's registration machinery.

Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j"
```

---

## Self-Review

**Spec coverage:** WCS (T1) ✓; gnomonic project/deproject + round-trip (T1) ✓; PlateSolver.solve pipeline — FOV radius, catalog query, project-to-grid both parities, TriangleMatcher, TransformSolver, inlier gate, WCS derivation (T2) ✓; synthetic-gate round-trip both parities (T2) ✓; degenerate→nil (T2) ✓; gated real-frame vs CRVAL (T2) ✓; near-solve only / reuse machinery / non-goals ✓.

**Placeholder scan:** the real-frame test notes an API-reconciliation step (`luminance()` / `FITSReader.read` shape) — flagged explicitly as an env-gated wire-up, not a code hole; every other step has complete code.

**Type consistency:** `WCS(centerRA:centerDec:rotationDegrees:pixelScaleArcsec:parity:inlierCount:)`, `GnomonicProjection.project/deproject`, `PlateSolver.solve(...)`, `Star(x:y:flux:)`, `TriangleMatcher.correspondences(source:target:)`, `TransformSolver.solve(source:target:pairs:)` / `.inliers(_:source:target:pairs:tolerance:)`, `SimilarityTransform.apply(x:y:)`, `StarCatalog.stars(nearRA:dec:radiusDegrees:)` / `.encode` — consistent across tasks. arcsec/rad `206264.806247` identical in solver + test.

## Note for after this sub-project
Sub-project 3 wires this in: expose `StackEngine.referenceStars`, compute scale (`FOCALLEN`/`XPIXSZ`) + approx center (`RA`/`DEC`) from the reference frame's metadata, run `PlateSolver.solve` off the hot path at seed/reseed, and apply `WCS.rotationDegrees` to rotate the display/master north-up (+ the packaging bundle-copy fix so `bundled()` works in shipped builds). Also generate the real Gaia catalog for the gated real-frame test to run.
