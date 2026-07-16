# Session-Scoped Seestar Live Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make "Seestar Live" stack only the frames captured after the tap (baseline-exclusion), and move Seestar detection off the main thread so tapping never beachballs on the SMB share.

**Architecture:** Three touch points. `SeestarRelay` gains a baseline set snapshotted at session start (on its own serial queue) and excludes those names in `copyOnce`, so the accumulated prior-night backlog is never relayed. `SeestarDetector` picks the newest fit by a parsed capture-timestamp token instead of statting every file. `AppModel.startSeestarLive` runs `detect()` inside `Task.detached` then hops back to `@MainActor` for the existing configure/start body.

**Tech Stack:** Swift 5.10, Swift Package Manager, XCTest. `LiveAstroCore` (UI-free, Foundation-only) + `LiveAstroStudio` (SwiftUI `@Observable`).

## Global Constraints

- Swift 5.10, macOS 14+.
- `LiveAstroCore` is Foundation-only (Foundation `FileManager`/`DispatchQueue` allowed; no other deps).
- Core tests run with `swift test --filter LiveAstroCoreTests`; all existing tests must keep passing.
- TDD for the two Core tasks (T1, T2). The AppModel async refactor (T3) is MANUAL/BUILD-VERIFIED in RELEASE — SwiftUI/`@MainActor`/window lifecycle is out of unit-test scope, matching the prior four pillars.
- `AppModel` is `@Observable` and declares observable state as plain `var` (NOT `@Published`).
- Cutoff semantics: "this session only" = frames that appear **after** the tap (baseline-exclusion, approach B). Never mutate the Seestar source folder.
- Branch `feature/session-scoped-seestar-live` (off main at 5d04130). Never commit to main.

---

### Task 1: SeestarRelay baseline-exclusion cutoff

**Files:**
- Modify: `Sources/LiveAstroCore/Seestar/SeestarRelay.swift`
- Test: `Tests/LiveAstroCoreTests/SeestarRelayTests.swift`

**Interfaces:**
- Consumes: existing `SeestarRelay(source:destination:glob:pollSeconds:)`, `wildcardMatch(_:_:)`, `copyOnce() -> Int`, `relayedCount`.
- Produces:
  - `SeestarRelay.init(source:destination:glob:pollSeconds:sessionScoped:)` — new trailing param `sessionScoped: Bool = true`.
  - `func snapshotBaseline()` — internal; lists `source`, stores the set of names matching `glob` into `baseline`. No-op when `sessionScoped == false`. On source-unreachable: log via `onLog` and leave `baseline` empty (fail-open).
  - `copyOnce()` now also skips any name in `baseline`.
  - Behavior contract: `baseline` is empty until `snapshotBaseline()` populates it, so a relay that never calls `snapshotBaseline()` copies everything (today's behavior — keeps existing tests green).

- [ ] **Step 1: Write the failing tests**

Add to `Tests/LiveAstroCoreTests/SeestarRelayTests.swift` (inside the class, reuse the existing `tmp()` and `write(_:_:bytes:)` helpers):

```swift
    func testSnapshotBaselineExcludesBacklog() throws {
        let src = try tmp(), dst = try tmp()
        // 3 backlog subs present at "tap" time
        try write(src, "Light_M 8_10.0s_LP_20260709-000001.fit")
        try write(src, "Light_M 8_10.0s_LP_20260709-000002.fit")
        try write(src, "Light_M 8_10.0s_LP_20260709-000003.fit")
        let r = SeestarRelay(source: src, destination: dst)   // sessionScoped defaults true
        r.snapshotBaseline()                                  // capture the 3 backlog names
        // 2 new subs arrive after the tap
        try write(src, "Light_M 8_10.0s_LP_20260711-010001.fit")
        try write(src, "Light_M 8_10.0s_LP_20260711-010002.fit")
        XCTAssertEqual(try r.copyOnce(), 2)                   // only the 2 new
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("Light_M 8_10.0s_LP_20260711-010001.fit").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.appendingPathComponent("Light_M 8_10.0s_LP_20260709-000001.fit").path))
    }

    func testSessionScopedFalseCopiesAll() throws {
        let src = try tmp(), dst = try tmp()
        try write(src, "Light_M 8_10.0s_LP_20260709-000001.fit")
        try write(src, "Light_M 8_10.0s_LP_20260709-000002.fit")
        let r = SeestarRelay(source: src, destination: dst, sessionScoped: false)
        r.snapshotBaseline()                                  // no-op when not session-scoped
        try write(src, "Light_M 8_10.0s_LP_20260711-010001.fit")
        XCTAssertEqual(try r.copyOnce(), 3)                   // baseline empty → copies all 3
    }

    func testBaselineStillHonorsGlob() throws {
        let src = try tmp(), dst = try tmp()
        try write(src, "Light_M 8_10.0s_LP_20260709-000001.fit")
        let r = SeestarRelay(source: src, destination: dst)
        r.snapshotBaseline()
        try write(src, "Light_M 8_20.0s_LP_20260711-010001.fit")   // new but wrong exposure
        try write(src, "Light_M 8_10.0s_LP_20260711-010002.fit")   // new and matches
        XCTAssertEqual(try r.copyOnce(), 1)                        // only the matching new one
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SeestarRelayTests`
Expected: compile failure — `value of type 'SeestarRelay' has no member 'snapshotBaseline'` (and `sessionScoped:` is an unknown argument).

- [ ] **Step 3: Implement the minimal change**

Edit `Sources/LiveAstroCore/Seestar/SeestarRelay.swift`:

Add the stored properties near the other lets (after `relayedCount`):
```swift
    private let sessionScoped: Bool
    private var baseline: Set<String> = []
```

Replace the initializer with (adds the trailing `sessionScoped` param):
```swift
    public init(source: URL, destination: URL,
                glob: String = "Light_*_10.0s_*.fit", pollSeconds: Double = 5,
                sessionScoped: Bool = true) {
        self.source = source; self.destination = destination
        self.glob = glob; self.pollSeconds = pollSeconds
        self.sessionScoped = sessionScoped
    }
```

Add the baseline snapshot method (place it just above `copyOnce()`):
```swift
    /// Snapshot the names already present in `source` (matching `glob`) so a
    /// session-scoped relay copies ONLY frames that appear afterward. No-op when
    /// `sessionScoped` is false. Source-unreachable → log + empty baseline
    /// (fail-open: relay rather than silently drop a whole session).
    func snapshotBaseline() {
        guard sessionScoped else { return }
        let fm = FileManager.default
        let names: [String]
        do { names = try fm.contentsOfDirectory(atPath: source.path) }
        catch { onLog?("source unreachable (baseline): \(source.path)"); baseline = []; return }
        baseline = Set(names.filter { Self.wildcardMatch($0, glob) })
    }
```

In `copyOnce()`, add the baseline skip inside the loop, right after the existing dest-exists skip:
```swift
        for name in names.sorted() where Self.wildcardMatch(name, glob) {
            if baseline.contains(name) { continue }
            let dst = destination.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) { continue }
            // ... unchanged stage-copy body ...
        }
```

In `start()`, snapshot the baseline on the serial `queue` BEFORE resuming the timer, so the SMB listing runs off the main thread and is guaranteed (serial queue) to complete before the first `copyOnce()`:
```swift
    public func start() throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        queue.async { [weak self] in self?.snapshotBaseline() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: pollSeconds)
        t.setEventHandler { [weak self] in _ = try? self?.copyOnce() }
        timer = t; t.resume()
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SeestarRelayTests`
Expected: PASS — the 3 new tests plus the 2 existing (`testCopyOnceCopiesNewMatchingSkipsRest`, `testCopyOnceSkipsAlreadyPresent`) and `testWildcardMatch`. The existing tests never call `snapshotBaseline()`, so their baseline is empty and behavior is unchanged.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Seestar/SeestarRelay.swift Tests/LiveAstroCoreTests/SeestarRelayTests.swift
git commit -m "feat: session-scoped SeestarRelay baseline exclusion"
```

---

### Task 2: SeestarDetector no-stat newest-fit via capture-timestamp token

**Files:**
- Modify: `Sources/LiveAstroCore/Seestar/SeestarDetector.swift`
- Test: `Tests/LiveAstroCoreTests/SeestarDetectorTests.swift`

**Interfaces:**
- Consumes: existing `detect(volumesRoot:) -> Found?`, `parseExposure(fromFilename:) -> Double?`, `Found`.
- Produces:
  - `static func parseCaptureTimestamp(fromFilename name: String) -> String?` — returns the trailing `YYYYMMDD-HHMMSS` token (e.g. `"20260711-013530"`), or nil.
  - `detect(...)` picks the newest fit by `max` over `parseCaptureTimestamp` (nil token treated as `""`, sorts lowest), **no per-file `contentModificationDate` stat**. Exposure parsed from that one name.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/LiveAstroCoreTests/SeestarDetectorTests.swift` (reuse the existing `tmp()` helper):

```swift
    func testParseCaptureTimestamp() {
        XCTAssertEqual(
            SeestarDetector.parseCaptureTimestamp(fromFilename: "Light_NGC 6960_30.0s_LP_20260711-013530.fit"),
            "20260711-013530")
        XCTAssertNil(SeestarDetector.parseCaptureTimestamp(fromFilename: "Light_M 8_10.0s_LP_1.fit"))
        XCTAssertNil(SeestarDetector.parseCaptureTimestamp(fromFilename: "nope.fit"))
    }

    func testDetectPicksExposureOfNewestByTimestampToken() throws {
        let vols = try tmp()
        let works = vols.appendingPathComponent("EMMC Images/MyWorks")
        try FileManager.default.createDirectory(at: works, withIntermediateDirectories: true)
        let sub = works.appendingPathComponent("NGC 6960_sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        // Older capture at 30s, NEWER capture at 20s. Full-name sort would wrongly
        // pick "30.0s" (since '3' > '2'); token sort must pick the newer 20s file.
        try Data(count: 8).write(to: sub.appendingPathComponent("Light_NGC 6960_30.0s_LP_20260710-220000.fit"))
        try Data(count: 8).write(to: sub.appendingPathComponent("Light_NGC 6960_20.0s_LP_20260711-010000.fit"))
        let found = SeestarDetector.detect(volumesRoot: vols)
        XCTAssertEqual(found?.target, "NGC 6960")
        XCTAssertEqual(found?.subExposure, 20.0)   // newest by capture-timestamp token
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SeestarDetectorTests`
Expected: compile failure — `type 'SeestarDetector' has no member 'parseCaptureTimestamp'`.

- [ ] **Step 3: Implement the minimal change**

Edit `Sources/LiveAstroCore/Seestar/SeestarDetector.swift`.

Add the token parser (place near `parseExposure`):
```swift
    /// Extract the sortable capture stamp "YYYYMMDD-HHMMSS" from a Seestar
    /// filename like "Light_NGC 6960_30.0s_LP_20260711-013530.fit". nil if absent.
    /// The token sorts chronologically as a plain string.
    public static func parseCaptureTimestamp(fromFilename name: String) -> String? {
        let base = (name as NSString).deletingPathExtension
        for token in base.split(separator: "_") {
            let t = String(token)
            // 8 digits, '-', 6 digits
            let parts = t.split(separator: "-")
            if parts.count == 2, parts[0].count == 8, parts[1].count == 6,
               parts[0].allSatisfy(\.isNumber), parts[1].allSatisfy(\.isNumber) {
                return t
            }
        }
        return nil
    }
```

Replace the newest-fit selection block in `detect(...)` (the part that stats each fit for `contentModificationDate`) with a token sort. The current block is:
```swift
        let fits = ((try? fm.contentsOfDirectory(at: best.url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension.lowercased() == "fit" }
        let newest = fits.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return da < db
        }
        return Found(subDir: best.url, target: target,
                     subExposure: newest.map { $0.lastPathComponent }.flatMap(parseExposure(fromFilename:)))
```
Replace with (names only — no stat; nil token sorts lowest so a single non-timestamped file is still selected):
```swift
        let fitNames = ((try? fm.contentsOfDirectory(atPath: best.url.path)) ?? [])
            .filter { ($0 as NSString).pathExtension.lowercased() == "fit" }
        let newestName = fitNames.max { a, b in
            (parseCaptureTimestamp(fromFilename: a) ?? "") < (parseCaptureTimestamp(fromFilename: b) ?? "")
        }
        return Found(subDir: best.url, target: target,
                     subExposure: newestName.flatMap(parseExposure(fromFilename:)))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SeestarDetectorTests`
Expected: PASS — the 2 new tests plus the existing three (`testParseExposure`, `testDetectPicksNewestSubFolder`, `testDetectReturnsNilWhenNoSub`). Note `testDetectPicksNewestSubFolder` uses a file whose trailing token is `"1"` (nil timestamp); with a single fit, `max` still returns it → exposure 10.0, so that test stays green.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Seestar/SeestarDetector.swift Tests/LiveAstroCoreTests/SeestarDetectorTests.swift
git commit -m "feat: SeestarDetector newest-fit by capture-timestamp token (no per-file stat)"
```

---

### Task 3: AppModel startSeestarLive off-main + isDetecting

**Files:**
- Modify: `Sources/LiveAstroStudio/AppModel.swift` (`startSeestarLive()` ~line 427; add `isDetecting` near the other observable `var`s ~line 40)

**Interfaces:**
- Consumes: `SeestarDetector.detect() -> Found?`; `SeestarRelay(source:destination:glob:pollSeconds:sessionScoped:)` (T1); the existing `startSession()`, `saveSettings()`, `seestarRelay`, `watchFolder`, `isRunning`, `isImporting`, `errorMessage`, `selectedTab`.
- Produces: `var isDetecting = false` (observable); `startSeestarLive()` runs detection off-main; private `configureAndStartSeestar(_ found: SeestarDetector.Found)` holds the existing on-main configure/start body.

**Note:** No unit test — SwiftUI `@Observable`/`@MainActor`/window lifecycle is out of unit-test scope (same convention as the prior four pillars). Verified by a clean RELEASE build in Step 4.

- [ ] **Step 1: Add the `isDetecting` observable flag**

In `Sources/LiveAstroStudio/AppModel.swift`, near the other state `var`s (e.g. just after `var neutralizeBackground = false` around line 39), add:
```swift
    var isDetecting = false
```

- [ ] **Step 2: Refactor `startSeestarLive()` to run detection off the main thread**

Replace the existing `startSeestarLive()` method (the whole method from `func startSeestarLive() {` through its closing `}`) with:

```swift
    func startSeestarLive() {
        guard !isRunning, !isImporting, !isDetecting else { return }
        isDetecting = true
        log.append("Looking for Seestar share…")
        Task.detached { [weak self] in
            let found = SeestarDetector.detect()      // SMB directory work, off the main thread
            await MainActor.run {
                guard let self else { return }
                self.isDetecting = false
                guard let found else {
                    self.errorMessage = "No Seestar share found. Mount it first: Finder → Go → Connect to Server → the Seestar's smb:// address, then try again."
                    return
                }
                self.configureAndStartSeestar(found)
            }
        }
    }

    /// The on-main configure + start body (unchanged from the old synchronous
    /// startSeestarLive, from `found` onward). Runs on the main actor.
    private func configureAndStartSeestar(_ found: SeestarDetector.Found) {
        sourceMode = .nativeStack
        fileNamePrefix = "Light_"
        neutralizeBackground = true
        targetName = found.target
        let exp = found.subExposure
        subExposureText = String(format: "%g", exp ?? 10)
        let expToken = exp.map { String(format: "%.1f", $0) }
        let glob = expToken.map { "Light_*_\($0)s_*.fit" } ?? "Light_*.fit"
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let relayDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("LiveAstro/relay/\(found.target)-\(df.string(from: Date()))\(expToken.map { "-\($0)s" } ?? "")",
                                    isDirectory: true)
        let relay = SeestarRelay(source: found.subDir, destination: relayDir, glob: glob)
        relay.onLog = { [weak self] msg in
            Task { @MainActor in self?.log.append(msg) }
        }
        do { try relay.start() } catch { errorMessage = "Relay failed to start: \(error)"; return }
        seestarRelay = relay
        watchFolder = relayDir
        saveSettings()
        startSession()
        if !isRunning {
            seestarRelay?.stop(); seestarRelay = nil
            return
        }
        selectedTab = .live
    }
```

(The `SeestarRelay(...)` call uses the default `sessionScoped: true`, which activates the T1 baseline cutoff.)

- [ ] **Step 3: Build debug to verify it compiles**

Run: `swift build`
Expected: `Build complete!` with no errors.

- [ ] **Step 4: Build RELEASE to confirm the shippable build**

Run: `swift build -c release --scratch-path /private/tmp/las-release-build`
Expected: `Build complete!` (the `.build` dir on the iCloud Desktop throws a build.db disk-I/O error; the local scratch path avoids it).

- [ ] **Step 5: Run the full Core test suite (nothing regressed)**

Run: `swift test --filter LiveAstroCoreTests`
Expected: all tests pass (no Core behavior changed by T3; this confirms T1+T2 still green together).

- [ ] **Step 6: Commit**

```bash
git add Sources/LiveAstroStudio/AppModel.swift
git commit -m "feat: startSeestarLive detects off-main + isDetecting; session-scoped relay"
```

---

## Notes for the implementer

- Do NOT change `wildcardMatch`, the stage-copy body, `retry next poll`, or `relayedCount` in `SeestarRelay` — only add the baseline field, `snapshotBaseline()`, the one skip line, and the `start()` snapshot enqueue.
- Do NOT reintroduce per-file `contentModificationDate` stats in `SeestarDetector.detect` for the fit selection — the whole point of T2 is name-only selection. Folder selection (which `_sub`) still uses the `_sub` directories' mod-dates; leave that alone.
- Keep all `AppModel` state mutation inside `await MainActor.run` / on the main actor. Only `SeestarDetector.detect()` runs in `Task.detached`.
- After all three tasks: a RELEASE `.app` repackage for a live test is a manual step Paul drives (not part of this plan).
