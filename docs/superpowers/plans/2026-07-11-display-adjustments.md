# Display Adjustments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three non-destructive display sliders (black-point, stretch strength, saturation) that shape the live/broadcast/snapshot/replay image on top of the existing auto-stretch, with neutral defaults reproducing today's image byte-for-byte and the linear `master.fit` left untouched.

**Architecture:** A `DisplayAdjustments` value type flows from the UI through `SessionSettings` into `SessionPipeline`, which applies it inside `displayCGImage` (black-point + midtone on the `AutoStretch.stretch` step, saturation after). A lock-guarded `displayAdjustments` on the pipeline lets the frame loop and a throttled off-main re-render (`renderCurrentDisplay`) read it race-free. The `master.fit` write path never calls `displayCGImage`, so the master stays linear.

**Tech Stack:** Swift 5.10, Swift Package Manager, XCTest. `LiveAstroCore` (Foundation/CoreGraphics/Accelerate) + `LiveAstroStudio` (SwiftUI `@Observable`).

## Global Constraints

- Swift 5.10, macOS 14+. `LiveAstroCore` uses Foundation / CoreGraphics / Accelerate only.
- Core tests: `swift test --filter LiveAstroCoreTests`; all existing tests must stay green.
- TDD for Core tasks (T1–T4). The AppModel + UI task (T5) is MANUAL/BUILD-VERIFIED in RELEASE — SwiftUI/`@Observable`/window lifecycle is out of unit-test scope, matching the prior pillars.
- `AppModel` is `@Observable` and declares observable state as plain `var` (NOT `@Published`).
- **Neutral-default guarantee:** `blackPoint=0, midtoneStrength=0, saturation=1` must reproduce today's image exactly. `stretch(img, blackPoint: 0, midtoneStrength: 0)` must be byte-identical to `stretch(img)`.
- Adjustments affect the display path only (live view + snapshots + replay). The `master.fit` write path stays linear and is not touched.
- Ranges (clamped on apply, not in the initializer): blackPoint 0…0.2, midtoneStrength −1…1, saturation 0…2.
- Branch `feature/display-adjustments` (off main at ff068a3). Never commit to main.

---

### Task 1: DisplayAdjustments value type

**Files:**
- Create: `Sources/LiveAstroCore/Imaging/DisplayAdjustments.swift`
- Test: `Tests/LiveAstroCoreTests/DisplayAdjustmentsTests.swift`

**Interfaces:**
- Produces: `public struct DisplayAdjustments: Equatable, Codable` with `blackPoint/midtoneStrength/saturation: Double`, `static let neutral`, and a memberwise `init` whose defaults equal neutral. No clamping in the initializer.

- [ ] **Step 1: Write the failing test**

Create `Tests/LiveAstroCoreTests/DisplayAdjustmentsTests.swift`:
```swift
import XCTest
@testable import LiveAstroCore

final class DisplayAdjustmentsTests: XCTestCase {
    func testNeutralDefaults() {
        let n = DisplayAdjustments.neutral
        XCTAssertEqual(n.blackPoint, 0)
        XCTAssertEqual(n.midtoneStrength, 0)
        XCTAssertEqual(n.saturation, 1)
        XCTAssertEqual(DisplayAdjustments(), n)   // default init == neutral
    }

    func testCodableRoundTrip() throws {
        let a = DisplayAdjustments(blackPoint: 0.1, midtoneStrength: -0.4, saturation: 1.6)
        let data = try JSONEncoder().encode(a)
        let b = try JSONDecoder().decode(DisplayAdjustments.self, from: data)
        XCTAssertEqual(a, b)
    }

    func testInitDoesNotClamp() {
        // Out-of-range persists as-is; clamping happens on apply (AutoStretch), not here.
        let a = DisplayAdjustments(blackPoint: 5, midtoneStrength: -9, saturation: 42)
        XCTAssertEqual(a.blackPoint, 5)
        XCTAssertEqual(a.midtoneStrength, -9)
        XCTAssertEqual(a.saturation, 42)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DisplayAdjustmentsTests`
Expected: compile failure — `cannot find 'DisplayAdjustments' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/LiveAstroCore/Imaging/DisplayAdjustments.swift`:
```swift
import Foundation

/// Non-destructive display-path adjustments layered on AutoStretch. Neutral
/// values reproduce the plain auto-stretch look exactly. Values are clamped to
/// their documented ranges when APPLIED (in AutoStretch), not here — so a
/// persisted out-of-range blob degrades gracefully rather than being rewritten.
///
/// - blackPoint:      0 (neutral) … 0.2  — shadow clip on the linear data
/// - midtoneStrength: −1 … +1, 0 neutral — scales the auto-MTF midpoint
/// - saturation:      0 … 2, 1 neutral   — luminance-preserving chroma scale
public struct DisplayAdjustments: Equatable, Codable {
    public var blackPoint: Double
    public var midtoneStrength: Double
    public var saturation: Double

    public init(blackPoint: Double = 0, midtoneStrength: Double = 0, saturation: Double = 1) {
        self.blackPoint = blackPoint
        self.midtoneStrength = midtoneStrength
        self.saturation = saturation
    }

    public static let neutral = DisplayAdjustments(blackPoint: 0, midtoneStrength: 0, saturation: 1)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DisplayAdjustmentsTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Imaging/DisplayAdjustments.swift Tests/LiveAstroCoreTests/DisplayAdjustmentsTests.swift
git commit -m "feat: DisplayAdjustments value type"
```

---

### Task 2: AutoStretch black-point + midtone strength + saturation

**Files:**
- Modify: `Sources/LiveAstroCore/Imaging/AutoStretch.swift`
- Test: `Tests/LiveAstroCoreTests/AutoStretchAdjustmentsTests.swift`

**Interfaces:**
- Consumes: existing `AutoStretch.stretch(_:targetBackground:shadowsClipping:)`, `AutoStretch.mtf(_:_:)`, `AstroImage`.
- Produces:
  - `stretch(_ image, targetBackground: Double = 0.25, shadowsClipping: Double = -2.8, blackPoint: Double = 0, midtoneStrength: Double = 0)` — two new trailing neutral-default params.
  - `static func applySaturation(_ image: AstroImage, _ factor: Double) -> AstroImage`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LiveAstroCoreTests/AutoStretchAdjustmentsTests.swift`:
```swift
import XCTest
@testable import LiveAstroCore

final class AutoStretchAdjustmentsTests: XCTestCase {
    // A small linear RGB image with a spread of values.
    func linearImage() -> AstroImage {
        let w = 4, h = 4, n = w * h
        var px = [Float](repeating: 0, count: n * 3)
        for c in 0..<3 {
            for i in 0..<n { px[c * n + i] = Float(i) / Float(n - 1) } // 0…1 ramp per channel
        }
        return AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
    }

    func testNeutralByteIdenticalToPlainStretch() {
        let img = linearImage()
        let plain = AutoStretch.stretch(img)
        let neutral = AutoStretch.stretch(img, blackPoint: 0, midtoneStrength: 0)
        XCTAssertEqual(plain.pixels, neutral.pixels)   // exact byte-for-byte
    }

    func testBlackPointClipsAndRescales() {
        // Black-point clip is applied to the LINEAR input: x' = max(0,(x-bp)/(1-bp)).
        // Verify the clip transform directly on a known ramp via a helper.
        let bp = 0.25
        func clip(_ x: Double) -> Double { max(0, (x - bp) / (1 - bp)) }
        XCTAssertEqual(clip(0.25), 0, accuracy: 1e-9)      // at bp → 0
        XCTAssertEqual(clip(1.0), 1, accuracy: 1e-9)       // at 1 → 1
        XCTAssertEqual(clip(0.625), 0.5, accuracy: 1e-9)   // midway above bp
        // And a bp>0 stretch darkens: its minimum output <= the neutral minimum.
        let img = linearImage()
        let neutral = AutoStretch.stretch(img)
        let clipped = AutoStretch.stretch(img, blackPoint: 0.25)
        XCTAssertLessThanOrEqual(clipped.pixels.min()!, neutral.pixels.min()!)
    }

    func testMidtoneStrengthDirection() {
        // Positive strength brightens mids (harder stretch): mean output rises.
        let img = linearImage()
        let neutral = AutoStretch.stretch(img, midtoneStrength: 0)
        let harder  = AutoStretch.stretch(img, midtoneStrength: 0.8)
        let gentler = AutoStretch.stretch(img, midtoneStrength: -0.8)
        func mean(_ a: [Float]) -> Double { Double(a.reduce(0, +)) / Double(a.count) }
        XCTAssertGreaterThan(mean(harder.pixels), mean(neutral.pixels))
        XCTAssertLessThan(mean(gentler.pixels), mean(neutral.pixels))
    }

    func testSaturationIdentityGreyAndMono() {
        // factor 1 → identity.
        let w = 2, h = 1
        let px: [Float] = [0.8, 0.2,   0.3, 0.6,   0.1, 0.9]  // R:[.8,.2] G:[.3,.6] B:[.1,.9]
        let img = AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: false)
        let same = AutoStretch.applySaturation(img, 1)
        XCTAssertEqual(same.pixels, px)

        // factor 0 → all channels equal luminance L, and L is preserved.
        let grey = AutoStretch.applySaturation(img, 0)
        for i in 0..<(w * h) {
            let L = 0.2126 * Double(px[i]) + 0.7152 * Double(px[w*h + i]) + 0.0722 * Double(px[2*w*h + i])
            XCTAssertEqual(Double(grey.pixels[i]),          L, accuracy: 1e-6)
            XCTAssertEqual(Double(grey.pixels[w*h + i]),    L, accuracy: 1e-6)
            XCTAssertEqual(Double(grey.pixels[2*w*h + i]),  L, accuracy: 1e-6)
        }

        // mono (1-channel) passthrough.
        let mono = AstroImage(width: 2, height: 1, channels: 1, pixels: [0.2, 0.7], sourceIsLinear: false)
        XCTAssertEqual(AutoStretch.applySaturation(mono, 0).pixels, mono.pixels)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AutoStretchAdjustmentsTests`
Expected: compile failure — `extra arguments 'blackPoint', 'midtoneStrength'` / `type 'AutoStretch' has no member 'applySaturation'`.

- [ ] **Step 3: Implement**

In `Sources/LiveAstroCore/Imaging/AutoStretch.swift`, change the `stretch` signature (add the two trailing params):
```swift
    public static func stretch(_ image: AstroImage,
                               targetBackground: Double = 0.25,
                               shadowsClipping: Double = -2.8,
                               blackPoint: Double = 0,
                               midtoneStrength: Double = 0) -> AstroImage {
```

Immediately after that line, apply the black-point clip to the working pixels (identity when `blackPoint == 0`) and use `work` everywhere the method currently reads `image.pixels`:
```swift
        // Black-point: gentle shadow clip on the LINEAR data. bp==0 → identity.
        let bp = min(max(blackPoint, 0), 0.2)
        let work: [Float]
        if bp > 0 {
            let inv = 1.0 - bp
            work = image.pixels.map { Float(max(0, (Double($0) - bp) / inv)) }
        } else {
            work = image.pixels
        }
```
Then in the sampling loop and the final transform loop, replace `image.pixels[...]` reads with `work[...]`. Specifically the sample accumulation `s += image.pixels[c * plane + i]` becomes `s += work[c * plane + i]`, and the final loop `let x = (Double(image.pixels[idx]) - shadow) / denom` becomes `let x = (Double(work[idx]) - shadow) / denom`. (`image.width/height/channels/pixels.count` stay as-is — dimensions are unchanged.)

Adjust the midtone line (currently `let midtone = mtf(r, targetBackground)`, ~line 43) to scale by strength (strength==0 → factor 1 → unchanged):
```swift
        let strengthFactor = pow(2.0, -min(max(midtoneStrength, -1), 1))
        let midtone = min(max(mtf(r, targetBackground) * strengthFactor, 1e-4), 1 - 1e-4)
```

Add the saturation function (place after `stretch`):
```swift
    /// Luminance-preserving saturation on stretched, display-space [0,1] RGB.
    /// factor 1 → identity, 0 → greyscale (each channel = luminance), 2 → doubled
    /// chroma around luminance. Mono (channels != 3) is returned unchanged.
    public static func applySaturation(_ image: AstroImage, _ factor: Double) -> AstroImage {
        guard image.channels == 3 else { return image }
        let f = min(max(factor, 0), 2)
        if f == 1 { return image }
        let plane = image.width * image.height
        var out = image.pixels
        for i in 0..<plane {
            let r = Double(image.pixels[i])
            let g = Double(image.pixels[plane + i])
            let b = Double(image.pixels[2 * plane + i])
            let L = 0.2126 * r + 0.7152 * g + 0.0722 * b
            out[i]             = Float(min(max(L + f * (r - L), 0), 1))
            out[plane + i]     = Float(min(max(L + f * (g - L), 0), 1))
            out[2 * plane + i] = Float(min(max(L + f * (b - L), 0), 1))
        }
        return AstroImage(width: image.width, height: image.height, channels: image.channels,
                          pixels: out, sourceIsLinear: image.sourceIsLinear)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AutoStretchAdjustmentsTests`
Expected: PASS (4 tests). Also run `swift test --filter AutoStretchTests` (existing) to confirm the extended signature didn't disturb current behavior.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Imaging/AutoStretch.swift Tests/LiveAstroCoreTests/AutoStretchAdjustmentsTests.swift
git commit -m "feat: AutoStretch black-point + midtone strength + saturation"
```

---

### Task 3: SessionSettings.displayAdjustments persistence

**Files:**
- Modify: `Sources/LiveAstroCore/Settings/SessionSettings.swift`
- Test: `Tests/LiveAstroCoreTests/SessionSettingsTests.swift` (add cases; create if absent)

**Interfaces:**
- Consumes: `DisplayAdjustments` (Task 1); the existing `SessionSettings` Codable pattern (`processorBackend`).
- Produces: `SessionSettings.displayAdjustments: DisplayAdjustments`, defaulting to `.neutral`, backward-compatible decode.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/LiveAstroCoreTests/SessionSettingsTests.swift` (create the file with this content if it does not exist):
```swift
import XCTest
@testable import LiveAstroCore

final class SessionSettingsDisplayAdjTests: XCTestCase {
    func testDefaultsHaveNeutralAdjustments() {
        XCTAssertEqual(SessionSettings.defaults.displayAdjustments, .neutral)
    }

    func testRoundTripPreservesAdjustments() throws {
        var s = SessionSettings.defaults
        s.displayAdjustments = DisplayAdjustments(blackPoint: 0.05, midtoneStrength: 0.3, saturation: 1.4)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(SessionSettings.self, from: data)
        XCTAssertEqual(back.displayAdjustments, s.displayAdjustments)
    }

    func testOldBlobWithoutKeyDecodesNeutral() throws {
        // A settings JSON written before this field existed must decode to neutral.
        let json = """
        {"sourceModeRaw":"nativeStack","filePrefix":"Light_","neutralizeBackground":true,
         "subExposureSeconds":30,"targetName":"NGC 6960",
         "calibration":\(try calibrationJSON()),
         "rejectionEnabled":true,"rejectionStrength":"medium","processorBackend":"none"}
        """
        let s = try JSONDecoder().decode(SessionSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.displayAdjustments, .neutral)
    }

    // Encode the current default calibration so the old-blob JSON stays valid if
    // CalibrationSelection's shape changes.
    private func calibrationJSON() throws -> String {
        String(data: try JSONEncoder().encode(SessionSettings.defaults.calibration), encoding: .utf8)!
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SessionSettingsDisplayAdjTests`
Expected: compile failure — `value of type 'SessionSettings' has no member 'displayAdjustments'`.

- [ ] **Step 3: Implement**

In `Sources/LiveAstroCore/Settings/SessionSettings.swift`, mirror `processorBackend` exactly:

Add the stored field after `processorBackend`:
```swift
    public var displayAdjustments: DisplayAdjustments
```
Add an init parameter (default `.neutral`) and assignment. In the memberwise `init(...)`, add `displayAdjustments: DisplayAdjustments = .neutral` to the parameter list and `self.displayAdjustments = displayAdjustments` to the body.
Add the CodingKey: extend the `case processorBackend` line to `case processorBackend, displayAdjustments`.
In `init(from:)`, after the `processorBackend` decode, add:
```swift
        displayAdjustments = try c.decodeIfPresent(DisplayAdjustments.self, forKey: .displayAdjustments) ?? .neutral
```
In `static let defaults = SessionSettings(...)`, add `displayAdjustments: .neutral` to the argument list.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SessionSettingsDisplayAdjTests`
Expected: PASS (3 tests). Also run any existing `SessionSettings` tests to confirm no regression.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Settings/SessionSettings.swift Tests/LiveAstroCoreTests/SessionSettingsTests.swift
git commit -m "feat: persist displayAdjustments in SessionSettings (backward-compatible)"
```

---

### Task 4: SessionPipeline applies adjustments + renderCurrentDisplay

**Files:**
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift`
- Test: `Tests/LiveAstroCoreTests/SessionPipelineDisplayAdjTests.swift`

**Interfaces:**
- Consumes: `DisplayAdjustments` (Task 1); `AutoStretch.stretch(...blackPoint:midtoneStrength:)` + `applySaturation` (Task 2); existing `engine`, `AutoStretch.makeCGImage`, `AutoStretch.neutralizeBackground(Additive)`, `StackEngine.currentStack()`.
- Produces:
  - `public var displayAdjustments: DisplayAdjustments` (lock-guarded) on `SessionPipeline`.
  - `public func renderCurrentDisplay(adjustments: DisplayAdjustments) -> CGImage?` — sets the stored adjustments, then re-renders the current stack (nil if no stack/engine).
  - `displayCGImage(from:)` applies the stored adjustments internally (no signature change at call sites).

- [ ] **Step 1: Write the failing tests**

Create `Tests/LiveAstroCoreTests/SessionPipelineDisplayAdjTests.swift`. Match the existing `SessionPipeline` test construction pattern — open `Tests/LiveAstroCoreTests/SessionPipelineTests.swift` and copy how it builds a native-mode pipeline + feeds a frame; the two tests below only need (a) a pipeline with no frames yet and (b) a pipeline that has accepted one frame:
```swift
import XCTest
@testable import LiveAstroCore

final class SessionPipelineDisplayAdjTests: XCTestCase {
    func testRenderCurrentDisplayNilWithoutStack() throws {
        let pipeline = try SessionPipelineTests.makeNativePipeline()  // reuse existing helper
        XCTAssertNil(pipeline.renderCurrentDisplay(adjustments: .neutral))
    }

    func testRenderCurrentDisplayNonNilAfterFrame() throws {
        let pipeline = try SessionPipelineTests.makeNativePipeline()
        try SessionPipelineTests.feedOneSyntheticFrame(pipeline)     // reuse existing helper
        XCTAssertNotNil(pipeline.renderCurrentDisplay(adjustments: DisplayAdjustments(saturation: 1.5)))
        XCTAssertEqual(pipeline.displayAdjustments.saturation, 1.5)  // stored for the next frame's snapshot
    }
}
```
If `SessionPipelineTests` has no reusable helpers, inline the minimal native-pipeline construction the existing tests use (same watch dir + one synthetic FITS sub) rather than inventing a new path — the goal is only "no stack → nil, one frame → non-nil".

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SessionPipelineDisplayAdjTests`
Expected: compile failure — `value of type 'SessionPipeline' has no member 'renderCurrentDisplay'` / `displayAdjustments`.

- [ ] **Step 3: Implement**

In `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift`:

Add a lock-guarded stored property (the frame loop and the off-main re-render both read it, so guard it):
```swift
    private let adjLock = NSLock()
    private var _displayAdjustments = DisplayAdjustments.neutral
    /// Display-path adjustments (black-point / midtone / saturation). Read once
    /// per render; guarded because the frame loop and the live re-render access
    /// it from different threads.
    public var displayAdjustments: DisplayAdjustments {
        get { adjLock.lock(); defer { adjLock.unlock() }; return _displayAdjustments }
        set { adjLock.lock(); _displayAdjustments = newValue; adjLock.unlock() }
    }
```

In `displayCGImage(from linear:)`, read the adjustments once and thread them through the existing stretch + a new saturation step. Replace the current body:
```swift
    private func displayCGImage(from linear: AstroImage) throws -> CGImage {
        let adj = displayAdjustments                        // single locked read, no tearing
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
(Keep the exact `ImageLoaderError`/return shape already in the file; only the stretch/saturation lines are new. The two existing callers at the live and import frame handlers are unchanged — they still call `displayCGImage(from:)`.)

Add the re-render entry point (near the other public methods). Use the file's actual engine property name/optionality — the master-finalize code already reads `engine` as optional via `if let eng = engine`:
```swift
    /// Re-render the current stack with the given adjustments, for live slider
    /// feedback. Stores the adjustments (so the next frame's snapshot matches),
    /// then renders engine.currentStack(). Returns nil when there is no stack yet.
    public func renderCurrentDisplay(adjustments: DisplayAdjustments) -> CGImage? {
        displayAdjustments = adjustments
        guard let mean = engine?.currentStack() else { return nil }
        return try? displayCGImage(from: mean)
    }
```

Do **not** modify the `master.fit` write path — it does not call `displayCGImage` and must stay linear.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SessionPipelineDisplayAdjTests`
Expected: PASS (2 tests). Then run the full Core suite once: `swift test --filter LiveAstroCoreTests` — all green, confirming the `displayCGImage` change didn't disturb existing pipeline/e2e tests (neutral adjustments = identical output).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Pipeline/SessionPipeline.swift Tests/LiveAstroCoreTests/SessionPipelineDisplayAdjTests.swift
git commit -m "feat: SessionPipeline applies display adjustments + renderCurrentDisplay"
```

---

### Task 5: AppModel throttled re-render + Display Adjustments UI

**Files:**
- Modify: `Sources/LiveAstroStudio/AppModel.swift`
- Modify: `Sources/LiveAstroStudio/ControlView.swift`

**Interfaces:**
- Consumes: `DisplayAdjustments`; `SessionPipeline.displayAdjustments` + `renderCurrentDisplay(adjustments:)` (Task 4); `SessionSettings.displayAdjustments` (Task 3); existing `latestImage: CGImage?`, `pipeline`, `saveSettings()`, settings load path.
- Produces: `AppModel.displayAdjustments` (observable) with a throttled off-main re-render; a Display Adjustments UI section.

**Note:** No unit test — SwiftUI `@Observable`/window lifecycle is out of unit-test scope (same convention as the prior pillars). Verified by a clean RELEASE build (Step 4).

- [ ] **Step 1: Add the observable property + settings load/save**

In `Sources/LiveAstroStudio/AppModel.swift`, near the other state `var`s, add:
```swift
    var displayAdjustments = DisplayAdjustments.neutral
```
Wire it into the existing settings load and `saveSettings()` alongside the other fields (find where `rejectionEnabled`/`processorBackend` are read from / written to `SessionSettings` and add `displayAdjustments` the same way — read `settings.displayAdjustments` on load, write `displayAdjustments` into the `SessionSettings(...)` you build in `saveSettings()`).

- [ ] **Step 2: Add the throttled off-main re-render**

Add a throttle timestamp and an apply method in `AppModel`:
```swift
    private var lastAdjustmentRender = Date.distantPast

    /// Called when a slider changes: persist, push adjustments to the pipeline so
    /// the next frame's snapshot matches, and re-render the current stack off-main
    /// (throttled to ~12 fps so dragging a 26MP stretch stays smooth).
    func applyDisplayAdjustments() {
        saveSettings()
        guard let pipeline else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAdjustmentRender) > 0.08 else { return }
        lastAdjustmentRender = now
        let adj = displayAdjustments
        Task.detached { [weak self] in
            let cg = pipeline.renderCurrentDisplay(adjustments: adj)
            await MainActor.run {
                guard let self, let cg else { return }
                self.latestImage = cg
            }
        }
    }
```
(If the AppModel's live image property is not named `latestImage`, use the actual name confirmed in the file — it is the `CGImage?` the Live/Broadcast view renders.)

- [ ] **Step 3: Add the Display Adjustments UI section**

In `Sources/LiveAstroStudio/ControlView.swift`, add a section (match the existing `@Bindable var model` + `.help()` idioms used by the rejection/processor sections):
```swift
            Section("Display Adjustments") {
                VStack(alignment: .leading) {
                    Text("Black point")
                    Slider(value: $model.displayAdjustments.blackPoint, in: 0...0.2) { editing in
                        if !editing { model.applyDisplayAdjustments() }
                    }
                    .help("Darken the sky background. 0 = auto.")
                }
                VStack(alignment: .leading) {
                    Text("Stretch strength")
                    Slider(value: $model.displayAdjustments.midtoneStrength, in: -1...1) { editing in
                        if !editing { model.applyDisplayAdjustments() }
                    }
                    .help("How aggressive the stretch is. 0 = auto.")
                }
                VStack(alignment: .leading) {
                    Text("Saturation")
                    Slider(value: $model.displayAdjustments.saturation, in: 0...2) { editing in
                        if !editing { model.applyDisplayAdjustments() }
                    }
                    .help("Color intensity. 1 = unchanged.")
                }
                Button("Reset") {
                    model.displayAdjustments = .neutral
                    model.applyDisplayAdjustments()
                }
                .help("Back to the neutral auto-stretch look.")
            }
```
Using the Slider `onEditingChanged` (`if !editing`) fires a render on release; for live dragging feedback, also call `model.applyDisplayAdjustments()` from a `.onChange(of: model.displayAdjustments)` on the enclosing view — the 0.08s throttle in `applyDisplayAdjustments` keeps drag updates cheap. Wire whichever of the two (release-only vs onChange+throttle) matches how the other live controls in this file behave; if unsure, release-only is the safe minimum.

- [ ] **Step 4: Build debug + RELEASE**

Run: `swift build`
Expected: `Build complete!`
Run: `swift build -c release --scratch-path /private/tmp/las-release-build`
Expected: `Build complete!` (local scratch path avoids the iCloud-Desktop build.db disk-I/O error).

- [ ] **Step 5: Run the full Core suite (no regression)**

Run: `swift test --filter LiveAstroCoreTests`
Expected: all pass (T5 changes only the app target; this confirms T1–T4 still green together).

- [ ] **Step 6: Commit**

```bash
git add Sources/LiveAstroStudio/AppModel.swift Sources/LiveAstroStudio/ControlView.swift
git commit -m "feat: Display Adjustments panel + throttled live re-render"
```

---

## Notes for the implementer

- The neutral guarantee is the load-bearing invariant: `blackPoint=0, midtoneStrength=0, saturation=1` must leave every output pixel exactly as today. `testNeutralByteIdenticalToPlainStretch` (T2) is the guard — do not weaken it.
- Do NOT touch the `master.fit` finalize path in `SessionPipeline` — the master stays linear. Only the `displayCGImage` display path gets adjustments.
- `applySaturation` runs on stretched, display-space [0,1] RGB (after `stretch`), never on linear data.
- Clamp adjustment values on APPLY (in AutoStretch), never in `DisplayAdjustments.init` — a persisted out-of-range blob must decode unchanged.
- The pipeline's `displayAdjustments` is lock-guarded because the frame loop and the live re-render read it from different threads; read it once per render into a local.
