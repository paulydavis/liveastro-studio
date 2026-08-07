import XCTest
@testable import LiveAstroCore

// MARK: - Shared obs-websocket frame scripting
//
// Frame builders and outbound-frame inspectors shared by OBSControllerTests
// and BroadcastControllerTests (extracted from OBSControllerTests so the
// broadcast lifecycle tests reuse the same mocked-socket machinery instead of
// duplicating it).

/// The server's Identified reply (op 2) to an Identify (op 1).
let identifiedFrame = #"{"op":2,"d":{"negotiatedRpcVersion":1}}"#

func helloFrame() -> String {
    frameJSON(["op": 0, "d": ["rpcVersion": 1]])
}

/// The server's Hello (op 0) WITH an authentication challenge (T5 preflight:
/// the local-config credential tests script a server that requires auth).
func helloFrame(salt: String, challenge: String) -> String {
    frameJSON(["op": 0, "d": ["rpcVersion": 1,
                              "authentication": ["salt": salt,
                                                 "challenge": challenge]]])
}

func responseFrame(requestId: String,
                   requestType: String = "X",
                   ok: Bool,
                   code: Int = 100,
                   responseData: [String: Any] = [:]) -> String {
    let d: [String: Any] = [
        "requestId": requestId,
        "requestType": requestType,
        "requestStatus": ["result": ok, "code": code],
        "responseData": responseData
    ]
    return frameJSON(["op": 7, "d": d])
}

func eventFrame(type: String, data: [String: Any]) -> String {
    frameJSON(["op": 5, "d": ["eventType": type, "eventData": data]])
}

private func frameJSON(_ obj: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: obj)
    return String(data: data, encoding: .utf8)!
}

func requestId(fromSent frame: String) -> String {
    field(frame, "requestId")
}

func requestType(fromSent frame: String) -> String {
    field(frame, "requestType")
}

/// The `requestData` payload of a sent op-6 request frame (T5 preflight: the
/// provisioning tests assert on CreateInput/SetInputSettings payloads).
func requestPayload(fromSent frame: String) -> [String: Any] {
    let obj = try! JSONSerialization.jsonObject(
        with: frame.data(using: .utf8)!) as! [String: Any]
    let d = obj["d"] as! [String: Any]
    return d["requestData"] as? [String: Any] ?? [:]
}

/// The `authentication` string of a sent Identify (op 1) frame, if any.
func identifyAuth(fromSent frame: String) -> String? {
    let obj = try! JSONSerialization.jsonObject(
        with: frame.data(using: .utf8)!) as! [String: Any]
    let d = obj["d"] as! [String: Any]
    return d["authentication"] as? String
}

private func field(_ frame: String, _ key: String) -> String {
    let obj = try! JSONSerialization.jsonObject(
        with: frame.data(using: .utf8)!) as! [String: Any]
    let d = obj["d"] as! [String: Any]
    return d[key] as! String
}

/// Poll a MainActor predicate until true or deadline (no wall-clock sleeps for
/// correctness — only for pacing the poll).
@MainActor
func waitUntil(_ predicate: () -> Bool,
               timeout: TimeInterval = 2,
               file: StaticString = #filePath,
               line: UInt = #line) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    XCTFail("waitUntil timed out", file: file, line: line)
}

// MARK: - ScriptedOBSServer

/// A mutable scripted OBS "server" for lifecycle tests.
///
/// Unlike the fixed responders in OBSControllerTests, this models the OBS
/// output state machine: StartStream/StopStream/StartRecord/StopRecord flip
/// `streamActive`/`recordActive` (when the corresponding `…ReactsToRequests`
/// flag is on), and GetStreamStatus/GetRecordStatus report the modeled state —
/// so bring-up confirm polls and stop confirm polls behave like real OBS.
///
/// Knobs:
/// - `…ReactsToRequests = false` models a stop/start whose request round-trips
///   ok but never takes effect (the review6 "unconfirmed stop" repro).
/// - `failTypes` answers those request types with `ok:false`.
/// - `parkTypes` leaves those requests unanswered; the (type, requestId) is
///   recorded in `parked` so a test can resume the exact request later with
///   `responseFrame(requestId:…)` — deterministic mid-await parking.
final class ScriptedOBSServer {

    var streamActive = false
    var recordActive = false
    var scenes = ["Stack", "Scope"]
    var currentScene = "Stack"
    var streamReactsToRequests = true
    var recordReactsToRequests = true
    /// T5 preflight modeling: scene contents, per-input settings, and the
    /// stream-service key the provisioning chain reads/writes. The defaults
    /// model a READY OBS — the capture input exists, targets the harness's
    /// broadcast-window id (4242), and a stream key is configured — so the
    /// pre-T5 lifecycle tests go live through the preflight chain unmodified,
    /// exactly as they would against a previously provisioned real OBS.
    /// CreateInput/CreateScene/SetInputSettings mutate this model additively
    /// (there is deliberately NO remove/rename modeling: the app never sends
    /// such requests, and the no-removal test pins that).
    var sceneItems: [[String: Any]] = [
        ["sourceName": "LiveAstro Stack", "inputKind": "screen_capture"]
    ]
    var inputSettings: [String: [String: Any]] = [
        "LiveAstro Stack": ["type": 1, "window": 4242]
    ]
    var streamKey = "k"
    var failTypes: Set<String> = []
    var parkTypes: Set<String> = []
    /// Answer the first N requests of a parked type NORMALLY before parking
    /// (review7: goLive reconciles with a GetStreamStatus/GetRecordStatus pair
    /// before StartStream, so tests that park the CONFIRM poll's
    /// GetStreamStatus skip the reconcile's with `parkSkip["GetStreamStatus"] = 1`).
    var parkSkip: [String: Int] = [:]
    private(set) var parked: [(type: String, id: String)] = []

    /// The reply hook to install via `mock.replyToLastSent(_:)`. Also answers
    /// the Identify (op 1) so `connect` succeeds.
    func responder() -> (String) -> String? {
        return { [self] sent in
            if sent.contains("\"op\":1") { return identifiedFrame }
            guard sent.contains("\"op\":6") else { return nil }
            let id = requestId(fromSent: sent)
            let type = requestType(fromSent: sent)
            if parkTypes.contains(type) {
                let skip = parkSkip[type] ?? 0
                if skip > 0 {
                    parkSkip[type] = skip - 1
                } else {
                    parked.append((type: type, id: id))
                    return nil
                }
            }
            if failTypes.contains(type) {
                return responseFrame(requestId: id, ok: false, code: 500)
            }
            switch type {
            case "GetSceneList":
                return responseFrame(requestId: id, ok: true, responseData: [
                    "currentProgramSceneName": currentScene,
                    "scenes": scenes.reversed().map { ["sceneName": $0] }   // OBS lists top→bottom
                ])
            case "GetStreamStatus":
                return responseFrame(requestId: id, ok: true, responseData: [
                    "outputActive": streamActive,
                    "outputDuration": 1000,
                    "outputTotalFrames": 100,
                    "outputSkippedFrames": 0,
                    "outputCongestion": 0
                ])
            case "GetRecordStatus":
                return responseFrame(requestId: id, ok: true,
                                     responseData: ["outputActive": recordActive])
            case "StartStream":
                if streamReactsToRequests { streamActive = true }
                return responseFrame(requestId: id, ok: true)
            case "StopStream":
                if streamReactsToRequests { streamActive = false }
                return responseFrame(requestId: id, ok: true)
            case "StartRecord":
                if recordReactsToRequests { recordActive = true }
                return responseFrame(requestId: id, ok: true)
            case "StopRecord":
                if recordReactsToRequests { recordActive = false }
                return responseFrame(requestId: id, ok: true)
            case "GetSceneItemList":
                return responseFrame(requestId: id, ok: true,
                                     responseData: ["sceneItems": sceneItems])
            case "GetInputSettings":
                let name = requestPayload(fromSent: sent)["inputName"] as? String ?? ""
                guard let settings = inputSettings[name] else {
                    return responseFrame(requestId: id, ok: false, code: 600)
                }
                return responseFrame(requestId: id, ok: true,
                                     responseData: ["inputSettings": settings])
            case "SetInputSettings":
                let payload = requestPayload(fromSent: sent)
                let name = payload["inputName"] as? String ?? ""
                let new = payload["inputSettings"] as? [String: Any] ?? [:]
                inputSettings[name] = (inputSettings[name] ?? [:])
                    .merging(new) { _, newer in newer }
                return responseFrame(requestId: id, ok: true)
            case "CreateInput":
                let payload = requestPayload(fromSent: sent)
                let name = payload["inputName"] as? String ?? ""
                sceneItems.append(["sourceName": name,
                                   "inputKind": payload["inputKind"] as? String ?? ""])
                inputSettings[name] = payload["inputSettings"] as? [String: Any] ?? [:]
                return responseFrame(requestId: id, ok: true)
            case "CreateScene":
                scenes.append(requestPayload(fromSent: sent)["sceneName"] as? String ?? "")
                return responseFrame(requestId: id, ok: true)
            case "GetStreamServiceSettings":
                return responseFrame(requestId: id, ok: true, responseData: [
                    "streamServiceType": "rtmp_common",
                    "streamServiceSettings": ["key": streamKey]
                ])
            default:
                // Covers SetCurrentProgramScene and anything else.
                return responseFrame(requestId: id, ok: true)
            }
        }
    }
}
