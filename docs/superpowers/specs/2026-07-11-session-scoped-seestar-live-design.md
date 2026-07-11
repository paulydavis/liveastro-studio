# LiveAstro Studio — "Session-Scoped Seestar Live" Design

**Date:** 2026-07-11 · **Status:** approved for planning ·
**Origin:** the 2026-07-11 live-session failure — tapping **Seestar Live** on
NGC 6960 replayed the two prior nights (606 old subs) before reaching tonight's
75, because the Seestar `<target>_sub` folder accumulates every night's raw subs
and the relay copies the whole folder oldest-first. It also beachballed while
enumerating the slow SMB share. Paul: *"it is a major UI flaw."* This is the #1
UX defect to fix — one-tap live viewing is unusable on any repeat target.

## 1. Goal

Tapping **Seestar Live** stacks **only the frames captured after the tap**, and
the tap **never blocks the UI on SMB**. No prior-night replay; no beachball.

## 2. Core decisions (settled 2026-07-11 with Paul)

| Decision | Choice |
|---|---|
| Cutoff semantics | **"This session only" = frames that appear after the tap** (Paul: "newer than tap time") |
| Cutoff mechanism | **Baseline-exclusion (approach B):** snapshot the filenames present at tap; relay only names that appear afterward. Clock-independent, source-agnostic, trivially testable — chosen over source-mtime (clock-skew fragile) and filename-timestamp parsing (Seestar-specific, brittle) |
| Scope | **Both** the replay cutoff **and** the detect() main-thread SMB stall (the "spinning") |
| Detect cost | **No per-file stats** — pick the newest fit by its trailing capture-timestamp token, not by statting every file |
| Threading | `startSeestarLive()` runs detection off the main thread; the relay's baseline snapshot + copies already run on the relay's own background queue |

## 3. Architecture

Three touch points, one new helper. `LiveAstroCore` stays Foundation-only.

```
LiveAstroCore/
  Seestar/
    SeestarRelay.swift      (+ sessionScoped flag + baseline snapshot + exclude-baseline in copyOnce)
    SeestarDetector.swift   (+ parseCaptureTimestamp; newest-fit by token, no per-file stat)
LiveAstroStudio/
    AppModel.swift          (startSeestarLive(): detect off-main via Task.detached, then hop to @MainActor)
```

### 3.1 `SeestarRelay` — baseline-exclusion cutoff

```swift
public init(source: URL, destination: URL,
            glob: String = "Light_*_10.0s_*.fit", pollSeconds: Double = 5,
            sessionScoped: Bool = true)
```

- New stored state: `private var baseline: Set<String> = []`.
- New internal method `func snapshotBaseline()` — lists `source` and stores the
  set of names matching `glob`. On source-unreachable it logs (existing
  "source unreachable" style) and leaves `baseline` empty (fail-open: better to
  relay than to silently drop a whole session).
- `start()`: create the destination dir, then enqueue the baseline snapshot on
  the existing serial `queue` (so the SMB listing runs **off the main thread**),
  then schedule the timer. Because `queue` is **serial** and the snapshot is
  enqueued before the timer resumes, the first `copyOnce()` is guaranteed to see
  the completed baseline. When `sessionScoped == false`, `snapshotBaseline()` is
  a no-op (empty baseline) → today's copy-everything behavior.
- `copyOnce()`: add one skip condition — `if baseline.contains(name) { continue }`
  — alongside the existing "already in destination" skip. Everything else
  (stage-copy, retry-next-poll, `relayedCount`) is unchanged.

**Resume-safety:** the relay dir is named `<target>-<date>[-<exp>s]`, so a
same-night app restart reuses it. Frames already relayed this session remain in
`destination` and are re-stacked (skip-existing keeps them); a fresh baseline
re-excludes only the backlog. No double-copy, no lost session frames.

### 3.2 `SeestarDetector` — newest fit without stat-storm

Today `detect()` stats **every** `.fit` (`contentModificationDateKey`) to find
the newest, purely to parse the current exposure — 659 SMB stats on the main
thread tonight. Replace with a token sort:

```swift
/// Extract the sortable capture stamp "YYYYMMDD-HHMMSS" from a Seestar filename
/// like "Light_NGC 6960_30.0s_LP_20260711-013530.fit". nil if absent.
public static func parseCaptureTimestamp(fromFilename name: String) -> String?
```

- Folder selection (which `_sub` is "tonight's") still uses the `_sub`
  directories' `contentModificationDate` — only a handful of dirs, cheap.
- Newest fit = the fit whose `parseCaptureTimestamp` token is lexicographically
  greatest (the `YYYYMMDD-HHMMSS` layout sorts chronologically). Parse the
  exposure (`parseExposure(fromFilename:)`, unchanged) from **that one name**.
  Files with no parseable token sort last / are ignored for "newest".
- Net: a directory listing + string comparisons, **zero per-file stats**.
- Sorting by the *timestamp token* (not the whole filename) is deliberate:
  full-name sort mis-orders when the exposure token varies
  (`"20.0s" < "30.0s"` regardless of date), which would report the wrong
  current exposure after a 30s→20s restart. The token sort is correct.

### 3.3 `AppModel.startSeestarLive()` — off the main thread

Wrap the SMB-touching detection so the UI never blocks:

```swift
func startSeestarLive() {
    guard !isRunning, !isImporting else { return }
    isDetecting = true                       // brief "Looking for Seestar…" state
    Task.detached { [weak self] in
        let found = SeestarDetector.detect()  // SMB work, off main
        await MainActor.run {
            guard let self else { return }
            self.isDetecting = false
            guard let found else {
                self.errorMessage = "No Seestar share found. Mount it first: …"
                return
            }
            self.configureAndStartSeestar(found)   // existing body, on main
        }
    }
}
```

- `configureAndStartSeestar(_:)` is the current synchronous body from
  `found` onward (set `sourceMode`/prefix/neutralize/target/exposure/glob,
  build `relayDir`, create + `start()` the relay, `saveSettings()`,
  `startSession()`, guard `isRunning`, switch to Live tab). Extracting it keeps
  the method small and leaves the on-main state mutation exactly as today.
- The relay's baseline snapshot and all copies run on the relay's background
  queue (§3.1), so **no** SMB work remains on the main thread.
- `isDetecting` is a published `@Observable` flag for a spinner/label; it does
  not gate correctness.

## 4. Data flow

```
tap "Seestar Live"
  isDetecting = true
  Task.detached:
    SeestarDetector.detect()            // off-main: list _sub dirs, token-sort newest fit → target+exposure
  @MainActor configureAndStartSeestar(found):
    set native mode, Light_ prefix, target, exposure, per-exp relay dir
    SeestarRelay(source: _sub, destination: relayDir, glob, sessionScoped: true)
    relay.start()  → queue.async { snapshotBaseline()  // off-main SMB list; backlog names captured }
                   → timer: copyOnce() skips baseline ∪ dest → only post-tap frames relayed
    startSession() watches relayDir (local disk) → stacks only this session's frames
    → Live tab
```

## 5. Error handling

| Situation | Behavior |
|---|---|
| No Seestar share mounted (`detect()` == nil) | existing mount-help `errorMessage`, now surfaced on main after the detached detect; `isDetecting` cleared |
| Source unreachable during baseline snapshot | log "source unreachable"; `baseline` stays empty (fail-open — relay rather than drop the session); copies resume when reachable |
| Filenames without a capture-timestamp token | ignored when choosing "newest"; if none parse, exposure is nil → any-exposure glob `Light_*.fit` (today's fallback) |
| `startSession()` fails (`!isRunning`) | existing rollback: `relay.stop()`, clear it, return |
| Same-night restart | relay dir reused; session frames preserved (skip-existing), backlog re-excluded |

## 6. Testing

`swift test --filter LiveAstroCoreTests`

- **`SeestarRelay` baseline exclusion (TDD):** a temp source seeded with 3
  backlog files → `snapshotBaseline()` → add 2 new matching files → `copyOnce()`
  copies **only the 2 new** (backlog excluded, count == 2, dest has exactly the
  2 new names).
- **`sessionScoped: false` back-compat:** with no baseline snapshot, `copyOnce()`
  copies all matching files (today's behavior) — proves the flag gates it.
- **Resume:** dest already contains one of this session's frames → `copyOnce()`
  skips it (skip-existing) and copies only the genuinely new ones; no double copy.
- **Glob still honored:** a non-matching file present after the snapshot is not
  relayed.
- **`parseCaptureTimestamp`:** valid Seestar name → `"20260711-013530"`; a name
  without the token → nil.
- **Newest-fit exposure selection:** given names mixing `30.0s`(older date) and
  `20.0s`(newer date), the detector reports **20.0s** (newest by token), proving
  the token sort, not full-name sort, and that no stat is required (pure-name
  inputs).
- **App wiring (`startSeestarLive` async refactor, `isDetecting`):**
  manual/build-verified in RELEASE — SwiftUI/`@MainActor`/window lifecycle is
  out of unit-test scope, matching the prior four pillars.

## 7. Non-goals (future builds)

"Detect current run by gap" or a run-picker UI (Paul chose newer-than-tap this
build); mtime/filename-timestamp cutoffs (B chosen); de-Seestar-ify / generic
source layer for ASI2600MC-Air (separate pillar — but the baseline mechanism is
already source-agnostic and ports cleanly); clearing/rotating the Seestar's own
`_sub` folder (we never mutate the source); the accepted-vs-seen count badge and
reference-seed validation (related, separately ledgered).

## 8. Risks

| Risk | Mitigation |
|---|---|
| Baseline snapshot races the first copy pass | snapshot and copyOnce are enqueued on the **same serial queue**, snapshot first → ordering guaranteed; a test drives `snapshotBaseline()` then `copyOnce()` explicitly |
| Session started *before* the tap loses its pre-tap frames | intended semantics (newer-than-tap, Paul's choice); the full set always remains on the Seestar EMMC for a later deep Import |
| Token sort mis-picks exposure | sort by the timestamp token only (not whole filename); explicit mixed-exposure test |
| Async `startSeestarLive` touches `@Observable` state off main | all state mutation stays inside `await MainActor.run`; only `detect()` runs detached |
| Fail-open baseline relays a backlog if the source briefly errors at snapshot | logged; worst case is a one-time over-relay (recoverable), preferred over silently dropping a whole session's frames |
