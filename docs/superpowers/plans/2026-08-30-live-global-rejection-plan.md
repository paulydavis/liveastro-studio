# Live Global Rejection (Real-Time Trail-Free Stacking) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While live-stacking, remove satellite trails / single-frame outliers from the broadcast outputs (and final `master.fit`) in near-real-time via a background refiner that recomputes a robustly-clipped full-survivor master, without changing the online engine or the operator's per-sub preview.

**Architecture:** A pure `GlobalCombine` core (robust median/MAD center over a RAM sample → weighted clipped-mean output over all survivors) is driven by a background `GlobalRefiner`. The refiner reuses each accepted sub's cached registration (`SubRegistration`) so it re-warps but never re-registers, reads subs from the local relay, and atomically publishes a clean master that broadcast/`latest.png`/`master.fit` prefer when a composite `freshnessKey` matches. The online accumulator and preview are untouched.

**Tech Stack:** Swift 5.9 / SwiftPM, XCTest. macOS 14+. Targets `LiveAstroCore` (pure/pipeline) and `LiveAstroStudio` (app/UI).

**Spec:** `docs/superpowers/specs/2026-08-30-live-global-rejection-design.md` (rev 2, `fd7c15c`).

## Global Constraints

- Online path (`StackEngine.processDetailed`, `handleNative`, the accumulator) and the operator per-sub preview are **not changed in behavior**. Feature OFF ⇒ byte-identical outputs to today (pin a test).
- Refiner runs entirely off the online consumer; never blocks per-sub ingest or preview. **Memory bound: the capped center SAMPLE held in RAM (≤ `maxSampleBytes`, default `6_000_000_000`) PLUS O(one image) streaming-output accumulators — it is NOT O(one image) overall.**
- **Generation-scoped:** combine only subs of the *current* `stackGeneration`; a reseed starts a new generation and prior-generation transforms are excluded.
- **Weighted** combine using the online `appliedWeight` (`frameWeight(stars, sigma·effectiveScale)`).
- Per-sub order matches the engine: **warp first, then warped-domain leveling** (`GradientLeveler.apply(sub, ref, effectiveScale)`), never pre-warp leveling.
- Output via `RestackPlanning.encodeMaster`; **STACKCNT/TOTALEXP = global survivor count**.
- Registration reused, never recomputed in the refiner.
- Bounded shutdown: an `end()`-triggered pass obeys the live-drain timeout discipline; any failure falls back to the online master.
- **Product minimum: the feature engages at ≥ `minSubs` (= 5) accepted subs** — the shallow-stack case is the whole point, and N=5 is a supported production case (proven by the GlobalCombine unit test). `minSampleFrames = 11` is ONLY the floor for the capped *deep-stack* subset and never exceeds the actual survivor count (at N=5 the sample is all 5).
- Sample subset is **deterministic evenly-strided** (no RNG), adjusted to **odd count**, exactly bounded (never > `maxSampleFrames`). Capped case is a *sample-derived* center + full-survivor output, never claimed as full-set median.
- Commit trailer `Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j`; NO Co-Authored-By. Branch `feature/live-global-rejection`; never commit to main.

---

## File Structure

- Create `Sources/LiveAstroCore/Stacking/GlobalCombine.swift` — pure core: `robustCenter`, `clippedWeightedMean`, `CombineMethod`.
- Create `Sources/LiveAstroCore/Pipeline/SubRegistration.swift` — `SubRegistration` struct + `sampleIndices` policy helper.
- Create `Sources/LiveAstroCore/Pipeline/GlobalRefiner.swift` — orchestrator (loader-injected, cancellable).
- Modify `Sources/LiveAstroCore/Stacking/StackEngine.swift` — surface registration payload + `stackGeneration`/`referenceIdentity` for accepted subs (additive).
- Modify `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` — capture cache, wire refiner, `publishedMaster` + `freshnessKey`, output preference, `end()` flow, trigger.
- Modify `Sources/LiveAstroStudio/AppModel.swift` + `Sources/LiveAstroStudio/CaptureSettingsView.swift` — toggle, gating, status.
- Tests: `Tests/LiveAstroCoreTests/GlobalCombineTests.swift`, `GlobalRefinerTests.swift`, `SubRegistrationTests.swift`, `LiveGlobalRejectionTests.swift`.

Base commit for reviews: `git rev-parse HEAD` before Task 1 (record it).

---

## Task 1: `GlobalCombine.robustCenter` — per-pixel median + MAD over a sample

**Files:**
- Create: `Sources/LiveAstroCore/Stacking/GlobalCombine.swift`
- Test: `Tests/LiveAstroCoreTests/GlobalCombineTests.swift`

**Interfaces:**
- Consumes: `AstroImage` (`width, height, channels, pixels: [Float], sourceIsLinear`).
- Produces: `enum GlobalCombine.CombineMethod { case clippedMean }`; `static func robustCenter(sample: [(image: AstroImage, mask: [Float])]) -> (center: AstroImage, scale: [Float])?` — `center.pixels` and `scale` both length `width*height*channels`; `mask` is length `width*height` (shared across channels, `>0` == in-bounds). `scale = 1.4826 · MAD`. Returns nil if `sample` empty or dimensions disagree.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class GlobalCombineTests: XCTestCase {
    /// A single-channel image with a constant value; mask all in-bounds.
    private func img(_ w: Int, _ h: Int, _ v: Float) -> (AstroImage, [Float]) {
        (AstroImage(width: w, height: h, channels: 1,
                    pixels: [Float](repeating: v, count: w*h), sourceIsLinear: true),
         [Float](repeating: 1, count: w*h))
    }

    func testRobustCenterIsMedianAndIgnoresOutlier() {
        // 5 frames: four ~1.0, one bright 9.0 trail. Median must be 1.0, unmoved by the outlier.
        let vals: [Float] = [1.0, 1.0, 1.0, 1.0, 9.0]
        let sample = vals.map { img(2, 2, $0) }
        let out = GlobalCombine.robustCenter(sample: sample)
        XCTAssertNotNil(out)
        for p in out!.center.pixels { XCTAssertEqual(p, 1.0, accuracy: 1e-6) }   // median, not mean (2.6)
        // MAD of {1,1,1,1,9} about median 1 = median{0,0,0,0,8} = 0 → scale 0 (all-equal core).
        for s in out!.scale { XCTAssertEqual(s, 0.0, accuracy: 1e-6) }
    }

    func testRobustCenterScaleIsMADScaled() {
        let vals: [Float] = [1.0, 2.0, 3.0, 4.0, 100.0]     // median 3; |v-3|={2,1,0,1,97}; MAD=1
        let sample = vals.map { img(1, 1, $0) }
        let out = GlobalCombine.robustCenter(sample: sample)!
        XCTAssertEqual(out.center.pixels[0], 3.0, accuracy: 1e-6)
        XCTAssertEqual(out.scale[0], 1.4826, accuracy: 1e-4)  // 1.4826 * MAD(=1)
    }

    func testRobustCenterNilOnEmpty() {
        XCTAssertNil(GlobalCombine.robustCenter(sample: []))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GlobalCombineTests/testRobustCenterIsMedianAndIgnoresOutlier`
Expected: FAIL — `GlobalCombine` type not found.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Pure full-set robust combine used by the live GlobalRefiner (and, later, the import surface).
/// No I/O, no knowledge of live/import/relay. Two composable pieces: a robust median/MAD CENTER
/// estimated over a RAM sample, and a weighted clipped MEAN accumulated over all survivors.
public enum GlobalCombine {
    public enum CombineMethod { case clippedMean }   // future: case median (output)

    /// Per-pixel·channel median + MAD over `sample` (masked). `scale = 1.4826·MAD` (robust σ).
    /// `mask` length == width*height (shared across channels; >0 == in-bounds). Center/scale
    /// length == width*height*channels. nil if sample empty or a frame's dims disagree.
    public static func robustCenter(sample: [(image: AstroImage, mask: [Float])])
        -> (center: AstroImage, scale: [Float])? {
        guard let first = sample.first else { return nil }
        let w = first.image.width, h = first.image.height, c = first.image.channels
        let plane = w * h, n = plane * c
        for s in sample where s.image.width != w || s.image.height != h
            || s.image.channels != c || s.mask.count != plane || s.image.pixels.count != n {
            return nil
        }
        var center = [Float](repeating: 0, count: n)
        var scale = [Float](repeating: 0, count: n)
        var vbuf = [Float](); vbuf.reserveCapacity(sample.count)
        var dbuf = [Float](); dbuf.reserveCapacity(sample.count)
        for idx in 0..<n {
            let p = idx % plane
            vbuf.removeAll(keepingCapacity: true)
            for s in sample where s.mask[p] > 0 { vbuf.append(s.image.pixels[idx]) }
            if vbuf.isEmpty { continue }               // no coverage → center/scale stay 0
            let med = median(&vbuf)
            center[idx] = med
            dbuf.removeAll(keepingCapacity: true)
            for v in vbuf { dbuf.append(abs(v - med)) }
            scale[idx] = 1.4826 * median(&dbuf)
        }
        return (AstroImage(width: w, height: h, channels: c, pixels: center, sourceIsLinear: true), scale)
    }

    /// In-place median (sorts the buffer). Even count → mean of the two middle elements.
    static func median(_ a: inout [Float]) -> Float {
        a.sort()
        let m = a.count / 2
        return a.count % 2 == 1 ? a[m] : (a[m - 1] + a[m]) / 2
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter GlobalCombineTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Stacking/GlobalCombine.swift Tests/LiveAstroCoreTests/GlobalCombineTests.swift
git commit -m "feat: GlobalCombine.robustCenter (per-pixel median/MAD)

Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j"
```

---

## Task 2: `GlobalCombine.clippedWeightedMean` — streamed weighted clipped mean

**Files:**
- Modify: `Sources/LiveAstroCore/Stacking/GlobalCombine.swift`
- Test: `Tests/LiveAstroCoreTests/GlobalCombineTests.swift`

**Interfaces:**
- Consumes: `robustCenter` output.
- Produces: `static func clippedWeightedMean(frames: () -> AnyIterator<(image: AstroImage, mask: [Float], weight: Float)>, center: AstroImage, scale: [Float], kappa: Float) -> (image: AstroImage, coverage: [Float])?`. `frames` is a factory (fresh iterator each call — the refiner may stream from disk). Accept `v` where `scale[idx] <= scaleFloor` (no clipping) OR `|v-center[idx]| <= kappa·scale[idx]`; output `Σw·v / Σw`. `coverage` length width*height, `1` where any survivor contributed, else `0`. nil on dim mismatch/empty.

- [ ] **Step 1: Write the failing test**

```swift
extension GlobalCombineTests {
    private func wimg(_ w: Int, _ h: Int, _ v: Float, weight: Float) -> (AstroImage, [Float], Float) {
        (AstroImage(width: w, height: h, channels: 1,
                    pixels: [Float](repeating: v, count: w*h), sourceIsLinear: true),
         [Float](repeating: 1, count: w*h), weight)
    }

    func testClippedWeightedMeanRemovesTrailAtN5() {
        // 5 frames, four = 1.0, one bright 9.0 (the "trail"). center=1, scale=0 → floor accepts all,
        // BUT with a tiny scale floor the trail is > center+kappa*floor and must be clipped.
        let frames = [wimg(2,2,1, weight: 1), wimg(2,2,1, weight: 1), wimg(2,2,1, weight: 1),
                      wimg(2,2,1, weight: 1), wimg(2,2,9, weight: 1)]
        let center = GlobalCombine.robustCenter(sample: frames.map { ($0.0, $0.1) })!  // center 1, MAD 0
        let out = GlobalCombine.clippedWeightedMean(
            frames: { AnyIterator(frames.map { (image: $0.0, mask: $0.1, weight: $0.2) }.makeIterator()) },
            center: center.center, scale: center.scale, kappa: 3.0)!
        // Zero-MAD core: sigma = max(0, scaleFloor); |9-1| = 8 ≫ 3·floor → trail rejected.
        // Mean of the four 1.0 survivors == 1.0 (NOT (4*1+9)/5 = 2.6).
        for p in out.image.pixels { XCTAssertEqual(p, 1.0, accuracy: 1e-6) }
        for cov in out.coverage { XCTAssertEqual(cov, 5.0, accuracy: 1e-6) }   // depth = 5 frames covered
    }

    func testClippedWeightedMeanHonorsWeights() {
        // Two clean frames, values 2 and 4, weights 3 and 1 → weighted mean = (3*2+1*4)/4 = 2.5.
        let frames = [wimg(1,1,2, weight: 3), wimg(1,1,4, weight: 1)]
        let center = GlobalCombine.robustCenter(sample: frames.map { ($0.0, $0.1) })!  // median 3, MAD 1
        let out = GlobalCombine.clippedWeightedMean(
            frames: { AnyIterator(frames.map { (image: $0.0, mask: $0.1, weight: $0.2) }.makeIterator()) },
            center: center.center, scale: center.scale, kappa: 5.0)!   // wide κ: keep both
        XCTAssertEqual(out.image.pixels[0], 2.5, accuracy: 1e-6)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter GlobalCombineTests/testClippedWeightedMeanRemovesTrailAtN5`
Expected: FAIL — `clippedWeightedMean` not found.

- [ ] **Step 3: Implement**

```swift
extension GlobalCombine {
    /// Floor for the robust σ used as the clip denominator: `sigma = max(scale, scaleFloor)`.
    /// Ensures a zero-MAD core ([1,1,1,1,9]) still rejects the gross outlier, and guards
    /// divide-by-tiny. Small absolute value; real data's MAD-derived scale dominates it.
    /// Tunable to the sensor noise floor.
    static let scaleFloor: Float = 1e-7

    public static func clippedWeightedMean(
        frames: () -> AnyIterator<(image: AstroImage, mask: [Float], weight: Float)>,
        center: AstroImage, scale: [Float], kappa: Float
    ) -> (image: AstroImage, coverage: [Float])? {
        let w = center.width, h = center.height, c = center.channels
        let plane = w * h, n = plane * c
        guard scale.count == n else { return nil }
        var sumW = [Float](repeating: 0, count: n)
        var sumWV = [Float](repeating: 0, count: n)
        var coverage = [Float](repeating: 0, count: plane)   // per-pixel FRAME DEPTH (not binary)
        var any = false
        var it = frames()
        while let f = it.next() {
            guard f.image.width == w, f.image.height == h, f.image.channels == c,
                  f.mask.count == plane, f.image.pixels.count == n else { return nil }
            any = true
            for p in 0..<plane where f.mask[p] > 0 { coverage[p] += 1 }   // spatial depth per pixel
            for idx in 0..<n where f.mask[idx % plane] > 0 {
                let v = f.image.pixels[idx]
                // REAL floor as the clip denominator: a zero-MAD core (e.g. [1,1,1,1,9]) must still
                // reject the 9. `if scale>floor` (the earlier form) wrongly ACCEPTED everything at MAD=0.
                let sigma = max(scale[idx], scaleFloor)
                if abs(v - center.pixels[idx]) > kappa * sigma { continue }   // reject outlier
                sumW[idx]  += f.weight
                sumWV[idx] += f.weight * v
            }
        }
        guard any else { return nil }
        var out = [Float](repeating: 0, count: n)
        for idx in 0..<n where sumW[idx] > 0 { out[idx] = sumWV[idx] / sumW[idx] }
        return (AstroImage(width: w, height: h, channels: c, pixels: out, sourceIsLinear: true), coverage)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter GlobalCombineTests`
Expected: PASS (5 tests). The N=5 trail case is the acceptance proof the mean/σ approach failed.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Stacking/GlobalCombine.swift Tests/LiveAstroCoreTests/GlobalCombineTests.swift
git commit -m "feat: GlobalCombine.clippedWeightedMean (weighted, trail-robust at N=5)

Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j"
```

---

## Task 3: `SubRegistration` + deterministic sample policy

**Files:**
- Create: `Sources/LiveAstroCore/Pipeline/SubRegistration.swift`
- Test: `Tests/LiveAstroCoreTests/SubRegistrationTests.swift`

**Interfaces:**
- Consumes: `FileIdentity`, `SimilarityTransform`, `BackgroundExtraction.BackgroundModel`.
- Produces: `struct SubRegistration` (fields per spec §2) and `static func sampleIndices(count: Int, maxSampleFrames: Int, minSampleFrames: Int = 11) -> [Int]` — indices into an ordered survivor list; all when `count <= maxSampleFrames`; else evenly strided, floored at `minSampleFrames`, forced to an odd length; deterministic (no RNG).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class SubRegistrationTests: XCTestCase {
    func testSampleAllWhenUnderBudget() {
        XCTAssertEqual(SubRegistration.sampleIndices(count: 8, maxSampleFrames: 20), Array(0..<8))
    }
    func testSampleIsStridedOddDeterministic() {
        let a = SubRegistration.sampleIndices(count: 100, maxSampleFrames: 20)
        let b = SubRegistration.sampleIndices(count: 100, maxSampleFrames: 20)
        XCTAssertEqual(a, b)                                   // deterministic
        XCTAssertLessThanOrEqual(a.count, 21)
        XCTAssertEqual(a.count % 2, 1, "sample count must be odd for a true per-pixel median")
        XCTAssertEqual(a.first, 0)
        XCTAssertTrue(a.allSatisfy { $0 >= 0 && $0 < 100 })
        XCTAssertEqual(a, a.sorted())                          // ascending, strided
    }
    func testSampleFlooredAtMinimum() {
        // count 12, maxSampleFrames 4 → must not drop below minSampleFrames (11).
        let a = SubRegistration.sampleIndices(count: 12, maxSampleFrames: 4, minSampleFrames: 11)
        XCTAssertGreaterThanOrEqual(a.count, 11)
        XCTAssertEqual(a.count % 2, 1)
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter SubRegistrationTests/testSampleIsStridedOddDeterministic`
Expected: FAIL — `SubRegistration` not found.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Everything the GlobalRefiner needs to re-produce an accepted sub WITHOUT re-registering it.
/// Captured by the online pass; keyed by content-digest identity. The reference frame's record is
/// transform=identity, effectiveScale=1, weight=1, leveling=nil, referenceIdentity=its own identity.
public struct SubRegistration {
    public let identity: FileIdentity
    public let relayURL: URL
    public let stackGeneration: Int
    public let referenceIdentity: FileIdentity
    public let transform: SimilarityTransform            // half-res; lift in warp
    public let effectiveScale: Float                     // the APPLIED scale (1.0 when unscaled)
    public let weight: Float                             // frameWeight(stars, sigma·effectiveScale)
    public let leveling: (sub: BackgroundExtraction.BackgroundModel,
                          ref: BackgroundExtraction.BackgroundModel)?
    public init(identity: FileIdentity, relayURL: URL, stackGeneration: Int, referenceIdentity: FileIdentity,
                transform: SimilarityTransform, effectiveScale: Float, weight: Float,
                leveling: (sub: BackgroundExtraction.BackgroundModel, ref: BackgroundExtraction.BackgroundModel)?) {
        self.identity = identity; self.relayURL = relayURL; self.stackGeneration = stackGeneration
        self.referenceIdentity = referenceIdentity; self.transform = transform
        self.effectiveScale = effectiveScale; self.weight = weight; self.leveling = leveling
    }

    /// Deterministic sample selection for the robust-center estimate (spec §3 sample policy).
    /// All indices when `count <= maxSampleFrames`; else an evenly-strided subset, never fewer than
    /// `minSampleFrames`, forced to ODD length (true middle element for the per-pixel median). No RNG.
    public static func sampleIndices(count: Int, maxSampleFrames: Int, minSampleFrames: Int = 11) -> [Int] {
        guard count > 0 else { return [] }
        if count <= maxSampleFrames { return Array(0..<count) }        // shallow: use all (incl. N=5)
        // Cap: pick EXACTLY k evenly-spaced indices, k in [min(minSampleFrames,count), maxSampleFrames],
        // odd (true per-pixel median), never exceeding count. Inclusive-endpoint mapping ⇒ exact k, no
        // overshoot (the old floor-stride could yield ceil(count/stride) > maxSampleFrames).
        var k = min(maxSampleFrames, count)
        k = max(k, min(minSampleFrames, count))
        if k % 2 == 0 { k -= 1 }
        if k <= 1 { return [0] }
        return (0..<k).map { $0 * (count - 1) / (k - 1) }             // 0..count-1, ascending, distinct
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter SubRegistrationTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Pipeline/SubRegistration.swift Tests/LiveAstroCoreTests/SubRegistrationTests.swift
git commit -m "feat: SubRegistration + deterministic odd-count sample policy

Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j"
```

---

## Task 4: StackEngine seam — surface registration payload + generation

**Files:**
- Modify: `Sources/LiveAstroCore/Stacking/StackEngine.swift` (`ProcessResult` ~line 19-24; the two return sites for `.becameReference` ~299 and `.stacked` ~377; add a `stackGeneration`/reseed counter + `referenceIdentity`)
- Test: `Tests/LiveAstroCoreTests/StackEngineTests.swift` (or the existing engine test file)

**Interfaces:**
- Produces: `ProcessResult.registration: RegistrationPayload?` (optional, additive — existing equality unaffected because pre-existing callers construct with `registration: nil` default). `struct RegistrationPayload: Equatable { let transform: SimilarityTransform; let effectiveScale: Float; let weight: Float; let leveling: (sub, ref)?; let stackGeneration: Int; let referenceIdentity: FileIdentity? }`. Reference frame → `transform = .identity`, `effectiveScale = 1`, `weight = 1`, `leveling = nil`, and **`referenceIdentity = its own `RawFrame.identity`** — every sub of a generation (including the reference) carries the *same* reference identity, so grouping is consistent (`referenceIdentity` is `FileIdentity?` only because an in-memory frame may have no file identity; `stackGeneration` is the primary generation key). `stackGeneration` increments on every reseed (manual `reseed()` + auto-reseed).
- Consumes: existing `RegisteredFrame`, `levelingModels`, `effectiveScale`, `appliedWeight`.

> Note to implementer: `leveling`'s tuple isn't `Equatable` for free — give `RegistrationPayload` a hand-written `==` that compares `transform, effectiveScale, weight, stackGeneration, referenceIdentity` and treats `leveling` by nil-ness only (the models are large; identity of presence is enough for the payload's equality, which exists only for test assertions).

- [ ] **Step 1: Write the failing test**

```swift
func testProcessDetailedSurfacesRegistrationForAcceptedSubs() throws {
    let engine = StackEngine()
    let ref = starFrame(dx: 0, dy: 0)      // helper producing a ≥15-star AstroImage
    let r1 = engine.processDetailed(RawFrame(image: ref, bayerPattern: nil, bottomUp: false,
                                             timestamp: Date(timeIntervalSince1970: 0), sourceName: "ref.fit"))
    XCTAssertEqual(r1.outcome, .becameReference)
    let reg1 = try XCTUnwrap(r1.registration)
    XCTAssertEqual(reg1.transform, .identity)
    XCTAssertEqual(reg1.effectiveScale, 1.0, accuracy: 1e-6)
    XCTAssertEqual(reg1.weight, 1.0, accuracy: 1e-6)
    let gen = reg1.stackGeneration                       // reference's referenceIdentity == its own
    // (in-memory test frames have nil identity; the grouping property is asserted below via reg2)

    let sub = starFrame(dx: 1.0, dy: -0.5)
    let r2 = engine.processDetailed(RawFrame(image: sub, bayerPattern: nil, bottomUp: false,
                                             timestamp: Date(timeIntervalSince1970: 1), sourceName: "s1.fit"))
    XCTAssertEqual(r2.outcome, .stacked(frameCount: 2))
    let reg2 = try XCTUnwrap(r2.registration)
    XCTAssertNotEqual(reg2.transform, .identity)          // it moved
    XCTAssertEqual(reg2.stackGeneration, gen)             // same generation as its reference
    XCTAssertEqual(reg2.referenceIdentity, reg1.referenceIdentity)  // subs carry the reference's identity
    XCTAssertEqual(reg2.weight, r2.weight, accuracy: 1e-6)
}

func testRejectedSubHasNoRegistration() {
    let engine = StackEngine()
    _ = engine.processDetailed(seedRaw())                 // seed
    let bad = RawFrame(image: AstroImage(width: 64, height: 64, channels: 1,
                       pixels: [Float](repeating: 0.05, count: 64*64), sourceIsLinear: true),
                       bayerPattern: nil, bottomUp: false, timestamp: Date(), sourceName: "flat.fit")
    let r = engine.processDetailed(bad)                    // too few stars → rejected
    if case .rejected = r.outcome { XCTAssertNil(r.registration) } else { XCTFail("expected reject") }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter StackEngineTests/testProcessDetailedSurfacesRegistrationForAcceptedSubs`
Expected: FAIL — `ProcessResult` has no `registration`.

- [ ] **Step 3: Implement**

Add the payload type + optional field (default nil so all existing `ProcessResult(...)` calls compile unchanged), a `stackGeneration` counter incremented in `reseed()` and wherever auto-reseed fires, and populate `registration` at the two accept sites. Reference site (~299):

```swift
// in ProcessResult:
public let registration: RegistrationPayload?
public init(outcome: StackOutcome, starCount: Int, backgroundSigma: Float, weight: Float,
            registration: RegistrationPayload? = nil) {
    self.outcome = outcome; self.starCount = starCount; self.backgroundSigma = backgroundSigma
    self.weight = weight; self.registration = registration
}

public struct RegistrationPayload {
    public let transform: SimilarityTransform
    public let effectiveScale: Float
    public let weight: Float
    public let leveling: (sub: BackgroundExtraction.BackgroundModel, ref: BackgroundExtraction.BackgroundModel)?
    public let stackGeneration: Int
    public let referenceIdentity: FileIdentity?
}
extension RegistrationPayload: Equatable {
    public static func == (l: Self, r: Self) -> Bool {
        l.transform == r.transform && l.effectiveScale == r.effectiveScale && l.weight == r.weight
            && l.stackGeneration == r.stackGeneration && l.referenceIdentity == r.referenceIdentity
            && (l.leveling == nil) == (r.leveling == nil)
    }
}
```

Reference return (~299) — set `self.referenceIdentity = frame.identity` here (stored for the
generation), and the reference carries its OWN identity:
```swift
self.referenceIdentity = frame.identity          // the generation's shared reference identity
return ProcessResult(outcome: .becameReference, starCount: stars.count, backgroundSigma: sigma, weight: 1.0,
    registration: RegistrationPayload(transform: .identity, effectiveScale: 1.0, weight: 1.0,
        leveling: nil, stackGeneration: stackGeneration, referenceIdentity: frame.identity))
```

Stacked return (~377) — capture the `pair` and `effectiveScale` already computed above:
```swift
let levelingPair = levelingModels(image: warped, mask: mask)   // reuse if already computed; else compute once
return ProcessResult(outcome: .stacked(frameCount: accumulator.frameCount),
    starCount: stars.count, backgroundSigma: sigma, weight: appliedWeight,
    registration: RegistrationPayload(transform: half, effectiveScale: effectiveScale, weight: appliedWeight,
        leveling: levelingPair, stackGeneration: stackGeneration, referenceIdentity: referenceIdentity))
```

Add `private var stackGeneration = 0` incremented in `reseed()` and the auto-reseed branch; expose `public var currentStackGeneration: Int { stackGeneration }`. Store `private var referenceIdentity: FileIdentity?` set when a frame becomes the reference (from `RawFrame.identity`) so stacked subs carry their reference's identity. `SimilarityTransform.identity` must exist — if not, add a static `identity` (scale 1, rotation 0, tx/ty 0).

- [ ] **Step 4: Run to verify pass + full engine suite**

Run: `swift test --filter StackEngineTests`
Expected: PASS including the two new tests; all pre-existing engine tests still green (equality/API unchanged for old callers).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Stacking/StackEngine.swift Tests/LiveAstroCoreTests/StackEngineTests.swift
git commit -m "feat: StackEngine surfaces per-sub registration payload + stackGeneration

Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j"
```

---

## Task 5: SessionPipeline captures the SubRegistration cache

**Files:**
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` (`handleNative`, after `let result = engine.processDetailed(frame)` and the existing `onSubFrame` block)
- Test: `Tests/LiveAstroCoreTests/GlobalRefinerTests.swift` (new file; start with the capture test)

**Interfaces:**
- Consumes: `ProcessResult.registration` (Task 4), `RawFrame.identity`, the relay's per-sub destination URL.
- Produces: `SessionPipeline.subRegistrations() -> [FileIdentity: SubRegistration]` (test seam) populated in capture order; each accepted sub maps identity → `SubRegistration` with `relayURL` = the local relay copy, `stackGeneration`/`referenceIdentity` from the payload (reference sub → its own identity).

- [ ] **Step 1: Write the failing test** — drive a native `.live` pipeline with 3 in-memory subs whose `RawFrame.identity` is set, assert `subRegistrations()` has 3 entries, the first is the reference (transform `.identity`, referenceIdentity == its own), and all share one `stackGeneration`. (Use the existing shutdown-test `BacklogLiveSource` pattern + a stub relay URL.)

- [ ] **Step 2: Run to verify fail** — `subRegistrations()` doesn't exist.

- [ ] **Step 3a: Add `RawFrame.sourceURL`** — `RawFrame` exposes `identity` + `sourceName` but not a URL. Reconstructing a URL from a basename is fragile (basename collisions, folder replacement). Add `public let sourceURL: URL?` to `RawFrame` (default `nil`, back-compat) and populate it in `FolderFrameSource.loadRawFrame(url:...)` with the actual `url` it read. Non-file/in-memory frames leave it `nil`. Test: a `FolderFrameSource(.live)` frame carries the real `sourceURL`.
- [ ] **Step 3b: Capture the cache** — in `handleNative`, after the online commit and `onSubFrame?`, when `result.registration != nil` insert into `private var _subRegistrations: [FileIdentity: SubRegistration]` (same serial-consumer context as `recordSubFrame`, no extra lock needed for writes; a lock only for the `subRegistrations()` read seam). `relayURL = frame.sourceURL` **directly** — never reconstructed. A frame with `sourceURL == nil` is skipped for registration (feature stays off, Task 11 gate). Reference sub → `referenceIdentity = frame.identity`. Expose `func subRegistrations() -> [FileIdentity: SubRegistration]`.

- [ ] **Step 4: Run to verify pass** + existing pipeline suites green.

- [ ] **Step 5: Commit** (`feat: SessionPipeline captures SubRegistration cache`).

---

## Task 6: `GlobalRefiner` — reproduce subs + combine (loader-injected)

**Files:**
- Create: `Sources/LiveAstroCore/Pipeline/GlobalRefiner.swift`
- Test: `Tests/LiveAstroCoreTests/GlobalRefinerTests.swift`

**Interfaces:**
- Consumes: `GlobalCombine`, `SubRegistration`, `Warp.apply(_:transform:)`, `GradientLeveler.apply(_:subModel:refModel:scale:)`, a **`FrameLoader`** protocol `func loadCalibratedRGB(url: URL, expectedDigest:) throws -> AstroImage` (injected — production wraps `FolderFrameSource.loadRawFrame` + calibrator + debayer; tests inject a stub).
- Produces: `struct GlobalRefiner { func refine(survivors: [SubRegistration], currentGeneration: Int, kappa: Float, maxSampleBytes: Int) -> RefineResult? }` where `RefineResult { let image: AstroImage; let coverage: [Float]; let survivorCount: Int; let skipped: Int }`. **Filters survivors to `stackGeneration == currentGeneration` (explicit equality — NEVER a majority heuristic; after a reseed the old frames could be the majority and refine the wrong stack)**, warps each (`transform.liftedToFullResolution()`), applies leveling when the pair exists, produces `(image, mask, weight)`; builds the RAM sample via `SubRegistration.sampleIndices`, calls `robustCenter` then `clippedWeightedMean` (streaming the output via the loader again). Per-sub load failure → skip + count. `currentGeneration` is passed by the caller from `engine.currentStackGeneration`.

- [ ] **Step 1: Write the failing test** — inject a stub loader returning constant frames + one trail frame; build `SubRegistration`s (identity transforms, generation 0, weight 1); assert `refine(...)` removes the trail (image == clean value), `survivorCount` correct, and a survivor of a *different* generation is excluded. A stub-loader throw for one URL → `skipped == 1` and the pass still returns.

- [ ] **Step 2: Run to verify fail** — `GlobalRefiner` not found.

- [ ] **Step 3: Implement** — the orchestration above. First `let inGen = survivors.filter { $0.stackGeneration == currentGeneration }` (explicit equality). Warp with `Warp.apply(rgb, transform: reg.transform.liftedToFullResolution())` → `(warped, mask)`; if `reg.leveling != nil` → `GradientLeveler.apply(warped, subModel: leveling.sub, refModel: leveling.ref, scale: reg.effectiveScale)` else use `warped`. Sample = `inGen` at `SubRegistration.sampleIndices(count: inGen.count, ...)`, materialized as `(image, mask)`; center = `robustCenter(sample)`; output = `clippedWeightedMean(frames: { re-stream all `inGen` survivors via loader }, center, scale, kappa)`. Skip a survivor whose load throws (`skipped += 1`); if the surviving quorum is too small, return nil (caller keeps last master).

- [ ] **Step 4: Run to verify pass** — GlobalRefinerTests green.

- [ ] **Step 5: Commit** (`feat: GlobalRefiner reproduces subs + robust combine`).

---

## Task 7: `publishedMaster` + composite `freshnessKey`

**Files:**
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift`
- Test: `Tests/LiveAstroCoreTests/GlobalRefinerTests.swift`

**Interfaces:**
- Produces: `struct FreshnessKey: Equatable { let stackGeneration: Int; let survivorDigests: [String]; let userRejectGeneration: Int; let kappa: Float }` (`survivorDigests` sorted); `SessionPipeline.currentFreshnessKey() -> FreshnessKey`; internal `publishedMaster: (image: AstroImage, coverage: [Float], survivorCount: Int, key: FreshnessKey)?` under a lock; `func publishedMasterIfCurrent() -> (image, coverage, survivorCount)?` returns the stored master only when `key == currentFreshnessKey()`.
- Consumes: the survivor set (Task 5 cache), `userRejectGeneration` (bump a counter on every `toggleReject`), `rejectionStrength.kappa`.

- [ ] **Step 1: Write the failing test** — publish a master with key K; assert `publishedMasterIfCurrent()` returns it; then simulate a user reject (bump `userRejectGeneration`) → `currentFreshnessKey()` changes → `publishedMasterIfCurrent()` returns nil (stale). Same for a κ change and a reseed (`stackGeneration` bump).

- [ ] **Step 2–5:** implement the composite key (sorted survivor digests + generations + κ), the locked store, and the equality-gated accessor; commit (`feat: publishedMaster with composite freshnessKey (reject/reseed/kappa invalidate)`).

---

## Task 8: Trigger + self-throttle (background, off the online path)

**Files:** Modify `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift`; Test `GlobalRefinerTests.swift`.

**Interfaces:** the pipeline exposes named invalidation hooks, each of which bumps the relevant generation and calls `refiner.noteChanged()`:
- `SessionPipeline.noteSubAccepted()` — from `handleNative` post-commit.
- `SessionPipeline.noteUserRejectChanged()` — bumps `userRejectGeneration`; **`AppModel.toggleReject` calls this** (not the refiner directly).
- `SessionPipeline.noteReseeded()` — on manual/auto reseed (freshnessKey's `stackGeneration` already changed).

The refiner owns a serial `DispatchQueue`; `noteChanged()` coalesces (idle → dispatch a pass; running → set `dirty`, exactly one more pass afterward) and returns immediately (never blocks the caller). On completion it stores `publishedMaster` (Task 7). Produces no return into the online path.

- [ ] **Step 1: Write the failing test** — fire `noteChanged()` 5× rapidly; assert at most one pass runs concurrently and exactly one extra pass runs after the first completes (use a counting stub loader + expectations); assert the calling thread is never blocked (the calls return immediately).

- [ ] **Step 2–5:** implement coalescing on the serial queue; the online consumer only calls `noteChanged()` (non-blocking); commit (`feat: self-throttling refiner trigger, off the online path`).

---

## Task 9: Output preference — broadcast/latest/master use the clean master; preview stays online

**Files:** Modify `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` (`renderSnapshot`, the broadcast/`latest.png` path); Test `GlobalRefinerTests.swift`.

**Interfaces:** the operator per-sub preview (`onUpdate` snapshot) continues to render from `engine.currentStackAndCoverage()` unchanged. Broadcast/`latest.png` render from `publishedMasterIfCurrent()` when non-nil, else fall back to `engine.currentStackAndCoverage()`. Same `cropToCoverage` → `displayCGImage` pipeline.

- [ ] **Step 1: Write the failing test** — with a current published master, assert the broadcast render uses it (distinct pixels from the online mean, e.g. trail removed) while the per-sub preview render still equals the online mean; with a stale key, both fall back to online.

- [ ] **Step 2–5:** implement the preference at the broadcast/latest site only (NOT the preview); commit (`feat: broadcast/master prefer the clean published master; preview stays online`).

---

## Task 10: `end()` writes the clean master (bounded), survivor-counted

**Files:** Modify `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` (`end()` master-write block ~985-1015); Test `Tests/LiveAstroCoreTests/SessionPipelineShutdownTests.swift`.

**Interfaces:** the `end()` order is **fixed and explicit** (a wrong order refines a moving/partial set):
1. **stop the source** (existing `folderSource.stop(timeout:)`).
2. **drain the backlog** (existing progress-aware `drainConsumeTaskOrThrow` — 2026-08-28 fix) so every in-flight accepted sub is recorded first.
3. **freeze** the survivor set + compute `currentFreshnessKey()` once — from here it does not change.
4. **cancel** any in-flight refiner and wait its bounded cancellation.
5. if `publishedMasterIfCurrent()` matches the frozen key → use it; **else** run ONE bounded `refiner.refine(survivors:currentGeneration:...)` against the frozen set.
6. **write** `master.fit` via `RestackPlanning.encodeMaster` with **STACKCNT = survivorCount** and **TOTALEXP = survivorCount · subExposureSeconds**.

On any refiner failure at step 5 → fall back to the online `finalizationState()` master (today's path); the session still finalizes. The bounded refine at step 5 shares the live-drain timeout budget (no hang).

- [ ] **Step 1: Write the failing test** — drive a `.live` pipeline (BacklogLiveSource) with a trail sub + feature on; `end()`; assert `master.fit` exists, its STACKCNT == survivor count (not the online stack count if they differ), and the trail-region pixels read background. Add a fault test: a refiner that always fails → `end()` still writes the online master (no throw, no hang).

- [ ] **Step 2–5:** implement; ensure the final pass shares the bounded-drain cancellation; commit (`feat: end() writes the clean survivor-counted master with online fallback`).

---

## Task 11: AppModel toggle + gating + status reason; CaptureSettingsView

**Files:** Modify `Sources/LiveAstroStudio/AppModel.swift`, `Sources/LiveAstroStudio/CaptureSettingsView.swift`; Test `Tests/LiveAstroCoreTests/` (pure gating helper) or an app-level test.

**Interfaces:** `AppModel.liveTrailRejection: Bool = true`; a pure `LiveRejectionGate.reason(sourceIsLocalLiveRelay: Bool, subCount: Int, minSubs: Int, reseeding: Bool, enabled: Bool) -> LiveRejectionStatus` returning `.active(subs:) | .off(reason: String)` with reasons `"network source"`, `"need ≥ N subs"`, `"reseeding"`, `"turned off"`. The pipeline consults the gate before engaging the refiner; the view shows the status string. κ from `rejectionStrength`.

- [ ] **Step 1: Write the failing test** — table-test `LiveRejectionGate.reason` for each branch (local+enough subs+on → active; network → off "network source"; too few → off "need ≥ N subs"; reseeding → off "reseeding"; toggle off → off "turned off").

- [ ] **Step 2–5:** implement the pure gate + wire the toggle/status into `CaptureSettingsView` (a `Toggle` + a caption bound to the status string); commit (`feat: live trail-rejection toggle, gating + status reason`).

---

## Task 12: Integration — synthetic (CI) + real-M51 (env-gated) acceptance

**Files:** Create `Tests/LiveAstroCoreTests/LiveGlobalRejectionTests.swift`.

**Interfaces:** consumes the whole wired pipeline.

- [ ] **Step 1: Write the tests**
  - **Always-CI synthetic:** build N=11 registered star frames in-memory, one with a bright diagonal streak; drive the `.live` pipeline with the feature ON; `end()`; assert `master.fit`'s streak-path pixels read background (trail removed) while a feature-OFF run keeps them bright. This is the automated form of the demo.
  - **Env-gated real data (skippable like `testSolvesRealM63Frame`):** guard on `ProcessInfo.processInfo.environment["LAS_TRAIL_FRAMES"]` pointing at the real M 51 set incl. the trail sub; drive the pipeline, assert (a) the trail is gone from `master.fit` (mean along the trail path ≈ local background), and (b) **SNR does not regress**, measured **ROI-based, not global**: pick a flat background ROI away from the trail and the galaxy, compute SNR = mean/σ there for both masters, and require `globalSNR ≥ 0.9 · onlineSNR` (tolerance for the survivor-count difference — NOT strict ≥). Skip when the env var is unset.
- [ ] **Step 2: Run** — synthetic passes; real-data test skips without the env var.
- [ ] **Step 3: Commit** (`test: live global rejection acceptance (synthetic CI + env-gated real M51)`).

---

## Final review

After Task 12: run the full suite (`swift test`), confirm 0 failures and feature-OFF parity, then dispatch the whole-branch code review (superpowers:requesting-code-review) AND an adversarial cold review (concurrency lens on the refiner↔online↔end() interaction; correctness lens on the combine + freshnessKey) per this project's standing rule for pipeline/concurrency changes. Fix Critical/Important findings, then finish the branch (superpowers:finishing-a-development-branch) → PR → release.
