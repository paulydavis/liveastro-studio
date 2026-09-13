# Session Completion Awareness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a live session aware it has stopped — an idle safeguard that writes the master mid-session (so a quit can't lose it) and keeps stacking, plus a planned clock-time stop that runs a full End Session.

**Architecture:** A pure `SessionCompletionMonitor.decide` returns an action from (clock, last-accepted-frame, settings); an `AppModel` 30 s tick dispatches it — `.safeguard` calls a new `SessionPipeline.writeMasterSnapshot()` (native-only, atomic, non-terminating), `.endSession` routes to the existing `endSession()`. macOS local notifications alert an away operator. New settings persist via the existing Codable-back-compat pattern.

**Tech Stack:** Swift 5.10 SPM, XCTest, SwiftUI, Foundation `UserNotifications` (system framework, no new dependency).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-07-session-completion-design.md` — binding.
- Idle safeguard **keeps the session live** (never ends/stops stacking); planned stop runs the **existing** `AppModel.endSession()` (no parallel finalize logic). Neither quits the app or stops an OBS broadcast.
- Master snapshot is **native-mode only** (watcher mode has no app-owned master; the external stacker owns it). Idle in watcher mode may notify but writes no master.
- Master writes use the temp+atomic `FileReplace.replaceItem` pattern — a failed write never destroys a prior good master, and the safeguard "fired" flag is NOT set on failure (retry next tick).
- Planned stop resolves to the **next occurrence** of the time-of-day (crosses midnight). If both triggers are due in one tick, `.endSession` wins.
- Settings back-compat: new `SessionSettings` fields decode via `decodeIfPresent ?? default` (old blobs load unchanged) — mirror the existing pattern at `SessionSettings.swift:36-53`.
- No new dependencies beyond Apple SDKs. One `swift test` at a time; `tee` durable logs; read the XCTest "Executed N tests" line (swift-testing "0 tests" line is noise; grep exits 1 on no match = success).
- Commit trailer: end every commit body with `Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j` and no other trailer.

---

### Task 1: SessionCompletionMonitor (pure decision logic)

**Files:**
- Create: `Sources/LiveAstroCore/Session/SessionCompletionMonitor.swift`
- Test: `Tests/LiveAstroCoreTests/SessionCompletionMonitorTests.swift`

**Interfaces:**
- Produces:
  - `public struct CompletionSettings: Equatable { public var idleSafeguardEnabled: Bool; public var idleSafeguardMinutes: Int; public var plannedStopEnabled: Bool; public var plannedStopHour: Int; public var plannedStopMinute: Int; public init(...) }`
  - `public enum CompletionAction: Equatable { case none, safeguard, endSession }`
  - `public enum SessionCompletionMonitor { static func decide(now: Date, lastAcceptedFrame: Date?, settings: CompletionSettings, safeguardAlreadyFiredThisIdle: Bool, plannedStopAlreadyFired: Bool, calendar: Calendar = .current) -> CompletionAction; static func plannedStopDeadline(after reference: Date, hour: Int, minute: Int, calendar: Calendar = .current) -> Date }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import LiveAstroCore

final class SessionCompletionMonitorTests: XCTestCase {
    private var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; return c }()
    private func d(_ s: String) -> Date {
        let f = ISO8601DateFormatter(); f.timeZone = cal.timeZone; return f.date(from: s)!
    }
    private func settings(idle: Bool = true, mins: Int = 15, planned: Bool = false, h: Int = 3, m: Int = 0) -> CompletionSettings {
        CompletionSettings(idleSafeguardEnabled: idle, idleSafeguardMinutes: mins,
                           plannedStopEnabled: planned, plannedStopHour: h, plannedStopMinute: m)
    }

    // --- planned stop deadline (next occurrence, midnight crossing) ---
    func testPlannedDeadlineLaterToday() {
        // 22:00, stop 23:30 → same day 23:30
        let dl = SessionCompletionMonitor.plannedStopDeadline(after: d("2026-08-07T22:00:00-04:00"), hour: 23, minute: 30, calendar: cal)
        XCTAssertEqual(dl, d("2026-08-07T23:30:00-04:00"))
    }
    func testPlannedDeadlineCrossesMidnight() {
        // 23:00, stop 03:00 → NEXT day 03:00
        let dl = SessionCompletionMonitor.plannedStopDeadline(after: d("2026-08-07T23:00:00-04:00"), hour: 3, minute: 0, calendar: cal)
        XCTAssertEqual(dl, d("2026-08-08T03:00:00-04:00"))
    }
    func testPlannedDeadlineTimeAlreadyPassedTodayRollsToTomorrow() {
        // 04:00, stop 03:00 → tomorrow 03:00
        let dl = SessionCompletionMonitor.plannedStopDeadline(after: d("2026-08-07T04:00:00-04:00"), hour: 3, minute: 0, calendar: cal)
        XCTAssertEqual(dl, d("2026-08-08T03:00:00-04:00"))
    }

    // --- idle ---
    func testIdleNotElapsed() {
        let a = SessionCompletionMonitor.decide(now: d("2026-08-07T22:10:00-04:00"),
            lastAcceptedFrame: d("2026-08-07T22:00:00-04:00"), settings: settings(mins: 15),
            safeguardAlreadyFiredThisIdle: false, plannedStopAlreadyFired: false, calendar: cal)
        XCTAssertEqual(a, .none)   // only 10 min < 15
    }
    func testIdleElapsedFiresSafeguard() {
        let a = SessionCompletionMonitor.decide(now: d("2026-08-07T22:16:00-04:00"),
            lastAcceptedFrame: d("2026-08-07T22:00:00-04:00"), settings: settings(mins: 15),
            safeguardAlreadyFiredThisIdle: false, plannedStopAlreadyFired: false, calendar: cal)
        XCTAssertEqual(a, .safeguard)
    }
    func testIdleElapsedButAlreadyFiredStaysNone() {
        let a = SessionCompletionMonitor.decide(now: d("2026-08-07T22:30:00-04:00"),
            lastAcceptedFrame: d("2026-08-07T22:00:00-04:00"), settings: settings(mins: 15),
            safeguardAlreadyFiredThisIdle: true, plannedStopAlreadyFired: false, calendar: cal)
        XCTAssertEqual(a, .none)   // one safeguard per idle episode
    }
    func testIdleDisabledNeverFires() {
        let a = SessionCompletionMonitor.decide(now: d("2026-08-07T23:00:00-04:00"),
            lastAcceptedFrame: d("2026-08-07T22:00:00-04:00"), settings: settings(idle: false),
            safeguardAlreadyFiredThisIdle: false, plannedStopAlreadyFired: false, calendar: cal)
        XCTAssertEqual(a, .none)
    }
    func testNoFramesYetUsesNoIdle() {
        // lastAcceptedFrame nil (session just started, no accepts) → no idle safeguard
        let a = SessionCompletionMonitor.decide(now: d("2026-08-07T22:16:00-04:00"),
            lastAcceptedFrame: nil, settings: settings(mins: 15),
            safeguardAlreadyFiredThisIdle: false, plannedStopAlreadyFired: false, calendar: cal)
        XCTAssertEqual(a, .none)
    }

    // --- planned stop ---
    func testPlannedStopBeforeDeadline() {
        // now 02:59, stop 03:00 → not yet
        let a = SessionCompletionMonitor.decide(now: d("2026-08-08T02:59:00-04:00"),
            lastAcceptedFrame: d("2026-08-08T02:58:00-04:00"), settings: settings(planned: true, h: 3, m: 0),
            safeguardAlreadyFiredThisIdle: false, plannedStopAlreadyFired: false, calendar: cal)
        XCTAssertEqual(a, .none)
    }
    func testPlannedStopAtDeadlineFires() {
        let a = SessionCompletionMonitor.decide(now: d("2026-08-08T03:00:05-04:00"),
            lastAcceptedFrame: d("2026-08-08T02:58:00-04:00"), settings: settings(planned: true, h: 3, m: 0),
            safeguardAlreadyFiredThisIdle: false, plannedStopAlreadyFired: false, calendar: cal)
        XCTAssertEqual(a, .endSession)
    }
    func testPlannedStopAlreadyFiredStaysNone() {
        let a = SessionCompletionMonitor.decide(now: d("2026-08-08T03:05:00-04:00"),
            lastAcceptedFrame: d("2026-08-08T02:58:00-04:00"), settings: settings(planned: true, h: 3, m: 0),
            safeguardAlreadyFiredThisIdle: false, plannedStopAlreadyFired: true, calendar: cal)
        XCTAssertEqual(a, .none)
    }

    // --- priority: both due → endSession wins ---
    func testBothDueEndSessionWins() {
        // idle elapsed AND past 03:00 stop
        let a = SessionCompletionMonitor.decide(now: d("2026-08-08T03:20:00-04:00"),
            lastAcceptedFrame: d("2026-08-08T02:00:00-04:00"), settings: settings(mins: 15, planned: true, h: 3, m: 0),
            safeguardAlreadyFiredThisIdle: false, plannedStopAlreadyFired: false, calendar: cal)
        XCTAssertEqual(a, .endSession)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SessionCompletionMonitorTests 2>&1 | tee /tmp/las-t1-red.log`
Expected: compile failure — `SessionCompletionMonitor` / `CompletionSettings` not defined.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// User-facing completion settings (a value copy of the relevant SessionSettings
/// fields, so the pure logic doesn't depend on the whole settings type).
public struct CompletionSettings: Equatable {
    public var idleSafeguardEnabled: Bool
    public var idleSafeguardMinutes: Int
    public var plannedStopEnabled: Bool
    public var plannedStopHour: Int
    public var plannedStopMinute: Int
    public init(idleSafeguardEnabled: Bool, idleSafeguardMinutes: Int,
                plannedStopEnabled: Bool, plannedStopHour: Int, plannedStopMinute: Int) {
        self.idleSafeguardEnabled = idleSafeguardEnabled
        self.idleSafeguardMinutes = idleSafeguardMinutes
        self.plannedStopEnabled = plannedStopEnabled
        self.plannedStopHour = plannedStopHour
        self.plannedStopMinute = plannedStopMinute
    }
}

public enum CompletionAction: Equatable { case none, safeguard, endSession }

/// Pure decision logic for session completion (spec §2). No side effects — the
/// driver owns the clock, the fired flags, and the actions.
public enum SessionCompletionMonitor {

    /// The next occurrence of `hour:minute` at or after `reference` (crosses
    /// midnight). If today's occurrence is already strictly before `reference`,
    /// roll to tomorrow.
    public static func plannedStopDeadline(after reference: Date, hour: Int, minute: Int,
                                           calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: reference)
        var comps = DateComponents(); comps.hour = hour; comps.minute = minute
        let todayAt = calendar.date(byAdding: comps, to: today) ?? reference
        if todayAt >= reference { return todayAt }
        return calendar.date(byAdding: .day, value: 1, to: todayAt) ?? todayAt
    }

    public static func decide(now: Date, lastAcceptedFrame: Date?, settings: CompletionSettings,
                              safeguardAlreadyFiredThisIdle: Bool, plannedStopAlreadyFired: Bool,
                              calendar: Calendar = .current) -> CompletionAction {
        // Planned stop takes priority when both are due.
        if settings.plannedStopEnabled, !plannedStopAlreadyFired {
            // Resolve the deadline relative to a reference EARLIER than now so the
            // "next occurrence" is the one we've reached. Using now itself for a
            // time that just passed today would roll to tomorrow; so compare the
            // deadline computed from the start of today.
            let today = calendar.startOfDay(for: now)
            var comps = DateComponents(); comps.hour = settings.plannedStopHour; comps.minute = settings.plannedStopMinute
            if let todayAt = calendar.date(byAdding: comps, to: today), now >= todayAt {
                return .endSession
            }
        }
        if settings.idleSafeguardEnabled, !safeguardAlreadyFiredThisIdle, let last = lastAcceptedFrame {
            let elapsed = now.timeIntervalSince(last)
            if elapsed >= Double(settings.idleSafeguardMinutes) * 60 { return .safeguard }
        }
        return .none
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter SessionCompletionMonitorTests 2>&1 | tee /tmp/las-t1-green.log`
Expected: all 12 PASS. (Note: `plannedStopDeadline` tests exercise the standalone helper; `decide` uses the inline start-of-day comparison so a time that just passed today fires today, not tomorrow.)

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Session/SessionCompletionMonitor.swift Tests/LiveAstroCoreTests/SessionCompletionMonitorTests.swift
git commit -m "feat: SessionCompletionMonitor pure decision logic"
```

### Task 2: SessionSettings fields + Codable back-compat

**Files:**
- Modify: `Sources/LiveAstroCore/Settings/SessionSettings.swift`
- Test: `Tests/LiveAstroCoreTests/SessionSettingsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `SessionSettings.idleSafeguardEnabled: Bool` (default true), `.idleSafeguardMinutes: Int` (default 15), `.plannedStopEnabled: Bool` (default false), `.plannedStopHour: Int` (default 3), `.plannedStopMinute: Int` (default 0); a `var completionSettings: CompletionSettings` computed accessor bridging to Task 1.

- [ ] **Step 1: Write the failing tests**

Append to `SessionSettingsTests.swift`:

```swift
func testCompletionDefaults() {
    let s = SessionSettings.defaults
    XCTAssertTrue(s.idleSafeguardEnabled)
    XCTAssertEqual(s.idleSafeguardMinutes, 15)
    XCTAssertFalse(s.plannedStopEnabled)
    XCTAssertEqual(s.plannedStopHour, 3)
    XCTAssertEqual(s.plannedStopMinute, 0)
}
func testCompletionSettingsBridge() {
    var s = SessionSettings.defaults
    s.plannedStopEnabled = true; s.plannedStopHour = 2; s.plannedStopMinute = 30
    let c = s.completionSettings
    XCTAssertTrue(c.plannedStopEnabled); XCTAssertEqual(c.plannedStopHour, 2); XCTAssertEqual(c.plannedStopMinute, 30)
    XCTAssertTrue(c.idleSafeguardEnabled); XCTAssertEqual(c.idleSafeguardMinutes, 15)
}
func testCompletionBackCompatOldBlobDecodesToDefaults() throws {
    // A JSON blob WITHOUT the new keys must decode with the defaults, not throw.
    let json = "{\"sourceModeRaw\":\"nativeStack\",\"filePrefix\":\"Light_\",\"neutralizeBackground\":true,\"subExposureSeconds\":30,\"targetName\":\"\"}"
    let s = try JSONDecoder().decode(SessionSettings.self, from: Data(json.utf8))
    XCTAssertTrue(s.idleSafeguardEnabled); XCTAssertEqual(s.idleSafeguardMinutes, 15)
    XCTAssertFalse(s.plannedStopEnabled); XCTAssertEqual(s.plannedStopHour, 3)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SessionSettingsTests 2>&1 | tee /tmp/las-t2-red.log`
Expected: compile failure — `idleSafeguardEnabled` unknown.

- [ ] **Step 3: Implement**

Add the five stored properties to the struct (after `demosaic`):

```swift
    public var idleSafeguardEnabled: Bool
    public var idleSafeguardMinutes: Int
    public var plannedStopEnabled: Bool
    public var plannedStopHour: Int
    public var plannedStopMinute: Int
```

Add matching parameters to the memberwise `init(...)` with defaults so existing call sites compile unchanged:

```swift
                idleSafeguardEnabled: Bool = true,
                idleSafeguardMinutes: Int = 15,
                plannedStopEnabled: Bool = false,
                plannedStopHour: Int = 3,
                plannedStopMinute: Int = 0)
```
and in the body:
```swift
        self.idleSafeguardEnabled = idleSafeguardEnabled
        self.idleSafeguardMinutes = idleSafeguardMinutes
        self.plannedStopEnabled = plannedStopEnabled
        self.plannedStopHour = plannedStopHour
        self.plannedStopMinute = plannedStopMinute
```

Add CodingKeys entries for the five keys, and in `init(from decoder:)` (mirroring `SessionSettings.swift:45-53`):

```swift
        idleSafeguardEnabled = try c.decodeIfPresent(Bool.self, forKey: .idleSafeguardEnabled) ?? true
        idleSafeguardMinutes = try c.decodeIfPresent(Int.self, forKey: .idleSafeguardMinutes) ?? 15
        plannedStopEnabled = try c.decodeIfPresent(Bool.self, forKey: .plannedStopEnabled) ?? false
        plannedStopHour = try c.decodeIfPresent(Int.self, forKey: .plannedStopHour) ?? 3
        plannedStopMinute = try c.decodeIfPresent(Int.self, forKey: .plannedStopMinute) ?? 0
```

Add the bridge accessor:

```swift
    /// The subset the completion monitor needs (Task 1).
    public var completionSettings: CompletionSettings {
        CompletionSettings(idleSafeguardEnabled: idleSafeguardEnabled,
                           idleSafeguardMinutes: idleSafeguardMinutes,
                           plannedStopEnabled: plannedStopEnabled,
                           plannedStopHour: plannedStopHour,
                           plannedStopMinute: plannedStopMinute)
    }
```

Also add the five to `.defaults` if it is a stored literal (not derived from `init()`); if `.defaults` uses the memberwise init with defaulted params, no change needed. Verify which and update accordingly.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter SessionSettingsTests 2>&1 | tee /tmp/las-t2-green.log`
Expected: all pre-existing + 3 new PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Settings/SessionSettings.swift Tests/LiveAstroCoreTests/SessionSettingsTests.swift
git commit -m "feat: SessionSettings completion fields with Codable back-compat"
```

### Task 3: SessionPipeline.writeMasterSnapshot (mid-session, native-only, atomic)

**Files:**
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift`
- Test: `Tests/LiveAstroCoreTests/SessionPipelineTests.swift` (or the existing pipeline test file — locate it; if none, create `SessionPipelineSnapshotTests.swift`)

**Interfaces:**
- Consumes: `StackEngine.currentStack() -> AstroImage?`, `.currentCoverage() -> [Float]?` (existing); `cropMaster`, `AutoStretch.neutralizeBackgroundAdditive`, `FITSWriter.float32`, `FileReplace.replaceItem` (existing).
- Produces: `public func writeMasterSnapshot() -> Bool` — writes `master.fit` from the current live stack into the session dir via a temp file + `FileReplace` atomic swap; returns true on success, false if not native / no stack / write failed. **Does NOT** stamp `end_time`, stop the engine, or touch session running state. Idempotent; callable repeatedly.

- [ ] **Step 1: Write the failing test**

Follow the existing SessionPipeline test setup (native `FrameSource` + `StackEngine`, feed a few synthetic frames, then snapshot). If no pipeline test file exists, model the fixture on `NativePipelineTests`/`SessionPipeline` e2e tests.

```swift
func testWriteMasterSnapshotProducesMasterMidSession() throws {
    // Build a native pipeline, start it, feed >=1 accepted frame so currentStack() is non-nil.
    // (reuse the project's native-pipeline fixture that seeds a star field)
    let pipeline = /* native pipeline over a temp session dir, engine seeded + 1 commit */
    XCTAssertTrue(pipeline.writeMasterSnapshot())
    let master = pipeline.sessionDir.appendingPathComponent("master.fit")   // expose sessionDir if needed (internal)
    XCTAssertTrue(FileManager.default.fileExists(atPath: master.path))
    // Session is STILL running: a further frame still commits (engine untouched).
    // (feed one more frame; assert currentStack() advanced / no throw)
}

func testSnapshotReturnsFalseWithNoStack() throws {
    // Native pipeline started but NO accepted frames yet (currentStack() == nil) → false, no file.
    let pipeline = /* native pipeline, started, zero commits */
    XCTAssertFalse(pipeline.writeMasterSnapshot())
}

func testPriorMasterSurvivesFailedSnapshot() throws {
    // Inject a FileManager whose replaceItem/move throws; write a good master first via
    // a successful snapshot, then a failing one; assert the prior master bytes are intact.
    // (use the ReplacementFailingFileManager pattern from NativeDenoiseProcessorTests)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter "SessionPipeline|Snapshot" 2>&1 | tee /tmp/las-t3-red.log`
Expected: `writeMasterSnapshot` not defined.

- [ ] **Step 3: Implement**

Add to `SessionPipeline` (mirror the master-write in `end()` at lines ~640-666 but source from `currentStack()`):

```swift
    /// Write master.fit from the CURRENT live stack without ending the session
    /// (idle safeguard, spec §2). Native mode only. Atomic via FileReplace so a
    /// prior good master survives a failed write. Returns false when there is no
    /// native stack yet or the write failed.
    @discardableResult
    public func writeMasterSnapshot() -> Bool {
        guard let engine, let dir = sessionDirectory else { return false }   // native + started
        guard let stack0 = engine.currentStack() else { return false }
        let master = cropMaster(stack0, coverage: engine.currentCoverage())
        let balanced = neutralizeBackground
            ? AutoStretch.neutralizeBackgroundAdditive(master)
            : master
        let data = FITSWriter.float32(width: balanced.width, height: balanced.height,
                                      channels: balanced.channels, pixels: balanced.pixels,
                                      metadata: sessionMetadata, stackCount: engine.committedCount,
                                      totalExposureSeconds: engine.committedCount * subExposureSeconds)
        let target = dir.appendingPathComponent("master.fit")
        let tmp = dir.appendingPathComponent(".master-snapshot-\(UUID().uuidString).fit")
        do {
            try data.write(to: tmp)
            try FileReplace.replaceItem(at: target, withItemAt: tmp, fileManager: fileManager)
            onLog?("master snapshot written (\(engine.committedCount) frames)")
            return true
        } catch {
            try? fileManager.removeItem(at: tmp)
            onLog?("master snapshot failed: \(error.localizedDescription)")
            return false
        }
    }
```

Wire the pieces this needs from existing pipeline state — confirm the exact names during implementation and adjust: the session directory (the plan assumes a `sessionDirectory: URL?`/`dir` the pipeline already holds — `start()` creates it; expose it internally if not already), `neutralizeBackground` (the profile flag used in `end()`), `sessionMetadata` (whatever `end()` passes as metadata), `engine.committedCount` (the accepted-frame count used for STACKCNT/TOTALEXP — if the engine exposes a different name like `currentStack` count, use that), `subExposureSeconds`, and an injectable `fileManager` (add a `fileManager: FileManager = .default` stored property if the pipeline doesn't have one, for the failure test). If `committedCount` does not exist, derive the count from the session's accepted total already tracked for the manifest. **Do not invent new engine API** — if `currentStack()`/`currentCoverage()` are the only accessors, use the session's existing accepted-count source for STACKCNT.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter "SessionPipeline|Snapshot" 2>&1 | tee /tmp/las-t3-green.log`
Expected: new snapshot tests PASS; existing pipeline tests unchanged.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Pipeline/SessionPipeline.swift Tests/LiveAstroCoreTests/*napshot*.swift Tests/LiveAstroCoreTests/SessionPipelineTests.swift
git commit -m "feat: SessionPipeline.writeMasterSnapshot for the idle safeguard"
```

### Task 4: SessionNotifier (macOS local notifications)

**Files:**
- Create: `Sources/LiveAstroStudio/SessionNotifier.swift`
- Test: build-only (system framework; behavior manual-verified — noted in the file).

**Interfaces:**
- Produces: `final class SessionNotifier { func requestAuthorizationIfNeeded(); func notifySafeguard(); func notifyPlannedStopEnd() }` — wraps `UNUserNotificationCenter`. Degrades silently if authorization is denied/unavailable.

- [ ] **Step 1: Implement**

```swift
import Foundation
import UserNotifications

/// Posts macOS local notifications so an away/asleep operator is alerted when a
/// session safeguards or auto-ends (spec §2 notifications). No-ops silently if
/// notification permission is denied — the safeguard/stop still happen either way.
/// Not unit-tested: UNUserNotificationCenter needs a real notification service;
/// behavior is manual-verified (grant permission once, trip the idle timeout).
final class SessionNotifier {
    private let center = UNUserNotificationCenter.current()

    func requestAuthorizationIfNeeded() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    func notifySafeguard() {
        post(title: "Capture idle", body: "No new frames — master saved. Session still running.")
    }
    func notifyPlannedStopEnd() {
        post(title: "Session complete", body: "Planned stop reached — master + replay written.")
    }
    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(req, withCompletionHandler: nil)
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tee /tmp/las-t4-build.log | tail -3`
Expected: Build complete.

- [ ] **Step 3: Commit**

```bash
git add Sources/LiveAstroStudio/SessionNotifier.swift
git commit -m "feat: SessionNotifier local notifications"
```

### Task 5: AppModel driver — tick, last-frame tracking, dispatch

**Files:**
- Modify: `Sources/LiveAstroStudio/AppModel.swift`
- Test: `Tests/LiveAstroCoreTests/` — the tick logic is exercised through `SessionCompletionMonitor` (Task 1); AppModel wiring is verified by build + a focused driver test if the model is testable, else manual. Add a small `SessionCompletionDriver` value type if needed to keep the re-arm/flag logic testable (see below).

**Interfaces:**
- Consumes: Task 1 `SessionCompletionMonitor.decide` + `CompletionAction`; Task 2 `settings.completionSettings`; Task 3 `pipeline.writeMasterSnapshot()`; Task 4 `SessionNotifier`; existing `AppModel.endSession()`, `sessionStart`, `isRunning`, `pipeline`.
- Produces: driver state on AppModel; a `lastAcceptedFrame: Date?` updated on every accepted frame.

- [ ] **Step 1: Extract the re-arm/flag logic into a testable type + test it**

Create `Sources/LiveAstroCore/Session/SessionCompletionDriver.swift`:

```swift
import Foundation

/// Holds the mutable per-session flags for completion (spec §2): the driver calls
/// `step` each tick; it clears the idle flag when a newer accepted frame appears
/// (re-arm) and marks flags after firing so each trigger fires once.
public struct SessionCompletionDriver {
    public private(set) var safeguardFired = false
    public private(set) var plannedStopFired = false
    private var lastSeenAcceptedFrame: Date?
    public init() {}

    public mutating func step(now: Date, lastAcceptedFrame: Date?, settings: CompletionSettings,
                              calendar: Calendar = .current) -> CompletionAction {
        // Re-arm the safeguard when a NEW accepted frame arrived since we last looked.
        if let last = lastAcceptedFrame, last != lastSeenAcceptedFrame {
            lastSeenAcceptedFrame = last
            safeguardFired = false
        }
        let action = SessionCompletionMonitor.decide(
            now: now, lastAcceptedFrame: lastAcceptedFrame, settings: settings,
            safeguardAlreadyFiredThisIdle: safeguardFired,
            plannedStopAlreadyFired: plannedStopFired, calendar: calendar)
        switch action {
        case .safeguard: safeguardFired = true
        case .endSession: plannedStopFired = true
        case .none: break
        }
        return action
    }
}
```

Test `Tests/LiveAstroCoreTests/SessionCompletionDriverTests.swift`:

```swift
import XCTest
@testable import LiveAstroCore

final class SessionCompletionDriverTests: XCTestCase {
    private var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; return c }()
    private func d(_ s: String) -> Date { let f = ISO8601DateFormatter(); f.timeZone = cal.timeZone; return f.date(from: s)! }
    private let s = CompletionSettings(idleSafeguardEnabled: true, idleSafeguardMinutes: 15,
                                       plannedStopEnabled: false, plannedStopHour: 3, plannedStopMinute: 0)

    func testSafeguardFiresOncePerIdleEpisode() {
        var drv = SessionCompletionDriver()
        let t0 = d("2026-08-07T22:00:00-04:00")
        XCTAssertEqual(drv.step(now: d("2026-08-07T22:16:00-04:00"), lastAcceptedFrame: t0, settings: s, calendar: cal), .safeguard)
        XCTAssertEqual(drv.step(now: d("2026-08-07T22:20:00-04:00"), lastAcceptedFrame: t0, settings: s, calendar: cal), .none)
    }
    func testResumedFrameReArmsSafeguard() {
        var drv = SessionCompletionDriver()
        let t0 = d("2026-08-07T22:00:00-04:00")
        _ = drv.step(now: d("2026-08-07T22:16:00-04:00"), lastAcceptedFrame: t0, settings: s, calendar: cal) // fires
        let t1 = d("2026-08-07T22:18:00-04:00")   // Seestar resumed
        _ = drv.step(now: d("2026-08-07T22:18:05-04:00"), lastAcceptedFrame: t1, settings: s, calendar: cal) // re-arm, not elapsed
        XCTAssertEqual(drv.step(now: d("2026-08-07T22:34:00-04:00"), lastAcceptedFrame: t1, settings: s, calendar: cal), .safeguard) // fires again
    }
    func testPlannedStopFiresOnce() {
        var drv = SessionCompletionDriver()
        let s2 = CompletionSettings(idleSafeguardEnabled: false, idleSafeguardMinutes: 15,
                                    plannedStopEnabled: true, plannedStopHour: 3, plannedStopMinute: 0)
        XCTAssertEqual(drv.step(now: d("2026-08-08T03:01:00-04:00"), lastAcceptedFrame: d("2026-08-08T02:00:00-04:00"), settings: s2, calendar: cal), .endSession)
        XCTAssertEqual(drv.step(now: d("2026-08-08T03:05:00-04:00"), lastAcceptedFrame: d("2026-08-08T02:00:00-04:00"), settings: s2, calendar: cal), .none)
    }
}
```

- [ ] **Step 2: Run red then implement the driver type; run green**

Run: `swift test --filter SessionCompletionDriverTests 2>&1 | tee /tmp/las-t5-red.log` (fails: driver undefined), implement the type above, then:
Run: `swift test --filter SessionCompletionDriverTests 2>&1 | tee /tmp/las-t5-green.log`
Expected: 3 PASS.

- [ ] **Step 3: Wire the driver into AppModel**

In `AppModel`:
- Add `private var completionDriver = SessionCompletionDriver()`, `private(set) var lastAcceptedFrame: Date?`, `private var completionTick: Task<Void, Never>?`, `private let notifier = SessionNotifier()`.
- In `startSession()`: `completionDriver = SessionCompletionDriver(); lastAcceptedFrame = nil; notifier.requestAuthorizationIfNeeded()`, then start the tick (below).
- In the accepted-frame path (where `acceptedCount` bumps, `AppModel.swift:376`): `self.lastAcceptedFrame = Date()`.
- In `endSession()`: `completionTick?.cancel(); completionTick = nil`.
- The tick:

```swift
    private func startCompletionTick() {
        completionTick?.cancel()
        completionTick = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)   // 30 s
                guard let self, self.isRunning, !Task.isCancelled else { return }
                let action = self.completionDriver.step(
                    now: Date(), lastAcceptedFrame: self.lastAcceptedFrame,
                    settings: self.settings.completionSettings)
                switch action {
                case .safeguard:
                    if self.pipeline?.writeMasterSnapshot() == true { self.notifier.notifySafeguard() }
                    else { /* snapshot failed/not native — driver flag stays set only on real fire;
                             writeMasterSnapshot false means retry next idle tick. Clear the flag so
                             it retries: */ self.completionDriver.clearSafeguardForRetry() }
                case .endSession:
                    self.notifier.notifyPlannedStopEnd()
                    self.endSession()   // existing full finalize; also cancels this tick
                    return
                case .none:
                    break
                }
            }
        }
    }
```

Add `mutating func clearSafeguardForRetry()` to `SessionCompletionDriver` that sets `safeguardFired = false` (so a failed native snapshot retries next tick). Add a driver test: safeguard action returned, then `clearSafeguardForRetry()`, next elapsed step returns `.safeguard` again.

Call `startCompletionTick()` at the end of a successful `startSession()`.

- [ ] **Step 4: Build + run driver/settings/monitor suites**

Run: `swift build 2>&1 | tail -3 && swift test --filter "SessionCompletion|SessionSettings" 2>&1 | tee /tmp/las-t5-suite.log`
Expected: build clean; all PASS (including the new `clearSafeguardForRetry` test).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Session/SessionCompletionDriver.swift Sources/LiveAstroStudio/AppModel.swift Tests/LiveAstroCoreTests/SessionCompletionDriverTests.swift
git commit -m "feat: AppModel completion driver tick + last-frame tracking"
```

### Task 6: UI (Setup group + Live status) + full-suite gate

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift` (Setup tab: "Session end" group; Live tab: armed status/countdown)
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `model.settings.idleSafeguardEnabled/Minutes/plannedStopEnabled/plannedStopHour/plannedStopMinute`; `model.settings.completionSettings`; `SessionCompletionMonitor.plannedStopDeadline` for the countdown.

- [ ] **Step 1: Add the Setup "Session end" group**

In the Setup form (near Session Profile / relay retention), a `Section("Session end")`:

```swift
Toggle("Idle safeguard — save master if capture stalls", isOn: $model.settings.idleSafeguardEnabled)
if model.settings.idleSafeguardEnabled {
    Stepper("After \(model.settings.idleSafeguardMinutes) min idle",
            value: $model.settings.idleSafeguardMinutes, in: 5...120, step: 5)
}
Toggle("Auto-stop at a set time", isOn: $model.settings.plannedStopEnabled)
if model.settings.plannedStopEnabled {
    DatePicker("Stop at", selection: Binding(
        get: { Calendar.current.date(bySettingHour: model.settings.plannedStopHour,
                minute: model.settings.plannedStopMinute, second: 0, of: Date()) ?? Date() },
        set: { newDate in
            let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
            model.settings.plannedStopHour = c.hour ?? 3
            model.settings.plannedStopMinute = c.minute ?? 0
        }), displayedComponents: .hourAndMinute)
}
```

Use `.help()` tooltips consistent with the codebase: idle-safeguard "Writes master.fit and keeps stacking; a cloud gap resumes normally."; auto-stop "Runs a full End Session at this time (does not quit the app or stop the broadcast)."

- [ ] **Step 2: Add the Live-tab armed status**

Where the Live tab shows session status, add a line when a live session is running and either trigger is armed:

```swift
if model.isRunning {
    let cs = model.settings.completionSettings
    if cs.plannedStopEnabled || cs.idleSafeguardEnabled {
        Text(completionStatusText(cs))
            .font(.caption).foregroundStyle(.secondary)
    }
}
```
with a helper that renders e.g. `"Auto-stop 3:00 AM · idle-safe 15 min"`, and when the planned stop is under 60 minutes away (via `SessionCompletionMonitor.plannedStopDeadline(after: Date(), hour:, minute:)` minus now), switch that segment to `"Auto-stop in 24 min"`.

- [ ] **Step 3: Build + manual UI sanity**

Run: `swift build 2>&1 | tail -3`
Expected: clean. (Manual: toggles persist across relaunch; status line appears when armed.)

- [ ] **Step 4: Full suite gate**

Run: `swift test 2>&1 | tee /tmp/las-t6-full.log; grep "Executed [0-9]* tests, with" /tmp/las-t6-full.log | tail -1`
Expected: 0 failures; watcher/segment + OBS invariant suites unaffected.

- [ ] **Step 5: Changelog + commit**

Add under Unreleased: "Session end: idle safeguard writes the master mid-session (never lose a stack to a quit) and keeps stacking; optional auto-stop at a set clock time runs a full End Session; macOS notifications when either fires."

```bash
git add Sources/LiveAstroStudio/ControlView.swift CHANGELOG.md
git commit -m "feat: Session-end UI (idle safeguard + auto-stop) + changelog"
```
