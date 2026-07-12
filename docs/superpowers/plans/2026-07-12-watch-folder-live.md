# Watch Folder Live (de-Seestar-ify) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A source-generic "Watch Folder Live" one-tap: pick any incoming-subs folder (ASIAIR / NINA / ASI camera) → session-scoped relay + native stacking, identical downstream to Seestar Live. Target/exposure read from the subs' FITS headers.

**Architecture:** Rename the already-generic `SeestarRelay` to `FrameRelay` (move out of `Seestar/`); add a Core `LiveSourceMetadata.newestFITSMetadata(inFolder:)` header reader; add `AppModel.startWatchFolderLive(source:)` that mirrors the Seestar path with a picked source folder + header-derived target/exposure; add a "Watch Folder Live" button. Seestar Live keeps working via `FrameRelay`.

**Tech Stack:** Swift 5.10, SwiftUI, XCTest. `LiveAstroCore` (Foundation) + `LiveAstroStudio` (`@Observable`).

## Global Constraints

- Swift 5.10, macOS 14+. `LiveAstroCore` Foundation only.
- Core tests: `swift test --filter LiveAstroCoreTests`; all existing tests stay green.
- TDD for T2 (header helper + broad-glob relay test). T1 (rename) is behavior-preserving — verified by the renamed tests staying green + a clean build. T3 (AppModel + ControlView) is MANUAL/BUILD-VERIFIED (SwiftUI + the real rig round-trip out of unit scope).
- The rename must be behavior-preserving: `FrameRelay` is `SeestarRelay` with no logic change. `SeestarDetector` is NOT renamed (it is genuinely Seestar-specific). Seestar Live must still work.
- ASIAIR auto-detect is OUT OF SCOPE (deferred). This build = pick-the-folder.
- `AppModel` is `@Observable` plain `var`.
- Branch `feature/watch-folder-live` (off main). Never commit to main.

---

### Task 1: Rename SeestarRelay → FrameRelay (behavior-preserving)

**Files:**
- Rename: `Sources/LiveAstroCore/Seestar/SeestarRelay.swift` → `Sources/LiveAstroCore/Live/FrameRelay.swift`
- Rename: `Tests/LiveAstroCoreTests/SeestarRelayTests.swift` → `Tests/LiveAstroCoreTests/FrameRelayTests.swift`
- Modify: `Sources/LiveAstroStudio/AppModel.swift` (references)

**Interfaces:**
- Produces: `public final class FrameRelay` with the identical API `init(source:destination:glob:pollSeconds:sessionScoped:)`, `start()`, `stop()`, `copyOnce()`, `snapshotBaseline()`, `wildcardMatch(_:_:)`, `onLog`, `relayedCount`. No behavior change.

- [ ] **Step 1: Move + rename the source file**

```bash
mkdir -p Sources/LiveAstroCore/Live
git mv Sources/LiveAstroCore/Seestar/SeestarRelay.swift Sources/LiveAstroCore/Live/FrameRelay.swift
```
In `Sources/LiveAstroCore/Live/FrameRelay.swift`, rename the type: `public final class SeestarRelay {` → `public final class FrameRelay {`. Update the doc comment's "Seestar `_sub` folder" wording to be source-generic (e.g. "a source folder of incoming subs"). The `DispatchQueue(label: "seestar.relay")` → `"frame.relay"`. No other change.

- [ ] **Step 2: Move + rename the test file**

```bash
git mv Tests/LiveAstroCoreTests/SeestarRelayTests.swift Tests/LiveAstroCoreTests/FrameRelayTests.swift
```
In it: `final class SeestarRelayTests` → `final class FrameRelayTests`, and every `SeestarRelay(` / `SeestarRelay.` → `FrameRelay(` / `FrameRelay.`. No test-logic change.

- [ ] **Step 3: Update AppModel references**

In `Sources/LiveAstroStudio/AppModel.swift`, rename all references (there are exactly these sites):
- `private var seestarRelay: SeestarRelay?` → `private var frameRelay: FrameRelay?`
- `self?.seestarRelay?.stop()` (in the willTerminate handler) → `self?.frameRelay?.stop()`
- `let relay = SeestarRelay(source: found.subDir, …)` → `let relay = FrameRelay(source: found.subDir, …)`
- `seestarRelay = relay` → `frameRelay = relay`
- `seestarRelay?.stop(); seestarRelay = nil` (both occurrences) → `frameRelay?.stop(); frameRelay = nil`

- [ ] **Step 4: Verify nothing else references the old names**

Run: `grep -rn "SeestarRelay\|seestarRelay" Sources Tests`
Expected: NO matches (all renamed). (`SeestarDetector` matches are fine — different type, not renamed.)

- [ ] **Step 5: Build + run the renamed tests + full suite**

Run: `swift build`
Expected: `Build complete!`
Run: `swift test --filter FrameRelayTests`
Expected: PASS (the same tests that were `SeestarRelayTests`).
Run: `swift test --filter LiveAstroCoreTests`
Expected: all green (behavior-preserving rename).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: rename SeestarRelay -> FrameRelay (source-generic; de-Seestar-ify)"
```

---

### Task 2: LiveSourceMetadata header reader + broad-glob relay test

**Files:**
- Create: `Sources/LiveAstroCore/Live/LiveSourceMetadata.swift`
- Test: `Tests/LiveAstroCoreTests/LiveSourceMetadataTests.swift`
- Modify: `Tests/LiveAstroCoreTests/FrameRelayTests.swift` (add a broad-FITS-glob case)

**Interfaces:**
- Consumes: `FITSReader.readHeader(_ data:) throws -> FITSHeader` (with `.keywords: [String:String]`), `SourceMetadata(fitsKeywords:)` (has `.object`, `.exposureSeconds`), `FITSWriter.float32(...metadata:)`, `FrameRelay` (T1).
- Produces: `LiveSourceMetadata.newestFITSMetadata(inFolder: URL) -> (object: String?, exposureSeconds: Double?, fileExtension: String)?` — `fileExtension` is the newest sub's lowercased extension (`"fit"` or `"fits"`), so the caller can build the matching relay glob (`*.fit` vs `*.fits`) without the single-pattern relay having to match both.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LiveAstroCoreTests/LiveSourceMetadataTests.swift`:
```swift
import XCTest
@testable import LiveAstroCore

final class LiveSourceMetadataTests: XCTestCase {
    func tmp() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
    }
    // Write a 1-channel FITS carrying OBJECT/EXPTIME headers via SourceMetadata.
    func writeFITS(_ dir: URL, _ name: String, object: String?, exposure: Double?) throws {
        var meta = SourceMetadata()
        meta.object = object
        meta.exposureSeconds = exposure
        let px = [Float](repeating: 0.1, count: 8 * 8)
        try FITSWriter.float32(width: 8, height: 8, channels: 1, pixels: px, metadata: meta)
            .write(to: dir.appendingPathComponent(name))
    }

    func testReadsNewestFITSObjectAndExposure() throws {
        let dir = try tmp()
        try writeFITS(dir, "a.fit", object: "OLD", exposure: 10)
        // ensure b is newer
        try writeFITS(dir, "b.fit", object: "NGC 6960", exposure: 30)
        try FileManager.default.setAttributes([.modificationDate: Date()],
            ofItemAtPath: dir.appendingPathComponent("b.fit").path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)],
            ofItemAtPath: dir.appendingPathComponent("a.fit").path)
        let m = LiveSourceMetadata.newestFITSMetadata(inFolder: dir)
        XCTAssertEqual(m?.object, "NGC 6960")
        XCTAssertEqual(m?.exposureSeconds, 30)
        XCTAssertEqual(m?.fileExtension, "fit")
    }

    func testNoFITSReturnsNil() throws {
        let dir = try tmp()
        try Data("not fits".utf8).write(to: dir.appendingPathComponent("readme.txt"))
        XCTAssertNil(LiveSourceMetadata.newestFITSMetadata(inFolder: dir))
    }

    func testHandlesFitsExtension() throws {
        let dir = try tmp()
        try writeFITS(dir, "x.fits", object: "M8", exposure: 20)   // .fits extension
        let m = LiveSourceMetadata.newestFITSMetadata(inFolder: dir)
        XCTAssertEqual(m?.object, "M8")
        XCTAssertEqual(m?.exposureSeconds, 20)
        XCTAssertEqual(m?.fileExtension, "fits")   // caller builds "*.fits" glob from this
    }
}
```

Add to `Tests/LiveAstroCoreTests/FrameRelayTests.swift` (reuse its `tmp()`/`write(_:_:)` helpers):
```swift
    func testBroadFitsGlobRelaysBothExtensionsSessionScoped() throws {
        let src = try tmp(), dst = try tmp()
        try write(src, "old.fit")                        // backlog
        let r = FrameRelay(source: src, destination: dst, glob: "*.fit")
        r.snapshotBaseline()                             // exclude backlog
        try write(src, "new1.fit")
        try write(src, "note.txt")                       // non-FITS ignored
        XCTAssertEqual(try r.copyOnce(), 1)              // only the new .fit
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("new1.fit").path))
    }
```
(If the relay's `wildcardMatch` cannot express "`.fit` OR `.fits`" in one glob, the implementer covers `.fits` in `startWatchFolderLive` by running the relay with the extension it detects, or extends the relay to accept a set of globs — decide in Step 3 and note it. The `LiveSourceMetadata` test already covers `.fits` reading.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LiveSourceMetadataTests`
Expected: compile failure — `cannot find 'LiveSourceMetadata' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/LiveAstroCore/Live/LiveSourceMetadata.swift`:
```swift
import Foundation

/// Reads target/exposure from a live source folder's newest FITS sub, so a
/// generic rig (ASIAIR / NINA / ASI camera) needs no filename convention.
public enum LiveSourceMetadata {
    /// The newest .fit/.fits in `folder`, parsed for OBJECT (target) and
    /// EXPTIME (exposure). nil if there is no readable FITS. Reads only a bounded
    /// header prefix, not the (potentially 50 MB) pixel data.
    public static func newestFITSMetadata(inFolder folder: URL)
        -> (object: String?, exposureSeconds: Double?, fileExtension: String)? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        let fits = items.filter { ["fit", "fits"].contains($0.pathExtension.lowercased()) }
        guard !fits.isEmpty else { return nil }
        let newest = fits.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return da < db
        }
        guard let url = newest else { return nil }
        let ext = url.pathExtension.lowercased()
        // Bounded header read: FITS headers are small 2880-byte blocks; 256 KB is
        // far more than any real header, so we avoid pulling the full sub.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        guard let header = try? FITSReader.readHeader(prefix) else { return nil }
        let meta = SourceMetadata(fitsKeywords: header.keywords)
        return (meta.object, meta.exposureSeconds, ext)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LiveSourceMetadataTests` then `swift test --filter FrameRelayTests`
Expected: PASS (3 metadata + the new broad-glob relay test + the existing relay tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Live/LiveSourceMetadata.swift Tests/LiveAstroCoreTests/LiveSourceMetadataTests.swift Tests/LiveAstroCoreTests/FrameRelayTests.swift
git commit -m "feat: LiveSourceMetadata newest-FITS header reader + broad-glob relay test"
```

---

### Task 3: AppModel.startWatchFolderLive + ControlView button

**Files:**
- Modify: `Sources/LiveAstroStudio/AppModel.swift`
- Modify: `Sources/LiveAstroStudio/ControlView.swift`

**Interfaces:**
- Consumes: `FrameRelay` (T1); `LiveSourceMetadata.newestFITSMetadata` (T2); the existing `configureAndStartSeestar` pattern, `sourceMode`, `neutralizeBackground`, `targetName`, `subExposureText`, `frameRelay`, `watchFolder`, `startSession()`, `isRunning`, `selectedTab`.
- Produces: `AppModel.startWatchFolderLive(source: URL)`; a "Watch Folder Live" button.

**Note:** No unit test — SwiftUI + the real rig round-trip are out of unit scope (per prior pillars). Verified by a clean RELEASE build (Step 3).

- [ ] **Step 1: Add startWatchFolderLive to AppModel**

In `Sources/LiveAstroStudio/AppModel.swift`, add (mirrors `startSeestarLive`/`configureAndStartSeestar`, but source-generic — reads headers off-main, then configures on main):
```swift
    func startWatchFolderLive(source: URL) {
        guard !isRunning, !isImporting, !isDetecting else { return }
        zoomPan = .fit
        isDetecting = true
        log.append("Reading subs in \(source.lastPathComponent)…")
        Task.detached { [weak self] in
            let meta = LiveSourceMetadata.newestFITSMetadata(inFolder: source)   // SMB header read, off main
            await MainActor.run {
                guard let self else { return }
                self.isDetecting = false
                self.configureAndStartWatchFolder(source: source, meta: meta)
            }
        }
    }

    private func configureAndStartWatchFolder(source: URL,
                                              meta: (object: String?, exposureSeconds: Double?, fileExtension: String)?) {
        sourceMode = .nativeStack
        neutralizeBackground = true
        if let object = meta?.object, !object.isEmpty { targetName = object }        // else keep form value
        if let exp = meta?.exposureSeconds, exp > 0 { subExposureText = String(format: "%g", exp) }
        let target = targetName.isEmpty ? "Live" : targetName
        let glob = "*.\(meta?.fileExtension ?? "fit")"       // *.fit or *.fits per the folder's subs
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let relayDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("LiveAstro/relay/\(target)-\(df.string(from: Date()))", isDirectory: true)
        let relay = FrameRelay(source: source, destination: relayDir, glob: glob)
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
The glob is built from the newest sub's actual extension (`*.fit` or `*.fits`), so the single-pattern relay matches whichever the rig writes. A folder mixing both extensions live is out of scope (documented in the spec).

- [ ] **Step 2: Add the "Watch Folder Live" button to ControlView**

In `Sources/LiveAstroStudio/ControlView.swift`, beside the existing "Seestar Live" button in the footer, add:
```swift
                Button("Watch Folder Live") { pickWatchFolderLive() }
                    .help("Live-stack subs from any folder your rig writes to (ASIAIR / NINA / ASI camera) — session-scoped from the moment you start.")
                    .disabled(model.isRunning || model.isImporting || model.isDetecting)
```
Add the picker helper (macOS `NSOpenPanel`, choose a directory), matching the existing `pickFolder()`/`pickImportFolder()` idiom in this file:
```swift
    private func pickWatchFolderLive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch"
        if panel.runModal() == .OK, let url = panel.url {
            model.startWatchFolderLive(source: url)
        }
    }
```

- [ ] **Step 3: Build debug + RELEASE**

Run: `swift build`
Expected: `Build complete!`
Run: `swift build -c release --scratch-path /private/tmp/las-release-build`
Expected: `Build complete!`

- [ ] **Step 4: Run the full Core suite (no regression)**

Run: `swift test --filter LiveAstroCoreTests`
Expected: all pass (T3 only changes the app target).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroStudio/AppModel.swift Sources/LiveAstroStudio/ControlView.swift
git commit -m "feat: Watch Folder Live one-tap (source-generic live stacking)"
```

---

## Notes for the implementer

- The rename (T1) must be pure — no behavior change; the renamed `FrameRelayTests` are the proof. Grep for `SeestarRelay`/`seestarRelay` after and confirm zero matches; `SeestarDetector` is NOT renamed.
- Target/exposure from headers are PREFILL only — they overwrite the form fields when present, but keep the form value when the header is absent (never blank out a user's entry).
- The relay dir is `~/LiveAstro/relay/<target>-<date>/` (no exposure token — generic sources may have uniform/unknown exposure).
- Session-scoping (baseline cutoff) is unchanged and applies to any folder — only subs written after the tap are relayed and stacked.
- Seestar Live must still work after the rename — it now constructs a `FrameRelay`.
