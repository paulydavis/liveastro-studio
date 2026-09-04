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
- Proxy: longest edge **1200 px**, integer **box-average** downsample; a stack already ≤1200 px on its long edge is used as-is.
- Proxy cache key: `(stack generation, processed sub count, source selector)`. Adjustments are deliberately NOT in the key — the proxy is linear and pre-adjustment.
- Preview honesty bound: derived median and MADN within **2% relative** of the full frame, measured on a non-uniform (star-field) image.
- Full test suite green before merge. Baseline at v3.6.1 is 1217 tests / 8 skipped / 0 failures.

---

### Task 1: Make `displayCGImage` a pure function of (image, adjustments)

**Files:**
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift:1074` (signature) and call sites at `:929`, `:941`, `:1121`, `:1233`, `:1276`
- Test: `Tests/LiveAstroCoreTests/DisplayRenderParityTests.swift` (create)

**Interfaces:**
- Produces: `private func displayCGImage(from linear: AstroImage, adjustments adj: DisplayAdjustments) throws -> CGImage`
- Produces (test seam): `func renderForTest(_ image: AstroImage, adjustments: DisplayAdjustments) throws -> CGImage`

- [ ] **Step 1: Write the characterization test with a placeholder hash**

Create `Tests/LiveAstroCoreTests/DisplayRenderParityTests.swift`:

```swift
import XCTest
import CryptoKit
@testable import LiveAstroCore

/// The render path behind this test produces the broadcast, snapshots, latest.png and
/// master.fit. A regression here is SILENT — it lands in recorded data, not in a crash — so
/// the committed-path output is pinned by hash across the refactor that parameterises it.
final class DisplayRenderParityTests: XCTestCase {

    /// Non-uniform test image: a constant frame would make every statistic survive any
    /// transformation, so this test (and the proxy test in Task 2) would pass vacuously.
    static func starField(w: Int = 320, h: Int = 240) -> AstroImage {
        var px = [Float](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let bg = 0.04 + 0.02 * Float(x) / Float(w)      // gradient, so DBE has work
                for c in 0..<3 { px[(y * w + x) * 3 + c] = bg + Float((x &* 7 &+ y &* 13) % 11) * 0.0008 }
            }
        }
        for (sx, sy, amp) in [(70, 60, Float(0.8)), (180, 150, 0.5), (250, 80, 0.65)] {
            for dy in -6...6 {
                for dx in -6...6 {
                    let x = sx + dx, y = sy + dy
                    guard x >= 0, x < w, y >= 0, y < h else { continue }
                    let g = amp * exp(-Float(dx * dx + dy * dy) / 8.0)
                    for c in 0..<3 { px[(y * w + x) * 3 + c] += g }
                }
            }
        }
        return AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
    }

    static func sha256(_ cg: CGImage) -> String {
        guard let data = cg.dataProvider?.data as Data? else { return "no-data" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

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
        let cg = try pipeline.renderForTest(Self.starField(), adjustments: Self.pinnedAdjustments)
        XCTAssertEqual(Self.sha256(cg), "PLACEHOLDER_FILL_IN_STEP_2",
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

    /// Test seam: a pipeline with no source/engine, usable only for render-path tests.
    static func forRenderTest() -> SessionPipeline {
        SessionPipeline(nativeSource: nil, engine: StackEngine(),
                        profile: SessionProfile(targetName: "RenderTest", telescope: "T", camera: "C",
                                                mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                                subExposureSeconds: 1, notes: ""),
                        rootDirectory: FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString, isDirectory: true))
    }
```

If `SessionPipeline.init` will not accept a nil source, use the smallest existing construction pattern from `Tests/LiveAstroCoreTests/GlobalRefinerTests.swift` (`StubLiveSource(sequence: [])`) instead — the point is a pipeline whose render path can be called, not a running session.

Run: `swift test --filter DisplayRenderParityTests 2>&1 | grep -E "XCTAssertEqual failed|passed"`
Expected: FAIL, reporting the ACTUAL hash. Copy that hash into `PLACEHOLDER_FILL_IN_STEP_2`.

- [ ] **Step 3: Re-run to confirm the golden is now green on unmodified code**

Run: `swift test --filter DisplayRenderParityTests`
Expected: PASS. This is the pre-refactor baseline — the test is now guarding real behaviour.

- [ ] **Step 4: Commit the baseline before touching the render path**

```bash
git add Tests/LiveAstroCoreTests/DisplayRenderParityTests.swift Sources/LiveAstroCore/Pipeline/SessionPipeline.swift
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

### Task 2: `PreviewProxy` — the downsample the preview renders from

**Files:**
- Create: `Sources/LiveAstroCore/Imaging/PreviewProxy.swift`
- Test: `Tests/LiveAstroCoreTests/PreviewProxyTests.swift` (create)

**Interfaces:**
- Produces: `public enum PreviewProxy { public static let longestEdge = 1200; public static func downsample(_ image: AstroImage) -> AstroImage }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LiveAstroCoreTests/PreviewProxyTests.swift`:

```swift
import XCTest
@testable import LiveAstroCore

final class PreviewProxyTests: XCTestCase {

    /// THE test this design rests on. The preview renders from a downsample, but AutoStretch
    /// derives its transform from the image's OWN median/MADN (AutoStretch.swift:47-57) — so if
    /// downsampling shifted those statistics, the preview would show a different stretch than
    /// the broadcast and would be lying to the operator. Measured on a NON-UNIFORM image: on a
    /// constant frame every statistic survives any sampling and this test would prove nothing.
    func testDownsamplePreservesTheStatisticsAutoStretchDerives() {
        let full = DisplayRenderParityTests.starField(w: 2400, h: 1800)
        let proxy = PreviewProxy.downsample(full)

        let (mFull, dFull) = Self.medianAndMADN(full)
        let (mProxy, dProxy) = Self.medianAndMADN(proxy)

        XCTAssertEqual(mProxy, mFull, accuracy: abs(mFull) * 0.02,
                       "median must survive the proxy downsample within 2% — the stretch is derived from it")
        XCTAssertEqual(dProxy, dFull, accuracy: abs(dFull) * 0.02,
                       "MADN must survive the proxy downsample within 2% — it sets the stretch slope")
    }

    func testDownsampleTargetsTheLongestEdge() {
        let landscape = PreviewProxy.downsample(DisplayRenderParityTests.starField(w: 2400, h: 1800))
        XCTAssertEqual(max(landscape.width, landscape.height), 1200)
        XCTAssertEqual(landscape.width, 1200)
        XCTAssertEqual(landscape.height, 900, "aspect ratio must be preserved by an integer factor")
    }

    /// A small stack must pass through untouched — downsampling it would throw away real
    /// resolution for no speed benefit.
    func testImageAlreadyWithinBudgetIsReturnedUnchanged() {
        let small = DisplayRenderParityTests.starField(w: 800, h: 600)
        let out = PreviewProxy.downsample(small)
        XCTAssertEqual(out.width, 800)
        XCTAssertEqual(out.height, 600)
        XCTAssertEqual(out.pixels, small.pixels)
    }

    /// Box-average, not nearest-neighbour: a 2x2 block of known values must average.
    func testDownsampleBoxAveragesRatherThanSampling() {
        let w = 2400, h = 1800
        var px = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { px[i] = (i % 2 == 0) ? 0.0 : 1.0 }   // checkerboard by index
        let img = AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true)
        let out = PreviewProxy.downsample(img)
        let mean = out.pixels.reduce(0, +) / Float(out.pixels.count)
        XCTAssertEqual(mean, 0.5, accuracy: 0.02,
                       "box-averaging a 50/50 pattern yields ~0.5; nearest-neighbour would yield 0 or 1")
    }

    static func medianAndMADN(_ image: AstroImage) -> (Double, Double) {
        let c = image.channels
        var lum = [Float]()
        lum.reserveCapacity(image.width * image.height)
        for p in stride(from: 0, to: image.pixels.count, by: c) {
            var s: Float = 0
            for k in 0..<c { s += image.pixels[p + k] }
            lum.append(s / Float(c))
        }
        lum.sort()
        let med = Double(lum[lum.count / 2])
        var dev = lum.map { abs(Double($0) - med) }
        dev.sort()
        return (med, dev[dev.count / 2] * 1.4826)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter PreviewProxyTests`
Expected: FAIL — "cannot find 'PreviewProxy' in scope".

- [ ] **Step 3: Implement `PreviewProxy`**

Create `Sources/LiveAstroCore/Imaging/PreviewProxy.swift`:

```swift
import Foundation

/// The linear image the staged preview renders from.
///
/// The preview must be FAST (a slider drag must not re-render a 26 MP stack) and HONEST (it
/// must show the stretch the broadcast will get). Those pull in opposite directions, and the
/// resolution is why the preview is a whole-frame downsample rather than a 1:1 crop:
///
/// - `AutoStretch` derives its transform from the image's own median and MADN
///   (`AutoStretch.swift:47-57`). A CROP's statistics differ from the full frame, so a crop
///   would render a different stretch than the broadcast. A uniform downsample preserves them.
/// - `BackgroundExtraction.flattenMultiscale` uses `scaleRadius = (scale/100) * max(sw, sh)`
///   (`BackgroundExtraction.swift:281`) — DBE's scale is RELATIVE to image dimensions, so a
///   crop changes the physical radius while a downsample preserves it proportionally.
///
/// Box-averaging (not nearest-neighbour sampling) is what keeps the statistics faithful;
/// `PreviewProxyTests` pins both properties.
public enum PreviewProxy {
    /// Target for the longest edge. A 26 MP 6236x4159 stack lands at 1200x800 (factor 5).
    public static let longestEdge = 1200

    public static func downsample(_ image: AstroImage) -> AstroImage {
        let longest = max(image.width, image.height)
        guard longest > longestEdge else { return image }
        let factor = max(2, Int((Double(longest) / Double(longestEdge)).rounded(.up)))
        let outW = image.width / factor, outH = image.height / factor
        guard outW >= 1, outH >= 1 else { return image }

        let c = image.channels
        var out = [Float](repeating: 0, count: outW * outH * c)
        let inv = Float(factor * factor)
        image.pixels.withUnsafeBufferPointer { src in
            for oy in 0..<outH {
                for ox in 0..<outW {
                    for k in 0..<c {
                        var sum: Float = 0
                        for by in 0..<factor {
                            let row = (oy * factor + by) * image.width
                            for bx in 0..<factor {
                                sum += src[(row + ox * factor + bx) * c + k]
                            }
                        }
                        out[(oy * outW + ox) * c + k] = sum / inv
                    }
                }
            }
        }
        return AstroImage(width: outW, height: outH, channels: c, pixels: out,
                          sourceIsLinear: image.sourceIsLinear)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter PreviewProxyTests`
Expected: all four PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Imaging/PreviewProxy.swift Tests/LiveAstroCoreTests/PreviewProxyTests.swift
git commit -m "feat: PreviewProxy box-average downsample for the staged preview

Preserves the median/MADN AutoStretch derives its transform from, and DBE's
dimension-relative radius — the two properties a 1:1 crop would have broken.

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
- Consumes: `PreviewProxy.downsample(_:)` (Task 2), `displayCGImage(from:adjustments:)` (Task 1)
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
        XCTAssertNotEqual(DisplayRenderParityTests.sha256(a), DisplayRenderParityTests.sha256(b),
                          "different adjustments must produce a different preview")
    }

    /// The preview renders from the proxy, so it is bounded by PreviewProxy.longestEdge.
    func testPreviewIsRenderedFromTheDownsampledProxy() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (pipeline, source) = try PreviewRenderTests.runningPipeline(sandbox: sandbox)
        defer { source.stop() }

        let cg = try XCTUnwrap(pipeline.renderPreview(source: .online, adjustments: .neutral))
        XCTAssertLessThanOrEqual(max(cg.width, cg.height), PreviewProxy.longestEdge)
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

    /// Reuses the established live-pipeline harness. Mirrors
    /// `GlobalRefinerTests.pipelineWithRegisteredSubs`; if that helper is made internal,
    /// call it directly instead of duplicating.
    static func runningPipeline(sandbox: URL) throws -> (SessionPipeline, StubLiveSource) {
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let profile = SessionProfile(targetName: "Preview", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let engine = StackEngine()
        let frames = (0..<3).map { i in
            RawFrame(image: DisplayRenderParityTests.starField(w: 2400, h: 1800),
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

If `StubLiveSource` is `private` to `GlobalRefinerTests`, promote it to an internal helper file `Tests/LiveAstroCoreTests/StubLiveSource.swift` in this step rather than duplicating it.

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
    public enum PreviewSource {
        case clean
        case online
    }

    /// Renders the staged preview WITHOUT touching committed state — the property
    /// `renderCurrentDisplay(adjustments:)` deliberately does not have (it commits, and is
    /// retained for the Apply path). Renders from `PreviewProxy` so a slider drag re-renders a
    /// ~1200 px image rather than a 26 MP stack. Returns nil when the requested source has
    /// nothing to show: no stack yet, or `.clean` with no published master.
    public func renderPreview(source: PreviewSource,
                              adjustments: DisplayAdjustments) -> CGImage? {
        let linear: AstroImage
        switch source {
        case .online:
            guard let (mean, coverage) = engine?.currentStackAndCoverage() else { return nil }
            linear = cropToCoverage(mean, coverage: coverage)
        case .clean:
            guard let published = publishedMasterIfCurrent() else { return nil }
            linear = cropToCoverage(published.image, coverage: published.coverage)
        }
        return try? displayCGImage(from: PreviewProxy.downsample(linear), adjustments: adjustments)
    }
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter PreviewRenderTests`
Expected: all four PASS.

- [ ] **Step 5: Confirm the committed path is still untouched**

Run: `swift test --filter "DisplayRenderParityTests|NativePipelineTests"`
Expected: PASS, same golden hash.

- [ ] **Step 6: Commit**

```bash
git add Sources/LiveAstroCore/Pipeline/SessionPipeline.swift Tests/LiveAstroCoreTests/PreviewRenderTests.swift
git commit -m "feat: renderPreview renders uncommitted adjustments without mutating state

Renders from the PreviewProxy downsample and can select the clean or online
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
    /// Called when a slider changes: re-render the PREVIEW only. Nothing reaches the pipeline
    /// here — that is what makes tuning mid-broadcast safe. Throttled to ~12 fps; the render
    /// is off-main and works on the proxy, so it is cheap even at 26 MP.
    func refreshPreview() {
        guard let pipeline else { return }
        let adj = staged.pending
        let source = previewSource
        let now = Date()
        guard now.timeIntervalSince(lastAdjustmentRender) > 0.08 else { return }
        lastAdjustmentRender = now
        Task.detached { [weak self] in
            guard let self else { return }
            let cg = pipeline.renderPreview(source: source, adjustments: adj)
            await MainActor.run { self.previewImage = cg }
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
        refreshPreview()
    }
```

`saveSettings()` must persist `staged.committed` — update the settings read/write to use it wherever it referenced `displayAdjustments`.

- [ ] **Step 5: Run the regression test and build the app target**

Run: `swift test --filter AppSourceRegressionTests`
Expected: PASS.

Run: `swift build`
Expected: builds clean. Fix any remaining `displayAdjustments` references on `AppModel` the compiler reports.

- [ ] **Step 6: Commit**

```bash
git add Sources/LiveAstroStudio/AppModel.swift Tests/LiveAstroCoreTests/AppSourceRegressionTests.swift
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
                        model.refreshPreview()
                    }
                    .onEnded { _ in
                        guard enabled else { return }
                        model.blinkHeld = false              // released: back to the clean one
                        model.refreshPreview()
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
