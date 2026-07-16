# Live-Session Accuracy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The native stacker auto-reseeds when it detects it seeded on a wrong-target frame (systematic `noTransform` failures), and the integration badge shows the current stack's honest depth (count derived from the same quantity as the time).

**Architecture:** `StackEngine` gains a consecutive-`noTransform` counter; at a threshold it clears the reference (so the next good frame reseeds) and bumps a public `autoReseedCount`. `SessionPipeline` logs when that counter increments (counter-diff, no new `StackOutcome` case). `IntegrationFormat` gains a 2-arg caption that derives the frame count from the integration seconds; `AppModel.integrationCaption` uses it so count and time can't disagree post-reseed.

**Tech Stack:** Swift 5.10, Swift Package Manager, XCTest. `LiveAstroCore` + `LiveAstroStudio` (SwiftUI `@Observable`).

## Global Constraints

- Swift 5.10, macOS 14+. `LiveAstroCore` Foundation/CoreGraphics/Accelerate only.
- Core tests: `swift test --filter LiveAstroCoreTests`; all existing tests must stay green.
- TDD for T1 (StackEngine) and T2 (IntegrationFormat). The pipeline log wire (T3) is manual/build-verified.
- Auto-reseed default threshold is **6** consecutive `.rejected(.noTransform)`; **0 disables**. The counter increments **only** on `.noTransform` and resets **only** on `.stacked`/`.becameReference` (an interleaved `insufficientStars`/`dimensionMismatch` neither increments nor resets it).
- `autoReseedCount` is session-total and is **not** reset by manual `reseed()` (matches `acceptedCount`/`rejectedCount`).
- New counters are mutated only inside the existing `process()` lock.
- Default threshold must not change existing behavior until 6 consecutive `noTransform` occur — existing StackEngine/pipeline/e2e tests stay green.
- Branch `feature/live-session-accuracy` (off main). Never commit to main.

---

### Task 1: StackEngine auto-reseed

**Files:**
- Modify: `Sources/LiveAstroCore/Stacking/StackEngine.swift`
- Test: `Tests/LiveAstroCoreTests/AutoReseedTests.swift`

**Interfaces:**
- Consumes: existing `process(_:) -> StackOutcome`, `StackOutcome` (`.becameReference`/`.stacked(frameCount:)`/`.rejected(RejectionReason)`), `RejectionReason.noTransform`, the seed path (`referenceSize == nil`), `reseed()`.
- Produces:
  - `StackEngine.init(..., autoReseedThreshold: Int = 6)` — new trailing param.
  - `public private(set) var autoReseedCount = 0`.
  - Auto-reseed behavior in `processLocked` (clear reference at the threshold).

- [ ] **Step 1: Write the failing tests**

Create `Tests/LiveAstroCoreTests/AutoReseedTests.swift`. Reuse the `cfaFrame` construction idiom from `StackEngineTests.swift` (a RawFrame built from a star list). Field B MUST have different *relative* geometry from A (the matcher is rotation/scale-invariant, so a shifted/rotated A would still match — B must be a different pattern) so B-against-A yields `.noTransform`:
```swift
import XCTest
@testable import LiveAstroCore

final class AutoReseedTests: XCTestCase {
    // Build a CFA RawFrame with Gaussian stars at the given positions (mirror StackEngineTests.cfaFrame).
    func cfaFrame(width: Int = 512, height: Int = 512, stars: [(Double, Double)],
                  name: String = "t.fit") -> RawFrame {
        var px = [Float](repeating: 0.03, count: width * height)
        for s in stars {
            for y in max(0, Int(s.1)-6)...min(height-1, Int(s.1)+6) {
                for x in max(0, Int(s.0)-6)...min(width-1, Int(s.0)+6) {
                    let dx = Double(x)-s.0, dy = Double(y)-s.1
                    px[y*width+x] += 0.9 * Float(exp(-(dx*dx+dy*dy)/(2*2.0*2.0)))
                }
            }
        }
        let img = AstroImage(width: width, height: height, channels: 1, pixels: px, sourceIsLinear: true)
        return RawFrame(image: img, bayerPattern: .grbg, bottomUp: false,
                        timestamp: Date(timeIntervalSince1970: 0), sourceName: name)
    }
    // Two disjoint fields (different relative geometry → won't triangle-match each other).
    var fieldA: [(Double, Double)] { (0..<20).map { (Double(($0*47)%480+16), Double(($0*83)%480+16)) } }
    var fieldB: [(Double, Double)] { (0..<20).map { (Double(($0*103)%470+20), Double(($0*31)%470+20)) } }

    func testAutoReseedsAfterSystematicNoTransform() {
        let engine = StackEngine(autoReseedThreshold: 6)
        XCTAssertEqual(engine.process(cfaFrame(stars: fieldA)), .becameReference)   // seed on A
        // 6 disjoint B frames → all noTransform; the 6th trips the reseed.
        for i in 0..<6 {
            XCTAssertEqual(engine.process(cfaFrame(stars: fieldB, name: "b\(i).fit")),
                           .rejected(.noTransform), "B\(i) should not match A")
        }
        XCTAssertEqual(engine.autoReseedCount, 1)
        // Reference was cleared → the next B frame re-seeds onto B.
        XCTAssertEqual(engine.process(cfaFrame(stars: fieldB, name: "seedB.fit")), .becameReference)
        // Subsequent B frames now stack against the B reference.
        if case .stacked = engine.process(cfaFrame(stars: fieldB, name: "b_ok.fit")) {} else {
            XCTFail("expected B to stack against the new B reference")
        }
    }

    func testNoFalseReseedOnGoodReference() {
        let engine = StackEngine(autoReseedThreshold: 6)
        _ = engine.process(cfaFrame(stars: fieldA))                       // seed A
        // Good A frames with an occasional single mismatch, never 6 in a row.
        for i in 0..<12 {
            if i % 4 == 3 { _ = engine.process(cfaFrame(stars: fieldB, name: "x\(i).fit")) } // 1 mismatch
            else { _ = engine.process(cfaFrame(stars: fieldA, name: "a\(i).fit")) }          // matches → .stacked resets
        }
        XCTAssertEqual(engine.autoReseedCount, 0)
    }

    func testThresholdZeroDisables() {
        let engine = StackEngine(autoReseedThreshold: 0)
        _ = engine.process(cfaFrame(stars: fieldA))
        for i in 0..<20 { _ = engine.process(cfaFrame(stars: fieldB, name: "b\(i).fit")) }
        XCTAssertEqual(engine.autoReseedCount, 0)                          // never auto-reseeds
    }

    func testCloudFrameDoesNotResetTheRun() {
        // noTransform ×3, insufficientStars ×1 (starless), noTransform ×3 → still 6 noTransform → trips.
        let engine = StackEngine(autoReseedThreshold: 6)
        _ = engine.process(cfaFrame(stars: fieldA))
        for i in 0..<3 { _ = engine.process(cfaFrame(stars: fieldB, name: "n\(i).fit")) }
        XCTAssertEqual(engine.process(cfaFrame(stars: [])), .rejected(.insufficientStars(found: 0)))
        for i in 3..<6 { _ = engine.process(cfaFrame(stars: fieldB, name: "n\(i).fit")) }
        XCTAssertEqual(engine.autoReseedCount, 1)                          // cloud didn't reset the count
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AutoReseedTests`
Expected: compile failure — `extra argument 'autoReseedThreshold'` / `no member 'autoReseedCount'`. (If `RawFrame`'s initializer arg labels differ from the snippet, match the real `RawFrame` init used in `StackEngineTests.swift` — open it and copy the exact labels; the star-field logic is the point, not the label spelling.)

- [ ] **Step 3: Implement**

In `Sources/LiveAstroCore/Stacking/StackEngine.swift`:

Add the stored state near `acceptedCount`/`rejectedCount`:
```swift
    /// Session-total automatic reseeds (reference cleared after systematic
    /// registration failure). Not reset by reseed(), like acceptedCount.
    public private(set) var autoReseedCount = 0
    private let autoReseedThreshold: Int
    private var consecutiveNoTransform = 0
```

Extend the initializer (add the trailing param + store it). The current init is
`public init(seedMinStars: Int = 15, minMatches: Int = 8, inlierTolerance: Double = 2.0, rejection: RejectionMethod = NoRejection())`:
```swift
    public init(seedMinStars: Int = 15, minMatches: Int = 8, inlierTolerance: Double = 2.0,
                rejection: RejectionMethod = NoRejection(), autoReseedThreshold: Int = 6) {
        // ... existing assignments ...
        self.autoReseedThreshold = autoReseedThreshold
    }
```

In `processLocked`, the seed path returns `.becameReference` — reset the counter there:
```swift
        if referenceSize == nil {
            // ... existing seed logic ...
            acceptedCount += 1
            consecutiveNoTransform = 0
            return .becameReference
        }
```

At the `.noTransform` rejection (the `TransformSolver.solve(...) else` block), add the counter + auto-reseed:
```swift
        guard let half = TransformSolver.solve(source: stars, target: referenceStars, pairs: pairs,
                                               minMatches: minMatches, inlierTolerance: inlierTolerance)
        else {
            rejectedCount += 1
            consecutiveNoTransform += 1
            if autoReseedThreshold > 0 && consecutiveNoTransform >= autoReseedThreshold {
                // Systematic mismatch ⇒ the reference is probably a wrong-target
                // frame. Clear it so the next ≥seedMinStars frame re-seeds.
                referenceStars = []
                referenceSize = nil
                referenceChannels = nil
                accumulator = nil
                consecutiveNoTransform = 0
                autoReseedCount += 1
            }
            return .rejected(.noTransform)
        }
```

On the successful accumulate path, reset the counter just before `return .stacked(...)`:
```swift
        accumulator.add(cleaned, mask: mask)
        acceptedCount += 1
        consecutiveNoTransform = 0
        return .stacked(frameCount: accumulator.frameCount)
```

Do NOT change `reseed()` — it clears the reference as today and must NOT reset `autoReseedCount`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AutoReseedTests`
Expected: PASS (4 tests). If `testAutoReseedsAfterSystematicNoTransform` sees a B frame `.stacked` instead of `.rejected(.noTransform)` at Step 1, field B accidentally matched A — change `fieldB`'s generator constants so its relative geometry differs from A, and re-run. Then run `swift test --filter StackEngineTests` (existing) to confirm no regression.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Stacking/StackEngine.swift Tests/LiveAstroCoreTests/AutoReseedTests.swift
git commit -m "feat: StackEngine auto-reseed on systematic registration failure"
```

---

### Task 2: Honest integration badge (frame count from integration seconds)

**Files:**
- Modify: `Sources/LiveAstroCore/Session/SessionModels.swift` (add a 2-arg `IntegrationFormat.caption`)
- Modify: `Sources/LiveAstroStudio/AppModel.swift` (`integrationCaption` uses it)
- Test: `Tests/LiveAstroCoreTests/IntegrationFormatTests.swift` (add cases; create if absent)

**Interfaces:**
- Consumes: existing `IntegrationFormat.caption(seconds:frames:subSeconds:)`.
- Produces: `IntegrationFormat.caption(seconds: Double, subSeconds: Double) -> String` — derives `frames = round(seconds/subSeconds)` (guarding `subSeconds > 0`) and delegates to the 3-arg version.

- [ ] **Step 1: Write the failing test**

Add to `Tests/LiveAstroCoreTests/IntegrationFormatTests.swift` (create with this if absent):
```swift
import XCTest
@testable import LiveAstroCore

final class IntegrationFormatDerivedTests: XCTestCase {
    func testFrameCountDerivedFromSeconds() {
        // 27 accepted × 30s: frame count must read 27 (from seconds), never the
        // session-total (e.g. 34) that a post-reseed index would carry.
        let s = IntegrationFormat.caption(seconds: 27 * 30, subSeconds: 30)
        XCTAssertTrue(s.contains("27 × 30s"), s)
    }
    func testZeroSubSecondsNoCrash() {
        // Guard: subSeconds 0 → 0 frames, no divide-by-zero / trap.
        let s = IntegrationFormat.caption(seconds: 0, subSeconds: 0)
        XCTAssertTrue(s.contains("0 ×"), s)
    }
    func testRoundsToNearestFrame() {
        // 26.6 × 30 ≈ 798s → 798/30 = 26.6 → rounds to 27.
        let s = IntegrationFormat.caption(seconds: 798, subSeconds: 30)
        XCTAssertTrue(s.contains("27 × 30s"), s)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter IntegrationFormatDerivedTests`
Expected: compile failure — `caption(seconds:subSeconds:)` not found (only the 3-arg exists).

- [ ] **Step 3: Implement**

In `Sources/LiveAstroCore/Session/SessionModels.swift`, add to the `IntegrationFormat` enum (beside the existing 3-arg `caption`):
```swift
    /// Caption whose frame count is DERIVED from the integration seconds, so the
    /// count and the time are always consistent (used for the live badge: a
    /// reseed resets the current-stack integration, and the count follows it —
    /// unlike the session-total accepted index).
    public static func caption(seconds: Double, subSeconds: Double) -> String {
        let frames = subSeconds > 0 ? Int((seconds / subSeconds).rounded()) : 0
        return caption(seconds: seconds, frames: frames, subSeconds: subSeconds)
    }
```

In `Sources/LiveAstroStudio/AppModel.swift`, change `integrationCaption` to call the 2-arg version:
```swift
    var integrationCaption: String {
        guard let rec = latestRecord else { return "waiting for first stack…" }
        return IntegrationFormat.caption(seconds: rec.estimatedIntegrationSeconds,
                                         subSeconds: profile.subExposureSeconds)
    }
```
(Drops the `frames: rec.index` argument. `rec.index` remains the monotonic snapshot identity used elsewhere — do not change it.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter IntegrationFormatDerivedTests`
Expected: PASS (3 tests). Then `swift build` to confirm the AppModel change compiles.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Session/SessionModels.swift Sources/LiveAstroStudio/AppModel.swift Tests/LiveAstroCoreTests/IntegrationFormatTests.swift
git commit -m "feat: integration badge frame count derived from integration seconds (honest post-reseed)"
```

---

### Task 3: Pipeline logs auto-reseed events

**Files:**
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift`

**Interfaces:**
- Consumes: `StackEngine.autoReseedCount` (T1); the existing `onLog` channel and the per-frame consume loop that calls `engine.process(frame)`.
- Produces: a log line when `autoReseedCount` increments between frames (counter-diff — no new `StackOutcome` case).

**Note:** Manual/build-verified — the log emission is a thin wire over the T1 logic (which is unit-tested at the engine level); SwiftUI/pipeline-run logging is out of unit scope, per prior pillars.

- [ ] **Step 1: Add the counter-diff log in the native consume loop**

In `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift`, add a stored field near the other pipeline state:
```swift
    private var lastAutoReseedCount = 0
```
In the native frame handler, right after `let outcome = engine.process(frame)` (before/around the existing `switch outcome`), add:
```swift
        if engine.autoReseedCount != lastAutoReseedCount {
            lastAutoReseedCount = engine.autoReseedCount
            onLog?("Auto-reseeded — the reference frame didn't match; re-seeding on the next good sub. (Earlier subs that couldn't register stay rejected.)")
        }
```
(Place it so it runs for every processed native frame regardless of the outcome. If there is more than one `engine.process` call site — e.g. a separate import path — add the same check at each, or factor a tiny `private func noteAutoReseed(_ engine:)`; keep it DRY.)

- [ ] **Step 2: Build debug**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Build RELEASE**

Run: `swift build -c release --scratch-path /private/tmp/las-release-build`
Expected: `Build complete!`

- [ ] **Step 4: Run the full Core suite (no regression)**

Run: `swift test --filter LiveAstroCoreTests`
Expected: all pass (the log wire changes no stacking behavior; default threshold leaves existing tests unaffected).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Pipeline/SessionPipeline.swift
git commit -m "feat: log auto-reseed events in the session pipeline"
```

---

## Notes for the implementer

- The auto-reseed counter increments ONLY on `.noTransform` and resets ONLY on `.stacked`/`.becameReference`. Do not reset it on `insufficientStars`/`dimensionMismatch` — a transient cloud must not erase the wrong-seed evidence (the `testCloudFrameDoesNotResetTheRun` test pins this).
- Do NOT reset `autoReseedCount` in `reseed()` — it is a session-total metric like `acceptedCount`.
- The default threshold (6) must leave every existing test green: existing tests never feed 6 consecutive non-matching starry frames, so no reference is auto-cleared.
- Field B in the T1 test must differ in *relative* geometry from A (not a shift/rotation — the matcher is invariant to those). If B stacks against A, change B's constants.
- The badge fix derives the count from `estimatedIntegrationSeconds` (which is `stackFrameCount × exp`, current-stack); it must NOT touch `rec.index` (the monotonic snapshot identity).
