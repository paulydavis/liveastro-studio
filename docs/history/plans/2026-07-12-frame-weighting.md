# Frame Weighting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Weight each accepted frame's contribution to the stack by a per-frame quality scalar (background-noise inverse-variance × star count), so poor subs contribute less — improving the stacked image, live and on import.

**Architecture:** The accumulator already computes a weighted mean; frame weighting scales each frame's mask contribution by `w_f`. A Python prototype (Task 1) validates the blend and fixes the constants; `StarDetector` exposes the background σ it already computes; `StackAccumulator`/`StackEngine` apply `w_f`; a default-on toggle persists it. Weighting-off is byte-identical to today.

**Tech Stack:** Python (numpy) for the prototype; Swift 5.10 / SwiftUI / SwiftPM / XCTest for the port. Zero new Swift dependencies.

## Global Constraints

- Swift 5.10, macOS 14+. `LiveAstroCore` imports Foundation / CoreGraphics / Accelerate only. Zero external Swift dependencies.
- Stacking-core (linear master) feature — not display-path.
- Deterministic; **weighting-off (`w_f = 1.0`) is byte-identical to today's equal-weight stack**.
- Core logic TDD'd; the Python prototype is a validation artifact (scratchpad, not shipped); app/UI build-verified.
- **Prototype-first:** the blend constants `(p, wLo, wHi)` come from Task 1's validated report. The plan's starting values are `p = 1.0`, `wLo = 0.25`, `wHi = 4.0`; Task 1's report supersedes any it tunes, and the SDD controller injects the final values into the Task 3 dispatch.
- Co-Authored-By Claude trailer allowed in this repo.

**Scratchpad dir (this session):** `/private/tmp/claude-501/-Users-pauldavis/2349d1c1-e213-4a31-a397-bea11f9674d7/scratchpad` — `$SCRATCH` below.

---

### Task 1: Python prototype + validation

**Files:**
- Create: `$SCRATCH/frame_weighting.py` (not shipped)

**Interfaces:**
- Produces (in the report): validated `(p, wLo, wHi)` + a metrics table showing weighted beats equal-weight on the degraded set.

- [ ] **Step 1: Write the prototype**

Create `$SCRATCH/frame_weighting.py`:

```python
import numpy as np, os
SCRATCH = os.path.dirname(os.path.abspath(__file__))
rng = np.random.default_rng(7)

H, W = 200, 300
def field():
    """Common star field (fixed positions/fluxes) as a clean signal image [0,1]."""
    img = np.zeros((H, W), np.float32)
    for _ in range(120):
        cy, cx = rng.integers(10, H-10), rng.integers(10, W-10)
        a = rng.uniform(0.3, 0.9)
        yy, xx = np.mgrid[cy-4:cy+5, cx-4:cx+5]
        img[cy-4:cy+5, cx-4:cx+5] += a*np.exp(-(((xx-cx)**2+(yy-cy)**2)/(2*1.5**2)))
    return np.clip(img, 0, 1)

SIGNAL = field()
STARS0 = 120

def make_sub(noise, gradient=0.0, star_drop=0.0):
    """One sub: signal + read noise (+ optional gradient, + optional dropped stars)."""
    img = SIGNAL.copy()
    if star_drop > 0:                       # simulate haze: attenuate star flux
        img *= (1.0 - star_drop)
    img = img + rng.normal(0, noise, img.shape).astype(np.float32)
    if gradient > 0:
        yy, xx = np.mgrid[0:H, 0:W]
        img = img + (gradient*(xx/W)).astype(np.float32)
    return np.clip(img, 0, 1)

def bg_sigma(sub):
    """Median background σ over a coarse grid (mirrors StarDetector sigGrid median)."""
    sigs = []
    gh, gw = 8, 12
    for gy in range(gh):
        for gx in range(gw):
            cell = sub[gy*H//gh:(gy+1)*H//gh, gx*W//gw:(gx+1)*W//gw].ravel()
            med = np.median(cell); mad = np.median(np.abs(cell-med))
            sigs.append(max(1.4826*mad, 1e-6))
    return float(np.median(sigs))

def star_count(sub):
    """Crude count: bright local peaks above sky+5σ (proxy for detected stars)."""
    s = bg_sigma(sub); thr = np.median(sub) + 5*s
    return int((sub > thr).sum() // 9)      # ~9 px per star blob

def weight(sub, s0, sig0, p, lo, hi):
    return float(np.clip((star_count(sub)/max(s0,1))**p * (sig0/max(bg_sigma(sub),1e-6))**2, lo, hi))

def star_snr(stack):
    """Peak-star signal over background σ — higher is better."""
    return float((stack.max() - np.median(stack)) / bg_sigma(stack))

if __name__ == "__main__":
    # 10 clean subs + 4 degraded (noisy / gradient / hazy).
    subs  = [make_sub(0.03) for _ in range(10)]
    subs += [make_sub(0.10), make_sub(0.03, gradient=0.15),
             make_sub(0.08, star_drop=0.5), make_sub(0.12)]
    s0, sig0 = star_count(subs[0]), bg_sigma(subs[0])   # seed = subs[0]

    P, LO, HI = 1.0, 0.25, 4.0                           # starting knobs — tune here
    equal = np.mean(subs, axis=0)
    ws = np.array([weight(s, s0, sig0, P, LO, HI) for s in subs], np.float32)
    weighted = (np.tensordot(ws, subs, axes=(0,0)) / ws.sum()).astype(np.float32)

    print(f"weights: {np.round(ws,3)}")
    print(f"{'combine':10} {'bgSigma':>10} {'starSNR':>10}")
    for name, st in [("equal", equal), ("weighted", weighted)]:
        print(f"{name:10} {bg_sigma(st):10.5f} {star_snr(st):10.4f}")
    print(f"\nCHOSEN: p={P}, wLo={LO}, wHi={HI}")
```

- [ ] **Step 2: Run it**

Run: `python3 "$SCRATCH/frame_weighting.py"` (deps: `pip3 install numpy`)
Expected: a weights vector (degraded subs should get visibly lower weights) and a table of `bgSigma` + `starSNR` for equal vs weighted.

- [ ] **Step 3: Validate + tune (the gate)**

Confirm the **weighted** combine has **lower `bgSigma` and higher `starSNR`** than equal-weight (weighting suppressed the degraded subs). Confirm the degraded subs (indices 10–13) got weights `< 1` while clean subs stayed near 1. If weighting doesn't clearly win, raise `P` (lean harder on star count) or tighten `LO`, re-run, until it does. Record the final `(p, wLo, wHi)` and the metrics table.

- [ ] **Step 4: Report**

```bash
cd ~/Desktop/liveastro-studio
git add -f "$SCRATCH/frame_weighting.py" 2>/dev/null || true
git commit -m "chore: frame-weighting Python prototype (validation artifact)" || echo "scratch not tracked — recipe in report"
```
Report the weights vector, the equal-vs-weighted metrics, and the chosen `(p, wLo, wHi)`.

---

### Task 2: `StarDetector.detectWithStats` — expose the background σ

**Files:**
- Modify: `Sources/LiveAstroCore/Stacking/StarDetector.swift`
- Test: `Tests/LiveAstroCoreTests/StarDetectorStatsTests.swift`

**Interfaces:**
- Produces: `public static func detectWithStats(luminance:width:height:maxStars:sigmaThreshold:) -> (stars: [Star], backgroundSigma: Float)`. `detect(...)` keeps its signature and delegates.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LiveAstroCoreTests/StarDetectorStatsTests.swift`:

```swift
import XCTest
@testable import LiveAstroCore

final class StarDetectorStatsTests: XCTestCase {
    // Flat sky + a few Gaussian stars + noise.
    func luminance(w: Int, h: Int, noise: Float, seed: UInt64) -> [Float] {
        var g = SystemRandomNumberGeneratorStub(seed: seed)
        var px = [Float](repeating: 0.05, count: w*h)
        let stars: [(Int,Int)] = [(20,20),(60,30),(40,55),(75,70),(15,65),(50,40),(30,15),(70,20),(25,45),(55,60)]
        for (sx,sy) in stars {
            for y in max(0,sy-3)...min(h-1,sy+3) { for x in max(0,sx-3)...min(w-1,sx+3) {
                let dx = Float(x-sx), dy = Float(y-sy)
                px[y*w+x] += 0.7*expf(-(dx*dx+dy*dy)/(2*1.2*1.2))
            } }
        }
        for i in 0..<px.count { px[i] += noise * g.nextGaussian() }
        return px.map { min(max($0,0),1) }
    }

    func testDetectWithStatsMatchesDetectAndReturnsPositiveSigma() {
        let w = 90, h = 90
        let lum = luminance(w: w, h: h, noise: 0.01, seed: 1)
        let r = StarDetector.detectWithStats(luminance: lum, width: w, height: h)
        XCTAssertEqual(r.stars, StarDetector.detect(luminance: lum, width: w, height: h))
        XCTAssertGreaterThan(r.backgroundSigma, 0)
    }

    func testNoisierFrameHasLargerSigma() {
        let w = 90, h = 90
        let quiet = StarDetector.detectWithStats(luminance: luminance(w: w, h: h, noise: 0.01, seed: 2), width: w, height: h)
        let noisy = StarDetector.detectWithStats(luminance: luminance(w: w, h: h, noise: 0.05, seed: 2), width: w, height: h)
        XCTAssertGreaterThan(noisy.backgroundSigma, quiet.backgroundSigma)
    }
}

/// Deterministic Gaussian noise source for reproducible tests.
struct SystemRandomNumberGeneratorStub {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state }
    mutating func nextGaussian() -> Float {
        let u1 = Float(next() >> 11) * (1.0/9007199254740992.0)
        let u2 = Float(next() >> 11) * (1.0/9007199254740992.0)
        return sqrtf(-2*logf(max(u1,1e-7))) * cosf(2 * .pi * u2)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter StarDetectorStatsTests`
Expected: FAIL — `type 'StarDetector' has no member 'detectWithStats'`.

- [ ] **Step 3: Refactor `detect` into `detectWithStats`**

In `Sources/LiveAstroCore/Stacking/StarDetector.swift`:
1. Rename the current `detect(luminance:width:height:maxStars:sigmaThreshold:) -> [Star]` to `detectWithStats(luminance:width:height:maxStars:sigmaThreshold:) -> (stars: [Star], backgroundSigma: Float)`, keeping the entire existing body unchanged up to where it returns the star array.
2. Just before the existing `return stars`, compute the median of the already-built `sigGrid` and return the tuple:
```swift
        var sig = sigGrid            // sigGrid is already computed above (per-cell 1.4826·MAD)
        sig.sort()
        let backgroundSigma = sig.isEmpty ? Float(1e-6) : sig[sig.count / 2]
        return (stars, backgroundSigma)
```
3. Re-add `detect` as a thin delegate so existing callers/tests are unchanged:
```swift
    public static func detect(luminance: [Float], width: Int, height: Int,
                              maxStars: Int = 60, sigmaThreshold: Double = 5.0) -> [Star] {
        detectWithStats(luminance: luminance, width: width, height: height,
                        maxStars: maxStars, sigmaThreshold: sigmaThreshold).stars
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter StarDetectorStatsTests`
Expected: PASS.
Run: `swift test --filter StarDetectorTests`
Expected: PASS (existing detect behavior unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Stacking/StarDetector.swift Tests/LiveAstroCoreTests/StarDetectorStatsTests.swift
git commit -m "feat: StarDetector.detectWithStats exposes median background sigma (TDD)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Accumulator frame-weight + StackEngine weighting

**Files:**
- Modify: `Sources/LiveAstroCore/Stacking/StackAccumulator.swift`
- Modify: `Sources/LiveAstroCore/Stacking/StackEngine.swift`
- Test: `Tests/LiveAstroCoreTests/FrameWeightTests.swift`

**Interfaces:**
- Consumes: `StarDetector.detectWithStats` (Task 2); Task-1 validated `(p, wLo, wHi)` (starting: 1.0 / 0.25 / 4.0).
- Produces: `StackAccumulator.add(_:mask:frameWeight:minRows:)`; `StackEngine.init(..., frameWeighting: Bool = false)`; `StackEngine.frameWeight(stars:sigma:) -> Float`; `RegisteredFrame.weight: Float`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LiveAstroCoreTests/FrameWeightTests.swift`:

```swift
import XCTest
@testable import LiveAstroCore

final class FrameWeightTests: XCTestCase {
    func img(_ w: Int, _ h: Int, _ v: Float) -> AstroImage {
        AstroImage(width: w, height: h, channels: 1, pixels: [Float](repeating: v, count: w*h), sourceIsLinear: true)
    }

    func testWeightedAddIsWeightedAverage() {
        let w = 4, h = 4, ones = [Float](repeating: 1, count: 16)
        let acc = StackAccumulator(width: w, height: h, channels: 1)
        acc.add(img(w, h, 0.9), mask: ones, frameWeight: 2.0)   // good frame, weight 2
        acc.add(img(w, h, 0.3), mask: ones, frameWeight: 1.0)   // poor frame, weight 1
        // weighted mean = (2·0.9 + 1·0.3) / 3 = 0.7
        for v in acc.mean().pixels { XCTAssertEqual(v, 0.7, accuracy: 1e-5) }
    }

    func testFrameWeightOneEqualsUnweighted() {
        let w = 4, h = 4, ones = [Float](repeating: 1, count: 16)
        let a = StackAccumulator(width: w, height: h, channels: 1)
        a.add(img(w, h, 0.4), mask: ones)                       // default frameWeight 1.0
        let b = StackAccumulator(width: w, height: h, channels: 1)
        b.add(img(w, h, 0.4), mask: ones, frameWeight: 1.0)
        XCTAssertEqual(a.mean().pixels, b.mean().pixels)
    }

    func testFrameWeightHelperNeutralWhenOff() {
        let e = StackEngine(frameWeighting: false)
        XCTAssertEqual(e.frameWeight(stars: 5, sigma: 0.01), 1.0)   // off → always 1
    }

    func testFrameWeightNoisyFrameLowerThanSeed() {
        let e = StackEngine(frameWeighting: true)
        e.setWeightBaselineForTesting(stars: 100, sigma: 0.02)
        // same stars, 2× noisier → (0.02/0.04)^2 = 0.25 → clamped at wLo 0.25
        XCTAssertEqual(e.frameWeight(stars: 100, sigma: 0.04), 0.25, accuracy: 1e-6)
        // seed-equal inputs → 1.0
        XCTAssertEqual(e.frameWeight(stars: 100, sigma: 0.02), 1.0, accuracy: 1e-6)
        // far fewer stars → below 1
        XCTAssertLessThan(e.frameWeight(stars: 40, sigma: 0.02), 1.0)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter FrameWeightTests`
Expected: FAIL — `extra argument 'frameWeight'` / no member `frameWeight`.

- [ ] **Step 3: Add `frameWeight` to `StackAccumulator.add`**

In `Sources/LiveAstroCore/Stacking/StackAccumulator.swift`, change `add` to take a `frameWeight` and scale the mask contribution:

```swift
    public func add(_ image: AstroImage, mask: [Float], frameWeight: Float = 1.0, minRows: Int = 64) {
        precondition(image.width == width && image.height == height && image.channels == channels)
        let plane = width * height
        let w = width, chans = channels
        image.pixels.withUnsafeBufferPointer { src in
            mask.withUnsafeBufferPointer { m in
                sum.withUnsafeMutableBufferPointer { sumBuf in
                    weight.withUnsafeMutableBufferPointer { wBuf in
                        Parallel.rows(height, minRows: minRows) { rows in
                            for y in rows {
                                for x in 0..<w {
                                    let i = y * w + x
                                    let mv = frameWeight * m[i]
                                    guard mv > 0 else { continue }
                                    wBuf[i] += mv
                                    for c in 0..<chans { sumBuf[c * plane + i] += mv * src[c * plane + i] }
                                }
                            }
                        }
                    }
                }
            }
        }
        frameCount += 1
    }
```
(`frameWeight: 1.0` default → `mv = 1·m[i] = m[i]` → byte-identical to before.)

- [ ] **Step 4: Add the weighting to `StackEngine`**

In `Sources/LiveAstroCore/Stacking/StackEngine.swift`:

(a) Add stored state + the option (near the other stored props):
```swift
    private let frameWeighting: Bool
    private var weightBaseline: (stars: Int, sigma: Float)?    // set at seed, reset on reseed
    // Task-1 validated constants:
    static let weightExponent: Float = 1.0
    static let weightLo: Float = 0.25
    static let weightHi: Float = 4.0
```
(b) In `init`, add `frameWeighting: Bool = false` and store it (keep existing params + defaults).
(c) Add the pure helper + a test seam:
```swift
    /// Per-frame stacking weight from star count + background σ, relative to the
    /// seed (stars₀, σ₀). Returns 1.0 when weighting is off or before seeding.
    public func frameWeight(stars: Int, sigma: Float) -> Float {
        guard frameWeighting, let base = weightBaseline else { return 1.0 }
        let starTerm = powf(Float(stars) / Float(max(base.stars, 1)), Self.weightExponent)
        let noiseTerm = powf(base.sigma / max(sigma, 1e-6), 2)
        return min(max(starTerm * noiseTerm, Self.weightLo), Self.weightHi)
    }

    func setWeightBaselineForTesting(stars: Int, sigma: Float) { weightBaseline = (stars, sigma) }
```
(d) Everywhere the engine currently calls `StarDetector.detect(luminance: lum, width: hw, height: hh)`, switch to `detectWithStats` and keep the σ. In `seedReference` and the seeding branch of `process`, after a successful seed set `weightBaseline = (stars.count, sigma)`. On reseed (where `referenceStars = []` is set), also set `weightBaseline = nil`.
(e) `RegisteredFrame` gains `public let weight: Float`. In `register`, compute `let weight = frameWeight(stars: stars.count, sigma: sigma)` (reads `weightBaseline`, set once at seed — a lock-free read consistent with the documented register contract) and pass it into the returned `RegisteredFrame`. In `commit`, call `accumulator.add(cleaned, mask: mask, frameWeight: reg.weight, minRows: minRows)`. Wait — `commit` receives `image`/`mask`, not the `RegisteredFrame`; thread the weight through: give `commit` a `frameWeight: Float` parameter (BatchImporter passes `reg.weight`), OR carry the weight on the warped result. Simplest: add `frameWeight: Float` to `commit(image:mask:frameWeight:minRows:)` and have BatchImporter pass `reg.weight`. Update `BatchImporter` accordingly (Task-3 modifies BatchImporter's `commit` call site to pass the weight; the `Work`/warp path already carries the `RegisteredFrame` transiently — capture `reg.weight` alongside the warped image).
(f) In the monolithic `process` (live path), after computing `stars`/`sigma` and warping, call `accumulator.add(cleaned, mask: mask, frameWeight: frameWeight(stars: stars.count, sigma: sigma))`.

- [ ] **Step 5: Run tests + off-path parity + full stacking suite**

Run: `swift test --filter FrameWeightTests`
Expected: PASS (4 tests).
Run: `swift test --filter StackEngineTests` and `swift test --filter StackEngineStagedTests` and `swift test --filter BatchImporterTests` and `swift test --filter AutoReseedTests`
Expected: PASS — with the default `frameWeighting: false`, every existing stack is byte-identical (the off path uses `frameWeight` 1.0). If `BatchImporterTests`' serial-vs-batch parity relies on `process` vs staged producing the same stack, both use weight 1.0 when off → still equal.

- [ ] **Step 6: Commit**

```bash
git add Sources/LiveAstroCore/Stacking/StackAccumulator.swift Sources/LiveAstroCore/Stacking/StackEngine.swift Sources/LiveAstroCore/Pipeline/BatchImporter.swift Tests/LiveAstroCoreTests/FrameWeightTests.swift
git commit -m "feat: quality-based frame weighting in the stack engine (TDD, off = byte-identical)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Settings + AppModel + ControlView toggle

**Files:**
- Modify: `Sources/LiveAstroCore/Settings/SessionSettings.swift`
- Modify: `Sources/LiveAstroStudio/AppModel.swift`
- Modify: `Sources/LiveAstroStudio/ControlView.swift`
- Test: `Tests/LiveAstroCoreTests/SessionSettingsTests.swift` (extend, or the existing settings test file)

**Interfaces:**
- Consumes: `StackEngine.init(..., frameWeighting:)` (Task 3).
- Produces: `SessionSettings.frameWeightingEnabled: Bool`; `AppModel.frameWeightingEnabled`.

- [ ] **Step 1: Write the failing test (backward-compat decode)**

Add to the SessionSettings test file:

```swift
    func testFrameWeightingDefaultsTrueAndBackwardCompat() throws {
        // An old settings blob without the key decodes to true (default on).
        let old = #"{"sourceModeRaw":"Raw subs (native stacking)","filePrefix":"Light_","neutralizeBackground":false,"subExposureSeconds":10,"targetName":"M8","calibration":{},"rejectionEnabled":true,"rejectionStrength":"medium"}"#
        let s = try JSONDecoder().decode(SessionSettings.self, from: Data(old.utf8))
        XCTAssertTrue(s.frameWeightingEnabled)
    }
```
(If the SessionSettings init/`calibration` shape makes that literal awkward, build a `SessionSettings(...)`, encode it, strip the `frameWeightingEnabled` key from the JSON dict, and decode — asserting the field comes back `true`.)

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter SessionSettingsTests`
Expected: FAIL — `value of type 'SessionSettings' has no member 'frameWeightingEnabled'`.

- [ ] **Step 3: Add the setting (mirror `rejectionEnabled` exactly)**

In `Sources/LiveAstroCore/Settings/SessionSettings.swift`, mirror every touch point used by `rejectionEnabled`: add `public var frameWeightingEnabled: Bool`; add to the memberwise init with `frameWeightingEnabled: Bool = true`; add to `CodingKeys`; in `init(from:)` add `frameWeightingEnabled = try c.decodeIfPresent(Bool.self, forKey: .frameWeightingEnabled) ?? true`; assign it in the memberwise init body. (Encode stays synthesized.)

- [ ] **Step 4: Wire AppModel + build the engine with it**

In `Sources/LiveAstroStudio/AppModel.swift`:
- Add `var frameWeightingEnabled = true` (near `rejectionEnabled`).
- In the settings-save path (where `rejectionEnabled: rejectionEnabled` is written) add `frameWeightingEnabled: frameWeightingEnabled`.
- In the settings-load path (where `rejectionEnabled = s.rejectionEnabled`) add `frameWeightingEnabled = s.frameWeightingEnabled`.
- In `makeStackEngine()`, pass the option: `return StackEngine(rejection: rejection, frameWeighting: frameWeightingEnabled)`.

- [ ] **Step 5: Add the ControlView toggle**

In `Sources/LiveAstroStudio/ControlView.swift`, next to the `Toggle("Reject outliers (σ-clip)", isOn: $model.rejectionEnabled)` line, add:
```swift
                        Toggle("Weight frames by quality", isOn: $model.frameWeightingEnabled)
                            .help("Give sharper, lower-noise subs more influence in the stack (star count + background noise). Turn off for an equal-weight stack.")
```

- [ ] **Step 6: Run tests + build**

Run: `swift test --filter SessionSettingsTests` → PASS.
Run: `swift test --filter LiveAstroCoreTests` → all pass.
Run: `swift build` → clean.
Run: `swift build -c release` → succeeds.

- [ ] **Step 7: Manual check (RELEASE)**

Launch; in the session controls confirm the **"Weight frames by quality"** toggle (default on) sits by the σ-clip toggle; import a set that includes a couple of poor subs, confirm a session runs and the master builds; toggle off and confirm equal-weight still works; confirm the setting persists across relaunch.

- [ ] **Step 8: Commit**

```bash
git add Sources/LiveAstroCore/Settings/SessionSettings.swift Sources/LiveAstroStudio/AppModel.swift Sources/LiveAstroStudio/ControlView.swift Tests/LiveAstroCoreTests/SessionSettingsTests.swift
git commit -m "feat: 'Weight frames by quality' toggle (default on) wired to the stack engine

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage:**
- Prototype validating weighted-beats-equal + fixing `(p,wLo,wHi)` → Task 1. ✅
- σ exposed near-free from `sigGrid` → Task 2 `detectWithStats`. ✅
- Accumulator scales by `w_f` → Task 3 `add(frameWeight:)`. ✅
- Weight = `clamp((stars/stars₀)^p·(σ₀/σ)², lo, hi)`, seed baseline, reset on reseed → Task 3 `frameWeight` + baseline. ✅
- Applies live + import (process + staged commit) → Task 3 (e)/(f). ✅
- Off = byte-identical → Task 3 default `frameWeighting:false` + `frameWeight:1.0` + parity run in Step 5. ✅
- Default-on toggle, persisted → Task 4. ✅
- Normalization deferred → not in scope. ✅

**2. Placeholder scan:** No lazy TBDs. The `(p,wLo,wHi)` come from Task 1 with concrete starting values written throughout. Every code step shows complete code; the T2 detect refactor and T3 (e) commit-threading are described with the exact new signatures + snippets (existing bodies are moved, not re-transcribed).

**3. Type consistency:** `detectWithStats(...) -> (stars:[Star], backgroundSigma:Float)`, `add(_:mask:frameWeight:minRows:)`, `frameWeight(stars:sigma:)`, `RegisteredFrame.weight`, `commit(image:mask:frameWeight:minRows:)`, `StackEngine.init(..., frameWeighting:)`, `SessionSettings.frameWeightingEnabled`, `AppModel.frameWeightingEnabled` — names/signatures are consistent across the tasks that define and consume them. Constants `weightExponent/weightLo/weightHi` defined once in Task 3.
