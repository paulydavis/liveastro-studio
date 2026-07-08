# OBS WebSocket Automation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** LiveAstro drives OBS over obs-websocket 5.x — auto-launch, stream/record control, manual + stall-based scene switching — per spec `docs/superpowers/specs/2026-07-08-obs-websocket-automation-design.md`.

**Architecture:** New `LiveAstroCore/OBS/` module: a transport-protocol seam (`OBSSocket`) so the handshake/auth/request-correlation client is fully unit-testable against a mock; `OBSController` state machine on top; `StallDetector` pure logic. App layer owns OBS process launch (NSWorkspace) and the Control-window OBS section.

**Tech Stack:** Swift 5.10, XCTest, Foundation + CryptoKit (system framework — SHA-256 for the auth challenge; same standing as Accelerate). Zero third-party deps.

## Global Constraints

- Zero external dependencies; `LiveAstroCore` stays UI-free (no SwiftUI/AppKit). CryptoKit and Network/URLSession are system frameworks and permitted.
- Every OBS operation failure is a logged status change, never an error thrown into the stacking/session path. `connect()` is the sole exception (reports success/failure for the launch flow).
- `disconnect()` and app-quit NEVER send StopStream — only End Session ends a broadcast.
- obs-websocket op codes: Hello=0, Identify=1, Identified=2, Event=5, Request=6, RequestResponse=7. rpcVersion 1. Default `localhost:4455`.
- Auth string = `base64(sha256(base64(sha256(password+salt)) + challenge))`.
- All existing tests stay green (116 executed / 1 skipped). Run `swift test` per task.
- Commits may carry the `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` trailer.

## File Map

```
Sources/LiveAstroCore/OBS/OBSAuth.swift          (new)
Sources/LiveAstroCore/OBS/OBSMessage.swift       (new)
Sources/LiveAstroCore/OBS/OBSSocket.swift         (new: protocol + URLSession impl)
Sources/LiveAstroCore/OBS/OBSClient.swift         (new)
Sources/LiveAstroCore/OBS/OBSController.swift     (new)
Sources/LiveAstroCore/OBS/StallDetector.swift     (new)
Sources/LiveAstroStudio/AppModel.swift            (modify: own OBSController, session hooks, OBS launch)
Sources/LiveAstroStudio/ControlView.swift         (modify: OBS section)
Tests/LiveAstroCoreTests/OBS*Tests.swift          (new, one per component)
```

---

### Task 1: OBSAuth — challenge/response hashing

**Files:**
- Create: `Sources/LiveAstroCore/OBS/OBSAuth.swift`
- Test: `Tests/LiveAstroCoreTests/OBSAuthTests.swift`

**Interfaces:**
- Produces: `enum OBSAuth { static func authString(password: String, salt: String, challenge: String) -> String }`

- [ ] **Step 1: Write failing test.** The expected vector is computed from the documented algorithm; this value is the reference (verify it once against the obs-websocket spec's own example if available, else compute with a one-off python `hashlib` script and paste the constant).

```swift
import XCTest
import Crypto
@testable import LiveAstroCore

final class OBSAuthTests: XCTestCase {
    func testKnownVector() {
        // password "supersecretpassword", salt "PZVbYpvAnZut2SS6JNJytDm9",
        // challenge "ztTBnnuqrqaKDzRM3xcVdbYm" → documented obs-websocket example.
        let auth = OBSAuth.authString(password: "supersecretpassword",
                                      salt: "PZVbYpvAnZut2SS6JNJytDm9",
                                      challenge: "ztTBnnuqrqaKDzRM3xcVdbYm")
        XCTAssertEqual(auth, "Dj2cKZM8y0evPvJXbwG3cTdSWc3n7fCUpQmDp7YuQFw=")
    }

    func testDeterministic() {
        let a = OBSAuth.authString(password: "p", salt: "s", challenge: "c")
        let b = OBSAuth.authString(password: "p", salt: "s", challenge: "c")
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.isEmpty)
    }
}
```

- [ ] **Step 2: Run** `swift test --filter OBSAuthTests` — compile failure.

- [ ] **Step 3: Implement.**

```swift
import Foundation
import Crypto

/// obs-websocket 5.x authentication (spec §3):
/// base64( sha256( base64(sha256(password + salt)) + challenge ) )
public enum OBSAuth {
    public static func authString(password: String, salt: String, challenge: String) -> String {
        let secret = base64Sha256(password + salt)
        return base64Sha256(secret + challenge)
    }

    private static func base64Sha256(_ s: String) -> String {
        Data(SHA256.hash(data: Data(s.utf8))).base64EncodedString()
    }
}
```

*Implementer note:* `import Crypto` is the CryptoKit module name under SwiftPM on macOS; if the build cannot resolve it, use `import CryptoKit` (both expose `SHA256`). Confirm which resolves and use it consistently in tests too.

- [ ] **Step 4: Run** `swift test --filter OBSAuthTests` — PASS. If the known vector fails, recompute it with `python3 -c "import hashlib,base64; ..."` and correct the constant — the algorithm, not the test, is authoritative.
- [ ] **Step 5: Full suite green; commit** `feat: OBS auth challenge hashing`

### Task 2: OBSMessage — codable protocol frames

**Files:**
- Create: `Sources/LiveAstroCore/OBS/OBSMessage.swift`
- Test: `Tests/LiveAstroCoreTests/OBSMessageTests.swift`

**Interfaces:**
- Produces: encode/decode helpers for the op frames used. Because `d` payloads are heterogeneous, use `JSONSerialization` for request-data dictionaries and small `Codable` structs for the fixed-shape frames (Hello, Identify, Identified).

```swift
public enum OBSOpCode: Int { case hello = 0, identify = 1, identified = 2, event = 5, request = 6, requestResponse = 7 }

public struct OBSHello: Decodable {           // d of op 0
    public struct Auth: Decodable { public let challenge: String; public let salt: String }
    public let rpcVersion: Int
    public let authentication: Auth?          // absent when OBS has no password
}
public struct OBSRequestResponse {            // d of op 7 (parsed loosely)
    public let requestId: String
    public let requestType: String
    public let ok: Bool
    public let code: Int
    public let comment: String?
    public let responseData: [String: Any]
}
```

- Provide `OBSMessage.identify(rpcVersion:auth:eventSubscriptions:) -> String` (JSON text for op 1), `OBSMessage.request(type:id:data:) -> String` (op 6), and `OBSMessage.parse(_ text: String) -> ParsedFrame` where `ParsedFrame` is an enum `.hello(OBSHello) / .identified / .event(type:String,data:[String:Any]) / .response(OBSRequestResponse) / .unknown`.

- [ ] **Step 1: Write failing tests** — encode an Identify with auth and assert the JSON has `op:1`, `d.rpcVersion:1`, `d.authentication:"..."`, `d.eventSubscriptions:<int>`; parse a captured Hello-with-auth JSON string and assert challenge/salt; parse a RequestResponse JSON and assert `requestId`, `ok` from `requestStatus.result`, and a value dug out of `responseData`; parse an Event JSON and assert `.event` with the right `eventType` and a data field.

(Provide real captured JSON strings as fixtures inline — the obs-websocket 5.x message shapes are stable and documented; e.g. Hello: `{"op":0,"d":{"obsWebSocketVersion":"5.x","rpcVersion":1,"authentication":{"challenge":"c","salt":"s"}}}`.)

- [ ] **Step 2:** compile failure. **Step 3:** implement with `Codable` for fixed frames and `JSONSerialization` for the loose `d` dictionaries; map `requestStatus.result` (Bool) → `ok`, `requestStatus.code` (Int), `requestStatus.comment` (String?). **Step 4:** PASS. **Step 5:** full suite green; commit `feat: OBS protocol message encode/decode`

### Task 3: StallDetector — pure timing logic

**Files:**
- Create: `Sources/LiveAstroCore/OBS/StallDetector.swift`
- Test: `Tests/LiveAstroCoreTests/StallDetectorTests.swift`

**Interfaces:**
- Produces:
```swift
public struct StallDetector {
    public init(subExposureSeconds: Double, multiplier: Double = 3, minimumInterval: TimeInterval = 90)
    public mutating func recordUpdate(at date: Date)
    public func isStalled(at date: Date) -> Bool
    public var threshold: TimeInterval { get }   // max(multiplier*sub, minimum)
}
```

- [ ] **Step 1: Write failing tests** (dates via `Date(timeIntervalSince1970:)`):

```swift
func testThresholdIsMaxOfScaledAndFloor() {
    XCTAssertEqual(StallDetector(subExposureSeconds: 20).threshold, 90, accuracy: 1e-9) // 3*20=60 < 90
    XCTAssertEqual(StallDetector(subExposureSeconds: 60).threshold, 180, accuracy: 1e-9) // 3*60=180 > 90
}
func testNotStalledBeforeThreshold() {
    var d = StallDetector(subExposureSeconds: 60) // threshold 180
    d.recordUpdate(at: Date(timeIntervalSince1970: 1000))
    XCTAssertFalse(d.isStalled(at: Date(timeIntervalSince1970: 1000 + 179)))
    XCTAssertTrue(d.isStalled(at: Date(timeIntervalSince1970: 1000 + 181)))
}
func testRecordResetsClock() {
    var d = StallDetector(subExposureSeconds: 60)
    d.recordUpdate(at: Date(timeIntervalSince1970: 1000))
    d.recordUpdate(at: Date(timeIntervalSince1970: 1170))   // fresh update
    XCTAssertFalse(d.isStalled(at: Date(timeIntervalSince1970: 1170 + 179)))
}
func testStalledWhenNoUpdateEver() {
    let d = StallDetector(subExposureSeconds: 60)
    XCTAssertFalse(d.isStalled(at: Date(timeIntervalSince1970: 0)))  // no baseline yet → not stalled
}
```

- [ ] **Step 2:** compile failure. **Step 3:** implement (store `lastUpdate: Date?`; `isStalled` = `lastUpdate` non-nil AND `now - lastUpdate > threshold`; no baseline → false). **Step 4:** PASS. **Step 5:** commit `feat: stall detector for scene automation`

### Task 4: OBSSocket protocol + URLSession implementation

**Files:**
- Create: `Sources/LiveAstroCore/OBS/OBSSocket.swift`
- Test: `Tests/LiveAstroCoreTests/OBSSocketMockTests.swift` (tests the MOCK contract used by later tasks; the URLSession impl is validated in the Task 8 smoke test)

**Interfaces:**
```swift
public protocol OBSSocket: AnyObject {
    func connect(url: URL) async throws
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close()
}
public final class URLSessionOBSSocket: OBSSocket { public init() ; /* wraps URLSessionWebSocketTask */ }
```

- [ ] **Step 1:** Provide a `MockOBSSocket` in the test target: a scripted queue of inbound frames plus a recorded list of sent frames; `receive()` awaits/pops the next scripted inbound (supporting "server pushes N frames"), `send` records. Write a test proving the mock's send-record and scripted-receive ordering, so later tasks build on a trusted double.
- [ ] **Step 2:** compile failure. **Step 3:** implement the protocol + `URLSessionOBSSocket` (create `URLSessionWebSocketTask`, `resume()`, bridge `send(.string)`/`receive()` async, `close(withCode:)`). The mock lives in tests. **Step 4:** mock test PASS. **Step 5:** commit `feat: OBS socket transport seam + mock`

### Task 5: OBSClient — handshake + request correlation

**Files:**
- Create: `Sources/LiveAstroCore/OBS/OBSClient.swift`
- Test: `Tests/LiveAstroCoreTests/OBSClientTests.swift`

**Interfaces:**
```swift
public actor OBSClient {
    public init(socket: OBSSocket)
    public func connect(url: URL, password: String?) async throws     // Hello→Identify→Identified
    public func request(_ type: String, data: [String: Any]?) async throws -> [String: Any]  // responseData or throw
    public var events: AsyncStream<(type: String, data: [String: Any])> { get }
    public func disconnect()
    public enum OBSError: Error, Equatable { case notConnected, timeout, requestFailed(code: Int, comment: String?), authFailed }
}
```

Behavior: `connect` sends Identify (with auth string computed from Hello's salt/challenge via `OBSAuth`, or no auth when Hello lacks `authentication`), waits for Identified. A receive loop routes op 7 to the pending continuation keyed by `requestId` (UUID), op 5 into `events`. `request` throws `.timeout` after 10 s, `.requestFailed` on `ok == false`.

- [ ] **Step 1: Write failing tests over MockOBSSocket:**
  - `testHandshakeNoAuth`: script Hello(no auth) then Identified → `connect` succeeds, sent frames include an Identify with no `authentication`.
  - `testHandshakeWithAuth`: script Hello(salt/challenge) then Identified → sent Identify carries the exact `OBSAuth.authString` value.
  - `testRequestResponseCorrelation`: after connect, call `request("GetVersion", nil)`; script a RequestResponse with the matching requestId and `responseData:{obsVersion:"30.0"}` → returns that dict. (Grab the requestId from the recorded sent frame to script the response — the mock supports a hook to reply to the last-sent id.)
  - `testRequestFailureThrows`: script a response with `requestStatus.result=false, code=604` → `request` throws `.requestFailed(604, _)`.
  - `testEventRouting`: script an Event frame → `events` yields `("StreamStateChanged", data)`.
- [ ] **Step 2:** compile failure. **Step 3:** implement the actor. **Step 4:** PASS. **Step 5:** full suite green; commit `feat: OBS client — handshake, request correlation, events`

### Task 6: OBSController — state machine + high-level ops

**Files:**
- Create: `Sources/LiveAstroCore/OBS/OBSController.swift`
- Test: `Tests/LiveAstroCoreTests/OBSControllerTests.swift`

**Interfaces:**
```swift
@MainActor public final class OBSController: ObservableObject {
    public enum OBSState: Equatable { case disconnected, connecting, connected, streaming }
    @Published public private(set) var state: OBSState = .disconnected
    @Published public private(set) var isRecording = false
    @Published public private(set) var sceneNames: [String] = []
    @Published public private(set) var currentScene: String?
    public var onLog: ((String) -> Void)?

    public init(makeClient: @escaping (OBSSocket) -> OBSClient = { OBSClient(socket: $0) },
                makeSocket: @escaping () -> OBSSocket = { URLSessionOBSSocket() })
    public func connect(host: String, port: Int, password: String?) async -> Bool
    public func disconnect()                    // never stops the stream
    public func refreshScenes() async
    public func setScene(_ name: String) async
    public func startStream() async
    public func stopStream() async
    public func setRecording(_ on: Bool) async
}
```

Behavior: `connect` builds `ws://host:port`, drives the client, on success `refreshScenes` + `GetStreamStatus`/`GetRecordStatus` to seed state, subscribes to the `events` stream to keep `currentScene`/`state`/`isRecording` live. All ops except `connect` swallow errors into `onLog`. Reconnect/backoff is driven by AppModel (Task 7) calling `connect` again — keep the controller's ops idempotent and status-driven.

- [ ] **Step 1: Write failing tests** injecting a mock socket via `makeSocket` (script the whole session): connect seeds `sceneNames` from a GetSceneList response and sets `.connected`; `startStream` moves to `.streaming` on the StreamStateChanged event; an out-of-band `CurrentProgramSceneChanged` event updates `currentScene`; `disconnect` never emits a StopStream frame (assert the recorded sent frames contain no `StopStream`). Reconnect convergence: after a scripted drop+reconnect, state re-seeds from fresh status responses.
- [ ] **Step 2:** compile failure. **Step 3:** implement. **Step 4:** PASS. **Step 5:** commit `feat: OBS controller state machine`

### Task 7: AppModel integration — session choreography + launch

**Files:**
- Modify: `Sources/LiveAstroStudio/AppModel.swift`
- Test: build only (app target has no test target) — logic that can be unit-tested (StallDetector wiring) is already covered in Core.

Behavior (mirror existing AppModel idiom — read it fully first):
- Own `let obs = OBSController()`, `@Published` OBS config (`obsHost="localhost"`, `obsPort=4455`, `obsPassword=""`, `obsAutoLaunch=true`, `obsRecord=false`, `sceneAutomationOn=false`, `stackSceneName`, `scopeSceneName`), wired `obs.onLog` → `log.append`.
- `startSession()`: after the pipeline starts, spawn `Task { await bringUpOBS() }`. `bringUpOBS`: if `obs.state == .disconnected`, `await obs.connect(...)`; on failure and `obsAutoLaunch`, launch OBS via `NSWorkspace.shared.openApplication(at:)` for bundle id `com.obsproject.obs-studio` (fallback `Process`/`open -a OBS`), then retry `connect` every 2 s until success or a 20 s budget elapses; on connect → `await obs.startStream()`, `if obsRecord { await obs.setRecording(true) }`, `if !stackSceneName.isEmpty { await obs.setScene(stackSceneName) }`. Every failure logs; session continues regardless.
- Scene automation: a 15 s `Timer` (only while a session runs and `sceneAutomationOn`) drives a `StallDetector` (seeded from the profile's `subExposureSeconds`); on transition-into-stalled → `await obs.setScene(scopeSceneName)` once; the pipeline's `onUpdate`/accepted callback calls `stall.recordUpdate` and, if currently showing the scope scene due to a stall, `await obs.setScene(stackSceneName)` once. Respect a manual override flag set when a `CurrentProgramSceneChanged` event arrives that the automation didn't cause.
- `endSession()`: existing flow (pipeline end → replay) runs FIRST; then `Task { await obs.stopStream(); await obs.setRecording(false) }`.
- App quit / abort: do NOT call stopStream.

- [ ] **Step 1:** implement per above. **Step 2:** `swift build` clean; `swift test` still 116/1-skip (no core regressions). **Step 3:** commit `feat: OBS session choreography + auto-launch in AppModel`

### Task 8: ControlView OBS section + real-connection smoke test

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift`
- Create: `Scripts/obs_smoke.swift` (headless connect check against real OBS)
- Modify: `README.md` (OBS automation section + manual validation checklist)

- [ ] **Step 1: ControlView "OBS" section** (match existing form idiom): status line (● state + REC dot), Connect/Disconnect button, host/port/password fields (disabled while connected), scene `Picker` fed by `obs.sceneNames` + ↻ refresh, Record `Toggle`, automation `Toggle` + Stack/Scope scene `Picker`s, Auto-launch `Toggle`. Build clean.
- [ ] **Step 2: Headless smoke test** `Scripts/obs_smoke.swift` — compiled against the release LiveAstroCore objects (same shim pattern as the validation scripts): read a password from `argv[1]`, `OBSController.connect(host:"localhost",port:4455,...)`, print state + `sceneNames` + obsVersion, `startStream()`, wait 3 s, `stopStream()`, exit. This validates the URLSession socket + real auth against the live server (confirmed listening on 4455).
- [ ] **Step 3: Run the smoke test** (Paul supplies the OBS password): `swift build -c release && xcrun swiftc Scripts/obs_smoke.swift -I .build/release/Modules .build/release/LiveAstroCore.build/*.o -framework Network -o /tmp/obs_smoke && /tmp/obs_smoke "<password>"`. Expected: connects, lists the scene "Scene", reports OBS 32.1.2, stream starts/stops (OBS shows the stream indicator). Record the result in the README.
- [ ] **Step 4: README** — document the OBS section, the Tools→WebSocket enablement one-time step, and the manual validation checklist from spec §5 (auth, cold auto-launch, stream toggle, scene automation via fakesiril stall, accidental-quit-leaves-stream-alive).
- [ ] **Step 5:** full suite green; commit `feat: OBS control UI + real-connection smoke validation`
