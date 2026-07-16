# LiveAstro Studio — OBS WebSocket Automation Design

**Date:** 2026-07-08 · **Status:** draft for review

## 1. Goal

LiveAstro drives OBS over its built-in WebSocket server so a session night is
one button: Start Session launches OBS if needed, starts the stream (and
recording when enabled), switches scenes automatically when the sky misbehaves,
and End Session stops the stream after the final held frame. Full production
control from the Control window — stream, recording, manual scene picker —
without touching OBS mid-session.

## 2. Decisions (made 2026-07-08 with Paul)

| Decision | Choice |
|---|---|
| Scope | **Full production control**: stream sync, recording toggle, manual scene picker, scene automation |
| OBS unreachable at session start | **Auto-launch OBS**, wait for WebSocket (20 s budget); if still unreachable, **warn and continue** — OBS never blocks astronomy |
| Scene automation | **Stall-based**: no accepted stack update for `3 × subExposure` (min 90 s) → cut to the configured scope scene; next accepted update → cut back to the stack scene. Toggleable; scene names chosen from OBS's live scene list |
| Failure semantics | Every OBS operation failure = log line + status change; never an error into the stacking/session path |
| Dependencies | None added. Transport: `URLSessionWebSocketTask`. Auth hashing: CryptoKit (system framework, same standing as Accelerate) |
| Config storage | Host/port/password in `UserDefaults` (`localhost:4455` defaults). The password guards LAN-local OBS control, not a remote account; Keychain migration is a deliberate non-goal for now, noted in §8 |

## 3. Protocol facts (obs-websocket 5.x, ships in OBS 28+)

- WebSocket at `ws://host:4455`, JSON messages `{op, d}`.
- Handshake: server sends **Hello (op 0)** — includes `authentication.challenge`
  + `.salt` when a password is set; client sends **Identify (op 1)** with
  `rpcVersion: 1`, optional `authentication` string, and an
  `eventSubscriptions` bitmask; server confirms **Identified (op 2)**.
- Auth string: `base64(sha256(base64(sha256(password + salt)) + challenge))`.
- **Request (op 6)** carries `requestType`, `requestId`, `requestData`;
  **RequestResponse (op 7)** echoes `requestId` with `requestStatus` + data.
- **Event (op 5)** delivers subscribed events.
- Requests used: `GetVersion`, `GetSceneList`, `SetCurrentProgramScene`,
  `StartStream`, `StopStream`, `GetStreamStatus`, `StartRecord`, `StopRecord`,
  `GetRecordStatus`.
- Events used: `CurrentProgramSceneChanged`, `StreamStateChanged`,
  `RecordStateChanged` (subscriptions: Scenes | Outputs).

## 4. Architecture

```
LiveAstroCore/OBS/                       LiveAstroStudio
  OBSMessage.swift   (codable op frames)   AppModel: owns OBSController,
  OBSAuth.swift      (challenge math)        launches OBS via NSWorkspace,
  OBSSocket.swift    (transport protocol     session choreography hooks
                      + URLSession impl)   ControlView: OBS section
  OBSClient.swift    (handshake, request/
                      response correlation,
                      event routing)
  OBSController.swift(state machine, recon-
                      nect, high-level ops)
  StallDetector.swift(pure timing logic)
```

### 4.1 OBSSocket (transport seam — the testability boundary)

```swift
public protocol OBSSocket: AnyObject {
    func connect(url: URL) async throws
    func send(_ text: String) async throws
    func receive() async throws -> String     // next text frame
    func close()
}
```

`URLSessionOBSSocket` is the production implementation. Tests inject a mock
that scripts Hello/Identified/RequestResponse frames — the entire client above
the socket is unit-testable with no OBS.

### 4.2 OBSClient

- `connect(host:port:password:)`: dials, performs Hello→Identify→Identified
  (computing the auth string via `OBSAuth.authString(password:salt:challenge:)`),
  then starts a receive loop routing op 7 to pending requests (by `requestId`,
  a UUID) and op 5 to an `events` AsyncStream.
- `request(_ type: String, data: [String: Any]? ) async throws -> OBSResponse`
  — throws `OBSError.requestFailed(code:comment:)` on non-success status,
  `OBSError.timeout` after 10 s, `OBSError.notConnected` when the socket is down.
- Single writer/reader actor isolation (an `actor` or a serial queue) so
  requests never interleave frames.

### 4.3 OBSController

Published state (observed by AppModel):

```swift
public enum OBSState: Equatable {
    case disconnected
    case connecting
    case connected           // identified, idle
    case streaming
}
public private(set) var state: OBSState
public private(set) var isRecording: Bool
public private(set) var sceneNames: [String]
public private(set) var currentScene: String?
```

Operations (all `async`, all failure-logging rather than throwing to callers,
except `connect` which reports success/failure for the launch flow):
`connect`, `disconnect`, `refreshScenes`, `setScene(_:)`, `startStream`,
`stopStream`, `setRecording(_:)`.

Reconnect: while a LiveAstro session is running, a dropped socket retries with
backoff (2 s → 4 s → 8 s, cap 15 s); on re-identify it re-queries stream/record
status so the UI state converges rather than assumes. Outside a session, a drop
just moves state to `.disconnected`.

### 4.4 StallDetector (pure logic)

```swift
public struct StallDetector {
    public init(subExposureSeconds: Double, multiplier: Double = 3, minimumInterval: TimeInterval = 90)
    public mutating func recordUpdate(at date: Date)
    public func isStalled(at date: Date) -> Bool   // no update for max(multiplier×sub, minimum)
}
```

AppModel ticks it from a 15 s timer during native/watcher sessions:
stalled & automation-on & scope scene configured → `setScene(scopeScene)` once;
next accepted update → `setScene(stackScene)` once. Manual scene changes made
in OBS (seen via `CurrentProgramSceneChanged`) suspend automation until the
next stall/resume boundary crossing, so a human override isn't fought.

### 4.5 Session choreography (AppModel)

- **Start Session** (both modes): after the pipeline starts, spawn the OBS
  bring-up task — if `OBSController.state == .disconnected`, try `connect`;
  on connection-refused and auto-launch enabled, `NSWorkspace` launches OBS
  (bundle id `com.obsproject.obs-studio`, fallback `open -a OBS`), then retry
  connect every 2 s within a 20 s budget. Connected → `startStream` (+
  `setRecording(true)` when the Record toggle is on) → switch to the stack
  scene when configured. Any step failing → log + status; session unaffected.
- **End Session**: stop stream/recording FIRST is wrong — the broadcast holds
  the final frame; order is: pipeline `end()` completes (replay rendered) →
  `stopStream`/`setRecording(false)`. A "say goodnight over the final frame"
  gap is preserved by stopping only when the user's End Session flow finishes,
  matching today's manual timing.
- **Quit/abort**: `disconnect()` never touches the stream — an accidental app
  quit must not kill a live broadcast.

### 4.6 Control window (ControlView)

New "OBS" section:
- Status line: ● Disconnected / Connecting… / Connected / Streaming (+ REC dot)
- Connect/Disconnect button; host, port, password fields (defaults
  `localhost` / `4455` / empty), disabled while connected
- Scene picker (Menu/Picker fed by `sceneNames`, shows `currentScene`) + ↻ refresh
- Record toggle (applies immediately when connected; else applies at session start)
- Automation: on/off toggle + "Stack scene" and "Scope scene" pickers
- Auto-launch OBS toggle (default on)

## 5. Testing

1. **OBSAuth**: fixed vectors — password/salt/challenge triples with
   precomputed expected auth strings (computed once with a reference
   implementation; committed as constants).
2. **OBSClient over MockOBSSocket**: handshake happy path; auth-required path;
   wrong-password path (server closes → `connect` throws); request/response
   correlation with out-of-order responses; request timeout; event routing.
3. **StallDetector**: pure-logic table tests (no update → stalls at exactly
   max(3×sub, 90); update resets; boundary equality).
4. **OBSController state machine over mock**: connect→streaming→drop→reconnect
   re-queries status; scene automation one-shot semantics (no repeated
   setScene spam while stalled).
5. **Manual validation (documented in README dev section)**: real OBS —
   password auth, auto-launch from cold, stream start/stop against the
   Twitch/YouTube "bandwidth test" mode, scene automation with fakesiril
   stalled mid-run, accidental-quit leaves stream alive.
   UNTESTABLE in unit scope: real OBS process lifecycle, real network auth —
   documented per house rules.

## 6. Performance / footprint

Negligible: one WebSocket, JSON frames of <1 KB, a 15 s timer. No impact on
the stacking path.

## 7. Non-goals

Keychain storage for the OBS password (LAN-local control credential; revisit
if profiles ever sync), multiple simultaneous OBS instances, OBS profile/
scene-collection management, virtual camera control, streaming-service key
management (stays in OBS), video preview of OBS output inside LiveAstro.

## 8. Risks

| Risk | Mitigation |
|---|---|
| obs-websocket protocol drift | v5 stable since OBS 28 (2022); `GetVersion` logged at connect; requests used are core-stable |
| Auto-launch races (OBS starts but WebSocket server lags) | retry-connect loop inside the 20 s budget; budget exhausted → warn-and-continue |
| Scene automation fighting the human | manual scene change (event-observed) suspends automation until the next stall boundary |
| Stream killed by accident | `disconnect()` and app-quit never send StopStream; only End Session does |
| Password in UserDefaults | documented non-goal; LAN-local credential |
