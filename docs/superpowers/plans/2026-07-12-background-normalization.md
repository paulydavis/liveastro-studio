# Background Normalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Shift each accepted sub, per channel, so its sky background matches the seed reference before the weighted combine — improving σ-clip rejection and preventing high-sky subs from biasing the master.

**Architecture:** A new pure `BackgroundNormalizer` subtracts a per-channel scalar offset (clamped to [0,1]). `StackEngine` captures the seed's per-channel background as a baseline, computes each sub's offset in `register`, and applies the normalizer **before** `rejection.apply` and the weighted `accumulator.add`, in both the live `process` path and the staged `register/warp/commit` (import) path. A `normalization` engine flag defaults off (byte-identical); the app defaults it on via a toggle.

**Tech Stack:** Swift 5.10 SPM (LiveAstroCore: Foundation/CoreGraphics/Accelerate only), SwiftUI app, Python 3 + numpy for the Task-1 prototype (not shipped).

## Global Constraints

- Swift 5.10, macOS 14+. `LiveAstroCore` imports Foundation / CoreGraphics / Accelerate only. Zero external dependencies.
- Stacking-core (linear master) feature — NOT the display path. Do not touch `neutralizeBackground` / DBE.
- Additive only (per-channel scalar pedestal). No multiplicative scale. No per-sub gradient modeling.
- Deterministic. Normalization OFF (`normalization: false` ⇒ offset all-zero) is **byte-identical** to the pre-change stack — regression-guarded.
- Normalization runs BEFORE rejection and BEFORE the weighted add, in both `process` (live) and `commit` (import).
- Baseline captured at seed, reset to nil at EVERY reseed path (manual `reseed()` and the auto-reseed block) — same discipline as `weightBaseline`.
- The background estimator (median vs low percentile) is fixed by Task 1's validated report; the plan's starting estimator is the per-channel median (`AstroImage.stats[c].median`).
- Core logic TDD'd; the Python prototype is a validation artifact; app/UI is build-verified.
- Branch: `feature/background-normalization` off `main` @ d230618. Spec: `docs/superpowers/specs/2026-07-12-background-normalization-design.md`.

---

## Task 1: Python prototype — validate the win + fix the estimator

**Files:**
- Create: `scratchpad/background_normalization.py` (NOT shipped — validation artifact; scratchpad is git-ignored)

This task's "test" is the validation gate: the prototype must show normalized-then-combined beats un-normalized on synthetic drifting-sky subs, and must pick the estimator. Mirrors `scratchpad/frame_weighting.py`.

- [ ] **Step 1: Write the prototype**

```python
# scratchpad/background_normalization.py
import numpy as np

rng = np.random.default_rng(7)
H, W, C = 120, 120, 3
N = 24  # subs

# One common star field per channel (sparse bright points on ~0 background).
stars = np.zeros((H, W, C), np.float64)
for _ in range(40):
    y, x = rng.integers(6, H - 6), rng.integers(6, W - 6)
    amp = rng.uniform(0.3, 0.9)
    yy, xx = np.mgrid[y-4:y+5, x-4:x+5]
    stars[y-4:y+5, x-4:x+5, :] += amp * np.exp(-((yy-y)**2 + (xx-x)**2) / 4.0)[..., None]

def make_sub(i):
    # per-channel sky pedestal drifting across the session + a slowly moving linear gradient
    ped = np.array([0.05, 0.04, 0.03]) + i * np.array([0.004, 0.003, 0.0025])   # rising sky
    gy = np.linspace(0, 0.02 * (i / N), H)[:, None, None]                       # moving gradient
    noise = rng.normal(0, 0.01, (H, W, C))
    return np.clip(stars + ped[None, None, :] + gy + noise, 0, 1)

subs = [make_sub(i) for i in range(N)]

def per_channel_bg(sub, estimator):
    # sky estimate per channel; stars are sparse so median ~ sky, percentile is more robust
    if estimator == "median":
        return np.median(sub.reshape(-1, C), axis=0)
    return np.percentile(sub.reshape(-1, C), 25, axis=0)

def combine(subs, normalize, estimator):
    ref_bg = per_channel_bg(subs[0], estimator)   # seed reference
    acc = np.zeros((H, W, C), np.float64)
    for s in subs:
        f = s
        if normalize:
            off = per_channel_bg(s, estimator) - ref_bg
            f = np.clip(s - off[None, None, :], 0, 1)
        acc += f
    return acc / len(subs)

def bg_nonuniformity(master):
    # corner-to-corner background spread (lower is flatter) on a sky region (top-left quadrant, star-free-ish)
    q = master[:H//3, :W//3, :]
    return float(np.mean(np.std(q.reshape(-1, C), axis=0)))

def star_snr(master):
    flat = master.reshape(-1, C).mean(axis=1)
    sky = np.median(flat)
    sig = np.mean(np.sort(flat)[-max(1, flat.size // 1000):]) - sky
    noise = 1.4826 * np.median(np.abs(flat - sky))
    return float(sig / noise) if noise > 0 else 0.0

for est in ("median", "p25"):
    off = combine(subs, False, est)
    on = combine(subs, True, est)
    print(f"[{est}] bg_nonuniformity off={bg_nonuniformity(off):.5f} on={bg_nonuniformity(on):.5f} "
          f"({100*(bg_nonuniformity(on)-bg_nonuniformity(off))/bg_nonuniformity(off):+.1f}%)  "
          f"starSNR off={star_snr(off):.2f} on={star_snr(on):.2f}")
```

- [ ] **Step 2: Run it**

Run: `python3 scratchpad/background_normalization.py`
Expected: for at least one estimator, `on` background non-uniformity is meaningfully lower than `off` (normalization flattens the stacked background), and star SNR is not worse. Example acceptance: `bg_nonuniformity` improves (negative %) by a clear margin.

- [ ] **Step 3: Record the verdict**

If normalized beats un-normalized, record in the report which estimator to ship (`median` or `p25`) and the measured deltas. If BOTH estimators fail to improve, STOP and escalate (the synthetic regime or the approach needs rethinking) — do not proceed to T2.

- [ ] **Step 4: Commit the artifact**

```bash
git add scratchpad/background_normalization.py
git commit -m "prototype: validate additive per-channel background normalization"
```

**Deliverable for later tasks:** the chosen estimator (`median` unless the prototype selects `p25`). T3's `perChannelBackground` uses it.

---

## Task 2: `BackgroundNormalizer` — pure per-channel subtract + clamp

**Files:**
- Create: `Sources/LiveAstroCore/Stacking/BackgroundNormalizer.swift`
- Test: `Tests/LiveAstroCoreTests/BackgroundNormalizerTests.swift`

**Interfaces:**
- Consumes: `AstroImage` (width/height/channels/pixels, planar channel-major), `Parallel.rows(_ height: Int, minRows: Int = 64, _ body: (Range<Int>) -> Void)`.
- Produces: `BackgroundNormalizer.apply(_ image: AstroImage, offset: [Float], minRows: Int = 64) -> AstroImage` — subtracts `offset[c]` from channel `c`, clamps `[0,1]`; returns the input unchanged when `offset` is all-zero.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/LiveAstroCoreTests/BackgroundNormalizerTests.swift
import XCTest
@testable import LiveAstroCore

final class BackgroundNormalizerTests: XCTestCase {
    func img(_ w: Int, _ h: Int, _ ch: Int, _ px: [Float]) -> AstroImage {
        AstroImage(width: w, height: h, channels: ch, pixels: px, sourceIsLinear: true)
    }

    func testZeroOffsetIsByteIdentical() {
        let a = img(2, 2, 3, (0..<12).map { Float($0) / 12 })
        let out = BackgroundNormalizer.apply(a, offset: [0, 0, 0])
        XCTAssertEqual(out.pixels, a.pixels)
    }

    func testSubtractsPerChannelOffset() {
        // 2x1, 3 channels: ch0=[0.5,0.5] ch1=[0.4,0.4] ch2=[0.3,0.3]
        let a = img(2, 1, 3, [0.5, 0.5, 0.4, 0.4, 0.3, 0.3])
        let out = BackgroundNormalizer.apply(a, offset: [0.1, 0.2, -0.1])
        // ch0 -0.1 → 0.4 ; ch1 -0.2 → 0.2 ; ch2 +0.1 → 0.4
        XCTAssertEqual(out.pixels, [0.4, 0.4, 0.2, 0.2, 0.4, 0.4])
    }

    func testClampsToUnitRange() {
        let a = img(1, 1, 1, [0.05])
        XCTAssertEqual(BackgroundNormalizer.apply(a, offset: [0.2]).pixels, [0.0])   // 0.05-0.2 → clamp 0
        let b = img(1, 1, 1, [0.95])
        XCTAssertEqual(BackgroundNormalizer.apply(b, offset: [-0.2]).pixels, [1.0])  // 0.95+0.2 → clamp 1
    }

    func testChannelIndependence() {
        // only channel 1 shifts; 0 and 2 untouched
        let a = img(1, 1, 3, [0.5, 0.5, 0.5])
        XCTAssertEqual(BackgroundNormalizer.apply(a, offset: [0, 0.1, 0]).pixels, [0.5, 0.4, 0.5])
    }

    func testParallelEqualsSerial() {
        let n = 300
        let px = (0..<(n * n * 3)).map { Float(($0 % 100)) / 100 }
        let a = img(n, n, 3, px)
        let serial = BackgroundNormalizer.apply(a, offset: [0.1, 0.05, 0.2], minRows: .max)
        let parallel = BackgroundNormalizer.apply(a, offset: [0.1, 0.05, 0.2], minRows: 1)
        XCTAssertEqual(serial.pixels, parallel.pixels)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter BackgroundNormalizerTests`
Expected: FAIL — `cannot find 'BackgroundNormalizer' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/LiveAstroCore/Stacking/BackgroundNormalizer.swift
import Foundation

/// Additive per-channel background matching (spec: background normalization).
/// Subtracts a per-channel scalar `offset` from a linear frame and clamps to
/// [0,1]. Deterministic and per-pixel independent (parallelized over row bands).
/// An all-zero offset returns the frame byte-identical.
public enum BackgroundNormalizer {
    public static func apply(_ image: AstroImage, offset: [Float], minRows: Int = 64) -> AstroImage {
        precondition(offset.count == image.channels, "offset must have one value per channel")
        if offset.allSatisfy({ $0 == 0 }) { return image }
        let w = image.width, h = image.height, chans = image.channels, plane = w * h
        var out = image.pixels
        out.withUnsafeMutableBufferPointer { buf in
            for c in 0..<chans {
                let off = offset[c], base = c * plane
                Parallel.rows(h, minRows: minRows) { rows in
                    for y in rows {
                        for x in 0..<w {
                            let i = base + y * w + x
                            buf[i] = min(max(buf[i] - off, 0), 1)
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

Run: `swift test --filter BackgroundNormalizerTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Stacking/BackgroundNormalizer.swift Tests/LiveAstroCoreTests/BackgroundNormalizerTests.swift
git commit -m "feat: BackgroundNormalizer — per-channel additive subtract + clamp (TDD)"
```

---

## Task 3: `StackEngine` — baseline, offset, normalize-before-rejection (both paths)

**Files:**
- Modify: `Sources/LiveAstroCore/Stacking/StackEngine.swift`
- Modify: `Sources/LiveAstroCore/Pipeline/BatchImporter.swift`
- Test: `Tests/LiveAstroCoreTests/BackgroundNormalizationEngineTests.swift`

**Interfaces:**
- Consumes: `BackgroundNormalizer.apply(_:offset:minRows:)` (Task 2); existing `StackEngine.RegisteredFrame { transform; rgb; weight }`, `commit(image:mask:frameWeight:minRows:)`, `register(_:minRows:) -> RegisteredFrame?`, `warp(_:minRows:)`, `reseed()`, `seedReference(_:minRows:)`, `AstroImage.stats[c].median`.
- Produces: `StackEngine.init(..., frameWeighting: Bool = false, normalization: Bool = false)`; `RegisteredFrame` gains `backgroundOffset: [Float]`; `commit(image:mask:frameWeight:backgroundOffset:minRows:)`; `perChannelBackground(_ rgb: AstroImage) -> [Float]`; `backgroundOffset(for rgb: AstroImage) -> [Float]`.

**Context for the implementer:** `StackEngine` (Sources/LiveAstroCore/Stacking/StackEngine.swift) is the native stacker. It has two accumulate paths that BOTH need normalization inserted, exactly mirroring how `frameWeight` is threaded:
1. **Live path** `processLocked(_:)` — around the tail, after solving the transform: `let (warped, mask) = Warp.apply(rgb, ...); let cleaned = rejection.apply(warped, mask: mask); accumulator.add(cleaned, mask: mask, frameWeight: frameWeight(stars:sigma:))`.
2. **Staged/import path** `register` → `warp` → `commit`. `register` builds `RegisteredFrame(transform:rgb:weight:)`. `commit` does `let cleaned = rejection.apply(image, mask: mask); accumulator.add(cleaned, mask: mask, frameWeight: frameWeight)`.

`weightBaseline: (stars: Int, sigma: Float)?` is set at the seed and reset to nil in `reseed()` AND the auto-reseed block (StackEngine.swift ~lines 60-68 and ~150-156). Add `backgroundBaseline: [Float]?` with the SAME lifecycle. The seed sets `frameWeighting`'s baseline at three seed sites (the `processLocked` `referenceSize == nil` branch and `seedReference`); set `backgroundBaseline` at the same sites.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/LiveAstroCoreTests/BackgroundNormalizationEngineTests.swift
import XCTest
@testable import LiveAstroCore

final class BackgroundNormalizationEngineTests: XCTestCase {
    // CFA frame with Gaussian stars + a per-channel-neutral sky pedestal `sky`.
    func cfaFrame(stars: [(Double, Double)], sky: Float, w: Int = 256, h: Int = 256) -> RawFrame {
        var px = [Float](repeating: sky, count: w * h)
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

    func testPerChannelBackgroundReflectsSky() {
        let eng = StackEngine(normalization: true)
        let lo = eng.perChannelBackground(AstroImage(width: 4, height: 4, channels: 1,
            pixels: [Float](repeating: 0.05, count: 16), sourceIsLinear: true))
        let hi = eng.perChannelBackground(AstroImage(width: 4, height: 4, channels: 1,
            pixels: [Float](repeating: 0.20, count: 16), sourceIsLinear: true))
        XCTAssertEqual(lo.count, 1); XCTAssertEqual(hi.count, 1)
        XCTAssertGreaterThan(hi[0], lo[0])
    }

    func testOffsetZeroForSeedEqualInputAndWhenOff() {
        let eng = StackEngine(normalization: true)
        _ = eng.seedReference(cfaFrame(stars: field, sky: 0.05), minRows: .max)  // establishes baseline
        let rgb = AstroImage(width: 4, height: 4, channels: 1, pixels: [Float](repeating: 0.05, count: 16), sourceIsLinear: true)
        XCTAssertTrue(eng.backgroundOffset(for: rgb).allSatisfy { abs($0) < 1e-6 })  // same sky → ~0
        let off = StackEngine(normalization: false)
        _ = off.seedReference(cfaFrame(stars: field, sky: 0.05), minRows: .max)
        XCTAssertTrue(off.backgroundOffset(for: rgb).allSatisfy { $0 == 0 })          // disabled → 0
    }

    func testOffPathByteIdenticalToUnnormalized() {
        // A stack with normalization:false must equal the pre-feature behavior (no normalizer applied).
        func run(_ normalize: Bool) -> [Float] {
            let eng = StackEngine(normalization: normalize)
            _ = eng.seedReference(cfaFrame(stars: field, sky: 0.05), minRows: .max)
            for i in 0..<5 {
                let f = cfaFrame(stars: field, sky: 0.05, w: 256, h: 256)
                if let reg = eng.register(f, minRows: .max) {
                    let (img, mask) = eng.warp(reg, minRows: .max)
                    eng.commit(image: img, mask: mask, frameWeight: reg.weight,
                               backgroundOffset: reg.backgroundOffset, minRows: .max)
                }
                _ = i
            }
            return eng.currentStack()!.pixels
        }
        // Same-sky frames → normalization offset ~0 → identical to off within fp tolerance.
        let off = run(false), on = run(true)
        XCTAssertEqual(off.count, on.count)
        for (a, b) in zip(off, on) { XCTAssertEqual(a, b, accuracy: 1e-5) }
    }

    func testHighSkySubIsPulledToReferenceBeforeCombine() {
        // Reference at sky 0.05; then feed subs at sky 0.15. With normalization the
        // stacked background stays near 0.05; without, it rises toward ~0.10.
        func stackedSky(_ normalize: Bool) -> Float {
            let eng = StackEngine(normalization: normalize)
            _ = eng.seedReference(cfaFrame(stars: field, sky: 0.05), minRows: .max)
            for _ in 0..<9 {
                let f = cfaFrame(stars: field, sky: 0.15)
                if let reg = eng.register(f, minRows: .max) {
                    let (img, mask) = eng.warp(reg, minRows: .max)
                    eng.commit(image: img, mask: mask, frameWeight: reg.weight,
                               backgroundOffset: reg.backgroundOffset, minRows: .max)
                }
            }
            let m = eng.currentStack()!
            // sky = median of a corner region (star-free)
            var corner = [Float](); for y in 0..<20 { for x in 0..<20 { corner.append(m.pixels[y*m.width+x]) } }
            corner.sort(); return corner[corner.count/2]
        }
        let on = stackedSky(true), off = stackedSky(false)
        XCTAssertLessThan(on, off)                 // normalized background is lower (pulled toward ref)
        XCTAssertLessThan(on, 0.10)                // and close to the 0.05 reference, not the 0.15 subs
    }

    func testBaselineResetOnReseed() {
        let eng = StackEngine(normalization: true)
        _ = eng.seedReference(cfaFrame(stars: field, sky: 0.20), minRows: .max)   // baseline sky 0.20
        eng.reseed()
        _ = eng.seedReference(cfaFrame(stars: field, sky: 0.05), minRows: .max)   // new baseline sky 0.05
        // A 0.05-sky sub now offsets ~0 against the new 0.05 baseline (not -0.15 against the old).
        let rgb = AstroImage(width: 4, height: 4, channels: 1, pixels: [Float](repeating: 0.05, count: 16), sourceIsLinear: true)
        XCTAssertTrue(eng.backgroundOffset(for: rgb).allSatisfy { abs($0) < 1e-6 })
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter BackgroundNormalizationEngineTests`
Expected: FAIL — `normalization:` label / `backgroundOffset` / `perChannelBackground` not found.

- [ ] **Step 3: Add the option, baseline field, and pure helpers**

In `StackEngine.swift`, add the stored flag + baseline next to `frameWeighting`/`weightBaseline`:

```swift
    private let normalization: Bool
    private var backgroundBaseline: [Float]?   // seed per-channel background; reset on reseed
```

Extend `init` (keep existing params/defaults; add `normalization`):

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

Add the pure helpers (place them near `frameWeight(stars:sigma:)`):

```swift
    /// Per-channel sky-background estimate of a frame. Median (stars are sparse,
    /// so the median ≈ sky). Estimator fixed by the Task-1 prototype.
    public func perChannelBackground(_ rgb: AstroImage) -> [Float] {
        (0..<rgb.channels).map { Float(rgb.stats[$0].median) }
    }

    /// Per-channel additive offset that pulls `rgb`'s sky to the seed reference.
    /// All-zero when normalization is off or before seeding (offset == frame − ref).
    public func backgroundOffset(for rgb: AstroImage) -> [Float] {
        guard normalization, let base = backgroundBaseline, base.count == rgb.channels else {
            return [Float](repeating: 0, count: rgb.channels)
        }
        let bg = perChannelBackground(rgb)
        return (0..<rgb.channels).map { bg[$0] - base[$0] }
    }
```

- [ ] **Step 4: Capture baseline at the seed sites and reset on reseed**

At EACH seed site, right after `weightBaseline = (stars.count, sigma)`, add:

```swift
            backgroundBaseline = perChannelBackground(rgb)
```

(There are two: the `processLocked` `referenceSize == nil` branch, and `seedReference`. Use whatever the local RGB variable is named — `rgb` in both.)

In `reseed()` (after `weightBaseline = nil`) and in the auto-reseed block in `processLocked` (after `weightBaseline = nil`), add:

```swift
            backgroundBaseline = nil
```

- [ ] **Step 5: Add `backgroundOffset` to `RegisteredFrame`, compute it in `register`**

```swift
    public struct RegisteredFrame {
        public let transform: SimilarityTransform
        public let rgb: AstroImage
        public let weight: Float
        public let backgroundOffset: [Float]        // per-channel additive normalization offset
    }
```

At the end of `register`, change the return to compute and carry the offset:

```swift
        let weight = frameWeight(stars: stars.count, sigma: sigma)
        return RegisteredFrame(transform: half, rgb: rgb, weight: weight,
                               backgroundOffset: backgroundOffset(for: rgb))
```

- [ ] **Step 6: Apply normalization BEFORE rejection in `commit` and `process`**

Change `commit` signature + body:

```swift
    public func commit(image: AstroImage, mask: [Float], frameWeight: Float = 1.0,
                       backgroundOffset: [Float] = [], minRows: Int) {
        lock.withLock {
            guard let accumulator else { return }
            let offset = backgroundOffset.isEmpty
                ? [Float](repeating: 0, count: image.channels) : backgroundOffset
            let normalized = BackgroundNormalizer.apply(image, offset: offset, minRows: minRows)
            let cleaned = rejection.apply(normalized, mask: mask)
            accumulator.add(cleaned, mask: mask, frameWeight: frameWeight, minRows: minRows)
            acceptedCount += 1
            consecutiveNoTransform = 0
        }
    }
```

In `processLocked` (live path tail), insert the normalizer between warp and rejection:

```swift
        let (warped, mask) = Warp.apply(rgb, transform: half.liftedToFullResolution())
        let normalized = BackgroundNormalizer.apply(warped, offset: backgroundOffset(for: rgb))
        let cleaned = rejection.apply(normalized, mask: mask)
        accumulator.add(cleaned, mask: mask, frameWeight: frameWeight(stars: stars.count, sigma: sigma))
```

- [ ] **Step 7: Thread `backgroundOffset` through `BatchImporter`**

In `Sources/LiveAstroCore/Pipeline/BatchImporter.swift`, add the field to `Work` and carry it:

```swift
    private struct Work {
        // ... existing fields ...
        let frameWeight: Float
        let backgroundOffset: [Float]
        // ...
    }
```

Where `Work(warped: w, frameWeight: reg.weight, ...)` is built, add `backgroundOffset: reg.backgroundOffset`. Where the rejection/no-warp `Work(warped: nil, frameWeight: 1.0, ...)` is built, add `backgroundOffset: []`. In the consumer `engine.commit(...)` call, pass `backgroundOffset: work.backgroundOffset`.

- [ ] **Step 8: Run the tests**

Run: `swift test --filter BackgroundNormalizationEngineTests`
Expected: PASS (5 tests). Then run the neighbors that touch the same code:
Run: `swift test --filter 'StackEngine|BatchImporter|FrameWeight|StackAccumulator|AutoReseed|RejectionEngine'`
Expected: PASS (no regressions — off path and weighting unaffected).

- [ ] **Step 9: Commit**

```bash
git add Sources/LiveAstroCore/Stacking/StackEngine.swift Sources/LiveAstroCore/Pipeline/BatchImporter.swift Tests/LiveAstroCoreTests/BackgroundNormalizationEngineTests.swift
git commit -m "feat: StackEngine background normalization — baseline + offset, normalize-before-rejection (TDD)"
```

---

## Task 4: Settings + AppModel + UI toggle

**Files:**
- Modify: `Sources/LiveAstroCore/Settings/SessionSettings.swift`
- Modify: `Sources/LiveAstroStudio/AppModel.swift`
- Modify: `Sources/LiveAstroStudio/ControlView.swift`
- Test: `Tests/LiveAstroCoreTests/SessionSettingsTests.swift`

**Interfaces:**
- Consumes: `StackEngine.init(..., normalization:)` (Task 3); `AppModel.makeStackEngine()`; `ControlView.helpToggle(_:isOn:help:)`.
- Produces: `SessionSettings.backgroundNormalizationEnabled: Bool` (default true, backward-compat decode `?? true`); `AppModel.backgroundNormalizationEnabled` persisted + wired; a "Match sky background" toggle row.

- [ ] **Step 1: Write the failing test (settings round-trip + backward-compat)**

Add to `Tests/LiveAstroCoreTests/SessionSettingsTests.swift`:

```swift
    func testBackgroundNormalizationDefaultsOnAndRoundTrips() throws {
        var s = SessionSettings()
        XCTAssertTrue(s.backgroundNormalizationEnabled)               // default on
        s.backgroundNormalizationEnabled = false
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(SessionSettings.self, from: data)
        XCTAssertFalse(back.backgroundNormalizationEnabled)           // round-trips
    }

    func testBackgroundNormalizationBackwardCompatDefaultsOn() throws {
        // A settings blob written before this field existed must decode to true.
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
1. Stored property: `public var backgroundNormalizationEnabled: Bool` (near `frameWeightingEnabled`).
2. `init` parameter: `backgroundNormalizationEnabled: Bool = true,` and assignment `self.backgroundNormalizationEnabled = backgroundNormalizationEnabled`.
3. `CodingKeys`: add `backgroundNormalizationEnabled` to the case list.
4. `init(from:)`: `backgroundNormalizationEnabled = try c.decodeIfPresent(Bool.self, forKey: .backgroundNormalizationEnabled) ?? true`.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter SessionSettingsTests`
Expected: PASS.

- [ ] **Step 5: Wire `AppModel`**

In `Sources/LiveAstroStudio/AppModel.swift`:
1. Add `var backgroundNormalizationEnabled = true` (near `frameWeightingEnabled` at line ~43).
2. In the `saveSettings()` builder (where `frameWeightingEnabled: frameWeightingEnabled,` is passed, ~line 163), add `backgroundNormalizationEnabled: backgroundNormalizationEnabled,`.
3. In `loadSettings`/apply (where `frameWeightingEnabled = s.frameWeightingEnabled`, ~line 181), add `backgroundNormalizationEnabled = s.backgroundNormalizationEnabled`.
4. In `makeStackEngine()` (~line 211), pass the flag:

```swift
        return StackEngine(rejection: rejection, frameWeighting: frameWeightingEnabled,
                           normalization: backgroundNormalizationEnabled)
```

- [ ] **Step 6: Add the UI toggle**

In `Sources/LiveAstroStudio/ControlView.swift`, directly after the "Weight frames by quality" `helpToggle` (~line 78), add:

```swift
                        helpToggle("Match sky background", isOn: $model.backgroundNormalizationEnabled,
                                   help: "Shift each sub's sky level to the reference before stacking, so passing gradients and drifting sky brightness don't bias the master. Additive per channel; off for an unadjusted stack.")
                            .disabled(model.isRunning || model.isImporting)
```

- [ ] **Step 7: Build + full suite**

Run: `swift build` then `swift build -c release`
Expected: both compile clean (the pre-existing `#SendableClosureCaptures` warning in AppModel is unrelated).
Run: `swift test`
Expected: full suite green (0 failures).

- [ ] **Step 8: Commit**

```bash
git add Sources/LiveAstroCore/Settings/SessionSettings.swift Sources/LiveAstroStudio/AppModel.swift Sources/LiveAstroStudio/ControlView.swift Tests/LiveAstroCoreTests/SessionSettingsTests.swift
git commit -m "feat: 'Match sky background' toggle (default on) wired to the stack engine"
```

---

## After all tasks

Dispatch the final whole-branch review (opus, most-capable model) per subagent-driven-development, then finish the branch (merge to main + push + repackage dist) per the session's established flow. The repackage recipe: `swift build -c release --scratch-path /private/tmp/las-release-build`, then `ditto` the binary + `LiveAstroStudio_LiveAstroStudio.bundle` into `dist/LiveAstroStudio.app/Contents/MacOS/`, `xattr -cr`, `codesign --force --sign -` the executable, verify with `codesign --verify --ignore-resources`.
