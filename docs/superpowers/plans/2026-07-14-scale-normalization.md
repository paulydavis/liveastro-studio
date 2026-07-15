# Multiplicative Scale Normalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scale each accepted sub's signal to the reference amplitude (matched-star flux ratio) before the combine, so transparency drift stops dimming the master and σ-clip compares consistent amplitudes.

**Architecture:** `StackEngine.scaleFactor` computes `s = median(flux_ref/flux_sub)` over the RANSAC inlier star pairs registration already produces (clamped [0.5, 2.0], ≥5 pairs). A pure `SignalScaler` applies `bg₀ + (x − bg₀)·s` per channel about the seed background median (`scaleBaseline`), inserted after `GradientLeveler` and before rejection in both paths. Frame weighting sees post-scale noise (`σ·s`). Engine option `scaleNormalization` defaults off (byte-identical); app default on via a "Match transparency" toggle.

**Tech Stack:** Swift 5.10 SPM (LiveAstroCore: Foundation/CoreGraphics/Accelerate only), SwiftUI app, Python 3 + numpy for the T1 prototype.

## Global Constraints

- Swift 5.10, macOS 14+. LiveAstroCore imports Foundation / CoreGraphics / Accelerate only; zero external deps.
- Off (`scaleNormalization: false`) ⇒ `scale = 1.0` everywhere ⇒ **byte-identical** (whole existing suite guards it). Engine default off; app default on.
- Order in BOTH paths: warp → level → **scale** → rejection → weighted add.
- `s ∈ [0.5, 2.0]` (named constants); < 5 inlier pairs or any invalid flux handling per spec ⇒ `s = 1.0`; seed `s = 1.0`.
- `scaleBaseline` set at BOTH seed sites, nil at BOTH reseed sites — the `weightBaseline` discipline (an auto-reseed path that forgot per-session state shipped as a real Critical here; mirror every site).
- Weight uses `sigma * scale` only when scaling is on.
- Core TDD'd; prototype gates the build; app/UI build-verified; adversarial pass before merge.
- Branch: `feature/scale-normalization` off `main` @ 98d8a18. Spec: `docs/superpowers/specs/2026-07-14-scale-normalization-design.md`.

---

## Task 1: Python prototype — estimator accuracy + the win (gate)

**Files:**
- Create: `scratchpad/scale_normalization.py`

- [ ] **Step 1: Write the prototype**

```python
# scratchpad/scale_normalization.py
import numpy as np
rng = np.random.default_rng(5)
H = W = 200; N = 24
NOISE = 0.008

yy, xx = np.mgrid[0:H, 0:W]

def make_field():
    stars = []
    for _ in range(30):
        y, x = rng.uniform(10, H-10), rng.uniform(10, W-10)
        amp = rng.uniform(0.15, 0.8); sig = rng.uniform(1.0, 1.8)
        stars.append((y, x, amp, sig))
    return stars

STARS = make_field()
BG = 0.05

def render(transparency):
    img = np.full((H, W), BG)
    for (y, x, amp, sig) in STARS:
        img += transparency * amp * np.exp(-(((xx-x)**2 + (yy-y)**2) / (2*sig*sig)))
    return np.clip(img + rng.normal(0, NOISE, (H, W)), 0, 1)

# per-sub true transparency drifting 1.0 -> 0.6 across the session
t_true = np.linspace(1.0, 0.6, N)
subs = [render(t) for t in t_true]
ref = subs[0]

def measure_fluxes(img):
    """Aperture flux (bg-subtracted 5x5 sum) at the KNOWN star positions —
    stands in for StarDetector flux; registration gives us matched pairs."""
    out = []
    for (y, x, amp, sig) in STARS:
        yi, xi = int(round(y)), int(round(x))
        ap = img[yi-2:yi+3, xi-2:xi+3]
        out.append(max(ap.sum() - 25 * BG, 1e-6))
    return np.array(out)

F_ref = measure_fluxes(ref)

def estimate_scale(img, corrupt_pairs=0):
    f = measure_fluxes(img)
    ratios = F_ref / f
    if corrupt_pairs:                        # simulate RANSAC mismatches surviving
        idx = rng.choice(len(ratios), corrupt_pairs, replace=False)
        ratios[idx] *= rng.uniform(0.2, 5.0, corrupt_pairs)
    return float(np.clip(np.median(ratios), 0.5, 2.0))

# ---- Part A: estimator accuracy ----
print("=== A: estimator accuracy (s_hat vs 1/t_true) ===")
errs, errs_corrupt = [], []
for i, s in enumerate(subs):
    target = np.clip(1.0 / t_true[i], 0.5, 2.0)
    errs.append(abs(estimate_scale(s) - target))
    errs_corrupt.append(abs(estimate_scale(s, corrupt_pairs=4) - target))
print(f"clean pairs : max|err|={max(errs):.4f}  mean={np.mean(errs):.4f}")
print(f"4 bad pairs : max|err|={max(errs_corrupt):.4f}  mean={np.mean(errs_corrupt):.4f}")

# ---- Part B: does scale-then-weight beat weight-alone on the master? ----
def combine(subs, use_scale):
    acc = np.zeros((H, W)); wsum = 0.0
    for i, s in enumerate(subs):
        k = estimate_scale(s) if use_scale else 1.0
        frame = np.clip(BG + (s - BG) * k, 0, 1)
        sigma = NOISE * k                                  # post-scale noise
        w = 1.0 / (sigma * sigma)                          # inverse-variance
        acc += w * frame; wsum += w
    return acc / wsum

truth = np.full((H, W), BG)
for (y, x, amp, sig) in STARS:
    truth += amp * np.exp(-(((xx-x)**2 + (yy-y)**2) / (2*sig*sig)))   # transparency 1.0 signal

def star_amp_err(master):
    """Mean |master peak - truth peak| over stars (amplitude fidelity)."""
    e = []
    for (y, x, amp, sig) in STARS:
        yi, xi = int(round(y)), int(round(x))
        e.append(abs(master[yi, xi] - truth[yi, xi]))
    return float(np.mean(e))

m_off = combine(subs, False)
m_on  = combine(subs, True)
print("=== B: master star-amplitude error vs ground truth ===")
print(f"weight-alone     : {star_amp_err(m_off):.5f}")
print(f"scale-then-weight: {star_amp_err(m_on):.5f}   "
      f"({100*(star_amp_err(m_on)-star_amp_err(m_off))/star_amp_err(m_off):+.1f}%)")

# ---- Part C: sigma-clip efficacy with drifting transparency ----
def clip_combine(subs, use_scale, kappa=3.0):
    frames = []
    for s in subs:
        k = estimate_scale(s) if use_scale else 1.0
        frames.append(np.clip(BG + (s - BG) * k, 0, 1))
    a = np.stack(frames)
    mean = a.mean(0); std = a.std(0) + 1e-9
    clipped = np.clip(a, mean - kappa*std, mean + kappa*std)
    return clipped.mean(0)

streaky = [s.copy() for s in subs]
streaky[10][100:102, :] = 0.9                            # satellite streak on one sub
c_off = clip_combine(streaky, False); c_on = clip_combine(streaky, True)
res_off = c_off[100:102, :].mean() - truth[100:102, :].mean()
res_on  = c_on[100:102, :].mean() - truth[100:102, :].mean()
print("=== C: streak residual after sigma-clip (lower = better rejection) ===")
print(f"weight-alone     : {res_off:.5f}")
print(f"scale-then-weight: {res_on:.5f}")
```

- [ ] **Step 2: Run it** — `python3 scratchpad/scale_normalization.py`
GATE: (A) estimator max|err| small (≲0.05 clean; robust with 4 corrupt pairs); (B) scale-then-weight star-amplitude error CLEARLY lower than weight-alone (the drifting-transparency stack biases amplitudes down without scaling); (C) streak residual not worse (ideally better). If B fails, STOP and report BLOCKED with numbers.

- [ ] **Step 3: Commit** — `git add scratchpad/scale_normalization.py && git commit -m "prototype: validate matched-flux scale normalization (estimator + master win)"`

---

## Task 2: `SignalScaler` + `StackEngine.scaleFactor` (TDD, pure pieces)

**Files:**
- Create: `Sources/LiveAstroCore/Stacking/SignalScaler.swift`
- Modify: `Sources/LiveAstroCore/Stacking/StackEngine.swift` (add the static helper + constants only)
- Test: `Tests/LiveAstroCoreTests/SignalScalerTests.swift`, `Tests/LiveAstroCoreTests/ScaleFactorTests.swift`

**Interfaces:**
- Produces: `SignalScaler.apply(_ image: AstroImage, scale: Float, background: [Float], minRows: Int = 64) -> AstroImage`; `StackEngine.scaleFactor(fluxPairs: [(sub: Double, ref: Double)]) -> Float` (static, pure) with `static let scaleLo: Float = 0.5`, `scaleHi: Float = 2.0`, `minScalePairs = 5`.

- [ ] **Step 1: Failing tests**

```swift
// Tests/LiveAstroCoreTests/SignalScalerTests.swift
import XCTest
@testable import LiveAstroCore

final class SignalScalerTests: XCTestCase {
    func img(_ w: Int, _ h: Int, _ ch: Int, _ px: [Float]) -> AstroImage {
        AstroImage(width: w, height: h, channels: ch, pixels: px, sourceIsLinear: true)
    }

    func testScaleOneIsByteIdentical() {
        let a = img(2, 2, 3, (0..<12).map { Float($0) / 12 })
        XCTAssertEqual(SignalScaler.apply(a, scale: 1.0, background: [0.1, 0.1, 0.1]).pixels, a.pixels)
    }

    func testScalesSignalAboutPerChannelBackground() {
        // ch0 bg 0.1: 0.3 -> 0.1 + 0.2*1.5 = 0.4 ; ch1 bg 0.2: 0.2 -> 0.2 (at pivot, unchanged)
        let a = img(1, 1, 2, [0.3, 0.2])
        let out = SignalScaler.apply(a, scale: 1.5, background: [0.1, 0.2])
        XCTAssertEqual(out.pixels[0], 0.4, accuracy: 1e-6)
        XCTAssertEqual(out.pixels[1], 0.2, accuracy: 1e-6)
    }

    func testClampsBothEnds() {
        let a = img(1, 1, 1, [0.9])
        XCTAssertEqual(SignalScaler.apply(a, scale: 2.0, background: [0.1]).pixels[0], 1.0)  // 0.1+0.8*2 → clamp
        let b = img(1, 1, 1, [0.05])
        XCTAssertEqual(SignalScaler.apply(b, scale: 2.0, background: [0.2]).pixels[0], 0.0)  // 0.2-0.15*2 → clamp
    }

    func testParallelEqualsSerial() {
        let n = 200
        let px = (0..<(n*n*3)).map { Float($0 % 97) / 97 }
        let a = img(n, n, 3, px)
        XCTAssertEqual(SignalScaler.apply(a, scale: 1.3, background: [0.1, 0.2, 0.3], minRows: .max).pixels,
                       SignalScaler.apply(a, scale: 1.3, background: [0.1, 0.2, 0.3], minRows: 1).pixels)
    }
}
```

```swift
// Tests/LiveAstroCoreTests/ScaleFactorTests.swift
import XCTest
@testable import LiveAstroCore

final class ScaleFactorTests: XCTestCase {
    func testMedianRatioOfMatchedFluxes() {
        // sub uniformly 20% dimmer → ratios all 1.25 → s = 1.25
        let pairs = (1...9).map { (sub: Double($0) * 0.8, ref: Double($0)) }
        XCTAssertEqual(StackEngine.scaleFactor(fluxPairs: pairs), 1.25, accuracy: 1e-5)
    }
    func testMedianRobustToOutlierPairs() {
        var pairs = (1...9).map { (sub: Double($0), ref: Double($0)) }   // s = 1
        pairs[0].ref = 100; pairs[1].sub = 100                            // two wild mismatches
        XCTAssertEqual(StackEngine.scaleFactor(fluxPairs: pairs), 1.0, accuracy: 1e-5)
    }
    func testClampedToRange() {
        let dim = (1...9).map { (sub: Double($0) * 0.1, ref: Double($0)) }   // ratio 10 → clamp 2.0
        XCTAssertEqual(StackEngine.scaleFactor(fluxPairs: dim), 2.0)
        let bright = (1...9).map { (sub: Double($0) * 10, ref: Double($0)) } // ratio 0.1 → clamp 0.5
        XCTAssertEqual(StackEngine.scaleFactor(fluxPairs: bright), 0.5)
    }
    func testTooFewPairsIsOne() {
        let pairs = (1...4).map { (sub: Double($0), ref: Double($0) * 2) }
        XCTAssertEqual(StackEngine.scaleFactor(fluxPairs: pairs), 1.0)
    }
    func testInvalidFluxPairsSkipped() {
        // 5 good pairs at ratio 1.5 + junk pairs (0 / negative / NaN) that must be ignored
        var pairs = (1...5).map { (sub: Double($0), ref: Double($0) * 1.5) }
        pairs.append((sub: 0, ref: 3)); pairs.append((sub: -1, ref: 2)); pairs.append((sub: .nan, ref: 1))
        XCTAssertEqual(StackEngine.scaleFactor(fluxPairs: pairs), 1.5, accuracy: 1e-5)
    }
}
```

- [ ] **Step 2: Verify fail** — `swift test --filter 'SignalScalerTests|ScaleFactorTests'`

- [ ] **Step 3: Implement**

```swift
// Sources/LiveAstroCore/Stacking/SignalScaler.swift
import Foundation

/// Multiplicative transparency normalization (spec: scale normalization).
/// Scales a frame's SIGNAL about the per-channel reference background:
/// out = clamp(bg[c] + (x − bg[c])·scale, 0, 1). scale == 1 returns the frame
/// byte-identical. Deterministic; parallel over row bands.
public enum SignalScaler {
    public static func apply(_ image: AstroImage, scale: Float, background: [Float],
                             minRows: Int = 64) -> AstroImage {
        precondition(background.count == image.channels, "background must have one value per channel")
        if scale == 1.0 { return image }
        let w = image.width, h = image.height, chans = image.channels, plane = w * h
        var out = image.pixels
        out.withUnsafeMutableBufferPointer { buf in
            for c in 0..<chans {
                let bg = background[c], base = c * plane
                Parallel.rows(h, minRows: minRows) { rows in
                    for y in rows {
                        for x in 0..<w {
                            let i = base + y * w + x
                            buf[i] = min(max(bg + (buf[i] - bg) * scale, 0), 1)
                        }
                    }
                }
            }
        }
        return AstroImage(width: w, height: h, channels: chans, pixels: out, sourceIsLinear: image.sourceIsLinear)
    }
}
```

In `StackEngine.swift`, next to the frame-weighting constants:

```swift
    // Scale-normalization constants (spec: multiplicative scale). Transparency
    // beyond a 2× swing is clouds — weighting/rejection's job, not scaling's.
    static let scaleLo: Float = 0.5
    static let scaleHi: Float = 2.0
    static let minScalePairs = 5

    /// Median matched-star flux ratio (ref/sub) over RANSAC inlier pairs — the
    /// sub's transparency correction. Pure. Invalid pairs (non-finite or ≤ 0 flux)
    /// are skipped; fewer than minScalePairs valid pairs ⇒ 1.0 (no scaling).
    public static func scaleFactor(fluxPairs: [(sub: Double, ref: Double)]) -> Float {
        let ratios = fluxPairs.compactMap { p -> Double? in
            guard p.sub.isFinite, p.ref.isFinite, p.sub > 0, p.ref > 0 else { return nil }
            return p.ref / p.sub
        }
        guard ratios.count >= minScalePairs else { return 1.0 }
        let sorted = ratios.sorted()
        let median = sorted[sorted.count / 2]
        return min(max(Float(median), scaleLo), scaleHi)
    }
```

- [ ] **Step 4: Verify pass** — same filter, 9 tests green.
- [ ] **Step 5: Commit** — `git add Sources/LiveAstroCore/Stacking/SignalScaler.swift Sources/LiveAstroCore/Stacking/StackEngine.swift Tests/LiveAstroCoreTests/SignalScalerTests.swift Tests/LiveAstroCoreTests/ScaleFactorTests.swift && git commit -m "feat: SignalScaler + StackEngine.scaleFactor (TDD, pure pieces)"`

---

## Task 3: Engine wiring (TDD)

**Files:**
- Modify: `Sources/LiveAstroCore/Stacking/StackEngine.swift`, `Sources/LiveAstroCore/Pipeline/BatchImporter.swift`
- Test: `Tests/LiveAstroCoreTests/ScaleNormalizationEngineTests.swift`

**Interfaces:**
- Consumes: `SignalScaler.apply`, `StackEngine.scaleFactor` (T2); `TransformSolver.inliers(_:source:target:pairs:tolerance:) -> [StarPair]` (existing internal; `StarPair` has `.source`/`.target` indices); existing `register`/`commit`/`processLocked` shapes.
- Produces: `StackEngine.init(..., scaleNormalization: Bool = false)`; `RegisteredFrame.scale: Float`; `commit(..., scale: Float = 1.0, ...)`; `scaleBaseline: [Float]?` lifecycle.

Wiring points (mirror the `weightBaseline` discipline at EVERY site — grep it):
1. Stored: `private let scaleNormalization: Bool` (init param, default false) and `private var scaleBaseline: [Float]?`.
2. BOTH seed sites (`processLocked` seed branch ~line 144 and `seedReference` ~line 292), after `weightBaseline = (stars.count, sigma)`: `scaleBaseline = scaleNormalization ? (0..<rgb.channels).map { Float(rgb.stats[$0].median) } : nil`.
3. BOTH reseed sites (manual `reseed()` ~line 80, auto-reseed ~line 171), after `weightBaseline = nil`: `scaleBaseline = nil`.
4. `register` (~line 320): after `TransformSolver.solve` succeeds, when `scaleNormalization`:
```swift
        var scale: Float = 1.0
        if scaleNormalization {
            let ins = TransformSolver.inliers(half, source: stars, target: referenceStars,
                                              pairs: pairs, tolerance: inlierTolerance)
            scale = Self.scaleFactor(fluxPairs: ins.map { (sub: stars[$0.source].flux, ref: referenceStars[$0.target].flux) })
        }
        let weight = frameWeight(stars: stars.count, sigma: sigma * scale)   // post-scale noise
        return RegisteredFrame(transform: half, rgb: rgb, weight: weight, scale: scale)
```
   (`RegisteredFrame` gains `public let scale: Float`; when off, `sigma * 1.0` keeps weighting byte-identical.)
5. `commit`: add `scale: Float = 1.0` param; after the leveling block, before rejection:
```swift
            if scale != 1.0, let bg = scaleBaseline {
                frame = SignalScaler.apply(frame, scale: scale, background: bg, minRows: minRows)
            }
```
6. `processLocked` (live tail, ~199–203): compute inliers + scale the same way after the solve (the `pairs` and `half` are in scope), insert the same `SignalScaler` block after the leveler, and pass `sigma * scale` to `frameWeight` in the `accumulator.add` line.
7. `BatchImporter`: `Work` gains `let scale: Float`; populate from `reg.scale` (warped case) / `1.0` (rejection case); pass `scale: work.scale` in the consumer's `engine.commit(...)`.

Tests (`ScaleNormalizationEngineTests`, reuse the `cfaFrame`/star-field helper pattern from `GradientLevelingEngineTests` — read that file):
- `testRegisterScaleOneWhenOff` / `testRegisterComputesScaleWhenOn` (build a sub whose CFA values are the seed's × 0.7 — signal 30% dimmer with same background → expect `reg.scale > 1` and roughly ≈ 1/0.7 within tolerance; off ⇒ exactly 1.0).
- `testOffPathByteIdentical` (off vs on over identical-transparency frames → equal within 1e-4, mirroring the leveling test).
- `testDimSubRestoredTowardReference` (seed normal; commit 9 dimmed subs with scaling on vs off; the master's brightest-star peak with scaling ON is closer to the seed's peak).
- `testWeightSeesPostScaleNoise` (with weighting+scaling on, a dimmed sub's `reg.weight` is LOWER than the same sub's weight when scaling is off — because σ·s > σ).
- `testScaleBaselineResetOnReseed` (seed bright field → reseed → seed normal field → commit an identical sub → pixels ≈ unchanged at a sky location, mirroring the leveling reseed test).

Steps: failing tests → wire → `swift test --filter 'ScaleNormalization|SignalScaler|ScaleFactor'` green → neighbors `swift test --filter 'StackEngine|BatchImporter|FrameWeight|AutoReseed|GradientLeveling|RejectionEngine'` green → commit `"feat: StackEngine scale normalization — matched-flux scale, level→scale→reject order, σ·s weighting (TDD)"`.

---

## Task 4: Settings + toggle

**Files:** `Sources/LiveAstroCore/Settings/SessionSettings.swift`, `Sources/LiveAstroStudio/AppModel.swift`, `Sources/LiveAstroStudio/ControlView.swift`, `Tests/LiveAstroCoreTests/SessionSettingsTests.swift`

Mirror `backgroundNormalizationEnabled` exactly (grep every touch point):
- `SessionSettings.scaleNormalizationEnabled: Bool` — default true, `decodeIfPresent ?? true`, all 5 touch points + `.defaults`.
- Tests: default-on round-trip + backward-compat (reuse the existing JSON literal).
- `AppModel`: `var scaleNormalizationEnabled = true`, currentSettings/loadSettings, `makeStackEngine` passes `scaleNormalization: scaleNormalizationEnabled`.
- `ControlView`: after "Match sky background": `helpToggle("Match transparency", isOn: $model.scaleNormalizationEnabled, help: "Scale each sub's signal to the reference brightness using matched star fluxes, so haze or thin cloud doesn't dim the master. Off for an unadjusted stack.")` with the sibling `.disabled(...)`.
- `swift build`, `swift build -c release`, full `swift test` (0 failures).
- Commit `"feat: 'Match transparency' toggle (default on) wired to the stack engine"`.

---

## After all tasks

Whole-branch review (opus) + adversarial pass (numerical: estimator bias — e.g. saturated star cores clamp fluxes, near-zero fluxes; ordering/composition with level+weight; degenerate: hostile flux pairs, clamp interactions). Then merge + push + repackage dist (standard recipe). Post-merge: real-data A/B on the 3-night NGC 6888 subs (real transparency drift likely).
