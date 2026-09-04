# Staged Display Adjustments + Preview Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let display adjustments be tuned against a live preview and committed explicitly, so a slider drag no longer reaches the broadcast, and add a hold-to-compare clean-vs-online view in the same panel.

**Architecture:** A pure `StagedAdjustments` value type in `LiveAstroCore` holds committed + pending sets; only `apply()` promotes pending to committed, and only committed reaches `SessionPipeline`. `displayCGImage` becomes a pure function of (image, adjustments) so a preview can render with uncommitted values, and previews render from a cached box-averaged proxy (longest edge 1200 px) that preserves both the statistics `AutoStretch` derives and DBE's dimension-relative radius.

**Tech Stack:** Swift 6, SwiftUI (macOS 14+), XCTest, Swift Package Manager.

**Spec:** `docs/superpowers/specs/2026-09-03-staged-display-adjustments-design.md`

## Global Constraints

- Branch `feature/staged-display-adjustments`, from main @ v3.6.1. Never commit to, base on, or target `main`.
- Commit trailer `Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j`. NO `Co-Authored-By` trailer.
- Only `LiveAstroCore` is unit-testable — `LiveAstroStudio` is an `executableTarget` with no test target (`Package.swift:12,18`). Any logic that needs a real test belongs in `LiveAstroCore`.
- Preview downsample: use the EXISTING `AstroImage.downsampled(maxLongEdge:)` (`AstroImage.swift:38`) at `SessionPipeline.previewLongEdge = 1200`. Do not write a new downsampler.
- `AstroImage` is **planar (channel-major)** (`AstroImage.swift:16`): index as `c * plane + y * width + x`. Interleaved indexing silently scrambles colour.
- Preview-proxy cache key, per source: clean → the published master's `FreshnessKey`; native online → `(stack generation, previewStackRevision)`; watcher online → a monotonic token bumped when a frame is retained (NOT the file digest: `StackUpdate.identity` and `FileIdentity.digest` are both optional). Adjustments are deliberately NOT in any of them — the proxy is linear and pre-adjustment, so slider drags reuse it.
- Preview honesty bound: derived median and MADN within **2% relative** of the full frame, measured on a non-uniform (star-field) image.
- Full test suite green before merge. Baseline at v3.6.1 is 1217 tests / 8 skipped / 0 failures.

---

### Task 1: Make `displayCGImage` a pure function of (image, adjustments)

**Files:**
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift:1074` (signature) and call sites at `:929`, `:941`, `:1121`, `:1233`, `:1276`
- Create: `Tests/LiveAstroCoreTests/PreviewTestSupport.swift` (shared helpers used by Tasks 1, 2, 4)
- Test: `Tests/LiveAstroCoreTests/DisplayRenderParityTests.swift` (create)

**Interfaces:**
- Produces: `private func displayCGImage(from linear: AstroImage, adjustments adj: DisplayAdjustments) throws -> CGImage`
- Produces (test seam): `func renderForTest(_ image: AstroImage, adjustments: DisplayAdjustments) throws -> CGImage`

- [ ] **Step 0: Create the shared test support file**

Three later tasks need the same helpers, and `StubLiveSource` is currently NESTED inside
`GlobalRefinerTests` (`GlobalRefinerTests.swift:12`), so a bare `StubLiveSource` will not
compile from a new test file. Extract it once, here.

Create `Tests/LiveAstroCoreTests/PreviewTestSupport.swift`:

```swift
import XCTest
import CryptoKit
@testable import LiveAstroCore

/// Helpers shared by the preview/staging tests.
///
/// `AstroImage` is PLANAR (channel-major) — `AstroImage.swift:16`, and see `Denoiser.swift:78`
/// indexing `sane[i], sane[plane + i], sane[2 * plane + i]`. Index as
/// `c * plane + y * width + x`; interleaved indexing silently scrambles colour AND would make
/// these helpers agree with a broken implementation, so the tests would pass while the code is
/// wrong.
enum PreviewTestSupport {

    /// Non-uniform planar star field with a gradient. A CONSTANT image would let every
    /// statistic survive any transformation, making the honesty tests vacuous.
    static func starField(w: Int = 2400, h: Int = 1800, channels: Int = 3) -> AstroImage {
        let plane = w * h
        var px = [Float](repeating: 0, count: plane * channels)
        for c in 0..<channels {
            for y in 0..<h {
                for x in 0..<w {
                    let bg = 0.04 + 0.02 * Float(x) / Float(w)
                    let grain = Float((x &* 7 &+ y &* 13) % 11) * 0.0008
                    px[c * plane + y * w + x] = bg + grain + Float(c) * 0.005
                }
            }
        }
        for (sx, sy, amp) in [(520, 430, Float(0.8)), (1400, 1100, 0.5), (1900, 600, 0.65)] {
            for dy in -8...8 {
                for dx in -8...8 {
                    let x = sx + dx, y = sy + dy
                    guard x >= 0, x < w, y >= 0, y < h else { continue }
                    let g = amp * exp(-Float(dx * dx + dy * dy) / 12.0)
                    for c in 0..<channels { px[c * plane + y * w + x] += g }
                }
            }
        }
        return AstroImage(width: w, height: h, channels: channels, pixels: px, sourceIsLinear: true)
    }

    /// Planar luminance -> (median, MADN): the two values AutoStretch derives its transform from.
    static func medianAndMADN(_ image: AstroImage) -> (Double, Double) {
        let plane = image.width * image.height
        var lum = [Float](repeating: 0, count: plane)
        for c in 0..<image.channels {
            for i in 0..<plane { lum[i] += image.pixels[c * plane + i] }
        }
        let inv = Float(image.channels)
        for i in 0..<plane { lum[i] /= inv }
        lum.sort()
        let med = Double(lum[plane / 2])
        var dev = lum.map { abs(Double($0) - med) }
        dev.sort()
        return (med, dev[plane / 2] * 1.4826)
    }

    static func sha256(_ cg: CGImage) -> String {
        guard let data = cg.dataProvider?.data as Data? else { return "no-data" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
```

Then MOVE `StubLiveSource` out of `GlobalRefinerTests` (it is declared at
`GlobalRefinerTests.swift:12` as a nested `final class`) into its own file
`Tests/LiveAstroCoreTests/StubLiveSource.swift` at file scope, unchanged apart from being
top-level and `final class StubLiveSource: FrameSource`. Update `GlobalRefinerTests` references
if the compiler asks.

Run: `swift test --filter GlobalRefinerTests 2>&1 | grep -E "Executed [0-9]+ tests, with"`
Expected: 44 tests, 0 failures — the extraction changed no behaviour.

- [ ] **Step 1: Write the characterization test with a placeholder hash**

Create `Tests/LiveAstroCoreTests/DisplayRenderParityTests.swift`:

```swift
import XCTest
@testable import LiveAstroCore

/// The render path behind this test produces the broadcast, snapshots, latest.png and
/// master.fit. A regression here is SILENT — it lands in recorded data, not in a crash — so
/// the committed-path output is pinned by hash across the refactor that parameterises it.
final class DisplayRenderParityTests: XCTestCase {

    /// The adjustment set under test exercises every stage: black point, midtone, saturation,
    /// DBE (with both its parameters) and denoise.
    static var pinnedAdjustments: DisplayAdjustments {
        var a = DisplayAdjustments.neutral
        a.blackPoint = 0.02
        a.midtoneStrength = 0.35
        a.saturation = 1.4
        a.backgroundExtraction = true
        a.bgScale = 8
        a.bgSmoothest = 1.5
        a.denoiseStrength = 0.3
        return a
    }

    func testCommittedRenderIsUnchangedByParameterisation() throws {
        let pipeline = SessionPipeline.forRenderTest()
        let cg = try pipeline.renderForTest(PreviewTestSupport.starField(w: 320, h: 240),
                                            adjustments: Self.pinnedAdjustments)
        XCTAssertEqual(PreviewTestSupport.sha256(cg), "PLACEHOLDER_FILL_IN_STEP_2",
                       "the committed render path must be byte-identical across the refactor")
    }
}
```

- [ ] **Step 2: Record the golden hash on UNMODIFIED code**

Add the two seams needed to call the render path from a test, WITHOUT changing render behaviour. In `SessionPipeline.swift`, next to `renderCurrentDisplay`:

```swift
    /// Test seam: render an arbitrary image through the SAME path the broadcast uses.
    /// Exists so `DisplayRenderParityTests` can pin the committed output by hash.
    func renderForTest(_ image: AstroImage, adjustments: DisplayAdjustments) throws -> CGImage {
        displayAdjustments = adjustments
        return try displayCGImage(from: image)
    }

    /// Test seam: a minimal pipeline usable for render-path tests. `nativeSource` is
    /// NON-OPTIONAL on this init (`SessionPipeline.swift:797`), so pass an empty stub source
    /// rather than nil — `StubLiveSource(sequence: [])` never yields a frame, so nothing runs.
    static func forRenderTest() -> SessionPipeline {
        SessionPipeline(nativeSource: StubLiveSource(sequence: []), engine: StackEngine(),
                        profile: SessionProfile(targetName: "RenderTest", telescope: "T", camera: "C",
                                                mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                                subExposureSeconds: 1, notes: ""),
                        rootDirectory: FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString, isDirectory: true))
    }
```

Run: `swift test --filter DisplayRenderParityTests 2>&1 | grep -E "XCTAssertEqual failed|passed"`
Expected: FAIL, reporting the ACTUAL hash. Copy that hash into `PLACEHOLDER_FILL_IN_STEP_2`.

- [ ] **Step 3: Re-run to confirm the golden is now green on unmodified code**

Run: `swift test --filter DisplayRenderParityTests`
Expected: PASS. This is the pre-refactor baseline — the test is now guarding real behaviour.

- [ ] **Step 4: Commit the baseline before touching the render path**

```bash
git add Tests/LiveAstroCoreTests/PreviewTestSupport.swift Tests/LiveAstroCoreTests/StubLiveSource.swift \
        Tests/LiveAstroCoreTests/GlobalRefinerTests.swift \
        Tests/LiveAstroCoreTests/DisplayRenderParityTests.swift \
        Sources/LiveAstroCore/Pipeline/SessionPipeline.swift
git commit -m "test: pin the committed display-render output by hash before parameterising it

Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j"
```

- [ ] **Step 5: Parameterise `displayCGImage`**

At `SessionPipeline.swift:1074`, change the signature and delete the locked read:

```swift
    private func displayCGImage(from linear: AstroImage,
                                adjustments adj: DisplayAdjustments) throws -> CGImage {
        // (was: let adj = displayAdjustments — the caller now supplies it, so this function is
        // a pure function of (image, adjustments) and can render UNCOMMITTED values for the
        // staged preview without touching pipeline state.)
```

Update all five call sites to pass the committed value explicitly. At `:929`, `:941`, `:1233`, `:1276` the surrounding code renders for broadcast/snapshot, so each becomes:

```swift
        let broadcastCG = try displayCGImage(from: displaySource, adjustments: displayAdjustments)
```

(applying the same `, adjustments: displayAdjustments` argument at each site; keep each call's existing variable names). At `:1121`, inside `renderCurrentDisplay(adjustments:)`, pass the parameter it already has:

```swift
        return try? displayCGImage(from: mean, adjustments: adjustments)
```

Simplify the test seam now that no mutation is needed:

```swift
    func renderForTest(_ image: AstroImage, adjustments: DisplayAdjustments) throws -> CGImage {
        try displayCGImage(from: image, adjustments: adjustments)
    }
```

- [ ] **Step 6: Verify the golden still holds**

Run: `swift test --filter DisplayRenderParityTests`
Expected: PASS with the same hash — proving the refactor changed no output.

- [ ] **Step 7: Run the neighbouring render suites**

Run: `swift test --filter "NativePipelineTests|SessionPipelineSnapshotTests|RestackPlanningTests"`
Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/LiveAstroCore/Pipeline/SessionPipeline.swift Tests/LiveAstroCoreTests/DisplayRenderParityTests.swift
git commit -m "refactor: displayCGImage takes adjustments as a parameter

Enables rendering UNCOMMITTED adjustments for the staged preview without
mutating pipeline state. Committed output pinned byte-identical by hash.

Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j"
```

---

### Task 2: Preview downsample constant + proof it does not distort the stretch

**Files:**
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` (add `previewLongEdge` constant)
- Test: `Tests/LiveAstroCoreTests/PreviewDownsampleHonestyTests.swift` (create)
- Consumes: `PreviewTestSupport` (Task 1 Step 0)

**Interfaces:**
- Consumes: `AstroImage.downsampled(maxLongEdge:)` — ALREADY EXISTS (`AstroImage.swift:38`)
- Produces: `static let previewLongEdge = 1200` on `SessionPipeline`

**Do NOT write a new downsampler.** `AstroImage.downsampled(maxLongEdge:)` already does exactly
this job: area-averaging, planar-correct, one O(pixels) pass, covered by
`AstroImageDownsampleTests`, and already used by the render path at `SessionPipeline.swift:928`
and `:940`. Its doc states its purpose is rendering the preview/display from a huge stacked
frame. An earlier draft of this plan reimplemented it (with the WRONG pixel layout); that is
deleted. This task adds only the named constant and the one property nothing currently proves.

**`AstroImage` is PLANAR (channel-major)** — `AstroImage.swift:16`, and see `Denoiser.swift:78`
indexing `sane[i], sane[plane + i], sane[2 * plane + i]`. Index as `c * plane + y * width + x`.
Interleaved `(y * w + x) * c` indexing is WRONG and will silently scramble colour.

- [ ] **Step 1: Write the failing honesty test**

Create `Tests/LiveAstroCoreTests/PreviewDownsampleHonestyTests.swift`:

```swift
import XCTest
@testable import LiveAstroCore

/// The staged preview renders from a downsample. `AutoStretch` derives its transform from the
/// image's OWN median and MADN (`AutoStretch.swift:47-57`), so if downsampling moved those
/// statistics the preview would show a different stretch than the broadcast — a preview that
/// lies is worse than no preview. `AstroImageDownsampleTests` already covers the mechanics of
/// the downsample; this covers the property the preview design rests on, which nothing did.
final class PreviewDownsampleHonestyTests: XCTestCase {

    func testDownsamplePreservesTheStatisticsAutoStretchDerives() {
        let full = PreviewTestSupport.starField()
        let proxy = full.downsampled(maxLongEdge: SessionPipeline.previewLongEdge)
        XCTAssertLessThanOrEqual(max(proxy.width, proxy.height), SessionPipeline.previewLongEdge)

        let (mFull, dFull) = PreviewTestSupport.medianAndMADN(full)
        let (mProxy, dProxy) = PreviewTestSupport.medianAndMADN(proxy)
        XCTAssertEqual(mProxy, mFull, accuracy: abs(mFull) * 0.02,
                       "median must survive the preview downsample within 2% — the stretch is derived from it")
        XCTAssertEqual(dProxy, dFull, accuracy: abs(dFull) * 0.02,
                       "MADN must survive the preview downsample within 2% — it sets the stretch slope")
    }

    /// Sentinel against the planar/interleaved confusion that produced the earlier draft of
    /// this plan: give each channel a distinct constant and prove the planes stay separate and
    /// keep their values through the downsample. Interleaved indexing anywhere in the chain
    /// smears the three constants together and this fails.
    func testDownsampleKeepsColourPlanesSeparate() {
        let w = 2400, h = 1800, plane = w * h
        var px = [Float](repeating: 0, count: plane * 3)
        for i in 0..<plane { px[i] = 0.10; px[plane + i] = 0.50; px[2 * plane + i] = 0.90 }
        let img = AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)

        let out = img.downsampled(maxLongEdge: SessionPipeline.previewLongEdge)
        let outPlane = out.width * out.height
        XCTAssertEqual(out.channels, 3)
        for (c, expected) in [(0, Float(0.10)), (1, 0.50), (2, 0.90)] {
            let mean = (0..<outPlane).reduce(Float(0)) { $0 + out.pixels[c * outPlane + $1] } / Float(outPlane)
            XCTAssertEqual(mean, expected, accuracy: 0.001,
                           "channel \(c) must keep its own value — planar layout, not interleaved")
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter PreviewDownsampleHonestyTests`
Expected: FAIL — `SessionPipeline.previewLongEdge` does not exist.

- [ ] **Step 3: Add the constant**

In `SessionPipeline.swift`, beside the existing `importPreviewLongEdge`:

```swift
    /// Long edge the STAGED PREVIEW renders at. A 26 MP 6236x4159 stack lands ~1200x800, so a
    /// slider drag re-renders ~1 MP instead of 26 MP. Downsampling (not cropping) is what keeps
    /// the preview honest: it preserves both the statistics `AutoStretch` derives its transform
    /// from and DBE's dimension-relative radius (`BackgroundExtraction.swift:281`).
    static let previewLongEdge = 1200
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter "PreviewDownsampleHonestyTests|AstroImageDownsampleTests"`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Pipeline/SessionPipeline.swift Tests/LiveAstroCoreTests/PreviewDownsampleHonestyTests.swift
git commit -m "test: pin that the preview downsample preserves the derived stretch statistics

Uses the existing AstroImage.downsampled(maxLongEdge:) rather than a new
downsampler. Adds a planar-layout sentinel so interleaved indexing cannot creep
into the preview path.

Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j"
```

---

### Task 3: `StagedAdjustments` — the pending/committed state machine

**Files:**
- Create: `Sources/LiveAstroCore/Imaging/StagedAdjustments.swift`
- Test: `Tests/LiveAstroCoreTests/StagedAdjustmentsTests.swift` (create)

**Interfaces:**
- Consumes: `DisplayAdjustments` (`Sources/LiveAstroCore/Imaging/DisplayAdjustments.swift`)
- Produces: `public struct StagedAdjustments { public private(set) var committed: DisplayAdjustments; public var pending: DisplayAdjustments; public var hasPendingChanges: Bool; public init(committed:); public mutating func apply() -> DisplayAdjustments; public mutating func revert() }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LiveAstroCoreTests/StagedAdjustmentsTests.swift`:

```swift
import XCTest
@testable import LiveAstroCore

/// This type exists in LiveAstroCore rather than AppModel for one reason: LiveAstroStudio is
/// an executableTarget with no test target (Package.swift:12,18), so state living there can
/// only be checked by grepping source text. The staging invariant is the property the whole
/// feature rests on, so it gets a real test.
final class StagedAdjustmentsTests: XCTestCase {

    private func adj(blackPoint: Double) -> DisplayAdjustments {
        var a = DisplayAdjustments.neutral
        a.blackPoint = blackPoint
        return a
    }

    /// THE invariant: editing `pending` must never move `committed`, which is what the
    /// pipeline (and therefore the broadcast) reads.
    func testEditingPendingLeavesCommittedUntouched() {
        var s = StagedAdjustments(committed: adj(blackPoint: 0.01))
        s.pending = adj(blackPoint: 0.19)
        XCTAssertEqual(s.committed.blackPoint, 0.01,
                       "a pending edit must never reach committed — committed is what viewers see")
        XCTAssertTrue(s.hasPendingChanges)
    }

    func testApplyPromotesPendingAndReturnsTheNewCommittedValue() {
        var s = StagedAdjustments(committed: adj(blackPoint: 0.01))
        s.pending = adj(blackPoint: 0.19)
        let committed = s.apply()
        XCTAssertEqual(committed.blackPoint, 0.19, "apply must RETURN the value to push to the pipeline")
        XCTAssertEqual(s.committed.blackPoint, 0.19)
        XCTAssertFalse(s.hasPendingChanges, "after apply the two sets agree")
    }

    func testRevertDiscardsPendingAndRestoresCommitted() {
        var s = StagedAdjustments(committed: adj(blackPoint: 0.01))
        s.pending = adj(blackPoint: 0.19)
        s.revert()
        XCTAssertEqual(s.pending.blackPoint, 0.01)
        XCTAssertFalse(s.hasPendingChanges)
    }

    func testFreshStateHasNoPendingChanges() {
        let s = StagedAdjustments(committed: adj(blackPoint: 0.05))
        XCTAssertFalse(s.hasPendingChanges, "a panel must open quiet, with Apply/Revert disabled")
        XCTAssertEqual(s.pending, s.committed)
    }

    /// Editing pending back to the committed value by hand must clear the pending state, or
    /// Apply/Revert would stay lit with nothing to do.
    func testEditingPendingBackToCommittedClearsThePendingState() {
        var s = StagedAdjustments(committed: adj(blackPoint: 0.01))
        s.pending = adj(blackPoint: 0.19)
        s.pending = adj(blackPoint: 0.01)
        XCTAssertFalse(s.hasPendingChanges)
    }

    /// Apply with nothing pending is a no-op that still returns the committed value, so the
    /// caller can push unconditionally without a special case.
    func testApplyWithNothingPendingIsANoOp() {
        var s = StagedAdjustments(committed: adj(blackPoint: 0.05))
        let committed = s.apply()
        XCTAssertEqual(committed.blackPoint, 0.05)
        XCTAssertFalse(s.hasPendingChanges)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter StagedAdjustmentsTests`
Expected: FAIL — "cannot find 'StagedAdjustments' in scope".

- [ ] **Step 3: Implement `StagedAdjustments`**

Create `Sources/LiveAstroCore/Imaging/StagedAdjustments.swift`:

```swift
import Foundation

/// Display adjustments split into what the audience currently sees (`committed`) and what the
/// operator is editing (`pending`).
///
/// Before this, `AppModel.applyDisplayAdjustments()` pushed every slider tick straight into
/// `SessionPipeline.displayAdjustments`, which feeds the broadcast, snapshots, `latest.png`,
/// replay and `master.fit` — so tuning mid-stream published every intermediate state. Only
/// `apply()` promotes `pending`, and only `committed` is ever handed to the pipeline or
/// persisted.
///
/// Deliberately a plain value type with no UI or pipeline dependency: it lives in
/// `LiveAstroCore` because `LiveAstroStudio` has no test target, and this is the invariant
/// the feature rests on.
public struct StagedAdjustments: Equatable {
    /// What the pipeline holds — the broadcast, the recorded artifacts, and the persisted set.
    public private(set) var committed: DisplayAdjustments
    /// What the sliders bind to. Never reaches the pipeline, never persisted.
    public var pending: DisplayAdjustments

    public init(committed: DisplayAdjustments) {
        self.committed = committed
        self.pending = committed
    }

    /// Drives the panel's pending treatment and the enabled state of Apply/Revert.
    public var hasPendingChanges: Bool { pending != committed }

    /// Promotes `pending` and RETURNS the new committed value, so the caller pushes exactly
    /// what was committed rather than re-reading state that may have moved.
    public mutating func apply() -> DisplayAdjustments {
        committed = pending
        return committed
    }

    /// Throws the pending edits away.
    public mutating func revert() {
        pending = committed
    }
}
```

- [ ] **Step 4: Confirm `DisplayAdjustments` is `Equatable`**

`hasPendingChanges` and the tests need `==`. Check:

Run: `grep -n "struct DisplayAdjustments" Sources/LiveAstroCore/Imaging/DisplayAdjustments.swift`
If the declaration does not already conform, add `Equatable` to it (all stored properties are `Double`/`Bool`/`Int`, so the synthesised conformance is correct).

- [ ] **Step 5: Run tests**

Run: `swift test --filter StagedAdjustmentsTests`
Expected: all six PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LiveAstroCore/Imaging/StagedAdjustments.swift Tests/LiveAstroCoreTests/StagedAdjustmentsTests.swift Sources/LiveAstroCore/Imaging/DisplayAdjustments.swift
git commit -m "feat: StagedAdjustments splits committed from pending display adjustments

Lives in LiveAstroCore, not AppModel, so the staging invariant gets a real test
rather than a source-text grep (LiveAstroStudio has no test target).

Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j"
```

---

### Task 4: `renderPreview(source:adjustments:)` — non-mutating preview render

**Files:**
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` (add near `renderCurrentDisplay`, `:1115`)
- Test: `Tests/LiveAstroCoreTests/PreviewRenderTests.swift` (create)

**Interfaces:**
- Consumes: `AstroImage.downsampled(maxLongEdge:)` + `SessionPipeline.previewLongEdge` (Task 2), `displayCGImage(from:adjustments:)` (Task 1), `PreviewTestSupport` and top-level `StubLiveSource` (Task 1 Step 0)
- Produces: `public enum PreviewSource { case clean, online }` and `public func renderPreview(source: PreviewSource, adjustments: DisplayAdjustments) -> CGImage?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LiveAstroCoreTests/PreviewRenderTests.swift`:

```swift
import XCTest
@testable import LiveAstroCore

final class PreviewRenderTests: XCTestCase {

    /// The whole point of the staged model: rendering a preview must not move the state the
    /// broadcast reads. Pre-change, `renderCurrentDisplay(adjustments:)` assigned to
    /// `displayAdjustments` as a side effect (SessionPipeline.swift:1116).
    func testRenderPreviewDoesNotMutateCommittedAdjustments() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (pipeline, source) = try PreviewRenderTests.runningPipeline(sandbox: sandbox)
        defer { source.stop() }

        var committed = DisplayAdjustments.neutral
        committed.blackPoint = 0.01
        pipeline.displayAdjustments = committed

        var pending = DisplayAdjustments.neutral
        pending.blackPoint = 0.18
        _ = pipeline.renderPreview(source: .online, adjustments: pending)

        XCTAssertEqual(pipeline.displayAdjustments.blackPoint, 0.01,
                       "a preview render must leave the committed adjustments alone")
    }

    /// The preview must actually honour the adjustments passed in — otherwise it would show
    /// the committed look and silently mislead.
    func testRenderPreviewReflectsTheAdjustmentsPassedIn() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (pipeline, source) = try PreviewRenderTests.runningPipeline(sandbox: sandbox)
        defer { source.stop() }

        var dark = DisplayAdjustments.neutral;  dark.blackPoint = 0.0
        var light = DisplayAdjustments.neutral; light.blackPoint = 0.15
        let a = try XCTUnwrap(pipeline.renderPreview(source: .online, adjustments: dark))
        let b = try XCTUnwrap(pipeline.renderPreview(source: .online, adjustments: light))
        XCTAssertNotEqual(PreviewTestSupport.sha256(a), PreviewTestSupport.sha256(b),
                          "different adjustments must produce a different preview")
    }

    /// The preview renders from the downsampled proxy, so it is bounded by previewLongEdge.
    func testPreviewIsRenderedFromTheDownsampledProxy() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (pipeline, source) = try PreviewRenderTests.runningPipeline(sandbox: sandbox)
        defer { source.stop() }

        let cg = try XCTUnwrap(pipeline.renderPreview(source: .online, adjustments: .neutral))
        XCTAssertLessThanOrEqual(max(cg.width, cg.height), SessionPipeline.previewLongEdge)
    }

    /// Finding 2: the spec requires a CACHED proxy. Without one, every slider tick walks the
    /// full 26 MP stack to build the downsample, so the drag is still O(26 MP) and only the
    /// final render got cheaper. Adjustment-only re-renders must reuse the proxy.
    func testRepeatedPreviewRendersReuseTheCachedProxy() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (pipeline, source) = try PreviewRenderTests.runningPipeline(sandbox: sandbox)
        defer { source.stop() }

        var a = DisplayAdjustments.neutral; a.blackPoint = 0.02
        var b = DisplayAdjustments.neutral; b.blackPoint = 0.06
        _ = pipeline.renderPreview(source: .online, adjustments: a)
        let buildsAfterFirst = pipeline.previewProxyBuildCountForTest
        _ = pipeline.renderPreview(source: .online, adjustments: b)
        _ = pipeline.renderPreview(source: .online, adjustments: a)

        XCTAssertEqual(pipeline.previewProxyBuildCountForTest, buildsAfterFirst,
                       "changing only the adjustments must reuse the cached proxy — adjustments are "
                       + "deliberately NOT part of the cache key, the proxy is linear and pre-adjustment")
    }

    /// ...but a new sub must invalidate it, or the preview would freeze on the first stack.
    func testANewSubInvalidatesTheCachedProxy() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (pipeline, source) = try PreviewRenderTests.runningPipeline(sandbox: sandbox)
        defer { source.stop() }

        _ = pipeline.renderPreview(source: .online, adjustments: .neutral)
        let before = pipeline.previewProxyBuildCountForTest
        let targetCount = pipeline.subRegistrations().count + 1

        source.send(RawFrame(image: PreviewTestSupport.starField(w: 2400, h: 1800),
                             bayerPattern: nil, bottomUp: false,
                             timestamp: Date(timeIntervalSince1970: 99), sourceName: "pv9.fit",
                             identity: FileIdentity(dev: 0, ino: 0, size: 0, mtimeSec: 0,
                                                    mtimeNsec: 0, digest: "pv9"),
                             sourceURL: URL(fileURLWithPath: "/tmp/preview/pv9.fit")))
        // Capture the target BEFORE sending, or the count read may already include the new sub
        // and the wait becomes a no-op that passes for the wrong reason.
        let deadline = Date().addingTimeInterval(20)
        while pipeline.subRegistrations().count < targetCount && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        _ = pipeline.renderPreview(source: .online, adjustments: .neutral)
        XCTAssertGreaterThan(pipeline.previewProxyBuildCountForTest, before,
                             "a new sub changes the stack, so the proxy must be rebuilt")
    }

    /// The case a (generation, sub count) key would MISS: a user reject changes which master is
    /// servable while both of those stay put.
    ///
    /// The correct behaviour is NOT "rebuild the proxy" — it is "serve nothing". A reject makes
    /// the published master WRONG (it contains a now-rejected sub), so `isServable` fails and
    /// `publishedMasterFreshnessKeyIfCurrent()` returns nil: the clean preview must go away
    /// entirely until a NEW master publishes. Serving a rebuilt-but-stale clean master would
    /// make the blink comparison compare against a master that no longer exists.
    func testAUserRejectStopsServingTheCleanPreviewUntilANewMasterPublishes() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (pipeline, source) = try PreviewRenderTests.runningPipeline(sandbox: sandbox)
        defer { source.stop() }
        pipeline.configureLiveRejection(enabled: true)

        guard let (mean, coverage) = pipeline.engineForTest?.currentStackAndCoverage() else {
            return XCTFail("expected a stack")
        }
        let cov = coverage ?? [Float](repeating: 1, count: mean.width * mean.height)
        pipeline.publishedMaster = PublishedMaster(
            image: mean, coverage: cov,
            survivorCount: pipeline.subRegistrations().count,
            key: pipeline.currentFreshnessKey())

        XCTAssertNotNil(pipeline.renderPreview(source: .clean, adjustments: .neutral),
                        "precondition: a current clean master IS previewable")
        let buildsBefore = pipeline.previewProxyBuildCountForTest

        // Same generation, same sub count — only the reject state moves.
        pipeline.setUserRejected([1])
        pipeline.noteUserRejectChanged()

        XCTAssertNil(pipeline.renderPreview(source: .clean, adjustments: .neutral),
                     "a master containing a now-rejected sub must not be previewed at all")
        XCTAssertEqual(pipeline.previewProxyBuildCountForTest, buildsBefore,
                       "and nothing is rebuilt while there is nothing servable to build from")

        // A fresh pass publishes at the NEW key; the clean preview returns and is rebuilt.
        pipeline.publishedMaster = PublishedMaster(
            image: mean, coverage: cov,
            survivorCount: pipeline.subRegistrations().count - 1,
            key: pipeline.currentFreshnessKey())
        XCTAssertNotNil(pipeline.renderPreview(source: .clean, adjustments: .neutral))
        XCTAssertGreaterThan(pipeline.previewProxyBuildCountForTest, buildsBefore,
                             "the new master carries a different FreshnessKey, so the proxy is rebuilt")
    }

    /// Watcher / external-stacker mode has NO engine (SessionPipeline.swift:768 leaves it nil),
    /// so without `lastPreviewLinear` the preview would be permanently blank there.
    func testWatcherModeStillProducesAPreview() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let watch = sandbox.appendingPathComponent("watch", isDirectory: true)
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        let pipeline = SessionPipeline(watchFolder: watch, profile:
            SessionProfile(targetName: "Watch", telescope: "T", camera: "C", mount: "M",
                           filter: "F", locationLabel: "L", bortle: 5,
                           subExposureSeconds: 20, notes: ""),
            rootDirectory: sandbox.appendingPathComponent("sessions"))

        XCTAssertNil(pipeline.renderPreview(source: .online, adjustments: .neutral),
                     "no frame seen yet — the panel shows its placeholder")
        pipeline.noteWatcherFrame(PreviewTestSupport.starField(w: 2400, h: 1800))
        let cg = try XCTUnwrap(pipeline.renderPreview(source: .online, adjustments: .neutral),
                               "watcher mode must still preview, from the retained last frame")
        XCTAssertLessThanOrEqual(max(cg.width, cg.height), SessionPipeline.previewLongEdge)
    }

    /// The callback is the ACTUAL fix for "a clean master appeared but the UI never knew", and
    /// it lives in LiveAstroCore, so it gets a real test rather than a source-text grep. It must
    /// fire when a publish is INSTALLED and stay silent when one is dropped — a notification for
    /// a dropped publish would make the panel switch to a clean master that was never stored.
    func testOnCleanMasterPublishedFiresOnlyWhenAPublishIsActuallyInstalled() throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock(); private var n = 0
            func bump() { lock.withLock { n += 1 } }
            var count: Int { lock.withLock { n } }
        }
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (pipeline, source) = try PreviewRenderTests.runningPipeline(sandbox: sandbox)
        defer { source.stop() }
        pipeline.configureLiveRejection(enabled: true)

        let fired = Counter()
        pipeline.onCleanMasterPublished = { fired.bump() }
        let refiner = try XCTUnwrap(pipeline.refinerForTest())
        guard let (mean, coverage) = pipeline.engineForTest?.currentStackAndCoverage() else {
            return XCTFail("expected a stack")
        }
        let cov = coverage ?? [Float](repeating: 1, count: mean.width * mean.height)
        let key = pipeline.currentFreshnessKey()
        let result = RefineResult(image: mean, coverage: cov,
                                  survivorCount: pipeline.subRegistrations().count, skipped: 0)

        refiner.publish?(result, key)
        XCTAssertEqual(fired.count, 1, "a servable publish is installed, so the UI must be told")

        // Now make that key unservable — a user reject changes what the master MEANS — and
        // republish under it. publishRefineResult drops the result, so nothing may fire.
        pipeline.setUserRejected([1])
        pipeline.noteUserRejectChanged()
        refiner.publish?(result, key)
        XCTAssertEqual(fired.count, 1,
                       "a dropped (unservable) publish stores nothing, so it must not notify — "
                       + "otherwise the panel switches to a clean master that was never installed")
    }

    /// With live rejection off there is no clean master, and the caller must be able to tell —
    /// the blink control's disabled state depends on it.
    func testCleanSourceReturnsNilWhenNoCleanMasterIsPublished() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (pipeline, source) = try PreviewRenderTests.runningPipeline(sandbox: sandbox)
        defer { source.stop() }

        XCTAssertNil(pipeline.renderPreview(source: .clean, adjustments: .neutral),
                     "no published clean master means no clean preview")
    }

    /// Reuses the established live-pipeline harness and the top-level `StubLiveSource`
    /// extracted in Task 1 Step 0.
    static func runningPipeline(sandbox: URL) throws -> (SessionPipeline, StubLiveSource) {
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let profile = SessionProfile(targetName: "Preview", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let engine = StackEngine()
        let frames = (0..<3).map { i in
            RawFrame(image: PreviewTestSupport.starField(w: 2400, h: 1800),
                     bayerPattern: nil, bottomUp: false,
                     timestamp: Date(timeIntervalSince1970: TimeInterval(i)),
                     sourceName: "pv\(i).fit",
                     identity: FileIdentity(dev: 0, ino: 0, size: 0, mtimeSec: 0, mtimeNsec: 0,
                                            digest: "pv\(i)"),
                     sourceURL: URL(fileURLWithPath: "/tmp/preview/pv\(i).fit"))
        }
        let source = StubLiveSource(sequence: frames)
        let pipeline = SessionPipeline(nativeSource: source, engine: engine,
                                       profile: profile, rootDirectory: sessions)
        pipeline.rendersReplay = false
        try pipeline.start()
        let deadline = Date().addingTimeInterval(20)
        while pipeline.subRegistrations().count < 1 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        return (pipeline, source)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter PreviewRenderTests`
Expected: FAIL — "cannot find 'renderPreview'".

- [ ] **Step 3: Implement the source selector and preview render**

In `SessionPipeline.swift`, immediately after `renderCurrentDisplay(adjustments:)` (`:1122`):

```swift
    /// Which master the staged preview shows. `.clean` is the trail-rejected master when one
    /// is being served; `.online` is the un-rejected running stack. The blink control swaps
    /// between them through the SAME adjustments, so the comparison isolates rejection rather
    /// than confounding it with a stretch difference.
    public enum PreviewSource: Equatable {
        case clean
        case online
    }

    /// Cached preview proxy, keyed on everything that changes the PIXELS — per source.
    ///
    /// `.clean` is keyed on the published master's FreshnessKey, NOT on generation/sub count: a
    /// kappa change, a user reject, a budget change or an enable-state transition each produce a
    /// different clean master while generation and count stay put, so a weaker key would serve a
    /// STALE clean master — and the blink comparison would then be comparing against something
    /// that no longer exists.
    ///
    /// Adjustments are deliberately absent from every case: the proxy is linear and
    /// pre-adjustment, so a slider drag reuses it.
    private enum PreviewProxyKey: Equatable {
        case online(generation: Int, revision: Int)
        case clean(FreshnessKey)
        case watcher(token: Int)
    }
    private let previewProxyLock = NSLock()
    private var previewProxy: (key: PreviewProxyKey, image: AstroImage)?
    /// Test seam: how many times the proxy has actually been rebuilt.
    private(set) var previewProxyBuildCountForTest = 0

    /// Monotonic stack revision for the preview cache key. `processedCount` (`:164`) is a
    /// private var mutated on the consume task (`:890`, `:970`), so reading it from a preview
    /// render — which runs on a detached task — would be a data race. Bump this under the lock
    /// at ALL THREE places `processedCount` is incremented (`:890`, `:970`, and `:1164` — the
    /// native live path; missing that one freezes a live session's preview).
    private let previewRevLock = NSLock()
    private var previewStackRevision = 0
    private func bumpPreviewStackRevision() {
        previewRevLock.lock(); previewStackRevision += 1; previewRevLock.unlock()
    }
    private var currentPreviewStackRevision: Int {
        previewRevLock.lock(); defer { previewRevLock.unlock() }; return previewStackRevision
    }

    /// The most recent rendered linear image, ALREADY downsampled to `previewLongEdge`, with the
    /// monotonic token it was retained under. Watcher / external-stacker mode (init at `:768`) has NO
    /// engine — it loads and renders each incoming file (`:1276`) — so without this the preview
    /// would be permanently blank there, even though display adjustments apply exactly as they
    /// do natively. Retaining the DOWNSAMPLED image costs ~1 MP, not 26 MP.
    /// Keyed by a monotonic TOKEN, not the file digest: `StackUpdate.identity` is
    /// `FileIdentity?` and `FileIdentity.digest` is `String?` (`StackFileWatcher.swift:150,14`),
    /// so a digest key would need a double unwrap and a fallback for the nil case. A token is
    /// always correct and costs nothing here — the retained image is already downsampled at
    /// ingest, so "rebuilding" the proxy is just handing back the stored image.
    private let lastPreviewLock = NSLock()
    private var watcherFrameToken = 0
    private var lastPreviewLinear: (token: Int, image: AstroImage)?
    func noteWatcherFrame(_ linear: AstroImage) {
        let small = linear.downsampled(maxLongEdge: Self.previewLongEdge)
        lastPreviewLock.lock()
        watcherFrameToken += 1
        lastPreviewLinear = (watcherFrameToken, small)
        lastPreviewLock.unlock()
    }

    /// Renders the staged preview WITHOUT touching committed state — the property
    /// `renderCurrentDisplay(adjustments:)` deliberately does not have (it commits, and is
    /// retained for the Apply path). Returns nil when the requested source has nothing to
    /// show: no stack yet, or `.clean` with no published master.
    public func renderPreview(source: PreviewSource,
                              adjustments: DisplayAdjustments) -> CGImage? {
        // Resolve the cache key FIRST — it decides what may be reused, and for `.clean` it is
        // the FreshnessKey of the master actually being served.
        let key: PreviewProxyKey
        switch source {
        case .clean:
            guard let publishedKey = publishedMasterFreshnessKeyIfCurrent() else { return nil }
            key = .clean(publishedKey)
        case .online:
            if let engine {
                key = .online(generation: engine.currentStackGeneration,
                              revision: currentPreviewStackRevision)
            } else {
                lastPreviewLock.lock()
                let token = lastPreviewLinear?.token
                lastPreviewLock.unlock()
                guard let token else { return nil }       // watcher mode, no frame yet
                key = .watcher(token: token)
            }
        }
        var proxy: AstroImage?
        previewProxyLock.lock()
        if let cached = previewProxy, cached.key == key { proxy = cached.image }
        previewProxyLock.unlock()

        if proxy == nil {
            let built: AstroImage
            switch source {
            case .online:
                if let engine, let (mean, coverage) = engine.currentStackAndCoverage() {
                    built = cropToCoverage(mean, coverage: coverage)
                        .downsampled(maxLongEdge: Self.previewLongEdge)
                } else {
                    // Watcher / external-stacker mode: already downsampled at ingest.
                    lastPreviewLock.lock()
                    let cached = lastPreviewLinear?.image
                    lastPreviewLock.unlock()
                    guard let cached else { return nil }
                    built = cached
                }
            case .clean:
                guard let published = publishedMasterIfCurrent() else { return nil }
                built = cropToCoverage(published.image, coverage: published.coverage)
                    .downsampled(maxLongEdge: Self.previewLongEdge)
            }
            previewProxyLock.lock()
            previewProxy = (key, built)
            previewProxyBuildCountForTest += 1
            previewProxyLock.unlock()
            proxy = built
        }
        guard let proxy else { return nil }
        return try? displayCGImage(from: proxy, adjustments: adjustments)
    }
```

- [ ] **Step 3b: Add the FreshnessKey accessor and wire the two counters**

`renderPreview` above calls `publishedMasterFreshnessKeyIfCurrent()`. Add it beside
`publishedMasterSurvivorCount()`, following the same lock discipline:

```swift
    /// The FreshnessKey of the clean master currently being SERVED, or nil if none is. The
    /// preview proxy cache keys `.clean` on this so a kappa change or a user reject invalidates
    /// it — generation and sub count would both miss those.
    func publishedMasterFreshnessKeyIfCurrent() -> FreshnessKey? {
        regLock.withLock {
            guard liveRejectionActive, let pm = publishedMaster,
                  pm.key.isServable(against: _freshnessKey) else { return nil }
            return pm.key
        }
    }
```

Then wire the two invalidation sources:

- Call `bumpPreviewStackRevision()` immediately after EACH `processedCount += 1`. There are
  **THREE** sites, not two: `SessionPipeline.swift:890`, `:970`, and **`:1164` — the NATIVE LIVE
  path**, which is the primary mode. Miss that one and a live session's preview FREEZES:
  `onUpdate` keeps firing and calling `refreshPreview`, but the key never moves so the cache
  hands back the first proxy forever. Verify with
  `grep -n "processedCount += 1" Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` and
  confirm every hit is followed by the bump.
- In the watcher render path (`:1276`), after `let linear = try ImageLoader.load(...)`, call
  `noteWatcherFrame(linear)` so watcher mode has a preview source at all. (It takes no digest:
  `update.identity` is `FileIdentity?` and `.digest` is `String?`, so a digest key would need a
  double unwrap plus a nil fallback — the monotonic token avoids both.)

- [ ] **Step 4: Run tests**

Run: `swift test --filter PreviewRenderTests`
Expected: all nine PASS.

- [ ] **Step 5: Confirm the committed path is still untouched**

Run: `swift test --filter "DisplayRenderParityTests|NativePipelineTests"`
Expected: PASS, same golden hash.

- [ ] **Step 6: Commit**

```bash
git add Sources/LiveAstroCore/Pipeline/SessionPipeline.swift Tests/LiveAstroCoreTests/PreviewRenderTests.swift
git commit -m "feat: renderPreview renders uncommitted adjustments without mutating state

Renders from a cached downsampled proxy and can select the clean or online
master, so the blink comparison runs both through identical adjustments.

Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j"
```

---

### Task 5: Wire `AppModel` to the staged model

**Files:**
- Modify: `Sources/LiveAstroStudio/AppModel.swift` — `:183` (property), `:531-552` (`applyDisplayAdjustments`), `:408`, `:487`, `:535`, `:784` (call sites)
- Modify: `Tests/LiveAstroCoreTests/AppSourceRegressionTests.swift:45`

**Interfaces:**
- Consumes: `StagedAdjustments` (Task 3), `SessionPipeline.renderPreview(source:adjustments:)` and `PreviewSource` (Task 4)
- Produces (for the view in Task 6): `model.staged: StagedAdjustments`, `model.previewImage: CGImage?`, `model.blinkHeld: Bool`, `model.previewSource: SessionPipeline.PreviewSource`, `model.applyAdjustments()`, `model.revertAdjustments()`, `model.refreshPreview()`

- [ ] **Step 1: Replace the source-text regression test**

`AppSourceRegressionTests.swift:45` greps `AppModel.swift` for the literal `"p.displayAdjustments = displayAdjustments"` — it guards the exact method being restructured, so it would either break or keep passing while the behaviour changed underneath. Replace that one test with a source-text assertion of the NEW invariant, keeping it honest about what it can and cannot check:

```swift
    /// AppModel cannot be unit-tested (LiveAstroStudio is an executableTarget with no test
    /// target, Package.swift:12,18), so this remains a source-text check — but it now guards
    /// the staging invariant instead of a line that no longer exists. The BEHAVIOUR is tested
    /// properly in StagedAdjustmentsTests; this only pins that AppModel pushes the value
    /// apply() returned, rather than pushing pending straight through.
    func testAppModelOnlyPushesCommittedAdjustmentsToThePipeline() throws {
        let appModelURL = root.appendingPathComponent("Sources/LiveAstroStudio/AppModel.swift")
        let appModel = try String(contentsOf: appModelURL, encoding: .utf8)

        XCTAssertTrue(appModel.contains("staged.apply()"),
                      "committing must go through StagedAdjustments.apply()")
        XCTAssertFalse(appModel.contains("pipeline.displayAdjustments = staged.pending"),
                       "pending adjustments must NEVER be pushed to the pipeline — that is the broadcast")
        XCTAssertFalse(appModel.contains("p.displayAdjustments = displayAdjustments"),
                       "the pre-staging direct push must be gone")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter AppSourceRegressionTests`
Expected: FAIL — `staged.apply()` is not in `AppModel.swift` yet.

- [ ] **Step 3: Replace the adjustments property**

At `AppModel.swift:183`, replace:

```swift
    var displayAdjustments = DisplayAdjustments.liveDefault
```

with:

```swift
    /// Committed vs pending display adjustments. Sliders bind to `staged.pending`; only
    /// `applyAdjustments()` promotes it and pushes to the pipeline. See StagedAdjustments.
    var staged = StagedAdjustments(committed: .liveDefault)
    /// The staged preview image (pending adjustments, proxy-sized). Distinct from
    /// `latestImage`, which stays on the COMMITTED render so the main view always shows what
    /// the audience sees.
    var previewImage: CGImage?
    /// True only while the blink control is held down. NOT a stored source: defaulting a
    /// source to `.clean` would blank the preview entirely whenever rejection is off (there
    /// is no published master, so `renderPreview(source: .clean)` returns nil) — which is
    /// every import session. `previewSource` below resolves it instead.
    var blinkHeld = false
```

Update the four other references so they read committed: `:408` and `:784` pass `staged.committed`; `:487` becomes
`staged = StagedAdjustments(committed: SessionSettingsStore.exists(.standard) ? s.displayAdjustments : .liveDefault)`.

- [ ] **Step 4: Replace `applyDisplayAdjustments` with staged behaviour**

Replace the body at `:531-552` with:

```swift
    /// Monotonic stamp for preview render requests. Renders run on detached tasks, so without
    /// it a slow EARLIER render can finish after a newer one and overwrite the preview with a
    /// stale image — visible as the preview snapping back to a setting you already moved past.
    private var previewRenderSeq = 0

    /// Called when a slider changes: re-render the PREVIEW only. Nothing reaches the pipeline
    /// here — that is what makes tuning mid-broadcast safe.
    ///
    /// `force` bypasses the throttle. Slider drags are throttled to ~12 fps because they fire
    /// continuously, but DISCRETE actions (Revert, Reset, blink press/release, a new frame, a
    /// session boundary) must never be silently dropped for landing inside an 80 ms window —
    /// a swallowed blink release would leave the panel showing the online master and quietly
    /// misrepresent what rejection is doing.
    func refreshPreview(force: Bool = false) {
        guard let pipeline else { return }
        let now = Date()
        if !force {
            guard now.timeIntervalSince(lastAdjustmentRender) > 0.08 else { return }
        }
        lastAdjustmentRender = now
        previewRenderSeq &+= 1
        let seq = previewRenderSeq
        let adj = staged.pending
        let source = previewSource
        Task.detached { [weak self] in
            guard let self else { return }
            let cg = pipeline.renderPreview(source: source, adjustments: adj)
            await MainActor.run {
                // Only the newest request may publish; a slower earlier render is discarded.
                guard seq == self.previewRenderSeq else { return }
                self.previewImage = cg
            }
        }
    }

    /// Which master the preview shows. Held → the un-rejected online master. Otherwise the
    /// clean master when one is actually being served, else online — so the panel still shows
    /// a picture when rejection is off, building, or unavailable, rather than going blank.
    var previewSource: SessionPipeline.PreviewSource {
        if blinkHeld { return .online }
        return pipeline?.publishedMasterSurvivorCount() != nil ? .clean : .online
    }

    /// Promotes the pending adjustments to committed: pushes them to the pipeline (so the
    /// broadcast, snapshots, latest.png and replay pick them up), persists them, and refreshes
    /// the main view. This is the ONLY path by which a slider reaches the audience.
    func applyAdjustments() {
        let committed = staged.apply()
        saveSettings()
        guard let pipeline else { return }
        pipeline.displayAdjustments = committed
        Task.detached { [weak self] in
            guard let self else { return }
            let cg = pipeline.renderCurrentDisplay(adjustments: committed)
            await MainActor.run {
                guard let cg else { return }
                self.latestImage = cg
            }
        }
    }

    /// Throws the pending edits away and puts the preview back on the committed look.
    func revertAdjustments() {
        staged.revert()
        refreshPreview(force: true)
    }

    /// Restores the shipped defaults as a PENDING edit — Reset must not reach the broadcast on
    /// its own, or it would be the one control that bypasses staging entirely. Apply commits it
    /// like any other change.
    func resetAdjustments() {
        staged.pending = .liveDefault
        refreshPreview(force: true)
    }

```

`saveSettings()` must persist `staged.committed` — update the settings read/write to use it wherever it referenced `displayAdjustments`.

- [ ] **Step 4d: Add the clean-master-published callback**

In `SessionPipeline.swift`, beside the other callbacks (`onSolveStateChanged` is at `:204`):

```swift
    /// Fired after a refiner pass installs a SERVABLE clean master. The staged preview needs it
    /// because `AppModel.liveRejectionStatus` is computed with no change notification, so there
    /// is no transition to observe: without this the preview would keep showing the online
    /// master after the first clean one publishes.
    public var onCleanMasterPublished: (() -> Void)?
```

Fire it from `publishRefineResult` (`:647`) — OUTSIDE `regLock`, per this file's lock discipline
(callbacks are never delivered while holding it):

```swift
    private func publishRefineResult(_ result: RefineResult, key: FreshnessKey) {
        var published = false
        regLock.withLock {
            guard liveRejectionActive, key.isServable(against: _freshnessKey) else { return }
            publishedMaster = PublishedMaster(image: result.image, coverage: result.coverage,
                                              survivorCount: result.survivorCount, key: key)
            published = true
        }
        if published { onCleanMasterPublished?() }
    }
```

- [ ] **Step 4b: Wire the preview lifecycle (concrete call sites)**

The preview is pinned on screen, so anything that changes what it SHOULD show must refresh it,
or it sits stale — at worst showing the previous session's stack until a control is touched.
These are edits, not guidance; make each one:

1. In the `pipeline.onUpdate` closure (`AppModel.swift:921`), after `self?.latestImage = image`,
   add `self?.refreshPreview(force: true)` — a new sub changed the stack.
2. Wire `pipeline.onCleanMasterPublished` (added in Step 4d) to `refreshPreview(force: true)`
   — with the main-actor hop the other callbacks use (`AppModel.swift:923`), since this one
   fires from the refiner's background pass:

```swift
        pipeline.onCleanMasterPublished = { [weak self] in
            Task { @MainActor in self?.refreshPreview(force: true) }
        }
```

2b. The callback covers the clean master APPEARING. It must also refresh when the clean master
   DISAPPEARS, or the panel keeps showing a clean preview that is no longer being served. Two
   call sites, both in `AppModel`:
   - `toggleReject(index:)` (`AppModel.swift:1071`) — a user reject makes the published master
     unservable immediately, so `previewSource` falls back to `.online`.
   - wherever `configureLiveRejection(enabled:kappa:)` is called (`AppModel.swift:1031`) —
     turning rejection off, or changing kappa, invalidates it the same way.
   Both call `refreshPreview(force: true)` after the change lands.
   `liveRejectionStatus` (`AppModel.swift:998`) is a COMPUTED property with no change
   notification, so there is nothing to observe for a transition into `.active` — without a real
   callback the panel keeps showing the online master until a control is touched.
3. At session start, immediately after the pipeline is assigned: `previewImage = nil` first, then
   `refreshPreview(force: true)` so the panel fills as soon as there is data.
4. At session end (both the normal `end()` path and the error/rollback path): `previewImage = nil`
   and `staged.revert()` — pending edits die with the session, and nothing from a finished
   session lingers on screen.

5. Wire `pipeline.onSolveStateChanged` to `refreshPreview(force: true)`, with the same
   main-actor hop. A MANUAL reseed changes the stack immediately and may not produce another
   accepted frame for a while, so `onUpdate` alone can leave the panel showing the old stack;
   `onSolveStateChanged` already fires on that edge (`SessionPipeline.swift:211`, commented
   "negative edge: reseed/auto-reseed dropped the solve"). The same hook also covers solve
   ARRIVAL (`:265`), which matters because North-up rotation is applied inside `displayCGImage`
   — the preview's orientation changes the moment a solve lands.

```swift
        pipeline.onSolveStateChanged = { [weak self] in
            Task { @MainActor in self?.refreshPreview(force: true) }
        }
```

Note this REPLACES the earlier claim that "a reseed needs no separate hook because onUpdate
covers it" — it does not, when no frame follows the reseed promptly.

- [ ] **Step 4c: Verify the lifecycle by hand**

`AppModel` has no test target, so these four are verified by running the app — do it, and record
the result in the task report rather than assuming:

- Start a session; the preview fills without touching a control.
- Let a sub land; the preview updates on its own.
- Turn live rejection on and wait for the first clean master; the preview switches to clean and
  the blink control becomes enabled.
- End the session; the preview clears and does not show the previous session's stack.

- [ ] **Step 5: Run the regression test and build the app target**

Run: `swift test --filter AppSourceRegressionTests`
Expected: PASS.

Run: `swift build`
Expected: builds clean. Fix any remaining `displayAdjustments` references on `AppModel` the compiler reports.

- [ ] **Step 6: Commit**

```bash
git add Sources/LiveAstroStudio/AppModel.swift \
        Sources/LiveAstroCore/Pipeline/SessionPipeline.swift \
        Tests/LiveAstroCoreTests/AppSourceRegressionTests.swift
git commit -m "feat: AppModel stages display adjustments instead of pushing every tick

Sliders now move staged.pending and re-render the preview only; applyAdjustments()
is the sole path to the pipeline. Replaces the source-text test that guarded the
line this restructures.

Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j"
```

---

### Task 6: The preview panel UI

**Files:**
- Modify: `Sources/LiveAstroStudio/DisplaySettingsView.swift` (pin preview above the `ScrollView`, rebind sliders)

**Interfaces:**
- Consumes: `model.staged`, `model.previewImage`, `model.blinkHeld`, `model.applyAdjustments()`, `model.revertAdjustments()`, `model.refreshPreview()`, `model.liveRejectionStatus`

- [ ] **Step 1: Rebind every Display Adjustments control to `staged.pending`**

In `DisplaySettingsView.swift`, the `Section("Display Adjustments")` controls currently bind to `$model.displayAdjustments.*` (lines 31, 38, 45, 50, 58, 67, 77, 84). Rebind each to `$model.staged.pending.*`, and change each `onEditingChanged`/`onChange` handler to call `model.refreshPreview()` instead of `model.applyDisplayAdjustments()`. The `Section("Night vision")` controls are unrelated and must NOT change.

The **Reset button** at `DisplaySettingsView.swift:108` must also be rebound — it is the one
control that would otherwise still write straight through. Its action becomes:

```swift
                    Button("Reset") { model.resetAdjustments() }
```

`resetAdjustments()` sets `staged.pending = .liveDefault` and force-refreshes the preview, so
Reset behaves like every other edit: staged, visible in the preview, and committed only by
Apply. Leaving it as an immediate write would make Reset the single slider that publishes to the
broadcast without asking.

- [ ] **Step 2: Pin the preview above the scrolling form**

Wrap the existing body so the preview stays visible while the sliders scroll — the DBE and denoise controls are far down the form and would otherwise push it off-screen exactly when in use:

```swift
    var body: some View {
        VStack(spacing: 0) {
            previewPanel
                .padding(.horizontal).padding(.top)
            Divider().padding(.top, 8)
            ScrollView {
                Form {
                    // ... existing Night vision + Display Adjustments sections, unchanged
                }
            }
        }
    }

    @ViewBuilder private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if let cg = model.previewImage {
                    Image(decorative: cg, scale: 1)
                        .resizable().aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                        .overlay(Text("No stack yet").font(.caption).foregroundStyle(.secondary))
                }
            }
            .frame(maxHeight: 260)
            .overlay(alignment: .topLeading) {
                if model.staged.hasPendingChanges {
                    Text("Pending — not yet on the broadcast")
                        .font(.caption2).padding(4)
                        .background(.yellow.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }
            }

            HStack {
                blinkButton
                Spacer()
                Button("Revert") { model.revertAdjustments() }
                    .disabled(!model.staged.hasPendingChanges)
                Button("Apply") { model.applyAdjustments() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.staged.hasPendingChanges)
            }
        }
    }
```

- [ ] **Step 3: Add the hold-to-compare control with an honest disabled state**

The blink button reuses `LiveRejectionStatus` (shipped in v3.6.0) so a disabled control explains itself rather than being mysteriously grey:

```swift
    @ViewBuilder private var blinkButton: some View {
        let status = model.liveRejectionStatus
        let (enabled, label): (Bool, String) = {
            switch status {
            case .active(let subs): return (true, "Hold to compare (clean, \(subs) subs)")
            case .building(let subs): return (false, "Building over \(subs) subs…")
            case .off(let reason): return (false, "Comparison unavailable — \(reason)")
            }
        }()
        Text(label)
            .font(.caption)
            .padding(.vertical, 4).padding(.horizontal, 8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            .opacity(enabled ? 1 : 0.5)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard enabled, !model.blinkHeld else { return }
                        model.blinkHeld = true               // held: show the UN-rejected master
                        model.refreshPreview(force: true)     // discrete action — never throttle it away
                    }
                    .onEnded { _ in
                        guard enabled else { return }
                        model.blinkHeld = false              // released: back to the clean one
                        model.refreshPreview(force: true)     // a swallowed release would strand the panel on online
                    }
            )
            .help("Hold to see the same stretch WITHOUT trail rejection, so the difference is rejection alone.")
    }
```

- [ ] **Step 4: Build and smoke the app**

Run: `swift build`
Expected: builds clean.

Run: `swift run LiveAstroStudio` (or launch the built `.app`), start an import or live session, and confirm by hand: sliders move the preview only; the main view does not change until Apply; the pending badge appears and clears; Revert restores; the blink control is disabled with a reason when rejection is off.

- [ ] **Step 5: Full suite**

Run: `swift test 2>&1 | tail -5`
Expected: `Test Suite 'All tests' passed`, 0 failures. Baseline was 1217 tests at v3.6.1; this plan adds roughly 17.

- [ ] **Step 6: Commit**

```bash
git add Sources/LiveAstroStudio/DisplaySettingsView.swift
git commit -m "feat: preview panel with Apply/Revert and hold-to-compare

Preview pinned above the scrolling form so it stays visible while the DBE and
denoise sliders are used. Blink control reuses LiveRejectionStatus so a disabled
state explains itself.

Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j"
```

---

## Notes for the executor

- **Task 1 is the risky one.** It touches the path producing `master.fit` and the broadcast. Do not proceed past Step 6 unless the golden hash is unchanged.
- **Do not "improve" the preview into a 1:1 crop.** The spec explains at length why a crop misrepresents both `AutoStretch` (statistics-derived) and DBE (dimension-relative radius). That is a deliberate exclusion, not an oversight.
- **`renderCurrentDisplay(adjustments:)` keeps its committing side effect.** It is now the Apply path only. Do not "clean it up" to match `renderPreview`.
- **`AstroImage` is planar (channel-major).** `c * plane + y * width + x`. An earlier draft of
  this plan used interleaved indexing in BOTH the implementation and its test helper, so the
  tests would have passed while colour was scrambled. `PreviewTestSupport` and the colour-plane
  sentinel in Task 2 exist to make that impossible to reintroduce.
- **Do not reimplement the downsample.** `AstroImage.downsampled(maxLongEdge:)` already exists,
  is planar-correct and area-averaging, and is already used by the render path. An earlier draft
  of this plan rewrote it from scratch.
- **Every discrete preview action forces past the throttle.** Revert, Reset, blink press and
  release, new frames and session boundaries all call `refreshPreview(force: true)`; only
  continuous slider drags are throttled.
