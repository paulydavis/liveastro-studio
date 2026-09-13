# Import Finalize Throttle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** During import, render the per-frame display/snapshot only on a cadence (~`snapshotBudget` renders, not one per accepted frame), cutting the measured 1.78 s/frame finalize (82% of the serial import cost) to hit ~2× (up to ~25× on 1483-frame imports).

**Architecture:** All in `SessionPipeline.swift`. Add import-only cadence state; factor the existing finalize render block into a `renderSnapshot` helper; gate it in `finalizeCommitted` behind a stride check (live/watcher mode always renders); and add one guaranteed final render in `end()` so `latest.png` + the last replay keyframe reflect full depth even when the last accepted frame was throttled.

**Tech Stack:** Swift 5.10, SPM package `LiveAstroCore`, XCTest.

## Global Constraints

- Branch `feature/import-finalize-throttle` (off main = v3.2.3). NEVER commit to / base on / rebase onto `main`.
- Commit trailer on every commit: `Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j`. NO `Co-Authored-By`.
- **Import mode only.** The live/watcher path (frames trickle at ~11 s) MUST keep rendering every committed frame — unchanged. Import mode = `source?.isFinite == true`.
- `master.fit` (full-res, cropped, additive-neutralized), the register/warp/commit pipeline, the neutralize math, and per-frame progress/count reporting MUST be unchanged.
- Cheap bookkeeping (`noteFrameProgress()`, `processedCount += 1`, `onImportProgress?`) runs for EVERY frame; only the expensive render (mean→downsample→neutralize→snapshot→preview) is throttled.
- Run only ONE `swift test` / `swift build` at a time (SPM build lock).

---

## File Structure

- `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` — all production changes (state, stride at `startSources`, `renderSnapshot` helper, gate in `finalizeCommitted`, final render in `end()`).
- `Tests/LiveAstroCoreTests/SessionPipelineFinalizeThrottleTests.swift` — new test file (both tasks).

Current relevant code (main = v3.2.3):
- State props ~line 74 (`private var processedCount = 0`), ~145 (`var importPrimaryTimeout`), ~150 (`var importPreviewLongEdge = SnapshotRecorder.maxSnapshotLongEdge`).
- `finalizeCommitted` (lines 249–277): does `noteFrameProgress()` then `withCallbackDelivery { … }` — inside: metadata capture, `processedCount += 1`, `guard let mean = engine.currentStack()`, `guard let recorder`, the render block (`downsampled` → `displayCGImage` → `recorder.save` → `session.recordSnapshot` → `onUpdate?`), then `onImportProgress?`.
- `startSources` import branch (lines 339–355): `if src.isFinite { … BatchImporter(engine: eng) … }`.
- `end()` import drain (~lines 703–706): `try drainFiniteImportOrThrow()` then `source?.stop()`, inside `if source?.isFinite ?? false {`.

---

### Task 1: Import finalize cadence + factored render helper

**Files:**
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` (add state; `startSources` stride; factor `renderSnapshot`; gate `finalizeCommitted`)
- Test: `Tests/LiveAstroCoreTests/SessionPipelineFinalizeThrottleTests.swift` (create)

**Interfaces:**
- Produces: `var snapshotBudget = 60` (internal test seam), `private var importFinalizeStride = 1`, `private var lastRenderedAcceptedIndex = 0`, `private var lastCommitted: (name: String, timestamp: Date)?`; `private func renderSnapshot(index:sourceName:timestamp:engine:)`; `private func shouldRenderImport(acceptedIndex:) -> Bool`. Task 2 consumes `renderSnapshot`, `lastRenderedAcceptedIndex`, `lastCommitted`.

- [ ] **Step 1: Write the failing test**

Create `Tests/LiveAstroCoreTests/SessionPipelineFinalizeThrottleTests.swift`:

```swift
import XCTest
@testable import LiveAstroCore

final class SessionPipelineFinalizeThrottleTests: XCTestCase {
    /// A finite source that yields the SAME frame `count` times (each registers via identity,
    /// so all commit) with totalCount set — exercises the real BatchImporter import path.
    private final class NFrameFiniteSource: FrameSource {
        let frames: AsyncStream<RawFrame>
        var isFinite: Bool { true }
        let totalCount: Int?
        init(_ frame: RawFrame, count: Int) {
            totalCount = count
            frames = AsyncStream { c in for _ in 0..<count { c.yield(frame) }; c.finish() }
        }
        func start() throws {}
        func stop() {}
    }

    private func starFrame() -> RawFrame {
        let w = 240, h = 180
        var px = [Float](repeating: 0.05, count: w * h)
        for i in 0..<20 {                       // ≥15 well-separated stars so the engine seeds
            let sx = (i % 5) * 46 + 20, sy = (i / 5) * 42 + 20
            for y in (sy - 4)...(sy + 4) { for x in (sx - 4)...(sx + 4) {
                let dx = Double(x - sx), dy = Double(y - sy)
                px[y * w + x] += 0.9 * Float(exp(-(dx * dx + dy * dy) / 5))
            } }
        }
        let img = AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true)
        return RawFrame(image: img, bayerPattern: nil, bottomUp: false,
                        timestamp: Date(timeIntervalSince1970: 0), sourceName: "sub.fit")
    }

    private func run(count: Int, budget: Int) throws -> (dir: URL, snapshots: Int) {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let profile = SessionProfile(targetName: "T", subExposureSeconds: 20)
        let engine = StackEngine()
        let pipeline = SessionPipeline(nativeSource: NFrameFiniteSource(starFrame(), count: count),
                                       engine: engine, profile: profile, rootDirectory: sandbox)
        pipeline.snapshotBudget = budget
        pipeline.rendersReplay = false     // skip the replay render for speed; end()'s final snapshot
                                           // render runs before replay, so it's still exercised
        try pipeline.start()
        let dir = try pipeline.end()
        let snaps = try FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("snapshots"),
                                                                includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }.count
        return (dir, snaps)
    }

    /// budget 5 over 20 frames → stride 4 → renders at 1,4,8,12,16,20 = 6 snapshots (not 20).
    func testImportThrottlesSnapshots() throws {
        let (dir, snaps) = try run(count: 20, budget: 5)
        XCTAssertEqual(snaps, 6, "throttled import should render ~budget snapshots, not one per frame")
        // Every frame still counted: manifest integration reflects all 20 accepted.
        let manifest = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
        XCTAssertFalse(manifest.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionPipelineFinalizeThrottleTests/testImportThrottlesSnapshots`
Expected: FAIL — `snapshotBudget` doesn't exist yet (compile error), or (if stubbed) snaps == 20 not 6.

- [ ] **Step 3: Add state, stride, helper, and the gate**

In `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift`, add these properties next to `importPreviewLongEdge` (~line 150):

```swift
    /// Import-only: render (mean→downsample→neutralize→snapshot→preview) on a cadence so ~`snapshotBudget`
    /// snapshots are produced instead of one per accepted frame (the 1.78 s/frame finalize is 82% of the
    /// serial import cost, and the replay keeps only maxKeyframes). Internal `var` = test seam. Live/watcher
    /// mode ignores this and renders every frame.
    var snapshotBudget = 60
    private var importFinalizeStride = 1          // 1 = every frame; set from totalCount at import start
    private var lastRenderedAcceptedIndex = 0     // for the guaranteed final render in end()
    private var lastCommitted: (name: String, timestamp: Date)?
```

In `startSources`, inside the `if src.isFinite {` import branch (just before `let cal = calibrator`), compute the stride:

```swift
            if src.isFinite {
                // IMPORT: frame-per-core parallel batch. Throttle finalize to ~snapshotBudget renders.
                let total = src.totalCount ?? 0
                importFinalizeStride = total > 0
                    ? max(1, Int((Double(total) / Double(snapshotBudget)).rounded()))
                    : 1
                let cal = calibrator
```

Factor the render block out of `finalizeCommitted` into a helper (add it right after `finalizeCommitted`):

```swift
    /// Renders + saves one snapshot from the current stack and pushes the preview. Shared by the
    /// throttled per-frame path and end()'s guaranteed final render. Sets lastRenderedAcceptedIndex.
    private func renderSnapshot(index: Int, sourceName: String, timestamp: Date, engine: StackEngine) {
        guard let mean = engine.currentStack() else { return }
        guard let recorder else { onLog?("recorder missing — frame dropped (\(sourceName))"); return }
        do {
            let displaySource = mean.downsampled(maxLongEdge: importPreviewLongEdge)
            let cg = try displayCGImage(from: displaySource)
            let record = try recorder.save(
                cgImage: cg, linear: mean, sourceFile: sourceName,
                index: index, timestamp: timestamp,
                estimatedIntegrationSeconds: Double(engine.stackFrameCount) * profile.subExposureSeconds)
            try session.recordSnapshot(record)
            lastRenderedAcceptedIndex = index
            onUpdate?(cg, record)
        } catch {
            onLog?("Skipped frame (\(sourceName)): \(error)")
        }
    }

    /// Live/watcher mode renders every committed frame; import mode renders the seed + every stride-th.
    private func shouldRenderImport(acceptedIndex index: Int) -> Bool {
        guard source?.isFinite == true else { return true }
        return index == 1 || index % importFinalizeStride == 0
    }
```

Now replace `finalizeCommitted`'s body (lines 249–277) so it uses the gate + helper:

```swift
    private func finalizeCommitted(index: Int, sourceName: String, timestamp: Date, metadata: SourceMetadata?, engine: StackEngine) {
        noteFrameProgress()   // cold1 I1: a finalized frame is drain progress
        withCallbackDelivery {
            if sourceMetadata == nil, let m = metadata { sourceMetadata = m }
            processedCount += 1
            lastCommitted = (sourceName, timestamp)       // remembered for end()'s guaranteed final render
            if shouldRenderImport(acceptedIndex: index) {
                renderSnapshot(index: index, sourceName: sourceName, timestamp: timestamp, engine: engine)
            }
            if let total = source?.totalCount {
                onImportProgress?(processedCount, total, engine.acceptedCount, engine.rejectedCount)
            }
        }
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter SessionPipelineFinalizeThrottleTests/testImportThrottlesSnapshots`
Expected: PASS (6 snapshots).

Then confirm the import/preview call-site tripwire + shutdown suites still pass:
Run: `swift test --filter SessionPipelineImportPreviewTests` then `swift test --filter SessionPipelineShutdownTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Pipeline/SessionPipeline.swift Tests/LiveAstroCoreTests/SessionPipelineFinalizeThrottleTests.swift
git commit -m "perf: throttle import finalize to ~snapshotBudget renders

Render mean->downsample->neutralize->snapshot->preview on a stride
(seed + every totalCount/budget-th accepted frame) during import only;
every frame still advances progress/counts. Live/watcher path renders
every frame unchanged. Factors renderSnapshot helper for reuse.

Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j"
```

---

### Task 2: Guaranteed final render in `end()`

**Files:**
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` (`end()` import drain branch)
- Test: `Tests/LiveAstroCoreTests/SessionPipelineFinalizeThrottleTests.swift` (add a method)

**Interfaces:**
- Consumes: `renderSnapshot`, `lastRenderedAcceptedIndex`, `lastCommitted` (Task 1); `engine.acceptedCount`.

- [ ] **Step 1: Write the failing test**

Add to `SessionPipelineFinalizeThrottleTests`:

```swift
    /// budget 5 over 21 frames → stride 4 → renders 1,4,8,12,16,20; last accepted (21) is off-cadence,
    /// so end() must emit one FINAL render → 7 snapshots, and latest.png decodes to the final stack.
    func testEndRendersFinalWhenLastFrameThrottled() throws {
        let (dir, snaps) = try run(count: 21, budget: 5)
        XCTAssertEqual(snaps, 7, "end() must add a final snapshot when the last accepted frame was throttled")
        let latest = try ImageLoader.load(url: dir.appendingPathComponent("latest.png"))
        XCTAssertGreaterThan(latest.width, 0, "latest.png reflects the guaranteed final render")
    }

    /// When the last accepted frame IS on-cadence, end() must NOT add a duplicate final render.
    func testEndAddsNoFinalWhenLastFrameRendered() throws {
        let (_, snaps) = try run(count: 20, budget: 5)   // 20 % 4 == 0 → last already rendered
        XCTAssertEqual(snaps, 6, "no duplicate final render when the last accepted frame was already rendered")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SessionPipelineFinalizeThrottleTests/testEndRendersFinalWhenLastFrameThrottled`
Expected: FAIL — snaps == 6 (no final render added yet), not 7.

- [ ] **Step 3: Add the final render in `end()`**

In `end()`, inside the import branch, immediately after `source?.stop()` (the `if source?.isFinite ?? false {` block, ~line 706), add:

```swift
                    try drainFiniteImportOrThrow()
                    source?.stop()
                    // Guaranteed final snapshot: the last accepted frame may have been throttled, so
                    // render once from the completed stack → latest.png + last replay keyframe show full depth.
                    if let eng = engine, lastRenderedAcceptedIndex < eng.acceptedCount, let lc = lastCommitted {
                        renderSnapshot(index: eng.acceptedCount, sourceName: lc.name, timestamp: lc.timestamp, engine: eng)
                    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SessionPipelineFinalizeThrottleTests`
Expected: PASS (all 3: throttle, final-when-throttled, no-final-when-rendered).

- [ ] **Step 5: Run the full suite once**

Run: `swift test 2>&1 | tail -15`
Expected: all tests pass (existing import/pipeline/replay suites green; the produced master + replay are unchanged).

- [ ] **Step 6: Commit**

```bash
git add Sources/LiveAstroCore/Pipeline/SessionPipeline.swift Tests/LiveAstroCoreTests/SessionPipelineFinalizeThrottleTests.swift
git commit -m "perf: guaranteed final snapshot at end() when last frame throttled

end() renders one final snapshot from the completed stack if the last
accepted frame was a throttled skip, so latest.png + the last replay
keyframe reflect full-depth integration. No-op when already rendered.

Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j"
```

---

## Post-plan: measure the win (not a code task)

Re-run the real 26 MP M63 import (release, the 16-symlink harness) with the throttle and record per-frame wall-clock in `project_liveastro_studio.md`. Expected: finalize drops from ~1.78 s/frame toward amortized; large imports approach the register/commit floor.

## Self-Review

**Spec coverage:** import-only cadence (Task 1 stride + gate) ✓; cheap bookkeeping every frame (Task 1 finalizeCommitted) ✓; seed always renders (`index == 1`) ✓; guaranteed final render (Task 2) ✓; sparse snapshots safe — replay reads manifest (no code change needed; existing behavior) ✓; live path untouched (`shouldRenderImport` returns true for non-finite) ✓; `snapshotBudget` test seam ✓; master.fit unchanged (not touched) ✓.

**Placeholder scan:** no TBD/TODO; every code step carries full code; commands have expected output.

**Type consistency:** `renderSnapshot(index:sourceName:timestamp:engine:)` and `shouldRenderImport(acceptedIndex:)` signatures identical across Tasks 1 & 2. `snapshotBudget`/`importFinalizeStride`/`lastRenderedAcceptedIndex`/`lastCommitted` names consistent. Stride formula `max(1, round(total/budget))` matches the spec and the test expectations (20/5→4, 21/5→4).
