# Native Background Extraction (DBE) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flatten the light-pollution gradient in the live display (live view + snapshots + replay) by fitting a per-channel low-order 2D polynomial to sky-tile samples and subtracting it, leaving the linear `master.fit` untouched.

**Architecture:** A new pure `BackgroundExtraction.flatten(_:degree:)` (tile-sample → sigma-clip bright tiles → least-squares polynomial fit → subtract + pedestal) runs inside `SessionPipeline.displayCGImage` before neutralize/stretch. Its two parameters (`backgroundExtraction`, `backgroundDegree`) are added to the shipped `DisplayAdjustments` value type so they ride the existing throttled-re-render and persistence plumbing. Off by default → today's output is byte-identical.

**Tech Stack:** Swift 5.10, Swift Package Manager, XCTest. `LiveAstroCore` (Foundation/CoreGraphics/Accelerate) + `LiveAstroStudio` (SwiftUI `@Observable`).

## Global Constraints

- Swift 5.10, macOS 14+. `LiveAstroCore` uses Foundation / CoreGraphics / Accelerate only — NO external LAPACK; the polynomial solve is a hand-rolled 3×3/6×6 Gaussian elimination.
- Core tests: `swift test --filter LiveAstroCoreTests`; all existing tests must stay green.
- TDD for Core tasks (T1–T3). The pipeline-wiring + UI task (T4) is MANUAL/BUILD-VERIFIED in RELEASE — SwiftUI/window lifecycle out of unit-test scope, matching the prior pillars.
- `DisplayAdjustments` values are NOT clamped in the initializer (persisted out-of-range decodes unchanged); `degree` is clamped to {1,2} on APPLY inside `flatten`.
- Display-path only. DBE runs in `displayCGImage`; the `master.fit` finalize/write path must NOT be touched (stays linear).
- **DBE off (default) must reproduce today's display output byte-for-byte** — the DBE branch is skipped when `backgroundExtraction == false`.
- Neutralize interaction: when DBE is on, SKIP `neutralizeBackgroundAdditive` (keep multiplicative `neutralizeBackground` if the toggle is on); when off, today's behavior unchanged.
- `AppModel` is `@Observable` with plain `var` (not `@Published`).
- Branch `feature/background-extraction` (off main). Never commit to main.

---

### Task 1: BackgroundExtraction.flatten (the polynomial DBE)

**Files:**
- Create: `Sources/LiveAstroCore/Imaging/BackgroundExtraction.swift`
- Test: `Tests/LiveAstroCoreTests/BackgroundExtractionTests.swift`

**Interfaces:**
- Consumes: `AstroImage` (has `width`, `height`, `channels`, `pixels: [Float]` planar per-channel, `sourceIsLinear`, and `init(width:height:channels:pixels:sourceIsLinear:)`).
- Produces: `static func flatten(_ image: AstroImage, degree: Int, tilesPerAxis: Int = 32, rejectionSigma: Double = 2.0) -> AstroImage`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LiveAstroCoreTests/BackgroundExtractionTests.swift`:
```swift
import XCTest
@testable import LiveAstroCore

final class BackgroundExtractionTests: XCTestCase {
    // 3-channel linear image: flat sky `base` + a planar ramp `slope` across x (same each channel).
    func gradientImage(w: Int, h: Int, base: Float, slope: Float) -> AstroImage {
        var px = [Float](repeating: 0, count: w * h * 3)
        for c in 0..<3 {
            for y in 0..<h {
                for x in 0..<w {
                    px[c*w*h + y*w + x] = base + slope * Float(x) / Float(w - 1)
                }
            }
        }
        return AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
    }
    // background spread over a central sky region (avoids edge tiles).
    func skySpread(_ img: AstroImage) -> Float {
        let w = img.width, h = img.height, plane = w * h
        var lo: Float = .greatestFiniteMagnitude, hi: Float = -.greatestFiniteMagnitude
        for y in (h/4)..<(3*h/4) { for x in (w/4)..<(3*w/4) {
            let v = img.pixels[y*w + x]; lo = min(lo, v); hi = max(hi, v)
        } }
        return hi - lo
    }

    func testPlanarGradientRemoved() {
        // slope 0.5 → values 0.1…0.6; skySpread over the central half measures ~0.25.
        let img = gradientImage(w: 128, h: 128, base: 0.1, slope: 0.5)
        let before = skySpread(img)
        let out = BackgroundExtraction.flatten(img, degree: 1)
        let after = skySpread(out)
        XCTAssertGreaterThan(before, 0.2)          // the input really has a ramp
        XCTAssertLessThan(after, before * 0.1)     // ramp largely removed (flat)
        XCTAssertEqual(out.width, 128); XCTAssertEqual(out.channels, 3)
    }

    func testNebulaPreserved() {
        var img = gradientImage(w: 128, h: 128, base: 0.1, slope: 0.4)
        var px = img.pixels
        let w = 128, h = 128, plane = w*h
        // bright Gaussian blob near center, all channels
        for c in 0..<3 { for y in 0..<h { for x in 0..<w {
            let dx = Double(x-64), dy = Double(y-64)
            px[c*plane + y*w + x] += Float(0.6 * exp(-(dx*dx+dy*dy)/(2*8.0*8.0)))
        } } }
        img = AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
        let out = BackgroundExtraction.flatten(img, degree: 1)
        // blob peak stands well above its local sky after flatten (signal not eaten)
        let peak = out.pixels[64*w + 64]
        let localSky = out.pixels[20*w + 20]
        XCTAssertGreaterThan(peak - localSky, 0.3)
    }

    func testQuadraticNeedsDegree2() {
        // curved gradient: base + k*(x-cx)^2 across the frame
        let w = 128, h = 128, plane = w*h
        var px = [Float](repeating: 0, count: plane*3)
        for c in 0..<3 { for y in 0..<h { for x in 0..<w {
            let nx = Double(x - w/2) / Double(w/2)
            px[c*plane + y*w + x] = Float(0.1 + 0.5 * nx * nx)
        } } }
        let img = AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
        let deg1 = BackgroundExtraction.flatten(img, degree: 1)
        let deg2 = BackgroundExtraction.flatten(img, degree: 2)
        XCTAssertLessThan(skySpread(deg2), skySpread(deg1))   // quadratic flattens curvature better
    }

    func testFlatImageUnchangedWithinTolerance() {
        let w = 64, h = 64
        let img = AstroImage(width: w, height: h, channels: 3,
                             pixels: [Float](repeating: 0.2, count: w*h*3), sourceIsLinear: true)
        let out = BackgroundExtraction.flatten(img, degree: 1)
        for i in 0..<out.pixels.count { XCTAssertEqual(out.pixels[i], 0.2, accuracy: 1e-3) }
    }

    func testMonoPassthrough() {
        let img = AstroImage(width: 8, height: 8, channels: 1,
                             pixels: [Float](repeating: 0.3, count: 64), sourceIsLinear: true)
        XCTAssertEqual(BackgroundExtraction.flatten(img, degree: 1).pixels, img.pixels)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BackgroundExtractionTests`
Expected: compile failure — `cannot find 'BackgroundExtraction' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/LiveAstroCore/Imaging/BackgroundExtraction.swift`:
```swift
import Foundation

/// Flattens a smooth background gradient (light-pollution ramp) by fitting a
/// per-channel low-order 2D polynomial to sky-tile samples and subtracting it.
/// Display-path only — never applied to the linear master. Conservative: a
/// degree-1/2 polynomial can only model a smooth ramp/bowl, so it cannot
/// subtract a non-smooth nebula. Returns the image UNCHANGED on any condition
/// that makes a fit unsafe (see guards).
public enum BackgroundExtraction {
    public static func flatten(_ image: AstroImage, degree: Int,
                               tilesPerAxis: Int = 32,
                               rejectionSigma: Double = 2.0) -> AstroImage {
        guard image.channels == 3 else { return image }        // mono display path unchanged
        let deg = min(max(degree, 1), 2)
        let nCoeff = deg == 1 ? 3 : 6
        let w = image.width, h = image.height, plane = w * h
        let tiles = max(1, tilesPerAxis)

        // Polynomial basis at normalized coords x,y ∈ [-1,1].
        func basis(_ x: Double, _ y: Double) -> [Double] {
            deg == 1 ? [1, x, y] : [1, x, y, x*x, x*y, y*y]
        }

        var out = image.pixels
        for c in 0..<3 {
            let base = c * plane
            // 1. tile samples: (nx, ny, median)
            var sx: [Double] = [], sy: [Double] = [], sv: [Double] = []
            sx.reserveCapacity(tiles*tiles); sy.reserveCapacity(tiles*tiles); sv.reserveCapacity(tiles*tiles)
            for ty in 0..<tiles {
                let y0 = ty * h / tiles, y1 = (ty + 1) * h / tiles
                if y1 <= y0 { continue }
                for tx in 0..<tiles {
                    let x0 = tx * w / tiles, x1 = (tx + 1) * w / tiles
                    if x1 <= x0 { continue }
                    var vals: [Float] = []; vals.reserveCapacity((y1-y0)*(x1-x0))
                    for yy in y0..<y1 { for xx in x0..<x1 { vals.append(image.pixels[base + yy*w + xx]) } }
                    vals.sort()
                    let med = Double(vals[vals.count/2])
                    let cx = (Double(x0 + x1) / 2) / Double(w) * 2 - 1   // → [-1,1]
                    let cy = (Double(y0 + y1) / 2) / Double(h) * 2 - 1
                    sx.append(cx); sy.append(cy); sv.append(med)
                }
            }
            // 2. sigma-clip bright tiles (nebula/stars) out of the sky set.
            var keep = [Bool](repeating: true, count: sv.count)
            for _ in 0..<3 {
                let kept = sv.enumerated().filter { keep[$0.offset] }.map { $0.element }
                if kept.count <= nCoeff { break }
                var sorted = kept.sorted()
                let med = sorted[sorted.count/2]
                var dev = sorted.map { abs($0 - med) }; dev.sort()
                let madn = 1.4826 * dev[dev.count/2]
                if madn <= 1e-12 { break }
                let hiCut = med + rejectionSigma * madn
                var changed = false
                for i in 0..<sv.count where keep[i] && sv[i] > hiCut { keep[i] = false; changed = true }
                if !changed { break }
            }
            let idx = (0..<sv.count).filter { keep[$0] }
            guard idx.count >= nCoeff else { continue }        // too few sky tiles → passthrough this channel

            // 3. least-squares normal equations AᵀA c = Aᵀb over kept tiles.
            var ata = [[Double]](repeating: [Double](repeating: 0, count: nCoeff), count: nCoeff)
            var atb = [Double](repeating: 0, count: nCoeff)
            for i in idx {
                let b = basis(sx[i], sy[i]); let v = sv[i]
                for r in 0..<nCoeff { atb[r] += b[r] * v; for col in 0..<nCoeff { ata[r][col] += b[r] * b[col] } }
            }
            guard let coeff = solveSymmetric(&ata, atb) else { continue }  // singular → passthrough channel

            // 4. evaluate surface, find pedestal (min), subtract + re-add pedestal.
            var surface = [Float](repeating: 0, count: plane)
            var minS = Double.greatestFiniteMagnitude
            for yy in 0..<h {
                let ny = Double(yy) / Double(h) * 2 - 1
                for xx in 0..<w {
                    let nx = Double(xx) / Double(w) * 2 - 1
                    let bb = basis(nx, ny)
                    var s = 0.0; for r in 0..<nCoeff { s += coeff[r] * bb[r] }
                    surface[yy*w + xx] = Float(s); if s < minS { minS = s }
                }
            }
            let ped = Float(minS)
            for i in 0..<plane {
                out[base + i] = min(max(image.pixels[base + i] - surface[i] + ped, 0), 1)
            }
        }
        return AstroImage(width: w, height: h, channels: image.channels, pixels: out,
                          sourceIsLinear: image.sourceIsLinear)
    }

    /// Solve an n×n symmetric system in place via Gaussian elimination with
    /// partial pivoting. Returns nil if singular / ill-conditioned.
    static func solveSymmetric(_ a: inout [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        var m = a, y = b
        for col in 0..<n {
            var piv = col
            for r in (col+1)..<n where abs(m[r][col]) > abs(m[piv][col]) { piv = r }
            if abs(m[piv][col]) < 1e-12 { return nil }
            if piv != col { m.swapAt(piv, col); y.swapAt(piv, col) }
            for r in (col+1)..<n {
                let f = m[r][col] / m[col][col]
                if f == 0 { continue }
                for k in col..<n { m[r][k] -= f * m[col][k] }
                y[r] -= f * y[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n-1, through: 0, by: -1) {
            var s = y[r]; for k in (r+1)..<n { s -= m[r][k] * x[k] }
            x[r] = s / m[r][r]
        }
        return x
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BackgroundExtractionTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Imaging/BackgroundExtraction.swift Tests/LiveAstroCoreTests/BackgroundExtractionTests.swift
git commit -m "feat: native BackgroundExtraction (polynomial DBE)"
```

---

### Task 2: DisplayAdjustments — DBE params + backward-compat Codable

**Files:**
- Modify: `Sources/LiveAstroCore/Imaging/DisplayAdjustments.swift`
- Test: `Tests/LiveAstroCoreTests/DisplayAdjustmentsTests.swift` (add cases)

**Interfaces:**
- Produces: `DisplayAdjustments.backgroundExtraction: Bool` (default false) and `backgroundDegree: Int` (default 1), a custom `init(from:)` that decodes missing keys to their defaults, and `.neutral` including the DBE defaults.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/LiveAstroCoreTests/DisplayAdjustmentsTests.swift`:
```swift
    func testDBEDefaultsOffPlanar() {
        let n = DisplayAdjustments.neutral
        XCTAssertFalse(n.backgroundExtraction)
        XCTAssertEqual(n.backgroundDegree, 1)
        XCTAssertEqual(DisplayAdjustments(), n)
    }

    func testDBERoundTrip() throws {
        let a = DisplayAdjustments(blackPoint: 0.05, midtoneStrength: 0.2, saturation: 1.3,
                                   backgroundExtraction: true, backgroundDegree: 2)
        let data = try JSONEncoder().encode(a)
        XCTAssertEqual(try JSONDecoder().decode(DisplayAdjustments.self, from: data), a)
    }

    func testOldBlobWithoutDBEKeysDecodesDefaults() throws {
        // JSON written before the DBE fields existed (only the original three keys).
        let json = #"{"blackPoint":0.1,"midtoneStrength":-0.3,"saturation":1.5}"#
        let a = try JSONDecoder().decode(DisplayAdjustments.self, from: Data(json.utf8))
        XCTAssertEqual(a.blackPoint, 0.1)
        XCTAssertFalse(a.backgroundExtraction)   // absent → default
        XCTAssertEqual(a.backgroundDegree, 1)    // absent → default
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DisplayAdjustmentsTests`
Expected: compile failure — `extra argument 'backgroundExtraction'` / `has no member 'backgroundExtraction'`.

- [ ] **Step 3: Implement**

Replace `Sources/LiveAstroCore/Imaging/DisplayAdjustments.swift` with (adds the two fields + a custom decode; encode stays synthesized):
```swift
import Foundation

/// Non-destructive display-path adjustments layered on AutoStretch. Neutral
/// values reproduce the plain auto-stretch look exactly. Values are clamped to
/// their documented ranges when APPLIED (in AutoStretch / BackgroundExtraction),
/// not here — so a persisted out-of-range blob degrades gracefully.
///
/// - blackPoint:          0 (neutral) … 0.2  — shadow clip on the linear data
/// - midtoneStrength:     −1 … +1, 0 neutral — scales the auto-MTF midpoint
/// - saturation:          0 … 2, 1 neutral   — luminance-preserving chroma scale
/// - backgroundExtraction false neutral       — flatten the LP gradient (DBE)
/// - backgroundDegree:    1 planar / 2 quad   — DBE polynomial degree (clamped on apply)
public struct DisplayAdjustments: Equatable, Codable {
    public var blackPoint: Double
    public var midtoneStrength: Double
    public var saturation: Double
    public var backgroundExtraction: Bool
    public var backgroundDegree: Int

    public init(blackPoint: Double = 0, midtoneStrength: Double = 0, saturation: Double = 1,
                backgroundExtraction: Bool = false, backgroundDegree: Int = 1) {
        self.blackPoint = blackPoint
        self.midtoneStrength = midtoneStrength
        self.saturation = saturation
        self.backgroundExtraction = backgroundExtraction
        self.backgroundDegree = backgroundDegree
    }

    public static let neutral = DisplayAdjustments()

    // Custom decode so a settings blob written before the DBE fields existed
    // still decodes (missing keys → defaults). Encode stays synthesized.
    private enum CodingKeys: String, CodingKey {
        case blackPoint, midtoneStrength, saturation, backgroundExtraction, backgroundDegree
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blackPoint = try c.decodeIfPresent(Double.self, forKey: .blackPoint) ?? 0
        midtoneStrength = try c.decodeIfPresent(Double.self, forKey: .midtoneStrength) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
        backgroundExtraction = try c.decodeIfPresent(Bool.self, forKey: .backgroundExtraction) ?? false
        backgroundDegree = try c.decodeIfPresent(Int.self, forKey: .backgroundDegree) ?? 1
    }
}
```
Note: `.neutral` now equals `DisplayAdjustments()` (also resolves the earlier ledgered DRY nit). The prior `testNeutralDefaults` / `testCodableRoundTrip` / `testInitDoesNotClamp` still pass (defaults unchanged for the original three fields; no clamping in init).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DisplayAdjustmentsTests`
Expected: PASS (existing 3 + new 3). Then `swift test --filter SessionSettings` (SessionSettings embeds DisplayAdjustments — confirm its Codable tests still pass with the custom decode).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Imaging/DisplayAdjustments.swift Tests/LiveAstroCoreTests/DisplayAdjustmentsTests.swift
git commit -m "feat: DisplayAdjustments DBE params (backward-compatible decode)"
```

---

### Task 3: SessionPipeline applies DBE in the display path

**Files:**
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift`
- Test: `Tests/LiveAstroCoreTests/SessionPipelineDisplayAdjTests.swift` (add a case)

**Interfaces:**
- Consumes: `BackgroundExtraction.flatten(_:degree:)` (T1); `DisplayAdjustments.backgroundExtraction/backgroundDegree` (T2); existing `displayCGImage`, `renderCurrentDisplay`, `AutoStretch.neutralizeBackground(Additive)`.
- Produces: `displayCGImage` applies DBE before neutralize/stretch and switches the neutralize step per the DBE flag.

- [ ] **Step 1: Write the failing test**

Add to `Tests/LiveAstroCoreTests/SessionPipelineDisplayAdjTests.swift` (reuse its existing `writeSub`/`makePipeline` helpers):
```swift
    func testRenderWithDBEEnabledProducesImage() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let subsDir = sandbox.appendingPathComponent("subs")
        try FileManager.default.createDirectory(at: subsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        var field: [(Double, Double)] = []
        for i in 0..<20 { field.append((Double((i*47)%240+8), Double((i*83)%240+8))) }
        try writeSub(subsDir, "Light_001.fit", stars: field)
        try writeSub(subsDir, "Light_002.fit", stars: field.map { ($0.0+2.4, $0.1-1.1) })
        let pipeline = makePipeline(sandbox, subsDir)
        try pipeline.start()
        _ = try pipeline.end()
        let adj = DisplayAdjustments(backgroundExtraction: true, backgroundDegree: 2)
        XCTAssertNotNil(pipeline.renderCurrentDisplay(adjustments: adj))   // DBE path renders, no crash
        XCTAssertTrue(pipeline.displayAdjustments.backgroundExtraction)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionPipelineDisplayAdjTests`
Expected: FAIL to compile — `extra argument 'backgroundExtraction'` (until T2 is in; if T2 already merged, the test compiles but the assertion still exercises the new pipeline path). If it compiles and passes without the T3 change, the DBE branch isn't wired — proceed to Step 3 and keep it as the regression guard.

- [ ] **Step 3: Implement**

In `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift`, update `displayCGImage(from:)` to insert the DBE step and switch the neutralize step. The current body (from Task 4 of the prior pillar) is:
```swift
    private func displayCGImage(from linear: AstroImage) throws -> CGImage {
        let adj = displayAdjustments
        let balanced = neutralizeBackground
            ? AutoStretch.neutralizeBackground(AutoStretch.neutralizeBackgroundAdditive(linear))
            : linear
        let stretched = balanced.sourceIsLinear
            ? AutoStretch.stretch(balanced, blackPoint: adj.blackPoint, midtoneStrength: adj.midtoneStrength)
            : balanced
        let display = AutoStretch.applySaturation(stretched, adj.saturation)
        guard let cg = AutoStretch.makeCGImage(display) else {
            throw ImageLoaderError.decodeFailed("CGImage packing")
        }
        return cg
    }
```
Change it to:
```swift
    private func displayCGImage(from linear: AstroImage) throws -> CGImage {
        let adj = displayAdjustments
        // DBE first, on linear data. When on, it removes the per-channel spatial
        // background, so skip the additive neutralize (keep multiplicative WB).
        let flattened = adj.backgroundExtraction
            ? BackgroundExtraction.flatten(linear, degree: adj.backgroundDegree)
            : linear
        let balanced: AstroImage
        if neutralizeBackground {
            balanced = adj.backgroundExtraction
                ? AutoStretch.neutralizeBackground(flattened)                              // multiplicative only
                : AutoStretch.neutralizeBackground(AutoStretch.neutralizeBackgroundAdditive(flattened))
        } else {
            balanced = flattened
        }
        let stretched = balanced.sourceIsLinear
            ? AutoStretch.stretch(balanced, blackPoint: adj.blackPoint, midtoneStrength: adj.midtoneStrength)
            : balanced
        let display = AutoStretch.applySaturation(stretched, adj.saturation)
        guard let cg = AutoStretch.makeCGImage(display) else {
            throw ImageLoaderError.decodeFailed("CGImage packing")
        }
        return cg
    }
```
When `adj.backgroundExtraction == false`, `flattened == linear` and the neutralize branch is exactly today's code → byte-identical output. Do NOT touch the master.fit finalize path.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SessionPipelineDisplayAdjTests`
Expected: PASS. Then the FULL Core suite: `swift test --filter LiveAstroCoreTests` — all green (DBE-off gives identical output, so existing native/crop/clean-export/e2e pipeline tests are unaffected).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Pipeline/SessionPipeline.swift Tests/LiveAstroCoreTests/SessionPipelineDisplayAdjTests.swift
git commit -m "feat: SessionPipeline applies DBE in the display path"
```

---

### Task 4: ControlView DBE toggle + degree picker

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift`

**Interfaces:**
- Consumes: `AppModel.displayAdjustments` (already observable + persisted + throttle-wired from the prior pillar); `applyDisplayAdjustments()`.
- Produces: a "Flatten background (DBE)" toggle + Planar/Quadratic picker in the Display Adjustments section.

**Note:** No unit test — SwiftUI out of unit-test scope (manual/build-verified, same as prior pillars). No AppModel change needed: `displayAdjustments` already persists (T2 added the fields) and `applyDisplayAdjustments()` already re-renders.

- [ ] **Step 1: Add the DBE controls to the Display Adjustments section**

In `Sources/LiveAstroStudio/ControlView.swift`, inside the existing `Section("Display Adjustments")`, add below the sliders (match the section's `@Bindable`/`.help()` idiom):
```swift
                Toggle("Flatten background (DBE)", isOn: $model.displayAdjustments.backgroundExtraction)
                    .help("Remove the light-pollution gradient so the sky darkens evenly. Off by default.")
                    .onChange(of: model.displayAdjustments.backgroundExtraction) { _, _ in
                        model.applyDisplayAdjustments()
                    }
                Picker("Gradient shape", selection: $model.displayAdjustments.backgroundDegree) {
                    Text("Planar").tag(1)
                    Text("Quadratic").tag(2)
                }
                .pickerStyle(.segmented)
                .disabled(!model.displayAdjustments.backgroundExtraction)
                .help("Planar removes a linear tilt; Quadratic also removes curvature/vignette.")
                .onChange(of: model.displayAdjustments.backgroundDegree) { _, _ in
                    model.applyDisplayAdjustments()
                }
```
(If the file targets a macOS-14 two-parameter `onChange(of:) { _, _ in }` — use that signature; if the existing code in this file uses the single-parameter `onChange(of:) { _ in }`, match whichever the file already uses.)

- [ ] **Step 2: Build debug**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Build RELEASE**

Run: `swift build -c release --scratch-path /private/tmp/las-release-build`
Expected: `Build complete!` (local scratch path avoids the iCloud-Desktop build.db disk-I/O error).

- [ ] **Step 4: Run the full Core suite (no regression)**

Run: `swift test --filter LiveAstroCoreTests`
Expected: all pass (T4 only changes the app target).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroStudio/ControlView.swift
git commit -m "feat: DBE toggle + degree picker in Display Adjustments"
```

---

## Notes for the implementer

- DBE off (default) must be a no-op: `flatten` is not called and the neutralize branch is the exact prior code — existing display output stays byte-identical.
- Do NOT touch the `master.fit` finalize/write path — DBE is display-only, master stays linear.
- The polynomial solve is hand-rolled (no LAPACK). Coordinates are normalized to [-1,1] for conditioning; `solveSymmetric` returns nil on a singular system → `flatten` passes that channel through unchanged.
- Bright-tile sigma-clip is what protects the nebula: nebula/star tiles are excluded from the fit, so the surface follows the sky, not the signal.
