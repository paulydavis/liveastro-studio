# Crop-to-Overlap for the Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply the coverage crop that already trims `master.fit` to the live/import DISPLAY path, so broadcast, snapshots, `latest.png`, and replay show the clean well-covered region (no grey wedge / bright seam).

**Architecture:** Add an atomic `StackEngine.currentStackAndCoverage()`; rename the pure-geometric `SessionPipeline.cropMaster` → `cropToCoverage` (it's no longer master-specific); crop the mean via `cropToCoverage` in the two display render sites (`renderSnapshot` import + `handleNative` live) before `displayCGImage`/`recorder.save`. Reuses `CoverageCrop.rect` + `AstroImage.cropped` + the existing full-frame and >40%-removed guards. Always-on, WYSIWYG with the master.

**Tech Stack:** Swift 5.10, SPM package `LiveAstroCore`, XCTest.

## Global Constraints

- Branch `feature/crop-to-overlap-display` (off main). NEVER commit to / base on / rebase onto `main`.
- Commit trailer on every commit: `Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j`. NO `Co-Authored-By`.
- `master.fit` behavior MUST be unchanged — only the helper's NAME changes (`cropMaster`→`cropToCoverage`); its logic, callers, and the produced master dims stay identical. `CropToOverlapPipelineTests` (master crop) must stay green.
- The crop reuses the EXISTING guards in that helper: full-frame rect → no-op; rect that removes >40% of area → keep full frame + `onLog`. Do NOT change `CoverageCrop` thresholds (`wellCoveredFraction: 0.9`) or the 60%-area guard.
- Always-on (no toggle/UI). The register/warp/commit pipeline, the finalize throttle, and the `displayCGImage` internals (DBE/denoise/stretch) are untouched.
- Run only ONE `swift test` / `swift build` at a time (SPM build lock).

---

## File Structure

- `Sources/LiveAstroCore/Stacking/StackEngine.swift` — add `currentStackAndCoverage()` (Task 1).
- `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` — rename `cropMaster`→`cropToCoverage` + update 2 callers (Task 1); crop in `renderSnapshot` + `handleNative` (Task 2).
- `Tests/LiveAstroCoreTests/StackEngineCoverageAccessorTests.swift` — new (Task 1).
- `Tests/LiveAstroCoreTests/CropToOverlapPipelineTests.swift` — add display-crop tests reusing its `makeDriftingSession`/`makeNoDriftSession`/`findMaster` helpers (Task 2).

Current code (main = 6d2db4f):
- `StackEngine.currentStack()` (~190) `lock.withLock { accumulator?.mean() }`; `currentCoverage()` (~200) `lock.withLock { accumulator?.coverage() }`; `masterSnapshotState()` (~212) shows the atomic multi-value pattern `lock.withLock { guard let accumulator else { return nil }; return (accumulator.mean(), accumulator.coverage(), accumulator.frameCount) }`.
- `SessionPipeline.cropMaster` (535–549) — pure crop with the two guards; callers at 575 and 791; doc mention at 557.
- `renderSnapshot` (274–291): `guard let mean = engine.currentStack() else { return }` then `guard let recorder …`, `mean.downsampled(maxLongEdge: importPreviewLongEdge)` → `displayCGImage` → `recorder.save(… linear: mean …)`.
- `handleNative` (`.becameReference, .stacked` case): `guard let mean = engine.currentStack() else { return }` then `guard let recorder …`, `displayCGImage(from: mean)` → `recorder.save(… linear: mean …)`.

---

### Task 1: Atomic accessor + rename `cropMaster` → `cropToCoverage`

**Files:**
- Modify: `Sources/LiveAstroCore/Stacking/StackEngine.swift` (add accessor)
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` (rename + 2 callers + doc)
- Test: `Tests/LiveAstroCoreTests/StackEngineCoverageAccessorTests.swift` (create)

**Interfaces:**
- Produces: `func currentStackAndCoverage() -> (image: AstroImage, coverage: [Float]?)?` on `StackEngine`; `private func cropToCoverage(_ image: AstroImage, coverage: [Float]?) -> AstroImage` on `SessionPipeline` (renamed from `cropMaster`, identical body). Task 2 consumes both.

- [ ] **Step 1: Write the failing accessor test**

Create `Tests/LiveAstroCoreTests/StackEngineCoverageAccessorTests.swift`:

```swift
import XCTest
@testable import LiveAstroCore

final class StackEngineCoverageAccessorTests: XCTestCase {
    private func starFrame(_ w: Int, _ h: Int) -> RawFrame {
        var px = [Float](repeating: 0.05, count: w * h)
        for i in 0..<20 {
            let sx = (i % 5) * (w / 6) + 20, sy = (i / 5) * (h / 6) + 20
            for y in (sy - 4)...(sy + 4) { for x in (sx - 4)...(sx + 4) {
                let dx = Double(x - sx), dy = Double(y - sy)
                px[y * w + x] += 0.9 * Float(exp(-(dx * dx + dy * dy) / 5))
            } }
        }
        let img = AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true)
        return RawFrame(image: img, bayerPattern: nil, bottomUp: false,
                        timestamp: Date(timeIntervalSince1970: 0), sourceName: "s.fit")
    }

    func testCurrentStackAndCoverageIsAtomicAndConsistent() {
        let engine = StackEngine()
        XCTAssertNil(engine.currentStackAndCoverage(), "nil before any stack exists")
        XCTAssertTrue(engine.seedReference(starFrame(160, 120), minRows: .max))
        guard let (image, coverage) = engine.currentStackAndCoverage() else {
            return XCTFail("expected a stack after seeding")
        }
        XCTAssertEqual(image.width, 160); XCTAssertEqual(image.height, 120)
        XCTAssertEqual(coverage?.count, 160 * 120, "coverage map is width*height")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StackEngineCoverageAccessorTests`
Expected: FAIL to compile — `StackEngine` has no member `currentStackAndCoverage`.

- [ ] **Step 3: Add the accessor**

In `Sources/LiveAstroCore/Stacking/StackEngine.swift`, add right after `currentCoverage()`:

```swift
    /// One-lock read of the current mean AND coverage together, so a consumer (the display
    /// crop) computes its rect from a coverage map consistent with the mean — no frame can
    /// commit between two separate `currentStack()` / `currentCoverage()` reads. Nil when
    /// there is no active stack. (Same atomic pattern as `masterSnapshotState`.)
    public func currentStackAndCoverage() -> (image: AstroImage, coverage: [Float]?)? {
        lock.withLock {
            guard let accumulator else { return nil }
            return (accumulator.mean(), accumulator.coverage())
        }
    }
```

- [ ] **Step 4: Rename `cropMaster` → `cropToCoverage`**

In `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift`:
- Rename the method declaration `private func cropMaster(` → `private func cropToCoverage(` (body unchanged).
- Update the two call sites: line ~575 `let master = cropMaster(snap.image, …)` → `cropToCoverage(snap.image, …)`; line ~791 `let master = cropMaster(master0, …)` → `cropToCoverage(master0, …)`.
- Update the doc comment at ~557 that says `cropMaster →` to `cropToCoverage →`.

- [ ] **Step 5: Run tests to verify pass + master unchanged**

Run: `swift test --filter StackEngineCoverageAccessorTests`
Expected: PASS (1 test).
Run: `swift test --filter CropToOverlapPipelineTests`
Expected: PASS (master crop unchanged by the rename).

- [ ] **Step 6: Commit**

```bash
git add Sources/LiveAstroCore/Stacking/StackEngine.swift Sources/LiveAstroCore/Pipeline/SessionPipeline.swift Tests/LiveAstroCoreTests/StackEngineCoverageAccessorTests.swift
git commit -m "refactor: atomic currentStackAndCoverage + rename cropMaster->cropToCoverage

Adds a one-lock (mean, coverage) accessor and renames the pure-geometric
crop helper (no longer master-specific). No behavior change; master.fit
crop unchanged.

Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j"
```

---

### Task 2: Crop the display in `renderSnapshot` + `handleNative`

**Files:**
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` (two render sites)
- Test: `Tests/LiveAstroCoreTests/CropToOverlapPipelineTests.swift` (add two methods)

**Interfaces:**
- Consumes: `engine.currentStackAndCoverage()` and `cropToCoverage(_:coverage:)` (Task 1).

- [ ] **Step 1: Write the failing display-crop tests**

Add to `CropToOverlapPipelineTests` (reusing its existing `makeDriftingSession`, `makeNoDriftSession`, `findMaster` helpers). Add a `latest.png` finder + two tests:

```swift
    private func findFile(_ name: String, in root: URL) throws -> URL {
        let fm = FileManager.default
        let en = fm.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in en where url.lastPathComponent == name { return url }
        throw NSError(domain: "CropToOverlapPipelineTests", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "\(name) not found under \(root.path)"])
    }

    /// Drifting subs => the display (latest.png) is cropped to the same covered region as master.fit,
    /// not the full 256px union. (Subs are 256px < the 2560 preview cap, so no downsample confounds dims.)
    func testDisplayCroppedToCoveredRegion() throws {
        let (subsDir, sessionRoot) = try makeDriftingSession()
        defer { try? FileManager.default.removeItem(at: subsDir.deletingLastPathComponent()) }
        let master = try ImageLoader.load(url: try findMaster(in: sessionRoot))
        let latest = try ImageLoader.load(url: try findFile("latest.png", in: sessionRoot))
        XCTAssertLessThan(latest.width, SUB_W, "display should be cropped (got \(latest.width))")
        XCTAssertLessThan(latest.height, SUB_H, "display should be cropped (got \(latest.height))")
        XCTAssertEqual(latest.width, master.width, "display crop matches master crop width")
        XCTAssertEqual(latest.height, master.height, "display crop matches master crop height")
    }

    /// Identical subs => uniform coverage => display is full frame (guard/no-op path), like master.
    func testDisplayFullFrameWhenNoDrift() throws {
        let (subsDir, sessionRoot) = try makeNoDriftSession()
        defer { try? FileManager.default.removeItem(at: subsDir.deletingLastPathComponent()) }
        let latest = try ImageLoader.load(url: try findFile("latest.png", in: sessionRoot))
        XCTAssertEqual(latest.width, SUB_W, "no-drift display should be full width")
        XCTAssertEqual(latest.height, SUB_H, "no-drift display should be full height")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CropToOverlapPipelineTests/testDisplayCroppedToCoveredRegion`
Expected: FAIL — `latest.width == SUB_W` (256), the display is not cropped yet.

- [ ] **Step 3: Crop the display in both render sites**

In `renderSnapshot`, replace the first two lines of its body:

```swift
        guard let mean = engine.currentStack() else { return }
        guard let recorder else { onLog?("recorder missing — frame dropped (\(sourceName))"); return }
```

with:

```swift
        guard let (mean0, coverage) = engine.currentStackAndCoverage() else { return }
        let mean = cropToCoverage(mean0, coverage: coverage)   // display shows the covered region (like master.fit)
        guard let recorder else { onLog?("recorder missing — frame dropped (\(sourceName))"); return }
```

In `handleNative`, in the `.becameReference, .stacked` case, replace:

```swift
                guard let mean = engine.currentStack() else { return }
                guard let recorder else {
                    onLog?("recorder missing — frame dropped (\(frame.sourceName))")
                    return
                }
```

with:

```swift
                guard let (mean0, coverage) = engine.currentStackAndCoverage() else { return }
                let mean = cropToCoverage(mean0, coverage: coverage)   // display shows the covered region (like master.fit)
                guard let recorder else {
                    onLog?("recorder missing — frame dropped (\(frame.sourceName))")
                    return
                }
```

The rest of each site (downsample/`displayCGImage`/`recorder.save(linear: mean …)`/`onUpdate`) is unchanged and now operates on the cropped `mean`, so the snapshot PNG, the manifest record dims/stats, `latest.png`, and the preview all reflect the cropped region.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter CropToOverlapPipelineTests`
Expected: PASS (master crop + no-drift master + the two new display tests, 4 total).

- [ ] **Step 5: Run the full suite once**

Run: `swift test 2>&1 | tail -15`
Expected: all pass (existing SnapshotRecorder / SessionPipeline / replay suites green — the display now crops but the pipeline is otherwise unchanged).

- [ ] **Step 6: Commit**

```bash
git add Sources/LiveAstroCore/Pipeline/SessionPipeline.swift Tests/LiveAstroCoreTests/CropToOverlapPipelineTests.swift
git commit -m "feat: crop the live/import display to the covered region

renderSnapshot + handleNative crop the mean via cropToCoverage before
display/snapshot, so broadcast, snapshots, latest.png and replay show the
clean well-covered region matching master.fit (no grey wedge/bright seam).
Full frame preserved for uniform coverage via the existing >40% guard.

Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j"
```

---

## Self-Review

**Spec coverage:** atomic accessor (Task 1) ✓; rename cropMaster→cropToCoverage + callers (Task 1) ✓; crop in renderSnapshot + handleNative (Task 2) ✓; cropped linear → consistent record/snapshot/master (Task 2 step 3 note) ✓; guards reused (unchanged helper) ✓; master.fit unchanged (rename-only + CropToOverlapPipelineTests green) ✓; nil-coverage/uniform → full frame (guard + no-drift test) ✓; display==master crop (test) ✓; always-on/no UI ✓.

**Placeholder scan:** no TBD/TODO; every code step has full code; commands have expected output.

**Type consistency:** `currentStackAndCoverage() -> (image: AstroImage, coverage: [Float]?)?` and `cropToCoverage(_:coverage:)` signatures identical across Tasks 1 & 2. Destructure `(mean0, coverage)` names consistent in both render sites. `SUB_W`/`SUB_H` (256) reused from the existing test class.
