# OBS Broadcast Pre-flight Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One-button Go Live that provisions and verifies the whole OBS chain (launch → connect with auto-discovered credentials → capture source in the user's scene → stream key present → streaming) with a five-link status panel.

**Architecture:** `BroadcastController.goLive()` (already a generation-guarded staged flow) gains explicit pre-flight stages that publish a `PreflightState` value; `OBSLocalConfig` reads OBS's own WebSocket config so the password paste disappears; `OBSController` gains thin obs-websocket v5 provisioning primitives. All provisioning is additive and idempotent; nothing in OBS is ever deleted, renamed, or reordered.

**Tech Stack:** Swift 5.10 SPM, XCTest, existing `ScriptedOBSServer`/fixed-responder OBS test harness, obs-websocket 5.x over `URLSessionWebSocketTask`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-06-obs-broadcast-preflight-design.md` — binding.
- **Task 1 is a binding gate**: no provisioning code before the real-OBS settings-schema probe result is recorded.
- The app **never deletes, renames, or reorders** any OBS object. Only objects it may create/modify: input `"LiveAstro Stack"`, scene `"LiveAstro"` (only when the user has zero scenes).
- Stream key: presence check only — the value is **never logged, stored, or displayed**.
- `OBSLocalConfig` is read-only; the app never writes OBS config files.
- Quit-safety / bring-up-race invariants: existing tests in `BroadcastControllerTests.swift` and `OBSControllerTests.swift` must pass **unmodified**.
- Broadcast window title constant: `"LiveAstro Broadcast"` (set by `BroadcastWindowConfigurator`, `Sources/LiveAstroStudio/BroadcastView.swift:287`).
- One `swift test` run at a time (SPM build lock). Durable logs: `swift test 2>&1 | tee /tmp/las-<task>.log` and read the log — never trust a piped exit status.
- Commit trailer: end every commit body with `Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j` and no other trailer.

---

### Task 1: Real-OBS capture settings-schema probe (BINDING GATE)

**Files:**
- Modify: `Scripts/obs_smoke.swift` (add `--probe-capture` mode)
- Create: `docs/superpowers/reviews/2026-08-06-obs-capture-schema.md` (probe record)

**Interfaces:**
- Produces: the verbatim macOS capture `inputKind` string and the settings-JSON schema (window-binding keys) that Task 5 turns into `OBSCaptureSchema` constants.

This task needs OBS 32 running locally with the WebSocket server enabled. It is interactive: the runner creates a window capture by hand once, then the probe dumps its exact wire representation.

- [ ] **Step 1: Add the probe mode to obs_smoke.swift**

Append after the existing smoke-test argument parsing (the script already connects with host/port/password args; follow its existing connect helper):

```swift
// --probe-capture: dump every input's kind + settings so the provisioning
// schema is copied from a REAL OBS, not docs. Usage:
//   1. In OBS: add a "macOS Screen Capture" source to any scene, set
//      Method: Window Capture, pick the "LiveAstro Broadcast" window.
//   2. swift Scripts/obs_smoke.swift <port> <password> --probe-capture
if CommandLine.arguments.contains("--probe-capture") {
    let inputs = try await request("GetInputList", [:])
    guard let list = inputs["inputs"] as? [[String: Any]] else {
        fatalError("GetInputList: unexpected shape \(inputs)")
    }
    for input in list {
        let name = input["inputName"] as? String ?? "?"
        let kind = input["inputKind"] as? String ?? "?"
        let settings = try await request("GetInputSettings", ["inputName": name])
        print("=== input \(name) kind=\(kind)")
        print(String(data: try JSONSerialization.data(
            withJSONObject: settings["inputSettings"] ?? [:],
            options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
    exit(0)
}
```

- [ ] **Step 2: Run the probe against real OBS**

Launch the dist app (so the "LiveAstro Broadcast" window exists), open OBS, add the manual window-capture source per the comment, then:

Run: `swift Scripts/obs_smoke.swift 4455 "$(python3 -c "import json;print(json.load(open('$HOME/Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json'))['server_password'])")" --probe-capture`
Expected: a dump including the capture source with its `kind` (expected `screen_capture` on macOS OBS 30+) and settings keys showing how the window is addressed (`window` id and/or owner/name strings — record exactly what appears).

- [ ] **Step 3: Record the schema verbatim**

Write `docs/superpowers/reviews/2026-08-06-obs-capture-schema.md` containing: OBS version, the input kind string, the full pretty-printed settings JSON, and one sentence naming which key(s) bind the window (these become `OBSCaptureSchema` in Task 5). If the window is bound by an opaque numeric `window` id rather than a title/owner string pair, record BOTH the id-form and any name/title keys present — Task 5 needs a re-derivable binding, so the probe record must show how the title appears in settings.

- [ ] **Step 4: Commit**

```bash
git add Scripts/obs_smoke.swift docs/superpowers/reviews/2026-08-06-obs-capture-schema.md
git commit -m "Probe: real-OBS capture input settings schema (preflight T1 gate)"
```

### Task 2: PreflightState value type

**Files:**
- Create: `Sources/LiveAstroCore/OBS/PreflightState.swift`
- Test: `Tests/LiveAstroCoreTests/PreflightStateTests.swift`

**Interfaces:**
- Produces:
  - `public enum PreflightLink: CaseIterable, Sendable` — `.obsRunning, .connected, .sceneCapture, .streamService, .streaming`; `static let chainOrder: [PreflightLink]` in that order.
  - `public enum PreflightLinkStatus: Equatable, Sendable` — `.unknown, .checking, .ok, .failed(reason: String, remedy: String)`.
  - `public struct PreflightState: Equatable, Sendable` — `init()` (all `.unknown`); `subscript(_ link: PreflightLink) -> PreflightLinkStatus`; `mutating func set(_ link: PreflightLink, _ status: PreflightLinkStatus)`; `var firstNonGreen: PreflightLink?` (chain order); `mutating func reset()`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import LiveAstroCore

final class PreflightStateTests: XCTestCase {
    func testInitAllUnknown() {
        let s = PreflightState()
        for link in PreflightLink.allCases { XCTAssertEqual(s[link], .unknown) }
    }
    func testFirstNonGreenFollowsChainOrder() {
        var s = PreflightState()
        XCTAssertEqual(s.firstNonGreen, .obsRunning)
        s.set(.obsRunning, .ok); s.set(.connected, .ok)
        XCTAssertEqual(s.firstNonGreen, .sceneCapture)
        s.set(.sceneCapture, .failed(reason: "no capture", remedy: "run Go Live"))
        XCTAssertEqual(s.firstNonGreen, .sceneCapture)
        for link in PreflightLink.allCases { s.set(link, .ok) }
        XCTAssertNil(s.firstNonGreen)
    }
    func testResetReturnsAllUnknown() {
        var s = PreflightState()
        s.set(.streaming, .ok)
        s.reset()
        XCTAssertEqual(s, PreflightState())
    }
    func testChainOrderIsCompleteAndStable() {
        XCTAssertEqual(PreflightLink.chainOrder,
                       [.obsRunning, .connected, .sceneCapture, .streamService, .streaming])
        XCTAssertEqual(Set(PreflightLink.chainOrder), Set(PreflightLink.allCases))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter PreflightStateTests 2>&1 | tee /tmp/las-t2-red.log`
Expected: compile failure — `PreflightState` not defined.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// One link in the Go Live pre-flight chain (spec §1). Order matters:
/// `chainOrder` is the resume order for a halted Go Live.
public enum PreflightLink: String, CaseIterable, Sendable {
    case obsRunning, connected, sceneCapture, streamService, streaming
    public static let chainOrder: [PreflightLink] =
        [.obsRunning, .connected, .sceneCapture, .streamService, .streaming]
}

public enum PreflightLinkStatus: Equatable, Sendable {
    case unknown
    case checking
    case ok
    case failed(reason: String, remedy: String)
}

/// Published by `BroadcastController`; rendered dumbly by the status panel.
public struct PreflightState: Equatable, Sendable {
    private var statuses: [PreflightLink: PreflightLinkStatus]

    public init() {
        statuses = Dictionary(uniqueKeysWithValues:
            PreflightLink.allCases.map { ($0, .unknown) })
    }
    public subscript(_ link: PreflightLink) -> PreflightLinkStatus {
        statuses[link] ?? .unknown
    }
    public mutating func set(_ link: PreflightLink, _ status: PreflightLinkStatus) {
        statuses[link] = status
    }
    /// First link in chain order that is not `.ok` — where Go Live resumes.
    public var firstNonGreen: PreflightLink? {
        PreflightLink.chainOrder.first { self[$0] != .ok }
    }
    public mutating func reset() { self = PreflightState() }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter PreflightStateTests 2>&1 | tee /tmp/las-t2-green.log`
Expected: 4/4 PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/OBS/PreflightState.swift Tests/LiveAstroCoreTests/PreflightStateTests.swift
git commit -m "feat: PreflightState value type for the Go Live chain"
```

### Task 3: OBSLocalConfig read-only parser

**Files:**
- Create: `Sources/LiveAstroCore/OBS/OBSLocalConfig.swift`
- Test: `Tests/LiveAstroCoreTests/OBSLocalConfigTests.swift`

**Interfaces:**
- Produces: `public struct OBSLocalConfig: Equatable` — `serverEnabled: Bool`, `port: Int`, `password: String?`; `static func read(from url: URL) -> OBSLocalConfig?` (nil ⇔ absent/unreadable/corrupt); `static var defaultURL: URL`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import LiveAstroCore

final class OBSLocalConfigTests: XCTestCase {
    private func write(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("obs-ws-\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: url)
        return url
    }
    func testParsesNormalConfig() throws {
        let url = try write(#"{"server_enabled": true, "server_port": 4455, "server_password": "abc123", "auth_required": true}"#)
        let c = OBSLocalConfig.read(from: url)
        XCTAssertEqual(c, OBSLocalConfig(serverEnabled: true, port: 4455, password: "abc123"))
    }
    func testServerDisabled() throws {
        let url = try write(#"{"server_enabled": false, "server_port": 4455, "server_password": "abc"}"#)
        XCTAssertEqual(OBSLocalConfig.read(from: url)?.serverEnabled, false)
    }
    func testMissingFieldsUseDefaults() throws {
        // Absent port → 4455 default; absent password → nil; absent enabled → false.
        let url = try write(#"{}"#)
        let c = OBSLocalConfig.read(from: url)
        XCTAssertEqual(c, OBSLocalConfig(serverEnabled: false, port: 4455, password: nil))
    }
    func testCorruptFileReturnsNil() throws {
        let url = try write("not json {")
        XCTAssertNil(OBSLocalConfig.read(from: url))
    }
    func testAbsentFileReturnsNil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("definitely-missing-\(UUID().uuidString).json")
        XCTAssertNil(OBSLocalConfig.read(from: url))
    }
    func testDefaultURLPointsAtOBSPluginConfig() {
        XCTAssertTrue(OBSLocalConfig.defaultURL.path.hasSuffix(
            "Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter OBSLocalConfigTests 2>&1 | tee /tmp/las-t3-red.log`
Expected: compile failure — `OBSLocalConfig` not defined.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Read-only view of OBS's local WebSocket server config (spec §3). The app
/// NEVER writes this file. `read` returns nil for absent/unreadable/corrupt
/// files — callers fall back to the manual host/port/password fields.
public struct OBSLocalConfig: Equatable {
    public var serverEnabled: Bool
    public var port: Int
    public var password: String?

    public init(serverEnabled: Bool, port: Int, password: String?) {
        self.serverEnabled = serverEnabled
        self.port = port
        self.password = password
    }

    /// `~/Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json`
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json")
    }

    public static func read(from url: URL = defaultURL) -> OBSLocalConfig? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        return OBSLocalConfig(
            serverEnabled: dict["server_enabled"] as? Bool ?? false,
            port: dict["server_port"] as? Int ?? 4455,
            password: dict["server_password"] as? String)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter OBSLocalConfigTests 2>&1 | tee /tmp/las-t3-green.log`
Expected: 6/6 PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/OBS/OBSLocalConfig.swift Tests/LiveAstroCoreTests/OBSLocalConfigTests.swift
git commit -m "feat: OBSLocalConfig read-only WebSocket config discovery"
```

### Task 4: OBSController provisioning primitives

**Files:**
- Modify: `Sources/LiveAstroCore/OBS/OBSController.swift` (new public funcs after `setRecording`, before `streamStatus`)
- Test: `Tests/LiveAstroCoreTests/OBSControllerTests.swift` (append a `// MARK: - Provisioning` section following the file's existing fixed-responder harness pattern)

**Interfaces:**
- Consumes: private `requestData(_:_:)` (existing).
- Produces (all `@MainActor`, all return nil/false on failure via `requestData`'s nil):
  - `public struct OBSSceneItem: Equatable { public let inputName: String; public let inputKind: String }`
  - `public func sceneItemList(scene: String) async -> [OBSSceneItem]?`
  - `public func inputSettings(inputName: String) async -> [String: Any]?`
  - `public func setInputSettings(inputName: String, settings: [String: Any]) async -> Bool`
  - `public func createInput(scene: String, inputName: String, inputKind: String, settings: [String: Any]) async -> Bool`
  - `public func createScene(_ name: String) async -> Bool`
  - `public func sceneNames() async -> [String]?` (from existing `refreshScenes` plumbing — expose the fetch as a value return)
  - `public func streamServiceKeyPresent() async -> Bool?` (nil = unavailable; NEVER logs the key)

- [ ] **Step 1: Write the failing tests**

Follow the existing pattern in `OBSControllerTests.swift` (connect a controller to a `MockOBSSocket`/responder that answers hello + identify, then the request under test — copy the setup helper the file already uses; do not invent a new harness). Add:

```swift
// MARK: - Provisioning

func testSceneItemListParsesNameAndKind() async {
    // Responder: GetSceneItemList → {"sceneItems":[{"sourceName":"LiveAstro Stack","inputKind":"screen_capture"},{"sourceName":"Paul Camera","inputKind":"macos-avcapture"}]}
    // Assert: sceneItemList(scene: "Scene") == [OBSSceneItem(inputName:"LiveAstro Stack",inputKind:"screen_capture"), OBSSceneItem(inputName:"Paul Camera",inputKind:"macos-avcapture")]
    // Assert the sent request carried {"sceneName":"Scene"}.
}
func testCreateInputSendsSceneNameKindAndSettings() async {
    // CreateInput responds ok; assert sent request data == {"sceneName":"S","inputName":"LiveAstro Stack","inputKind":"screen_capture","inputSettings":{...}} and result true.
}
func testSetInputSettingsSendsOverlayTrue() async {
    // Assert sent data includes {"inputName":"LiveAstro Stack","overlay":true,"inputSettings":{...}}; result true.
}
func testCreateSceneSendsName() async { /* {"sceneName":"LiveAstro"} → true */ }
func testStreamServiceKeyPresentTrueWhenNonEmpty() async {
    // GetStreamServiceSettings → {"streamServiceSettings":{"key":"SECRET","server":"rtmps://..."}} → true
    // AND assert the controller's log sink never received a string containing "SECRET".
}
func testStreamServiceKeyPresentFalseWhenEmpty() async { /* key "" → false */ }
func testStreamServiceKeyPresentNilWhenRequestFails() async { /* responder returns error status → nil */ }
func testSceneNamesReturnsList() async { /* GetSceneList → ["Scene","LiveAstro"] */ }
```

Write these as real tests using the file's existing responder helper — the comments above specify responder payloads and assertions; the mechanics (frame builders, waitUntil) are already in `OBSTestScripting.swift`.

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter OBSControllerTests 2>&1 | tee /tmp/las-t4-red.log`
Expected: compile failure — `sceneItemList` not defined. Existing tests in the filter still compile-blocked; that is fine at the red step.

- [ ] **Step 3: Implement in OBSController.swift**

```swift
// MARK: - Provisioning primitives (preflight spec §3 — additive only; this
// controller deliberately has NO remove/delete/rename request anywhere).

public struct OBSSceneItem: Equatable {
    public let inputName: String
    public let inputKind: String
}

public func sceneItemList(scene: String) async -> [OBSSceneItem]? {
    guard let data = await requestData("GetSceneItemList", ["sceneName": scene]),
          let items = data["sceneItems"] as? [[String: Any]] else { return nil }
    return items.compactMap { item in
        guard let name = item["sourceName"] as? String else { return nil }
        return OBSSceneItem(inputName: name,
                            inputKind: item["inputKind"] as? String ?? "")
    }
}

public func inputSettings(inputName: String) async -> [String: Any]? {
    guard let data = await requestData("GetInputSettings", ["inputName": inputName])
    else { return nil }
    return data["inputSettings"] as? [String: Any] ?? [:]
}

public func setInputSettings(inputName: String, settings: [String: Any]) async -> Bool {
    await requestData("SetInputSettings",
                      ["inputName": inputName, "inputSettings": settings,
                       "overlay": true]) != nil
}

public func createInput(scene: String, inputName: String,
                        inputKind: String, settings: [String: Any]) async -> Bool {
    await requestData("CreateInput",
                      ["sceneName": scene, "inputName": inputName,
                       "inputKind": inputKind, "inputSettings": settings]) != nil
}

public func createScene(_ name: String) async -> Bool {
    await requestData("CreateScene", ["sceneName": name]) != nil
}

public func sceneNames() async -> [String]? {
    guard let data = await requestData("GetSceneList", nil),
          let scenes = data["scenes"] as? [[String: Any]] else { return nil }
    return scenes.compactMap { $0["sceneName"] as? String }
}

/// Presence-only stream-key check (spec §3). The key value never reaches a
/// log, a published property, or a thrown error — only this Bool leaves.
public func streamServiceKeyPresent() async -> Bool? {
    guard let data = await requestData("GetStreamServiceSettings", nil),
          let settings = data["streamServiceSettings"] as? [String: Any]
    else { return nil }
    let key = settings["key"] as? String ?? ""
    return !key.isEmpty
}
```

Note: `requestData` already logs the request TYPE on failure — that log never includes response payloads, so the key cannot leak through it. The test in Step 1 pins this.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter OBSControllerTests 2>&1 | tee /tmp/las-t4-green.log`
Expected: all pre-existing OBSControllerTests PASS unmodified + 8 new PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/OBS/OBSController.swift Tests/LiveAstroCoreTests/OBSControllerTests.swift
git commit -m "feat: OBSController v5 provisioning primitives (additive only)"
```

### Task 5: goLive pre-flight chain in BroadcastController

**Files:**
- Create: `Sources/LiveAstroCore/OBS/OBSCaptureSchema.swift`
- Modify: `Sources/LiveAstroCore/OBS/BroadcastController.swift` (`BroadcastDeps`, new published `preflight`, config-discovery + capture + stream-key stages wired into `goLive()`)
- Test: `Tests/LiveAstroCoreTests/BroadcastControllerTests.swift` (append `// MARK: - Preflight`)

**Interfaces:**
- Consumes: Task 2 `PreflightState`, Task 3 `OBSLocalConfig`, Task 4 primitives, Task 1 schema record.
- Produces:
  - `enum OBSCaptureSchema` — `static let inputKind: String`; `static func settings(windowTitle: String) -> [String: Any]`; `static func targetsWindow(_ settings: [String: Any], title: String) -> Bool`. **Constants verbatim from the Task 1 probe record** (`docs/superpowers/reviews/2026-08-06-obs-capture-schema.md`).
  - `BroadcastController.preflight: PreflightState` (observable, `private(set)`).
  - `BroadcastDeps` gains `public var openBroadcastWindow: () -> Void = {}` and `public var broadcastWindowTitleRegistered: () -> Bool = { true }` (app wires these in Task 6; defaults keep existing tests source-compatible).
  - `static let captureInputName = "LiveAstro Stack"`, `static let starterSceneName = "LiveAstro"` on `BroadcastController`.
  - `public var localConfigURLOverride: URL?` on `BroadcastController` (tests point it at fixtures; nil → `OBSLocalConfig.defaultURL`).

- [ ] **Step 1: Write the failing tests**

Append to `BroadcastControllerTests.swift`, using its existing controller+scripted-server setup helper (the file already builds a `BroadcastController` against the mock socket — reuse that fixture; each test scripts responder payloads for the request types it expects). Cases:

```swift
// MARK: - Preflight

func testGoLiveHappyChainTurnsAllLinksGreen() async {
    // Script: connect ok; GetStreamStatus/GetRecordStatus inactive;
    // GetSceneItemList → [{"sourceName":"LiveAstro Stack","inputKind":OBSCaptureSchema.inputKind}];
    // GetInputSettings → OBSCaptureSchema.settings(windowTitle:"LiveAstro Broadcast");
    // GetStreamServiceSettings → key "k"; StartStream ok + stream-started event.
    // Assert: broadcastState == .live and every PreflightLink is .ok.
}
func testAdoptByNameSkipsCreateAndRepair() async {
    // Same as happy chain. Assert sentRequestTypes contains NO "CreateInput"
    // and NO "SetInputSettings".
}
func testMistargetedCaptureIsRepairedNotRecreated() async {
    // GetInputSettings → OBSCaptureSchema.settings(windowTitle:"Some Other Window").
    // Assert exactly one "SetInputSettings" sent with settings where
    // OBSCaptureSchema.targetsWindow(_, title: "LiveAstro Broadcast"); no "CreateInput".
}
func testMissingCaptureIsCreatedIntoUsersScene() async {
    // GetSceneItemList → [{"sourceName":"Paul Camera","inputKind":"macos-avcapture"}].
    // Assert one "CreateInput" with sceneName == stackSceneName,
    // inputName == "LiveAstro Stack", inputKind == OBSCaptureSchema.inputKind.
}
func testNoScenesCreatesStarterScene() async {
    // stackSceneName = ""; GetSceneList → []. Assert "CreateScene"("LiveAstro")
    // then "CreateInput" into it, and stackSceneName == "LiveAstro" afterwards.
}
func testMissingStreamKeyHaltsChainRedWithRemedy() async {
    // GetStreamServiceSettings → key "". Assert preflight[.streamService] is
    // .failed with remedy containing "Settings" and "Stream"; NO "StartStream"
    // sent; broadcastState is NOT .live.
}
func testGoLiveResumesFromFirstNonGreen() async {
    // After the halt above, fix the responder (key "k") and goLive() again.
    // Assert the second attempt does NOT re-run CreateInput/SetInputSettings
    // (sceneCapture already .ok) and ends .live with all links green.
}
func testLocalConfigSuppliesPortAndPassword() async throws {
    // Write fixture config (enabled, port <mock's>, password "pw"); set
    // controller.localConfigURLOverride; leave obsPassword = "".
    // Assert the connect handshake authenticated with "pw" (server scripted to
    // require it) and the chain proceeds.
}
func testManualPasswordFieldOverridesLocalConfig() async throws {
    // Fixture password "wrong-from-file"; obsPassword = "manual-right".
    // Assert handshake used "manual-right".
}
func testServerDisabledInConfigFailsConnectedLinkWithRemedy() async throws {
    // Fixture {enabled:false}; obsPassword=""; connect refused by responder.
    // Assert preflight[.connected] == .failed and remedy mentions
    // "WebSocket Server Settings".
}
func testNoRemovalTypeRequestEverSent() async {
    // Run the happy, repair, create, and create-scene scenarios above against
    // a recording responder; assert the union of all sent request types
    // contains none of: "RemoveInput", "RemoveScene", "RemoveSceneItem",
    // "SetInputName", "SetSceneName".
}
func testCancellationMidChainLeavesNoStartStream() async {
    // Script sceneCapture stage to stall (delayed responder); call
    // endBroadcast()/disconnect() while stalled. Assert no "StartStream" was
    // ever sent and preflight resets to all .unknown on the next goLive().
}
```

Write real bodies from these specifications with the file's existing helpers; each comment names the responder script and the assertions — none may be skipped.

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter BroadcastControllerTests 2>&1 | tee /tmp/las-t5-red.log`
Expected: compile failure — `preflight` / `OBSCaptureSchema` not defined.

- [ ] **Step 3: Implement OBSCaptureSchema**

```swift
import Foundation

/// Wire schema for the macOS window-capture input, copied VERBATIM from the
/// Task-1 probe of real OBS 32 (docs/superpowers/reviews/2026-08-06-obs-
/// capture-schema.md). If the probe record and these constants disagree, the
/// probe record wins — re-run the probe before editing here.
enum OBSCaptureSchema {
    static let inputKind = "<VERBATIM FROM PROBE — expected \"screen_capture\">"

    /// Settings that bind the capture to the broadcast window by title.
    static func settings(windowTitle: String) -> [String: Any] {
        // <VERBATIM KEYS FROM PROBE> — e.g. ["type": 2, "window_name": windowTitle, ...]
        // The implementer fills the exact dictionary from the probe record.
        [:]
    }

    /// Does an existing input's settings target our window?
    static func targetsWindow(_ settings: [String: Any], title: String) -> Bool {
        // Compare the probe-identified binding key(s) against `title`.
        false
    }
}
```

The two bodies are filled from the probe record — the plan cannot know OBS's exact keys ahead of the gate; the probe record is the single source, and the Task-5 reviewer must diff the constants against `2026-08-06-obs-capture-schema.md`.

- [ ] **Step 4: Implement the stages in BroadcastController**

Additions (names exact; wire-in points described relative to the existing `goLive()` at `BroadcastController.swift:608`):

```swift
public private(set) var preflight = PreflightState()
public var localConfigURLOverride: URL?
public static let captureInputName = "LiveAstro Stack"
public static let starterSceneName = "LiveAstro"

/// Stage 0 (before connectOBS): discover local credentials. Manual field wins;
/// otherwise adopt the config file's port/password. serverEnabled=false is a
/// hard, remediable failure of the `.connected` link.
private func applyLocalConfigDiscovery() -> Bool {
    guard obsPassword.isEmpty,
          let cfg = OBSLocalConfig.read(from: localConfigURLOverride
                                        ?? OBSLocalConfig.defaultURL)
    else { return true }        // no file / manual override → existing fields
    guard cfg.serverEnabled else {
        preflight.set(.connected, .failed(
            reason: "OBS WebSocket server is disabled",
            remedy: "OBS → Tools → WebSocket Server Settings → Enable (one time)"))
        return false
    }
    obsPort = cfg.port
    if let pw = cfg.password { obsPassword = pw }
    discoveredPasswordFromConfig = cfg.password != nil
    return true
}
private var discoveredPasswordFromConfig = false

/// Stage 3: ensure the selected stack scene carries our capture source
/// (adopt-by-name → adopt-by-target → repair → create; spec §3). Additive
/// only. Returns false on any OBS refusal (link set .failed inside).
private func ensureCaptureStage(gen: Int) async -> Bool {
    preflight.set(.sceneCapture, .checking)
    deps.openBroadcastWindow()
    // Bounded wait for the window-server title (OBS binds by title).
    for _ in 0..<20 where !deps.broadcastWindowTitleRegistered() {
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard gen == broadcastGeneration, !Task.isCancelled else { return false }
    }
    var scene = stackSceneName
    if scene.isEmpty {
        guard let names = await obs.sceneNames(), gen == broadcastGeneration
        else { return failCapture("Could not list OBS scenes",
                                  "Check the OBS connection, then Go Live again") }
        if let first = names.first {
            scene = first
        } else {
            guard await obs.createScene(Self.starterSceneName),
                  gen == broadcastGeneration
            else { return failCapture("Could not create a starter scene",
                                      "Create any scene in OBS, then Go Live again") }
            scene = Self.starterSceneName
        }
        stackSceneName = scene
    }
    guard let items = await obs.sceneItemList(scene: scene),
          gen == broadcastGeneration
    else { return failCapture("Could not read scene '\(scene)'",
                              "Check the OBS connection, then Go Live again") }
    let title = "LiveAstro Broadcast"
    if items.contains(where: { $0.inputName == Self.captureInputName }) {
        // Adopt by name; repair only if mistargeted.
        guard let settings = await obs.inputSettings(inputName: Self.captureInputName),
              gen == broadcastGeneration
        else { return failCapture("Could not read the capture source",
                                  "Check the OBS connection, then Go Live again") }
        if !OBSCaptureSchema.targetsWindow(settings, title: title) {
            guard await obs.setInputSettings(
                    inputName: Self.captureInputName,
                    settings: OBSCaptureSchema.settings(windowTitle: title)),
                  gen == broadcastGeneration
            else { return failCapture("Could not retarget the capture source",
                                      "Point '\(Self.captureInputName)' at the LiveAstro Broadcast window in OBS") }
            deps.log("OBS: repaired '\(Self.captureInputName)' → LiveAstro Broadcast window")
        }
    } else if let adopted = await adoptCaptureByTarget(items: items, title: title, gen: gen) {
        if !adopted { return false }        // failure already recorded
    } else {
        guard await obs.createInput(scene: scene, inputName: Self.captureInputName,
                                    inputKind: OBSCaptureSchema.inputKind,
                                    settings: OBSCaptureSchema.settings(windowTitle: title)),
              gen == broadcastGeneration
        else { return failCapture("Could not add the capture source to '\(scene)'",
                                  "Add a macOS Screen Capture of the LiveAstro Broadcast window to that scene") }
        deps.log("OBS: added '\(Self.captureInputName)' to scene '\(scene)'")
    }
    preflight.set(.sceneCapture, .ok)
    return true
}

/// Adopt any existing capture-kind input already pointing at our window
/// (pre-existing user setups keep their own source name). Returns nil when
/// no candidate exists (caller creates), true on adopt, false on failure.
private func adoptCaptureByTarget(items: [OBSSceneItem],
                                  title: String, gen: Int) async -> Bool? {
    for item in items where item.inputKind == OBSCaptureSchema.inputKind {
        guard let settings = await obs.inputSettings(inputName: item.inputName),
              gen == broadcastGeneration else { return false }
        if OBSCaptureSchema.targetsWindow(settings, title: title) {
            deps.log("OBS: adopted existing capture '\(item.inputName)'")
            preflight.set(.sceneCapture, .ok)
            return true
        }
    }
    return nil
}

private func failCapture(_ reason: String, _ remedy: String) -> Bool {
    preflight.set(.sceneCapture, .failed(reason: reason, remedy: remedy))
    deps.log("OBS preflight: \(reason)")
    return false
}

/// Stage 4: stream service configured (presence only; spec §3).
private func streamServiceStage(gen: Int) async -> Bool {
    preflight.set(.streamService, .checking)
    guard let present = await obs.streamServiceKeyPresent(),
          gen == broadcastGeneration
    else {
        preflight.set(.streamService, .failed(
            reason: "Could not read the stream service settings",
            remedy: "Check the OBS connection, then Go Live again"))
        return false
    }
    guard present else {
        preflight.set(.streamService, .failed(
            reason: "No stream key configured in OBS",
            remedy: "OBS → Settings → Stream → connect YouTube (one time)"))
        return false
    }
    preflight.set(.streamService, .ok)
    return true
}
```

Wire-in (each bullet is an edit inside the existing `goLive()` task closure — the surrounding generation guards and semantics are already there; the stages slot between them):

1. At entry (before `broadcastGeneration += 1`): links already `.ok` from a halted attempt stay (resume semantics); a fresh attempt from `.idle`/`.unknown` with `preflight.firstNonGreen == .obsRunning` calls `preflight.reset()`. Then `guard applyLocalConfigDiscovery() else { broadcastState = origin; return }`.
2. Around `connectOBS(gen:)`: set `.obsRunning`/`.connected` to `.checking` before, and on success both `.ok`; on failure set the failed link (`connectOBS` returning false with OBS never reachable → `.obsRunning` failed with remedy "Install/launch OBS, then Go Live"; reachable-but-auth-failed → `.connected` failed with remedy "Paste the password from OBS → Tools → WebSocket Server Settings"). Auth-failure with `discoveredPasswordFromConfig` → clear `obsPassword`, re-read config once, retry connect before failing (regenerated-password case, spec §3).
3. After `reconcile` returns `.bothInactive` and before `startBroadcast`: `guard await ensureCaptureStage(gen: gen) else { broadcastState = teardownLanding(from: origin); return }` then the same for `streamServiceStage(gen:)`.
4. Around `startBroadcast`: `.streaming` `.checking` → `.confirmedLive` sets `.ok`; other outcomes set `.failed` with the existing error text as reason.
5. `sessionDidEnd`/`disconnect`/`endBroadcast` cancellation paths: no preflight writes needed beyond the entry reset — cancelled attempts leave links as they were; the next fresh goLive resets.

- [ ] **Step 5: Run to verify pass**

Run: `swift test --filter BroadcastControllerTests 2>&1 | tee /tmp/las-t5-green.log`
Expected: every pre-existing BroadcastControllerTests case PASS **unmodified** + all new Preflight cases PASS.

- [ ] **Step 6: Run the OBS-adjacent suites**

Run: `swift test --filter "OBSControllerTests|OBSClientTests|BroadcastControllerTests" 2>&1 | tee /tmp/las-t5-obs.log`
Expected: all PASS; grep the log for `error:` (expect zero matches — remember grep exits 1 on no match, that is success).

- [ ] **Step 7: Commit**

```bash
git add Sources/LiveAstroCore/OBS/OBSCaptureSchema.swift Sources/LiveAstroCore/OBS/BroadcastController.swift Tests/LiveAstroCoreTests/BroadcastControllerTests.swift
git commit -m "feat: goLive pre-flight chain — config discovery, capture provisioning, stream-key check"
```

### Task 6: Status panel UI, app wiring, Help recipes

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift` (OBSSection, ~line 974)
- Modify: `Sources/LiveAstroStudio/AppModel.swift` (wire `openBroadcastWindow` / `broadcastWindowTitleRegistered` into `BroadcastDeps`)
- Modify: `Sources/LiveAstroStudio/Resources/Help.md` (broadcast recipes)
- Test: build + existing suites (SwiftUI section is view-only; logic already tested in Task 5)

**Interfaces:**
- Consumes: `model.broadcast.preflight` (Task 5), `PreflightLink.chainOrder`, `PreflightLinkStatus`.

- [ ] **Step 1: Wire the window deps in AppModel**

Where `BroadcastDeps` is constructed in `AppModel.swift`, add:

```swift
deps.openBroadcastWindow = { [weak self] in self?.surface.openBroadcastWindow() }
deps.broadcastWindowTitleRegistered = {
    NSApp.windows.contains { $0.title == "LiveAstro Broadcast" }
}
```

(`surface.openBroadcastWindow` is the existing openWindow("broadcast") path used by Detach; if `AppSurface` lacks it, add the closure property there following its existing fields and set it in `LiveAstroApp`/`MainView` where `openWindow` is in scope.)

- [ ] **Step 2: Render the chain in OBSSection**

Inside `OBSSection` (ControlView.swift:974), above the existing Connect/Go Live controls:

```swift
VStack(alignment: .leading, spacing: 4) {
    ForEach(PreflightLink.chainOrder, id: \.self) { link in
        let status = model.broadcast.preflight[link]
        HStack(spacing: 6) {
            switch status {
            case .unknown:  Image(systemName: "circle").foregroundStyle(.secondary)
            case .checking: ProgressView().controlSize(.mini)
            case .ok:       Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:   Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
            Text(label(for: link))
            if case .failed(let reason, let remedy) = status {
                Text("— \(reason). \(remedy)")
                    .font(.caption).foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }
}
.padding(.vertical, 4)
```

with

```swift
private func label(for link: PreflightLink) -> String {
    switch link {
    case .obsRunning:    return "OBS running"
    case .connected:     return "Connected"
    case .sceneCapture:  return "Stack scene capture"
    case .streamService: return "Stream service"
    case .streaming:     return "Streaming"
    }
}
```

Password field `.help` text updates to mention auto-discovery: "Auto-filled from OBS's local settings when left empty; paste manually only for remote OBS."

- [ ] **Step 3: Help recipes**

Append to `Resources/Help.md` a `## Broadcast setups` section with four short recipes (camera PiP via Video Capture Device source drag-resized over the stack; Seestar/ASIAIR phone app via AirPlay mirroring to the Mac + window capture; NINA via window/display capture; multi-scene combos + the stall auto-switch). Each recipe is 2–4 lines of steps — documentation, no code. State the boundary sentence from the spec: "LiveAstro guarantees only its own 'LiveAstro Stack' source; everything else in your scenes is yours."

- [ ] **Step 4: Build + run app-adjacent tests**

Run: `swift build 2>&1 | tee /tmp/las-t6-build.log && swift test --filter "BroadcastControllerTests|PreflightStateTests" 2>&1 | tee /tmp/las-t6-tests.log`
Expected: build clean; suites PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroStudio/ControlView.swift Sources/LiveAstroStudio/AppModel.swift Sources/LiveAstroStudio/Resources/Help.md
git commit -m "feat: pre-flight status panel, window-dep wiring, broadcast recipes"
```

### Task 7: Full-suite gate + manual smoke + changelog

**Files:**
- Modify: `CHANGELOG.md`
- No source changes expected (fix-forward only if the gate finds drift)

- [ ] **Step 1: Full suite**

Run: `swift test 2>&1 | tee /tmp/las-t7-full.log; tail -5 /tmp/las-t7-full.log`
Expected: 0 failures (suite ≈ 880+ tests; the 6 known env-skips are fine). Any failure is adjudicated (stale pin vs regression) before proceeding — record the adjudication in the commit body.

- [ ] **Step 2: Release build**

Run: `swift build -c release --scratch-path /private/tmp/las-release-build 2>&1 | tail -3`
Expected: clean build (local scratch path dodges the iCloud build.db issue).

- [ ] **Step 3: Manual smoke against real OBS (with the operator)**

With OBS running: fresh Go Live from a cold start must walk the panel green end-to-end without touching OBS by hand (stream key already linked). Kill cases to eyeball: OBS closed (auto-launch), wrong manual password cleared to empty (auto-discovery), capture source deleted in OBS beforehand (re-created), stream key removed (red link + remedy). Record results in the PR/merge notes.

- [ ] **Step 4: Changelog + commit**

Add under Unreleased: "One-button Go Live: pre-flight status panel, OBS WebSocket auto-discovery (no password paste), automatic capture-source provisioning/repair (additive only), stream-key presence check."

```bash
git add CHANGELOG.md
git commit -m "docs: changelog for OBS broadcast pre-flight"
```
