# Per-Sub Gradient Leveling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Level each accepted sub, per channel, so its low-order background surface matches the seed reference before the weighted combine — flattening inter-sub gradient differences that master-DBE can't fix and that corrupt σ-clip.

**Architecture:** Refactor `BackgroundExtraction.flatten` to expose a reusable `BackgroundModel` (fit per-channel polynomial coefficients → evaluate surface). A new pure `GradientLeveler` subtracts the *difference* of a sub's model and the reference's model (per channel, clamped). `StackEngine` captures the reference model at seed and applies the leveler **before** rejection + weighted add in both the live `process` and staged `commit` paths. A `normalization` flag defaults off (byte-identical); the app defaults it on via a toggle.

**Tech Stack:** Swift 5.10 SPM (LiveAstroCore: Foundation/CoreGraphics/Accelerate only), SwiftUI app, Python 3 + numpy for the Task-1 prototype (not shipped).

## Global Constraints

- Swift 5.10, macOS 14+. `LiveAstroCore` imports Foundation / CoreGraphics / Accelerate only. Zero external dependencies.
- Stacking-core (linear master) feature — NOT the display path. Reuse `BackgroundExtraction`'s fit machinery; do not duplicate it.
- Additive, per-channel, low-order (degree 1–2) only. Reference-matched: subtract `model_f − model₀`; never flatten-to-zero.
- Deterministic. Leveling OFF (`normalization: false`) is **byte-identical** to the pre-change stack — regression-guarded. The refactored `flatten` is **byte-identical** to the current `flatten` — guarded by the existing `BackgroundExtractionTests`.
- Leveling runs BEFORE rejection and BEFORE the weighted add, in both `process` (live) and `commit` (import). Composes with frame weighting and the display-path DBE.
- Baseline model captured at seed, reset to nil at EVERY reseed path (manual `reseed()` and the auto-reseed block) — same discipline as `weightBaseline`.
- The polynomial degree comes from Task 1's validated report; the plan's starting degree is 1.
- Core logic TDD'd; the Python prototype is a validation artifact; app/UI is build-verified.
- Branch: `feature/gradient-leveling` off `main`. Spec: `docs/superpowers/specs/2026-07-12-gradient-leveling-design.md`.

---

## Task 1: Python prototype — validate the win + fix the degree

**Files:**
- Create: `scratchpad/gradient_leveling.py` (NOT shipped — scratchpad is git-ignored)

This task's "test" is the validation gate: reference-matched per-sub polynomial leveling must flatten the stacked master's large-scale gradient (and not hurt SNR) on synthetic subs with DIFFERING/moving gradients — and beat the scalar baseline. If the gate fails for both degree 1 and 2, report BLOCKED.

- [ ] **Step 1: Write the prototype**

```python
# scratchpad/gradient_leveling.py
import numpy as np
rng = np.random.default_rng(7)
H = W = 120; C = 3; N = 24

stars = np.zeros((H, W, C))
for _ in range(40):
    y, x = rng.integers(6, H-6), rng.integers(6, W-6); a = rng.uniform(.3, .9)
    yy, xx = np.mgrid[y-4:y+5, x-4:x+5]
    stars[y-4:y+5, x-4:x+5, :] += a * np.exp(-((yy-y)**2 + (xx-x)**2)/4)[..., None]

# normalized coords [-1,1]
ny, nx = np.mgrid[0:H, 0:W]
nx = nx / (W-1) * 2 - 1; ny = ny / (H-1) * 2 - 1

def make(i):
    # a linear sky gradient whose direction+slope DRIFT across the session (moonrise sweep),
    # plus a per-channel base pedestal + noise.
    ang = 2 * np.pi * i / N
    slope = 0.05 * (i / N)
    grad = slope * (np.cos(ang) * nx + np.sin(ang) * ny)   # H,W
    ped = np.array([.05, .04, .03])
    return np.clip(stars + grad[..., None] + ped[None, None, :] + rng.normal(0, .01, (H, W, C)), 0, 1)

subs = [make(i) for i in range(N)]

def basis(px, py, deg):
    return [np.ones_like(px), px, py] if deg == 1 else [np.ones_like(px), px, py, px*px, px*py, py*py]

def fit_coeffs(sub_c, deg, tiles=16):
    # tile medians → sigma-clip bright → least squares (mirrors BackgroundExtraction.flatten)
    txs, tys, tvs = [], [], []
    for ty in range(tiles):
        y0, y1 = ty*H//tiles, (ty+1)*H//tiles
        for tx in range(tiles):
            x0, x1 = tx*W//tiles, (tx+1)*W//tiles
            if y1 <= y0 or x1 <= x0: continue
            tvs.append(np.median(sub_c[y0:y1, x0:x1]))
            txs.append(((x0+x1)/2)/W*2 - 1); tys.append(((y0+y1)/2)/H*2 - 1)
    txs, tys, tvs = map(np.array, (txs, tys, tvs))
    keep = np.ones(len(tvs), bool)
    for _ in range(3):
        v = tvs[keep]
        if v.size <= 6: break
        med = np.median(v); madn = 1.4826*np.median(np.abs(v-med))
        if madn <= 1e-12: break
        keep &= tvs <= med + 2.0*madn
    B = np.stack(basis(txs[keep], tys[keep], deg), 1)
    coeff, *_ = np.linalg.lstsq(B, tvs[keep], rcond=None)
    return coeff

def surface(coeff, deg):
    B = np.stack([b.ravel() for b in basis(nx, ny, deg)], 1)
    return (B @ coeff).reshape(H, W)

def combine(subs, level, deg):
    ref = [fit_coeffs(subs[0][..., c], deg) for c in range(C)] if level else None
    acc = np.zeros((H, W, C))
    for s in subs:
        f = s.copy()
        if level:
            for c in range(C):
                diff = fit_coeffs(s[..., c], deg) - ref[c]
                f[..., c] = np.clip(s[..., c] - surface(diff, deg), 0, 1)
        acc += f
    return acc / len(subs)

def corner_delta(m):
    tl = m[:H//3, :W//3].reshape(-1, C).mean(0); br = m[2*H//3:, 2*W//3:].reshape(-1, C).mean(0)
    return float(np.mean(np.abs(br - tl)))
def row_grad_rms(m):
    rows = m.reshape(H, -1).mean(1); return float(np.sqrt(np.mean(np.diff(rows)**2)))

off = combine(subs, False, 1)
for deg in (1, 2):
    on = combine(subs, True, deg)
    print(f"[deg {deg}] corner_delta off={corner_delta(off):.5f} on={corner_delta(on):.5f} "
          f"({100*(corner_delta(on)-corner_delta(off))/corner_delta(off):+.1f}%)  "
          f"row_grad_rms off={row_grad_rms(off):.5f} on={row_grad_rms(on):.5f} "
          f"({100*(row_grad_rms(on)-row_grad_rms(off))/row_grad_rms(off):+.1f}%)")
```

- [ ] **Step 2: Run it**

Run: `python3 scratchpad/gradient_leveling.py`
Expected: for at least one degree, `on` corner_delta AND row_grad_rms are meaningfully LOWER than `off` (leveling flattens the master's large-scale gradient). Example acceptance: both metrics improve (negative %) by a clear margin (unlike the scalar version which was 0.0%).

- [ ] **Step 3: Record the verdict**

If leveling flattens the master, record the chosen degree (prefer degree 1 if it already wins clearly — lower risk of eating signal; else degree 2) and the deltas. If NEITHER degree improves both metrics, STOP and report BLOCKED with the numbers.

- [ ] **Step 4: Commit the artifact**

```bash
git add scratchpad/gradient_leveling.py
git commit -m "prototype: validate per-sub reference-matched gradient leveling"
```

**Deliverable for later tasks:** the chosen degree (1 unless the prototype selects 2). T4's fit uses it.

---

## Task 2: `BackgroundExtraction` → expose `BackgroundModel` (byte-identical refactor)

**Files:**
- Modify: `Sources/LiveAstroCore/Imaging/BackgroundExtraction.swift`
- Test: `Tests/LiveAstroCoreTests/BackgroundModelTests.swift`

**Interfaces:**
- Consumes: existing `BackgroundExtraction.flatten(_:degree:tilesPerAxis:rejectionSigma:)`, `solveSymmetric(_:_:)`, `AstroImage`.
- Produces: `struct BackgroundExtraction.BackgroundModel { degree; width; height; coeffPerChannel: [[Double]?] }` with `rawSurface(channel:) -> [Float]?` and `static func evaluate(coeff:degree:width:height:) -> [Float]`; `static func fitBackground(_:degree:tilesPerAxis:rejectionSigma:) -> BackgroundModel`.

**Context:** the current `flatten` (Sources/LiveAstroCore/Imaging/BackgroundExtraction.swift:10-99) does: sanitize → per channel {tile medians → σ-clip bright tiles → least-squares solve → evaluate surface → subtract surface + pedestal(min)}. Split the fit (sanitize + tile/σ-clip/solve) into `fitBackground`, the surface eval into `evaluate`/`rawSurface`, and reimplement `flatten` on top so it is byte-identical (the existing `BackgroundExtractionTests` are the parity guard). `flatten` keeps its exact signature. **Do not change** `flatten`'s arithmetic (same normalized-coord basis `x,y ∈ [-1,1]` via `coord/dim*2-1` — NOTE `evaluate` must use the SAME mapping `Double(xx)/Double(w)*2-1` as `flatten` step 4, NOT `(xx)/(w-1)`).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/LiveAstroCoreTests/BackgroundModelTests.swift
import XCTest
@testable import LiveAstroCore

final class BackgroundModelTests: XCTestCase {
    // 3-channel image with a known linear gradient in channel 0 (ch1/ch2 flat).
    func gradientImage(_ w: Int, _ h: Int) -> AstroImage {
        var px = [Float](repeating: 0.1, count: w * h * 3)
        for y in 0..<h { for x in 0..<w {
            px[y*w + x] = 0.1 + 0.4 * Float(x) / Float(w - 1)     // ch0: left→right ramp
        } }
        return AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
    }

    func testFitBackgroundReturnsDegree1CoeffsPerChannel() {
        let m = BackgroundExtraction.fitBackground(gradientImage(64, 64), degree: 1)
        XCTAssertEqual(m.degree, 1); XCTAssertEqual(m.coeffPerChannel.count, 3)
        XCTAssertNotNil(m.coeffPerChannel[0])                     // ch0 fit succeeded
        XCTAssertEqual(m.coeffPerChannel[0]!.count, 3)            // [1, x, y]
        XCTAssertGreaterThan(m.coeffPerChannel[0]![1], 0.1)       // positive x-slope for a left→right ramp
    }

    func testRawSurfaceReconstructsTheGradient() {
        let m = BackgroundExtraction.fitBackground(gradientImage(64, 64), degree: 1)
        let s = m.rawSurface(channel: 0)!
        // surface should rise left→right, spanning ~0.4 across the width
        XCTAssertGreaterThan(s[63], s[0] + 0.3)
    }

    func testEvaluateZeroCoeffsIsFlatZero() {
        let s = BackgroundExtraction.BackgroundModel.evaluate(coeff: [0, 0, 0], degree: 1, width: 8, height: 8)
        XCTAssertTrue(s.allSatisfy { $0 == 0 })
    }

    func testFlattenStillMatchesFitPlusEvaluate() {
        // The refactored flatten must equal fit→evaluate→subtract-surface+pedestal.
        let img = gradientImage(48, 48)
        let flat = BackgroundExtraction.flatten(img, degree: 1)
        // reconstruct manually from the model
        let m = BackgroundExtraction.fitBackground(img, degree: 1)
        let s = m.rawSurface(channel: 0)!
        let ped = s.min()!
        let plane = 48 * 48
        for i in 0..<plane {
            let expected = min(max(img.pixels[i] - s[i] + ped, 0), 1)
            XCTAssertEqual(flat.pixels[i], expected, accuracy: 1e-6)
        }
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter BackgroundModelTests`
Expected: FAIL — `fitBackground` / `BackgroundModel` not found.

- [ ] **Step 3: Add `BackgroundModel`, `fitBackground`, `evaluate`, `rawSurface`**

Add inside `enum BackgroundExtraction` (above `flatten`):

```swift
    /// A fitted per-channel low-order polynomial background (degree 1 or 2).
    /// `coeffPerChannel[c] == nil` means that channel could not be fit (too few
    /// sky tiles or singular) — callers treat it as passthrough.
    public struct BackgroundModel {
        public let degree: Int
        public let width: Int
        public let height: Int
        public let coeffPerChannel: [[Double]?]

        /// Raw polynomial surface for one channel (no pedestal), or nil if unfit.
        public func rawSurface(channel: Int) -> [Float]? {
            guard channel < coeffPerChannel.count, let c = coeffPerChannel[channel] else { return nil }
            return BackgroundModel.evaluate(coeff: c, degree: degree, width: width, height: height)
        }

        /// Evaluate a coefficient vector over a width×height grid at normalized
        /// coords x,y ∈ [-1,1] (SAME mapping as flatten: coord/dim*2 − 1).
        public static func evaluate(coeff: [Double], degree: Int, width w: Int, height h: Int) -> [Float] {
            let deg = min(max(degree, 1), 2)
            var surface = [Float](repeating: 0, count: w * h)
            for yy in 0..<h {
                let ny = Double(yy) / Double(h) * 2 - 1
                for xx in 0..<w {
                    let nx = Double(xx) / Double(w) * 2 - 1
                    let bb: [Double] = deg == 1 ? [1, nx, ny] : [1, nx, ny, nx*nx, nx*ny, ny*ny]
                    var s = 0.0; for r in 0..<bb.count { s += coeff[r] * bb[r] }
                    surface[yy*w + xx] = Float(s)
                }
            }
            return surface
        }
    }

    /// Fit a per-channel low-order polynomial background (steps 1–3 of flatten):
    /// tile medians → σ-clip bright tiles → least-squares. 3-channel only (others
    /// get all-nil coeffs). Deterministic; NaN/Inf sanitized up front.
    public static func fitBackground(_ image: AstroImage, degree: Int,
                                     tilesPerAxis: Int = 32,
                                     rejectionSigma: Double = 2.0) -> BackgroundModel {
        let w = image.width, h = image.height, plane = w * h
        let deg = min(max(degree, 1), 2)
        let nCoeff = deg == 1 ? 3 : 6
        guard image.channels == 3 else {
            return BackgroundModel(degree: deg, width: w, height: h,
                                   coeffPerChannel: Array(repeating: nil, count: image.channels))
        }
        let tiles = max(1, tilesPerAxis)
        func basis(_ x: Double, _ y: Double) -> [Double] { deg == 1 ? [1, x, y] : [1, x, y, x*x, x*y, y*y] }
        let src = image.pixels.map { $0.isFinite ? $0 : Float(0) }
        var coeffs = [[Double]?](repeating: nil, count: 3)
        for c in 0..<3 {
            let base = c * plane
            var sx: [Double] = [], sy: [Double] = [], sv: [Double] = []
            sx.reserveCapacity(tiles*tiles); sy.reserveCapacity(tiles*tiles); sv.reserveCapacity(tiles*tiles)
            for ty in 0..<tiles {
                let y0 = ty * h / tiles, y1 = (ty + 1) * h / tiles
                if y1 <= y0 { continue }
                for tx in 0..<tiles {
                    let x0 = tx * w / tiles, x1 = (tx + 1) * w / tiles
                    if x1 <= x0 { continue }
                    var vals: [Float] = []; vals.reserveCapacity((y1-y0)*(x1-x0))
                    for yy in y0..<y1 { for xx in x0..<x1 { vals.append(src[base + yy*w + xx]) } }
                    vals.sort()
                    sx.append((Double(x0 + x1) / 2) / Double(w) * 2 - 1)
                    sy.append((Double(y0 + y1) / 2) / Double(h) * 2 - 1)
                    sv.append(Double(vals[vals.count/2]))
                }
            }
            var keep = [Bool](repeating: true, count: sv.count)
            for _ in 0..<3 {
                let kept = sv.enumerated().filter { keep[$0.offset] }.map { $0.element }
                if kept.count <= nCoeff { break }
                let sorted = kept.sorted(); let med = sorted[sorted.count/2]
                var dev = sorted.map { abs($0 - med) }; dev.sort()
                let madn = 1.4826 * dev[dev.count/2]
                if madn <= 1e-12 { break }
                let hiCut = med + rejectionSigma * madn
                var changed = false
                for i in 0..<sv.count where keep[i] && sv[i] > hiCut { keep[i] = false; changed = true }
                if !changed { break }
            }
            let idx = (0..<sv.count).filter { keep[$0] }
            guard idx.count >= nCoeff else { continue }
            var ata = [[Double]](repeating: [Double](repeating: 0, count: nCoeff), count: nCoeff)
            var atb = [Double](repeating: 0, count: nCoeff)
            for i in idx {
                let b = basis(sx[i], sy[i]); let v = sv[i]
                for r in 0..<nCoeff { atb[r] += b[r] * v; for col in 0..<nCoeff { ata[r][col] += b[r] * b[col] } }
            }
            guard let coeff = solveSymmetric(&ata, atb), coeff.allSatisfy({ $0.isFinite }) else { continue }
            coeffs[c] = coeff
        }
        return BackgroundModel(degree: deg, width: w, height: h, coeffPerChannel: coeffs)
    }
```

Then reimplement `flatten` on top (replace its body, keep the signature):

```swift
    public static func flatten(_ image: AstroImage, degree: Int,
                               tilesPerAxis: Int = 32,
                               rejectionSigma: Double = 2.0) -> AstroImage {
        guard image.channels == 3 else { return image }
        let w = image.width, h = image.height, plane = w * h
        let model = fitBackground(image, degree: degree, tilesPerAxis: tilesPerAxis, rejectionSigma: rejectionSigma)
        let src = image.pixels.map { $0.isFinite ? $0 : Float(0) }
        var out = src
        for c in 0..<3 {
            guard let surface = model.rawSurface(channel: c) else { continue }   // passthrough this channel
            let base = c * plane
            let ped = surface.min() ?? 0
            for i in 0..<plane { out[base + i] = min(max(src[base + i] - surface[i] + ped, 0), 1) }
        }
        return AstroImage(width: w, height: h, channels: image.channels, pixels: out, sourceIsLinear: image.sourceIsLinear)
    }
```

- [ ] **Step 4: Run to verify they pass — including existing flatten parity**

Run: `swift test --filter 'BackgroundModelTests|BackgroundExtractionTests'`
Expected: PASS. The existing `BackgroundExtractionTests` (unchanged) prove `flatten` is byte-identical to before the refactor. If any existing flatten test fails, the refactor diverged — fix until green.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Imaging/BackgroundExtraction.swift Tests/LiveAstroCoreTests/BackgroundModelTests.swift
git commit -m "refactor: expose BackgroundModel (fit/evaluate) from BackgroundExtraction; flatten byte-identical (TDD)"
```

---

## Task 3: `GradientLeveler` — subtract the model difference

**Files:**
- Create: `Sources/LiveAstroCore/Stacking/GradientLeveler.swift`
- Test: `Tests/LiveAstroCoreTests/GradientLevelerTests.swift`

**Interfaces:**
- Consumes: `BackgroundExtraction.BackgroundModel` (Task 2), `BackgroundExtraction.BackgroundModel.evaluate(coeff:degree:width:height:)`, `Parallel.rows`, `AstroImage`.
- Produces: `GradientLeveler.apply(_ image: AstroImage, subModel: BackgroundExtraction.BackgroundModel, refModel: BackgroundExtraction.BackgroundModel, minRows: Int = 64) -> AstroImage`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/LiveAstroCoreTests/GradientLevelerTests.swift
import XCTest
@testable import LiveAstroCore

final class GradientLevelerTests: XCTestCase {
    typealias Model = BackgroundExtraction.BackgroundModel
    func img(_ w: Int, _ h: Int, _ px: [Float]) -> AstroImage {
        AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
    }

    func testIdenticalModelsAreByteIdentical() {
        let a = img(2, 2, (0..<12).map { Float($0) / 12 })
        let m = Model(degree: 1, width: 2, height: 2, coeffPerChannel: [[0.1, 0.2, 0.0], [0, 0, 0], [0, 0, 0]])
        XCTAssertEqual(GradientLeveler.apply(a, subModel: m, refModel: m).pixels, a.pixels)
    }

    func testSubtractsModelDifferenceForChannel() {
        // 2x1x3, ch0 flat 0.5. Sub model ch0 has a constant +0.1 more than ref → subtract 0.1.
        let a = img(2, 1, 3, [0.5, 0.5, 0.3, 0.3, 0.2, 0.2])
        let sub = Model(degree: 1, width: 2, height: 1, coeffPerChannel: [[0.1, 0, 0], nil, nil])
        let ref = Model(degree: 1, width: 2, height: 1, coeffPerChannel: [[0.0, 0, 0], nil, nil])
        let out = GradientLeveler.apply(a, subModel: sub, refModel: ref)
        XCTAssertEqual(out.pixels[0], 0.4, accuracy: 1e-6)        // ch0: 0.5 - (0.1-0.0) = 0.4
        XCTAssertEqual(out.pixels[1], 0.4, accuracy: 1e-6)
        XCTAssertEqual(out.pixels[2], 0.3, accuracy: 1e-6)        // ch1 nil coeff → passthrough
    }

    func testNilCoeffChannelPassesThrough() {
        let a = img(1, 1, 3, [0.5, 0.6, 0.7])
        let sub = Model(degree: 1, width: 1, height: 1, coeffPerChannel: [nil, [0.2, 0, 0], nil])
        let ref = Model(degree: 1, width: 1, height: 1, coeffPerChannel: [[0.1, 0, 0], nil, nil])
        let out = GradientLeveler.apply(a, subModel: sub, refModel: ref)
        // ch0 ref-only or sub-nil → passthrough; ch1 ref nil → passthrough; ch2 both nil → passthrough
        XCTAssertEqual(out.pixels, [0.5, 0.6, 0.7])
    }

    func testClampsToUnitRange() {
        let a = img(1, 1, 3, [0.05, 0.95, 0.5])
        let sub = Model(degree: 1, width: 1, height: 1, coeffPerChannel: [[0.2, 0, 0], [-0.2, 0, 0], [0, 0, 0]])
        let ref = Model(degree: 1, width: 1, height: 1, coeffPerChannel: [[0, 0, 0], [0, 0, 0], [0, 0, 0]])
        let out = GradientLeveler.apply(a, subModel: sub, refModel: ref)
        XCTAssertEqual(out.pixels[0], 0.0, accuracy: 1e-6)        // 0.05 - 0.2 → clamp 0
        XCTAssertEqual(out.pixels[1], 1.0, accuracy: 1e-6)        // 0.95 - (-0.2) → clamp 1
    }

    func testParallelEqualsSerial() {
        let n = 200
        let px = (0..<(n*n*3)).map { Float($0 % 100) / 100 }
        let a = img(n, n, px)
        let sub = Model(degree: 2, width: n, height: n, coeffPerChannel: [[0.1, 0.05, 0.02, 0.01, 0, 0], [0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0]])
        let ref = Model(degree: 2, width: n, height: n, coeffPerChannel: [[0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0]])
        XCTAssertEqual(GradientLeveler.apply(a, subModel: sub, refModel: ref, minRows: .max).pixels,
                       GradientLeveler.apply(a, subModel: sub, refModel: ref, minRows: 1).pixels)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter GradientLevelerTests`
Expected: FAIL — `GradientLeveler` not found.

- [ ] **Step 3: Implement**

```swift
// Sources/LiveAstroCore/Stacking/GradientLeveler.swift
import Foundation

/// Reference-matched per-sub background leveling (spec: gradient leveling).
/// For each channel where BOTH the sub and reference models have coefficients,
/// subtracts the difference surface (coeff_sub − coeff_ref) and clamps to [0,1].
/// A channel with either coeff missing is passthrough. Identical models return
/// the frame byte-identical. Deterministic; parallel over row bands.
public enum GradientLeveler {
    public static func apply(_ image: AstroImage,
                             subModel: BackgroundExtraction.BackgroundModel,
                             refModel: BackgroundExtraction.BackgroundModel,
                             minRows: Int = 64) -> AstroImage {
        let w = image.width, h = image.height, chans = image.channels, plane = w * h
        let deg = subModel.degree
        var out = image.pixels
        out.withUnsafeMutableBufferPointer { buf in
            for c in 0..<chans {
                guard c < subModel.coeffPerChannel.count, c < refModel.coeffPerChannel.count,
                      let cs = subModel.coeffPerChannel[c], let cr = refModel.coeffPerChannel[c] else { continue }
                let diff = zip(cs, cr).map { $0 - $1 }
                if diff.allSatisfy({ $0 == 0 }) { continue }        // identical → passthrough (byte-identical)
                let surface = BackgroundExtraction.BackgroundModel.evaluate(coeff: diff, degree: deg, width: w, height: h)
                let base = c * plane
                Parallel.rows(h, minRows: minRows) { rows in
                    for y in rows {
                        for x in 0..<w {
                            let i = base + y * w + x
                            buf[i] = min(max(buf[i] - surface[y * w + x], 0), 1)
                        }
                    }
                }
            }
        }
        return AstroImage(width: w, height: h, channels: chans, pixels: out, sourceIsLinear: image.sourceIsLinear)
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter GradientLevelerTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Stacking/GradientLeveler.swift Tests/LiveAstroCoreTests/GradientLevelerTests.swift
git commit -m "feat: GradientLeveler — subtract reference-matched model difference (TDD)"
```

---

## Task 4: `StackEngine` — reference model, apply-before-rejection (both paths)

**Files:**
- Modify: `Sources/LiveAstroCore/Stacking/StackEngine.swift`
- Modify: `Sources/LiveAstroCore/Pipeline/BatchImporter.swift`
- Test: `Tests/LiveAstroCoreTests/GradientLevelingEngineTests.swift`

**Interfaces:**
- Consumes: `GradientLeveler.apply(_:subModel:refModel:minRows:)` (Task 3), `BackgroundExtraction.fitBackground(_:degree:)` (Task 2); existing `RegisteredFrame { transform; rgb; weight }`, `commit(image:mask:frameWeight:minRows:)`, `register`, `warp`, `reseed`, `seedReference`.
- Produces: `StackEngine.init(..., frameWeighting: Bool = false, normalization: Bool = false)`; `RegisteredFrame` gains `backgroundModel: BackgroundExtraction.BackgroundModel?`; `commit(image:mask:frameWeight:backgroundModel:minRows:)`.

**Context:** mirror how `frameWeight`/`weightBaseline` are threaded (the recently-shipped frame-weighting pillar). `weightBaseline` is set at the seed sites and reset in `reseed()` + the auto-reseed block; add `backgroundBaseline: BackgroundExtraction.BackgroundModel?` with the SAME lifecycle. The engine has a `degree` for the fit — store the Task-1-validated degree as a constant `static let backgroundDegree = 1` (or 2 if the prototype chose it). Two accumulate paths need the leveler inserted before `rejection.apply`: the live `processLocked` tail, and the staged `commit`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/LiveAstroCoreTests/GradientLevelingEngineTests.swift
import XCTest
@testable import LiveAstroCore

final class GradientLevelingEngineTests: XCTestCase {
    // CFA frame: stars + a linear sky gradient with x-slope `slope` (per-pixel over width).
    func cfaFrame(stars: [(Double, Double)], slope: Float, base: Float = 0.05, w: Int = 256, h: Int = 256) -> RawFrame {
        var px = [Float](repeating: base, count: w * h)
        for y in 0..<h { for x in 0..<w { px[y*w+x] += slope * Float(x) / Float(w-1) } }
        for s in stars {
            for y in max(0, Int(s.1)-6)...min(h-1, Int(s.1)+6) {
                for x in max(0, Int(s.0)-6)...min(w-1, Int(s.0)+6) {
                    let dx = Double(x)-s.0, dy = Double(y)-s.1
                    px[y*w+x] += 0.8 * Float(exp(-(dx*dx+dy*dy)/(2*2.0*2.0)))
                }
            }
        }
        return RawFrame(image: AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true),
                        bayerPattern: .grbg, bottomUp: false, timestamp: Date(timeIntervalSince1970: 0), sourceName: "t.fit")
    }
    let field: [(Double, Double)] = [
        (30,30),(90,60),(150,90),(210,120),(60,150),(120,180),(180,210),(40,200),(200,40),(100,100),
        (160,50),(50,90),(140,140),(80,220),(220,80),(110,30),(30,110),(190,190),(70,70),(150,200)
    ]

    func testRegisterProducesBackgroundModelWhenOn() {
        let eng = StackEngine(normalization: true)
        _ = eng.seedReference(cfaFrame(stars: field, slope: 0.0), minRows: .max)
        let reg = eng.register(cfaFrame(stars: field, slope: 0.10), minRows: .max)
        XCTAssertNotNil(reg?.backgroundModel)
        XCTAssertNotNil(reg?.backgroundModel?.coeffPerChannel[0] ?? nil)
    }

    func testRegisterModelNilWhenOff() {
        let eng = StackEngine(normalization: false)
        _ = eng.seedReference(cfaFrame(stars: field, slope: 0.0), minRows: .max)
        XCTAssertNil(eng.register(cfaFrame(stars: field, slope: 0.10), minRows: .max)?.backgroundModel)
    }

    func testOffPathByteIdentical() {
        // normalization:false must equal a stack that never applies the leveler.
        func run(_ on: Bool) -> [Float] {
            let eng = StackEngine(normalization: on)
            _ = eng.seedReference(cfaFrame(stars: field, slope: 0.0), minRows: .max)
            for _ in 0..<4 {
                if let reg = eng.register(cfaFrame(stars: field, slope: 0.0), minRows: .max) {
                    let (img, mask) = eng.warp(reg, minRows: .max)
                    eng.commit(image: img, mask: mask, frameWeight: reg.weight,
                               backgroundModel: reg.backgroundModel, minRows: .max)
                }
            }
            return eng.currentStack()!.pixels
        }
        // flat-gradient frames identical to the flat reference → leveler subtracts ~0 → within fp tol.
        let off = run(false), on = run(true)
        for (a, b) in zip(off, on) { XCTAssertEqual(a, b, accuracy: 1e-4) }
    }

    func testGradientDifferenceIsLeveledBeforeCombine() {
        // Reference is flat (slope 0). Subs carry a strong x-gradient (slope 0.30). With leveling
        // the stacked master's left→right delta shrinks toward the flat reference; without, it stays.
        func lrDelta(_ on: Bool) -> Float {
            let eng = StackEngine(normalization: on)
            _ = eng.seedReference(cfaFrame(stars: field, slope: 0.0), minRows: .max)
            for _ in 0..<9 {
                if let reg = eng.register(cfaFrame(stars: field, slope: 0.30), minRows: .max) {
                    let (img, mask) = eng.warp(reg, minRows: .max)
                    eng.commit(image: img, mask: mask, frameWeight: reg.weight,
                               backgroundModel: reg.backgroundModel, minRows: .max)
                }
            }
            let m = eng.currentStack()!
            // sky delta: median of a right-edge column band minus a left-edge column band (star-free rows)
            func band(_ xr: Range<Int>) -> Float {
                var v = [Float](); for y in 0..<8 { for x in xr { v.append(m.pixels[y*m.width+x]) } }; v.sort(); return v[v.count/2]
            }
            return band((m.width-8)..<m.width) - band(0..<8)
        }
        let on = lrDelta(true), off = lrDelta(false)
        XCTAssertLessThan(on, off)              // leveled master is flatter (smaller L→R delta)
    }

    func testBaselineResetOnReseed() {
        let eng = StackEngine(normalization: true)
        _ = eng.seedReference(cfaFrame(stars: field, slope: 0.30), minRows: .max)   // sloped baseline
        eng.reseed()
        _ = eng.seedReference(cfaFrame(stars: field, slope: 0.0), minRows: .max)     // flat baseline
        // a flat sub now levels ~0 against the flat baseline (not −0.30 against the old sloped one)
        if let reg = eng.register(cfaFrame(stars: field, slope: 0.0), minRows: .max) {
            let (img, mask) = eng.warp(reg, minRows: .max)
            let before = img.pixels
            eng.commit(image: img, mask: mask, frameWeight: reg.weight, backgroundModel: reg.backgroundModel, minRows: .max)
            // the committed (leveled) frame ≈ the warped frame (flat vs flat → ~no change) at a mid sky pixel
            XCTAssertEqual(eng.currentStack()!.pixels[100*eng.currentStack()!.width + 5], before[100*img.width + 5], accuracy: 0.03)
        } else { XCTFail("register failed") }
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter GradientLevelingEngineTests`
Expected: FAIL — `normalization:` / `backgroundModel` not found.

- [ ] **Step 3: Add the option, baseline field, and degree constant**

In `StackEngine.swift` add next to `frameWeighting`/`weightBaseline`:

```swift
    private let normalization: Bool
    private var backgroundBaseline: BackgroundExtraction.BackgroundModel?   // seed model; reset on reseed
    static let backgroundDegree = 1   // Task-1 validated; bump to 2 only if the prototype chose it
```

Extend `init` (add `normalization`, keep the rest):

```swift
    public init(seedMinStars: Int = 15, minMatches: Int = 8, inlierTolerance: Double = 2.0,
                rejection: RejectionMethod = NoRejection(), autoReseedThreshold: Int = 6,
                frameWeighting: Bool = false, normalization: Bool = false) {
        self.seedMinStars = seedMinStars
        self.minMatches = minMatches
        self.inlierTolerance = inlierTolerance
        self.rejection = rejection
        self.autoReseedThreshold = autoReseedThreshold
        self.frameWeighting = frameWeighting
        self.normalization = normalization
    }
```

- [ ] **Step 4: Capture the reference model at the seed sites; reset on reseed**

At EACH seed site (the `processLocked` `referenceSize == nil` branch and `seedReference`), right after `weightBaseline = (stars.count, sigma)`, add:

```swift
            backgroundBaseline = normalization
                ? BackgroundExtraction.fitBackground(rgb, degree: Self.backgroundDegree) : nil
```

In `reseed()` (after `weightBaseline = nil`) and the auto-reseed block (after `weightBaseline = nil`), add:

```swift
            backgroundBaseline = nil
```

- [ ] **Step 5: Add `backgroundModel` to `RegisteredFrame`, fit it in `register`**

```swift
    public struct RegisteredFrame {
        public let transform: SimilarityTransform
        public let rgb: AstroImage
        public let weight: Float
        public let backgroundModel: BackgroundExtraction.BackgroundModel?   // nil when leveling off
    }
```

At the end of `register`, fit and carry the model:

```swift
        let weight = frameWeight(stars: stars.count, sigma: sigma)
        let bgModel = normalization ? BackgroundExtraction.fitBackground(rgb, degree: Self.backgroundDegree) : nil
        return RegisteredFrame(transform: half, rgb: rgb, weight: weight, backgroundModel: bgModel)
```

- [ ] **Step 6: Apply the leveler BEFORE rejection in `commit` and `process`**

`commit`:

```swift
    public func commit(image: AstroImage, mask: [Float], frameWeight: Float = 1.0,
                       backgroundModel: BackgroundExtraction.BackgroundModel? = nil, minRows: Int) {
        lock.withLock {
            guard let accumulator else { return }
            var frame = image
            if let sub = backgroundModel, let ref = backgroundBaseline {
                frame = GradientLeveler.apply(image, subModel: sub, refModel: ref, minRows: minRows)
            }
            let cleaned = rejection.apply(frame, mask: mask)
            accumulator.add(cleaned, mask: mask, frameWeight: frameWeight, minRows: minRows)
            acceptedCount += 1
            consecutiveNoTransform = 0
        }
    }
```

`processLocked` (live tail), between warp and rejection:

```swift
        let (warped, mask) = Warp.apply(rgb, transform: half.liftedToFullResolution())
        var frame = warped
        if normalization, let ref = backgroundBaseline {
            let subModel = BackgroundExtraction.fitBackground(rgb, degree: Self.backgroundDegree)
            frame = GradientLeveler.apply(warped, subModel: subModel, refModel: ref)
        }
        let cleaned = rejection.apply(frame, mask: mask)
        accumulator.add(cleaned, mask: mask, frameWeight: frameWeight(stars: stars.count, sigma: sigma))
```

- [ ] **Step 7: Thread `backgroundModel` through `BatchImporter`**

In `Sources/LiveAstroCore/Pipeline/BatchImporter.swift`, add to `Work`:

```swift
    private struct Work {
        // ... existing ...
        let frameWeight: Float
        let backgroundModel: BackgroundExtraction.BackgroundModel?
        // ...
    }
```

Where `Work(warped: w, frameWeight: reg.weight, ...)` is built, add `backgroundModel: reg.backgroundModel`. Where the no-warp `Work(warped: nil, frameWeight: 1.0, ...)` is built, add `backgroundModel: nil`. In the consumer `engine.commit(...)` call, add `backgroundModel: work.backgroundModel`.

- [ ] **Step 8: Run the tests**

Run: `swift test --filter GradientLevelingEngineTests`
Expected: PASS (5 tests). Then the neighbors:
Run: `swift test --filter 'StackEngine|BatchImporter|FrameWeight|AutoReseed|RejectionEngine|BackgroundModel|GradientLeveler'`
Expected: PASS (no regressions).

- [ ] **Step 9: Commit**

```bash
git add Sources/LiveAstroCore/Stacking/StackEngine.swift Sources/LiveAstroCore/Pipeline/BatchImporter.swift Tests/LiveAstroCoreTests/GradientLevelingEngineTests.swift
git commit -m "feat: StackEngine gradient leveling — reference model + level-before-rejection (TDD)"
```

---

## Task 5: Settings + AppModel + UI toggle

**Files:**
- Modify: `Sources/LiveAstroCore/Settings/SessionSettings.swift`
- Modify: `Sources/LiveAstroStudio/AppModel.swift`
- Modify: `Sources/LiveAstroStudio/ControlView.swift`
- Test: `Tests/LiveAstroCoreTests/SessionSettingsTests.swift`

**Interfaces:**
- Consumes: `StackEngine.init(..., normalization:)` (Task 4); `AppModel.makeStackEngine()`; `ControlView.helpToggle(_:isOn:help:)`.
- Produces: `SessionSettings.backgroundNormalizationEnabled: Bool` (default true, decode `?? true`); `AppModel.backgroundNormalizationEnabled` persisted + wired; a "Match sky background" toggle.

- [ ] **Step 1: Write the failing test (settings round-trip + backward-compat)**

Add to `Tests/LiveAstroCoreTests/SessionSettingsTests.swift`:

```swift
    func testBackgroundNormalizationDefaultsOnAndRoundTrips() throws {
        var s = SessionSettings()
        XCTAssertTrue(s.backgroundNormalizationEnabled)               // default on
        s.backgroundNormalizationEnabled = false
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(SessionSettings.self, from: data)
        XCTAssertFalse(back.backgroundNormalizationEnabled)
    }

    func testBackgroundNormalizationBackwardCompatDefaultsOn() throws {
        let json = "{\"subExposureSeconds\":60,\"targetName\":\"\",\"rejectionEnabled\":true}"
        let s = try JSONDecoder().decode(SessionSettings.self, from: Data(json.utf8))
        XCTAssertTrue(s.backgroundNormalizationEnabled)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter SessionSettingsTests`
Expected: FAIL — `backgroundNormalizationEnabled` not a member.

- [ ] **Step 3: Add the field to `SessionSettings`**

In `Sources/LiveAstroCore/Settings/SessionSettings.swift`, mirror `frameWeightingEnabled` at all four touch points:
1. Stored property `public var backgroundNormalizationEnabled: Bool`.
2. `init` param `backgroundNormalizationEnabled: Bool = true,` + assignment.
3. Add `backgroundNormalizationEnabled` to `CodingKeys`.
4. `init(from:)`: `backgroundNormalizationEnabled = try c.decodeIfPresent(Bool.self, forKey: .backgroundNormalizationEnabled) ?? true`.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter SessionSettingsTests`
Expected: PASS.

- [ ] **Step 5: Wire `AppModel`**

In `Sources/LiveAstroStudio/AppModel.swift`:
1. `var backgroundNormalizationEnabled = true` (near `frameWeightingEnabled`, ~line 43).
2. In `saveSettings()` builder (near `frameWeightingEnabled: frameWeightingEnabled,`, ~line 163) add `backgroundNormalizationEnabled: backgroundNormalizationEnabled,`.
3. In load/apply (near `frameWeightingEnabled = s.frameWeightingEnabled`, ~line 181) add `backgroundNormalizationEnabled = s.backgroundNormalizationEnabled`.
4. `makeStackEngine()` (~line 211):

```swift
        return StackEngine(rejection: rejection, frameWeighting: frameWeightingEnabled,
                           normalization: backgroundNormalizationEnabled)
```

- [ ] **Step 6: Add the UI toggle**

In `Sources/LiveAstroStudio/ControlView.swift`, directly after the "Weight frames by quality" `helpToggle` (~line 78):

```swift
                        helpToggle("Match sky background", isOn: $model.backgroundNormalizationEnabled,
                                   help: "Level each sub's sky gradient to the reference before stacking, so a drifting light-pollution ramp or moonrise gradient doesn't leave a residual gradient the master can't remove. Low-order per channel; off for an unadjusted stack.")
                            .disabled(model.isRunning || model.isImporting)
```

- [ ] **Step 7: Build + full suite**

Run: `swift build` then `swift build -c release`
Expected: both compile clean (the pre-existing `#SendableClosureCaptures` warning is unrelated).
Run: `swift test`
Expected: full suite green (0 failures).

- [ ] **Step 8: Commit**

```bash
git add Sources/LiveAstroCore/Settings/SessionSettings.swift Sources/LiveAstroStudio/AppModel.swift Sources/LiveAstroStudio/ControlView.swift Tests/LiveAstroCoreTests/SessionSettingsTests.swift
git commit -m "feat: 'Match sky background' toggle (default on) wired to the stack engine"
```

---

## After all tasks

Dispatch the final whole-branch review (opus) per subagent-driven-development, then finish the branch (merge to main + push + repackage dist). Repackage recipe: `swift build -c release --scratch-path /private/tmp/las-release-build`, then `ditto` the binary + `LiveAstroStudio_LiveAstroStudio.bundle` into `dist/LiveAstroStudio.app/Contents/MacOS/`, `xattr -cr`, `codesign --force --sign -` the executable, verify `codesign --verify --ignore-resources`.

---

# REWORK ADDENDUM (post-adversarial-review): fit-on-warped

Adversarial cold review proved two Criticals in the as-built feature: (C1) the sub model is fit on the UN-warped frame but applied in the WARPED grid — injects spurious gradient under rotation (133 ADU at a meridian flip); (C2) a frame-filling nebula contaminates the fit and a dithered nebula creates a spurious differential. Both fixed by fitting the sub model on the WARPED, reference-aligned frame, mask-aware. R1 prototype (commit a350b50) validated: degree 2, coverage gate ≥ 0.75.

### Task R2: `fitBackground` mask-aware + degree-2 default

**Files:** Modify `Sources/LiveAstroCore/Imaging/BackgroundExtraction.swift`, `Tests/LiveAstroCoreTests/BackgroundModelTests.swift`

Add `mask: [Float]? = nil` parameter to `fitBackground(_:degree:tilesPerAxis:rejectionSigma:mask:)`. When non-nil (length w*h), a tile is included ONLY if its covered fraction (mean of mask values > 0 over the tile) ≥ 0.75 (named constant `minTileCoverage: Float = 0.75`, cite the R1 prototype). `flatten` continues to call with `mask: nil` (byte-identical — existing BackgroundExtractionTests stay green + unmodified). TDD: a test with a synthetic border-zero region (right 40% masked out) shows the masked fit recovers the true gradient of the covered region while the unmasked fit is biased; a fully-covered mask equals nil-mask fit exactly.

### Task R3: `GradientLeveler` surface-subtract + guards

**Files:** Modify `Sources/LiveAstroCore/Stacking/GradientLeveler.swift`, `Tests/LiveAstroCoreTests/GradientLevelerTests.swift`

Replace the coefficient-zip with per-model surface evaluation: `surfSub = evaluate(cs, subModel.degree, …)`, `surfRef = evaluate(cr, refModel.degree, …)`, subtract `surfSub[i] − surfRef[i]` per pixel (fixes the PROVEN degree-mismatch crash and the zip-truncation silent corruption; models of different degrees now compose correctly). Keep the identical-model byte-identical fast path (skip when `cs == cr && subModel.degree == refModel.degree`). Sanitize: if either surface value or the pixel result is non-finite, passthrough that pixel's original value (fixes the NaN-through-clamp gap). TDD: regression test sub.deg2/ref.deg1 (crashed before — now correct surface difference); sub.deg1/ref.deg2 quadratic no longer silently dropped; NaN coeff → output finite and equal to input.

### Task R4: `StackEngine` fit AFTER warp + degree 2

**Files:** Modify `Sources/LiveAstroCore/Stacking/StackEngine.swift`, `Sources/LiveAstroCore/Pipeline/BatchImporter.swift`, `Tests/LiveAstroCoreTests/GradientLevelingEngineTests.swift`

- `backgroundDegree` 1 → 2 (cite R1).
- Remove the fit from `register` (drop `RegisteredFrame.backgroundModel`). Add a pure, lock-free helper `fitWarpedBackground(image: AstroImage, mask: [Float]) -> BackgroundExtraction.BackgroundModel?` — nil when `normalization` off; else `fitBackground(image, degree: Self.backgroundDegree, mask: mask)`.
- Live path (`processLocked`): after `Warp.apply`, `let subModel = fitWarpedBackground(image: warped, mask: mask)` then level (both-non-nil guard unchanged).
- Import path: `BatchImporter` worker calls `engine.warp(...)` then `engine.fitWarpedBackground(image: w.image, mask: w.mask)` (still on the pool — pure) and carries it in `Work.backgroundModel` → `commit` (signature unchanged).
- Seed baseline unchanged: fit on the seed rgb with a full-coverage mask (`mask: nil` domain equivalent — pass `nil`-mask path by fitting `fitBackground(rgb, degree: Self.backgroundDegree)`); the seed IS reference coords.
- Tests: update engine tests for the new call shape; add a rotation regression — a sub captured with a strong gradient and warped under rotation levels toward the reference (the old pre-warp fit left/injected error); reseed + off-path parity tests unchanged and green.
