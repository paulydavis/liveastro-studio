# LiveAstro Studio — "Go Live to YouTube (via OBS)" Design

**Date:** 2026-07-11 · **Status:** approved for planning ·
**Origin:** Paul's roadmap want — a one-tap **Go Live** that broadcasts the live
stack to YouTube by driving OBS, so he doesn't fiddle with OBS manually. This is
the **MVP tier**: OBS is configured with the YouTube RTMP + key once (OBS ▸
Settings ▸ Stream); LiveAstro triggers the stream. In-app YouTube OAuth / the
YouTube Live API is the deferred **Full tier** (not this build).

## 1. Goal

A deliberate, user-triggered broadcast: **Go Live** launches/connects OBS,
switches to the stack scene, and starts streaming to YouTube; **End Broadcast**
stops it. A live health readout shows it's actually broadcasting. Broadcasting is
**decoupled from session start**.

## 2. Core principles

- **Deliberate, not automatic.** Today `bringUpOBS()` auto-starts the stream on
  every session start. This pillar removes that: broadcasting only happens when
  the user taps Go Live. You image without broadcasting, then Go Live when the
  stack looks good.
- **Go Live owns the OBS lifecycle.** Session start no longer touches OBS; Go
  Live launches/connects OBS on demand. OBS only comes up when you broadcast.
- **Honest status.** A live readout (streaming, duration, dropped frames,
  congestion) via `GetStreamStatus`, so the operator sees the broadcast is real.
- **Safe teardown.** End Session auto-stops any live broadcast (never leave a
  dangling stream); End Broadcast leaves OBS connected for a quick re-Go-Live.
- **Best-effort guardrails.** OBS-WebSocket doesn't expose the YouTube key, so we
  attempt the stream and confirm it went active, surfacing a clear "check OBS ▸
  Settings ▸ Stream" message if it doesn't.
- **Builds on shipped plumbing.** The OBS WebSocket layer (auth, `StartStream`/
  `StopStream`, `SetCurrentProgramScene`, `GetStreamStatus`, event handling)
  already exists; this pillar is orchestration + status + guardrails + UI.

## 3. Decisions

| Decision | Choice |
|---|---|
| Scope | MVP only — OBS drives the YouTube RTMP; NO in-app YouTube OAuth/API |
| Session/OBS coupling | **Decoupled** — session start no longer brings up OBS; Go Live owns the whole OBS lifecycle |
| Trigger | Explicit **Go Live** / **End Broadcast** button |
| Scene | Go Live sets `stackSceneName` (if configured) before starting the stream |
| Health | `GetStreamStatus` polled ~2 s while live → `StreamHealth` readout |
| Guardrail | attempt `StartStream`, confirm `outputActive` within ~5 s; else stop + "check OBS Settings→Stream" |
| End Session | auto-stops a live broadcast (existing teardown stays) |
| End Broadcast | stops the stream, leaves OBS connected |

## 4. Architecture

```
LiveAstroCore/
  OBS/
    StreamHealth.swift        (NEW: value type + parse from GetStreamStatus)
    OBSController.swift        (+ streamStatus(), startBroadcast(scene:), stopBroadcast())
LiveAstroStudio/
    AppModel.swift            (broadcastState + streamHealth + goLive()/endBroadcast();
                              remove OBS bring-up from startSession; End Session stops broadcast)
    ControlView.swift         (Go Live / End Broadcast button + live status readout)
```

### 4.1 `StreamHealth` (pure, testable)

```swift
public struct StreamHealth: Equatable {
    public let active: Bool
    public let durationSeconds: Double     // outputDuration (ms) / 1000
    public let skippedFrames: Int          // outputSkippedFrames
    public let totalFrames: Int            // outputTotalFrames
    public let congestion: Double          // outputCongestion, clamped [0,1]
    /// Parse a GetStreamStatus responseData dict. nil if `outputActive` is absent.
    public static func parse(_ dict: [String: Any]) -> StreamHealth?
    public var droppedFraction: Double     // skipped / max(total,1)
}
```

### 4.2 `OBSController` additions

```swift
public func streamStatus() async -> StreamHealth?          // GetStreamStatus → parse
public func startBroadcast(scene: String?) async -> Bool   // scene? + StartStream + confirm active
public func stopBroadcast() async                          // StopStream + setRecording(false)
```
- `startBroadcast(scene:)`: if `scene` is non-nil/non-empty, `SetCurrentProgramScene`;
  then `StartStream`; then poll `GetStreamStatus` up to ~5× (≈1 s apart) until
  `active == true`. If it becomes active → return true. **If it never becomes
  active, send `StopStream` to reset OBS (don't leave it half-streaming on a bad
  key) and return false.** All via the existing `requestData` seam (so
  `MockOBSSocket` tests it). Logs each step via `onLog`.
- `stopBroadcast()`: `StopStream`, `setRecording(false)`.
- The `OBSState.streaming` case and the `StreamStateChanged` event handling
  already exist; `startBroadcast` returning true implies `state == .streaming`.

### 4.3 `AppModel`

```swift
enum BroadcastState: Equatable { case idle, connecting, live, stopping }
var broadcastState: BroadcastState = .idle
var streamHealth: StreamHealth?
private var healthPollTask: Task<Void, Never>?

func goLive()          // connecting → ensure connected (launch+retry) → startBroadcast → live + poll | error → idle
func endBroadcast()    // stopping → stopBroadcast → stop poll → idle (OBS stays connected)
```
- **Remove** `obsBringUpTask = Task { await bringUpOBS() }` from `startSession()`
  and delete/repurpose `bringUpOBS`'s auto-`startStream`. Factor the
  connect+launch+retry into a reusable `connectOBS() async -> Bool` that
  `goLive()` calls (no `StartStream` inside it).
- `goLive()`: guard `broadcastState == .idle`; `.connecting`; `connectOBS()` —
  false ⇒ `errorMessage = "OBS not reachable — is it installed/running?"`, `.idle`;
  true ⇒ `obs.startBroadcast(scene: stackSceneName)` — false ⇒
  `errorMessage = "OBS started but the stream didn't go live — check OBS ▸ Settings ▸ Stream (YouTube server + key)."`, `.idle`;
  true ⇒ `.live`, `streamHealth = ...`, start `healthPollTask` (loop: sleep 2 s,
  `obs.streamStatus()` → `streamHealth`; exit when not `.live`).
- `endBroadcast()`: guard `.live`; `.stopping`; cancel `healthPollTask`;
  `obs.stopBroadcast()`; `streamHealth = nil`; `.idle`.
- **End Session:** if `broadcastState == .live`, call `endBroadcast()` (or the
  existing `stopStream` teardown) so no broadcast is left running; clear state.
- **willTerminate:** existing quit-safety — a running broadcast is stopped only
  on a deliberate End Session (unchanged invariant: disconnect never sends
  StopStream).

### 4.4 UI (`ControlView`)

- A prominent **Go Live** button in the Live-tab footer area; while `.live` it
  becomes **End Broadcast** (red). Disabled during `.connecting`/`.stopping`
  (shows a spinner + label).
- A **status line** while `.live`: `● LIVE · HH:MM:SS · N dropped · congestion`
  from `streamHealth` (duration formatted; dropped = `skippedFrames`; congestion
  as a small bar/percent). Hidden when idle.
- The existing `OBSSection` (host/port/password/scene picker) remains for setup.

## 5. Data flow

```
tap Go Live → broadcastState=.connecting
  connectOBS() (launch+retry, NO StartStream)
    fail → errorMessage; .idle
    ok   → obs.startBroadcast(scene: stackSceneName):
              SetCurrentProgramScene(stack) ; StartStream ; poll GetStreamStatus until active (≤~5s)
           false → StopStream (reset OBS) ; "check OBS Settings→Stream" ; .idle  (OBS stays connected)
           true  → .live ; healthPollTask{ every 2s: streamHealth = obs.streamStatus() }
tap End Broadcast / End Session → .stopping → obs.stopBroadcast() ; cancel poll ; streamHealth=nil ; .idle
```

## 6. Error handling / edge cases

| Situation | Behavior |
|---|---|
| OBS not installed / won't launch / connect fails | `errorMessage`, `.idle`; session unaffected |
| Stream started but never goes active (bad/missing key) | after ~5 s, treat as failure; `errorMessage` points to OBS ▸ Settings ▸ Stream; `.idle` |
| Go Live tapped with no `stackSceneName` set | stream starts on OBS's current scene (scene step skipped); still broadcasts |
| End Session while live | broadcast auto-stopped before teardown |
| OBS disconnects mid-broadcast (crash) | `OBSController` error handling drops to `.disconnected`; poll sees no status → surface + `.idle` |
| Double-tap Go Live | guarded by `broadcastState == .idle` |
| App quit while live | unchanged quit-safety; deliberate End Session is the stop path |

## 7. Testing

`swift test --filter LiveAstroCoreTests`

- **`StreamHealth.parse` (TDD):** a realistic `GetStreamStatus` dict (outputActive
  true, outputDuration 754000, outputSkippedFrames 3, outputTotalFrames 1500,
  outputCongestion 0.2) → correct fields (duration 754.0 s, droppedFraction
  3/1500); missing `outputActive` → nil; congestion > 1 clamps to 1; absent
  optional numeric fields default to 0.
- **`OBSController.startBroadcast` (TDD, via `MockOBSSocket`):** with a scene →
  sends `SetCurrentProgramScene` then `StartStream`, and returns true when the
  mock's `GetStreamStatus` reports `outputActive: true`; returns false when the
  mock never reports active (confirm it doesn't hang — bounded polls). With a
  nil/empty scene → no `SetCurrentProgramScene`, still `StartStream`.
- **`OBSController.stopBroadcast` (TDD):** sends `StopStream` (and the
  record-off request). `streamStatus()` parses the mock response.
- **Manual/build-verified:** `AppModel.goLive/endBroadcast`, the health poll, the
  removal of bring-up from `startSession`, End-Session-stops-broadcast, the
  button/status UI, and the real YouTube round-trip (needs a live stream key —
  manual, on a real session). Confirm the existing OBS controller/quit-safety
  tests stay green after refactoring bring-up.

## 8. Non-goals (future builds)

In-app YouTube OAuth / stream-key entry / YouTube Live Streaming API (the Full
tier); scheduling/thumbnails/titles; multi-platform simulcast; recording-only
mode changes; auto-reconnect-and-resume a dropped broadcast; a broadcast-quality
picker (OBS owns encoding settings). Crop-to-overlap already ships and applies to
the broadcast frame — no work here.

## 9. Risks

| Risk | Mitigation |
|---|---|
| Removing auto-stream-on-session-start breaks an existing test/expectation | it's the intended behavior change; update the affected controller/AppModel test; the quit-safety invariant (disconnect never StopStreams) is preserved |
| Can't verify the YouTube key is configured | attempt + confirm `outputActive`; a clear actionable message on failure; documented best-effort |
| Health poll races End Broadcast | poll task cancelled in `endBroadcast`; loop exits when `broadcastState != .live`; `streamHealth` cleared |
| OBS auto-launch UX (OBS window pops up) | now only on Go Live (deliberate), not every session — a net improvement |
| `startBroadcast` polling hangs if OBS never answers | bounded poll count with per-poll timeout via the existing `requestData` timeout seam |
