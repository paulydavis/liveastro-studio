# Per-Sub Stats, User Rejection & Settings De-Clutter — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retain and display the per-sub quality signal the pipeline already computes, let the operator flag bad subs and rebuild the master via a re-stack, and split the single Setup panel into sub-tabs.

**Architecture:** A new `SubFrameRecord` captures the `(starCount, backgroundSigma, weight, outcome)` the stacker computes per sub (surfaced via a new `StackEngine.processDetailed` seam and a `SessionPipeline.onSubFrame` hook), persisted in the session manifest and a new CSV. Flagging sets a mutable `rejectedByUser` flag; a `RestackCoordinator` rebuilds the master by re-running the existing offline-import pipeline over the raw subs minus the flagged set. `ControlView`'s one `Form` becomes an inner `TabView` (Capture/Display/Stats/Broadcast/Diagnostics) with the new `StatsView` living in the Stats tab.

**Tech Stack:** Swift 5.10, Swift Package Manager, SwiftUI (macOS 14+), XCTest.

## Global Constraints

- Build: `swift build`; test: `swift test --scratch-path .build/test` (one at a time; full suite green before any merge).
- Swift 5.10 concurrency: warnings, not errors. Existing lock-free batch contract in `StackEngine` must not be broken.
- Backward compatibility: new `SessionManifest` fields MUST be `Optional` with a `= nil` default so legacy manifests decode unchanged (follow the existing `masterOutcome`/`stackFrameCount` pattern using synthesized `Codable` `decodeIfPresent`).
- Commit trailer on every commit (no `Co-Authored-By`):
  `Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j`
- Branch: `feature/sub-stats-rejection-settings` (already created; spec committed at `cd2eb73`). Never commit to `main`.
- Reject model: flagging NEVER mutates the running stack. Re-stack is a deliberate action that rebuilds from raw.
- v1 metrics only: star count, background σ, frame weight, outcome. No FWHM/HFR (no shape detector exists).
- Write commit messages to a file and use `git commit -F` (backticks in `-m` trigger shell substitution).

---

### Task 1: `SubFrameRecord` type

**Files:**
- Create: `Sources/LiveAstroCore/Session/SubFrameRecord.swift`
- Test: `Tests/LiveAstroCoreTests/SubFrameRecordTests.swift`

**Interfaces:**
- Consumes: nothing (leaf type).
- Produces: `SubFrameOutcome` (enum: `.reference`, `.stacked`, `.rejected`), `SubFrameRecord` struct with fields `index: Int, timestamp: Date, sourceFile: String, starCount: Int, backgroundSigma: Float, weight: Float, outcome: SubFrameOutcome, rejectionReason: String?, rejectedByUser: Bool`, and `public init(...)`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class SubFrameRecordTests: XCTestCase {
    func testCodableRoundTripPreservesAllFields() throws {
        let r = SubFrameRecord(index: 7, timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                               sourceFile: "Light_007.fit", starCount: 212, backgroundSigma: 1.83,
                               weight: 1.94, outcome: .stacked, rejectionReason: nil, rejectedByUser: false)
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(SubFrameRecord.self, from: data)
        XCTAssertEqual(back, r)
    }

    func testRejectedRecordCarriesReason() throws {
        let r = SubFrameRecord(index: 3, timestamp: Date(timeIntervalSince1970: 0),
                               sourceFile: "Light_003.fit", starCount: 2, backgroundSigma: 4.1,
                               weight: 0, outcome: .rejected, rejectionReason: "insufficientStars(found: 2)",
                               rejectedByUser: false)
        let back = try JSONDecoder().decode(SubFrameRecord.self, from: try JSONEncoder().encode(r))
        XCTAssertEqual(back.outcome, .rejected)
        XCTAssertEqual(back.rejectionReason, "insufficientStars(found: 2)")
    }

    func testRejectedByUserIsMutable() {
        var r = SubFrameRecord(index: 1, timestamp: Date(timeIntervalSince1970: 0),
                               sourceFile: "a.fit", starCount: 100, backgroundSigma: 1.0,
                               weight: 1.0, outcome: .stacked, rejectionReason: nil, rejectedByUser: false)
        r.rejectedByUser = true
        XCTAssertTrue(r.rejectedByUser)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --scratch-path .build/test --filter SubFrameRecordTests`
Expected: FAIL — "cannot find 'SubFrameRecord' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Where a sub ended up in the stack (spec §Data model).
public enum SubFrameOutcome: String, Codable, Equatable {
    case reference   // became the stack reference (seed)
    case stacked     // accepted and accumulated
    case rejected    // rejected at intake (registration failure)
}

/// A per-sub quality record retained for the session. The measured metrics
/// (`starCount`, `backgroundSigma`, `weight`, `outcome`) are computed once by the
/// stacker and never rewritten; `rejectedByUser` is the operator's flag and the
/// only mutable field. Drives the Stats view and re-stack exclusion.
public struct SubFrameRecord: Codable, Equatable {
    public let index: Int
    public let timestamp: Date
    public let sourceFile: String
    public let starCount: Int
    public let backgroundSigma: Float
    public let weight: Float
    public let outcome: SubFrameOutcome
    public let rejectionReason: String?
    public var rejectedByUser: Bool

    public init(index: Int, timestamp: Date, sourceFile: String, starCount: Int,
                backgroundSigma: Float, weight: Float, outcome: SubFrameOutcome,
                rejectionReason: String?, rejectedByUser: Bool) {
        self.index = index; self.timestamp = timestamp; self.sourceFile = sourceFile
        self.starCount = starCount; self.backgroundSigma = backgroundSigma
        self.weight = weight; self.outcome = outcome
        self.rejectionReason = rejectionReason; self.rejectedByUser = rejectedByUser
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --scratch-path .build/test --filter SubFrameRecordTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Session/SubFrameRecord.swift Tests/LiveAstroCoreTests/SubFrameRecordTests.swift
git commit -F /tmp/las-commit.txt   # message: "feat(core): SubFrameRecord per-sub quality record"
```

---

### Task 2: `SessionManifest.subFrames` field (backward-compatible)

**Files:**
- Modify: `Sources/LiveAstroCore/Session/SessionModels.swift` (add field to `SessionManifest`, ~line 100 region)
- Test: `Tests/LiveAstroCoreTests/SessionManifestSubFramesTests.swift`

**Interfaces:**
- Consumes: `SubFrameRecord` (Task 1).
- Produces: `SessionManifest.subFrames: [SubFrameRecord]?` (default `nil`, `public internal(set)`).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class SessionManifestSubFramesTests: XCTestCase {
    private func manifest() -> SessionManifest {
        SessionManifest(sessionId: "s1", targetName: "M63", startTime: Date(timeIntervalSince1970: 0),
                        endTime: nil, subExposureSeconds: 20, bortle: 4, locationLabel: "yard",
                        telescope: "Askar120", camera: "2600MC", mount: "AM5N", filter: "none",
                        notes: "", snapshots: [], masterExpected: true)
    }

    func testSubFramesRoundTrip() throws {
        var m = manifest()
        m.subFrames = [SubFrameRecord(index: 1, timestamp: Date(timeIntervalSince1970: 10),
                                      sourceFile: "a.fit", starCount: 100, backgroundSigma: 1.0,
                                      weight: 1.0, outcome: .reference, rejectionReason: nil,
                                      rejectedByUser: false)]
        let back = try JSONDecoder().decode(SessionManifest.self, from: try JSONEncoder().encode(m))
        XCTAssertEqual(back.subFrames?.count, 1)
        XCTAssertEqual(back.subFrames?.first?.outcome, .reference)
    }

    func testLegacyManifestWithoutSubFramesDecodesToNil() throws {
        // A manifest JSON that predates the field must decode with subFrames == nil.
        let m = manifest()
        var json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(m)) as! [String: Any]
        json.removeValue(forKey: "subFrames")
        let data = try JSONSerialization.data(withJSONObject: json)
        let back = try JSONDecoder().decode(SessionManifest.self, from: data)
        XCTAssertNil(back.subFrames)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --scratch-path .build/test --filter SessionManifestSubFramesTests`
Expected: FAIL — "value of type 'SessionManifest' has no member 'subFrames'".

- [ ] **Step 3: Add the field**

In `SessionModels.swift`, inside `struct SessionManifest`, directly after the existing
`public internal(set) var sessionRejectedCount: Int? = nil` line, add:

```swift
    /// Per-sub quality records (spec §Data model). Optional for backward compatibility:
    /// legacy manifests decode with this absent (nil — synthesized Codable uses
    /// decodeIfPresent). Written incrementally during a live session and at finalize.
    public internal(set) var subFrames: [SubFrameRecord]? = nil
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --scratch-path .build/test --filter SessionManifestSubFramesTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Session/SessionModels.swift Tests/LiveAstroCoreTests/SessionManifestSubFramesTests.swift
git commit -F /tmp/las-commit.txt   # "feat(core): persist subFrames in SessionManifest (backward-compatible)"
```

---

### Task 3: `SessionManager` append + flag API

**Files:**
- Modify: `Sources/LiveAstroCore/Session/SessionManager.swift` (add two methods near `recordSnapshot`, line 90)
- Test: `Tests/LiveAstroCoreTests/SessionManagerSubFrameTests.swift`

**Interfaces:**
- Consumes: `SubFrameRecord` (Task 1), `SessionManifest.subFrames` (Task 2).
- Produces:
  - `func recordSubFrame(_ record: SubFrameRecord) throws` — appends to `manifest.subFrames`, persists.
  - `func setSubFrameUserRejected(index: Int, rejected: Bool) throws` — sets `rejectedByUser` on the record with matching `index`; no-op if not found; persists.
  - `var subFrames: [SubFrameRecord]` — convenience read (`manifest?.subFrames ?? []`).

Note: `recordSnapshot` (line 90) already shows the persist pattern — build a `proposed` copy of the manifest, mutate it, assign back, and call the same writer. Mirror it exactly.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class SessionManagerSubFrameTests: XCTestCase {
    private func startedManager() throws -> (SessionManager, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mgr = SessionManager(rootDirectory: dir)
        _ = try mgr.startSession(profile: SessionProfile(targetName: "M63", subExposureSeconds: 20),
                                 masterExpected: true)
        return (mgr, dir)
    }

    private func rec(_ i: Int, rejected: Bool = false) -> SubFrameRecord {
        SubFrameRecord(index: i, timestamp: Date(timeIntervalSince1970: Double(i)),
                       sourceFile: "Light_\(i).fit", starCount: 100 + i, backgroundSigma: 1.5,
                       weight: 1.0, outcome: .stacked, rejectionReason: nil, rejectedByUser: rejected)
    }

    func testRecordSubFrameAppends() throws {
        let (mgr, _) = try startedManager()
        try mgr.recordSubFrame(rec(1))
        try mgr.recordSubFrame(rec(2))
        XCTAssertEqual(mgr.subFrames.map(\.index), [1, 2])
    }

    func testSetUserRejectedFlipsFlag() throws {
        let (mgr, _) = try startedManager()
        try mgr.recordSubFrame(rec(1))
        try mgr.setSubFrameUserRejected(index: 1, rejected: true)
        XCTAssertTrue(mgr.subFrames.first!.rejectedByUser)
        try mgr.setSubFrameUserRejected(index: 1, rejected: false)
        XCTAssertFalse(mgr.subFrames.first!.rejectedByUser)
    }

    func testSetUserRejectedUnknownIndexIsNoOp() throws {
        let (mgr, _) = try startedManager()
        try mgr.recordSubFrame(rec(1))
        try mgr.setSubFrameUserRejected(index: 999, rejected: true)   // must not throw
        XCTAssertFalse(mgr.subFrames.first!.rejectedByUser)
    }

    func testSubFramesPersistAcrossReload() throws {
        let (mgr, dir) = try startedManager()
        try mgr.recordSubFrame(rec(1, rejected: true))
        let data = try Data(contentsOf: dir.appendingPathComponent(mgr.manifest!.sessionId)
            .appendingPathComponent("session.json"))
        let reloaded = try JSONDecoder().decode(SessionManifest.self, from: data)
        XCTAssertEqual(reloaded.subFrames?.first?.rejectedByUser, true)
    }
}
```

Note for the implementer: confirm the on-disk manifest filename/path by reading `startSession` (line 59-82) — use whatever path it writes (adjust the `testSubFramesPersistAcrossReload` path to match; the other three tests do not depend on it).

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --scratch-path .build/test --filter SessionManagerSubFrameTests`
Expected: FAIL — "value of type 'SessionManager' has no member 'recordSubFrame'".

- [ ] **Step 3: Implement the API**

Add to `SessionManager` (mirror `recordSnapshot`'s persist mechanics — read the existing method first for the exact writer call and error type):

```swift
    public var subFrames: [SubFrameRecord] { manifest?.subFrames ?? [] }

    /// Append a per-sub record and persist. Mirrors recordSnapshot's persist path.
    public func recordSubFrame(_ record: SubFrameRecord) throws {
        guard var proposed = manifest else { throw SessionError.notStarted }
        var subs = proposed.subFrames ?? []
        subs.append(record)
        proposed.subFrames = subs
        try persist(proposed)          // use the SAME persist helper recordSnapshot uses
        manifest = proposed
    }

    /// Set the operator reject flag on the record with `index`. No-op if absent. Persists.
    public func setSubFrameUserRejected(index: Int, rejected: Bool) throws {
        guard var proposed = manifest, var subs = proposed.subFrames else { return }
        guard let i = subs.firstIndex(where: { $0.index == index }) else { return }
        subs[i].rejectedByUser = rejected
        proposed.subFrames = subs
        try persist(proposed)
        manifest = proposed
    }
```

If `recordSnapshot` inlines its persist (no `persist` helper) rather than calling a shared method, inline the identical write here (build `Data` via the manifest encoder and call `manifestWriter`), and use whatever error `recordSnapshot` throws when the manifest is missing (shown in that method) instead of `SessionError.notStarted`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --scratch-path .build/test --filter SessionManagerSubFrameTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Session/SessionManager.swift Tests/LiveAstroCoreTests/SessionManagerSubFrameTests.swift
git commit -F /tmp/las-commit.txt   # "feat(core): SessionManager record/flag sub-frames"
```

---

### Task 4: `SubFrameCSV` writer

**Files:**
- Create: `Sources/LiveAstroCore/Session/SubFrameCSV.swift`
- Test: `Tests/LiveAstroCoreTests/SubFrameCSVTests.swift`

**Interfaces:**
- Consumes: `SubFrameRecord` (Task 1).
- Produces: `enum SubFrameCSV { static func string(from records: [SubFrameRecord]) -> String }`.

Read `Sources/LiveAstroCore/Session/SessionFrameCSV.swift` first for the project's CSV idiom (delimiter, quoting, date formatting) and mirror it. The columns are:
`index,timestamp,source_file,star_count,background_sigma,weight,outcome,rejection_reason,rejected_by_user`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class SubFrameCSVTests: XCTestCase {
    func testEmptyRecordsYieldsHeaderOnly() {
        let csv = SubFrameCSV.string(from: [])
        XCTAssertEqual(csv, "index,timestamp,source_file,star_count,background_sigma,weight,outcome,rejection_reason,rejected_by_user\n")
    }

    func testRowFormatting() {
        let r = SubFrameRecord(index: 5, timestamp: Date(timeIntervalSince1970: 0),
                               sourceFile: "Light_005.fit", starCount: 180, backgroundSigma: 1.5,
                               weight: 1.25, outcome: .stacked, rejectionReason: nil, rejectedByUser: true)
        let csv = SubFrameCSV.string(from: [r])
        let row = csv.split(separator: "\n").last!
        XCTAssertTrue(row.hasPrefix("5,"))
        XCTAssertTrue(row.contains("Light_005.fit"))
        XCTAssertTrue(row.contains("180"))
        XCTAssertTrue(row.contains("stacked"))
        XCTAssertTrue(row.hasSuffix("true"))
    }

    func testCommaInReasonIsQuoted() {
        let r = SubFrameRecord(index: 1, timestamp: Date(timeIntervalSince1970: 0),
                               sourceFile: "a.fit", starCount: 2, backgroundSigma: 4.0, weight: 0,
                               outcome: .rejected, rejectionReason: "insufficientStars, found 2",
                               rejectedByUser: false)
        let row = SubFrameCSV.string(from: [r]).split(separator: "\n").last!
        XCTAssertTrue(row.contains("\"insufficientStars, found 2\""))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --scratch-path .build/test --filter SubFrameCSVTests`
Expected: FAIL — "cannot find 'SubFrameCSV' in scope".

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Serializes per-sub quality records to CSV (spec §Persistence & outputs).
/// Companion to SessionFrameCSV; same quoting rule (a field containing a comma,
/// quote, or newline is wrapped in double quotes with internal quotes doubled).
public enum SubFrameCSV {
    static let header = "index,timestamp,source_file,star_count,background_sigma,weight,outcome,rejection_reason,rejected_by_user"

    public static func string(from records: [SubFrameRecord]) -> String {
        var out = header + "\n"
        let iso = ISO8601DateFormatter()
        for r in records {
            let cols = [
                String(r.index),
                iso.string(from: r.timestamp),
                r.sourceFile,
                String(r.starCount),
                String(r.backgroundSigma),
                String(r.weight),
                r.outcome.rawValue,
                r.rejectionReason ?? "",
                r.rejectedByUser ? "true" : "false",
            ].map(escape)
            out += cols.joined(separator: ",") + "\n"
        }
        return out
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
```

If `SessionFrameCSV` uses a shared date format other than ISO8601, use that same formatter here instead so the two CSVs agree.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --scratch-path .build/test --filter SubFrameCSVTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Session/SubFrameCSV.swift Tests/LiveAstroCoreTests/SubFrameCSVTests.swift
git commit -F /tmp/las-commit.txt   # "feat(core): SubFrameCSV writer"
```

---

### Task 5: `StackEngine.processDetailed` seam

**Files:**
- Modify: `Sources/LiveAstroCore/Stacking/StackEngine.swift` (`process`, `processLocked`)
- Test: `Tests/LiveAstroCoreTests/StackEngineProcessDetailedTests.swift`

**Interfaces:**
- Consumes: `StackOutcome`, `RawFrame` (existing).
- Produces:
  - `public struct ProcessResult { public let outcome: StackOutcome; public let starCount: Int; public let backgroundSigma: Float; public let weight: Float }`
  - `public func processDetailed(_ frame: RawFrame) -> ProcessResult`
  - `process(_:)` unchanged externally: `public func process(_ frame: RawFrame) -> StackOutcome { processDetailed(frame).outcome }`

Rationale: the native path computes `(stars, sigma)` and the applied weight inside `processLocked` and discards them. This seam surfaces them without changing `StackOutcome` (which is `Equatable` and used widely). Read `processLocked` fully first — it already has `stars.count`, `sigma`, and calls `frameWeight(...)` (or computes the applied weight) internally; thread those three values out into `ProcessResult`. For `.becameReference` the weight is `1.0`; for `.rejected` the weight is `0` and `starCount`/`backgroundSigma` are whatever was measured before rejection (use `0`/`0` only if rejection happened before detection, e.g. dimension mismatch).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class StackEngineProcessDetailedTests: XCTestCase {
    // Uses the same synthetic-frame helpers other StackEngine tests use.
    // See StackEngineTests for makeSyntheticStarField / RawFrame construction.

    func testProcessDelegatesToProcessDetailed() {
        let engine = TestFixtures.seededEngine()          // helper mirrored from StackEngineTests
        let frame = TestFixtures.registrableFrame()
        let detailed = engine.processDetailed(frame)
        // A second identical engine+frame through process() yields the same outcome.
        let engine2 = TestFixtures.seededEngine()
        let plain = engine2.process(TestFixtures.registrableFrame())
        XCTAssertEqual(detailed.outcome, plain)
    }

    func testReferenceFrameReportsWeightOne() {
        let engine = TestFixtures.freshEngine()
        let result = engine.processDetailed(TestFixtures.seedFrame())
        XCTAssertEqual(result.outcome, .becameReference)
        XCTAssertEqual(result.weight, 1.0, accuracy: 1e-6)
        XCTAssertGreaterThan(result.starCount, 0)
    }

    func testStackedFrameReportsMeasuredStarsAndSigma() {
        let engine = TestFixtures.seededEngine()
        let result = engine.processDetailed(TestFixtures.registrableFrame())
        if case .stacked = result.outcome {
            XCTAssertGreaterThan(result.starCount, 0)
            XCTAssertGreaterThan(result.backgroundSigma, 0)
        } else {
            XCTFail("expected .stacked, got \(result.outcome)")
        }
    }
}
```

Implementer note: `TestFixtures` here stands for the existing synthetic-frame builders in `StackEngineTests.swift` — reuse those exact helpers (copy the builder calls inline if they are `private`), do not invent a new star-field generator.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --scratch-path .build/test --filter StackEngineProcessDetailedTests`
Expected: FAIL — "value of type 'StackEngine' has no member 'processDetailed'".

- [ ] **Step 3: Implement the seam**

Add the result type near `StackOutcome` (top of file):

```swift
/// `process` outcome plus the per-sub quality metrics the stacker measured while
/// deciding it (spec §Data flow). Surfaced so the session can retain per-sub stats
/// without recomputation. Weight is the value actually applied (1.0 for the reference,
/// 0 for a rejected sub).
public struct ProcessResult: Equatable {
    public let outcome: StackOutcome
    public let starCount: Int
    public let backgroundSigma: Float
    public let weight: Float
}
```

Replace `process`:

```swift
    public func process(_ frame: RawFrame) -> StackOutcome { processDetailed(frame).outcome }

    public func processDetailed(_ frame: RawFrame) -> ProcessResult {
        lock.withLock { processDetailedLocked(frame) }
    }
```

Rename the existing `processLocked(_:) -> StackOutcome` to `processDetailedLocked(_:) -> ProcessResult`, and at each of its `return` sites wrap the outcome with the metrics already in scope. Concretely, wherever it currently does `return .stacked(frameCount:)`, `return .becameReference`, or `return .rejected(reason)`, capture the local `stars.count`, `sigma`, and applied weight and instead `return ProcessResult(outcome: <that outcome>, starCount: <stars.count or 0>, backgroundSigma: <sigma or 0>, weight: <applied weight, 1.0 for reference, 0 for rejected>)`. Keep every branch's existing side effects (accumulate, counters) exactly as-is.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --scratch-path .build/test --filter "StackEngineProcessDetailedTests|StackEngineTests"`
Expected: PASS — the new tests AND all existing `StackEngineTests` (proves `process` behavior is unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Stacking/StackEngine.swift Tests/LiveAstroCoreTests/StackEngineProcessDetailedTests.swift
git commit -F /tmp/las-commit.txt   # "feat(core): StackEngine.processDetailed surfaces per-sub metrics"
```

---

### Task 6: `SessionPipeline.onSubFrame` hook

**Files:**
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` (add callback; call it in `handleNative`, line 579)
- Test: `Tests/LiveAstroCoreTests/SessionPipelineSubFrameTests.swift`

**Interfaces:**
- Consumes: `ProcessResult` (Task 5), `SubFrameRecord`/`SubFrameOutcome` (Task 1).
- Produces: `public var onSubFrame: ((SubFrameRecord) -> Void)?` — fired once per processed native sub, on the same callback-delivery context as `onUpdate`/`onRejected`.

In `handleNative`, change `let outcome = engine.process(frame)` to `let result = engine.processDetailed(frame)` and use `result.outcome` in the existing `switch`. After the switch (still inside `withCallbackDelivery`), build and emit a `SubFrameRecord`:

```swift
        let subOutcome: SubFrameOutcome
        var reason: String? = nil
        switch result.outcome {
        case .becameReference: subOutcome = .reference
        case .stacked:         subOutcome = .stacked
        case .rejected(let r): subOutcome = .rejected; reason = "\(r)"
        }
        onSubFrame?(SubFrameRecord(
            index: engine.acceptedCount, timestamp: frame.timestamp, sourceFile: frame.sourceName,
            starCount: result.starCount, backgroundSigma: result.backgroundSigma,
            weight: result.weight, outcome: subOutcome, rejectionReason: reason, rejectedByUser: false))
```

Use `engine.acceptedCount` for accepted subs' index (matches `SnapshotRecord.index` in the accept branch). For a rejected sub, index by `processedCount` so every sub gets a distinct index — read the accept branch's index expression and keep accepted-sub indices identical to the snapshot index so the Stats row and the snapshot align; give rejected subs `processedCount` (they have no snapshot).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class SessionPipelineSubFrameTests: XCTestCase {
    func testOnSubFrameFiresForEachNativeSub() throws {
        // Reuse the native-pipeline harness from SessionPipelineTests (synthetic FolderFrameSource
        // + in-memory recorder). Copy its setup helper.
        let harness = try NativePipelineHarness(frames: [.seed, .good, .tooFewStars])
        var captured: [SubFrameRecord] = []
        harness.pipeline.onSubFrame = { captured.append($0) }
        try harness.runToCompletion()
        XCTAssertEqual(captured.count, 3)
        XCTAssertEqual(captured[0].outcome, .reference)
        XCTAssertEqual(captured[1].outcome, .stacked)
        XCTAssertEqual(captured[2].outcome, .rejected)
        XCTAssertNotNil(captured[2].rejectionReason)
    }
}
```

Implementer note: `NativePipelineHarness` / `.seed` / `.good` / `.tooFewStars` stand for the existing synthetic native-source test scaffolding in `SessionPipelineTests.swift` (or `StackEngineTests`). Reuse the real helpers; if a "too few stars" synthetic frame builder does not exist, build one from the existing star-field helper with fewer than `seedMinStars` stars.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --scratch-path .build/test --filter SessionPipelineSubFrameTests`
Expected: FAIL — "value of type 'SessionPipeline' has no member 'onSubFrame'".

- [ ] **Step 3: Add the callback declaration + wire the emit**

Add near the other `public var on…` declarations:

```swift
    /// Fired once per processed native sub with its measured quality (spec §Data flow).
    /// Same delivery context as onUpdate/onRejected. Watcher mode does not fire this
    /// (no per-sub stacking there).
    public var onSubFrame: ((SubFrameRecord) -> Void)?
```

Then apply the `handleNative` changes described in the Interfaces block above.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --scratch-path .build/test --filter "SessionPipelineSubFrameTests|SessionPipelineTests"`
Expected: PASS — new test AND existing pipeline tests (proves the switch refactor preserved behavior).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Pipeline/SessionPipeline.swift Tests/LiveAstroCoreTests/SessionPipelineSubFrameTests.swift
git commit -F /tmp/las-commit.txt   # "feat(core): SessionPipeline.onSubFrame per-sub hook"
```

---

### Task 7: `RestackCoordinator` — re-stack from raw excluding flagged

**Files:**
- Create: `Sources/LiveAstroCore/Pipeline/RestackCoordinator.swift`
- Test: `Tests/LiveAstroCoreTests/RestackCoordinatorTests.swift`

**Interfaces:**
- Consumes: `StackEngine`, `RawFrame`, `AstroImage`, `SubFrameRecord` (for the excluded set's source files).
- Produces:
  - `enum RestackError: Error, Equatable { case noSurvivingSubs, belowSeedMinimum(surviving: Int, needed: Int) }`
  - `struct RestackReport: Equatable { let master: AstroImage; let stackedCount: Int; let skippedMissing: Int }`
  - `enum RestackCoordinator { static func restack(rawURLs: [URL], excludingSourceFiles: Set<String>, makeEngine: () -> StackEngine, minRows: Int) throws -> RestackReport }`

Design: this is the **pure core** of re-stack — given the raw sub URLs and the set of source-file basenames to exclude, it seeds+registers+stacks with a fresh engine and returns the master. The app layer (Task 8) resolves the URLs from the session's `subFrames`/relay folder and applies the result. Keeping the URL-resolution and UI out of this function is what makes it unit-testable and byte-identical-checkable against a direct stack.

Algorithm:
1. Filter `rawURLs` to those whose `lastPathComponent` is **not** in `excludingSourceFiles`, preserving order. Count how many of the *kept* URLs fail to load as `skippedMissing`.
2. Decode each kept+loadable URL to a `RawFrame` (reuse `ImageLoader.load` / the same loader the import path uses).
3. If survivors is 0 → throw `.noSurvivingSubs`. Seed with the first; if seeding fails, advance to the next until one seeds or the list is exhausted (throw `.belowSeedMinimum(surviving:needed:)` with the engine's seed minimum — expose it via a read the engine already has, or pass it in). Then `process` the rest.
4. Return `RestackReport(master: engine.currentStack()!, stackedCount: engine.stackFrameCount, skippedMissing:)`.

Read `ImportController.beginImport` (lines 94-160) and `SessionPipeline.start`/`end` before implementing — prefer routing through the **same** `SessionPipeline` offline path if it can be driven from an explicit URL list; if the existing `FolderFrameSource` only takes a folder (not a URL list), drive the engine directly here (seed+process loop) rather than inventing a new source. The golden test below pins that "drive the engine directly" and "route through SessionPipeline" produce the same master, so either is acceptable as long as the test passes.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class RestackCoordinatorTests: XCTestCase {
    // Writes N synthetic FITS subs to a temp dir; returns their URLs in order.
    private func writeSubs(_ n: Int) throws -> [URL] { /* reuse FITSWriter + star-field helper */ }
    private func makeEngine() -> StackEngine { TestFixtures.freshEngine() }

    func testRestackEqualsFreshStackOfSurvivors() throws {
        let urls = try writeSubs(5)
        let excluded: Set<String> = [urls[2].lastPathComponent]
        let report = try RestackCoordinator.restack(rawURLs: urls, excludingSourceFiles: excluded,
                                                    makeEngine: makeEngine, minRows: 100)
        // Reference: stack the same 4 survivors directly through a fresh engine.
        let survivors = urls.enumerated().filter { $0.offset != 2 }.map(\.element)
        let reference = try TestFixtures.stackDirectly(survivors, minRows: 100)
        XCTAssertEqual(report.master.pixels, reference.pixels)   // byte-identical
        XCTAssertEqual(report.stackedCount, 4)
    }

    func testFlagIsOrderIndependent() throws {
        let urls = try writeSubs(4)
        let a = try RestackCoordinator.restack(rawURLs: urls, excludingSourceFiles: [urls[1].lastPathComponent, urls[3].lastPathComponent], makeEngine: makeEngine, minRows: 100)
        let b = try RestackCoordinator.restack(rawURLs: urls, excludingSourceFiles: [urls[3].lastPathComponent, urls[1].lastPathComponent], makeEngine: makeEngine, minRows: 100)
        XCTAssertEqual(a.master.pixels, b.master.pixels)
    }

    func testAllExcludedThrowsNoSurviving() throws {
        let urls = try writeSubs(3)
        let all = Set(urls.map(\.lastPathComponent))
        XCTAssertThrowsError(try RestackCoordinator.restack(rawURLs: urls, excludingSourceFiles: all, makeEngine: makeEngine, minRows: 100)) {
            XCTAssertEqual($0 as? RestackError, .noSurvivingSubs)
        }
    }

    func testMissingRawCountedAsSkipped() throws {
        var urls = try writeSubs(3)
        urls.append(URL(fileURLWithPath: "/nonexistent/ghost.fit"))
        let report = try RestackCoordinator.restack(rawURLs: urls, excludingSourceFiles: [], makeEngine: makeEngine, minRows: 100)
        XCTAssertEqual(report.skippedMissing, 1)
        XCTAssertEqual(report.stackedCount, 3)
    }
}
```

Implementer note: `TestFixtures.stackDirectly` / `writeSubs` reuse the existing synthetic-FITS builders (`FITSWriter` + the star-field helper used by `StackEngineTests`/`MasterBuilderTests`). `stackDirectly` seeds the first survivor and `process`es the rest through a fresh engine — the exact sequence `restack` performs, which is what makes the byte-identity assertion meaningful.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --scratch-path .build/test --filter RestackCoordinatorTests`
Expected: FAIL — "cannot find 'RestackCoordinator' in scope".

- [ ] **Step 3: Implement**

```swift
import Foundation

public enum RestackError: Error, Equatable {
    case noSurvivingSubs
    case belowSeedMinimum(surviving: Int, needed: Int)
}

public struct RestackReport: Equatable {
    public let master: AstroImage
    public let stackedCount: Int
    public let skippedMissing: Int
}

/// Rebuilds a master from raw subs minus an excluded set (spec §Re-stack engine).
/// Pure given a URL list and exclusion set: seeds + processes with a fresh engine and
/// returns the master. URL resolution and applying the result live in the app layer.
public enum RestackCoordinator {
    public static func restack(rawURLs: [URL], excludingSourceFiles: Set<String>,
                               makeEngine: () -> StackEngine, minRows: Int) throws -> RestackReport {
        let kept = rawURLs.filter { !excludingSourceFiles.contains($0.lastPathComponent) }
        var frames: [RawFrame] = []
        var skippedMissing = 0
        for url in kept {
            guard let frame = try? ImageLoader.loadRawFrame(url: url) else { skippedMissing += 1; continue }
            frames.append(frame)
        }
        guard !frames.isEmpty else { throw RestackError.noSurvivingSubs }

        let engine = makeEngine()
        var seeded = false
        for frame in frames {
            if !seeded {
                seeded = engine.seedReference(frame, minRows: minRows)
                continue
            }
            _ = engine.process(frame)
        }
        guard seeded, let master = engine.currentStack() else {
            throw RestackError.belowSeedMinimum(surviving: frames.count, needed: engine.seedMinStars)
        }
        return RestackReport(master: master, stackedCount: engine.stackFrameCount, skippedMissing: skippedMissing)
    }
}
```

Implementer notes:
- Use whatever loader the import path uses to turn a URL into a `RawFrame` (read `ImageLoader` — if there is no `loadRawFrame(url:)`, use the existing call `ImportController`/`FolderFrameSource` uses and match its calibration behavior; for v1 re-stack, calibration parity with the live session is desirable but the golden test runs without calibration).
- `engine.seedMinStars` is `private` today — add a `public var seedMinStars: Int { seedMinStarsValue }` accessor (or read the stored `let`) so the error can report it. If exposing it is awkward, throw `.belowSeedMinimum(surviving: frames.count, needed: 0)` and drop `needed` from the assertion.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --scratch-path .build/test --filter RestackCoordinatorTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Pipeline/RestackCoordinator.swift Tests/LiveAstroCoreTests/RestackCoordinatorTests.swift
git commit -F /tmp/las-commit.txt   # "feat(core): RestackCoordinator rebuilds master from raw minus flagged"
```

---

### Task 8: AppModel wiring — published sub-frames, flag, re-stack drive

**Files:**
- Modify: `Sources/LiveAstroStudio/AppModel.swift` (add published state + methods; wire `onSubFrame`)
- Modify: `Sources/LiveAstroStudio/ImportController.swift` or wherever `onSubFrame` should also fire for offline import (optional — see note)
- Test: `Tests/LiveAstroStudioTests/AppModelSubFrameTests.swift` (create if the app-test target exists; otherwise fold into an existing app test file)

**Interfaces:**
- Consumes: `onSubFrame` (Task 6), `SessionManager.recordSubFrame`/`setSubFrameUserRejected`/`subFrames` (Task 3), `RestackCoordinator.restack` (Task 7), `RestackReport`/`RestackError`.
- Produces on `AppModel`:
  - `@Published private(set) var subFrames: [SubFrameRecord] = []`
  - `var flaggedCount: Int { subFrames.filter(\.rejectedByUser).count }`
  - `func toggleReject(index: Int)` — flips the flag on the in-memory record + persists via `SessionManager`.
  - `@Published private(set) var isRestacking = false`
  - `func restackWithoutFlagged()` — resolves survivor raw URLs, calls `RestackCoordinator`, applies the new master to the display/broadcast + `master.fit`, updates counts; guards against concurrent runs.

Wiring: where `AppModel` builds the native `SessionPipeline` (search for existing `onUpdate =`/`onRejected =` assignments), add:

```swift
        pipeline.onSubFrame = { [weak self] record in
            guard let self else { return }
            self.subFrames.append(record)
            try? self.session.recordSubFrame(record)
        }
```

(Match the main-actor hop pattern the sibling callbacks use.)

`toggleReject`:

```swift
    func toggleReject(index: Int) {
        guard let i = subFrames.firstIndex(where: { $0.index == index }) else { return }
        subFrames[i].rejectedByUser.toggle()
        try? session.setSubFrameUserRejected(index: index, rejected: subFrames[i].rejectedByUser)
    }
```

`restackWithoutFlagged` (drive on a background task, apply on main):

```swift
    func restackWithoutFlagged() {
        guard !isRestacking else { return }
        let excluded = Set(subFrames.filter(\.rejectedByUser).map(\.sourceFile))
        guard !excluded.isEmpty else { return }
        guard let rawURLs = resolveRawSubURLs() else {          // relay/watch folder listing
            log("Re-stack unavailable — raw subs are no longer on disk.")
            return
        }
        isRestacking = true
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let report = try RestackCoordinator.restack(
                    rawURLs: rawURLs, excludingSourceFiles: excluded,
                    makeEngine: { self.makeStackEngine() }, minRows: self.minRows)
                await MainActor.run {
                    self.applyRestackedMaster(report.master)     // re-render display + write master.fit
                    if report.skippedMissing > 0 {
                        self.log("Re-stack: \(report.skippedMissing) raw sub(s) missing — used the rest.")
                    }
                    self.log("Re-stacked without \(excluded.count) flagged sub(s): \(report.stackedCount) frames.")
                    self.isRestacking = false
                }
            } catch {
                await MainActor.run {
                    self.log("Re-stack failed: \(error). Master unchanged.")
                    self.isRestacking = false
                }
            }
        }
    }
```

Implementer notes:
- `resolveRawSubURLs()`, `applyRestackedMaster(_:)`, `makeStackEngine()`, `minRows`, and `log(_:)` — wire these to the existing AppModel/`AppSurface` equivalents (the import path already has `makeStackEngine`, a display-render path, and a `master.fit` writer via `writeMasterSnapshot`/`MasterBuilder.save`). Reuse them; do not duplicate rendering.
- **Offline import**: `onSubFrame` fires only in native live mode (Task 6). Firing it for "Stack Previous Shoot" is a nice-to-have; if the offline pipeline shares `handleNative` it comes for free — verify and note. Not required for v1 (spec scopes rejection to the live/just-finished session).

- [ ] **Step 1: Write the failing test** (if `LiveAstroStudioTests` target exists)

```swift
import XCTest
@testable import LiveAstroStudio
@testable import LiveAstroCore

@MainActor
final class AppModelSubFrameTests: XCTestCase {
    func testToggleRejectFlipsFlagAndCount() {
        let model = AppModel.testInstance()               // use existing test factory if present
        model.ingestSubFrameForTesting(.init(index: 1, timestamp: Date(timeIntervalSince1970: 0),
            sourceFile: "a.fit", starCount: 100, backgroundSigma: 1, weight: 1,
            outcome: .stacked, rejectionReason: nil, rejectedByUser: false))
        XCTAssertEqual(model.flaggedCount, 0)
        model.toggleReject(index: 1)
        XCTAssertEqual(model.flaggedCount, 1)
        model.toggleReject(index: 1)
        XCTAssertEqual(model.flaggedCount, 0)
    }
}
```

If there is **no** app-level test target (only `LiveAstroCoreTests`), skip this test file; the `toggleReject`/`flaggedCount` logic is thin over the Task-3 core API which is already tested. State this explicitly in the task report rather than adding a target.

- [ ] **Step 2: Run test to verify it fails** (or note target absence)

Run: `swift test --scratch-path .build/test --filter AppModelSubFrameTests`
Expected: FAIL — missing member; OR "no tests matched" if the app target has no tests (then rely on build + manual verification).

- [ ] **Step 3: Implement the wiring** (as above).

- [ ] **Step 4: Verify**

Run: `swift build` (must compile) and `swift test --scratch-path .build/test --filter AppModelSubFrameTests` if the target exists.
Expected: build succeeds; app test passes or is correctly absent.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroStudio/AppModel.swift Tests/LiveAstroStudioTests/AppModelSubFrameTests.swift 2>/dev/null; git add -A
git commit -F /tmp/las-commit.txt   # "feat(app): AppModel sub-frame capture, flagging, and re-stack drive"
```

---

### Task 9: Setup → inner `TabView` split (structural)

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift` (reduce to a `TabView` container + pinned footer)
- Create: `Sources/LiveAstroStudio/CaptureSettingsView.swift`, `DisplaySettingsView.swift`, `BroadcastSettingsView.swift`, `DiagnosticsView.swift`
- Test: none new — this is a behavior-preserving relocation; verified by `swift build` + full suite green.

**Interfaces:**
- Consumes: `AppModel` (existing bindings).
- Produces: four `View` structs each taking `@Bindable var model: AppModel` (or the exact injection `ControlView` uses today), rendering the moved `Form` sections.

This is a **cut-and-relocate**, not a rewrite. Map (from the spec + current `ControlView`):

| New file | Sections moved out of `ControlView`'s `Form` |
|---|---|
| `CaptureSettingsView` | "Start Workflow", "Watch Folder", "Calibration", "Session Profile", "Session end" |
| `DisplaySettingsView` | "Night vision", "Display Adjustments" |
| `BroadcastSettingsView` | "OBS" (`OBSSection`) |
| `DiagnosticsView` | "Log" section + (from the footer) the Session Health grid |
| `StatsView` | (created in Task 10) |

`ControlView.body` becomes:

```swift
    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            TabView(selection: $model.setupSubTab) {
                CaptureSettingsView(model: model).tabItem { Label("Capture", systemImage: "camera") }.tag(SetupSubTab.capture)
                DisplaySettingsView(model: model).tabItem { Label("Display", systemImage: "slider.horizontal.3") }.tag(SetupSubTab.display)
                StatsView(model: model).tabItem { Label("Stats", systemImage: "chart.bar") }.tag(SetupSubTab.stats)
                BroadcastSettingsView(model: model).tabItem { Label("Broadcast", systemImage: "dot.radiowaves.left.and.right") }.tag(SetupSubTab.broadcast)
                DiagnosticsView(model: model).tabItem { Label("Diagnostics", systemImage: "stethoscope") }.tag(SetupSubTab.diagnostics)
            }
            Divider()
            controlFooter          // the existing always-visible footer VStack (Start/End, Go Live, Session Outputs) — extract to a computed property, keep pinned
        }
    }
```

Add to `AppModel`: `enum SetupSubTab: Hashable { case capture, display, stats, broadcast, diagnostics }` and `@Published var setupSubTab: SetupSubTab = .capture`.

Rules for the move:
- Each moved `Section` keeps its exact contents, bindings, `.disabled(...)`, and helper subviews (`WorkflowActionRow`, `InfoButton`, `helpToggle`, `HealthItem`, `OBSSection`). Move the private helper structs used by only one destination into that destination's file; keep shared helpers (`InfoButton`, `helpToggle`, `HealthItem`) in a small shared file (e.g. `ControlView` keeps them, or a new `ControlWidgets.swift`) so multiple views reference one copy — **do not duplicate** them.
- The footer (Start/End session, Go Live, Session Outputs, import progress, app version) stays in `ControlView` below the `TabView`, unchanged.
- Each new view wraps its sections in `ScrollView { Form { … }.formStyle(.grouped) }` exactly as `ControlView` does today.

- [ ] **Step 1: Add `SetupSubTab` + `setupSubTab` to `AppModel`.** Build.

Run: `swift build` — Expected: succeeds.

- [ ] **Step 2: Create the four view files, moving sections verbatim.** After each file, build.

Run: `swift build` — Expected: succeeds (fix any missed binding/helper reference before moving on).

- [ ] **Step 3: Rewrite `ControlView.body` to the `TabView` container + extracted `controlFooter`.**

Run: `swift build` — Expected: succeeds.

- [ ] **Step 4: Run the full suite to prove nothing regressed.**

Run: `swift test --scratch-path .build/test`
Expected: PASS — same count as before this task (UI move adds no tests; existing tests unaffected).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -F /tmp/las-commit.txt   # "refactor(app): split Setup into Capture/Display/Stats/Broadcast/Diagnostics sub-tabs"
```

---

### Task 10: `StatsView` — table, rollups, reject toggle, re-stack button

**Files:**
- Create: `Sources/LiveAstroStudio/StatsView.swift`
- Test: none new (SwiftUI view over Task-8 logic; verified by build + manual). The reject/re-stack logic it calls is tested in Tasks 3/7/8.

**Interfaces:**
- Consumes: `AppModel.subFrames`, `flaggedCount`, `isRestacking`, `toggleReject(index:)`, `restackWithoutFlagged()`.
- Produces: `struct StatsView: View`.

```swift
import SwiftUI
import LiveAstroCore

struct StatsView: View {
    @Bindable var model: AppModel

    private var accepted: Int { model.subFrames.filter { $0.outcome != .rejected }.count }
    private var rejected: Int { model.subFrames.filter { $0.outcome == .rejected }.count }
    private var meanWeight: Float {
        let stacked = model.subFrames.filter { $0.outcome == .stacked }
        guard !stacked.isEmpty else { return 0 }
        return stacked.map(\.weight).reduce(0, +) / Float(stacked.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            rollup
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.subFrames.reversed(), id: \.index) { row($0) }   // newest first
                }
            }
            Divider()
            footer
        }
    }

    private var rollup: some View {
        HStack(spacing: 16) {
            stat("Accepted", "\(accepted)")
            stat("Rejected", "\(rejected)")
            stat("Flagged", "\(model.flaggedCount)")
            stat("Mean weight", String(format: "%.2f", meanWeight))
            Spacer()
            StarCountSparkline(values: model.subFrames.map { $0.starCount })
                .frame(width: 120, height: 28)
        }
        .padding(10)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }
    }

    private func row(_ r: SubFrameRecord) -> some View {
        HStack {
            Text("#\(r.index)").frame(width: 48, alignment: .leading).monospacedDigit()
            Text("★\(r.starCount)").frame(width: 60, alignment: .leading).monospacedDigit()
            Text(String(format: "σ%.2f", r.backgroundSigma)).frame(width: 64, alignment: .leading).monospacedDigit()
            Text(String(format: "×%.2f", r.weight)).frame(width: 56, alignment: .leading).monospacedDigit()
            statusBadge(r)
            Spacer()
            if r.outcome != .rejected {
                Toggle("Reject", isOn: Binding(
                    get: { r.rejectedByUser },
                    set: { _ in model.toggleReject(index: r.index) }))
                    .toggleStyle(.button).controlSize(.small)
                    .disabled(model.isRestacking)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(r.rejectedByUser ? Color.red.opacity(0.12) : .clear)
        .opacity(r.outcome == .rejected ? 0.5 : 1)
    }

    private func statusBadge(_ r: SubFrameRecord) -> some View {
        let (text, color): (String, Color) = switch r.outcome {
            case .reference: ("ref", .blue)
            case .stacked:   ("stacked", .green)
            case .rejected:  ("rejected", .orange)
        }
        return Text(text).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.2), in: Capsule()).foregroundStyle(color)
    }

    private var footer: some View {
        HStack {
            if model.isRestacking { ProgressView().controlSize(.small); Text("Re-stacking…").foregroundStyle(.secondary) }
            else { Text(model.flaggedCount == 0 ? "No subs flagged" : "\(model.flaggedCount) flagged").foregroundStyle(.secondary) }
            Spacer()
            Button("Re-stack without flagged") { model.restackWithoutFlagged() }
                .disabled(model.flaggedCount == 0 || model.isRestacking)
        }
        .padding(10)
    }
}

/// Minimal inline sparkline of per-sub star counts so a cloud band / focus drift reads at a glance.
private struct StarCountSparkline: View {
    let values: [Int]
    var body: some View {
        GeometryReader { geo in
            if values.count > 1, let maxV = values.max(), maxV > 0 {
                Path { p in
                    for (i, v) in values.enumerated() {
                        let x = geo.size.width * CGFloat(i) / CGFloat(values.count - 1)
                        let y = geo.size.height * (1 - CGFloat(v) / CGFloat(maxV))
                        i == 0 ? p.move(to: .init(x: x, y: y)) : p.addLine(to: .init(x: x, y: y))
                    }
                }.stroke(.secondary, lineWidth: 1)
            }
        }
    }
}
```

- [ ] **Step 1: Create `StatsView.swift` with the code above.**

- [ ] **Step 2: Build.**

Run: `swift build`
Expected: succeeds. (StatsView is already referenced by `ControlView`'s Stats tab from Task 9 — this resolves that reference.)

- [ ] **Step 3: Full suite green.**

Run: `swift test --scratch-path .build/test`
Expected: PASS — unchanged count.

- [ ] **Step 4: Commit**

```bash
git add Sources/LiveAstroStudio/StatsView.swift
git commit -F /tmp/las-commit.txt   # "feat(app): StatsView — per-sub table, rollups, reject + re-stack"
```

---

### Task 11: Persist & export sub-frames CSV + session-end re-stack offer

**Files:**
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` (write `sub-frames.csv` in `end()`, near the existing `frame-summary.csv` write)
- Modify: `Sources/LiveAstroStudio/ControlView.swift` (Session Outputs footer: add sub-frames.csv reveal/open, matching the existing CSV affordance)
- Modify: `Sources/LiveAstroStudio/AppModel.swift` (at session end, if `flaggedCount > 0`, surface a re-stack offer — a confirm, not automatic)
- Test: `Tests/LiveAstroCoreTests/SessionPipelineSubFrameCSVTests.swift`

**Interfaces:**
- Consumes: `SubFrameCSV` (Task 4), `SessionManager.subFrames` (Task 3), `restackWithoutFlagged()` (Task 8).
- Produces: a `sub-frames.csv` file in the session directory; a Session Outputs affordance; a session-end confirm hook.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class SessionPipelineSubFrameCSVTests: XCTestCase {
    func testEndWritesSubFramesCSV() throws {
        let harness = try NativePipelineHarness(frames: [.seed, .good])
        let sessionDir = try harness.runToCompletion()      // returns the session directory
        let csv = sessionDir.appendingPathComponent("sub-frames.csv")
        XCTAssertTrue(FileManager.default.fileExists(atPath: csv.path))
        let text = try String(contentsOf: csv, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("index,timestamp,source_file,star_count"))
        XCTAssertEqual(text.split(separator: "\n").count, 3)   // header + 2 subs
    }
}
```

Adjust `runToCompletion()`'s return to expose the session directory if it does not already (read the harness).

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --scratch-path .build/test --filter SessionPipelineSubFrameCSVTests`
Expected: FAIL — file does not exist.

- [ ] **Step 3: Write the CSV in `end()`**

In `SessionPipeline.end()`, next to where `frame-summary.csv` is written (search for `SessionFrameCSV` / `frame-summary`), add:

```swift
        let subCSV = SubFrameCSV.string(from: session.subFrames)
        try? (subCSV.data(using: .utf8) ?? Data()).write(to: sessionDir.appendingPathComponent("sub-frames.csv"), options: .atomic)
```

Use the same `sessionDir` variable and write idiom the existing CSV uses.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --scratch-path .build/test --filter SessionPipelineSubFrameCSVTests`
Expected: PASS.

- [ ] **Step 5: Add the Session Outputs affordance + session-end offer, then build**

- In `ControlView`'s Session Outputs footer, duplicate the existing `frame-summary.csv` open/reveal buttons for `sub-frames.csv` (same helper, new filename).
- In `AppModel`'s session-end path (where `end()` returns), if `flaggedCount > 0` set a `@Published var restackOfferPending = true` that `StatsView`/`ControlView` surfaces as a non-blocking "N subs flagged — Re-stack final master?" affordance calling `restackWithoutFlagged()`. Automatic re-stack is NOT performed (spec: it's a confirm).

Run: `swift build && swift test --scratch-path .build/test`
Expected: build succeeds; full suite green.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -F /tmp/las-commit.txt   # "feat: export sub-frames.csv + offer final re-stack at session end"
```

---

## Final verification (before finishing the branch)

- [ ] Full suite green on a quiet machine, normal runtime, read three ways (exit code + "All tests passed" + failure count):
  `swift test --scratch-path .build/test`
- [ ] `swift build -c release` succeeds (release config catches what debug misses).
- [ ] Dispatch an **adversarial-cold-review** (2+ parallel lenses: math/correctness on `RestackCoordinator` byte-identity + concurrency/robustness on the `onSubFrame`/re-stack task lifecycle) and a **code-quality-review** on the new files, per the project's review skills. Fix PROVEN Critical/Important with regression tests before merge.
- [ ] Manual smoke: run a Demo session, watch the Stats tab populate, flag a sub, hit Re-stack, confirm the master updates and `sub-frames.csv` is present in the session folder.

## Self-Review (completed by author)

**Spec coverage:** A (stats retain+show) → T1,T2,T3,T5,T6,T8,T10. B (rejection+re-stack) → T7,T8,T10,T11. C (settings de-clutter) → T9. Persistence/CSV → T2,T4,T11. Error handling (missing raw / all-flagged / below-seed / in-flight) → T7 (core) + T8 (drive guards). Out-of-scope items (FWHM/HFR, auto-threshold, past-session editing) correctly absent. No gaps.

**Type consistency:** `SubFrameRecord`/`SubFrameOutcome` field names and `ProcessResult`/`RestackReport`/`RestackError` signatures are identical across T1→T11. `onSubFrame: ((SubFrameRecord) -> Void)?`, `processDetailed -> ProcessResult`, `restack(rawURLs:excludingSourceFiles:makeEngine:minRows:)`, `toggleReject(index:)`, `restackWithoutFlagged()`, `SetupSubTab` used consistently.

**Known implementer-judgment points (flagged inline, not placeholders):** exact persist helper in `SessionManager` (mirror `recordSnapshot`), the synthetic-frame test builders' real names (reuse from existing test files), the raw-URL loader name in `ImageLoader`, and whether an app-level test target exists (T8). Each names the existing code to read and the fallback if it differs.

---

## Task 8 Refinement (resolved during execution — architecture decisions)

Reading the real `AppModel`/`SessionPipeline` surface surfaced ownership and concurrency
facts the original Task 8 under-specified. Resolved decisions (these BIND Tasks 8a/8b/11):

- **`SessionPipeline.session` is `public let session: SessionManager`.** The manifest is
  mutated on the pipeline's callback-delivery thread (where `recordSnapshot` runs). AppModel
  must NOT write the manifest from the main actor — that races the consume task.
- **Sub-record persistence lives in the pipeline**, not AppModel: `handleNative` calls
  `try? session.recordSubFrame(record)` right where it emits `onSubFrame` (same thread as
  `recordSnapshot`, for every sub — accepted AND rejected). This completes the Task-6 emit.
- **AppModel holds a main-actor `@Published private(set) var subFrames` mirror**, appended in
  the `onSubFrame` handler's `Task { @MainActor }`. It is the source of truth for the Stats UI
  and the re-stack excluded set.
- **Flagging (`toggleReject`) mutates the AppModel mirror only** during a live session — it does
  NOT write the manifest mid-session (would race the consume task). Flags are persisted to the
  manifest at the race-free points: `end()` and re-stack (Task 11 writes them before the CSV).
  v1 limitation (documented): a flag made mid-session is not crash-durable until `end()`.
- **Re-stack is gated on `!isRunning`** (available after capture stops / import finishes).
  Rationale: applying a rebuilt master to a live pipeline's display would be overwritten by the
  next frame, and it avoids concurrent-writer hazards. Faithful to the spec's "deliberate button
  / offered at session end." Live re-stack is a possible v1.1 follow-up.
- **Raw-sub directory for re-stack:** AppModel records the directory the just-finished session
  drew subs from (relay session dir for live; the chosen folder for import) and passes it to the
  coordinator. `RestackCoordinator.restack` takes raw URLs, so AppModel lists that directory's
  FITS files.

### Task 8a — Sub-frame data plane (pipeline persistence + AppModel mirror + flagging)
- Amend `SessionPipeline.handleNative`: after the `onSubFrame?` emit, `try? session.recordSubFrame(record)`.
- AppModel: `@Published private(set) var subFrames: [SubFrameRecord] = []`; wire `pipeline.onSubFrame`
  in `wireCallbacks` to append on the main actor; `var flaggedCount`; `func toggleReject(index:)`
  (mirror-only mutation); reset `subFrames = []` at session start.
- Tests: a pipeline test asserting subs land in `session.subFrames` (accepted + rejected); the
  AppModel mirror/toggle logic is thin over tested core.

### Task 8b — Re-stack drive
- `@Published private(set) var isRestacking`; `func restackWithoutFlagged()` gated on `!isRunning`
  and `flaggedCount > 0`; resolve raw dir → list FITS URLs → `RestackCoordinator.restack(rawURLs:excludingSourceFiles:makeEngine:)`
  off-main → on success write `master.fit` (reuse the master-write path) + update `latestImage`
  via `displayCGImage`; guard concurrent runs; surface missing-raw / errors via `log`/`errorMessage`.
