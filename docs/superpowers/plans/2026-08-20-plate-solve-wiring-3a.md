# Plate-Solve Wiring (3a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the (already validated) native plate-solver off the hot path when the reference frame is established, and expose the resulting `WCS` for the north-up feature (3b) to consume.

**Architecture:** Pure backend wiring — no new data plumbing. `StackEngine` exposes its existing reference stars/size; `SessionPipeline` pairs them with the already-captured `sourceMetadata` (RA/DEC/FOCALLEN/XPIXSZ), runs `PlateSolver.solve` on a background queue at reference-seed time, and stores/exposes the result. Re-solves on reseed.

**Tech Stack:** Swift 5.10, SPM, macOS 14+, zero external dependencies, XCTest.

## Global Constraints

- Branch: `feature/plate-solve-wiring-3a` (already created). NEVER commit to `main`.
- Commit trailer `Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j`; no `Co-Authored-By`.
- One `swift test` / `swift build` at a time (SPM build lock). Build to a local scratch path to dodge the iCloud `build.db` race: `--scratch-path /private/tmp/claude-501/-Users-pauldavis/2349d1c1-e213-4a31-a397-bea11f9674d7/scratchpad/las-build`.
- The solve MUST run off the hot path (background queue); the import/commit loop must never block on it.
- Reference stars are HALF-RES: the solve's `pixelScaleArcsec` = `pixelSizeUM / focalLengthMM * 206.264806 * 2` (the ×2 is the half-res factor). Center + rotation are scale-invariant, so half-res space is correct.
- Plate-solve is OPTIONAL: any missing precondition (no catalog, missing metadata, no reference) → skip silently, `currentWCS` stays nil, import unaffected. No user-visible errors.
- No UI, no display rotation, no download — those are 3b/3c. `StarCatalog.bundled()` is nil today (placeholder), so this code is a correct no-op until 3c; tests inject a real in-memory catalog.

---

### Task 1: `StackEngine.referenceSolveInput()` accessor

**Files:**
- Modify: `Sources/LiveAstroCore/Stacking/StackEngine.swift` (reference state near line 90; add accessor)
- Test: `Tests/LiveAstroCoreTests/StackEngineReferenceSolveInputTests.swift` (new)

**Interfaces:**
- Consumes: existing `private var referenceStars: [Star]`, `private var referenceSize: (w: Int, h: Int)?`, and the engine's existing lock (same one guarding reference state).
- Produces: `public func referenceSolveInput() -> (stars: [Star], width: Int, height: Int)?`

- [ ] **Step 1: Write the failing test**

Model frame construction on the existing engine tests (find one that calls `seedReference`/`commit` — e.g. grep `StackEngine(` in Tests). Build a tiny `RawFrame` with a few stars, seed it, and assert the accessor returns them; assert nil before any seed.

```swift
import XCTest
@testable import LiveAstroCore

final class StackEngineReferenceSolveInputTests: XCTestCase {
    func testReturnsNilBeforeSeed() {
        let engine = StackEngine(/* match the default init used in existing StackEngine tests */)
        XCTAssertNil(engine.referenceSolveInput())
    }

    func testReturnsStarsAndSizeAfterSeed() {
        let engine = StackEngine(/* … */)
        // seed a reference frame the same way existing StackEngine tests do (seedReference with a RawFrame
        // whose luminance yields detectable stars). See NativePipelineTests / existing StackEngine tests.
        // … seed …
        let got = engine.referenceSolveInput()
        XCTAssertNotNil(got)
        XCTAssertGreaterThan(got!.stars.count, 0)
        XCTAssertEqual(got!.width, /* half-res width of the seeded frame */)
        XCTAssertEqual(got!.height, /* half-res height */)
    }
}
```

- [ ] **Step 2: Run it, verify it fails** (`referenceSolveInput` undefined). Command: `swift test --scratch-path <scratch> --filter StackEngineReferenceSolveInputTests`

- [ ] **Step 3: Implement the accessor** (near the other reference accessors, under the same lock):

```swift
/// The reference frame's detected stars + dimensions in HALF-RES coordinates (detection runs on the
/// half-res luminance). nil until a reference is seeded. Consumers solving against a sky catalog must
/// double the pixel scale to match the half-res space (a half-res pixel subtends 2× the sky).
public func referenceSolveInput() -> (stars: [Star], width: Int, height: Int)? {
    lock.lock(); defer { lock.unlock() }          // use the engine's actual lock name
    guard !referenceStars.isEmpty, let s = referenceSize else { return nil }
    return (referenceStars, s.w, s.h)
}
```

- [ ] **Step 4: Run the test, verify it passes.**

- [ ] **Step 5: Commit** (`feat(plate-solve): expose StackEngine.referenceSolveInput for 3a`).

---

### Task 2: `SessionPipeline` solve coordinator + `currentWCS`

**Files:**
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` (state near line 75; trigger in `finalizeCommitted` ~line 257; also the second capture site ~line 454)
- Test: `Tests/LiveAstroCoreTests/SessionPipelinePlateSolveTests.swift` (new)

**Interfaces:**
- Consumes: `StackEngine.referenceSolveInput()` (Task 1); `SessionPipeline.sourceMetadata` (`ra`, `dec`, `focalLengthMM`, `pixelSizeUM`); `StarCatalog.bundled()`; `PlateSolver.solve(...)`.
- Produces: `public var currentWCS: WCS? { get }`; internal `solvedWCS`, `solveAttempted`, `func attemptPlateSolve(engine:)`.
- **Test seam:** so tests don't depend on the (nil) bundled catalog, add an injectable catalog:
  `var plateSolveCatalog: StarCatalog? = StarCatalog.bundled()` (internal, settable in tests). The
  coordinator reads this property, not `bundled()` directly.

- [ ] **Step 1: Write the failing end-to-end test**

Model the synthetic native session on `NativePipelineTests` / `CropToOverlapPipelineTests` (how they
write synthetic FITS subs to a temp dir and drive the native import). The subs' star field = a known
catalog projected through a known full-res WCS (reuse the projection math from `PlateSolverTests`
`projectThroughWCS`); write `RA`/`DEC`/`FOCALLEN`/`XPIXSZ` into the headers via `FITSWriter` +
`SourceMetadata`. Set `pipeline.plateSolveCatalog = <in-memory catalog>`.

```swift
func testSolvesReferenceAndExposesWCS() throws {
    // build temp dir of synthetic subs whose stars = catalog projected through knownWCS (center cra,cdec)
    // with headers RA=cra, DEC=cdec, FOCALLEN, XPIXSZ; catalog spread to fill the FOV (see PlateSolverTests)
    let pipeline = /* construct as NativePipelineTests does */
    pipeline.plateSolveCatalog = knownCatalog
    // run the native import to completion (same driver as NativePipelineTests)
    // the background solve may lag the final frame — poll currentWCS with a short bounded wait:
    let wcs = try waitForNonNil(timeout: 10) { pipeline.currentWCS }
    let sep = 3600 * hypot((wcs.centerRA - cra) * cos(cdec * .pi/180), wcs.centerDec - cdec)
    XCTAssertLessThan(sep, 120, "solved center off by \(sep)\"")   // arcmin-level
}
```

Add a small `waitForNonNil` polling helper (or use an XCTestExpectation the coordinator fulfils — see
Step 3).

- [ ] **Step 2: Run it, verify it fails** (no `currentWCS` / `plateSolveCatalog`). Command as above with `--filter SessionPipelinePlateSolveTests/testSolvesReferenceAndExposesWCS`.

- [ ] **Step 3: Implement the coordinator**

State (near line 75, guarded by the pipeline's existing serial queue/lock):
```swift
private var solvedWCS: WCS?
private var solveAttempted = false
var plateSolveCatalog: StarCatalog? = StarCatalog.bundled()   // injectable in tests
/// The plate-solved WCS for the current reference, or nil (not solved / no catalog / missing metadata).
public var currentWCS: WCS? { queueSync { solvedWCS } }        // read on the pipeline queue
```

Coordinator (call at the END of `finalizeCommitted`, after `sourceMetadata` is captured; also reachable
from the line-454 capture path — call the same method):
```swift
private func attemptPlateSolve(engine: StackEngine) {
    guard !solveAttempted, solvedWCS == nil,
          let catalog = plateSolveCatalog,
          let m = sourceMetadata,
          let ra = m.ra, let dec = m.dec,
          let focal = m.focalLengthMM, focal > 0,
          let pix = m.pixelSizeUM, pix > 0,
          let input = engine.referenceSolveInput() else { return }
    solveAttempted = true
    let halfResScale = pix / focal * 206.264806 * 2      // ×2: reference stars are half-res
    // OFF THE HOT PATH — do not block the commit loop:
    plateSolveQueue.async {                               // a private DispatchQueue
        let wcs = PlateSolver.solve(stars: input.stars, width: input.width, height: input.height,
                                    pixelScaleArcsec: halfResScale, approxCenterRA: ra,
                                    approxCenterDec: dec, catalog: catalog)
        self.queueAsync { self.solvedWCS = wcs }          // store back on the pipeline queue
    }
}
```
Use the pipeline's actual queue/lock accessors (match how existing pipeline state is synchronised —
inspect `SessionPipeline` for its `queue`/lock pattern; do NOT introduce a second locking discipline).
Add `private let plateSolveQueue = DispatchQueue(label: "plate-solve")`.

- [ ] **Step 4: Run the end-to-end test, verify it passes.**

- [ ] **Step 5: Add guard tests** (same file):
  - `testNoCatalogLeavesWCSNil` — `plateSolveCatalog = nil` → after import, `currentWCS == nil`, import completes normally.
  - `testMissingMetadataLeavesWCSNil` — subs without `FOCALLEN` → `currentWCS == nil`.
  - `testHalfResScaleIsDoubled` — a focused check that the ×2 is required: solving the same reference with the un-doubled scale misplaces the center (assert the doubled scale is the one that lands within tolerance). May be a direct `PlateSolver.solve` comparison rather than a full pipeline run.

- [ ] **Step 6: Run all tests in the file, verify they pass.**

- [ ] **Step 7: Commit** (`feat(plate-solve): solve reference off the hot path + expose currentWCS`).

---

### Task 3: Re-solve on reseed

**Files:**
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` (`reseed()` ~line 238)
- Test: `Tests/LiveAstroCoreTests/SessionPipelinePlateSolveTests.swift` (extend)

**Interfaces:**
- Consumes: the Task 2 state (`solvedWCS`, `solveAttempted`).
- Produces: reseed clears both so the next reference generation re-solves.

- [ ] **Step 1: Write the failing test**

```swift
func testReseedResolvesForNewField() throws {
    // import a first field (center A) → currentWCS ≈ A
    // reseed(), then import a second field (center B, different RA/DEC headers) → currentWCS ≈ B
    // assert the WCS updated from A to B (not stuck on A, not nil)
}
```

- [ ] **Step 2: Run it, verify it fails** (WCS stuck on the first field because `solveAttempted` never reset).

- [ ] **Step 3: Implement** — in `SessionPipeline.reseed()`, on the pipeline queue, clear:
```swift
solvedWCS = nil
solveAttempted = false
// sourceMetadata: leave as-is if the object is unchanged; if reseed implies a new target, also reset
// sourceMetadata so the new field's RA/DEC are captured. Match existing reseed semantics — if reseed
// keeps sourceMetadata, the new field's first finalize re-captures via the `== nil` guard only when it
// was cleared. Reset sourceMetadata = nil here so a new-target reseed re-captures center.
sourceMetadata = nil
```
(Confirm against existing reseed behaviour: if the codebase treats reseed as same-target continuation,
keep `sourceMetadata`; if new-target, clear it. The test above dictates: different center after reseed →
must clear. If that breaks a same-target assumption elsewhere, surface it in review.)

- [ ] **Step 4: Run the test, verify it passes.**

- [ ] **Step 5: Run the whole new test file + Task 1 file together, verify green.**

- [ ] **Step 6: Commit** (`feat(plate-solve): re-solve on reseed`).

---

## Post-plan verification

- [ ] Run the full `PlateSolverTests` + the new test files once together (confirm no regressions in the solver tests from any shared changes).
- [ ] Confirm `currentWCS` is nil with the committed placeholder catalog (no behaviour change for shipped app until 3c).
- [ ] Adversarial cold review of the coordinator's concurrency (the background solve + queue hand-off) before merge — a race on `solvedWCS`/`solveAttempted` is the main risk.
