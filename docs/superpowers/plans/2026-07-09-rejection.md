# Native-Stacker Rejection Pillar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove satellite/plane/cosmic-ray outliers during native stacking via online winsorized κ-σ, as a pluggable strategy, on by default, live and import.

**Architecture:** A `RejectionMethod` protocol (`NoRejection` + `WinsorizedSigmaClip`) that `StackEngine` applies to each warped frame right before it hits the unchanged `StackAccumulator`. The winsorizer keeps per-pixel Welford stats (O(1) in frame count) and clamps each pixel to ±kσ after a per-pixel warm-up. UI toggle + strength, persisted in `SessionSettings`.

**Tech Stack:** Swift 5.10, SwiftUI, SPM, macOS 14+, XCTest. Zero external dependencies.

## Global Constraints

- Zero external dependencies — only Foundation, CoreGraphics, AVFoundation, CryptoKit, Accelerate/vImage (system frameworks).
- Swift 5.10, macOS 14+. Tests via `swift test` from the repo root (use fully-qualified `--filter LiveAstroCoreTests.<Suite>`; the bare form can report "No matching test cases").
- **`StackAccumulator` stays UNCHANGED** (it remains a dumb weighted mean).
- Winsorize (clamp to ±kσ, keep the sample) — never drop; no per-pixel weight loss (the validated no-noise-penalty property).
- Update the running Welford stats with the **clamped** value (not the raw) so a persistent bright trail cannot inflate σ.
- Per-pixel warm-up `W = 8`: accept raw until that pixel's in-bounds count ≥ W, then clip.
- Strength → κ: Low = 3.5, Medium = 3.0 (default), High = 2.5.
- Rejection defaults ON; `NoRejection` is byte-identical to today's behavior; `StackEngine`'s new `rejection:` param defaults to `NoRejection()` so existing callers/tests are unchanged.

**Existing interfaces this plan consumes (verbatim):**
- `struct AstroImage { let width, height, channels: Int; let pixels: [Float] /* planar top-down 0…1 */; let sourceIsLinear: Bool; init(width:height:channels:pixels:sourceIsLinear:) }`
- `StackEngine`: `public init(seedMinStars: Int = 15, minMatches: Int = 8, inlierTolerance: Double = 2.0)`; `public func reseed()`; `public func process(_ frame: RawFrame) -> StackOutcome`; `public func currentStack() -> AstroImage?`. In `processLocked`, the reference-seed path does `acc.add(rgb, mask: [Float](repeating: 1, count: rgb.width*rgb.height))`; the stacked path does `let (warped, mask) = Warp.apply(rgb, transform: half.liftedToFullResolution()); accumulator.add(warped, mask: mask)`. `reseed()` nils `accumulator`/`referenceStars`/`referenceSize`/`referenceChannels` inside `lock.withLock`.
- `StackAccumulator.add(_ image: AstroImage, mask: [Float])`, `.mean() -> AstroImage`, `.frameCount`.
- `SessionSettings: Codable, Equatable` with fields `sourceModeRaw, watchFolderPath, filePrefix, neutralizeBackground, subExposureSeconds, targetName, calibration` + `static var defaults`.
- `SessionPipeline(nativeSource:engine:profile:rootDirectory:…, neutralizeBackground:, calibrator:)`.
- `AppModel`: `startSession()`, `importSubs(from:)` construct `StackEngine()` for native mode; `currentSettings()/saveSettings()/loadSettings()` map fields ↔ `SessionSettings`.
- Test fixture pattern (from `NativePipelineTests`): `FITSWriter.float32(width:height:channels:1, pixels:).write(to:)`, mono starfields with ~18 stars.

---

### Task 1: RejectionMethod protocol + NoRejection + RejectionStrength

**Files:**
- Create: `Sources/LiveAstroCore/Stacking/RejectionMethod.swift`
- Test: `Tests/LiveAstroCoreTests/RejectionMethodTests.swift`

**Interfaces:**
- Produces: `protocol RejectionMethod: AnyObject { func apply(_ frame: AstroImage, mask: [Float]) -> AstroImage; func reset() }`; `final class NoRejection: RejectionMethod`; `enum RejectionStrength: String, CaseIterable, Codable { case low, medium, high; var kappa: Float }`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class RejectionMethodTests: XCTestCase {
    func img(_ px: [Float], w: Int = 2, h: Int = 1, c: Int = 1) -> AstroImage {
        AstroImage(width: w, height: h, channels: c, pixels: px, sourceIsLinear: true)
    }

    func testNoRejectionIsIdentity() {
        let f = img([0.1, 0.9])                     // 0.9 would be an outlier, but NoRejection keeps it
        let out = NoRejection().apply(f, mask: [1, 1])
        XCTAssertEqual(out.pixels, [0.1, 0.9])
    }

    func testNoRejectionResetIsNoOp() {
        let r = NoRejection(); r.reset()            // must not crash
        XCTAssertEqual(r.apply(img([0.2, 0.3]), mask: [1, 1]).pixels, [0.2, 0.3])
    }

    func testStrengthKappaMapping() {
        XCTAssertEqual(RejectionStrength.low.kappa, 3.5)
        XCTAssertEqual(RejectionStrength.medium.kappa, 3.0)
        XCTAssertEqual(RejectionStrength.high.kappa, 2.5)
        XCTAssertEqual(RejectionStrength.allCases.count, 3)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LiveAstroCoreTests.RejectionMethodTests`
Expected: FAIL — `RejectionMethod`/`NoRejection`/`RejectionStrength` undefined.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Transforms an incoming warped frame before it is accumulated, updating its own
/// per-pixel running state. Reference type (holds mutable state).
public protocol RejectionMethod: AnyObject {
    /// Returns the frame to accumulate. Only pixels where `mask[i] > 0` are treated
    /// as in-bounds (stats updated + clamped there); other pixels pass through.
    func apply(_ frame: AstroImage, mask: [Float]) -> AstroImage
    /// Discard all accumulated per-pixel state (called from StackEngine.reseed()).
    func reset()
}

/// Pass-through — preserves today's behavior exactly.
public final class NoRejection: RejectionMethod {
    public init() {}
    public func apply(_ frame: AstroImage, mask: [Float]) -> AstroImage { frame }
    public func reset() {}
}

/// UI strength → κ (sigma multiplier). Higher κ = safer (rejects less).
public enum RejectionStrength: String, CaseIterable, Codable {
    case low, medium, high
    public var kappa: Float {
        switch self {
        case .low:    return 3.5
        case .medium: return 3.0
        case .high:   return 2.5
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LiveAstroCoreTests.RejectionMethodTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Stacking/RejectionMethod.swift Tests/LiveAstroCoreTests/RejectionMethodTests.swift
git commit -m "feat: RejectionMethod protocol + NoRejection + RejectionStrength"
```

---

### Task 2: WinsorizedSigmaClip (online Welford winsorizer)

**Files:**
- Create: `Sources/LiveAstroCore/Stacking/WinsorizedSigmaClip.swift`
- Test: `Tests/LiveAstroCoreTests/WinsorizedSigmaClipTests.swift`

**Interfaces:**
- Consumes: `RejectionMethod`, `AstroImage`.
- Produces: `final class WinsorizedSigmaClip: RejectionMethod { init(kappa: Float = 3.0, warmUp: Int = 8) }`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class WinsorizedSigmaClipTests: XCTestCase {
    // single-pixel 1x1 mono frame
    func px(_ v: Float) -> AstroImage {
        AstroImage(width: 1, height: 1, channels: 1, pixels: [v], sourceIsLinear: true)
    }
    let m: [Float] = [1]

    func testWarmUpPassesRaw() {
        let r = WinsorizedSigmaClip(kappa: 3, warmUp: 8)
        // first frame is a wild outlier; within warm-up it must pass through untouched
        XCTAssertEqual(r.apply(px(0.9), mask: m).pixels[0], 0.9, accuracy: 1e-6)
    }

    func testOutlierClampedAfterWarmUp() {
        let r = WinsorizedSigmaClip(kappa: 3, warmUp: 8)
        // 8 warm-up frames with small spread around ~0.05 → σ ≈ 0.008
        for v: Float in [0.042, 0.058, 0.05, 0.046, 0.054, 0.05, 0.048, 0.052] { _ = r.apply(px(v), mask: m) }
        // 9th frame is a bright streak; count == 8 ≥ warmUp → clamp to ≈ mean + 3σ (well below 0.9)
        let out = r.apply(px(0.9), mask: m).pixels[0]
        XCTAssertLessThan(out, 0.2)
        XCTAssertGreaterThan(out, 0.05)   // clamped near the mean, not zeroed
    }

    func testInDistributionValueUnchanged() {
        let r = WinsorizedSigmaClip(kappa: 3, warmUp: 8)
        for v: Float in [0.042, 0.058, 0.05, 0.046, 0.054, 0.05, 0.048, 0.052] { _ = r.apply(px(v), mask: m) }
        // a value within ±3σ of the mean must pass through unclamped
        let inD: Float = 0.056
        XCTAssertEqual(r.apply(px(inD), mask: m).pixels[0], inD, accuracy: 1e-5)
    }

    func testUpdateWithClampedKeepsSigmaBounded() {
        let r = WinsorizedSigmaClip(kappa: 3, warmUp: 8)
        for v: Float in [0.042, 0.058, 0.05, 0.046, 0.054, 0.05, 0.048, 0.052] { _ = r.apply(px(v), mask: m) }
        // repeated bright outliers: each stays clamped near the mean because stats update
        // with the CLAMPED value (σ never grows to admit 0.9)
        var last: Float = 0
        for _ in 0..<5 { last = r.apply(px(0.9), mask: m).pixels[0] }
        XCTAssertLessThan(last, 0.2)
    }

    func testResetRestartsWarmUp() {
        let r = WinsorizedSigmaClip(kappa: 3, warmUp: 8)
        for v: Float in [0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05] { _ = r.apply(px(v), mask: m) }
        r.reset()
        // after reset, an outlier is within warm-up again → passes raw
        XCTAssertEqual(r.apply(px(0.9), mask: m).pixels[0], 0.9, accuracy: 1e-6)
    }

    func testMaskedPixelUntouched() {
        let r = WinsorizedSigmaClip(kappa: 3, warmUp: 1)
        // 2-pixel frame; pixel 1 masked-out (mask 0) must pass through with no state/clamp
        _ = r.apply(AstroImage(width: 2, height: 1, channels: 1, pixels: [0.05, 0.9], sourceIsLinear: true), mask: [1, 0])
        let out = r.apply(AstroImage(width: 2, height: 1, channels: 1, pixels: [0.05, 0.9], sourceIsLinear: true), mask: [1, 0])
        XCTAssertEqual(out.pixels[1], 0.9, accuracy: 1e-6)   // never clamped — always out-of-bounds
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LiveAstroCoreTests.WinsorizedSigmaClipTests`
Expected: FAIL — `WinsorizedSigmaClip` undefined.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Online winsorized κ-σ rejection. Per pixel·channel it keeps running Welford
/// stats (count, mean, M2) and, after a per-pixel warm-up, clamps each incoming
/// value to ±kσ of the running mean. Memory is O(image), O(1) in frame count.
public final class WinsorizedSigmaClip: RejectionMethod {
    private let kappa: Float
    private let warmUp: Float
    private var count: [Float] = []
    private var mean: [Float] = []
    private var m2: [Float] = []

    public init(kappa: Float = 3.0, warmUp: Int = 8) {
        self.kappa = kappa
        self.warmUp = Float(warmUp)
    }

    public func reset() { count = []; mean = []; m2 = [] }

    public func apply(_ frame: AstroImage, mask: [Float]) -> AstroImage {
        let plane = frame.width * frame.height
        let n = frame.pixels.count
        if count.count != n {                 // lazy alloc / dimension change
            count = [Float](repeating: 0, count: n)
            mean  = [Float](repeating: 0, count: n)
            m2    = [Float](repeating: 0, count: n)
        }
        var out = frame.pixels
        for c in 0..<frame.channels {
            let base = c * plane
            for i in 0..<plane where mask[i] > 0 {
                let idx = base + i
                var v = frame.pixels[idx]
                if count[idx] >= warmUp {                         // clip only after warm-up
                    let sigma = (m2[idx] / count[idx]).squareRoot()
                    let lo = mean[idx] - kappa * sigma
                    let hi = mean[idx] + kappa * sigma
                    if v < lo { v = lo } else if v > hi { v = hi }
                    out[idx] = v
                }
                // Welford update with v (raw during warm-up, clamped after)
                count[idx] += 1
                let d = v - mean[idx]
                mean[idx] += d / count[idx]
                m2[idx] += d * (v - mean[idx])
            }
        }
        return AstroImage(width: frame.width, height: frame.height,
                          channels: frame.channels, pixels: out,
                          sourceIsLinear: frame.sourceIsLinear)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LiveAstroCoreTests.WinsorizedSigmaClipTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Stacking/WinsorizedSigmaClip.swift Tests/LiveAstroCoreTests/WinsorizedSigmaClipTests.swift
git commit -m "feat: WinsorizedSigmaClip — online Welford per-pixel winsorizing"
```

---

### Task 3: StackEngine integration + A/B satellite proof

**Files:**
- Modify: `Sources/LiveAstroCore/Stacking/StackEngine.swift`
- Test: `Tests/LiveAstroCoreTests/RejectionEngineTests.swift`

**Interfaces:**
- Consumes: `RejectionMethod`, `NoRejection`, `WinsorizedSigmaClip`.
- Produces: `StackEngine.init(seedMinStars:minMatches:inlierTolerance:rejection:)` with `rejection: RejectionMethod = NoRejection()`; rejection applied at both accumulate sites; `reseed()` also calls `rejection.reset()`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class RejectionEngineTests: XCTestCase {
    /// Identical mono starfield (18 stars) so registration is identity (no warp shift);
    /// `streakRow` (if >= 0) paints a bright horizontal streak into this frame.
    func frame(streakRow: Int) -> RawFrame {
        let w = 128, h = 128
        var px = [Float](repeating: 0.05, count: w * h)
        for i in 0..<18 {
            let sx = (i * 37) % 116 + 6, sy = (i * 53) % 116 + 6
            for y in max(0, sy-3)...min(h-1, sy+3) {
                for x in max(0, sx-3)...min(w-1, sx+3) {
                    let dx = Double(x-sx), dy = Double(y-sy)
                    px[y*w+x] += 0.8 * Float(exp(-(dx*dx+dy*dy)/4))
                }
            }
        }
        if streakRow >= 0 { for x in 0..<w { px[streakRow*w+x] = 0.9 } }   // bright streak
        return RawFrame(image: AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true),
                        bayerPattern: nil, bottomUp: false, timestamp: Date(), sourceName: "f.fit")
    }

    /// Stack 20 identical frames; frame #10 carries a streak on row 40. Returns the
    /// stacked value at a streak pixel (row 40, col 64), for the given engine.
    func stackedStreakValue(_ engine: StackEngine) -> Float {
        for i in 0..<20 { _ = engine.process(frame(streakRow: i == 10 ? 40 : -1)) }
        let mean = engine.currentStack()!
        return mean.pixels[40 * mean.width + 64]
    }

    func testRejectionRemovesStreakThatNoRejectionDilutes() {
        let withReject = StackEngine(rejection: WinsorizedSigmaClip(kappa: 3, warmUp: 8))
        let without = StackEngine()   // default NoRejection
        let r = stackedStreakValue(withReject)
        let n = stackedStreakValue(without)
        // NoRejection dilutes the 1-frame streak: ~ (0.9 + 19*0.05)/20 ≈ 0.0925
        XCTAssertGreaterThan(n, 0.08)
        // Winsorized clamps it away → close to the 0.05 background
        XCTAssertLessThan(r, 0.06)
        XCTAssertLessThan(r, n)       // rejection strictly cleaner
    }

    func testReseedResetsRejectionState() {
        let engine = StackEngine(rejection: WinsorizedSigmaClip(kappa: 3, warmUp: 8))
        for i in 0..<12 { _ = engine.process(frame(streakRow: -1)) }
        engine.reseed()
        // after reseed the next frame becomes the reference (fresh stats); no crash, stacks cleanly
        _ = engine.process(frame(streakRow: -1))
        XCTAssertNotNil(engine.currentStack())
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LiveAstroCoreTests.RejectionEngineTests`
Expected: FAIL — `rejection:` argument does not exist on `StackEngine.init`.

- [ ] **Step 3: Modify StackEngine**

Add the stored property and init parameter:
```swift
    private let rejection: RejectionMethod

    public init(seedMinStars: Int = 15, minMatches: Int = 8, inlierTolerance: Double = 2.0,
                rejection: RejectionMethod = NoRejection()) {
        self.seedMinStars = seedMinStars
        self.minMatches = minMatches
        self.inlierTolerance = inlierTolerance
        self.rejection = rejection
    }
```

In `reseed()`, add `rejection.reset()` inside the `lock.withLock` block (alongside the existing nils).

At the **reference-seed** site, route the seed through the rejector:
```swift
            let rgb = displayRGB(frame)
            let ones = [Float](repeating: 1, count: rgb.width * rgb.height)
            let seed = rejection.apply(rgb, mask: ones)
            let acc = StackAccumulator(width: rgb.width, height: rgb.height, channels: rgb.channels)
            acc.add(seed, mask: ones)
```

At the **stacked** site, clean the warped frame before accumulating:
```swift
        let (warped, mask) = Warp.apply(rgb, transform: half.liftedToFullResolution())
        let cleaned = rejection.apply(warped, mask: mask)
        accumulator.add(cleaned, mask: mask)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LiveAstroCoreTests.RejectionEngineTests` then `swift test --filter LiveAstroCoreTests.StackEngineTests` and `swift test --filter LiveAstroCoreTests.NativePipelineTests`
Expected: new tests PASS; existing StackEngine/NativePipeline tests still PASS (default `NoRejection` = byte-identical behavior).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Stacking/StackEngine.swift Tests/LiveAstroCoreTests/RejectionEngineTests.swift
git commit -m "feat: apply RejectionMethod in StackEngine before accumulate (A/B satellite proof)"
```

---

### Task 4: SessionSettings rejection fields (backward-compatible)

**Files:**
- Modify: `Sources/LiveAstroCore/Settings/SessionSettings.swift`
- Test: `Tests/LiveAstroCoreTests/SessionSettingsTests.swift` (add cases)

**Interfaces:**
- Consumes: `RejectionStrength` (Task 1).
- Produces: `SessionSettings.rejectionEnabled: Bool` (default true), `.rejectionStrength: RejectionStrength` (default `.medium`), with a custom `init(from:)` that defaults these when absent from an older stored blob.

- [ ] **Step 1: Write the failing test**

```swift
    func testRejectionDefaults() {
        let d = SessionSettings.defaults
        XCTAssertTrue(d.rejectionEnabled)
        XCTAssertEqual(d.rejectionStrength, .medium)
    }

    func testRejectionRoundTrips() {
        let dd = defaults()
        var s = SessionSettings.defaults
        s.rejectionEnabled = false; s.rejectionStrength = .high
        SessionSettingsStore.save(s, to: dd)
        XCTAssertEqual(SessionSettingsStore.load(dd), s)
    }

    func testOldBlobWithoutRejectionKeysDecodesToDefaults() throws {
        // an older SessionSettings JSON (no rejection keys) must decode with rejection
        // defaults rather than failing the whole load and wiping other settings.
        let dd = defaults()
        let json = """
        {"sourceModeRaw":"Raw subs (native stacking)","watchFolderPath":null,
         "filePrefix":"Light_","neutralizeBackground":true,"subExposureSeconds":10,
         "targetName":"M8","calibration":{"darkPath":null,"flatPath":null,"biasPath":null}}
        """
        dd.set(Data(json.utf8), forKey: "sessionSettings.v1")
        let loaded = SessionSettingsStore.load(dd)
        XCTAssertEqual(loaded.targetName, "M8")            // old fields preserved
        XCTAssertTrue(loaded.rejectionEnabled)              // new fields defaulted
        XCTAssertEqual(loaded.rejectionStrength, .medium)
    }
```

(The `defaults()` helper already exists in this test file.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LiveAstroCoreTests.SessionSettingsTests`
Expected: FAIL — `rejectionEnabled` undefined.

- [ ] **Step 3: Implement**

Add the two stored properties, extend the memberwise `init` and `defaults`, and add a custom `init(from:)` that defaults the new keys when missing:

```swift
public struct SessionSettings: Codable, Equatable {
    public var sourceModeRaw: String
    public var watchFolderPath: String?
    public var filePrefix: String
    public var neutralizeBackground: Bool
    public var subExposureSeconds: Double
    public var targetName: String
    public var calibration: CalibrationSelection
    public var rejectionEnabled: Bool
    public var rejectionStrength: RejectionStrength

    public init(sourceModeRaw: String, watchFolderPath: String?, filePrefix: String,
                neutralizeBackground: Bool, subExposureSeconds: Double, targetName: String,
                calibration: CalibrationSelection,
                rejectionEnabled: Bool = true, rejectionStrength: RejectionStrength = .medium) {
        self.sourceModeRaw = sourceModeRaw; self.watchFolderPath = watchFolderPath
        self.filePrefix = filePrefix; self.neutralizeBackground = neutralizeBackground
        self.subExposureSeconds = subExposureSeconds; self.targetName = targetName
        self.calibration = calibration
        self.rejectionEnabled = rejectionEnabled; self.rejectionStrength = rejectionStrength
    }

    // Backward-compatible decode: older blobs lack the rejection keys → default them
    // (so updating the app doesn't wipe the user's other saved settings).
    private enum CodingKeys: String, CodingKey {
        case sourceModeRaw, watchFolderPath, filePrefix, neutralizeBackground
        case subExposureSeconds, targetName, calibration, rejectionEnabled, rejectionStrength
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceModeRaw = try c.decode(String.self, forKey: .sourceModeRaw)
        watchFolderPath = try c.decodeIfPresent(String.self, forKey: .watchFolderPath)
        filePrefix = try c.decode(String.self, forKey: .filePrefix)
        neutralizeBackground = try c.decode(Bool.self, forKey: .neutralizeBackground)
        subExposureSeconds = try c.decode(Double.self, forKey: .subExposureSeconds)
        targetName = try c.decode(String.self, forKey: .targetName)
        calibration = try c.decode(CalibrationSelection.self, forKey: .calibration)
        rejectionEnabled = try c.decodeIfPresent(Bool.self, forKey: .rejectionEnabled) ?? true
        rejectionStrength = try c.decodeIfPresent(RejectionStrength.self, forKey: .rejectionStrength) ?? .medium
    }

    public static var defaults: SessionSettings {
        SessionSettings(sourceModeRaw: "Stacker output (Siril)", watchFolderPath: nil,
                        filePrefix: "live_stack", neutralizeBackground: false,
                        subExposureSeconds: 60, targetName: "",
                        calibration: CalibrationSelection(darkPath: nil, flatPath: nil, biasPath: nil),
                        rejectionEnabled: true, rejectionStrength: .medium)
    }
}
```

(`Encodable` stays synthesized; only `init(from:)` is custom. `SessionSettingsStore` is unchanged.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LiveAstroCoreTests.SessionSettingsTests`
Expected: PASS (existing 3 + 3 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Settings/SessionSettings.swift Tests/LiveAstroCoreTests/SessionSettingsTests.swift
git commit -m "feat: persist rejection settings (backward-compatible decode)"
```

---

### Task 5: Wire rejection into AppModel

**Files:**
- Modify: `Sources/LiveAstroStudio/AppModel.swift`

No unit test (app-layer glue over tested core). Deliverable: the native `StackEngine` is built with the chosen rejection method, and the setting persists.

- [ ] **Step 1: Add rejection state + settings mapping**

Add to `AppModel`:
```swift
    var rejectionEnabled = true
    var rejectionStrength: RejectionStrength = .medium
```
In `currentSettings()`, add `rejectionEnabled: rejectionEnabled, rejectionStrength: rejectionStrength` to the `SessionSettings(...)` call. In `loadSettings()`, add `rejectionEnabled = s.rejectionEnabled; rejectionStrength = s.rejectionStrength`.

- [ ] **Step 2: Build the StackEngine with the chosen rejection**

Add a helper and use it wherever the native `StackEngine()` is constructed (both `startSession()`'s `.nativeStack` path and `importSubs(from:)`):
```swift
    private func makeStackEngine() -> StackEngine {
        let rejection: RejectionMethod = rejectionEnabled
            ? WinsorizedSigmaClip(kappa: rejectionStrength.kappa)
            : NoRejection()
        return StackEngine(rejection: rejection)
    }
```
Replace the `StackEngine()` calls in the native `SessionPipeline(nativeSource:engine:…)` constructions with `makeStackEngine()`. (Read those two call sites and swap `engine: StackEngine()` → `engine: makeStackEngine()`.)

- [ ] **Step 3: Build + manual validation**

Run: `swift build`
Manual: with rejection on (default), run an import of a folder containing a sub with a satellite trail → the trail is gone/greatly reduced in the stacked master; toggle off and re-import → trail visible (diluted). Relaunch → the rejection toggle/strength are remembered.

- [ ] **Step 4: Commit**

```bash
git add Sources/LiveAstroStudio/AppModel.swift
git commit -m "feat: build StackEngine with chosen rejection method; persist rejection settings"
```

---

### Task 6: Rejection UI (toggle + strength + tooltips)

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift`

No unit test (SwiftUI). Deliverable: a rejection toggle (default on) + strength picker shown when on, in the Setup form.

- [ ] **Step 1: Add the controls**

In `ControlView`'s Setup form (near the Neutralize-background control), add:
```swift
    Toggle("Reject outliers (σ-clip)", isOn: $model.rejectionEnabled)
        .help("Drop satellite / plane / cosmic-ray streaks by clamping pixels that deviate from the per-pixel stack statistics (winsorized κ-σ). On by default.")
    if model.rejectionEnabled {
        Picker("Strength", selection: $model.rejectionStrength) {
            Text("Low").tag(RejectionStrength.low)
            Text("Medium").tag(RejectionStrength.medium)
            Text("High").tag(RejectionStrength.high)
        }
        .pickerStyle(.segmented)
        .help("Higher = safer (rejects less); lower = more aggressive. Medium (κ=3) is the validated default.")
    }
```
(Use `@Bindable var model = model` if the view doesn't already expose bindings; match the file's existing binding pattern. `RejectionStrength` comes from `import LiveAstroCore`.)

- [ ] **Step 2: Build + manual validation**

Run: `swift build` then `swift test`
Expected: build succeeds; all tests pass.
Manual: the toggle shows on by default; turning it off hides the strength picker; hovering shows the tips; the choices persist across relaunch (via Task 5).

- [ ] **Step 3: Commit**

```bash
git add Sources/LiveAstroStudio/ControlView.swift
git commit -m "feat: rejection toggle + strength picker in Setup"
```

---

## Manual validation (whole feature)

1. Import the M8 1,483-sub dataset (`~/Desktop/livestack_live`) with rejection **on** vs **off** → the satellite trail present in the off-stack is gone in the on-stack (the before/after demo).
2. Live session with rejection on → a plane/satellite crossing mid-session leaves no trail.
3. Toggle/strength persist across relaunch.

## Global self-check before final review

`swift test` (all pass) and `swift build`. Confirm the existing native/calibrated pipeline tests are unaffected (default `NoRejection`), and that rejection adds one linear pass per frame (parallelizable later — out of scope here).
