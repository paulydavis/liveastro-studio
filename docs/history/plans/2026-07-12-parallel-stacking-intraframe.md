# Multithreaded Stacking (Intra-frame) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Parallelize the four pixel-O(N) stacking loops (Warp, Debayer, half-res luminance, accumulate) across cores so each frame processes faster, with byte-identical output.

**Architecture:** A shared `Parallel.rows` helper splits `[0, height)` into contiguous row bands run via `DispatchQueue.concurrentPerform`; each of the four loops writes disjoint output rows within its band (no locks). `StackEngine`'s per-frame lock + serial accumulator model are unchanged — parallelism is strictly intra-frame.

**Tech Stack:** Swift 5.10, SwiftPM, XCTest, Foundation/Dispatch. Zero external dependencies.

## Global Constraints

- Swift 5.10, macOS 14+.
- `LiveAstroCore` imports Foundation / CoreGraphics / Accelerate only. `Parallel` uses Foundation/Dispatch only.
- Zero external dependencies.
- **Byte-identical** output vs the current serial implementation — guarded by parity tests (forced-serial vs forced-parallel on the same input) AND the existing Core suite passing unchanged.
- Core logic is TDD'd (`swift test --filter LiveAstroCoreTests`).
- `StackEngine` per-frame lock + serial accumulator model unchanged; parallelism is intra-frame only.
- Public signatures gain only defaulted internal params (`minRows: Int = 64`); external callers unchanged.
- Co-Authored-By Claude trailer allowed in this repo.

---

### Task 1: `Parallel.rows` helper (TDD)

**Files:**
- Create: `Sources/LiveAstroCore/Util/Parallel.swift`
- Test: `Tests/LiveAstroCoreTests/ParallelTests.swift`

**Interfaces:**
- Consumes: nothing (leaf utility).
- Produces: `enum Parallel { static func rows(_ height: Int, minRows: Int = 64, _ body: (Range<Int>) -> Void) }` (module-internal).

- [ ] **Step 1: Write the failing tests**

Create `Tests/LiveAstroCoreTests/ParallelTests.swift`:

```swift
import XCTest
@testable import LiveAstroCore

final class ParallelTests: XCTestCase {
    func testBandsCoverEveryRowExactlyOnce() {
        for height in [1, 7, 64, 100, 257, 1000] {
            var counts = [Int](repeating: 0, count: height)
            let lock = NSLock()
            Parallel.rows(height, minRows: 0) { rows in          // minRows 0 → force parallel
                var local: [Int] = []
                for y in rows { local.append(y) }
                lock.withLock { for y in local { counts[y] += 1 } }
            }
            XCTAssertTrue(counts.allSatisfy { $0 == 1 }, "height \(height): each row visited exactly once")
        }
    }

    func testSerialPathBelowThresholdIsOneBand() {
        var ranges: [Range<Int>] = []
        Parallel.rows(10, minRows: 64) { ranges.append($0) }     // 10 < 64 → serial
        XCTAssertEqual(ranges, [0..<10])
    }

    func testZeroHeightRunsNothing() {
        var called = false
        Parallel.rows(0, minRows: 0) { _ in called = true }
        XCTAssertFalse(called)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ParallelTests`
Expected: FAIL — `cannot find 'Parallel' in scope`.

- [ ] **Step 3: Write the helper**

Create `Sources/LiveAstroCore/Util/Parallel.swift`:

```swift
import Foundation

/// Data-parallel helpers for pixel-O(N) loops. Splits a row range into
/// contiguous bands run concurrently across cores; each band writes disjoint
/// output rows, so no locks are needed. Callers stay byte-identical to a serial
/// loop because every output element is written by exactly one band.
enum Parallel {
    /// Run `body` over contiguous row bands of `[0, height)` concurrently. Below
    /// `minRows` rows (or on a single-core machine) runs a single serial band —
    /// avoids GCD overhead on small/test images. Blocks until all bands finish.
    /// `body` receives a half-open row range and must write only rows in it.
    static func rows(_ height: Int, minRows: Int = 64, _ body: (Range<Int>) -> Void) {
        guard height > 0 else { return }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        if height < minRows || cores <= 1 {
            body(0..<height)
            return
        }
        let bandCount = min(cores, height)
        DispatchQueue.concurrentPerform(iterations: bandCount) { b in
            let lo = b * height / bandCount
            let hi = (b + 1) * height / bandCount
            if lo < hi { body(lo..<hi) }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ParallelTests`
Expected: PASS — 3 tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Util/Parallel.swift Tests/LiveAstroCoreTests/ParallelTests.swift
git commit -m "feat: Parallel.rows row-band helper for data-parallel pixel loops (TDD)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Parallelize `Warp.apply` (the biggest loop)

**Files:**
- Modify: `Sources/LiveAstroCore/Stacking/Warp.swift`
- Test: `Tests/LiveAstroCoreTests/WarpParallelTests.swift`

**Interfaces:**
- Consumes: `Parallel.rows(_:minRows:_:)` (Task 1).
- Produces: `Warp.apply(_:transform:minRows:)` — new defaulted `minRows: Int = 64` trailing param; return type unchanged `(image: AstroImage, mask: [Float])`.

- [ ] **Step 1: Write the failing parity test**

Create `Tests/LiveAstroCoreTests/WarpParallelTests.swift`:

```swift
import XCTest
@testable import LiveAstroCore

final class WarpParallelTests: XCTestCase {
    func testParallelWarpIsByteIdenticalToSerial() {
        let w = 160, h = 130
        var px = [Float](repeating: 0, count: w * h * 3)
        for i in 0..<px.count { px[i] = Float((i * 7 + 3) % 251) / 251 }   // deterministic pattern
        let img = AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
        let t = SimilarityTransform(scale: 1.02, rotation: 0.03, tx: 2.5, ty: -1.5)

        let serial = Warp.apply(img, transform: t, minRows: .max)   // force serial
        let parallel = Warp.apply(img, transform: t, minRows: 0)    // force parallel

        XCTAssertEqual(serial.image.pixels, parallel.image.pixels)
        XCTAssertEqual(serial.mask, parallel.mask)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WarpParallelTests`
Expected: FAIL — `extra argument 'minRows' in call` (param not added yet).

- [ ] **Step 3: Rewrite `Warp.apply` to band by row**

Replace the body of `Warp.apply` in `Sources/LiveAstroCore/Stacking/Warp.swift` with (adds `minRows`, moves the `for y` loop into `Parallel.rows`, same math):

```swift
    public static func apply(_ image: AstroImage,
                             transform: SimilarityTransform,
                             minRows: Int = 64) -> (image: AstroImage, mask: [Float]) {
        let w = image.width, h = image.height, plane = w * h
        let channels = image.channels
        let inv = transform.inverse()
        var out = [Float](repeating: 0, count: image.pixels.count)
        var mask = [Float](repeating: 0, count: plane)
        image.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { outBuf in
                mask.withUnsafeMutableBufferPointer { maskBuf in
                    Parallel.rows(h, minRows: minRows) { rows in
                        for y in rows {
                            for x in 0..<w {
                                let p = inv.apply(x: Double(x), y: Double(y))
                                let x0 = Int(floor(p.x)), y0 = Int(floor(p.y))
                                guard x0 >= 0, y0 >= 0, x0 < w - 1 || (x0 == w - 1 && p.x == Double(w - 1)),
                                      y0 < h - 1 || (y0 == h - 1 && p.y == Double(h - 1)) else { continue }
                                let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
                                let tx = Float(p.x - Double(x0)), ty = Float(p.y - Double(y0))
                                let w00 = (1 - tx) * (1 - ty), w01 = tx * (1 - ty)
                                let w10 = (1 - tx) * ty, w11 = tx * ty
                                for c in 0..<channels {
                                    let base = c * plane
                                    outBuf[base + y * w + x] =
                                        w00 * src[base + y0 * w + x0] + w01 * src[base + y0 * w + x1] +
                                        w10 * src[base + y1 * w + x0] + w11 * src[base + y1 * w + x1]
                                }
                                maskBuf[y * w + x] = 1
                            }
                        }
                    }
                }
            }
        }
        let img = AstroImage(width: w, height: h, channels: channels,
                             pixels: out, sourceIsLinear: image.sourceIsLinear)
        return (img, mask)
    }
```

- [ ] **Step 4: Run the parity test + existing Warp tests**

Run: `swift test --filter WarpParallelTests`
Expected: PASS.
Run: `swift test --filter WarpTests`
Expected: PASS (behavior unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Stacking/Warp.swift Tests/LiveAstroCoreTests/WarpParallelTests.swift
git commit -m "perf: parallelize Warp.apply over row bands (byte-identical)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Parallelize `Debayer.bilinear`

**Files:**
- Modify: `Sources/LiveAstroCore/Stacking/Debayer.swift`
- Test: `Tests/LiveAstroCoreTests/DebayerParallelTests.swift`

**Interfaces:**
- Consumes: `Parallel.rows` (Task 1).
- Produces: `Debayer.bilinear(cfa:pattern:minRows:)` — new defaulted `minRows: Int = 64` trailing param; return type unchanged (`AstroImage`).

- [ ] **Step 1: Write the failing parity test**

Create `Tests/LiveAstroCoreTests/DebayerParallelTests.swift`:

```swift
import XCTest
@testable import LiveAstroCore

final class DebayerParallelTests: XCTestCase {
    func testParallelDebayerIsByteIdenticalToSerial() {
        let w = 150, h = 140
        var px = [Float](repeating: 0, count: w * h)
        for i in 0..<px.count { px[i] = Float((i * 13 + 5) % 239) / 239 }
        let cfa = AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true)

        let serial = Debayer.bilinear(cfa: cfa, pattern: .rggb, minRows: .max)
        let parallel = Debayer.bilinear(cfa: cfa, pattern: .rggb, minRows: 0)

        XCTAssertEqual(serial.pixels, parallel.pixels)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DebayerParallelTests`
Expected: FAIL — `extra argument 'minRows' in call`.

- [ ] **Step 3: Rewrite `Debayer.bilinear` to band by row**

Replace the body of `Debayer.bilinear` in `Sources/LiveAstroCore/Stacking/Debayer.swift` with (adds `minRows`, moves `for y` into `Parallel.rows`, same math):

```swift
    public static func bilinear(cfa: AstroImage, pattern: BayerPattern,
                                minRows: Int = 64) -> AstroImage {
        precondition(cfa.channels == 1, "CFA input must be single-channel")
        let w = cfa.width, h = cfa.height, plane = w * h
        // K weights by (dy+1, dx+1); G kernel is the cross, R/B the full 3×3.
        let kG: [Float] = [0, 1, 0, 1, 4, 1, 0, 1, 0]
        let kRB: [Float] = [1, 2, 1, 2, 4, 2, 1, 2, 1]
        var out = [Float](repeating: 0, count: plane * 3)
        cfa.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { outBuf in
                Parallel.rows(h, minRows: minRows) { rows in
                    for y in rows {
                        for x in 0..<w {
                            for c in 0..<3 {
                                let k = c == 1 ? kG : kRB
                                var num: Float = 0, den: Float = 0
                                for dy in -1...1 {
                                    let yy = y + dy
                                    guard yy >= 0, yy < h else { continue }
                                    for dx in -1...1 {
                                        let xx = x + dx
                                        guard xx >= 0, xx < w else { continue }
                                        guard pattern.channel(row: yy, col: xx) == c else { continue }
                                        let kw = k[(dy + 1) * 3 + (dx + 1)]
                                        num += kw * src[yy * w + xx]
                                        den += kw
                                    }
                                }
                                outBuf[c * plane + y * w + x] = den > 0 ? num / den : 0
                            }
                        }
                    }
                }
            }
        }
        return AstroImage(width: w, height: h, channels: 3, pixels: out,
                          sourceIsLinear: cfa.sourceIsLinear)
    }
```

- [ ] **Step 4: Run the parity test + existing Debayer tests**

Run: `swift test --filter DebayerParallelTests`
Expected: PASS.
Run: `swift test --filter DebayerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Stacking/Debayer.swift Tests/LiveAstroCoreTests/DebayerParallelTests.swift
git commit -m "perf: parallelize Debayer.bilinear over row bands (byte-identical)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Parallelize `halfResLuminance` and `StackAccumulator.add`

**Files:**
- Modify: `Sources/LiveAstroCore/Stacking/StackEngine.swift` (the static `halfResLuminance`)
- Modify: `Sources/LiveAstroCore/Stacking/StackAccumulator.swift` (`add`)
- Test: `Tests/LiveAstroCoreTests/HalfResLuminanceParallelTests.swift`
- Test: `Tests/LiveAstroCoreTests/StackAccumulatorParallelTests.swift`

**Interfaces:**
- Consumes: `Parallel.rows` (Task 1); `RawFrame(image:bayerPattern:bottomUp:timestamp:sourceName:)`.
- Produces: `StackEngine.halfResLuminance(frame:minRows:)` and `StackAccumulator.add(_:mask:minRows:)` — each with a new defaulted `minRows: Int = 64` trailing param.

- [ ] **Step 1: Write the failing parity tests**

Create `Tests/LiveAstroCoreTests/HalfResLuminanceParallelTests.swift`:

```swift
import XCTest
@testable import LiveAstroCore

final class HalfResLuminanceParallelTests: XCTestCase {
    func testParallelLuminanceIsByteIdenticalToSerial() {
        let w = 200, h = 300
        var px = [Float](repeating: 0, count: w * h)
        for i in 0..<px.count { px[i] = Float((i * 11 + 2) % 233) / 233 }
        let img = AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true)
        let frame = RawFrame(image: img, bayerPattern: .rggb, bottomUp: false,
                             timestamp: Date(timeIntervalSince1970: 0), sourceName: "t")

        let serial = StackEngine.halfResLuminance(frame: frame, minRows: .max)
        let parallel = StackEngine.halfResLuminance(frame: frame, minRows: 0)

        XCTAssertEqual(serial.lum, parallel.lum)
        XCTAssertEqual(serial.width, parallel.width)
        XCTAssertEqual(serial.height, parallel.height)
    }

    func testBottomUpParallelMatchesSerial() {
        let w = 200, h = 260
        var px = [Float](repeating: 0, count: w * h)
        for i in 0..<px.count { px[i] = Float((i * 5 + 9) % 197) / 197 }
        let img = AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true)
        let frame = RawFrame(image: img, bayerPattern: .rggb, bottomUp: true,
                             timestamp: Date(timeIntervalSince1970: 0), sourceName: "t")
        let serial = StackEngine.halfResLuminance(frame: frame, minRows: .max)
        let parallel = StackEngine.halfResLuminance(frame: frame, minRows: 0)
        XCTAssertEqual(serial.lum, parallel.lum)
    }
}
```

Create `Tests/LiveAstroCoreTests/StackAccumulatorParallelTests.swift`:

```swift
import XCTest
@testable import LiveAstroCore

final class StackAccumulatorParallelTests: XCTestCase {
    func testParallelAddIsByteIdenticalToSerial() {
        let w = 180, h = 220, plane = w * h
        var px = [Float](repeating: 0, count: plane * 3)
        for i in 0..<px.count { px[i] = Float((i * 3 + 1) % 211) / 211 }
        let img = AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
        var mask = [Float](repeating: 1, count: plane)
        for i in stride(from: 0, to: plane, by: 7) { mask[i] = 0 }   // some uncovered pixels

        let serialAcc = StackAccumulator(width: w, height: h, channels: 3)
        serialAcc.add(img, mask: mask, minRows: .max)
        let parallelAcc = StackAccumulator(width: w, height: h, channels: 3)
        parallelAcc.add(img, mask: mask, minRows: 0)

        XCTAssertEqual(serialAcc.mean().pixels, parallelAcc.mean().pixels)
        XCTAssertEqual(serialAcc.coverage(), parallelAcc.coverage())
        XCTAssertEqual(serialAcc.frameCount, parallelAcc.frameCount)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter HalfResLuminanceParallelTests`
Run: `swift test --filter StackAccumulatorParallelTests`
Expected: both FAIL — `extra argument 'minRows' in call`.

- [ ] **Step 3: Rewrite `halfResLuminance` to band by row**

Replace the static `halfResLuminance` in `Sources/LiveAstroCore/Stacking/StackEngine.swift` with (adds `minRows`, bands the `for j` loop; each band writes disjoint `lum` rows):

```swift
    static func halfResLuminance(frame: RawFrame, minRows: Int = 64)
        -> (lum: [Float], width: Int, height: Int) {
        let raw = frame.image
        let hw = raw.width / 2, hh = raw.height / 2
        var lum = [Float](repeating: 0, count: hw * hh)
        let bottomUp = frame.bottomUp
        let rw = raw.width
        raw.pixels.withUnsafeBufferPointer { p in
            lum.withUnsafeMutableBufferPointer { lumBuf in
                Parallel.rows(hh, minRows: minRows) { rows in
                    for j in rows {
                        let srcRow = bottomUp ? (hh - 1 - j) : j
                        for i in 0..<hw {
                            let r0 = 2 * srcRow * rw + 2 * i
                            let r1 = r0 + rw
                            lumBuf[j * hw + i] = (p[r0] + p[r0 + 1] + p[r1] + p[r1 + 1]) / 4
                        }
                    }
                }
            }
        }
        return (lum, hw, hh)
    }
```

- [ ] **Step 4: Rewrite `StackAccumulator.add` to band by row**

Replace `StackAccumulator.add` in `Sources/LiveAstroCore/Stacking/StackAccumulator.swift` with (adds `minRows`, converts the flat `for i` loop into a row-banded loop; each pixel index is written by exactly one band):

```swift
    public func add(_ image: AstroImage, mask: [Float], minRows: Int = 64) {
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
                                    let mv = m[i]
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

- [ ] **Step 5: Run the parity tests + the full stacking suite**

Run: `swift test --filter HalfResLuminanceParallelTests`
Run: `swift test --filter StackAccumulatorParallelTests`
Expected: both PASS.
Run: `swift test --filter StackEngineTests` (and any StackAccumulator/AutoReseed tests)
Expected: PASS (behavior unchanged).

- [ ] **Step 6: Full Core suite green + release build**

Run: `swift test --filter LiveAstroCoreTests`
Expected: all pass.
Run: `swift build -c release`
Expected: succeeds.

- [ ] **Step 7: Commit**

```bash
git add Sources/LiveAstroCore/Stacking/StackEngine.swift Sources/LiveAstroCore/Stacking/StackAccumulator.swift Tests/LiveAstroCoreTests/HalfResLuminanceParallelTests.swift Tests/LiveAstroCoreTests/StackAccumulatorParallelTests.swift
git commit -m "perf: parallelize halfResLuminance + StackAccumulator.add over row bands (byte-identical)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage:**
- `Parallel.rows` helper (banding, minRows serial fallback, disjoint bands) → Task 1. ✅
- Warp parallel → Task 2; Debayer → Task 3; halfResLuminance + accumulator → Task 4. ✅ (all four loops)
- Byte-identical guarantee → parity tests in T2/T3/T4 (forced serial `.max` vs parallel `0`) + existing suites must pass. ✅
- `minRows` defaulted internal knob on each function; external callers unchanged (StackEngine.process/displayRGB call with defaults). ✅
- StackEngine lock + serial accumulator unchanged (only the inner loops fan out; `concurrentPerform` blocks to join). ✅
- No StarDetector, no inter-frame, no external deps → none added. ✅
- `Parallel.rows` band-coverage + serial-path + zero-height unit tests → Task 1. ✅

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code; run steps show command + expected result.

**3. Type consistency:** `Parallel.rows(_:minRows:_:)` signature is identical across Task 1 (definition) and Tasks 2–4 (calls). The `minRows: Int = 64` trailing param is added consistently to `Warp.apply`, `Debayer.bilinear`, `StackEngine.halfResLuminance`, and `StackAccumulator.add`; parity tests pass `.max` (serial) / `0` (parallel). `RawFrame(image:bayerPattern:bottomUp:timestamp:sourceName:)` and `SimilarityTransform(scale:rotation:tx:ty:)` match the real initializers. `BayerPattern.rggb` is a real case.
