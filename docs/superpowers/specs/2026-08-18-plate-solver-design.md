# Plate-Solver (plate-solve sub-project 2) — Design

**Date:** 2026-08-18 · **Status:** approved (design, near-solve), pending spec review
**Parent pillar:** native plate-solve / north-up (catalog ✓ → **solver** → apply-north-up).
**Goal:** Recover a reference frame's WCS (center RA/Dec + rotation) by matching its detected stars
against the bundled Gaia DR3 catalog, given the FITS approximate center + known pixel scale.

## Core idea

Plate-solving = **register the reference frame against the catalog** instead of against the previous
frame. It reuses the existing stacking machinery: `StarDetector` (already produces the frame's stars),
`TriangleMatcher.correspondences` (rotation/scale/translation-invariant star matching), and
`TransformSolver.solve` (Umeyama similarity fit). Known-scale near-solve: the FITS header gives an
approximate center (`RA`/`DEC`) and the pixel scale (`FOCALLEN`/`XPIXSZ`), so we only recover the
residual rotation + refined center — no blind all-sky search.

## Scope (this sub-project)

The **pure solver**: `WCS`, a gnomonic tangent-plane projection, and `PlateSolver.solve(...)` — a
free function taking explicit inputs (frame stars, image size, pixel scale, approx center, catalog)
and returning a `WCS?`. NO pipeline wiring (exposing `StackEngine.referenceStars`, computing scale
from metadata, triggering the solve off the hot path) and NO rotation/UI — those are sub-project 3.

## Components (`Sources/LiveAstroCore/PlateSolve/`)

- **`WCS`** — `struct WCS: Equatable { let centerRA: Double; let centerDec: Double;
  let rotationDegrees: Double; let pixelScaleArcsec: Double; let parity: Bool; let inlierCount: Int }`
  (degrees; `rotationDegrees` = the image-up position angle relative to north; `parity` = mirrored).
- **`GnomonicProjection`** — the standard TAN projection about a tangent point:
  - `project(ra:dec:centerRA:centerDec:) -> (xi: Double, eta: Double)` — celestial → tangent-plane
    standard coords (radians): `cosc = sin(dec0)sin(dec)+cos(dec0)cos(dec)cos(ra−ra0)`,
    `xi = cos(dec)sin(ra−ra0)/cosc`, `eta = (cos(dec0)sin(dec)−sin(dec0)cos(dec)cos(ra−ra0))/cosc`.
  - `deproject(xi:eta:centerRA:centerDec:) -> (ra: Double, dec: Double)` — the inverse (for refining
    the true center from the solved image-center grid position).
- **`PlateSolver`** — `static func solve(stars: [Star], width: Int, height: Int,
  pixelScaleArcsec: Double, approxCenterRA: Double, approxCenterDec: Double, catalog: StarCatalog,
  minInliers: Int = 8) -> WCS?`.

## Algorithm (`PlateSolver.solve`)

1. **FOV radius:** `radiusDeg = 0.5 * hypot(width, height) * pixelScaleArcsec / 3600 * 1.2` (diagonal
   half-FOV + 20% margin). `catalog.stars(nearRA: approxCenterRA, dec: approxCenterDec,
   radiusDegrees: radiusDeg)`. If fewer than `minInliers`+2 catalog stars → nil.
2. **Project catalog → a north-up pixel grid** at the FRAME's pixel scale (so the frame↔grid transform
   is scale ≈ 1, satisfying `TransformSolver`'s [0.5,2.0] scale guard). For each catalog star:
   `(xi,eta)=project(...)`; grid position `gx = width/2 + (xi * 206264.8 / pixelScaleArcsec)`,
   `gy = height/2 − (eta * 206264.8 / pixelScaleArcsec)`; wrap as `Star(x: gx, y: gy, flux: 1/mag-ish)`.
   Build TWO grids: normal and **mirrored** (`gx → width − gx`) — `TransformSolver` is rotation-only
   (no reflection), so parity is resolved by trying both.
3. **Match + solve, each parity:** `TriangleMatcher.correspondences(source: stars, target: grid)` →
   `TransformSolver.solve(source: stars, target: grid, pairs:)` → `SimilarityTransform?` (frame→grid).
   Count inliers (`TransformSolver.inliers`, tolerance ~a few px). Keep the parity with more inliers.
4. **Gate:** if the best fit has `< minInliers` inliers (or no transform) → nil ("couldn't solve").
5. **Derive WCS:** `rotationDegrees` = the transform's rotation (deg), adjusted for parity; map the
   image center `(width/2, height/2)` through the transform to grid coords `(gcx, gcy)`, convert back
   to `(xi,eta)` and `deproject(...)` → refined `centerRA/centerDec`. `pixelScaleArcsec` passes
   through; `inlierCount` = the winning inlier count.

## Feasibility gate first (the research risk)

The uncertain part is whether the triangle-match + Umeyama reliably recovers the WCS. Validate
**synthetically before trusting real frames**, and fail-fast:
- **Synthetic round-trip (the gate):** build a synthetic `StarCatalog` (~30 stars at known RA/Dec
  around a center); pick a known WCS (center, rotation, scale); project those catalog stars THROUGH
  the WCS to frame pixel coords (+ small position noise + a few spurious non-catalog stars); run
  `solve` and assert the recovered center is within ~arcsec and rotation within ~0.1° of the known
  WCS — for BOTH a normal and a mirrored (parity) synthetic frame.
- If the synthetic gate can't be met, STOP and rethink before building further — do not push to real
  frames on a broken algorithm.

## Testing

- **Gnomonic round-trip:** `deproject(project(ra,dec,...),...) == (ra,dec)` to ~1e-6° across a range
  incl. near-pole and RA-seam centers.
- **Synthetic solve (the gate):** known WCS recovered to arcsec/0.1° (normal + mirrored parity);
  spurious stars + noise tolerated.
- **Degenerate → nil:** too few catalog stars, no triangle matches, or inliers < `minInliers` → nil.
- **Gated real-frame (env `LAS_SOLVE_FRAME` + real catalog):** load an M63 sub (`~/Desktop/M63-import`),
  `StarDetector.detectWithStats`, compute scale from `FOCALLEN`/`XPIXSZ`, `approxCenter` from `RA`/`DEC`,
  solve, and assert the recovered center matches the frame's `CRVAL1`/`CRVAL2` (the ASIAIR's own
  plate-solved answer) to within a few arcmin. `XCTSkip` when the env/real-catalog/frame is absent
  (the synthetic gate covers the algorithm; this is the real-world confirmation).

## Non-goals (this sub-project)

- Blind solving with no prior center (the rigs always write `RA`/`DEC`; near-solve only).
- Lens distortion / SIP polynomial terms (a single similarity transform suffices at these FOVs).
- Pipeline wiring: exposing `referenceStars`, computing scale from metadata, triggering the solve at
  session/reseed time — sub-project 3.
- Any image rotation / north-up / UI — sub-project 3.
- Per-frame solving (the reference solves once; the stack inherits it).

## Expected result

`PlateSolver.solve(...)` returns a `WCS` (center + rotation + parity + inlier confidence) for a real
reference frame, or nil when it can't confidently solve — proven byte-exactly on synthetic ground
truth and confirmed against the M63 frames' `CRVAL` when the real catalog is generated. Reuses the
stacker's own star-matching machinery; zero new dependencies.
