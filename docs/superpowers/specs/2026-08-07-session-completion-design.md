# Session Completion Awareness — Design

**Goal:** stop live sessions from silently idling (and stop losing masters to a
premature quit). Born from the 2026-08-06 M17 loss: the Seestar's plan
finished/clouded at 01:59, LiveAstro idled, and a Cmd-Q with no End Session
discarded the live master. Two owner-approved triggers make the app aware a
session has stopped and protect the outputs.

**Decisions (owner, 2026-08-07):** two independent triggers with *different*
behavior — idle **safeguards and keeps going**, planned-stop **fully ends**
(including an OBS broadcast LiveAstro owns — a manually-started OBS stream is
untouched); neither quits the app. Planned stop is an absolute
clock time. macOS local notifications so alerts reach an away/asleep operator.

**Non-goals:** no auto-quit; no duration or
frame-count stop inputs (clock time only); no change to the End Session flow
itself beyond invoking it. Replay is not rendered by the idle safeguard.
(Planned stop *does* run the full End Session, which stops an OBS broadcast
LiveAstro owns — the same as clicking End Session; a stream the operator started
manually in OBS is not touched.)

## 1. Behaviors

### Idle safeguard (keeps the session live)
- Tracks time since the last **accepted** frame (registration success + accumulate).
- When that exceeds `idleSafeguardMinutes` (default 15): **write `master.fit` +
  `session-summary.md` + `manifest.json`** from the current live stack, and post
  a notification — but do **not** end the session or stop stacking.
- Fires **once per idle episode**. Re-arms when a new accepted frame arrives
  (cloud gap resumes → stacking continues, safeguard ready again).
- Rationale: the master is the irreplaceable artifact; snapshots already exist on
  disk and the replay is regenerable from them via Import, so the safeguard
  protects the *data* cheaply without the heavy replay render.

### Planned stop (definitive end)
- User sets an absolute clock time (e.g. 3:00 AM). The deadline is the **next
  occurrence** of that time (set at 23:00, "3:00 AM" resolves to 03:00 the next
  day — crosses midnight correctly).
- At the deadline: run the **full existing End Session** (finalize master +
  render replay + write summary, stop stacking) and post a notification.
- Does **not** quit the app. It runs the full End Session, so it **ends an OBS
  broadcast LiveAstro owns** (started via Go Live), exactly like clicking End
  Session; a stream the operator started manually in OBS is left untouched.

Both triggers may be armed at once; they are independent. A cloud gap that trips
the idle safeguard never ends the session — only the planned stop (or the
operator) does.

## 2. Architecture

- **`SessionCompletionMonitor`** (LiveAstroCore, new) — the decision logic as a
  **pure function** with no side effects:
  ```
  enum CompletionAction: Equatable { case none, safeguard, endSession }
  static func decide(now: Date,
                     sessionStart: Date,
                     lastAcceptedFrame: Date?,
                     settings: CompletionSettings,
                     safeguardAlreadyFiredThisIdle: Bool,
                     plannedStopAlreadyFired: Bool) -> CompletionAction
  ```
  Where `CompletionSettings` carries `idleSafeguardEnabled`,
  `idleSafeguardMinutes`, `plannedStopEnabled`, `plannedStopTimeOfDay`
  (hour+minute). Planned-stop resolution to the next occurrence (midnight
  crossing) is pure math over `now` + time-of-day and is unit-tested here.
  Priority: if both are due in the same tick, `.endSession` wins (a definitive
  end supersedes a safeguard).
- **Driver** (AppModel / session orchestration): a repeating main-actor tick
  (e.g. every 30 s while a live session runs) that reads the clock + the
  watcher's last-accepted-frame timestamp, calls `decide`, and dispatches the
  action. Tracks the two "already fired" flags; clears the idle flag when a new
  accepted frame lands (re-arm). Cancelled on End Session / session teardown.
- **`SessionPipeline` gains `writeMasterSnapshot()`** — serialize the current
  live accumulator to `master.fit` + refresh `session-summary.md` +
  `manifest.json`, without ending the session or touching the stacking engine's
  running state. Reuses the existing writer + `FileReplace` atomic-swap so a
  failed write never destroys a prior good master.
- **`SessionNotifier`** (app layer, new small type) — posts macOS local
  notifications via the system **UserNotifications** framework (no new
  dependency; requests authorization once). Two messages: safeguard
  ("Capture idle — master saved") and planned-stop end ("Session complete —
  master + replay written"). Degrades silently if the user denied permission.

## 3. Settings & UI

- `SessionSettings` gains: `idleSafeguardEnabled: Bool = true`,
  `idleSafeguardMinutes: Int = 15`, `plannedStopEnabled: Bool = false`,
  `plannedStopHour: Int = 3`, `plannedStopMinute: Int = 0`. Codable
  `decodeIfPresent` with those defaults for back-compat (old blobs load
  unchanged).
- **Setup tab** — a "Session end" group: idle-safeguard toggle + minutes stepper;
  "Stop at" toggle + a time picker (hour/minute). Disabled while not in a live
  session is not required — they're pre-session settings.
- **Live tab** — a quiet status line when either is armed:
  *"Auto-stop 3:00 AM · idle-safe 15 min"*; the stop time switches to a
  countdown ("Auto-stop in 24 min") under, say, 60 minutes.

## 4. Error handling

- `writeMasterSnapshot` uses the temp+atomic-replace pattern (existing
  `FileReplace`); a failed snapshot logs and leaves any prior master intact, and
  the safeguard flag is NOT set (so it retries next tick).
- Planned-stop firing routes through the *existing* End Session path, inheriting
  all its finalize/robustness behavior; no parallel finalize logic.
- Notification authorization denied or unavailable → safeguard/stop still happen;
  only the alert is skipped (logged once).
- Monitor tick is generation/teardown-guarded like the other orchestration so a
  fired action can't land after the session already ended by other means.

## 5. Testing

- **`SessionCompletionMonitor.decide` (pure, exhaustive):** idle not-yet-elapsed →
  `.none`; idle elapsed + not-yet-fired → `.safeguard`; idle elapsed + already
  fired → `.none`; new frame clears the flag (re-arm); planned-stop before/after
  deadline; **midnight crossing** (set 23:00, stop 03:00 → resolves next day);
  both-due same tick → `.endSession` wins; disabled toggles → `.none`.
- **`writeMasterSnapshot`:** produces a valid `master.fit` from a live
  accumulator mid-session; prior master survives an injected write failure;
  session keeps running after (stacking engine untouched).
- **Driver:** re-arm on resumed frames; single safeguard per idle episode;
  planned-stop routes to End Session exactly once; cancelled on teardown.
- **Settings:** Codable back-compat (old blob → defaults), round-trip.
- Full suite green; watcher/segment and OBS invariant suites unaffected.
