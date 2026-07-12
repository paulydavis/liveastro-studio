# ASIAIR Live — one-tap auto-detect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a one-tap "Start ASIAIR" live source that auto-detects the ASIAIR's `Autorun/Light` target folder and starts session-scoped relay + native stacking, and adopt verb-led names for the three live buttons.

**Architecture:** A new Foundation-only `ASIAIRDetector` in LiveAstroCore (mirrors `SeestarDetector`, different path) finds tonight's target folder; new AppModel methods `startASIAIRLive`/`configureAndStartASIAIR` wire it into the existing `FrameRelay` + native-stacking path; ControlView gains a Start ASIAIR button and the two existing live buttons are renamed. Help.md is updated to match.

**Tech Stack:** Swift 5.10, SwiftUI, SwiftPM, XCTest. Zero external dependencies.

## Global Constraints

- Swift 5.10, macOS 14+.
- `LiveAstroCore` imports Foundation / CoreGraphics / Accelerate only. `ASIAIRDetector` uses Foundation + the in-module `LiveSourceMetadata`.
- Zero external dependencies.
- Core logic is TDD'd (`swift test --filter LiveAstroCoreTests`); SwiftUI app code is build/manual-verified (no XCTest for the app target, house pattern).
- New source group `Sources/LiveAstroCore/ASIAIR/`.
- v1 covers **Autorun/Light only** — no ASIAIR Plan-mode / manual-capture paths.
- Seestar Live and Watch Folder Live behavior unchanged (labels change; handlers do not).
- Verb-led button names: **Start Seestar** / **Start ASIAIR** / **Choose Folder…**.
- Co-Authored-By Claude trailer allowed in this repo.

---

### Task 1: `ASIAIRDetector` (TDD)

**Files:**
- Create: `Sources/LiveAstroCore/ASIAIR/ASIAIRDetector.swift`
- Test: `Tests/LiveAstroCoreTests/ASIAIRDetectorTests.swift`

**Interfaces:**
- Consumes: `LiveSourceMetadata.newestFITSMetadata(inFolder:) -> (object: String?, exposureSeconds: Double?, fileExtension: String)?` (existing).
- Produces:
  - `public struct ASIAIRDetector.Found: Equatable { let subDir: URL; let target: String; let subExposure: Double?; let subFileExtension: String }`
  - `public static func ASIAIRDetector.detect(volumesRoot: URL = URL(fileURLWithPath: "/Volumes")) -> Found?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LiveAstroCoreTests/ASIAIRDetectorTests.swift`:

```swift
import XCTest
@testable import LiveAstroCore

final class ASIAIRDetectorTests: XCTestCase {
    func tmp() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
    }

    /// Create <vol>/Autorun/Light/<target>/ and return that target folder URL.
    @discardableResult
    func makeTarget(_ vol: URL, _ target: String) throws -> URL {
        let dir = vol.appendingPathComponent("Autorun/Light/\(target)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write a 1-channel FITS carrying OBJECT/EXPTIME via SourceMetadata (mirrors LiveSourceMetadataTests).
    func writeFITS(_ dir: URL, _ name: String, object: String?, exposure: Double?) throws {
        var meta = SourceMetadata()
        meta.object = object
        meta.exposureSeconds = exposure
        let px = [Float](repeating: 0.1, count: 8 * 8)
        try FITSWriter.float32(width: 8, height: 8, channels: 1, pixels: px, metadata: meta)
            .write(to: dir.appendingPathComponent(name))
    }

    func testTargetIsFolderNameNewestWins() throws {
        let volumes = try tmp()
        let vol = volumes.appendingPathComponent("ASIAIR", isDirectory: true)
        let older = try makeTarget(vol, "NGC 7000")
        let newer = try makeTarget(vol, "M 31")
        try writeFITS(older, "a.fit", object: "x", exposure: 60)
        try writeFITS(newer, "b.fit", object: "y", exposure: 120)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: newer.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: older.path)

        let found = ASIAIRDetector.detect(volumesRoot: volumes)
        XCTAssertEqual(found?.target, "M 31")
        XCTAssertEqual(found?.subDir.lastPathComponent, "M 31")
    }

    func testExposureAndExtensionFromHeader() throws {
        let volumes = try tmp()
        let vol = volumes.appendingPathComponent("ASIAIR", isDirectory: true)
        let t = try makeTarget(vol, "M 42")
        try writeFITS(t, "light.fit", object: "M 42", exposure: 180)
        let found = ASIAIRDetector.detect(volumesRoot: volumes)
        XCTAssertEqual(found?.subExposure, 180)
        XCTAssertEqual(found?.subFileExtension, "fit")
    }

    func testIgnoresTargetFolderWithoutFITS() throws {
        let volumes = try tmp()
        let vol = volumes.appendingPathComponent("ASIAIR", isDirectory: true)
        let empty = try makeTarget(vol, "EMPTY")               // newer, but no FITS
        let withFits = try makeTarget(vol, "M 13")             // older, has FITS
        try writeFITS(withFits, "a.fit", object: "M 13", exposure: 90)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: empty.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: withFits.path)
        let found = ASIAIRDetector.detect(volumesRoot: volumes)
        XCTAssertEqual(found?.target, "M 13")   // containment guard beats "newest"
    }

    func testReturnsNilWhenNoAutorunLight() throws {
        let volumes = try tmp()
        let vol = volumes.appendingPathComponent("ASIAIR", isDirectory: true)
        try FileManager.default.createDirectory(at: vol.appendingPathComponent("SomethingElse"),
                                                withIntermediateDirectories: true)
        XCTAssertNil(ASIAIRDetector.detect(volumesRoot: volumes))
    }

    func testReturnsNilWhenNoFITSAnywhere() throws {
        let volumes = try tmp()
        let vol = volumes.appendingPathComponent("ASIAIR", isDirectory: true)
        let t = try makeTarget(vol, "M 45")
        try Data("nope".utf8).write(to: t.appendingPathComponent("readme.txt"))
        XCTAssertNil(ASIAIRDetector.detect(volumesRoot: volumes))
    }

    func testScansMultipleVolumes() throws {
        let volumes = try tmp()
        let volA = volumes.appendingPathComponent("EMPTYVOL", isDirectory: true)
        try FileManager.default.createDirectory(at: volA, withIntermediateDirectories: true)   // no Autorun/Light
        let volB = volumes.appendingPathComponent("ASIAIR", isDirectory: true)
        let t = try makeTarget(volB, "IC 1396")
        try writeFITS(t, "a.fit", object: "IC 1396", exposure: 300)
        let found = ASIAIRDetector.detect(volumesRoot: volumes)
        XCTAssertEqual(found?.target, "IC 1396")
    }

    func testFitsExtensionSupported() throws {
        let volumes = try tmp()
        let vol = volumes.appendingPathComponent("ASIAIR", isDirectory: true)
        let t = try makeTarget(vol, "M 8")
        try writeFITS(t, "a.fits", object: "M 8", exposure: 45)   // .fits, not .fit
        let found = ASIAIRDetector.detect(volumesRoot: volumes)
        XCTAssertEqual(found?.subFileExtension, "fits")
        XCTAssertEqual(found?.subExposure, 45)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ASIAIRDetectorTests`
Expected: FAIL — `cannot find 'ASIAIRDetector' in scope`.

- [ ] **Step 3: Write the detector**

Create `Sources/LiveAstroCore/ASIAIR/ASIAIRDetector.swift`:

```swift
import Foundation

/// Finds the active ASIAIR capture folder: scans <volumesRoot>/*/Autorun/Light/<TARGET>/
/// and returns the newest-modified target folder that contains at least one
/// .fit/.fits sub. `target` is the folder name; `subExposure` and
/// `subFileExtension` come from the newest FITS header via LiveSourceMetadata.
///
/// Mirrors `SeestarDetector` but for the ASIAIR's Autorun/Light layout. Unlike
/// Seestar's `_sub` suffix, ASIAIR target folders have no marker, so a
/// "contains FITS" guard is what distinguishes a real capture folder from an
/// empty leftover.
public enum ASIAIRDetector {
    public struct Found: Equatable {
        public let subDir: URL
        public let target: String
        public let subExposure: Double?
        public let subFileExtension: String
        public init(subDir: URL, target: String, subExposure: Double?, subFileExtension: String) {
            self.subDir = subDir
            self.target = target
            self.subExposure = subExposure
            self.subFileExtension = subFileExtension
        }
    }

    public static func detect(volumesRoot: URL = URL(fileURLWithPath: "/Volumes")) -> Found? {
        let fm = FileManager.default
        var candidates: [(url: URL, mod: Date)] = []
        let vols = (try? fm.contentsOfDirectory(at: volumesRoot, includingPropertiesForKeys: nil)) ?? []
        for vol in vols {
            let lightRoot = vol.appendingPathComponent("Autorun").appendingPathComponent("Light")
            let targets = (try? fm.contentsOfDirectory(
                at: lightRoot,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])) ?? []
            for target in targets {
                let isDir = (try? target.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard isDir, folderContainsFITS(target, fm: fm) else { continue }
                let mod = (try? target.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                candidates.append((target, mod))
            }
        }
        guard let best = candidates.max(by: { $0.mod < $1.mod }) else { return nil }
        let meta = LiveSourceMetadata.newestFITSMetadata(inFolder: best.url)
        return Found(subDir: best.url,
                     target: best.url.lastPathComponent,
                     subExposure: meta?.exposureSeconds,
                     subFileExtension: meta?.fileExtension ?? "fit")
    }

    private static func folderContainsFITS(_ folder: URL, fm: FileManager) -> Bool {
        let items = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        return items.contains { ["fit", "fits"].contains(($0 as NSString).pathExtension.lowercased()) }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ASIAIRDetectorTests`
Expected: PASS — all tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/ASIAIR/ASIAIRDetector.swift Tests/LiveAstroCoreTests/ASIAIRDetectorTests.swift
git commit -m "feat: ASIAIRDetector — auto-detect Autorun/Light target folder (TDD)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: AppModel wiring + ControlView button + verb-led rename + Help.md consistency

**Files:**
- Modify: `Sources/LiveAstroStudio/AppModel.swift` (add `startASIAIRLive` + `configureAndStartASIAIR`, near the Seestar pair ~line 491–535)
- Modify: `Sources/LiveAstroStudio/ControlView.swift` (footer buttons ~line 154–159)
- Modify: `Sources/LiveAstroStudio/Resources/Help.md`

**Interfaces:**
- Consumes: `ASIAIRDetector.detect() -> ASIAIRDetector.Found?` and `Found { subDir, target, subExposure, subFileExtension }` (Task 1); existing `FrameRelay(source:destination:glob:)`, `startSession()`, `sourceMode`, `fileNamePrefix`, `neutralizeBackground`, `targetName`, `subExposureText`, `watchFolder`, `frameRelay`, `isDetecting`, `zoomPan`, `selectedTab`, `log`, `errorMessage`.
- Produces: nothing consumed by later tasks (final task).

- [ ] **Step 1: Add the AppModel methods**

In `Sources/LiveAstroStudio/AppModel.swift`, immediately after `configureAndStartSeestar(_:)` (ends ~line 535, before `endSession()`), add:

```swift
    func startASIAIRLive() {
        guard !isRunning, !isImporting, !isDetecting else { return }
        zoomPan = .fit
        isDetecting = true
        log.append("Looking for ASIAIR share…")
        Task.detached { [weak self] in
            let found = ASIAIRDetector.detect()       // SMB directory work, off the main thread
            await MainActor.run {
                guard let self else { return }
                self.isDetecting = false
                guard let found else {
                    self.errorMessage = "No ASIAIR share found. In the ASIAIR app: Settings → Network Share → Enable. Then on the Mac: Finder → Go → Connect to Server → smb://asiair.local, and try again."
                    return
                }
                self.configureAndStartASIAIR(found)
            }
        }
    }

    /// On-main configure + start for an auto-detected ASIAIR target folder.
    /// Unlike the Seestar path, the relay glob is `*.<ext>` (the ASIAIR target
    /// folder is already target-scoped) and `fileNamePrefix` is cleared: the
    /// relay dir is glob-filtered AND session-scoped, so the native stacker must
    /// accept every FITS in it — ASIAIR light files are not guaranteed to start
    /// with "Light_" (the .nativeStack default prefix would otherwise drop them).
    private func configureAndStartASIAIR(_ found: ASIAIRDetector.Found) {
        sourceMode = .nativeStack
        fileNamePrefix = ""                 // accept-all: see doc comment above
        neutralizeBackground = true
        targetName = found.target
        subExposureText = String(format: "%g", found.subExposure ?? 10)
        let glob = "*.\(found.subFileExtension)"
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let relayDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("LiveAstro/relay/\(found.target)-\(df.string(from: Date()))",
                                    isDirectory: true)
        let relay = FrameRelay(source: found.subDir, destination: relayDir, glob: glob)
        relay.onLog = { [weak self] msg in Task { @MainActor in self?.log.append(msg) } }
        do { try relay.start() } catch { errorMessage = "Relay failed to start: \(error)"; return }
        frameRelay = relay
        watchFolder = relayDir
        saveSettings()
        startSession()
        if !isRunning { frameRelay?.stop(); frameRelay = nil; return }
        selectedTab = .live
    }
```

- [ ] **Step 2: Add the Start ASIAIR button and rename the two existing live buttons**

In `Sources/LiveAstroStudio/ControlView.swift`, the footer block currently reads:

```swift
                    Button {
                        model.startSeestarLive()
                    } label: { Label("Seestar Live", systemImage: "dot.radiowaves.left.and.right") }
                    .help("Auto-detect the mounted Seestar folder, start relaying its 10s subs, and begin native stacking — one tap.")
                    .disabled(model.isRunning || model.isImporting || model.isDetecting)
                    Button("Watch Folder Live") { pickWatchFolderLive() }
                        .help("Live-stack subs from any folder your rig writes to (ASIAIR / NINA / ASI camera) — session-scoped from the moment you start.")
                        .disabled(model.isRunning || model.isImporting || model.isDetecting)
```

Replace it with (rename Seestar's label, add Start ASIAIR, rename the manual pick):

```swift
                    Button {
                        model.startSeestarLive()
                    } label: { Label("Start Seestar", systemImage: "dot.radiowaves.left.and.right") }
                    .help("Auto-detect the mounted Seestar folder, start relaying its 10s subs, and begin native stacking — one tap.")
                    .disabled(model.isRunning || model.isImporting || model.isDetecting)
                    Button {
                        model.startASIAIRLive()
                    } label: { Label("Start ASIAIR", systemImage: "camera.aperture") }
                    .help("Auto-detect the ASIAIR's Autorun/Light folder, relay its subs, and begin native stacking — one tap.")
                    .disabled(model.isRunning || model.isImporting || model.isDetecting)
                    Button("Choose Folder…") { pickWatchFolderLive() }
                        .help("Live-stack subs from any folder your rig writes to (NINA / ASI camera / any incoming-subs folder) — session-scoped from the moment you start.")
                        .disabled(model.isRunning || model.isImporting || model.isDetecting)
```

- [ ] **Step 3: Build (debug) to verify it compiles**

Run: `swift build`
Expected: `Build complete!` with no errors.

- [ ] **Step 4: Update Help.md button-name references and document the new source**

In `Sources/LiveAstroStudio/Resources/Help.md`:

(a) Replace the Quick Start section (the `## Quick Start` heading through its numbered list) with:

```markdown
## Quick Start

There are three one-tap live paths. Each relays only the subs that arrive **after** you tap (session-scoped), then stacks them natively.

1. **Start Seestar** — mount the Seestar's SMB share in Finder, then tap **Start Seestar**. The app auto-detects the share, relays 10-second subs to a local folder, and begins stacking.
2. **Start ASIAIR** — mount the ASIAIR's SMB share (ASIAIR app: Settings → Network Share → Enable), then tap **Start ASIAIR**. The app auto-detects the ASIAIR's `Autorun/Light` target folder and stacks its subs live.
3. **Choose Folder…** — tap **Choose Folder…** and pick the folder your rig writes subs to (a NINA output folder, or any incoming-subs folder). The app relays new subs from that folder and stacks them.
```

(b) Replace the Source Modes table rows with:

```markdown
| **Start Seestar** | Auto-detects the Seestar SMB share and stacks its 10s subs live. |
| **Start ASIAIR** | Auto-detects the ASIAIR's Autorun/Light folder and stacks its subs live. |
| **Choose Folder…** | Relays new subs from a folder you pick (any rig) and stacks them live. |
| **Raw subs** | Imports and stacks a folder of existing sub-exposures with the native stacker. |
```

(c) In the Troubleshooting section, rename the button references:
- `**"No share found" when tapping Seestar Live**` → `**"No share found" when tapping Start Seestar**`
- In that item's body, `try Seestar Live again.` → `try Start Seestar again.`
- `**Watch Folder Live isn't stacking**` → `**Choose Folder… isn't stacking**`

- [ ] **Step 5: Verify Help.md still parses within the renderer's subset (regression guard)**

Run: `swift test --filter MarkdownBlocksTests/testBundledHelpHasNoFallenThroughBlockMarkers`
Expected: PASS — the edited Help.md stays within the supported markdown subset.

- [ ] **Step 6: Confirm Core suite green + release build**

Run: `swift test --filter LiveAstroCoreTests`
Expected: all tests pass (adds `ASIAIRDetectorTests`; no regressions).

Run: `swift build -c release`
Expected: succeeds (ships the app).

- [ ] **Step 7: Manual check (RELEASE, no hardware needed)**

Create a fake tree and confirm detect → relay → live stack:
```bash
mkdir -p "/Volumes/ASIAIR/Autorun/Light/M 31"   # if /Volumes is writable; else use a spare mounted volume
```
(If `/Volumes` is not writable without a mounted share, this manual step is done later with the real ASIAIR.) Launch the app, tap **Start ASIAIR**: with no share, confirm the guidance message; with a folder present, confirm target/exposure fill in and the Live tab shows stacking. Confirm the footer now reads **Start Seestar · Start ASIAIR · Choose Folder…** and Help renders the three-path Quick Start.

- [ ] **Step 8: Commit**

```bash
git add Sources/LiveAstroStudio/AppModel.swift Sources/LiveAstroStudio/ControlView.swift Sources/LiveAstroStudio/Resources/Help.md
git commit -m "feat: Start ASIAIR one-tap live source + verb-led live-button naming

Auto-detect the ASIAIR Autorun/Light folder → session-scoped relay + native
stacking (accept-all prefix, *.ext glob). Rename Seestar Live → Start Seestar,
Watch Folder Live → Choose Folder…; update Help.md to match.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage:**
- ASIAIRDetector (scan Autorun/Light, newest-modified-with-FITS, target=folder name, exposure from header) → Task 1. ✅
- Reuse FrameRelay session-scoped relay + native stacking → Task 2 `configureAndStartASIAIR`. ✅
- Off-main detection → `Task.detached` in `startASIAIRLive`. ✅
- Broad `*.<ext>` glob + accept-all prefix (ASIAIR correctness) → Task 2, documented. ✅
- ASIAIR-specific no-share message → Task 2. ✅
- Start ASIAIR button + verb-led rename of the other two → Task 2 Step 2. ✅
- Help.md label consistency + document the new source → Task 2 Step 4. ✅
- 8 detector tests → Task 1 Step 1. ✅
- Seestar Live / Watch Folder Live handlers unchanged (labels only) → Task 2 Step 2 (only Label/Button title strings change). ✅

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code; run steps show command + expected result. The one hardware-dependent manual step (Step 7) is explicitly marked as deferrable to real-ASIAIR time — not a placeholder, an honest environment note.

**3. Type consistency:** `ASIAIRDetector.Found` fields (`subDir`, `target`, `subExposure`, `subFileExtension`) are defined in Task 1 and consumed with those exact names in Task 2's `configureAndStartASIAIR`. `detect()` signature matches. `FrameRelay(source:destination:glob:)`, `startSession()`, and the AppModel properties used are all verified against the current Seestar/Watch-Folder implementations.
