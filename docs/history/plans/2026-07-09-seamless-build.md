# LiveAstro Seamless Build — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take LiveAstro from fiddly launch-to-stacking to ~one tap: in-app Seestar relay, one-tap Seestar Live, persisted settings, a tabbed/detachable window that fits, imports with progress + cancel, and in-app help.

**Architecture:** Four testable core-logic units in LiveAstroCore (`SessionSettings`, `SeestarRelay`, `SeestarDetector`, import progress/cancel on `SessionPipeline`), then app-layer wiring/UI in LiveAstroStudio (settings persistence, a `MainView` tabbed `Live | Setup | Help` window with detach, the one-tap Seestar Live flow, import progress/Cancel UI, hover tooltips, and a Help tab).

**Tech Stack:** Swift 5.10, SwiftUI, SPM, macOS 14+, XCTest. Zero external dependencies.

## Global Constraints

- Zero external dependencies — only Foundation, CoreGraphics, AVFoundation, CryptoKit, Accelerate/vImage (system frameworks).
- Swift 5.10, macOS 14+. Tests via `swift test` from repo root.
- Native in-app relay uses the proven stage-then-local-copy pattern (mktemp stage dir → cp source→stage → cp stage→dest) so the watcher never sees a partial FITS.
- Relay glob defaults to `Light_*_10.0s_*.fit` (excludes other exposures/prior nights; survives midnight rollover).
- One-tap Seestar Live does NOT auto-start OBS.
- App-managed relay dir: `~/LiveAstro/relay/<target>-<yyyy-MM-dd>/`.
- The detached broadcast window MUST keep `.windowStyle(.hiddenTitleBar)` and the `BroadcastWindowConfigurator` ScreenCaptureKit title so OBS still captures it.
- Co-Authored-By Claude trailer is allowed in this repo.

**Existing interfaces this plan consumes (verbatim):**
- `SourceMode` (in `AppModel`): `enum SourceMode: String, CaseIterable { case stackerOutput = "Stacker output (Siril)"; case nativeStack = "Raw subs (native stacking)"; var defaultFileNamePrefix: String }`
- `struct CalibrationSelection: Equatable { var darkPath, flatPath, biasPath: String?; init(darkPath:flatPath:biasPath:) }` (in `Sources/LiveAstroCore/Calibration/CalibrationSelection.swift`)
- `FolderFrameSource`: `enum Mode { case importOnce, live }`; `init(folder: URL, mode: Mode, fileNamePrefix: String? = nil)`; `var isFinite: Bool { mode == .importOnce }`; conforms to `FrameSource`
- `protocol FrameSource: AnyObject { var frames: AsyncStream<RawFrame> { get }; var isFinite: Bool { get }; func start() throws; func stop() }`
- `SessionPipeline`: native `init(nativeSource:engine:profile:rootDirectory:replaySettings:maxKeyframes:neutralizeBackground:calibrator:)`; `private func handleNative(_ rawFrame: RawFrame, engine: StackEngine)`; `public func end() throws -> URL`; `public var onRejected: ((RejectionReason, String) -> Void)?`; `public var onLog: ((String) -> Void)?`; `public var onUpdate: ((CGImage, SnapshotRecord) -> Void)?`
- `AppModel` fields: `targetName`, `subExposureText` ("60"), `fileNamePrefix`, `neutralizeBackground`, `calibration` (= `CalibrationStore.load(.standard)`), `watchFolder: URL?`, `sourceMode: SourceMode`, `isRunning`, `isImporting`, `acceptedCount`, `rejectedCount`.
- `LiveAstroApp`: main `WindowGroup("LiveAstro Control"){ ControlView().environment(model) }` + `Window("LiveAstro Broadcast", id: "broadcast"){ BroadcastView()… }.windowStyle(.hiddenTitleBar)`.

---

### Task 1: SessionSettings persistence

**Files:**
- Create: `Sources/LiveAstroCore/Settings/SessionSettings.swift`
- Modify: `Sources/LiveAstroCore/Calibration/CalibrationSelection.swift` (add `Codable`)
- Test: `Tests/LiveAstroCoreTests/SessionSettingsTests.swift`

**Interfaces:**
- Produces: `struct SessionSettings: Codable, Equatable { var sourceModeRaw, filePrefix, targetName: String; var watchFolderPath: String?; var neutralizeBackground: Bool; var subExposureSeconds: Double; var calibration: CalibrationSelection; static var defaults: SessionSettings }`; `enum SessionSettingsStore { static func load(_ d: UserDefaults) -> SessionSettings; static func save(_ s: SessionSettings, to d: UserDefaults) }`
- Note: `sourceModeRaw` is the app `SourceMode.rawValue` string — Core stays independent of the app enum.

- [ ] **Step 1: Make CalibrationSelection Codable**

In `CalibrationSelection.swift`, change the declaration line:
```swift
public struct CalibrationSelection: Codable, Equatable {
```
(The three `String?` members already satisfy `Codable` synthesis; no other change.)

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class SessionSettingsTests: XCTestCase {
    func defaults() -> UserDefaults { UserDefaults(suiteName: "seamless-\(UUID().uuidString)")! }

    func testDefaultsWhenEmpty() {
        let s = SessionSettingsStore.load(defaults())
        XCTAssertEqual(s, SessionSettings.defaults)
        XCTAssertEqual(s.filePrefix, "live_stack")
        XCTAssertEqual(s.subExposureSeconds, 60)
    }

    func testRoundTrip() {
        let d = defaults()
        var s = SessionSettings.defaults
        s.sourceModeRaw = "Raw subs (native stacking)"
        s.filePrefix = "Light_"; s.neutralizeBackground = true; s.subExposureSeconds = 10
        s.targetName = "M8 Lagoon"; s.watchFolderPath = "/x/y"
        s.calibration = CalibrationSelection(darkPath: "/m/dark.fit", flatPath: nil, biasPath: nil)
        SessionSettingsStore.save(s, to: d)
        XCTAssertEqual(SessionSettingsStore.load(d), s)
    }

    func testCorruptDataFallsBackToDefaults() {
        let d = defaults()
        d.set(Data([0x00, 0x01]), forKey: "sessionSettings.v1")
        XCTAssertEqual(SessionSettingsStore.load(d), SessionSettings.defaults)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter LiveAstroCoreTests.SessionSettingsTests`
Expected: FAIL — `SessionSettings` undefined.

- [ ] **Step 4: Implement**

```swift
import Foundation

/// Persistable snapshot of the control-form settings. `sourceModeRaw` holds the
/// app's SourceMode.rawValue string so LiveAstroCore stays independent of the
/// app-layer enum.
public struct SessionSettings: Codable, Equatable {
    public var sourceModeRaw: String
    public var watchFolderPath: String?
    public var filePrefix: String
    public var neutralizeBackground: Bool
    public var subExposureSeconds: Double
    public var targetName: String
    public var calibration: CalibrationSelection

    public init(sourceModeRaw: String, watchFolderPath: String?, filePrefix: String,
                neutralizeBackground: Bool, subExposureSeconds: Double,
                targetName: String, calibration: CalibrationSelection) {
        self.sourceModeRaw = sourceModeRaw; self.watchFolderPath = watchFolderPath
        self.filePrefix = filePrefix; self.neutralizeBackground = neutralizeBackground
        self.subExposureSeconds = subExposureSeconds; self.targetName = targetName
        self.calibration = calibration
    }

    /// Matches the app's fresh-launch defaults (Siril mode, live_stack prefix, 60 s).
    public static var defaults: SessionSettings {
        SessionSettings(sourceModeRaw: "Stacker output (Siril)", watchFolderPath: nil,
                        filePrefix: "live_stack", neutralizeBackground: false,
                        subExposureSeconds: 60, targetName: "",
                        calibration: CalibrationSelection(darkPath: nil, flatPath: nil, biasPath: nil))
    }
}

public enum SessionSettingsStore {
    static let key = "sessionSettings.v1"

    public static func load(_ d: UserDefaults) -> SessionSettings {
        guard let data = d.data(forKey: key),
              let s = try? JSONDecoder().decode(SessionSettings.self, from: data)
        else { return .defaults }
        return s
    }

    public static func save(_ s: SessionSettings, to d: UserDefaults) {
        if let data = try? JSONEncoder().encode(s) { d.set(data, forKey: key) }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter LiveAstroCoreTests.SessionSettingsTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/LiveAstroCore/Settings/SessionSettings.swift Sources/LiveAstroCore/Calibration/CalibrationSelection.swift Tests/LiveAstroCoreTests/SessionSettingsTests.swift
git commit -m "feat: SessionSettings — Codable persist of control-form settings"
```

---

### Task 2: SeestarRelay (native stage-copy relay)

**Files:**
- Create: `Sources/LiveAstroCore/Seestar/SeestarRelay.swift`
- Test: `Tests/LiveAstroCoreTests/SeestarRelayTests.swift`

**Interfaces:**
- Produces: `final class SeestarRelay { init(source: URL, destination: URL, glob: String = "Light_*_10.0s_*.fit", pollSeconds: Double = 5); func start() throws; func stop(); var onLog: ((String)->Void)?; private(set) var relayedCount: Int; func copyOnce() (internal, testable); static func wildcardMatch(_ name: String, _ pattern: String) -> Bool }`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class SeestarRelayTests: XCTestCase {
    func tmp() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
    }
    func write(_ dir: URL, _ name: String, bytes: Int = 32) throws {
        try Data(count: bytes).write(to: dir.appendingPathComponent(name))
    }

    func testWildcardMatch() {
        XCTAssertTrue(SeestarRelay.wildcardMatch("Light_M 8_10.0s_LP_20260709-034653.fit", "Light_*_10.0s_*.fit"))
        XCTAssertFalse(SeestarRelay.wildcardMatch("Light_M 8_20.0s_LP_20260707-000534.fit", "Light_*_10.0s_*.fit"))
        XCTAssertFalse(SeestarRelay.wildcardMatch("Light_M 8_10.0s_LP_x.jpg", "Light_*_10.0s_*.fit"))
        XCTAssertTrue(SeestarRelay.wildcardMatch("ab.fit", "*.fit"))
    }

    func testCopyOnceCopiesNewMatchingSkipsRest() throws {
        let src = try tmp(), dst = try tmp()
        try write(src, "Light_M 8_10.0s_LP_1.fit")        // match
        try write(src, "Light_M 8_10.0s_LP_1.jpg")        // wrong ext
        try write(src, "Light_M 8_20.0s_LP_2.fit")        // wrong exposure
        let r = SeestarRelay(source: src, destination: dst)
        let n = try r.copyOnce()
        XCTAssertEqual(n, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("Light_M 8_10.0s_LP_1.fit").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dst.path).filter { $0.hasSuffix(".fit") }.count, 1)
    }

    func testCopyOnceSkipsAlreadyPresent() throws {
        let src = try tmp(), dst = try tmp()
        try write(src, "Light_M 8_10.0s_LP_1.fit")
        let r = SeestarRelay(source: src, destination: dst)
        XCTAssertEqual(try r.copyOnce(), 1)   // first pass copies
        XCTAssertEqual(try r.copyOnce(), 0)   // second pass skips existing
        XCTAssertEqual(r.relayedCount, 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LiveAstroCoreTests.SeestarRelayTests`
Expected: FAIL — `SeestarRelay` undefined.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Watches a Seestar `_sub` folder and stage-copies new matching subs into a
/// local destination, so the native watcher never reads a partial FITS off SMB.
/// Mirrors the proven seestar_relay.sh: mktemp stage → cp source→stage →
/// cp stage→dest, skip files already in dest.
public final class SeestarRelay {
    private let source: URL
    private let destination: URL
    private let glob: String
    private let pollSeconds: Double
    public var onLog: ((String) -> Void)?
    public private(set) var relayedCount = 0

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "seestar.relay")

    public init(source: URL, destination: URL,
                glob: String = "Light_*_10.0s_*.fit", pollSeconds: Double = 5) {
        self.source = source; self.destination = destination
        self.glob = glob; self.pollSeconds = pollSeconds
    }

    public func start() throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: pollSeconds)
        t.setEventHandler { [weak self] in _ = try? self?.copyOnce() }
        timer = t; t.resume()
    }

    public func stop() { timer?.cancel(); timer = nil }

    /// One relay pass: copy new matching files not yet in destination. Returns count copied.
    @discardableResult
    func copyOnce() throws -> Int {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: source.path)) ?? []
        let stage = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                               appropriateFor: destination, create: true)
        defer { try? fm.removeItem(at: stage) }
        var copied = 0
        for name in names.sorted() where Self.wildcardMatch(name, glob) {
            let dst = destination.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) { continue }
            let src = source.appendingPathComponent(name)
            let stg = stage.appendingPathComponent(name)
            do {
                try fm.copyItem(at: src, to: stg)      // slow SMB pull into stage (outside dest)
                try fm.copyItem(at: stg, to: dst)      // fast local copy into dest (atomic enough)
                try? fm.removeItem(at: stg)
                copied += 1; relayedCount += 1
                onLog?("relayed: \(name) (\(relayedCount))")
            } catch {
                try? fm.removeItem(at: stg); try? fm.removeItem(at: dst)  // retry next poll
                onLog?("retry next poll: \(name)")
            }
        }
        return copied
    }

    /// Minimal `*` wildcard match (no `?`), case-sensitive. Two-pointer with backtracking.
    static func wildcardMatch(_ name: String, _ pattern: String) -> Bool {
        let s = Array(name), p = Array(pattern)
        var si = 0, pi = 0, star = -1, mark = 0
        while si < s.count {
            if pi < p.count && (p[pi] == s[si]) { si += 1; pi += 1 }
            else if pi < p.count && p[pi] == "*" { star = pi; mark = si; pi += 1 }
            else if star != -1 { pi = star + 1; mark += 1; si = mark }
            else { return false }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LiveAstroCoreTests.SeestarRelayTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Seestar/SeestarRelay.swift Tests/LiveAstroCoreTests/SeestarRelayTests.swift
git commit -m "feat: SeestarRelay — native stage-copy relay for Seestar subs"
```

---

### Task 3: SeestarDetector

**Files:**
- Create: `Sources/LiveAstroCore/Seestar/SeestarDetector.swift`
- Test: `Tests/LiveAstroCoreTests/SeestarDetectorTests.swift`

**Interfaces:**
- Produces: `enum SeestarDetector { struct Found: Equatable { let subDir: URL; let target: String; let subExposure: Double? }; static func detect(volumesRoot: URL = URL(fileURLWithPath: "/Volumes")) -> Found?; static func parseExposure(fromFilename: String) -> Double? }`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class SeestarDetectorTests: XCTestCase {
    func tmp() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
    }

    func testParseExposure() {
        XCTAssertEqual(SeestarDetector.parseExposure(fromFilename: "Light_M 8_10.0s_LP_x.fit"), 10.0)
        XCTAssertEqual(SeestarDetector.parseExposure(fromFilename: "Light_NGC 7000_20.0s_LP_x.fit"), 20.0)
        XCTAssertNil(SeestarDetector.parseExposure(fromFilename: "nope.fit"))
    }

    func testDetectPicksNewestSubFolder() throws {
        let vols = try tmp()
        let works = vols.appendingPathComponent("EMMC Images/MyWorks")
        try FileManager.default.createDirectory(at: works, withIntermediateDirectories: true)
        let older = works.appendingPathComponent("NGC 7000_sub")
        let newer = works.appendingPathComponent("M 8_sub")
        for d in [older, newer] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data(count: 8).write(to: newer.appendingPathComponent("Light_M 8_10.0s_LP_1.fit"))
        // make `newer` the most-recently-modified
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: newer.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: older.path)

        let found = SeestarDetector.detect(volumesRoot: vols)
        XCTAssertEqual(found?.target, "M 8")
        XCTAssertEqual(found?.subExposure, 10.0)
        XCTAssertEqual(found?.subDir.lastPathComponent, "M 8_sub")
    }

    func testDetectReturnsNilWhenNoSub() throws {
        XCTAssertNil(SeestarDetector.detect(volumesRoot: try tmp()))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LiveAstroCoreTests.SeestarDetectorTests`
Expected: FAIL — `SeestarDetector` undefined.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Finds the active Seestar capture folder: scans <volumesRoot>/ * /MyWorks/ * _sub
/// and returns the newest-modified one (tonight's target).
public enum SeestarDetector {
    public struct Found: Equatable {
        public let subDir: URL
        public let target: String
        public let subExposure: Double?
        public init(subDir: URL, target: String, subExposure: Double?) {
            self.subDir = subDir; self.target = target; self.subExposure = subExposure
        }
    }

    public static func detect(volumesRoot: URL = URL(fileURLWithPath: "/Volumes")) -> Found? {
        let fm = FileManager.default
        var candidates: [(url: URL, mod: Date)] = []
        let vols = (try? fm.contentsOfDirectory(at: volumesRoot, includingPropertiesForKeys: nil)) ?? []
        for vol in vols {
            let works = vol.appendingPathComponent("MyWorks")
            let subs = (try? fm.contentsOfDirectory(at: works, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for sub in subs where sub.lastPathComponent.hasSuffix("_sub") {
                let mod = (try? sub.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                candidates.append((sub, mod))
            }
        }
        guard let best = candidates.max(by: { $0.mod < $1.mod }) else { return nil }
        let target = String(best.url.lastPathComponent.dropLast("_sub".count))
        let sample = ((try? fm.contentsOfDirectory(atPath: best.url.path)) ?? []).first { $0.hasSuffix(".fit") }
        return Found(subDir: best.url, target: target,
                     subExposure: sample.flatMap(parseExposure(fromFilename:)))
    }

    /// Parse "..._10.0s_..." → 10.0
    public static func parseExposure(fromFilename name: String) -> Double? {
        // find a token of the form <digits(.digits)?>s bounded by underscores
        for token in name.split(separator: "_") where token.hasSuffix("s") {
            let num = token.dropLast()
            if let v = Double(num) { return v }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LiveAstroCoreTests.SeestarDetectorTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Seestar/SeestarDetector.swift Tests/LiveAstroCoreTests/SeestarDetectorTests.swift
git commit -m "feat: SeestarDetector — find newest mounted Seestar _sub folder"
```

---

### Task 4: SessionPipeline import progress + cancel

**Files:**
- Modify: `Sources/LiveAstroCore/Sources/FolderFrameSource.swift` (add `totalCount`)
- Modify: `Sources/LiveAstroCore/Sources/FrameSource.swift` (add `totalCount` to protocol)
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` (progress callback + cancel)
- Test: `Tests/LiveAstroCoreTests/ImportProgressTests.swift`

**Interfaces:**
- Consumes: `FolderFrameSource`, `SessionPipeline` native mode, `StackEngine`.
- Produces: `FrameSource.totalCount: Int? { get }`; `SessionPipeline.onImportProgress: ((_ processed: Int, _ total: Int, _ accepted: Int, _ rejected: Int) -> Void)?`; `SessionPipeline.cancelImport()`.

- [ ] **Step 1: Add `totalCount` to the FrameSource protocol**

In `FrameSource.swift`, add to the protocol:
```swift
    /// Total frames known up front (finite import); nil for live sources.
    var totalCount: Int? { get }
```
In `FolderFrameSource.swift`, implement it (it already enumerates the folder for importOnce; expose that count). Add a stored `public let totalCount: Int?` set in `init` — for `.importOnce`, the count of prefix-matching `.fit` files in `folder`; for `.live`, `nil`:
```swift
    public let totalCount: Int?
```
The `.importOnce` init path already builds the sorted list of prefix-matching `.fit` files it will emit. Capture its `.count` into `self.totalCount`; for `.live`, set `self.totalCount = nil`. (Read the existing `init` to find that file-list local and set `totalCount` from its count — do not re-enumerate the folder separately.)

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class ImportProgressTests: XCTestCase {
    func writeSub(_ dir: URL, _ name: String, stars: [(Double, Double)]) throws {
        var px = [Float](repeating: 0.05, count: 128 * 128)
        for s in stars {
            for y in max(0, Int(s.1)-4)...min(127, Int(s.1)+4) {
                for x in max(0, Int(s.0)-4)...min(127, Int(s.0)+4) {
                    let dx = Double(x)-s.0, dy = Double(y)-s.1
                    px[y*128+x] += 0.8 * Float(exp(-(dx*dx+dy*dy)/6))
                }
            }
        }
        try FITSWriter.float32(width: 128, height: 128, channels: 1, pixels: px)
            .write(to: dir.appendingPathComponent(name))
    }

    func testImportReportsProgress() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let subs = sandbox.appendingPathComponent("subs"), sessions = sandbox.appendingPathComponent("s")
        try FileManager.default.createDirectory(at: subs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        var field: [(Double, Double)] = []
        for i in 0..<18 { field.append((Double((i*37)%116+6), Double((i*53)%116+6))) }
        for i in 1...4 { try writeSub(subs, "Light_00\(i).fit", stars: field.map { ($0.0 + Double(i)*0.5, $0.1) }) }

        let profile = SessionProfile(targetName: "T", telescope: "", camera: "", mount: "",
                                     filter: "", locationLabel: "", bortle: 5, subExposureSeconds: 10, notes: "")
        let source = FolderFrameSource(folder: subs, mode: .importOnce, fileNamePrefix: "Light_")
        XCTAssertEqual(source.totalCount, 4)
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: profile, rootDirectory: sessions)
        var lastTotal = 0, lastProcessed = 0
        pipeline.onImportProgress = { processed, total, _, _ in lastProcessed = processed; lastTotal = total }
        try pipeline.start()
        _ = try pipeline.end()
        XCTAssertEqual(lastTotal, 4)
        XCTAssertEqual(lastProcessed, 4)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter LiveAstroCoreTests.ImportProgressTests`
Expected: FAIL — `onImportProgress` / `totalCount` undefined.

- [ ] **Step 4: Implement in SessionPipeline**

Add properties:
```swift
    public var onImportProgress: ((_ processed: Int, _ total: Int,
                                   _ accepted: Int, _ rejected: Int) -> Void)?
    private let cancelled = NSLock_Flag()   // simple atomic bool (see below)
    private var processedCount = 0
```
Add a tiny atomic-bool helper at file scope:
```swift
final class NSLock_Flag {
    private let lock = NSLock(); private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
```
`cancelImport()`:
```swift
    /// Cancel an in-progress import: stops feeding new frames; end() finalizes
    /// whatever completed into a valid master.fit + replay (not a hard abort).
    public func cancelImport() { cancelled.set(); source?.stop() }
```
In `handleNative`, at the top add the cancel check + progress emit (after computing the outcome, whether accepted or rejected):
```swift
    private func handleNative(_ rawFrame: RawFrame, engine: StackEngine) {
        if cancelled.isSet { return }
        let frame = calibrator?.apply(rawFrame) ?? rawFrame
        let outcome = engine.process(frame)
        processedCount += 1
        // …existing accepted/rejected handling unchanged…
        if let total = source?.totalCount {
            onImportProgress?(processedCount, total, engine.acceptedCount, engine.rejectedCount)
        }
    }
```
(Keep the existing `switch outcome` body; only add the `processedCount`/progress lines and the leading `cancelled` guard. `engine.rejectedCount` already exists.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter LiveAstroCoreTests.ImportProgressTests` then `swift test --filter LiveAstroCoreTests.NativePipelineTests` (regression) and `swift test --filter LiveAstroCoreTests.CalibratedPipelineTests`.
Expected: all PASS (progress reported; existing native/calibrated e2e unaffected since callbacks default nil).

- [ ] **Step 6: Commit**

```bash
git add Sources/LiveAstroCore/Sources/FrameSource.swift Sources/LiveAstroCore/Sources/FolderFrameSource.swift Sources/LiveAstroCore/Pipeline/SessionPipeline.swift Tests/LiveAstroCoreTests/ImportProgressTests.swift
git commit -m "feat: import progress callback + cancelImport on SessionPipeline"
```

---

### Task 5: Wire settings persistence into AppModel

**Files:**
- Modify: `Sources/LiveAstroStudio/AppModel.swift`

**Interfaces:**
- Consumes: `SessionSettings`, `SessionSettingsStore` (Task 1).

This task has no unit test (AppModel is app-layer glue over the Task 1 core, which is tested). Deliverable: settings load at launch and persist across relaunches.

- [ ] **Step 1: Add load/save mapping**

Add to `AppModel`:
```swift
    private func currentSettings() -> SessionSettings {
        SessionSettings(
            sourceModeRaw: sourceMode.rawValue,
            watchFolderPath: watchFolder?.path,
            filePrefix: fileNamePrefix,
            neutralizeBackground: neutralizeBackground,
            subExposureSeconds: Double(subExposureText) ?? 60,
            targetName: targetName,
            calibration: calibration)
    }
    func saveSettings() { SessionSettingsStore.save(currentSettings(), to: .standard) }
    func loadSettings() {
        let s = SessionSettingsStore.load(.standard)
        sourceMode = SourceMode(rawValue: s.sourceModeRaw) ?? .stackerOutput
        watchFolder = s.watchFolderPath.map { URL(fileURLWithPath: $0) }
        fileNamePrefix = s.filePrefix
        neutralizeBackground = s.neutralizeBackground
        subExposureText = String(format: "%g", s.subExposureSeconds)
        targetName = s.targetName
        calibration = s.calibration
    }
```

- [ ] **Step 2: Call loadSettings() at init and saveSettings() at session/import start**

In `AppModel.init()` (create one if absent), call `loadSettings()` after the stored properties initialize. In the existing `startSession()`, `importSubs(from:)`, and the new `startSeestarLive()` (Task 7), call `saveSettings()` as the first line so the last-used config persists. Also call `saveSettings()` in the app's `applicationWillTerminate` (add to `AppDelegate` via a model reference, or call from `endSession()`).

- [ ] **Step 3: Build + manual validation**

Run: `swift build`
Manual: launch, change source mode / prefix / neutralize / sub-exposure / target, start (or just quit), relaunch → fields are pre-filled with the last values.

- [ ] **Step 4: Commit**

```bash
git add Sources/LiveAstroStudio/AppModel.swift
git commit -m "feat: persist + restore control-form settings across launches"
```

---

### Task 6: Window restructure — MainView tabs + detach + fixed footer

**Files:**
- Create: `Sources/LiveAstroStudio/MainView.swift`
- Modify: `Sources/LiveAstroStudio/LiveAstroApp.swift`
- Modify: `Sources/LiveAstroStudio/ControlView.swift` (Start/End/Seestar-Live into a fixed footer)
- Modify: `Sources/LiveAstroStudio/AppModel.swift` (add `selectedTab`, `isDetached`)

No unit test (SwiftUI window lifecycle). Deliverable: one window with `Live | Setup | Help`, always-visible Start footer, working detach that OBS can still capture.

- [ ] **Step 1: Add tab + detach state to AppModel**

```swift
    enum MainTab: String, CaseIterable { case live = "Live", setup = "Setup", help = "Help" }
    var selectedTab: MainTab = .setup
    var isDetached = false
```

- [ ] **Step 2: Create MainView**

```swift
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $model.selectedTab) {
                    ForEach(AppModel.MainTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
                Spacer()
                if model.selectedTab == .live {
                    Button { openWindow(id: "broadcast"); model.isDetached = true } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }.help("Detach the display into its own window (for OBS capture / second monitor)")
                     .disabled(model.isDetached)
                }
            }.padding(8)
            Divider()
            switch model.selectedTab {
            case .live:  model.isDetached ? AnyView(detachedPlaceholder) : AnyView(BroadcastView())
            case .setup: AnyView(ControlView())
            case .help:  AnyView(HelpView())
            }
        }
    }

    private var detachedPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle").font(.largeTitle).foregroundStyle(.secondary)
            Text("Display detached ↗").foregroundStyle(.secondary)
            Text("Close the detached window to re-embed it here.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
    }
}
```
(HelpView is created in Task 9; if implementing Task 6 first, stub `struct HelpView: View { var body: some View { Text("Help") } }` and flesh out in Task 9.)

- [ ] **Step 3: Point the main WindowGroup at MainView; keep broadcast window as detached**

In `LiveAstroApp.swift`, change the main scene body to `MainView().environment(model)` (title "LiveAstro"), and on the broadcast `Window`, add `.onDisappear { model.isDetached = false }` so closing the detached window re-embeds. Keep `.windowStyle(.hiddenTitleBar)` and the existing `BroadcastWindowConfigurator` wiring intact. Give `MainView` a larger default size (e.g. `CGSize(width: 900, height: 720)`) so the Live view is usable.

- [ ] **Step 4: Move Start/End/Seestar-Live into a fixed footer in ControlView**

Refactor `ControlView` so the form (source, watch folder, prefix, neutralize, calibration, session profile) is inside a `ScrollView`, and the action buttons (Start/End Session, Import Subs, Open Broadcast Window → now "Detach", Reseed, and the new Seestar Live button) live in a `VStack` **below** the ScrollView (outside it) so they never scroll off. Auto-switch: in `startSession()`/`startSeestarLive()`, set `selectedTab = .live`.

- [ ] **Step 5: Build + manual validation**

Run: `swift build`
Manual: (a) window shows Live|Setup|Help; (b) Setup's Start button is always visible without scrolling; (c) starting a session flips to Live and shows the stack; (d) Detach opens a separate borderless window, Live tab shows the placeholder; (e) **OBS → add "macOS Screen Capture" / window capture still lists and captures the detached "LiveAstro Broadcast" window**; (f) closing the detached window re-embeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/LiveAstroStudio/MainView.swift Sources/LiveAstroStudio/LiveAstroApp.swift Sources/LiveAstroStudio/ControlView.swift Sources/LiveAstroStudio/AppModel.swift
git commit -m "feat: tabbed Live|Setup|Help window with detachable display + fixed Start footer"
```

---

### Task 7: One-tap Seestar Live flow

**Files:**
- Modify: `Sources/LiveAstroStudio/AppModel.swift`
- Modify: `Sources/LiveAstroStudio/ControlView.swift` (Seestar Live button in the footer)

**Interfaces:**
- Consumes: `SeestarDetector`, `SeestarRelay` (Tasks 2–3), the native `startSession()` path.

No unit test (integration over tested core). Deliverable: one button configures + relays + starts + switches to Live.

- [ ] **Step 1: Add the relay handle + flow to AppModel**

```swift
    private var seestarRelay: SeestarRelay?

    func startSeestarLive() {
        guard let found = SeestarDetector.detect() else {
            errorMessage = "No Seestar share found. Mount it first: Finder → Go → Connect to Server → the Seestar's smb:// address, then try again."
            return
        }
        // configure
        sourceMode = .nativeStack
        fileNamePrefix = "Light_"
        neutralizeBackground = true
        targetName = found.target
        subExposureText = String(format: "%g", found.subExposure ?? 10)
        // app-managed relay dir
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let relayDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("LiveAstro/relay/\(found.target)-\(df.string(from: Date()))", isDirectory: true)
        let relay = SeestarRelay(source: found.subDir, destination: relayDir)
        relay.onLog = { [weak self] in self?.log.append($0) }
        do { try relay.start() } catch { errorMessage = "Relay failed to start: \(error)"; return }
        seestarRelay = relay
        watchFolder = relayDir
        saveSettings()
        startSession()             // existing native-start path (uses watchFolder + sourceMode)
        selectedTab = .live
    }
```

- [ ] **Step 2: Stop the relay on end + quit**

In the existing `endSession()`, add `seestarRelay?.stop(); seestarRelay = nil` before/after the pipeline `end()`. Ensure `applicationWillTerminate` (or `endSession()`) also stops it so it never outlives the session.

- [ ] **Step 3: Add the Seestar Live button to the ControlView footer**

```swift
    Button {
        model.startSeestarLive()
    } label: { Label("Seestar Live", systemImage: "dot.radiowaves.left.and.right") }
    .help("Auto-detect the mounted Seestar folder, start relaying its 10s subs, and begin native stacking — one tap.")
    .disabled(model.isRunning)
```

- [ ] **Step 4: Build + manual validation**

Run: `swift build`
Manual (needs the Seestar share mounted, or a fake `/Volumes/*/MyWorks/*_sub` tree): tap Seestar Live → detects the target, starts relaying into `~/LiveAstro/relay/<target>-<date>/`, native session starts, view flips to Live and the stack builds. With no share mounted → the guidance alert appears. End Session stops the relay (no leftover `SeestarRelay` process activity).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroStudio/AppModel.swift Sources/LiveAstroStudio/ControlView.swift
git commit -m "feat: one-tap Seestar Live — detect, relay, native-stack in one action"
```

---

### Task 8: Import progress + Cancel UI

**Files:**
- Modify: `Sources/LiveAstroStudio/AppModel.swift`
- Modify: `Sources/LiveAstroStudio/ControlView.swift`

**Interfaces:**
- Consumes: `SessionPipeline.onImportProgress`, `cancelImport()` (Task 4).

No unit test (UI over tested core). Deliverable: import shows a live progress bar + counts + Cancel.

- [ ] **Step 1: Add progress state + wire the callback**

```swift
    var importProcessed = 0
    var importTotal = 0
```
Where the import `SessionPipeline` is constructed in `importSubs(from:)`, set:
```swift
    pipeline.onImportProgress = { [weak self] processed, total, accepted, rejected in
        DispatchQueue.main.async {
            self?.importProcessed = processed; self?.importTotal = total
            self?.acceptedCount = accepted; self?.rejectedCount = rejected
        }
    }
    self.importPipeline = pipeline    // keep a reference so Cancel can reach it
```
Add `private var importPipeline: SessionPipeline?` and:
```swift
    func cancelImport() { importPipeline?.cancelImport() }
```

- [ ] **Step 2: Progress + Cancel UI in the footer (import state)**

```swift
    if model.isImporting {
        VStack(spacing: 4) {
            ProgressView(value: Double(model.importProcessed),
                         total: Double(max(model.importTotal, 1)))
            HStack {
                Text("\(model.importProcessed) / \(model.importTotal)")
                Spacer()
                Text("✓ \(model.acceptedCount)  ✗ \(model.rejectedCount)").foregroundStyle(.secondary)
                Button("Cancel", role: .cancel) { model.cancelImport() }
            }.font(.caption)
        }.padding(.horizontal)
    }
```

- [ ] **Step 3: Build + manual validation**

Run: `swift build`
Manual: Import Subs on a folder → a progress bar advances "N / total" with live accepted/rejected; Cancel stops it and the session finalizes a valid `master.fit` + replay of what completed (no corrupt session, no force-quit needed).

- [ ] **Step 4: Commit**

```bash
git add Sources/LiveAstroStudio/AppModel.swift Sources/LiveAstroStudio/ControlView.swift
git commit -m "feat: import progress bar + accepted/rejected + Cancel button"
```

---

### Task 9: Hover tooltips + Help tab

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift`, `CalibrationSection.swift` (`.help(...)` on controls)
- Create: `Sources/LiveAstroStudio/HelpView.swift`
- Create: `Sources/LiveAstroStudio/Resources/Help.md`
- Modify: `Package.swift` (bundle `Resources/` for the LiveAstroStudio target)

No unit test (UI/content). Deliverable: hover tips on controls + a rendered Help tab.

- [ ] **Step 1: Add `.help(...)` to controls**

Add a `.help("…")` to each control with a one-line explanation: Source segmented control ("Stacker output watches Siril's live_stack.fit; Raw subs stacks the individual exposures natively"), watch-folder Choose, File prefix, Neutralize background, each calibration Dark/Flat/Bias row + Build/Use-file, Sub-exposure, Reseed, Detach, Import Subs, and the OBS host/port/password fields. Keep each tip to one sentence.

- [ ] **Step 2: Add Help.md**

Create `Sources/LiveAstroStudio/Resources/Help.md` with concise sections: **Quick start (Seestar Live)**, **Source modes**, **Calibration**, **OBS setup** (include the WebSocket-password-regenerates gotcha), **Troubleshooting** (no share found → mount it; stack not updating → check the relay folder). Plain Markdown.

- [ ] **Step 3: Bundle resources in Package.swift**

In the `LiveAstroStudio` target, add `resources: [.process("Resources")]` so `Help.md` ships in the bundle.

- [ ] **Step 4: HelpView renders the bundled Markdown**

```swift
import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            Text(helpText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
    private var helpText: AttributedString {
        guard let url = Bundle.module.url(forResource: "Help", withExtension: "md"),
              let md = try? String(contentsOf: url, encoding: .utf8),
              let attr = try? AttributedString(markdown: md,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return AttributedString("Help unavailable.") }
        return attr
    }
}
```

- [ ] **Step 5: Build + run full suite + manual validation**

Run: `swift build` then `swift test`
Expected: build succeeds; all tests pass.
Manual: hovering any control shows its tip; the Help tab renders the guide.

- [ ] **Step 6: Commit**

```bash
git add Sources/LiveAstroStudio/HelpView.swift Sources/LiveAstroStudio/Resources/Help.md Sources/LiveAstroStudio/ControlView.swift Sources/LiveAstroStudio/CalibrationSection.swift Package.swift
git commit -m "feat: hover tooltips + in-app Help tab (bundled Help.md)"
```

---

## Manual validation (whole feature, documented per house rules)

Run once on real hardware after all tasks:
1. Relaunch → all settings pre-filled (Task 5).
2. Mount Seestar share, tap **Seestar Live** → detects target, relays, stacks, flips to Live (Task 7).
3. **Detach** → OBS captures the separate window (Task 6).
4. **Import Subs** on `~/Desktop/livestack_live` → progress bar + counts; **Cancel** mid-way → valid partial master + replay (Tasks 4, 8).
5. Hover tips + Help tab readable (Task 9).

## Global self-check before final review

`swift test` (all pass) and `swift build`. Confirm the release `.app` still lists the detached broadcast window to OBS (the one regression risk).
