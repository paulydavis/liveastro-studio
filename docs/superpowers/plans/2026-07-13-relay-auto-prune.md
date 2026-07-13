# Relay Auto-Prune Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically delete relay staging sessions older than a configurable window (default 7 days) whenever a new session starts, reclaiming the disk space that `~/LiveAstro/relay` currently accumulates forever.

**Architecture:** A pure `RelayPruner` (LiveAstroCore/Live) parses each relay folder's session date from its NAME (`<target>-YYYY-MM-DD[-<exp>s]`) and deletes immediate subdirectories strictly older than the cutoff — never the active/incoming dir, never unparseable names. `AppModel` calls it at the 3 relay-creation sites just before `relay.start()`, driven by a persisted `relayRetentionDays` setting (0 = Off, default 7) with a segmented picker in the Watch Folder section.

**Tech Stack:** Swift 5.10 SPM (LiveAstroCore: Foundation/CoreGraphics/Accelerate only), SwiftUI app.

## Global Constraints

- Swift 5.10, macOS 14+. LiveAstroCore imports Foundation / CoreGraphics / Accelerate only; zero external deps.
- Deletion ONLY under `~/LiveAstro/relay`, only name-dated immediate subdirectories, strictly older than the window (date granularity), never `excluding`.
- Date parsed from the folder NAME (last valid `YYYY-MM-DD` token), never from mtime. Unparseable name ⇒ never deleted.
- Default 7 days; 0 = Off (no-op); persisted with backward-compat decode `?? 7`.
- Best-effort, non-throwing; every removal logged with its size.
- Core logic TDD'd; app/UI build-verified.
- Branch: `feature/relay-auto-prune` off `main` @ 67da91b. Spec: `docs/superpowers/specs/2026-07-13-relay-auto-prune-design.md`.

---

## Task 1: `RelayPruner` (TDD)

**Files:**
- Create: `Sources/LiveAstroCore/Live/RelayPruner.swift`
- Test: `Tests/LiveAstroCoreTests/RelayPrunerTests.swift`

**Interfaces:**
- Consumes: Foundation only (`FileManager`, `Calendar`, `DateFormatter`).
- Produces: `RelayPruner.prune(root: URL, olderThanDays: Int, now: Date = Date(), excluding: URL? = nil) -> [RelayPruner.Removed]` and `RelayPruner.Removed { name: String; bytes: Int64 }`; internal `RelayPruner.sessionDate(fromName: String) -> Date?` (testable via `@testable`).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/LiveAstroCoreTests/RelayPrunerTests.swift
import XCTest
@testable import LiveAstroCore

final class RelayPrunerTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Make a relay-style session dir containing one small file (so bytes > 0).
    @discardableResult
    func makeSession(_ name: String) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1024).write(to: dir.appendingPathComponent("sub.fit"))
        return dir
    }

    func date(_ s: String) -> Date {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        df.calendar = Calendar.current; df.timeZone = Calendar.current.timeZone
        return df.date(from: s)!
    }

    // MARK: sessionDate parsing

    func testParsesPlainDate() {
        XCTAssertEqual(RelayPruner.sessionDate(fromName: "M 101-2026-07-09"), date("2026-07-09"))
    }
    func testParsesExposureSuffixedDate() {
        XCTAssertEqual(RelayPruner.sessionDate(fromName: "NGC 6960-2026-07-11-30.0s"), date("2026-07-11"))
    }
    func testTargetWithDigitsAndHyphensParsesLastDateToken() {
        // hostile-ish target name containing a date-shaped fragment earlier in the name
        XCTAssertEqual(RelayPruner.sessionDate(fromName: "Sh2-101-2026-07-09"), date("2026-07-09"))
    }
    func testInvalidCalendarDateIsNil() {
        XCTAssertNil(RelayPruner.sessionDate(fromName: "Target-2026-13-99"))
    }
    func testNoDateIsNil() {
        XCTAssertNil(RelayPruner.sessionDate(fromName: "random-folder"))
    }

    // MARK: prune semantics

    func testDeletesStrictlyOlderKeepsWindowAndToday() throws {
        try makeSession("Old-2026-07-01")            // 12 days before "now" → delete
        try makeSession("Edge-2026-07-06")           // exactly 7 days before → KEEP (strictly older only)
        try makeSession("Recent-2026-07-10")         // inside window → keep
        try makeSession("Today-2026-07-13")          // today → keep
        let removed = RelayPruner.prune(root: root, olderThanDays: 7, now: date("2026-07-13"))
        XCTAssertEqual(removed.map(\.name), ["Old-2026-07-01"])
        XCTAssertTrue(removed[0].bytes > 0)
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(left, ["Edge-2026-07-06", "Recent-2026-07-10", "Today-2026-07-13"])
    }

    func testExcludedDirSurvivesEvenIfOld() throws {
        let dir = try makeSession("Active-2026-01-01")
        let removed = RelayPruner.prune(root: root, olderThanDays: 7, now: date("2026-07-13"),
                                        excluding: dir)
        XCTAssertTrue(removed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    func testUnparseableNameSurvives() throws {
        try makeSession("my-precious-data")
        XCTAssertTrue(RelayPruner.prune(root: root, olderThanDays: 7, now: date("2026-07-13")).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("my-precious-data").path))
    }

    func testPlainFileAtRootUntouched() throws {
        let f = root.appendingPathComponent("stray-2026-01-01.txt")
        try Data("x".utf8).write(to: f)
        XCTAssertTrue(RelayPruner.prune(root: root, olderThanDays: 7, now: date("2026-07-13")).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }

    func testZeroOrNegativeDaysIsNoOp() throws {
        try makeSession("Old-2020-01-01")
        XCTAssertTrue(RelayPruner.prune(root: root, olderThanDays: 0, now: date("2026-07-13")).isEmpty)
        XCTAssertTrue(RelayPruner.prune(root: root, olderThanDays: -3, now: date("2026-07-13")).isEmpty)
    }

    func testMissingRootReturnsEmpty() {
        let ghost = root.appendingPathComponent("nope", isDirectory: true)
        XCTAssertTrue(RelayPruner.prune(root: ghost, olderThanDays: 7, now: date("2026-07-13")).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter RelayPrunerTests`
Expected: FAIL — `cannot find 'RelayPruner' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/LiveAstroCore/Live/RelayPruner.swift
import Foundation

/// Age-based cleanup of relay staging sessions (spec: relay auto-prune).
/// Relay dirs are named "<target>-YYYY-MM-DD[-<exp>s]" by the app; the session
/// date is parsed from the NAME (relaying touches mtimes, so mtime is unreliable).
/// Deletes only immediate, name-dated subdirectories of `root` that are STRICTLY
/// older than `now − olderThanDays` (date granularity). Anything unparseable, any
/// plain file, and the `excluding` dir (the active/incoming session) are never
/// touched. Best-effort and non-throwing; every removal is reported for logging.
public enum RelayPruner {
    public struct Removed: Equatable {
        public let name: String
        public let bytes: Int64
        public init(name: String, bytes: Int64) { self.name = name; self.bytes = bytes }
    }

    public static func prune(root: URL, olderThanDays: Int, now: Date = Date(),
                             excluding: URL? = nil) -> [Removed] {
        guard olderThanDays > 0 else { return [] }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else { return [] }
        let cal = Calendar.current
        guard let cutoff = cal.date(byAdding: .day, value: -olderThanDays,
                                    to: cal.startOfDay(for: now)) else { return [] }
        let excluded = excluding?.standardizedFileURL.path
        var removed: [Removed] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  entry.standardizedFileURL.path != excluded,
                  let session = sessionDate(fromName: entry.lastPathComponent),
                  session < cutoff else { continue }
            let bytes = directorySize(entry)
            do {
                try fm.removeItem(at: entry)
                removed.append(Removed(name: entry.lastPathComponent, bytes: bytes))
            } catch { continue }   // best-effort: a locked/undeletable dir is skipped
        }
        return removed
    }

    /// The YYYY-MM-DD session date embedded in a relay dir name, or nil.
    /// Takes the LAST date-shaped token (target names may contain digits/hyphens)
    /// and requires it to be a real calendar date.
    static func sessionDate(fromName name: String) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}"#) else { return nil }
        let range = NSRange(name.startIndex..., in: name)
        guard let match = regex.matches(in: name, range: range).last,
              let r = Range(match.range, in: name) else { return nil }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.calendar = Calendar.current
        df.timeZone = Calendar.current.timeZone
        df.isLenient = false
        return df.date(from: String(name[r]))
    }

    /// Recursive allocated size (for the log line); best-effort.
    private static func directorySize(_ dir: URL) -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return total
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter RelayPrunerTests`
Expected: PASS (11 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Live/RelayPruner.swift Tests/LiveAstroCoreTests/RelayPrunerTests.swift
git commit -m "feat: RelayPruner — age-based, name-dated relay session cleanup (TDD)"
```

---

## Task 2: Settings + AppModel wiring + UI picker

**Files:**
- Modify: `Sources/LiveAstroCore/Settings/SessionSettings.swift`
- Modify: `Sources/LiveAstroStudio/AppModel.swift` (3 relay sites ~lines 493, 537, 589 + settings plumbing)
- Modify: `Sources/LiveAstroStudio/ControlView.swift`
- Test: `Tests/LiveAstroCoreTests/SessionSettingsTests.swift`

**Interfaces:**
- Consumes: `RelayPruner.prune(root:olderThanDays:now:excluding:) -> [RelayPruner.Removed]` (Task 1); existing `helpToggle`/`InfoButton` UI patterns; `frameWeightingEnabled` settings pattern.
- Produces: `SessionSettings.relayRetentionDays: Int` (default 7, decode `?? 7`); `AppModel.relayRetentionDays`; `AppModel.pruneRelay(excluding:)` private helper; "Keep relay sessions" picker row.

- [ ] **Step 1: Write the failing settings tests**

Add to `Tests/LiveAstroCoreTests/SessionSettingsTests.swift`:

```swift
    func testRelayRetentionDefaultsSevenAndRoundTrips() throws {
        var s = SessionSettings()
        XCTAssertEqual(s.relayRetentionDays, 7)                       // default 7
        s.relayRetentionDays = 0                                       // Off
        let back = try JSONDecoder().decode(SessionSettings.self,
                                            from: JSONEncoder().encode(s))
        XCTAssertEqual(back.relayRetentionDays, 0)
    }

    func testRelayRetentionBackwardCompatDefaultsSeven() throws {
        // A blob written before this field existed must decode to 7. Reuse the same
        // minimal-valid JSON shape as testBackgroundNormalizationBackwardCompatDefaultsOn
        // (copy its JSON string and simply assert the new field).
        let json = try XCTUnwrap(backwardCompatJSONWithoutNewKeys())
        let s = try JSONDecoder().decode(SessionSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.relayRetentionDays, 7)
    }
```

(If the existing file has no shared `backwardCompatJSONWithoutNewKeys()` helper, inline the SAME JSON string used by `testBackgroundNormalizationBackwardCompatDefaultsOn` — read that test and reuse its literal, which already includes all required decode fields.)

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter SessionSettingsTests`
Expected: FAIL — `relayRetentionDays` not a member.

- [ ] **Step 3: Add the field to `SessionSettings`**

In `Sources/LiveAstroCore/Settings/SessionSettings.swift`, mirror `frameWeightingEnabled` at all touch points:
1. Stored property (near line 17): `public var relayRetentionDays: Int`
2. `init` param (near line 26): `relayRetentionDays: Int = 7,` + assignment `self.relayRetentionDays = relayRetentionDays`
3. `CodingKeys` (line ~47): add `relayRetentionDays`
4. `init(from:)` (line ~61): `relayRetentionDays = try c.decodeIfPresent(Int.self, forKey: .relayRetentionDays) ?? 7`
5. `.defaults` (line ~74): add `relayRetentionDays: 7,`

- [ ] **Step 4: Run to verify settings tests pass**

Run: `swift test --filter SessionSettingsTests`
Expected: PASS.

- [ ] **Step 5: Wire `AppModel`**

In `Sources/LiveAstroStudio/AppModel.swift`:
1. Property (near line 44): `var relayRetentionDays = 7`
2. `currentSettings()` builder (near line 165): add `relayRetentionDays: relayRetentionDays,`
3. `loadSettings` apply (near line 184): add `relayRetentionDays = s.relayRetentionDays`
4. Add a private helper (near the relay-configure methods):

```swift
    /// Age-prune old relay sessions just before a new one is created (spec:
    /// relay auto-prune). `relayDir` is the incoming session — never pruned.
    private func pruneRelay(excluding relayDir: URL) {
        let relayRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("LiveAstro/relay", isDirectory: true)
        for r in RelayPruner.prune(root: relayRoot, olderThanDays: relayRetentionDays,
                                   excluding: relayDir) {
            let size = ByteCountFormatter.string(fromByteCount: r.bytes, countStyle: .file)
            log.append("pruned relay \(r.name) (\(size))")
        }
    }
```

5. At EACH of the 3 relay-creation sites (the `let relay = FrameRelay(...)` lines at ~495, ~540, ~592), insert immediately BEFORE the `FrameRelay` construction:

```swift
        pruneRelay(excluding: relayDir)
```

(All three sites already have `relayDir` in scope at that point.)

- [ ] **Step 6: Add the UI picker**

In `Sources/LiveAstroStudio/ControlView.swift`, in the Watch Folder section directly after the "Match sky background" `helpToggle` row:

```swift
                        HStack(spacing: 6) {
                            Text("Keep relay sessions")
                            InfoButton(text: "Live sessions stage incoming subs in ~/LiveAstro/relay. Sessions older than this are deleted automatically when a new session starts — they are copies; originals stay on the Seestar/rig. Off disables pruning.")
                            Spacer()
                            Picker("", selection: $model.relayRetentionDays) {
                                Text("Off").tag(0)
                                Text("3d").tag(3)
                                Text("7d").tag(7)
                                Text("14d").tag(14)
                                Text("30d").tag(30)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: 300)
                            .disabled(model.isRunning || model.isImporting)
                        }
```

- [ ] **Step 7: Build + full suite**

Run: `swift build` then `swift build -c release`
Expected: both clean (pre-existing `#SendableClosureCaptures` warning in AppModel is unrelated).
Run: `swift test`
Expected: full suite green (0 failures).

- [ ] **Step 8: Commit**

```bash
git add Sources/LiveAstroCore/Settings/SessionSettings.swift Sources/LiveAstroStudio/AppModel.swift Sources/LiveAstroStudio/ControlView.swift Tests/LiveAstroCoreTests/SessionSettingsTests.swift
git commit -m "feat: 'Keep relay sessions' retention setting (default 7d) pruned at session start"
```

---

## After all tasks

Whole-branch review, then finish: merge to main + push + repackage dist (`swift build -c release --scratch-path /private/tmp/las-release-build`, `ditto` binary + `LiveAstroStudio_LiveAstroStudio.bundle` into `dist/LiveAstroStudio.app/Contents/MacOS/`, `xattr -cr`, `codesign --force --sign -` the executable, verify `--ignore-resources`). Manual verification afterward: start a session (or Seestar Live) and confirm the log shows the old NGC 6960/6692 relay sessions pruned (~18 GB freed).
