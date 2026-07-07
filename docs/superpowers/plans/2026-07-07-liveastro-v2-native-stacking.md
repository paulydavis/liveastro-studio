# LiveAstro v2 Native Stacking — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** LiveAstro stacks sub-exposures natively — import (folder of acquired subs) and live (watched folder) — per spec `docs/superpowers/specs/2026-07-07-liveastro-v2-native-stacking-design.md`.

**Architecture:** Pure `StackEngine` (debayer → star-detect → triangle-match → RANSAC similarity → warp → weighted mean accumulator) behind a `FrameSource` protocol; `SessionPipeline` gains a native mode that feeds engine output into the existing snapshot/replay path and writes `master.fit` at session end.

**Tech Stack:** Swift 5.10 SPM, XCTest, Foundation/CoreGraphics only (Accelerate allowed, ships with macOS). Porting reference: `Scripts/build_session_from_subs.py` — never Siril source (GPL).

## Global Constraints

- Zero external dependencies; `LiveAstroCore` stays UI-free (no SwiftUI/AppKit imports).
- Debayer full-res bilinear; patterns GRBG and RGGB; pattern applied in **stored row order before any flip**.
- Rejection is registration-failure only: too few stars or no consistent transform → `.rejected`, logged and counted. No quality knobs.
- Stacking = incremental weighted mean (Float32 planar sum + per-pixel weight).
- Alignment = similarity transform (translation + rotation + scale), RANSAC, default `minMatches = 8` inliers at `inlierTolerance = 2.0` px.
- Registration runs on half-res CFA-superpixel luminance; solved transform is lifted exactly to full res (`s`, `θ` unchanged; `t_full = 2·t_half + (I − sR)·(0.5, 0.5)`).
- Reference = first frame with ≥ `seedMinStars = 15` detected stars; `reseed()` clears accumulator + reference.
- Manifest stats stay linear/raw (cloud-gate contract from v1.1); neutralization toggle applies only to display/snapshot rendering, exactly as in `SessionPipeline.handle`.
- End Session in native mode writes `master.fit` (32-bit float, 3-channel, TOP-DOWN ROWORDER) via `FITSWriter`.
- All existing tests keep passing; run `swift test` from repo root per task.
- Commits may carry the `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` trailer.

## File Map

```
Sources/LiveAstroCore/FITS/FITSTypes.swift        (modify: keywords on FITSHeader)
Sources/LiveAstroCore/FITS/FITSReader.swift       (modify: collect keywords)
Sources/LiveAstroCore/Stacking/Debayer.swift      (new)
Sources/LiveAstroCore/Stacking/StarDetector.swift (new)
Sources/LiveAstroCore/Stacking/TriangleMatcher.swift (new)
Sources/LiveAstroCore/Stacking/SimilarityTransform.swift (new)
Sources/LiveAstroCore/Stacking/TransformSolver.swift (new)
Sources/LiveAstroCore/Stacking/Warp.swift         (new)
Sources/LiveAstroCore/Stacking/StackAccumulator.swift (new)
Sources/LiveAstroCore/Stacking/StackEngine.swift  (new)
Sources/LiveAstroCore/Sources/FrameSource.swift   (new: protocol + RawFrame)
Sources/LiveAstroCore/Sources/FolderFrameSource.swift (new)
Sources/LiveAstroCore/Pipeline/SessionPipeline.swift (modify: native mode + master.fit)
Sources/LiveAstroStudio/AppModel.swift            (modify: mode, counters, import)
Sources/LiveAstroStudio/ControlView.swift         (modify: picker, reseed, import UI)
Tests/LiveAstroCoreTests/… one test file per new component
```

---

### Task 1: FITSHeader keyword map (BAYERPAT, DATE-OBS)

**Files:**
- Modify: `Sources/LiveAstroCore/FITS/FITSTypes.swift`
- Modify: `Sources/LiveAstroCore/FITS/FITSReader.swift`
- Test: `Tests/LiveAstroCoreTests/FITSReaderTests.swift` (append)

**Interfaces:**
- Produces: `FITSHeader.keywords: [String: String]` — every parsed `KEY = value` card, key uppercased, string values unquoted/trimmed; convenience `var bayerPattern: String? { keywords["BAYERPAT"] }` and `var dateObs: String? { keywords["DATE-OBS"] }`.
- Consumes: existing card parsing loop in `FITSReader.readHeader`.

- [ ] **Step 1: Write failing tests** (append to FITSReaderTests)

```swift
    func testHeaderKeywordsCaptured() throws {
        var header = ""
        func card(_ s: String) { header += s.padding(toLength: 80, withPad: " ", startingAt: 0) }
        card("SIMPLE  =                    T")
        card("BITPIX  =                   16")
        card("NAXIS   =                    2")
        card("NAXIS1  =                    4")
        card("NAXIS2  =                    2")
        card("BZERO   =                32768")
        card("BAYERPAT= 'GRBG    '")
        card("DATE-OBS= '2026-07-06T22:04:40.123'")
        card("END")
        var data = header.data(using: .ascii)!
        data.append(Data(repeating: 0x20, count: 2880 - data.count % 2880))
        data.append(Data(repeating: 0, count: 16))
        let h = try FITSReader.readHeader(data)
        XCTAssertEqual(h.bayerPattern, "GRBG")
        XCTAssertEqual(h.dateObs, "2026-07-06T22:04:40.123")
        XCTAssertEqual(h.keywords["BITPIX"], "16")
    }
```

- [ ] **Step 2: Run** `swift test --filter FITSReaderTests 2>&1 | tail -5` — expect compile failure (`bayerPattern` undefined).

- [ ] **Step 3: Implement.** In `FITSTypes.swift` add to `FITSHeader`:

```swift
    public let keywords: [String: String]

    public var bayerPattern: String? { keywords["BAYERPAT"] }
    public var dateObs: String? { keywords["DATE-OBS"] }
```

Give `keywords` a `= [:]` default in the memberwise `init` so existing construction sites compile unchanged. In `FITSReader.readHeader`, inside the existing card loop, after a card's key and raw value are split, add every pair to a local `var keywords: [String: String]`: key uppercased and trimmed; value with surrounding single quotes stripped and whitespace trimmed (reuse the existing value-parsing helper if one exists — read the file first and follow its idiom). Pass `keywords` into the returned `FITSHeader`.

- [ ] **Step 4: Run** `swift test --filter FITSReaderTests 2>&1 | tail -5` — expect PASS.
- [ ] **Step 5: Full suite** `swift test 2>&1 | grep "Executed"` — all pass.
- [ ] **Step 6: Commit** `feat: surface FITS header keywords (BAYERPAT, DATE-OBS)`

### Task 2: Bilinear full-res debayer

**Files:**
- Create: `Sources/LiveAstroCore/Stacking/Debayer.swift`
- Test: `Tests/LiveAstroCoreTests/DebayerTests.swift`

**Interfaces:**
- Produces: `Debayer.bilinear(cfa: AstroImage, pattern: BayerPattern) -> AstroImage` (3-channel, same width/height, `sourceIsLinear` preserved); `enum BayerPattern: String { case grbg = "GRBG", rggb = "RGGB" }` with `init?(headerValue: String?)` (case-insensitive, trims).
- Consumes: `AstroImage` (1-channel CFA in **stored** row order).

Algorithm: mask-normalized 3×3 convolution. For channel c: `out_c = conv(cfa·M_c, K_c) / conv(M_c, K_c)` where `M_c` is the CFA site mask, `K_G = [[0,1,0],[1,4,1],[0,1,0]]`, `K_R = K_B = [[1,2,1],[2,4,2],[1,2,1]]`. This reproduces classic bilinear demosaic in the interior and stays exact at edges (denominator shrinks with the mask). Site layout: GRBG ⇒ 2×2 = [G,R / B,G]; RGGB ⇒ [R,G / G,B].

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import LiveAstroCore

final class DebayerTests: XCTestCase {
    func testPatternParse() {
        XCTAssertEqual(BayerPattern(headerValue: " grbg "), .grbg)
        XCTAssertEqual(BayerPattern(headerValue: "RGGB"), .rggb)
        XCTAssertNil(BayerPattern(headerValue: "XTRANS"))
        XCTAssertNil(BayerPattern(headerValue: nil))
    }

    func testConstantCFAGivesConstantRGB() {
        let cfa = AstroImage(width: 6, height: 6, channels: 1,
                             pixels: [Float](repeating: 0.25, count: 36), sourceIsLinear: true)
        let rgb = Debayer.bilinear(cfa: cfa, pattern: .grbg)
        XCTAssertEqual(rgb.channels, 3)
        XCTAssertEqual(rgb.width, 6); XCTAssertEqual(rgb.height, 6)
        for v in rgb.pixels { XCTAssertEqual(v, 0.25, accuracy: 1e-6) }
    }

    func testGRBGSiteValuesPreserved() {
        // 4x4 CFA: distinct per-channel constants — R=0.8, G=0.4, B=0.2
        // GRBG rows: [G R G R], [B G B G], ...
        var px = [Float](repeating: 0, count: 16)
        for y in 0..<4 { for x in 0..<4 {
            let isR = (y % 2 == 0 && x % 2 == 1)
            let isB = (y % 2 == 1 && x % 2 == 0)
            px[y * 4 + x] = isR ? 0.8 : (isB ? 0.2 : 0.4)
        }}
        let rgb = Debayer.bilinear(cfa: AstroImage(width: 4, height: 4, channels: 1,
                                                   pixels: px, sourceIsLinear: true), pattern: .grbg)
        let plane = 16
        // Every output pixel of each channel equals that channel's constant
        for i in 0..<plane {
            XCTAssertEqual(rgb.pixels[i], 0.8, accuracy: 1e-5)             // R
            XCTAssertEqual(rgb.pixels[plane + i], 0.4, accuracy: 1e-5)     // G
            XCTAssertEqual(rgb.pixels[2 * plane + i], 0.2, accuracy: 1e-5) // B
        }
    }

    func testRGGBPhase() {
        // Single bright red site at (0,0) under RGGB — R channel peaks there
        var px = [Float](repeating: 0, count: 16)
        px[0] = 1.0
        let rgb = Debayer.bilinear(cfa: AstroImage(width: 4, height: 4, channels: 1,
                                                   pixels: px, sourceIsLinear: true), pattern: .rggb)
        XCTAssertEqual(rgb.pixels[0], 1.0, accuracy: 1e-5)      // R at its own site
        XCTAssertEqual(rgb.pixels[16], 0.0, accuracy: 1e-5)     // G(0,0) interpolates zero neighbors
    }
}
```

- [ ] **Step 2: Run** `swift test --filter DebayerTests 2>&1 | tail -4` — compile failure.

- [ ] **Step 3: Implement `Debayer.swift`**

```swift
import Foundation

public enum BayerPattern: String {
    case grbg = "GRBG"
    case rggb = "RGGB"

    public init?(headerValue: String?) {
        guard let v = headerValue?.trimmingCharacters(in: .whitespaces).uppercased(),
              let p = BayerPattern(rawValue: v) else { return nil }
        self = p
    }

    /// Channel at CFA site (row % 2, col % 2): 0 = R, 1 = G, 2 = B.
    func channel(row: Int, col: Int) -> Int {
        switch self {
        case .grbg: return (row % 2 == 0) ? (col % 2 == 0 ? 1 : 0) : (col % 2 == 0 ? 2 : 1)
        case .rggb: return (row % 2 == 0) ? (col % 2 == 0 ? 0 : 1) : (col % 2 == 0 ? 1 : 2)
        }
    }
}

/// Full-resolution bilinear demosaic (spec §3): mask-normalized 3×3 convolution,
/// exact at image edges because the kernel weight renormalizes with the mask.
public enum Debayer {
    public static func bilinear(cfa: AstroImage, pattern: BayerPattern) -> AstroImage {
        precondition(cfa.channels == 1, "CFA input must be single-channel")
        let w = cfa.width, h = cfa.height, plane = w * h
        // K weights by (dy+1, dx+1); G kernel is the cross, R/B the full 3×3.
        let kG: [Float] = [0, 1, 0, 1, 4, 1, 0, 1, 0]
        let kRB: [Float] = [1, 2, 1, 2, 4, 2, 1, 2, 1]
        var out = [Float](repeating: 0, count: plane * 3)
        cfa.pixels.withUnsafeBufferPointer { src in
            for y in 0..<h {
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
                        out[c * plane + y * w + x] = den > 0 ? num / den : 0
                    }
                }
            }
        }
        return AstroImage(width: w, height: h, channels: 3, pixels: out,
                          sourceIsLinear: cfa.sourceIsLinear)
    }
}
```

- [ ] **Step 4: Run** `swift test --filter DebayerTests 2>&1 | tail -4` — PASS.
- [ ] **Step 5: Full suite green; commit** `feat: bilinear full-res debayer (GRBG/RGGB)`

*(Performance note for the implementer: the naive loop is O(9·3·N). If Task 11's perf gate fails, specialize the inner loop per site-parity instead of testing the mask per tap — but do not pre-optimize now.)*

### Task 3: Star detector

**Files:**
- Create: `Sources/LiveAstroCore/Stacking/StarDetector.swift`
- Test: `Tests/LiveAstroCoreTests/StarDetectorTests.swift`

**Interfaces:**
- Produces: `struct Star { let x, y: Double; let flux: Double }`; `StarDetector.detect(luminance: [Float], width: Int, height: Int, maxStars: Int = 60, sigmaThreshold: Double = 5.0) -> [Star]` — flux-descending order, sub-pixel flux-weighted centroids.
- Consumes: plain luminance buffer (callers build it from CFA superpixels — see Task 8).

Algorithm: (1) tile the image into a grid of ~32×32-px cells; per cell compute median and MADN (1.4826·MAD); (2) per-pixel background/σ by bilinear interpolation between cell centers (clamp at borders); (3) threshold mask `pix > bg + kσ`; (4) 4-connected components via iterative flood fill (explicit stack, no recursion), min area 3 px, max area 400 px; (5) per component: flux = Σ(pix − bg), centroid = flux-weighted mean position; (6) sort by flux, return top N.

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import LiveAstroCore

final class StarDetectorTests: XCTestCase {
    /// Synthetic field: flat background + Gaussian stars at known sub-pixel positions.
    func makeField(width: Int = 256, height: Int = 256, background: Float = 0.05,
                   stars: [(x: Double, y: Double, amp: Float)]) -> [Float] {
        var px = [Float](repeating: background, count: width * height)
        for s in stars {
            for y in max(0, Int(s.y) - 6)...min(height - 1, Int(s.y) + 6) {
                for x in max(0, Int(s.x) - 6)...min(width - 1, Int(s.x) + 6) {
                    let dx = Double(x) - s.x, dy = Double(y) - s.y
                    px[y * width + x] += s.amp * Float(exp(-(dx * dx + dy * dy) / (2 * 1.5 * 1.5)))
                }
            }
        }
        return px
    }

    func testRecoversKnownPositions() {
        let truth: [(x: Double, y: Double, amp: Float)] =
            [(40.3, 60.7, 0.9), (200.5, 30.2, 0.7), (128.0, 128.0, 0.5), (60.8, 220.4, 0.3)]
        let field = makeField(stars: truth)
        let found = StarDetector.detect(luminance: field, width: 256, height: 256)
        XCTAssertEqual(found.count, 4)
        // flux-descending order matches amplitude order
        for (star, t) in zip(found, truth) {
            XCTAssertEqual(star.x, t.x, accuracy: 0.3)
            XCTAssertEqual(star.y, t.y, accuracy: 0.3)
        }
    }

    func testIgnoresHotPixels() {
        var field = makeField(stars: [(100.0, 100.0, 0.8)])
        field[50 * 256 + 50] = 1.0   // single hot pixel: area 1 < min area 3
        let found = StarDetector.detect(luminance: field, width: 256, height: 256)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].x, 100.0, accuracy: 0.3)
    }

    func testHandlesGradientBackground() {
        // Linear gradient 0.02...0.20 across x plus one star — grid background absorbs the gradient
        var field = makeField(stars: [(180.0, 90.0, 0.6)])
        for y in 0..<256 { for x in 0..<256 { field[y * 256 + x] += 0.18 * Float(x) / 255 } }
        let found = StarDetector.detect(luminance: field, width: 256, height: 256)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].x, 180.0, accuracy: 0.4)
    }

    func testEmptyFieldFindsNothing() {
        let field = [Float](repeating: 0.05, count: 256 * 256)
        XCTAssertEqual(StarDetector.detect(luminance: field, width: 256, height: 256).count, 0)
    }
}
```

- [ ] **Step 2: Run** `swift test --filter StarDetectorTests 2>&1 | tail -4` — compile failure.

- [ ] **Step 3: Implement `StarDetector.swift`**

```swift
import Foundation

public struct Star: Equatable {
    public let x: Double
    public let y: Double
    public let flux: Double
}

/// Threshold + connected-component star finder with grid-interpolated background
/// (spec §4.2). Deterministic, no randomness.
public enum StarDetector {
    public static func detect(luminance: [Float], width: Int, height: Int,
                              maxStars: Int = 60, sigmaThreshold: Double = 5.0) -> [Star] {
        precondition(luminance.count == width * height)
        let cell = 32
        let gw = max(1, (width + cell - 1) / cell), gh = max(1, (height + cell - 1) / cell)
        var bgGrid = [Float](repeating: 0, count: gw * gh)
        var sigGrid = [Float](repeating: 0, count: gw * gh)
        for gy in 0..<gh {
            for gx in 0..<gw {
                var vals: [Float] = []
                vals.reserveCapacity(cell * cell)
                for y in (gy * cell)..<min((gy + 1) * cell, height) {
                    for x in (gx * cell)..<min((gx + 1) * cell, width) {
                        vals.append(luminance[y * width + x])
                    }
                }
                vals.sort()
                let med = vals[vals.count / 2]
                var dev = vals.map { abs($0 - med) }
                dev.sort()
                bgGrid[gy * gw + gx] = med
                sigGrid[gy * gw + gx] = max(1.4826 * dev[dev.count / 2], 1e-6)
            }
        }
        // Bilinear grid interpolation at pixel (x, y): grid coords in cell-center space.
        func gridAt(_ grid: [Float], _ x: Int, _ y: Int) -> Float {
            let fx = (Float(x) - Float(cell) / 2) / Float(cell)
            let fy = (Float(y) - Float(cell) / 2) / Float(cell)
            let x0 = min(max(Int(floor(fx)), 0), gw - 1), y0 = min(max(Int(floor(fy)), 0), gh - 1)
            let x1 = min(x0 + 1, gw - 1), y1 = min(y0 + 1, gh - 1)
            let tx = min(max(fx - Float(x0), 0), 1), ty = min(max(fy - Float(y0), 0), 1)
            let a = grid[y0 * gw + x0] * (1 - tx) + grid[y0 * gw + x1] * tx
            let b = grid[y1 * gw + x0] * (1 - tx) + grid[y1 * gw + x1] * tx
            return a * (1 - ty) + b * ty
        }

        var mask = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                mask[i] = Double(luminance[i]) >
                    Double(gridAt(bgGrid, x, y)) + sigmaThreshold * Double(gridAt(sigGrid, x, y))
            }
        }

        var visited = [Bool](repeating: false, count: width * height)
        var stars: [Star] = []
        let minArea = 3, maxArea = 400
        for start in 0..<mask.count where mask[start] && !visited[start] {
            var stack = [start]
            visited[start] = true
            var member: [Int] = []
            while let i = stack.popLast() {
                member.append(i)
                let x = i % width, y = i / width
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let n = ny * width + nx
                    if mask[n] && !visited[n] { visited[n] = true; stack.append(n) }
                }
            }
            guard member.count >= minArea, member.count <= maxArea else { continue }
            var flux = 0.0, cx = 0.0, cy = 0.0
            for i in member {
                let x = i % width, y = i / width
                let f = Double(luminance[i] - gridAt(bgGrid, x, y))
                guard f > 0 else { continue }
                flux += f; cx += f * Double(x); cy += f * Double(y)
            }
            guard flux > 0 else { continue }
            stars.append(Star(x: cx / flux, y: cy / flux, flux: flux))
        }
        stars.sort { $0.flux > $1.flux }
        return Array(stars.prefix(maxStars))
    }
}
```

- [ ] **Step 4: Run** `swift test --filter StarDetectorTests 2>&1 | tail -4` — PASS.
- [ ] **Step 5: Full suite green; commit** `feat: grid-background star detector with sub-pixel centroids`

### Task 4: SimilarityTransform value type

**Files:**
- Create: `Sources/LiveAstroCore/Stacking/SimilarityTransform.swift`
- Test: `Tests/LiveAstroCoreTests/SimilarityTransformTests.swift`

**Interfaces:**
- Produces:

```swift
public struct SimilarityTransform: Equatable {
    public let scale: Double
    public let rotation: Double   // radians
    public let tx: Double
    public let ty: Double
    public static let identity: SimilarityTransform
    public func apply(x: Double, y: Double) -> (x: Double, y: Double)
    public func inverse() -> SimilarityTransform
    /// Lift a transform solved at half resolution to full resolution (spec §4.2):
    /// same scale/rotation; t_full = 2·t_half + (I − sR)·(0.5, 0.5).
    public func liftedToFullResolution() -> SimilarityTransform
}
```

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import LiveAstroCore

final class SimilarityTransformTests: XCTestCase {
    func testApplyKnownTransform() {
        // 90° rotation, scale 2, translate (10, -5): (1,0) -> s·(0,1) + t = (10, -3)
        let t = SimilarityTransform(scale: 2, rotation: .pi / 2, tx: 10, ty: -5)
        let p = t.apply(x: 1, y: 0)
        XCTAssertEqual(p.x, 10, accuracy: 1e-12)
        XCTAssertEqual(p.y, -3, accuracy: 1e-12)
    }

    func testInverseRoundTrip() {
        let t = SimilarityTransform(scale: 1.02, rotation: 0.03, tx: 14.5, ty: -8.25)
        let inv = t.inverse()
        for (x, y) in [(0.0, 0.0), (100.0, 50.0), (-3.5, 999.0)] {
            let q = t.apply(x: x, y: y)
            let back = inv.apply(x: q.x, y: q.y)
            XCTAssertEqual(back.x, x, accuracy: 1e-9)
            XCTAssertEqual(back.y, y, accuracy: 1e-9)
        }
    }

    func testLiftExactness() {
        // Half-res point p maps to q; full-res point (2p+0.5) must map to (2q+0.5).
        let t = SimilarityTransform(scale: 0.998, rotation: 0.05, tx: 3.2, ty: -1.7)
        let lifted = t.liftedToFullResolution()
        for (x, y) in [(10.0, 20.0), (500.25, 301.5)] {
            let q = t.apply(x: x, y: y)
            let full = lifted.apply(x: 2 * x + 0.5, y: 2 * y + 0.5)
            XCTAssertEqual(full.x, 2 * q.x + 0.5, accuracy: 1e-9)
            XCTAssertEqual(full.y, 2 * q.y + 0.5, accuracy: 1e-9)
        }
    }
}
```

- [ ] **Step 2: Run** `swift test --filter SimilarityTransformTests 2>&1 | tail -4` — compile failure.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// 2-D similarity transform y = s·R(θ)·x + t (spec §3: alignment model).
public struct SimilarityTransform: Equatable {
    public let scale: Double
    public let rotation: Double
    public let tx: Double
    public let ty: Double

    public init(scale: Double, rotation: Double, tx: Double, ty: Double) {
        self.scale = scale; self.rotation = rotation; self.tx = tx; self.ty = ty
    }

    public static let identity = SimilarityTransform(scale: 1, rotation: 0, tx: 0, ty: 0)

    public func apply(x: Double, y: Double) -> (x: Double, y: Double) {
        let c = cos(rotation) * scale, s = sin(rotation) * scale
        return (c * x - s * y + tx, s * x + c * y + ty)
    }

    public func inverse() -> SimilarityTransform {
        let invScale = 1 / scale
        let invRot = -rotation
        let c = cos(invRot) * invScale, s = sin(invRot) * invScale
        return SimilarityTransform(scale: invScale, rotation: invRot,
                                   tx: -(c * tx - s * ty), ty: -(s * tx + c * ty))
    }

    public func liftedToFullResolution() -> SimilarityTransform {
        let c = cos(rotation) * scale, s = sin(rotation) * scale
        // t_full = 2t + (I − sR)·(0.5, 0.5)
        let txF = 2 * tx + 0.5 - (c * 0.5 - s * 0.5)
        let tyF = 2 * ty + 0.5 - (s * 0.5 + c * 0.5)
        return SimilarityTransform(scale: scale, rotation: rotation, tx: txF, ty: tyF)
    }
}
```

- [ ] **Step 4: Run** `swift test --filter SimilarityTransformTests 2>&1 | tail -4` — PASS.
- [ ] **Step 5: Full suite green; commit** `feat: SimilarityTransform value type with inverse and half-to-full-res lift`

### Task 5: Triangle matcher

**Files:**
- Create: `Sources/LiveAstroCore/Stacking/TriangleMatcher.swift`
- Test: `Tests/LiveAstroCoreTests/TriangleMatcherTests.swift`

**Interfaces:**
- Produces: `TriangleMatcher.correspondences(source: [Star], target: [Star], maxTriangleStars: Int = 20, invariantTolerance: Double = 0.02, minVotes: Int = 2) -> [(source: Int, target: Int)]` — index pairs into the input arrays, vote-descending.
- Consumes: `Star` from Task 3.

Algorithm (astroalign family, clean-room): take the `maxTriangleStars` brightest of each set; form all C(n,3) triangles; per triangle compute side lengths sorted `L1 ≤ L2 ≤ L3` and the invariant pair `(L2/L1, L3/L2)`; skip degenerate triangles (`L1 < 4` px or collinear: invariant components > 20). Match triangles across images when both invariant components differ by < `invariantTolerance` (relative). Each triangle match votes for 3 vertex pairs, where vertices are identified by the rank of their **opposite** side. Correspondences with ≥ `minVotes` votes are returned, ties broken by vote count descending then source index.

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import LiveAstroCore

final class TriangleMatcherTests: XCTestCase {
    func stars(_ pts: [(Double, Double)]) -> [Star] {
        pts.enumerated().map { Star(x: $1.0, y: $1.1, flux: Double(100 - $0)) }
    }

    func testExactCorrespondenceUnderSimilarity() {
        let src = stars([(10, 10), (200, 40), (60, 180), (150, 150), (30, 90), (220, 200)])
        let t = SimilarityTransform(scale: 1.01, rotation: 0.04, tx: 12, ty: -7)
        let dst = src.map { s -> Star in
            let p = t.apply(x: s.x, y: s.y); return Star(x: p.x, y: p.y, flux: s.flux)
        }
        let pairs = TriangleMatcher.correspondences(source: src, target: dst)
        XCTAssertGreaterThanOrEqual(pairs.count, 5)
        for p in pairs { XCTAssertEqual(p.source, p.target) }   // same ordering by construction
    }

    func testRobustToSpuriousAndMissingStars() {
        let src = stars([(10, 10), (200, 40), (60, 180), (150, 150), (30, 90), (220, 200), (120, 60)])
        var dstPts: [(Double, Double)] = [(10, 10), (200, 40), (60, 180), (150, 150), (30, 90)]
        dstPts.append((300, 300))   // spurious star not in source
        let dst = stars(dstPts)
        let pairs = TriangleMatcher.correspondences(source: src, target: dst)
        XCTAssertGreaterThanOrEqual(pairs.count, 4)
        for p in pairs where p.target < 5 { XCTAssertEqual(p.source, p.target) }
        XCTAssertFalse(pairs.contains { $0.target == 5 })   // spurious star matched nothing
    }

    func testTooFewStarsReturnsEmpty() {
        XCTAssertTrue(TriangleMatcher.correspondences(
            source: stars([(1, 1), (2, 2)]), target: stars([(1, 1), (2, 2), (3, 1)])).isEmpty)
    }
}
```

- [ ] **Step 2: Run** `swift test --filter TriangleMatcherTests 2>&1 | tail -4` — compile failure.

- [ ] **Step 3: Implement `TriangleMatcher.swift`**

```swift
import Foundation

/// Triangle-invariant star matching (spec §4.2). Clean-room implementation of the
/// classic method: triangles are similarity-invariant, so matching side-ratio
/// signatures across images yields vertex correspondences without initial alignment.
public enum TriangleMatcher {
    struct Triangle {
        let vertices: (Int, Int, Int)   // star indices ordered by opposite-side rank:
                                        // .0 opposite shortest, .2 opposite longest
        let invariant: (Double, Double) // (L2/L1, L3/L2), L1 ≤ L2 ≤ L3
    }

    static func triangles(_ stars: [Star], maxStars: Int) -> [Triangle] {
        let n = min(stars.count, maxStars)
        guard n >= 3 else { return [] }
        var out: [Triangle] = []
        for i in 0..<(n - 2) {
            for j in (i + 1)..<(n - 1) {
                for k in (j + 1)..<n {
                    func dist(_ a: Int, _ b: Int) -> Double {
                        let dx = stars[a].x - stars[b].x, dy = stars[a].y - stars[b].y
                        return (dx * dx + dy * dy).squareRoot()
                    }
                    // side opposite each vertex
                    let sides = [(dist(j, k), i), (dist(i, k), j), (dist(i, j), k)]
                        .sorted { $0.0 < $1.0 }
                    let (l1, l2, l3) = (sides[0].0, sides[1].0, sides[2].0)
                    guard l1 > 4 else { continue }                    // degenerate / same blob
                    let inv = (l2 / l1, l3 / l2)
                    guard inv.0 < 20, inv.1 < 20 else { continue }    // near-collinear
                    out.append(Triangle(vertices: (sides[0].1, sides[1].1, sides[2].1),
                                        invariant: inv))
                }
            }
        }
        return out
    }

    public static func correspondences(source: [Star], target: [Star],
                                       maxTriangleStars: Int = 20,
                                       invariantTolerance: Double = 0.02,
                                       minVotes: Int = 2) -> [(source: Int, target: Int)] {
        let ts = triangles(source, maxStars: maxTriangleStars)
        let tt = triangles(target, maxStars: maxTriangleStars)
        guard !ts.isEmpty, !tt.isEmpty else { return [] }
        var votes: [Int: Int] = [:]   // key = srcIdx * 4096 + dstIdx
        for a in ts {
            for b in tt {
                let r1 = abs(a.invariant.0 - b.invariant.0) / max(a.invariant.0, 1e-9)
                let r2 = abs(a.invariant.1 - b.invariant.1) / max(a.invariant.1, 1e-9)
                guard r1 < invariantTolerance, r2 < invariantTolerance else { continue }
                for (sv, tv) in [(a.vertices.0, b.vertices.0),
                                 (a.vertices.1, b.vertices.1),
                                 (a.vertices.2, b.vertices.2)] {
                    votes[sv * 4096 + tv, default: 0] += 1
                }
            }
        }
        // Greedy one-to-one assignment by vote count.
        let ranked = votes.filter { $0.value >= minVotes }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var usedS = Set<Int>(), usedT = Set<Int>()
        var out: [(source: Int, target: Int)] = []
        for (key, _) in ranked {
            let s = key / 4096, t = key % 4096
            guard !usedS.contains(s), !usedT.contains(t) else { continue }
            usedS.insert(s); usedT.insert(t)
            out.append((source: s, target: t))
        }
        return out
    }
}
```

- [ ] **Step 4: Run** `swift test --filter TriangleMatcherTests 2>&1 | tail -4` — PASS.
- [ ] **Step 5: Full suite green; commit** `feat: triangle-invariant star correspondence matching`

### Task 6: RANSAC transform solver

**Files:**
- Create: `Sources/LiveAstroCore/Stacking/TransformSolver.swift`
- Test: `Tests/LiveAstroCoreTests/TransformSolverTests.swift`

**Interfaces:**
- Produces: `TransformSolver.solve(source: [Star], target: [Star], pairs: [(source: Int, target: Int)], minMatches: Int = 8, inlierTolerance: Double = 2.0, iterations: Int = 500, seed: UInt64 = 0x5EED) -> SimilarityTransform?` — nil when no transform reaches `minMatches` inliers. Deterministic (seeded LCG, same idiom as fakesiril).
- Consumes: `Star`, `SimilarityTransform`, matcher pairs from Task 5.

Least-squares similarity fit (Umeyama closed form) over point pairs `(pᵢ → qᵢ)`: demean both sets; `a = Σ(xᵢ·uᵢ + yᵢ·vᵢ)`, `b = Σ(xᵢ·vᵢ − yᵢ·uᵢ)`, `d = Σ|pᵢ−p̄|²`; `s = √(a²+b²)/d`, `θ = atan2(b, a)`, `t = q̄ − sR·p̄`. RANSAC: sample 2 distinct pairs, fit, count inliers under `inlierTolerance`; keep the best; final refit on all inliers of the best model; require ≥ `minMatches` inliers.

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import LiveAstroCore

final class TransformSolverTests: XCTestCase {
    let truth = SimilarityTransform(scale: 1.003, rotation: 0.021, tx: 8.4, ty: -3.9)

    func makePairs(n: Int, outliers: Int = 0) -> (src: [Star], dst: [Star], pairs: [(source: Int, target: Int)]) {
        var seed: UInt64 = 42
        func rand() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(UInt32.max)
        }
        var src: [Star] = [], dst: [Star] = [], pairs: [(source: Int, target: Int)] = []
        for i in 0..<n {
            let x = rand() * 900, y = rand() * 500
            src.append(Star(x: x, y: y, flux: 1))
            let q = truth.apply(x: x, y: y)
            let isOutlier = i < outliers
            dst.append(Star(x: q.x + (isOutlier ? 80 + rand() * 50 : (rand() - 0.5) * 0.6),
                            y: q.y + (isOutlier ? -60 - rand() * 40 : (rand() - 0.5) * 0.6), flux: 1))
            pairs.append((source: i, target: i))
        }
        return (src, dst, pairs)
    }

    func testExactRecoveryFromCleanPairs() throws {
        let (src, dst, pairs) = makePairs(n: 20)
        let t = try XCTUnwrap(TransformSolver.solve(source: src, target: dst, pairs: pairs))
        XCTAssertEqual(t.rotation, truth.rotation, accuracy: 0.1 * .pi / 180)   // 0.1°
        XCTAssertEqual(t.scale, truth.scale, accuracy: 1e-3)
        XCTAssertEqual(t.tx, truth.tx, accuracy: 0.5)
        XCTAssertEqual(t.ty, truth.ty, accuracy: 0.5)
    }

    func testRobustToThirtyPercentOutliers() throws {
        let (src, dst, pairs) = makePairs(n: 20, outliers: 6)
        let t = try XCTUnwrap(TransformSolver.solve(source: src, target: dst, pairs: pairs))
        XCTAssertEqual(t.rotation, truth.rotation, accuracy: 0.1 * .pi / 180)
        XCTAssertEqual(t.tx, truth.tx, accuracy: 0.5)
    }

    func testNilWhenTooFewInliers() {
        let (src, dst, pairs) = makePairs(n: 7)   // 7 < minMatches 8
        XCTAssertNil(TransformSolver.solve(source: src, target: dst, pairs: pairs))
    }

    func testDeterministic() {
        let (src, dst, pairs) = makePairs(n: 20, outliers: 4)
        let a = TransformSolver.solve(source: src, target: dst, pairs: pairs)
        let b = TransformSolver.solve(source: src, target: dst, pairs: pairs)
        XCTAssertEqual(a, b)
    }
}
```

- [ ] **Step 2: Run** `swift test --filter TransformSolverTests 2>&1 | tail -4` — compile failure.

- [ ] **Step 3: Implement `TransformSolver.swift`**

```swift
import Foundation

/// RANSAC similarity-transform estimation over matched star pairs (spec §4.2).
public enum TransformSolver {
    /// Closed-form least-squares similarity fit (Umeyama) over the given pair indices.
    static func fit(source: [Star], target: [Star],
                    pairs: ArraySlice<(source: Int, target: Int)>) -> SimilarityTransform? {
        let n = Double(pairs.count)
        guard pairs.count >= 2 else { return nil }
        var pcx = 0.0, pcy = 0.0, qcx = 0.0, qcy = 0.0
        for pr in pairs {
            pcx += source[pr.source].x; pcy += source[pr.source].y
            qcx += target[pr.target].x; qcy += target[pr.target].y
        }
        pcx /= n; pcy /= n; qcx /= n; qcy /= n
        var a = 0.0, b = 0.0, d = 0.0
        for pr in pairs {
            let x = source[pr.source].x - pcx, y = source[pr.source].y - pcy
            let u = target[pr.target].x - qcx, v = target[pr.target].y - qcy
            a += x * u + y * v
            b += x * v - y * u
            d += x * x + y * y
        }
        guard d > 1e-9 else { return nil }
        let scale = (a * a + b * b).squareRoot() / d
        guard scale > 1e-6 else { return nil }
        let rotation = atan2(b, a)
        let c = cos(rotation) * scale, s = sin(rotation) * scale
        return SimilarityTransform(scale: scale, rotation: rotation,
                                   tx: qcx - (c * pcx - s * pcy),
                                   ty: qcy - (s * pcx + c * pcy))
    }

    static func inliers(_ t: SimilarityTransform, source: [Star], target: [Star],
                        pairs: [(source: Int, target: Int)], tolerance: Double) -> [(source: Int, target: Int)] {
        pairs.filter { pr in
            let q = t.apply(x: source[pr.source].x, y: source[pr.source].y)
            let dx = q.x - target[pr.target].x, dy = q.y - target[pr.target].y
            return (dx * dx + dy * dy).squareRoot() < tolerance
        }
    }

    public static func solve(source: [Star], target: [Star],
                             pairs: [(source: Int, target: Int)],
                             minMatches: Int = 8, inlierTolerance: Double = 2.0,
                             iterations: Int = 500, seed: UInt64 = 0x5EED) -> SimilarityTransform? {
        guard pairs.count >= minMatches else { return nil }
        var rng = seed
        func randIndex(_ bound: Int) -> Int {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Int(rng >> 33) % bound
        }
        var best: [(source: Int, target: Int)] = []
        for _ in 0..<iterations {
            let i = randIndex(pairs.count)
            var j = randIndex(pairs.count)
            if j == i { j = (j + 1) % pairs.count }
            guard let candidate = fit(source: source, target: target, pairs: [pairs[i], pairs[j]][...])
            else { continue }
            let ins = inliers(candidate, source: source, target: target,
                              pairs: pairs, tolerance: inlierTolerance)
            if ins.count > best.count { best = ins }
        }
        guard best.count >= minMatches,
              let refined = fit(source: source, target: target, pairs: best[...])
        else { return nil }
        return refined
    }
}
```

- [ ] **Step 4: Run** `swift test --filter TransformSolverTests 2>&1 | tail -4` — PASS.
- [ ] **Step 5: Full suite green; commit** `feat: RANSAC similarity solver (Umeyama closed-form fit)`

### Task 7: Warp (inverse-mapped bilinear resample)

**Files:**
- Create: `Sources/LiveAstroCore/Stacking/Warp.swift`
- Test: `Tests/LiveAstroCoreTests/WarpTests.swift`

**Interfaces:**
- Produces: `Warp.apply(_ image: AstroImage, transform: SimilarityTransform) -> (image: AstroImage, mask: [Float])` — output pixel `(x,y)` sampled from `transform.inverse().apply(x,y)`; `mask` is `width·height` floats — binary source-in-bounds indicator (1 where all bilinear taps are inside the source, 0 otherwise; the ~1 px partially-covered rim is deliberately dropped). Multi-channel supported.
- Consumes: `SimilarityTransform` from Task 4.

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import LiveAstroCore

final class WarpTests: XCTestCase {
    func ramp(w: Int, h: Int) -> AstroImage {
        var px = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { px[y * w + x] = Float(x) / Float(w) } }
        return AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true)
    }

    func testIdentityIsExact() {
        let img = ramp(w: 16, h: 12)
        let (out, mask) = Warp.apply(img, transform: .identity)
        for i in 0..<img.pixels.count {
            XCTAssertEqual(out.pixels[i], img.pixels[i], accuracy: 1e-6)
            XCTAssertEqual(mask[i], 1.0, accuracy: 1e-6)
        }
    }

    func testIntegerTranslation() {
        let img = ramp(w: 16, h: 12)
        let (out, mask) = Warp.apply(img, transform: SimilarityTransform(scale: 1, rotation: 0, tx: 3, ty: 0))
        // out(x,y) = in(x-3,y): column 5 of output equals column 2 of input
        XCTAssertEqual(out.pixels[5], img.pixels[2], accuracy: 1e-6)
        // columns 0..2 have no source — masked out
        XCTAssertEqual(mask[0], 0.0, accuracy: 1e-6)
        XCTAssertEqual(mask[2], 0.0, accuracy: 1e-6)
        XCTAssertEqual(mask[3], 1.0, accuracy: 1e-6)
    }

    func testHalfPixelTranslationInterpolates() {
        let img = ramp(w: 16, h: 12)
        let (out, _) = Warp.apply(img, transform: SimilarityTransform(scale: 1, rotation: 0, tx: 0.5, ty: 0))
        // out(5,0) = in(4.5,0) = mean of columns 4 and 5
        let expected = (img.pixels[4] + img.pixels[5]) / 2
        XCTAssertEqual(out.pixels[5], expected, accuracy: 1e-6)
    }

    func testThreeChannelWarpsAllPlanes() {
        let w = 8, h = 8, plane = 64
        var px = [Float](repeating: 0, count: plane * 3)
        for c in 0..<3 { for i in 0..<plane { px[c * plane + i] = Float(c) * 0.3 } }
        let img = AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
        let (out, _) = Warp.apply(img, transform: SimilarityTransform(scale: 1, rotation: 0, tx: 1, ty: 1))
        for c in 0..<3 {
            XCTAssertEqual(out.pixels[c * plane + 3 * w + 3], Float(c) * 0.3, accuracy: 1e-6)
        }
    }
}
```

- [ ] **Step 2: Run** `swift test --filter WarpTests 2>&1 | tail -4` — compile failure.

- [ ] **Step 3: Implement `Warp.swift`**

```swift
import Foundation

/// Inverse-mapped bilinear warp with coverage mask (spec §4.2). The mask lets the
/// accumulator weight partial-overlap edges correctly instead of averaging in zeros.
public enum Warp {
    public static func apply(_ image: AstroImage,
                             transform: SimilarityTransform) -> (image: AstroImage, mask: [Float]) {
        let w = image.width, h = image.height, plane = w * h
        let inv = transform.inverse()
        var out = [Float](repeating: 0, count: image.pixels.count)
        var mask = [Float](repeating: 0, count: plane)
        image.pixels.withUnsafeBufferPointer { src in
            for y in 0..<h {
                for x in 0..<w {
                    let p = inv.apply(x: Double(x), y: Double(y))
                    let x0 = Int(floor(p.x)), y0 = Int(floor(p.y))
                    guard x0 >= 0, y0 >= 0, x0 < w - 1 || (x0 == w - 1 && p.x == Double(w - 1)),
                          y0 < h - 1 || (y0 == h - 1 && p.y == Double(h - 1)) else { continue }
                    let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
                    let tx = Float(p.x - Double(x0)), ty = Float(p.y - Double(y0))
                    let w00 = (1 - tx) * (1 - ty), w01 = tx * (1 - ty)
                    let w10 = (1 - tx) * ty, w11 = tx * ty
                    for c in 0..<image.channels {
                        let base = c * plane
                        out[base + y * w + x] =
                            w00 * src[base + y0 * w + x0] + w01 * src[base + y0 * w + x1] +
                            w10 * src[base + y1 * w + x0] + w11 * src[base + y1 * w + x1]
                    }
                    mask[y * w + x] = 1
                }
            }
        }
        let img = AstroImage(width: w, height: h, channels: image.channels,
                             pixels: out, sourceIsLinear: image.sourceIsLinear)
        return (img, mask)
    }
}
```

- [ ] **Step 4: Run** `swift test --filter WarpTests 2>&1 | tail -4` — PASS.
- [ ] **Step 5: Full suite green; commit** `feat: bilinear inverse warp with coverage mask`

*(If Task 12's perf gate fails on 26 MP warps, port the inner loop to vImage — `vImageAffineWarp_PlanarF` per plane with the same transform — behind the identical function signature. Not before.)*

### Task 8: Accumulator + StackEngine

**Files:**
- Create: `Sources/LiveAstroCore/Stacking/StackAccumulator.swift`
- Create: `Sources/LiveAstroCore/Stacking/StackEngine.swift`
- Test: `Tests/LiveAstroCoreTests/StackEngineTests.swift`

**Interfaces:**
- Produces:

```swift
public final class StackAccumulator {
    public init(width: Int, height: Int, channels: Int)
    public func add(_ image: AstroImage, mask: [Float])   // mask all-1s for the seed frame
    public var frameCount: Int { get }
    public func mean() -> AstroImage                       // sum/weight where weight>0, else 0
}

public enum StackOutcome: Equatable {
    case becameReference
    case stacked(frameCount: Int)
    case rejected(RejectionReason)
}
public enum RejectionReason: Equatable {
    case insufficientStars(found: Int)
    case noTransform
    case dimensionMismatch
}

public final class StackEngine {
    public init(seedMinStars: Int = 15, minMatches: Int = 8, inlierTolerance: Double = 2.0)
    public private(set) var acceptedCount: Int
    public private(set) var rejectedCount: Int
    public func process(_ frame: RawFrame) -> StackOutcome
    public func currentStack() -> AstroImage?              // display orientation (top-down)
    public func reseed()
}
```

- Consumes: everything from Tasks 2–7 plus `RawFrame` from Task 9 — **to keep this task self-contained, define `RawFrame` here** in `Sources/LiveAstroCore/Sources/FrameSource.swift` (create the file with just the struct; Task 9 adds the protocol beside it):

```swift
import Foundation

/// One raw (pre-debayer, stored row order) frame from any source (spec §4.1).
public struct RawFrame {
    public let image: AstroImage          // 1-channel CFA or mono, stored row order
    public let bayerPattern: BayerPattern?
    public let bottomUp: Bool             // FITS ROWORDER
    public let timestamp: Date
    public let sourceName: String

    public init(image: AstroImage, bayerPattern: BayerPattern?, bottomUp: Bool,
                timestamp: Date, sourceName: String) {
        self.image = image; self.bayerPattern = bayerPattern; self.bottomUp = bottomUp
        self.timestamp = timestamp; self.sourceName = sourceName
    }
}
```

Engine flow per frame (spec §4.2): (1) dimensions must match the reference once seeded, else `.rejected(.dimensionMismatch)`; (2) build half-res superpixel luminance **from the CFA in stored order** (`lum[i,j] = (p[2i,2j] + p[2i,2j+1] + p[2i+1,2j] + p[2i+1,2j+1]) / 4`; for mono frames, 2×2 block mean); (3) detect stars; if unseeded: seed when `stars.count ≥ seedMinStars` (debayer full-res, flip to top-down if `bottomUp`, accumulate with all-1s mask, store reference stars, return `.becameReference`), else `.rejected(.insufficientStars)`; (4) seeded: match + solve against reference stars; nil transform → `.rejected(.noTransform)`; (5) debayer full-res, flip to top-down if `bottomUp`, **lift the half-res transform** with `liftedToFullResolution()`, warp, accumulate with the warp mask, return `.stacked`.

**Orientation invariant:** the luminance used for star detection must be flipped to top-down the same way as the accumulated full-res image (flip CFA-luminance rows when `bottomUp`), so reference stars and warped frames share one coordinate frame. Debayer ALWAYS runs on stored-order CFA before any flip; the flip applies to the debayered RGB (and to the luminance array), never to the CFA.

- [ ] **Step 1: Write failing tests.** Test strategy: synthesize CFA frames of a star field (reuse the Gaussian-field generator idea from StarDetectorTests but paint stars into a GRBG mosaic: per pixel, the star luminance value lands in whichever channel the CFA site holds, with G twice as sensitive as R/B is unnecessary — just paint identical values into all sites so debayered RGB is gray). Frames: reference + a translated copy (`tx=4.6, ty=-2.2` full-res) + a rotated copy (0.3°) + a starless (flat) frame.

```swift
import XCTest
@testable import LiveAstroCore

final class StackEngineTests: XCTestCase {
    /// Gray CFA starfield: same value at every CFA site → debayer yields R≈G≈B.
    func cfaFrame(width: Int = 512, height: Int = 512,
                  stars: [(x: Double, y: Double)], amp: Float = 0.8,
                  name: String = "test.fit") -> RawFrame {
        var px = [Float](repeating: 0.05, count: width * height)
        for s in stars {
            for y in max(0, Int(s.y) - 8)...min(height - 1, Int(s.y) + 8) {
                for x in max(0, Int(s.x) - 8)...min(width - 1, Int(s.x) + 8) {
                    let dx = Double(x) - s.x, dy = Double(y) - s.y
                    px[y * width + x] += amp * Float(exp(-(dx * dx + dy * dy) / (2 * 3.0 * 3.0)))
                }
            }
        }
        let img = AstroImage(width: width, height: height, channels: 1, pixels: px, sourceIsLinear: true)
        return RawFrame(image: img, bayerPattern: .grbg, bottomUp: false,
                        timestamp: Date(timeIntervalSince1970: 0), sourceName: name)
    }

    let field: [(x: Double, y: Double)] = [
        (60.2, 80.5), (400.7, 90.1), (200.3, 300.9), (350.5, 420.2), (100.8, 380.4),
        (250.1, 150.6), (450.3, 250.8), (80.9, 200.2), (320.4, 60.7), (180.6, 460.3),
        (420.2, 380.5), (140.7, 120.9), (280.8, 400.1), (380.1, 160.3), (60.5, 300.7),
        (460.6, 460.9), (240.2, 240.4), (120.3, 40.6), (40.7, 440.8), (340.9, 340.2),
    ]

    func testSeedsOnFirstStarryFrame() {
        let engine = StackEngine()
        XCTAssertEqual(engine.process(cfaFrame(stars: [])), .rejected(.insufficientStars(found: 0)))
        XCTAssertEqual(engine.process(cfaFrame(stars: field)), .becameReference)
        XCTAssertEqual(engine.acceptedCount, 1)
        XCTAssertEqual(engine.rejectedCount, 1)
    }

    func testStacksTranslatedFrame() {
        let engine = StackEngine()
        XCTAssertEqual(engine.process(cfaFrame(stars: field)), .becameReference)
        let shifted = field.map { (x: $0.x + 4.6, y: $0.y - 2.2) }
        XCTAssertEqual(engine.process(cfaFrame(stars: shifted)), .stacked(frameCount: 2))
        // Stack keeps stars at REFERENCE positions: local max near (60.2, 80.5)
        let stack = engine.currentStack()!
        let plane = stack.width * stack.height
        let lum = { (x: Int, y: Int) -> Float in
            (0..<stack.channels).reduce(Float(0)) { $0 + stack.pixels[$1 * plane + y * stack.width + x] }
        }
        XCTAssertGreaterThan(lum(60, 80), lum(65, 78) + 0.0)   // peak stayed put (not doubled/moved)
        XCTAssertGreaterThan(lum(60, 80), 0.5)
    }

    func testRejectsStarlessFrameAfterSeeding() {
        let engine = StackEngine()
        _ = engine.process(cfaFrame(stars: field))
        let outcome = engine.process(cfaFrame(stars: []))
        XCTAssertEqual(outcome, .rejected(.insufficientStars(found: 0)))
        XCTAssertEqual(engine.rejectedCount, 1)
    }

    func testReseedRestarts() {
        let engine = StackEngine()
        _ = engine.process(cfaFrame(stars: field))
        _ = engine.process(cfaFrame(stars: field))
        engine.reseed()
        XCTAssertNil(engine.currentStack())
        XCTAssertEqual(engine.process(cfaFrame(stars: field)), .becameReference)
    }

    func testDimensionMismatchRejected() {
        let engine = StackEngine()
        _ = engine.process(cfaFrame(stars: field))
        let small = cfaFrame(width: 256, height: 256, stars: [(100, 100), (50, 200), (200, 60)])
        XCTAssertEqual(engine.process(small), .rejected(.dimensionMismatch))
    }

    func testBottomUpFrameFlipped() {
        // Same field delivered bottom-up must land at flipped y in the stack
        let engine = StackEngine()
        let f = cfaFrame(stars: field)
        let flipped = RawFrame(image: f.image, bayerPattern: .grbg, bottomUp: true,
                               timestamp: f.timestamp, sourceName: f.sourceName)
        _ = engine.process(flipped)
        let stack = engine.currentStack()!
        let plane = stack.width * stack.height
        // star at stored (60.2, 80.5) appears near y = 512 − 1 − 80 in display orientation
        let yFlip = 512 - 1 - 80
        XCTAssertGreaterThan(stack.pixels[plane + yFlip * 512 + 60], 0.3)   // G channel
    }
}
```

- [ ] **Step 2: Run** `swift test --filter StackEngineTests 2>&1 | tail -4` — compile failure.

- [ ] **Step 3: Implement `StackAccumulator.swift`**

```swift
import Foundation

/// Weighted incremental mean stack (spec §3): per-pixel Float32 sum + weight.
public final class StackAccumulator {
    private var sum: [Float]
    private var weight: [Float]
    private let width: Int, height: Int, channels: Int
    public private(set) var frameCount = 0

    public init(width: Int, height: Int, channels: Int) {
        self.width = width; self.height = height; self.channels = channels
        sum = [Float](repeating: 0, count: width * height * channels)
        weight = [Float](repeating: 0, count: width * height)
    }

    public func add(_ image: AstroImage, mask: [Float]) {
        precondition(image.width == width && image.height == height && image.channels == channels)
        let plane = width * height
        for i in 0..<plane {
            let m = mask[i]
            guard m > 0 else { continue }
            weight[i] += m
            for c in 0..<channels { sum[c * plane + i] += m * image.pixels[c * plane + i] }
        }
        frameCount += 1
    }

    public func mean() -> AstroImage {
        let plane = width * height
        var out = [Float](repeating: 0, count: sum.count)
        for i in 0..<plane where weight[i] > 0 {
            for c in 0..<channels { out[c * plane + i] = sum[c * plane + i] / weight[i] }
        }
        return AstroImage(width: width, height: height, channels: channels,
                          pixels: out, sourceIsLinear: true)
    }
}
```

- [ ] **Step 4: Implement `StackEngine.swift`**

```swift
import Foundation

public enum StackOutcome: Equatable {
    case becameReference
    case stacked(frameCount: Int)
    case rejected(RejectionReason)
}

public enum RejectionReason: Equatable {
    case insufficientStars(found: Int)
    case noTransform
    case dimensionMismatch
}

/// Native stacking core (spec §4.2): registration on half-res superpixel luminance,
/// full-res accumulation. Rejection is registration-failure only (spec §3).
public final class StackEngine {
    private let seedMinStars: Int
    private let minMatches: Int
    private let inlierTolerance: Double
    private var accumulator: StackAccumulator?
    private var referenceStars: [Star] = []
    private var referenceSize: (w: Int, h: Int)?
    public private(set) var acceptedCount = 0
    public private(set) var rejectedCount = 0

    public init(seedMinStars: Int = 15, minMatches: Int = 8, inlierTolerance: Double = 2.0) {
        self.seedMinStars = seedMinStars
        self.minMatches = minMatches
        self.inlierTolerance = inlierTolerance
    }

    public func reseed() {
        accumulator = nil
        referenceStars = []
        referenceSize = nil
    }

    public func currentStack() -> AstroImage? { accumulator?.mean() }

    public func process(_ frame: RawFrame) -> StackOutcome {
        let raw = frame.image
        if let size = referenceSize, size != (raw.width, raw.height) {
            rejectedCount += 1
            return .rejected(.dimensionMismatch)
        }
        // Half-res superpixel luminance in DISPLAY orientation (flip rows if bottom-up).
        let hw = raw.width / 2, hh = raw.height / 2
        var lum = [Float](repeating: 0, count: hw * hh)
        raw.pixels.withUnsafeBufferPointer { p in
            for j in 0..<hh {
                let srcRow = frame.bottomUp ? (hh - 1 - j) : j
                for i in 0..<hw {
                    let r0 = 2 * srcRow * raw.width + 2 * i
                    let r1 = r0 + raw.width
                    lum[j * hw + i] = (p[r0] + p[r0 + 1] + p[r1] + p[r1 + 1]) / 4
                }
            }
        }
        let stars = StarDetector.detect(luminance: lum, width: hw, height: hh)

        if referenceSize == nil {
            guard stars.count >= seedMinStars else {
                rejectedCount += 1
                return .rejected(.insufficientStars(found: stars.count))
            }
            let rgb = displayRGB(frame)
            let acc = StackAccumulator(width: rgb.width, height: rgb.height, channels: rgb.channels)
            acc.add(rgb, mask: [Float](repeating: 1, count: rgb.width * rgb.height))
            accumulator = acc
            referenceStars = stars
            referenceSize = (raw.width, raw.height)
            acceptedCount += 1
            return .becameReference
        }

        guard stars.count >= 3 else {
            rejectedCount += 1
            return .rejected(.insufficientStars(found: stars.count))
        }
        let pairs = TriangleMatcher.correspondences(source: stars, target: referenceStars)
        guard let half = TransformSolver.solve(source: stars, target: referenceStars, pairs: pairs,
                                               minMatches: minMatches, inlierTolerance: inlierTolerance)
        else {
            rejectedCount += 1
            return .rejected(.noTransform)
        }
        let rgb = displayRGB(frame)
        let (warped, mask) = Warp.apply(rgb, transform: half.liftedToFullResolution())
        accumulator!.add(warped, mask: mask)
        acceptedCount += 1
        return .stacked(frameCount: accumulator!.frameCount)
    }

    /// Debayer in stored order (never flip the CFA), then flip rows to top-down display.
    private func displayRGB(_ frame: RawFrame) -> AstroImage {
        var rgb: AstroImage
        if let pattern = frame.bayerPattern, frame.image.channels == 1 {
            rgb = Debayer.bilinear(cfa: frame.image, pattern: pattern)
        } else {
            rgb = frame.image
        }
        guard frame.bottomUp else { return rgb }
        let w = rgb.width, h = rgb.height, plane = w * h
        var flipped = [Float](repeating: 0, count: rgb.pixels.count)
        for c in 0..<rgb.channels {
            for y in 0..<h {
                let src = c * plane + (h - 1 - y) * w
                let dst = c * plane + y * w
                flipped.replaceSubrange(dst..<(dst + w), with: rgb.pixels[src..<(src + w)])
            }
        }
        return AstroImage(width: w, height: h, channels: rgb.channels,
                          pixels: flipped, sourceIsLinear: rgb.sourceIsLinear)
    }
}
```

Also create `Sources/LiveAstroCore/Sources/FrameSource.swift` with the `RawFrame` struct shown in the Interfaces block above (protocol arrives in Task 9).

- [ ] **Step 5: Run** `swift test --filter StackEngineTests 2>&1 | tail -4` — PASS.
- [ ] **Step 6: Full suite green; commit** `feat: StackEngine — native registration + weighted mean stacking core`

### Task 9: FrameSource protocol + FolderFrameSource

**Files:**
- Modify: `Sources/LiveAstroCore/Sources/FrameSource.swift` (add protocol beside RawFrame)
- Create: `Sources/LiveAstroCore/Sources/FolderFrameSource.swift`
- Test: `Tests/LiveAstroCoreTests/FolderFrameSourceTests.swift`

**Interfaces:**
- Produces:

```swift
public protocol FrameSource: AnyObject {
    /// Emits raw frames as available; finishes when the source ends (import) or stop() is called.
    var frames: AsyncStream<RawFrame> { get }
    func start() throws
    func stop()
}

public final class FolderFrameSource: FrameSource {
    public enum Mode { case importOnce, live }
    public init(folder: URL, mode: Mode, fileNamePrefix: String? = nil)
    public let frames: AsyncStream<RawFrame>
    public func start() throws
    public func stop()
    /// Shared FITS→RawFrame loader (also used by tests):
    public static func loadRawFrame(url: URL) throws -> RawFrame
}
```

- Consumes: `FITSReader.readHeader/read` + Task 1 keywords; `StackFileWatcher` for live mode.

`loadRawFrame`: read `Data(contentsOf:)`; `FITSReader.readHeader` for `bayerPattern` (via `BayerPattern(headerValue:)`), `bottomUp`, `dateObs`; `FITSReader.read` for pixels → `AstroImage(width:height:channels:pixels:sourceIsLinear: true)` **without any flip** (stored order — the engine owns orientation). Timestamp: parse `dateObs` with `ISO8601DateFormatter` (`.withInternetDateTime, .withFractionalSeconds` then plain) else file modification date.

`importOnce.start()`: enumerate `folder` non-recursively, keep `ImageLoader.fitsExtensions`, apply prefix filter (same lowercased-hasPrefix rule as StackFileWatcher), sort by filename, load + yield each on a detached Task, finish the stream. Unreadable files are skipped with no frame (import continues).

`live.start()`: create `StackFileWatcher(folder:fileNamePrefix:)`, start it, forward each `StackUpdate` through `loadRawFrame` (skip on throw), finish when the watcher stream finishes. `stop()` stops the watcher / cancels the import task.

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import LiveAstroCore

final class FolderFrameSourceTests: XCTestCase {
    func writeFITS(_ dir: URL, name: String, value: Float) throws -> URL {
        let px = [Float](repeating: value, count: 64 * 32)
        let data = FITSWriter.float32(width: 64, height: 32, channels: 1, pixels: px)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testImportOnceYieldsSortedFramesAndFinishes() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writeFITS(dir, name: "Light_B_002.fit", value: 0.2)
        _ = try writeFITS(dir, name: "Light_A_001.fit", value: 0.1)
        try "x".write(to: dir.appendingPathComponent("ignore.txt"),
                      atomically: true, encoding: .utf8)   // non-FITS ignored

        let source = FolderFrameSource(folder: dir, mode: .importOnce, fileNamePrefix: "Light_")
        try source.start()
        var names: [String] = []
        for await frame in source.frames { names.append(frame.sourceName) }
        XCTAssertEqual(names, ["Light_A_001.fit", "Light_B_002.fit"])
    }

    func testLoadRawFrameKeepsStoredOrderAndMetadata() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writeFITS(dir, name: "sub.fit", value: 0.5)
        let frame = try FolderFrameSource.loadRawFrame(url: url)
        XCTAssertEqual(frame.image.channels, 1)
        XCTAssertEqual(frame.image.width, 64)
        XCTAssertEqual(frame.sourceName, "sub.fit")
        XCTAssertNil(frame.bayerPattern)   // FITSWriter emits no BAYERPAT
    }

    func testLiveModeForwardsNewFiles() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = FolderFrameSource(folder: dir, mode: .live, fileNamePrefix: "Light_")
        try source.start()
        _ = try writeFITS(dir, name: "Light_live_001.fit", value: 0.3)
        var got: RawFrame?
        for await frame in source.frames { got = frame; break }
        source.stop()
        XCTAssertEqual(got?.sourceName, "Light_live_001.fit")
    }
}
```

- [ ] **Step 2: Run** — compile failure. **Step 3: Implement** per the interface description (read `StackFileWatcher.swift` first and mirror its AsyncStream construction idiom — continuation captured in init, exactly like the watcher does). **Step 4:** tests PASS. **Step 5:** full suite green; commit `feat: FrameSource protocol + folder source (import + live)`

### Task 10: SessionPipeline native mode + master.fit

**Files:**
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift`
- Modify: `Sources/LiveAstroCore/FITS/FITSWriter.swift` (only if it lacks a ROWORDER keyword — read it first; add `roworder: String? = nil` parameter emitting `ROWORDER= 'TOP-DOWN'` when set)
- Test: `Tests/LiveAstroCoreTests/NativePipelineTests.swift`

**Interfaces:**
- Produces: second designated initializer

```swift
    public init(nativeSource: FrameSource, engine: StackEngine, profile: SessionProfile,
                rootDirectory: URL, replaySettings: ReplaySettings = .init(),
                maxKeyframes: Int = 45, neutralizeBackground: Bool = false)
```

plus `public var onRejected: ((RejectionReason, String) -> Void)?` and `public func reseed()` (forwards to the engine). `end()` in native mode additionally writes `master.fit` into the session directory and returns the replay URL as before.

- Consumes: Tasks 8–9; existing SessionManager/SnapshotRecorder/ReplayService.

Implementation notes for the implementer:
- Keep the existing watcher-mode code path untouched; native mode stores `source`/`engine` optionals and `start()` branches. The consume task iterates `source.frames`; per frame call `engine.process`:
  - `.becameReference` / `.stacked` → `let mean = engine.currentStack()!`; render exactly like `handle()` does today: optional `AutoStretch.neutralizeBackground`, `AutoStretch.stretch` when linear, `makeCGImage`; `recorder.save(cgImage:linear: mean, sourceFile: frame.sourceName, index: engine.acceptedCount, timestamp: frame.timestamp, estimatedIntegrationSeconds: Double(engine.acceptedCount) * profile.subExposureSeconds)`; `session.recordSnapshot`; `onUpdate`.
  - `.rejected(let reason)` → `onRejected?(reason, frame.sourceName)` and `onLog`.
- The drain-then-end semaphore pattern is identical — reuse `consumeDone`.
- `end()` native extras, after the manifest finalizes and before replay: `let master = engine.currentStack()`; if non-nil, `FITSWriter.float32(width:height:channels:pixels:)` (+ TOP-DOWN ROWORDER) → write to `sessionDir/master.fit`.
- Snapshot/manifest stats: `recorder.save` already computes stats from the linear image passed in — passing the raw `mean` keeps the v1.1 cloud-gate contract.

- [ ] **Step 1: Write failing tests** — an import-mode e2e in a temp sandbox:

```swift
import XCTest
@testable import LiveAstroCore

final class NativePipelineTests: XCTestCase {
    /// Mono starfield FITS subs (no BAYERPAT — engine's mono path), one starless.
    func writeSub(_ dir: URL, name: String, stars: [(Double, Double)]) throws {
        var px = [Float](repeating: 0.05, count: 256 * 256)
        for s in stars {
            for y in max(0, Int(s.1) - 6)...min(255, Int(s.1) + 6) {
                for x in max(0, Int(s.0) - 6)...min(255, Int(s.0) + 6) {
                    let dx = Double(x) - s.0, dy = Double(y) - s.1
                    px[y * 256 + x] += 0.8 * Float(exp(-(dx * dx + dy * dy) / (2 * 2.0 * 2.0)))
                }
            }
        }
        try FITSWriter.float32(width: 256, height: 256, channels: 1, pixels: px)
            .write(to: dir.appendingPathComponent(name))
    }

    func testImportEndToEnd() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let subsDir = sandbox.appendingPathComponent("subs")
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: subsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let field: [(Double, Double)] = (0..<20).map { i in
            (Double((i * 47) % 240 + 8), Double((i * 83) % 240 + 8))
        }
        try writeSub(subsDir, name: "Light_001.fit", stars: field)
        try writeSub(subsDir, name: "Light_002.fit", stars: field.map { ($0.0 + 2.4, $0.1 - 1.1) })
        try writeSub(subsDir, name: "Light_003.fit", stars: [])          // rejected
        try writeSub(subsDir, name: "Light_004.fit", stars: field.map { ($0.0 - 1.2, $0.1 + 0.8) })

        let profile = SessionProfile(targetName: "Test Field", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let source = FolderFrameSource(folder: subsDir, mode: .importOnce, fileNamePrefix: "Light_")
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: profile, rootDirectory: sessions)
        var rejected: [String] = []
        pipeline.onRejected = { _, name in rejected.append(name) }
        try pipeline.start()
        let replayURL = try pipeline.end()   // end() drains the finite import stream first

        XCTAssertEqual(rejected, ["Light_003.fit"])
        let sessionDir = replayURL.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: replayURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("master.fit").path))
        let manifest = try ManifestCoding.decoder().decode(SessionManifest.self,
            from: Data(contentsOf: sessionDir.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.snapshots.count, 3)
        XCTAssertEqual(manifest.snapshots.last?.estimatedIntegrationSeconds, 60)   // 3 accepted × 20 s
        // master.fit round-trips through our own reader
        let master = try FITSReader.read(Data(contentsOf: sessionDir.appendingPathComponent("master.fit")))
        XCTAssertEqual(master.width, 256)
    }
}
```

**Note:** check `SessionProfile`'s actual memberwise initializer in `SessionModels.swift` before writing the test — use its real parameter order/labels verbatim.

- [ ] **Step 2:** compile failure → **Step 3: Implement** → **Step 4:** PASS → **Step 5:** full suite green; commit `feat: native stacking mode in SessionPipeline + master.fit output`

### Task 11: App UI — source picker, counters, reseed, import

**Files:**
- Modify: `Sources/LiveAstroStudio/AppModel.swift`
- Modify: `Sources/LiveAstroStudio/ControlView.swift`
- Test: build only (`swift build`) — UI layer has no test target.

Read both files first and match their existing idiom exactly. Required behavior:

- `AppModel` gains: `enum SourceMode: String, CaseIterable { case stackerOutput = "Stacker output (Siril)"; case nativeStack = "Raw subs (native stacking)" }`, `var sourceMode: SourceMode = .stackerOutput`, `var acceptedCount = 0`, `var rejectedCount = 0`.
- `startSession()`: in `.nativeStack` mode build `FolderFrameSource(folder:, mode: .live, fileNamePrefix:)` + `StackEngine()` and the native `SessionPipeline` initializer, wiring `onRejected` to bump `rejectedCount` and log, `onUpdate` to bump `acceptedCount` (both on main actor, same pattern as the existing callbacks). Watcher mode is unchanged.
- `func reseedReference()` → `pipeline?.reseed()`, log "reference reseeded".
- `func importSubs(from folder: URL)`: guard not running; build importOnce source + engine + native pipeline rooted at the same sessions root; run `start()` + `end()` on a background queue (the import stream is finite, `end()` drains it — same call pattern as the e2e test); progress = the existing log lines (`✓ update N`); on completion log the replay path.
- `ControlView`: `Picker("Source", selection: $model.sourceMode)` (segmented) above the watch-folder row; when `.nativeStack` and running, a `Text("accepted \(model.acceptedCount) · rejected \(model.rejectedCount)")` line and a `Button("Reseed Reference") { model.reseedReference() }`; an `Button("Import Subs…")` (disabled while running) that presents `NSOpenPanel` (directory-only, same pattern as the existing Choose… button) and calls `model.importSubs(from:)`.
- The file-name filter field applies to both modes (subs prefix like `Light_` in native mode — update its placeholder text to say so).

- [ ] **Step 1:** implement; **Step 2:** `swift build 2>&1 | tail -2` — Build complete; `swift test` still green.
- [ ] **Step 3:** Manual smoke check (documented for the human/final validation): `swift run LiveAstroStudio`, switch source mode to native, Import Subs… over `~/Documents/ngc7000_lights` — session appears with live-updating broadcast window.
- [ ] **Step 4: Commit** `feat: native-stacking UI — source picker, counters, reseed, import`

### Task 12: Real-data parity fixtures + performance gate

**Files:**
- Create: `Scripts/make_parity_fixtures.py` (run once; commits small fixtures)
- Create: `Tests/LiveAstroCoreTests/Fixtures/parity_a.fit`, `parity_b.fit`, `parity_expected.json` (generated)
- Create: `Tests/LiveAstroCoreTests/ParityTests.swift`
- Create: `Tests/LiveAstroCoreTests/PerformanceTests.swift`
- Modify: `Package.swift` (add `resources: [.copy("Fixtures")]` to the test target)

`make_parity_fixtures.py`: pick two NGC 6888 subs ~40 apart (`~/Documents/lights`, files exist per repo owner); crop the central 1024×1024 region at an EVEN pixel offset (preserves GRBG phase); write both crops as 16-bit FITS with `BAYERPAT='GRBG'` and original `DATE-OBS`/`ROWORDER`; run astroalign on the two crops' superpixel luminances (exact code from `Scripts/build_session_from_subs.py`) and dump `parity_expected.json`: `{"rotation_deg": ..., "scale": ..., "tx": ..., "ty": ..., "n_source_stars_min": 25}`. Print what it wrote.

`ParityTests`: locate fixtures via `Bundle.module`; `FolderFrameSource.loadRawFrame` both; build superpixel luminance the same way `StackEngine` does; assert `StarDetector.detect` finds ≥ `n_source_stars_min` on each; run matcher + solver A→B; assert rotation within 0.05°, scale within 1e-3, translation within 0.5 px of `parity_expected.json`.

`PerformanceTests`: synthesize one 6248×4176 GRBG frame (constant background + 200 Gaussian stars, seeded), seed an engine with it, process a shifted copy, assert the `process` call completes in < 10 s wall clock (`Date` timing, not `measure {}` — one shot is the gate). Mark with `try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil)` guard? No CI exists — leave unconditional.

- [ ] **Step 1:** write + run the fixture script; verify the two `.fit` crops are ≤ 3 MB each; commit fixtures + script.
- [ ] **Step 2:** write both test files (failing only if implementation is wrong — these validate, not drive).
- [ ] **Step 3:** `swift test --filter ParityTests` and `--filter PerformanceTests` — PASS. If the perf gate fails, apply the escalation notes in Tasks 2/7 (site-parity debayer loop, vImage warp) and re-run before proceeding.
- [ ] **Step 4:** full suite green; commit `test: real-data parity fixtures + 26MP performance gate`

### Task 13: Docs + full-dataset validation

**Files:**
- Create: `Scripts/compare_to_master.py`
- Modify: `README.md`, `docs/superpowers/specs/2026-07-07-liveastro-v2-native-stacking-design.md` (status), `docs/superpowers/specs/2026-07-05-liveastro-studio-v1-design.md` (§9 non-goals: native stacking now exists — annotate)

`compare_to_master.py`: loads a LiveAstro `master.fit` + Paul's Siril master (paths as CLI args), registers via astroalign luminance, prints per-channel Pearson correlation (reuse the logic from the scratchpad `bayer_truth.py` comparison stage — reimplement cleanly, it is not in the repo).

README: new "Native stacking" section — source-mode picker, import flow, live flow, reseed button, master.fit, and the validation ladder result (fill in the measured correlation after running).

Manual validation run (document the result in the PR/commit message):
```
swift run LiveAstroStudio   # Import Subs… over ~/Documents/lights (120 NGC 6888 subs)
python3 Scripts/compare_to_master.py ~/Documents/LiveAstro/<session>/master.fit \
    ~/Documents/NGC_6888_1000x20sec_2026-07-02_2026-07-03_1500_og.fit
```
Acceptance (spec §5): per-channel correlation ≥ the Python prototype's result on the same GRBG labeling.

- [ ] **Step 1:** write script + docs; **Step 2:** run the NGC 6888 validation, record numbers in README; **Step 3:** full suite green; commit `docs: v2 native stacking — usage, validation results`
