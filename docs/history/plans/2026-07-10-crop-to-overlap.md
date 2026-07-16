# Crop-to-Overlap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-crop the exported `master.fit` to the fully-covered region (removing ragged partial-coverage edges from dither/drift), improving every downstream processing pass — without touching the stack, live view, or replay.

**Architecture:** The per-pixel coverage map already exists as `StackAccumulator.weight` (binary Warp masks → `weight[i]` = frames covering pixel i). A read-only accessor exposes it; a pure function computes the inscribed rectangle of the well-covered region; `AstroImage` gains a rectangular crop; the session finalize path crops a copy of the master (with a safety guard) before the existing additive-balance + FITS write.

**Tech Stack:** Swift 5.10, macOS 14+, LiveAstroCore (Foundation only, zero external deps), XCTest.

## Global Constraints

- Swift 5.10, macOS 14+. LiveAstroCore uses **Foundation only** — zero external dependencies.
- Core tests run via `swift test --filter LiveAstroCoreTests`.
- `StackAccumulator` **accumulation math stays byte-identical** — this pillar adds ONLY a read-only `coverage()` accessor returning a copy; a test asserts `mean()` output is unchanged.
- Crop is an **output-stage op on a COPY of the master** — the accumulator, live display, `replay.mp4`, and snapshot PNGs are NEVER cropped.
- Crop shape is a **rectangular inscribed bounding box**.
- Coverage threshold: a pixel is well-covered iff `coverage[i] >= wellCoveredFraction * peak` with `wellCoveredFraction = 0.9`; edges trimmed while per-line well-covered fraction `< edgeFloor = 0.5`. These are named constants (defaulted parameters).
- **Always-on** with a safety guard: skip the crop (write full master) when coverage is nil, the rect is nil, the rect equals the full frame, or the cropped area would be `< 0.6 ×` the full area. No user-facing setting.
- Crop happens **before** the additive-balance. Cropped `width`/`height` flow into FITS `NAXIS1/2` automatically (no `FITSWriter` change).
- `CropRect` bounds are **inclusive** (`x0…x1`, `y0…y1`).
- TDD throughout; frequent commits.

---

### Task 1: `CropRect` + `AstroImage.cropped(to:)`

**Files:**
- Create: `Sources/LiveAstroCore/Stacking/CoverageCrop.swift`
- Modify: `Sources/LiveAstroCore/Imaging/AstroImage.swift` (add `cropped(to:)`)
- Test: `Tests/LiveAstroCoreTests/AstroImageCropTests.swift`

**Interfaces:**
- Consumes: `AstroImage(width:height:channels:pixels:sourceIsLinear:)` (existing; planar row-major pixels, per-channel plane = `width*height`, layout `pixels[c*plane + y*width + x]`).
- Produces: `public struct CropRect: Equatable { public let x0, y0, x1, y1: Int; public init(x0:Int,y0:Int,x1:Int,y1:Int) }` (inclusive bounds) in `CoverageCrop.swift`; `public func cropped(to rect: CropRect) -> AstroImage` on `AstroImage`. (Task 2 adds `CoverageCrop.rect` to the same `CoverageCrop.swift`.)

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class AstroImageCropTests: XCTestCase {
    func testCropMonoInteriorRect() {
        // 4x4 mono, pixel value = y*10 + x
        var px = [Float](repeating: 0, count: 16)
        for y in 0..<4 { for x in 0..<4 { px[y*4 + x] = Float(y*10 + x) } }
        let img = AstroImage(width: 4, height: 4, channels: 1, pixels: px, sourceIsLinear: true)
        // crop to columns 1..2, rows 1..2 (inclusive) => 2x2
        let out = img.cropped(to: CropRect(x0: 1, y0: 1, x1: 2, y1: 2))
        XCTAssertEqual(out.width, 2); XCTAssertEqual(out.height, 2); XCTAssertEqual(out.channels, 1)
        XCTAssertEqual(out.pixels, [11, 12, 21, 22])
        XCTAssertEqual(out.sourceIsLinear, true)
    }

    func testCropRGBKeepsChannelsSeparate() {
        // 2x2, 3 channels; plane=4. channel c fills value = c*100 + (y*2+x)
        let plane = 4
        var px = [Float](repeating: 0, count: plane * 3)
        for c in 0..<3 { for y in 0..<2 { for x in 0..<2 {
            px[c*plane + y*2 + x] = Float(c*100 + y*2 + x)
        }}}
        let img = AstroImage(width: 2, height: 2, channels: 3, pixels: px, sourceIsLinear: false)
        // crop to the single pixel (1,1)
        let out = img.cropped(to: CropRect(x0: 1, y0: 1, x1: 1, y1: 1))
        XCTAssertEqual(out.width, 1); XCTAssertEqual(out.height, 1); XCTAssertEqual(out.channels, 3)
        // pixel (1,1) per channel: c*100 + 3
        XCTAssertEqual(out.pixels, [3, 103, 203])
    }

    func testFullFrameCropIsIdentity() {
        let px: [Float] = (0..<9).map { Float($0) }
        let img = AstroImage(width: 3, height: 3, channels: 1, pixels: px, sourceIsLinear: true)
        let out = img.cropped(to: CropRect(x0: 0, y0: 0, x1: 2, y1: 2))
        XCTAssertEqual(out.width, 3); XCTAssertEqual(out.height, 3)
        XCTAssertEqual(out.pixels, px)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AstroImageCropTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'CropRect' in scope` / no `cropped` member.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/LiveAstroCore/Stacking/CoverageCrop.swift`:

```swift
import Foundation

/// Inclusive pixel bounds of a rectangular crop region.
public struct CropRect: Equatable {
    public let x0: Int, y0: Int, x1: Int, y1: Int
    public init(x0: Int, y0: Int, x1: Int, y1: Int) {
        self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1
    }
    public var width: Int { x1 - x0 + 1 }
    public var height: Int { y1 - y0 + 1 }
}
```

Add to `Sources/LiveAstroCore/Imaging/AstroImage.swift` (inside `AstroImage`):

```swift
    /// Rectangular sub-region copy (per channel). `rect` bounds are inclusive
    /// and must lie within the image.
    public func cropped(to rect: CropRect) -> AstroImage {
        precondition(rect.x0 >= 0 && rect.y0 >= 0 && rect.x1 < width && rect.y1 < height && rect.x0 <= rect.x1 && rect.y0 <= rect.y1)
        let nw = rect.width, nh = rect.height
        let srcPlane = width * height
        let dstPlane = nw * nh
        var out = [Float](repeating: 0, count: dstPlane * channels)
        for c in 0..<channels {
            for y in 0..<nh {
                let srcRow = (rect.y0 + y) * width + rect.x0
                let dstRow = c * dstPlane + y * nw
                for x in 0..<nw {
                    out[dstRow + x] = pixels[c * srcPlane + srcRow + x]
                }
            }
        }
        return AstroImage(width: nw, height: nh, channels: channels, pixels: out, sourceIsLinear: sourceIsLinear)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AstroImageCropTests 2>&1 | tail -5`
Expected: PASS — 3 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Stacking/CoverageCrop.swift Sources/LiveAstroCore/Imaging/AstroImage.swift Tests/LiveAstroCoreTests/AstroImageCropTests.swift
git commit -m "feat: CropRect + AstroImage.cropped(to:)"
```

---

### Task 2: `CoverageCrop.rect` — inscribed rectangle of the covered region

**Files:**
- Modify: `Sources/LiveAstroCore/Stacking/CoverageCrop.swift` (add the `CoverageCrop` enum)
- Test: `Tests/LiveAstroCoreTests/CoverageCropTests.swift`

**Interfaces:**
- Consumes: `CropRect` (Task 1).
- Produces: `public enum CoverageCrop { public static func rect(coverage: [Float], width: Int, height: Int, wellCoveredFraction: Float = 0.9, edgeFloor: Float = 0.5) -> CropRect? }`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class CoverageCropTests: XCTestCase {
    // Build a width×height coverage map from a closure.
    private func cov(_ w: Int, _ h: Int, _ f: (Int, Int) -> Float) -> [Float] {
        var a = [Float](repeating: 0, count: w*h)
        for y in 0..<h { for x in 0..<w { a[y*w + x] = f(x, y) } }
        return a
    }

    func testCenteredCoreYieldsInnerRect() {
        // 10x10: coverage 10 in the inner 2..7 box, 1 (low) at the border.
        let w = 10, h = 10
        let c = cov(w, h) { x, y in (x >= 2 && x <= 7 && y >= 2 && y <= 7) ? 10 : 1 }
        let r = CoverageCrop.rect(coverage: c, width: w, height: h)
        XCTAssertEqual(r, CropRect(x0: 2, y0: 2, x1: 7, y1: 7))
    }

    func testUniformCoverageIsFullFrame() {
        let w = 6, h = 5
        let c = cov(w, h) { _, _ in 8 }
        XCTAssertEqual(CoverageCrop.rect(coverage: c, width: w, height: h),
                       CropRect(x0: 0, y0: 0, x1: w-1, y1: h-1))
    }

    func testTaperedCornerExcludesLowCoverageEdges() {
        // left/top few columns/rows are under-covered; inscribed rect starts inside them.
        let w = 12, h = 12
        let c = cov(w, h) { x, y in (x >= 3 && y >= 2) ? 20 : 1 }
        let r = CoverageCrop.rect(coverage: c, width: w, height: h)!
        XCTAssertEqual(r.x0, 3); XCTAssertEqual(r.y0, 2)
        XCTAssertEqual(r.x1, 11); XCTAssertEqual(r.y1, 11)
    }

    func testAllZeroCoverageReturnsNil() {
        XCTAssertNil(CoverageCrop.rect(coverage: [Float](repeating: 0, count: 16), width: 4, height: 4))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CoverageCropTests 2>&1 | tail -5`
Expected: FAIL — `type 'CoverageCrop' has no member 'rect'`.

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/LiveAstroCore/Stacking/CoverageCrop.swift`:

```swift
/// Computes the inscribed rectangle of the well-covered region of a coverage
/// (per-pixel frame-count) map. Robust to translation and field rotation:
/// trims whole rows/columns whose well-covered fraction is too low.
public enum CoverageCrop {
    public static func rect(coverage: [Float], width: Int, height: Int,
                            wellCoveredFraction: Float = 0.9,
                            edgeFloor: Float = 0.5) -> CropRect? {
        guard width > 0, height > 0, coverage.count == width * height else { return nil }
        var peak: Float = 0
        for v in coverage where v > peak { peak = v }
        guard peak > 0 else { return nil }
        let thresh = wellCoveredFraction * peak

        // per-row and per-column count of well-covered pixels
        var rowCount = [Int](repeating: 0, count: height)
        var colCount = [Int](repeating: 0, count: width)
        for y in 0..<height {
            let base = y * width
            for x in 0..<width where coverage[base + x] >= thresh {
                rowCount[y] += 1; colCount[x] += 1
            }
        }
        func trim(_ counts: [Int], _ span: Int) -> (Int, Int)? {
            var lo = 0, hi = counts.count - 1
            while lo <= hi && Float(counts[lo]) < edgeFloor * Float(span) { lo += 1 }
            while hi >= lo && Float(counts[hi]) < edgeFloor * Float(span) { hi -= 1 }
            return lo <= hi ? (lo, hi) : nil
        }
        // a row's "span" is width (max well-covered pixels it could have); col's is height
        guard let (y0, y1) = trim(rowCount, width),
              let (x0, x1) = trim(colCount, height) else { return nil }
        return CropRect(x0: x0, y0: y0, x1: x1, y1: y1)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CoverageCropTests 2>&1 | tail -5`
Expected: PASS — 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Stacking/CoverageCrop.swift Tests/LiveAstroCoreTests/CoverageCropTests.swift
git commit -m "feat: CoverageCrop.rect — inscribed rectangle of covered region"
```

---

### Task 3: Coverage accessors — `StackAccumulator.coverage()` + `StackEngine.currentCoverage()`

**Files:**
- Modify: `Sources/LiveAstroCore/Stacking/StackAccumulator.swift` (add `coverage()`)
- Modify: `Sources/LiveAstroCore/Stacking/StackEngine.swift` (add `currentCoverage()`)
- Test: `Tests/LiveAstroCoreTests/CoverageAccessorTests.swift`

**Interfaces:**
- Consumes: `StackAccumulator` internals (`weight: [Float]`, `add(_:mask:)`, `mean()`); `StackEngine` (`private var accumulator`, `currentStack()`, the `lock`).
- Produces: `public func coverage() -> [Float]` on `StackAccumulator` (returns a COPY of `weight`); `public func currentCoverage() -> [Float]?` on `StackEngine` (nil if no accumulator; read under the same lock as `currentStack()`).

**Constraint:** the accumulation math must not change. `coverage()` is a pure read that returns a copy. A test asserts `mean()` output is byte-identical for the same added frames whether or not `coverage()` is called.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class CoverageAccessorTests: XCTestCase {
    private func img(_ w: Int, _ h: Int, _ v: Float) -> AstroImage {
        AstroImage(width: w, height: h, channels: 1, pixels: [Float](repeating: v, count: w*h), sourceIsLinear: true)
    }

    func testCoverageCountsMaskContributions() {
        let acc = StackAccumulator(width: 2, height: 2, channels: 1)   // match real init
        acc.add(img(2,2,0.5), mask: [1,1,0,0])
        acc.add(img(2,2,0.5), mask: [1,0,0,0])
        // pixel0 covered twice, pixel1 once, pixels 2&3 never
        XCTAssertEqual(acc.coverage(), [2, 1, 0, 0])
    }

    func testCoverageIsACopy_doesNotAffectMean() {
        let acc = StackAccumulator(width: 2, height: 2, channels: 1)
        acc.add(img(2,2,0.4), mask: [1,1,1,1])
        let meanBefore = acc.mean().pixels
        var cov = acc.coverage()
        cov[0] = 999                       // mutate the returned copy
        acc.add(img(2,2,0.6), mask: [1,1,1,1])
        // mean must reflect real accumulation, unaffected by mutating the copy
        let meanAfter = acc.mean().pixels
        XCTAssertEqual(meanBefore, [0.4, 0.4, 0.4, 0.4])
        XCTAssertEqual(meanAfter, [0.5, 0.5, 0.5, 0.5], accuracy: 1e-6)
    }
}
```

> Match the real `StackAccumulator(width:height:channels:)` initializer — check `StackAccumulator.swift` and how `StackEngine` constructs it; adjust the init call if it differs. There is no `StackEngine` test here because constructing an engine with a live accumulator is covered by the e2e in Task 4; `currentCoverage()` is exercised there.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CoverageAccessorTests 2>&1 | tail -5`
Expected: FAIL — no `coverage()` member.

- [ ] **Step 3: Write minimal implementation**

Add to `StackAccumulator` (after `mean()`):

```swift
    /// Read-only per-pixel coverage (sum of applied mask values). With binary
    /// Warp masks this is the number of frames covering each pixel. Returns a
    /// copy; callers cannot mutate accumulator state.
    public func coverage() -> [Float] { weight }
```

Add to `StackEngine`:

```swift
    /// The current per-pixel coverage map, or nil if there is no active stack.
    public func currentCoverage() -> [Float]? {
        lock.withLock { accumulator?.coverage() }
    }
```

> `weight` is a `[Float]` (a value type); returning it copies. Use the exact property name from `StackAccumulator.swift` (`weight`). Use the exact lock the engine already uses for `currentStack()`/`stackFrameCount`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CoverageAccessorTests 2>&1 | tail -5`
Then regression: `swift test --filter LiveAstroCoreTests 2>&1 | tail -5`
Expected: both PASS (accumulation unchanged; existing stacker tests green).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Stacking/StackAccumulator.swift Sources/LiveAstroCore/Stacking/StackEngine.swift Tests/LiveAstroCoreTests/CoverageAccessorTests.swift
git commit -m "feat: read-only coverage() / currentCoverage() accessors"
```

---

### Task 4: Crop the master in `SessionPipeline.end()` (before balance) with safety guard

**Files:**
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` (add `cropMaster` helper; use it in `end()`'s master-write block)
- Test: `Tests/LiveAstroCoreTests/CropToOverlapPipelineTests.swift`

**Interfaces:**
- Consumes: `StackEngine.currentStack()`, `StackEngine.currentCoverage()` (Task 3), `CoverageCrop.rect` (Task 2), `AstroImage.cropped(to:)` (Task 1), the existing `AutoStretch.neutralizeBackgroundAdditive`, `FITSWriter.float32(...metadata:stackCount:totalExposureSeconds:)`, `sourceMetadata` / `neutralizeBackground` / `profile` (existing pipeline state).
- Produces: a private `cropMaster(_ image: AstroImage, coverage: [Float]?) -> AstroImage` on `SessionPipeline`, and a modified master-write block that crops **before** balance.

**Current master-write block (from clean-export, `SessionPipeline.swift` ~lines 219-231):**
```swift
if let eng = engine, let master = eng.currentStack() {
    let balanced = neutralizeBackground ? AutoStretch.neutralizeBackgroundAdditive(master) : master
    let totalExp = Double(eng.stackFrameCount) * profile.subExposureSeconds
    let masterData = FITSWriter.float32(width: balanced.width, height: balanced.height,
        channels: balanced.channels, pixels: balanced.pixels,
        metadata: sourceMetadata, stackCount: eng.acceptedCount, totalExposureSeconds: totalExp)
    try masterData.write(to: dir.appendingPathComponent("master.fit"))
}
```

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class CropToOverlapPipelineTests: XCTestCase {
    // Run a native session over synthetic subs that DRIFT so their footprints
    // only partly overlap, then inspect master.fit dims. Mirror the harness in
    // CleanExportPipelineTests / NativePipelineTests for session construction.

    func testMasterIsCroppedToCoveredRegion() throws {
        let (subsDir, sessionRoot) = try makeDriftingSession()   // helper below
        defer { try? FileManager.default.removeItem(at: subsDir); try? FileManager.default.removeItem(at: sessionRoot) }
        let master = try findMaster(in: sessionRoot)
        let hdr = try FITSReader.readHeader(master)
        let (w, h) = (Int(hdr.keywords["NAXIS1"]!.trimmingCharacters(in: .whitespaces))!,
                     Int(hdr.keywords["NAXIS2"]!.trimmingCharacters(in: .whitespaces))!)
        // subs are SUB_W×SUB_H; drift means the covered core is strictly smaller
        XCTAssertLessThan(w, SUB_W)
        XCTAssertLessThan(h, SUB_H)
        XCTAssertGreaterThan(w, SUB_W / 2)   // safety guard kept a majority
    }

    func testFullFrameWhenNoDrift() throws {
        // identical (non-drifting) subs => uniform coverage => no crop
        let (subsDir, sessionRoot) = try makeNoDriftSession()
        defer { try? FileManager.default.removeItem(at: subsDir); try? FileManager.default.removeItem(at: sessionRoot) }
        let hdr = try FITSReader.readHeader(try findMaster(in: sessionRoot))
        XCTAssertEqual(Int(hdr.keywords["NAXIS1"]!.trimmingCharacters(in: .whitespaces))!, SUB_W)
        XCTAssertEqual(Int(hdr.keywords["NAXIS2"]!.trimmingCharacters(in: .whitespaces))!, SUB_H)
    }
}
```

> Implement `makeDriftingSession`, `makeNoDriftSession`, `findMaster`, and the `SUB_W`/`SUB_H` constants as private test helpers. **Model session construction on `CleanExportPipelineTests`** (it already builds a native session over synthetic CFA subs with shared stars and runs `end()`). For `makeDriftingSession`, shift each sub's star pattern + content by a few pixels between frames (a small translation per frame) so registration succeeds but the footprints only partly overlap → the covered core is smaller than a single sub. For `makeNoDriftSession`, use identical (unshifted) subs → uniform coverage → the safety/no-op path keeps the full frame. Use enough subs (≥4) and bright shared stars so `StackEngine` seeds and stacks.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CropToOverlapPipelineTests 2>&1 | tail -8`
Expected: FAIL — master NAXIS equals the sub size (no crop applied yet).

- [ ] **Step 3: Write minimal implementation**

Add the helper to `SessionPipeline`:

```swift
    /// Crop the master to its covered region (a copy). Returns the image
    /// unchanged when coverage is unavailable, the rect is nil, the rect is the
    /// full frame, or the crop would remove more than ~40% of the area.
    private func cropMaster(_ image: AstroImage, coverage: [Float]?) -> AstroImage {
        guard let cov = coverage,
              let rect = CoverageCrop.rect(coverage: cov, width: image.width, height: image.height)
        else { return image }
        if rect.x0 == 0 && rect.y0 == 0 && rect.x1 == image.width - 1 && rect.y1 == image.height - 1 {
            return image   // full-frame rect: no-op
        }
        let croppedArea = rect.width * rect.height
        guard croppedArea >= (image.width * image.height) * 6 / 10 else {
            onLog?("Crop-to-overlap: rect \(rect.width)x\(rect.height) would remove >40% — keeping full frame")
            return image
        }
        return image.cropped(to: rect)
    }
```

Replace the master-write block in `end()`:

```swift
if let eng = engine, let master0 = eng.currentStack() {
    let master = cropMaster(master0, coverage: eng.currentCoverage())   // crop BEFORE balance
    let balanced = neutralizeBackground ? AutoStretch.neutralizeBackgroundAdditive(master) : master
    let totalExp = Double(eng.stackFrameCount) * profile.subExposureSeconds
    let masterData = FITSWriter.float32(width: balanced.width, height: balanced.height,
        channels: balanced.channels, pixels: balanced.pixels,
        metadata: sourceMetadata, stackCount: eng.acceptedCount, totalExposureSeconds: totalExp)
    try masterData.write(to: dir.appendingPathComponent("master.fit"))
}
```

> Use the exact `onLog?` logging call the pipeline already uses (check `SessionPipeline.swift` for the log closure name; if it's different, match it — the log line is nice-to-have, not load-bearing).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CropToOverlapPipelineTests 2>&1 | tail -5`
Then full core: `swift test --filter LiveAstroCoreTests 2>&1 | tail -5`
Expected: both PASS. (Existing `CleanExportPipelineTests` must stay green — their subs are non-drifting/identical, so coverage is uniform → no crop → their asserted dims are unchanged. If a clean-export test used drifting subs, reconcile: those e2e subs are identical per that pillar's design, so they hit the no-op path.)

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Pipeline/SessionPipeline.swift Tests/LiveAstroCoreTests/CropToOverlapPipelineTests.swift
git commit -m "feat: crop master to covered region before export (safety-guarded)"
```

---

## Notes for the implementer

- **`CropRect` lives in `CoverageCrop.swift`** (created in Task 1). Task 2 appends the `CoverageCrop` enum to the same file. Task 1's `AstroImage.cropped` depends on `CropRect` existing — that's why Task 1 creates the file.
- **`StackAccumulator` init + `weight` property name:** confirm against the real `StackAccumulator.swift` before Task 3 (the Explore reported `private var weight: [Float]` and `public private(set) var frameCount`; the init signature used by `StackEngine` is what the Task 3 test must call).
- **Task 4 e2e harness:** the single biggest adaptation point — reuse `CleanExportPipelineTests`'s native-session construction verbatim and only change the subs (drifting vs identical). Registration needs shared bright stars across frames; a per-frame translation of a few pixels creates partial overlap without breaking the star match.
- **No regression to clean-export:** the crop slots *before* the additive-balance and metadata write; the balance/metadata/STACKCNT/TOTALEXP behavior is unchanged, just applied to a (possibly) smaller image. The `FITSWriter` signature is untouched.
