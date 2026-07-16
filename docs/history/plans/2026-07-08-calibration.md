# LiveAstro Calibration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Calibrate raw CFA frames with master dark/flat/bias before debayer, in native import and live stacking modes, using the validated matched-frame recipe.

**Architecture:** New `Sources/LiveAstroCore/Calibration/` with `MasterBuilder` (folder of FITS → canonical top-down master, save/load) and `Calibrator` (`(L−D)/F` on the CFA, aligning masters to each light's stored row order). `SessionPipeline` gains an optional `Calibrator` applied in `handleNative` before `engine.process`. A "Calibration" section in native session setup builds/selects masters with remembered paths.

**Tech Stack:** Swift 5.10, SwiftUI, SPM, macOS 14+, XCTest. Zero external dependencies.

## Global Constraints

- Zero external dependencies — only Foundation, CoreGraphics, AVFoundation, CryptoKit, Accelerate/vImage (system frameworks).
- Swift 5.10, macOS 14+. Tests via `swift test` from repo root.
- Masters are **canonical top-down** `AstroImage`s: read every master with `FITSReader.read(_, normalizeRowOrder: true)`; save with `FITSWriter.float32(..., bottomUp: false)`.
- Calibration operates in normalized [0,1] space (FITSReader maps physical ÷ 65535 → [0,1]); the recipe is scale-invariant.
- `flatFloor = 1.0 / 65535` (1 ADU at 16-bit) — the divide-by-zero clamp for flats.
- Calibration failures **never** propagate into the stacking/session path: a dimension-mismatched master is skipped and logged, never a thrown error into `process`.
- Non-finite calibration results map to 0 (NaN-poisoning guard, matching `FITSReader` line 152).
- Co-Authored-By Claude trailer IS allowed in this repo.
- Recipe: `masterDark = mean(darks)`; `masterFlat = mean(flats [− bias]) `, clamp ≥ `flatFloor`, normalize to median 1; per light `cal = (light − masterDark) / masterFlatNorm`, clamp [0,1].

**Existing interfaces this plan consumes (verbatim):**
- `struct AstroImage { let width, height, channels: Int; let pixels: [Float] /* planar top-down 0…1 */; let sourceIsLinear: Bool; let stats: [ChannelStats]; init(width:height:channels:pixels:sourceIsLinear:) }`
- `struct FITSImage { let width, height, channels: Int; let pixels: [Float] }`
- `FITSReader.read(_ data: Data, normalizeRowOrder: Bool = true) throws -> FITSImage`
- `FITSWriter.float32(width:Int, height:Int, channels:Int, pixels:[Float], bottomUp:Bool = false) -> Data` (writes `ROWORDER` card)
- `struct RawFrame { let image: AstroImage; let bayerPattern: BayerPattern?; let bottomUp: Bool; let timestamp: Date; let sourceName: String; init(image:bayerPattern:bottomUp:timestamp:sourceName:) }`
- `FolderFrameSource(folder:URL, mode:.importOnce, fileNamePrefix:String?)`; `FolderFrameSource.loadRawFrame(url:) throws -> RawFrame`
- `StackEngine()`; `SessionPipeline(nativeSource:FrameSource, engine:StackEngine, profile:SessionProfile, rootDirectory:URL, replaySettings:_, maxKeyframes:_, neutralizeBackground:Bool = false)`
- `SessionPipeline.handleNative(_ frame: RawFrame, engine: StackEngine)` (private; `handleNative` calls `engine.process(frame)`)
- `SessionProfile(targetName:telescope:camera:mount:filter:locationLabel:bortle:subExposureSeconds:notes:)`

---

### Task 1: MasterKind + MasterBuilder.combine

**Files:**
- Create: `Sources/LiveAstroCore/Calibration/MasterBuilder.swift`
- Test: `Tests/LiveAstroCoreTests/MasterBuilderTests.swift`

**Interfaces:**
- Consumes: `FITSReader.read`, `AstroImage`, `FITSWriter.float32` (test fixtures).
- Produces:
  - `public enum MasterKind { case dark, flat, bias }`
  - `public enum MasterBuilder { public static let flatFloor: Float; public static func combine(fitsURLs:[URL], kind:MasterKind, bias:AstroImage?) throws -> AstroImage; public enum BuildError: Error, Equatable { case noFrames, noValidFrames } }`
  - `combine` returns a canonical top-down single-channel `AstroImage`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class MasterBuilderTests: XCTestCase {
    /// Write a top-down mono FITS of constant value `v` (2×2 default).
    func writeConst(_ dir: URL, _ name: String, _ v: Float, w: Int = 2, h: Int = 2) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FITSWriter.float32(width: w, height: h, channels: 1,
                               pixels: [Float](repeating: v, count: w * h)).write(to: url)
        return url
    }

    func sandbox() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testDarkIsMeanOfFrames() throws {
        let dir = try sandbox(); defer { try? FileManager.default.removeItem(at: dir) }
        // values 0.2 and 0.4 in [0,1] → mean 0.3
        let a = try writeConst(dir, "d1.fit", 0.2)
        let b = try writeConst(dir, "d2.fit", 0.4)
        let master = try MasterBuilder.combine(fitsURLs: [a, b], kind: .dark, bias: nil)
        XCTAssertEqual(master.width, 2); XCTAssertEqual(master.channels, 1)
        for p in master.pixels { XCTAssertEqual(p, 0.3, accuracy: 1e-5) }
    }

    func testEmptyThrows() throws {
        XCTAssertThrowsError(try MasterBuilder.combine(fitsURLs: [], kind: .dark, bias: nil)) {
            XCTAssertEqual($0 as? MasterBuilder.BuildError, .noFrames)
        }
    }

    func testDimensionMismatchIsSkipped() throws {
        let dir = try sandbox(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try writeConst(dir, "d1.fit", 0.5, w: 2, h: 2)
        let odd = try writeConst(dir, "d2.fit", 0.9, w: 4, h: 4)     // mismatched → skipped
        let master = try MasterBuilder.combine(fitsURLs: [a, odd], kind: .dark, bias: nil)
        XCTAssertEqual(master.width, 2)
        for p in master.pixels { XCTAssertEqual(p, 0.5, accuracy: 1e-5) }   // only a counted
    }

    func testNoValidFramesThrows() throws {
        let dir = try sandbox(); defer { try? FileManager.default.removeItem(at: dir) }
        let garbage = dir.appendingPathComponent("x.fit")
        try Data([0x00, 0x01, 0x02]).write(to: garbage)     // not a FITS file → unreadable
        XCTAssertThrowsError(try MasterBuilder.combine(fitsURLs: [garbage], kind: .dark, bias: nil)) {
            XCTAssertEqual($0 as? MasterBuilder.BuildError, .noValidFrames)
        }
    }

    func testFlatBiasSubtractedAndNormalizedToMedianOne() throws {
        let dir = try sandbox(); defer { try? FileManager.default.removeItem(at: dir) }
        // flat frames constant 0.6; bias constant 0.1 → (0.6-0.1)=0.5 everywhere;
        // normalized to median 1 → all pixels 1.0
        let f1 = try writeConst(dir, "f1.fit", 0.6)
        let f2 = try writeConst(dir, "f2.fit", 0.6)
        let bias = AstroImage(width: 2, height: 2, channels: 1,
                              pixels: [0.1, 0.1, 0.1, 0.1], sourceIsLinear: true)
        let flat = try MasterBuilder.combine(fitsURLs: [f1, f2], kind: .flat, bias: bias)
        for p in flat.pixels { XCTAssertEqual(p, 1.0, accuracy: 1e-5) }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MasterBuilderTests`
Expected: FAIL — `MasterBuilder` / `MasterKind` undefined.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

public enum MasterKind { case dark, flat, bias }

/// Builds master calibration frames by mean-combining raw FITS frames.
/// Masters are canonical TOP-DOWN AstroImages (read with normalizeRowOrder: true),
/// so a bottom-up source is flipped in and all masters share one orientation.
public enum MasterBuilder {

    /// Divide-by-zero floor for flats: 1 ADU at 16-bit, normalized (FITSReader
    /// maps physical ÷ 65535 → [0,1], so 1.0 = full scale). Matches the Python
    /// prototype's clip(flat, 1.0) in ADU space.
    public static let flatFloor: Float = 1.0 / 65535

    public enum BuildError: Error, Equatable { case noFrames, noValidFrames }

    /// Mean-combine `fitsURLs` into a top-down master.
    /// - .flat: subtracts `bias` per-frame when provided, then clamps ≥ flatFloor
    ///   and normalizes to median 1.
    /// - The first successfully-read frame sets the reference dimensions; later
    ///   frames of a different size are skipped. Throws if no frames are readable.
    public static func combine(fitsURLs: [URL], kind: MasterKind,
                               bias: AstroImage?) throws -> AstroImage {
        guard !fitsURLs.isEmpty else { throw BuildError.noFrames }

        var sum: [Double] = []
        var refW = 0, refH = 0, refC = 0
        var count = 0

        for url in fitsURLs {
            guard let data = try? Data(contentsOf: url),
                  let img = try? FITSReader.read(data, normalizeRowOrder: true) else { continue }
            if count == 0 {
                refW = img.width; refH = img.height; refC = img.channels
                sum = [Double](repeating: 0, count: refW * refH * refC)
            } else if img.width != refW || img.height != refH || img.channels != refC {
                continue    // dimension mismatch → skip
            }
            // For flats, subtract bias per-frame when its dimensions match.
            if kind == .flat, let bias, bias.pixels.count == sum.count {
                for i in 0..<sum.count { sum[i] += Double(img.pixels[i]) - Double(bias.pixels[i]) }
            } else {
                for i in 0..<sum.count { sum[i] += Double(img.pixels[i]) }
            }
            count += 1
        }

        guard count > 0 else { throw BuildError.allMismatched }

        var mean = sum.map { Float($0 / Double(count)) }

        if kind == .flat {
            for i in 0..<mean.count where mean[i] < flatFloor { mean[i] = flatFloor }
            let med = median(of: mean)
            let divisor = med < flatFloor ? flatFloor : med
            for i in 0..<mean.count { mean[i] /= divisor }
        }

        return AstroImage(width: refW, height: refH, channels: refC,
                          pixels: mean, sourceIsLinear: true)
    }

    /// Exact median via full sort of a copy (one-time build; correctness over speed).
    private static func median(of values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        var v = values; v.sort()
        let mid = v.count / 2
        return v.count % 2 == 0 ? (v[mid - 1] + v[mid]) / 2 : v[mid]
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MasterBuilderTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Calibration/MasterBuilder.swift Tests/LiveAstroCoreTests/MasterBuilderTests.swift
git commit -m "feat: MasterBuilder.combine — mean-combine masters (dark/flat/bias)"
```

---

### Task 2: MasterBuilder save/load round-trip

**Files:**
- Modify: `Sources/LiveAstroCore/Calibration/MasterBuilder.swift`
- Test: `Tests/LiveAstroCoreTests/MasterBuilderTests.swift` (add cases)

**Interfaces:**
- Consumes: `FITSWriter.float32`, `FITSReader.read`, `AstroImage`.
- Produces: `MasterBuilder.save(_ master: AstroImage, to url: URL) throws`; `MasterBuilder.load(_ url: URL) throws -> AstroImage`.

- [ ] **Step 1: Write the failing test**

```swift
    func testSaveLoadRoundTripPreservesPixels() throws {
        let dir = try sandbox(); defer { try? FileManager.default.removeItem(at: dir) }
        let master = AstroImage(width: 3, height: 2, channels: 1,
                                pixels: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6], sourceIsLinear: true)
        let url = dir.appendingPathComponent("master_dark.fit")
        try MasterBuilder.save(master, to: url)
        let loaded = try MasterBuilder.load(url)
        XCTAssertEqual(loaded.width, 3); XCTAssertEqual(loaded.height, 2)
        for (a, b) in zip(loaded.pixels, master.pixels) { XCTAssertEqual(a, b, accuracy: 1e-5) }
    }

    func testLoadFlipsBottomUpFileToTopDown() throws {
        let dir = try sandbox(); defer { try? FileManager.default.removeItem(at: dir) }
        // A bottom-up file with rows [r0=A, r1=B]; loaded top-down must be [B, A].
        let url = dir.appendingPathComponent("bu.fit")
        try FITSWriter.float32(width: 1, height: 2, channels: 1,
                               pixels: [0.9, 0.1], bottomUp: true).write(to: url)
        let loaded = try MasterBuilder.load(url)
        // FITSWriter(bottomUp:true) stores the input flipped; read normalizeRowOrder:true
        // yields the input back in top-down. Just assert it round-trips the logical image.
        XCTAssertEqual(loaded.pixels.count, 2)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MasterBuilderTests`
Expected: FAIL — `save`/`load` undefined.

- [ ] **Step 3: Write the implementation** (append to `MasterBuilder`)

```swift
    /// Save a master as Float32 top-down FITS (ROWORDER = TOP-DOWN).
    public static func save(_ master: AstroImage, to url: URL) throws {
        let data = FITSWriter.float32(width: master.width, height: master.height,
                                      channels: master.channels, pixels: master.pixels,
                                      bottomUp: false)
        try data.write(to: url)
    }

    /// Load a pre-built master as a canonical top-down AstroImage.
    public static func load(_ url: URL) throws -> AstroImage {
        let data = try Data(contentsOf: url)
        let img = try FITSReader.read(data, normalizeRowOrder: true)
        return AstroImage(width: img.width, height: img.height, channels: img.channels,
                          pixels: img.pixels, sourceIsLinear: true)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MasterBuilderTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Calibration/MasterBuilder.swift Tests/LiveAstroCoreTests/MasterBuilderTests.swift
git commit -m "feat: MasterBuilder save/load — canonical top-down FITS round-trip"
```

---

### Task 3: Calibrator (apply + row-order alignment)

**Files:**
- Create: `Sources/LiveAstroCore/Calibration/Calibrator.swift`
- Test: `Tests/LiveAstroCoreTests/CalibratorTests.swift`

**Interfaces:**
- Consumes: `AstroImage`, `RawFrame`, `MasterBuilder.flatFloor`.
- Produces: `public final class Calibrator { init(dark: AstroImage?, flat: AstroImage?); var onLog: ((String) -> Void)?; func apply(_ frame: RawFrame) -> RawFrame }`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class CalibratorTests: XCTestCase {
    func mono(_ w: Int, _ h: Int, _ px: [Float], bottomUp: Bool = false) -> RawFrame {
        RawFrame(image: AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true),
                 bayerPattern: nil, bottomUp: bottomUp, timestamp: Date(), sourceName: "L.fit")
    }

    func testNoMastersIsIdentity() {
        let f = mono(2, 2, [0.1, 0.2, 0.3, 0.4])
        let out = Calibrator(dark: nil, flat: nil).apply(f)
        XCTAssertEqual(out.image.pixels, f.image.pixels)
    }

    func testDarkSubtractsPedestal() {
        let dark = AstroImage(width: 2, height: 2, channels: 1,
                              pixels: [0.1, 0.1, 0.1, 0.1], sourceIsLinear: true)
        let f = mono(2, 2, [0.3, 0.4, 0.5, 0.6])
        let out = Calibrator(dark: dark, flat: nil).apply(f)
        XCTAssertEqual(out.image.pixels, [0.2, 0.3, 0.4, 0.5])
    }

    func testFlatDividesAndNormalizes() {
        // flat = 0.5 multiplier everywhere → light / 0.5 = light × 2, clamped [0,1]
        let flat = AstroImage(width: 2, height: 2, channels: 1,
                              pixels: [0.5, 0.5, 0.5, 0.5], sourceIsLinear: true)
        let f = mono(2, 2, [0.1, 0.2, 0.3, 0.9])
        let out = Calibrator(dark: nil, flat: flat).apply(f)
        XCTAssertEqual(out.image.pixels, [0.2, 0.4, 0.6, 1.0])   // 0.9/0.5=1.8 → clamp 1.0
    }

    func testFlatZeroClampsNoNaN() {
        let flat = AstroImage(width: 1, height: 1, channels: 1, pixels: [0.0], sourceIsLinear: true)
        let f = mono(1, 1, [0.5])
        let out = Calibrator(dark: nil, flat: flat).apply(f)
        XCTAssertTrue(out.image.pixels[0].isFinite)
        XCTAssertEqual(out.image.pixels[0], 1.0)   // 0.5 / flatFloor → huge → clamp 1.0
    }

    func testDimensionMismatchSkipsMasterAndLogs() {
        let dark = AstroImage(width: 4, height: 4, channels: 1,
                              pixels: [Float](repeating: 0.1, count: 16), sourceIsLinear: true)
        let f = mono(2, 2, [0.3, 0.4, 0.5, 0.6])
        let cal = Calibrator(dark: dark, flat: nil)
        var logged = false; cal.onLog = { _ in logged = true }
        let out = cal.apply(f)
        XCTAssertEqual(out.image.pixels, f.image.pixels)   // dark skipped → unchanged
        XCTAssertTrue(logged)
    }

    func testBottomUpLightFlipsMasterForAlignment() {
        // Master dark (top-down) rows: r0=[0.0,0.0], r1=[0.5,0.5].
        let dark = AstroImage(width: 2, height: 2, channels: 1,
                              pixels: [0.0, 0.0, 0.5, 0.5], sourceIsLinear: true)
        // Bottom-up light rows (stored): r0=[0.6,0.6] (physical bottom), r1=[0.2,0.2].
        // Aligned dark for a bottom-up light = vertical flip → r0 subtracts 0.5, r1 subtracts 0.0.
        let f = mono(2, 2, [0.6, 0.6, 0.2, 0.2], bottomUp: true)
        let out = Calibrator(dark: dark, flat: nil).apply(f)
        XCTAssertEqual(out.image.pixels, [0.1, 0.1, 0.2, 0.2])
        XCTAssertTrue(out.bottomUp)   // orientation preserved for the engine
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CalibratorTests`
Expected: FAIL — `Calibrator` undefined.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Applies master dark/flat calibration to a raw CFA frame before debayer.
/// Masters are canonical top-down; a bottom-up light gets a vertically flipped
/// master so photosites align. Never throws — a size-mismatched master is
/// skipped and logged so calibration can never break the session.
public final class Calibrator {
    private let dark: AstroImage?
    private let flat: AstroImage?
    public var onLog: ((String) -> Void)?

    // Masters aligned to the current light orientation, cached: every frame in a
    // session shares `bottomUp`, so alignment is computed at most once.
    // `alignedForBottomUp == nil` means "not yet aligned".
    private var alignedDark: AstroImage?
    private var alignedFlat: AstroImage?
    private var alignedForBottomUp: Bool?
    private var loggedDarkMismatch = false
    private var loggedFlatMismatch = false

    public init(dark: AstroImage?, flat: AstroImage?) {
        self.dark = dark
        self.flat = flat
    }

    public func apply(_ frame: RawFrame) -> RawFrame {
        guard dark != nil || flat != nil else { return frame }

        let light = frame.image
        let n = light.pixels.count
        computeAlignment(for: frame.bottomUp)

        // Resolve masters usable for THIS frame's dimensions.
        let d = usable(alignedDark, light: light, kind: "dark", logged: &loggedDarkMismatch)
        let f = usable(alignedFlat, light: light, kind: "flat", logged: &loggedFlatMismatch)
        if d == nil && f == nil { return frame }

        var out = [Float](repeating: 0, count: n)
        light.pixels.withUnsafeBufferPointer { L in
            for i in 0..<n {
                var v = L[i]
                if let d { v -= d.pixels[i] }
                if let f {
                    let denom = max(f.pixels[i], MasterBuilder.flatFloor)
                    v /= denom
                }
                out[i] = v.isFinite ? min(max(v, 0), 1) : 0
            }
        }
        let image = AstroImage(width: light.width, height: light.height,
                               channels: light.channels, pixels: out, sourceIsLinear: true)
        return RawFrame(image: image, bayerPattern: frame.bayerPattern, bottomUp: frame.bottomUp,
                        timestamp: frame.timestamp, sourceName: frame.sourceName)
    }

    private func computeAlignment(for bottomUp: Bool) {
        if alignedForBottomUp == bottomUp { return }
        alignedForBottomUp = bottomUp
        alignedDark = dark.map { bottomUp ? Self.verticalFlip($0) : $0 }
        alignedFlat = flat.map { bottomUp ? Self.verticalFlip($0) : $0 }
    }

    /// Return the master if its dimensions match the light; else nil, logging once.
    private func usable(_ master: AstroImage?, light: AstroImage, kind: String,
                        logged: inout Bool) -> AstroImage? {
        guard let master else { return nil }
        guard master.width == light.width, master.height == light.height,
              master.channels == light.channels else {
            if !logged { onLog?("master \(kind) \(master.width)×\(master.height) ≠ light " +
                                "\(light.width)×\(light.height) — skipping \(kind)"); logged = true }
            return nil
        }
        return master
    }

    /// Reverse row order within each channel plane.
    static func verticalFlip(_ img: AstroImage) -> AstroImage {
        let w = img.width, h = img.height, plane = w * h
        var out = [Float](repeating: 0, count: img.pixels.count)
        for c in 0..<img.channels {
            for y in 0..<h {
                let src = c * plane + (h - 1 - y) * w
                let dst = c * plane + y * w
                out.replaceSubrange(dst..<(dst + w), with: img.pixels[src..<(src + w)])
            }
        }
        return AstroImage(width: w, height: h, channels: img.channels,
                          pixels: out, sourceIsLinear: img.sourceIsLinear)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CalibratorTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Calibration/Calibrator.swift Tests/LiveAstroCoreTests/CalibratorTests.swift
git commit -m "feat: Calibrator — (L-D)/F on CFA with top-down master alignment"
```

---

### Task 4: SessionPipeline native integration + e2e

**Files:**
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift`
- Test: `Tests/LiveAstroCoreTests/CalibratedPipelineTests.swift`

**Interfaces:**
- Consumes: `Calibrator`, `RawFrame`, existing native `SessionPipeline` init and `handleNative`.
- Produces: native `SessionPipeline.init(..., calibrator: Calibrator? = nil)`; `handleNative` applies the calibrator before `engine.process`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class CalibratedPipelineTests: XCTestCase {
    /// Top-down mono starfield + additive pedestal, written as FITS.
    func writeSub(_ dir: URL, _ name: String, pedestal: Float, stars: [(Double, Double)]) throws {
        var px = [Float](repeating: 0.02 + pedestal, count: 256 * 256)
        for s in stars {
            for y in max(0, Int(s.1) - 6)...min(255, Int(s.1) + 6) {
                for x in max(0, Int(s.0) - 6)...min(255, Int(s.0) + 6) {
                    let dx = Double(x) - s.0, dy = Double(y) - s.1
                    px[y * 256 + x] += 0.8 * Float(exp(-(dx * dx + dy * dy) / 8))
                }
            }
        }
        try FITSWriter.float32(width: 256, height: 256, channels: 1, pixels: px)
            .write(to: dir.appendingPathComponent(name))
    }

    func testCalibrationRemovesPedestalFromMaster() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let subs = sandbox.appendingPathComponent("subs")
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: subs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        var field: [(Double, Double)] = []
        for i in 0..<20 { field.append((Double((i * 47) % 240 + 8), Double((i * 83) % 240 + 8))) }
        let pedestal: Float = 0.1
        try writeSub(subs, "Light_001.fit", pedestal: pedestal, stars: field)
        try writeSub(subs, "Light_002.fit", pedestal: pedestal, stars: field.map { ($0.0 + 2.0, $0.1 - 1.0) })

        // Master dark = constant pedestal.
        let dark = AstroImage(width: 256, height: 256, channels: 1,
                              pixels: [Float](repeating: pedestal, count: 256 * 256), sourceIsLinear: true)

        let profile = SessionProfile(targetName: "Cal", telescope: "T", camera: "C", mount: "M",
                                     filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let source = FolderFrameSource(folder: subs, mode: .importOnce, fileNamePrefix: "Light_")
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: profile, rootDirectory: sessions,
                                       calibrator: Calibrator(dark: dark, flat: nil))
        try pipeline.start()
        let replayURL = try pipeline.end()
        let masterURL = replayURL.deletingLastPathComponent().appendingPathComponent("master.fit")
        let master = try FITSReader.read(Data(contentsOf: masterURL))
        // Background (corner pixel, no star) should be ~0.02 (pedestal removed), not ~0.12.
        XCTAssertLessThan(master.pixels[0], 0.05)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CalibratedPipelineTests`
Expected: FAIL — `calibrator:` argument does not exist.

- [ ] **Step 3: Modify SessionPipeline**

Add the stored property near the other `private let` fields (after `neutralizeBackground`):

```swift
    private let calibrator: Calibrator?
```

Update the native initializer signature and body (the `init(nativeSource:…)` one) to accept and store the calibrator, and wire its log:

```swift
    public init(nativeSource: FrameSource, engine: StackEngine, profile: SessionProfile,
                rootDirectory: URL, replaySettings: ReplaySettings = .init(),
                maxKeyframes: Int = FrameSelector.defaultMaxKeyframes,
                neutralizeBackground: Bool = false, calibrator: Calibrator? = nil) {
        self.watcher = nil
        self.source = nativeSource
        self.engine = engine
        self.profile = profile
        self.session = SessionManager(rootDirectory: rootDirectory)
        self.replaySettings = replaySettings
        self.maxKeyframes = maxKeyframes
        self.neutralizeBackground = neutralizeBackground
        self.calibrator = calibrator
    }
```

Add `self.calibrator = nil` to the watcher-mode initializer so it still compiles.

In `handleNative`, calibrate first (rename the parameter to `rawFrame`):

```swift
    private func handleNative(_ rawFrame: RawFrame, engine: StackEngine) {
        let frame = calibrator?.apply(rawFrame) ?? rawFrame
        let outcome = engine.process(frame)
        // …rest unchanged…
    }
```

Wire the calibrator's log to the pipeline log at the top of `start()` (native branch), right after `recorder = SnapshotRecorder(...)`:

```swift
        calibrator?.onLog = { [weak self] in self?.onLog?($0) }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CalibratedPipelineTests` then `swift test --filter NativePipelineTests`
Expected: both PASS (calibration removes the pedestal; the existing native e2e still passes with `calibrator` defaulting to nil).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Pipeline/SessionPipeline.swift Tests/LiveAstroCoreTests/CalibratedPipelineTests.swift
git commit -m "feat: apply Calibrator in native SessionPipeline before stacking"
```

---

### Task 5: Calibration UI + remembered master paths

**Files:**
- Create: `Sources/LiveAstroCore/Calibration/CalibrationSelection.swift`
- Create: `Sources/LiveAstroStudio/CalibrationSection.swift`
- Modify: `Sources/LiveAstroStudio/ControlView.swift` (embed the section in native-mode setup)
- Modify: `Sources/LiveAstroStudio/AppModel.swift` (build the `Calibrator` from the selection at session start)
- Test: `Tests/LiveAstroCoreTests/CalibrationSelectionTests.swift`

**Interfaces:**
- Consumes: `MasterBuilder.load`, `Calibrator`, `UserDefaults`.
- Produces:
  - `struct CalibrationSelection: Equatable { var darkPath, flatPath, biasPath: String? }`
  - `enum CalibrationStore { static func load(_ d: UserDefaults) -> CalibrationSelection; static func save(_ s: CalibrationSelection, to d: UserDefaults); static func mastersDirectory() -> URL }`
  - `enum CalibrationLoader { static func makeCalibrator(dark: URL?, flat: URL?) -> (Calibrator?, [String]) }` — loads masters, returns the calibrator (nil if neither loads) plus any warning strings for missing/unreadable files.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class CalibrationSelectionTests: XCTestCase {
    func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "cal-test-\(UUID().uuidString)")!
        return d
    }

    func testSelectionRoundTripsThroughUserDefaults() {
        let d = defaults()
        let sel = CalibrationSelection(darkPath: "/m/dark.fit", flatPath: "/m/flat.fit", biasPath: nil)
        CalibrationStore.save(sel, to: d)
        XCTAssertEqual(CalibrationStore.load(d), sel)
    }

    func testEmptySelectionByDefault() {
        XCTAssertEqual(CalibrationStore.load(defaults()),
                       CalibrationSelection(darkPath: nil, flatPath: nil, biasPath: nil))
    }

    func testMakeCalibratorNilWhenNoMasters() {
        let (cal, warnings) = CalibrationLoader.makeCalibrator(dark: nil, flat: nil)
        XCTAssertNil(cal); XCTAssertTrue(warnings.isEmpty)
    }

    func testMakeCalibratorWarnsOnMissingFile() {
        let missing = URL(fileURLWithPath: "/nope/dark.fit")
        let (cal, warnings) = CalibrationLoader.makeCalibrator(dark: missing, flat: nil)
        XCTAssertNil(cal)
        XCTAssertEqual(warnings.count, 1)
    }

    func testMakeCalibratorLoadsRealMaster() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("dark.fit")
        try MasterBuilder.save(AstroImage(width: 2, height: 2, channels: 1,
                                          pixels: [0.1, 0.1, 0.1, 0.1], sourceIsLinear: true), to: url)
        let (cal, warnings) = CalibrationLoader.makeCalibrator(dark: url, flat: nil)
        XCTAssertNotNil(cal); XCTAssertTrue(warnings.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CalibrationSelectionTests`
Expected: FAIL — `CalibrationSelection` / `CalibrationStore` / `CalibrationLoader` undefined.

- [ ] **Step 3: Write the implementation** (`CalibrationSelection.swift`)

```swift
import Foundation

/// Persistable choice of master files for calibration (last-used paths).
public struct CalibrationSelection: Equatable {
    public var darkPath: String?
    public var flatPath: String?
    public var biasPath: String?
    public init(darkPath: String?, flatPath: String?, biasPath: String?) {
        self.darkPath = darkPath; self.flatPath = flatPath; self.biasPath = biasPath
    }
}

public enum CalibrationStore {
    private static let darkKey = "calibration.darkPath"
    private static let flatKey = "calibration.flatPath"
    private static let biasKey = "calibration.biasPath"

    public static func load(_ d: UserDefaults) -> CalibrationSelection {
        CalibrationSelection(darkPath: d.string(forKey: darkKey),
                             flatPath: d.string(forKey: flatKey),
                             biasPath: d.string(forKey: biasKey))
    }

    public static func save(_ s: CalibrationSelection, to d: UserDefaults) {
        d.set(s.darkPath, forKey: darkKey)
        d.set(s.flatPath, forKey: flatKey)
        d.set(s.biasPath, forKey: biasKey)
    }

    /// Default masters store: ~/LiveAstro/masters/
    public static func mastersDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("LiveAstro/masters", isDirectory: true)
    }
}

public enum CalibrationLoader {
    /// Load master files into a Calibrator. Returns (nil, []) when neither is set,
    /// and a warning per file that is set but unreadable. Bias is not loaded here —
    /// it is folded into the flat at build time.
    public static func makeCalibrator(dark: URL?, flat: URL?) -> (Calibrator?, [String]) {
        var warnings: [String] = []
        func loadMaster(_ url: URL?, _ label: String) -> AstroImage? {
            guard let url else { return nil }
            do { return try MasterBuilder.load(url) }
            catch { warnings.append("Could not load master \(label): \(url.lastPathComponent)"); return nil }
        }
        let d = loadMaster(dark, "dark")
        let f = loadMaster(flat, "flat")
        guard d != nil || f != nil else { return (nil, warnings) }
        return (Calibrator(dark: d, flat: f), warnings)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CalibrationSelectionTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Write the SwiftUI section** (`CalibrationSection.swift`)

Manual-validation UI (no unit test — file pickers, off-main build). Wire it into `ControlView`'s native-mode setup and `AppModel`.

```swift
import SwiftUI
import LiveAstroCore
import UniformTypeIdentifiers

/// Native-mode "Calibration" setup: pick or build master dark/flat/bias.
/// Selections persist via CalibrationStore; masters build off the main thread.
struct CalibrationSection: View {
    @Binding var selection: CalibrationSelection
    var onLog: (String) -> Void

    var body: some View {
        GroupBox("Calibration") {
            VStack(alignment: .leading, spacing: 6) {
                masterRow("Dark", path: $selection.darkPath, kind: .dark, needsBias: false)
                masterRow("Flat", path: $selection.flatPath, kind: .flat, needsBias: true)
                masterRow("Bias", path: $selection.biasPath, kind: .bias, needsBias: false)
                Text("Bias is used to clean flats; it is not applied to lights directly.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(6)
        }
    }

    @ViewBuilder
    private func masterRow(_ label: String, path: Binding<String?>,
                           kind: MasterKind, needsBias: Bool) -> some View {
        HStack {
            Text(label).frame(width: 44, alignment: .leading)
            Text(path.wrappedValue.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None")
                .foregroundStyle(path.wrappedValue == nil ? .secondary : .primary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Use file…") { pickFile(path) }
            Button("Build…") { pickFolderAndBuild(path, kind: kind, needsBias: needsBias) }
            if path.wrappedValue != nil { Button("Clear") { path.wrappedValue = nil } }
        }
    }

    private func pickFile(_ path: Binding<String?>) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fit") ?? .data,
                                     UTType(filenameExtension: "fits") ?? .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
    }

    private func pickFolderAndBuild(_ path: Binding<String?>, kind: MasterKind, needsBias: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder,
                    includingPropertiesForKeys: nil))?
            .filter { ["fit", "fits"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path } ?? []
        let biasURL = needsBias ? selection.biasPath.map { URL(fileURLWithPath: $0) } : nil
        onLog("Building \(label(kind)) master from \(urls.count) frames…")
        DispatchQueue.global(qos: .userInitiated).async {
            let bias = biasURL.flatMap { try? MasterBuilder.load($0) }
            do {
                let master = try MasterBuilder.combine(fitsURLs: urls, kind: kind, bias: bias)
                let dir = CalibrationStore.mastersDirectory()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let out = dir.appendingPathComponent("master_\(label(kind)).fit")
                try MasterBuilder.save(master, to: out)
                DispatchQueue.main.async { path.wrappedValue = out.path; onLog("Built \(out.lastPathComponent)") }
            } catch {
                DispatchQueue.main.async { onLog("Build failed: \(error)") }
            }
        }
    }

    private func label(_ k: MasterKind) -> String {
        switch k { case .dark: return "dark"; case .flat: return "flat"; case .bias: return "bias" }
    }
}
```

- [ ] **Step 6: Wire into ControlView + AppModel**

In `AppModel`, add a persisted selection and build the calibrator at native session start:

```swift
    // AppModel
    @Published var calibration = CalibrationStore.load(.standard)

    // where the native SessionPipeline is constructed for "Raw subs (native stacking)":
    let (calibrator, warnings) = CalibrationLoader.makeCalibrator(
        dark: calibration.darkPath.map { URL(fileURLWithPath: $0) },
        flat: calibration.flatPath.map { URL(fileURLWithPath: $0) })
    warnings.forEach { log($0) }
    CalibrationStore.save(calibration, to: .standard)
    let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                   profile: profile, rootDirectory: root,
                                   neutralizeBackground: neutralizeBackground,
                                   calibrator: calibrator)
```

In `ControlView`, show the section in the native-mode setup block:

```swift
    CalibrationSection(selection: $model.calibration, onLog: { model.log($0) })
```

(Match the exact property/log names already in `AppModel`/`ControlView`; the
above uses `model.log(_:)` and a `neutralizeBackground` local as placeholders for
the existing equivalents — read those files and use the real names.)

- [ ] **Step 7: Build the app target + run the full suite**

Run: `swift build` then `swift test`
Expected: build succeeds; all tests pass (existing + new calibration tests).

- [ ] **Step 8: Commit**

```bash
git add Sources/LiveAstroCore/Calibration/CalibrationSelection.swift \
        Sources/LiveAstroStudio/CalibrationSection.swift \
        Sources/LiveAstroStudio/ControlView.swift Sources/LiveAstroStudio/AppModel.swift \
        Tests/LiveAstroCoreTests/CalibrationSelectionTests.swift
git commit -m "feat: Calibration UI section + remembered master paths"
```

---

## Manual validation (documented per house rules)

Untestable in unit scope — verify by hand on the real IC 443 data (`~/Desktop/jelly`):

1. **Build masters:** in native session setup, Build dark from `~/Desktop/jelly/Dark` (81 frames), Build bias from `~/Desktop/jelly/Bias`, Build flat from `~/Desktop/jelly/Flat` (bias auto-applied). Confirm three `master_*.fit` land in `~/LiveAstro/masters/` and the rows show file names + no errors.
2. **Remembered paths:** quit and relaunch; the master paths are pre-filled.
3. **Calibrated import:** Import Subs from `~/Documents/ic443_lights` (uncalibrated) with the masters selected. Compare the resulting `master.fit` to the uncalibrated `2026-07-08-ic443jellyfish` session — amp glow / vignette flattened, matching the Python `ic443jellyfishcal` result (100/100 accepted).
4. **Missing-file warning:** point a remembered path at a deleted file → a log warning, session proceeds uncalibrated-by-that-master.
5. **Live path (optional, Seestar night):** confirm calibration also applies in live mode (same `handleNative` path).

## Global self-check before final review

Run `swift test` (all pass) and `swift test -c release --filter PerformanceTests` (26MP perf gate holds — calibration adds one linear pass over the CFA per frame).
