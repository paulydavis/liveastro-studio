import XCTest
@testable import LiveAstroCore

/// Tests for OBSController — the @MainActor state machine over OBSClient.
///
/// The whole OBS session is scripted through `MockOBSSocket`, injected via the
/// controller's `makeSocket` hook. The mock's `replyToLastSent` hook answers
/// each outbound frame (Identify, GetSceneList, GetStreamStatus, …) with a
/// matching inbound frame, so a single scripted responder drives the handshake
/// and the seed requests deterministically.
@MainActor
final class OBSControllerTests: XCTestCase {

    // MARK: - Frame scripting

    /// A scripted responder that answers every op-1/op-6 frame the controller
    /// sends during connect + seed, keyed by requestType. Returns nil for
    /// anything it doesn't recognize (e.g. an outbound StopStream we want to
    /// prove is never sent — its absence is asserted separately).
    private func sessionResponder(
        scenes: [String] = ["Scene A", "Scene B"],
        currentScene: String = "Scene A",
        streaming: Bool = false,
        recording: Bool = false
    ) -> (String) -> String? {
        return { [self] sent in
            // Identify → Identified.
            if sent.contains("\"op\":1") { return identifiedFrame }
            guard sent.contains("\"op\":6") else { return nil }
            let id = requestId(fromSent: sent)
            let type = requestType(fromSent: sent)
            switch type {
            case "GetSceneList":
                let sceneList = scenes.reversed().map { ["sceneName": $0] }  // OBS lists top→bottom
                return responseFrame(requestId: id, ok: true, responseData: [
                    "currentProgramSceneName": currentScene,
                    "scenes": sceneList
                ])
            case "GetStreamStatus":
                return responseFrame(requestId: id, ok: true,
                                     responseData: ["outputActive": streaming])
            case "GetRecordStatus":
                return responseFrame(requestId: id, ok: true,
                                     responseData: ["outputActive": recording])
            case "SetCurrentProgramScene", "StartStream", "StopStream", "SetStream",
                 "StartRecord", "StopRecord":
                return responseFrame(requestId: id, ok: true, responseData: [:])
            default:
                return responseFrame(requestId: id, ok: true, responseData: [:])
            }
        }
    }

    private let identifiedFrame = #"{"op":2,"d":{"negotiatedRpcVersion":1}}"#

    private func responseFrame(requestId: String,
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
        return json(["op": 7, "d": d])
    }

    private func helloFrame() -> String {
        json(["op": 0, "d": ["rpcVersion": 1]])
    }

    private func eventFrame(type: String, data: [String: Any]) -> String {
        json(["op": 5, "d": ["eventType": type, "eventData": data]])
    }

    private func json(_ obj: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }

    private func requestId(fromSent frame: String) -> String {
        field(frame, "requestId")
    }
    private func requestType(fromSent frame: String) -> String {
        field(frame, "requestType")
    }
    private func field(_ frame: String, _ key: String) -> String {
        let obj = try! JSONSerialization.jsonObject(
            with: frame.data(using: .utf8)!) as! [String: Any]
        let d = obj["d"] as! [String: Any]
        return d[key] as! String
    }

    // MARK: - Controller factory

    /// Build a controller whose socket is `mock` and whose client uses a short
    /// request timeout (so any accidental hang fails fast instead of at 10 s).
    private func makeController(_ mock: MockOBSSocket) -> OBSController {
        OBSController(
            makeClient: { OBSClient(socket: $0, requestTimeout: 1) },
            makeSocket: { mock }
        )
    }

    /// Script Hello + a full session responder, then connect.
    private func connect(_ controller: OBSController,
                         _ mock: MockOBSSocket,
                         scenes: [String] = ["Scene A", "Scene B"],
                         currentScene: String = "Scene A",
                         streaming: Bool = false,
                         recording: Bool = false) async -> Bool {
        mock.enqueueInbound(helloFrame())
        mock.replyToLastSent(sessionResponder(
            scenes: scenes, currentScene: currentScene,
            streaming: streaming, recording: recording))
        return await controller.connect(host: "localhost", port: 4455, password: nil)
    }

    /// Poll a MainActor predicate until true or deadline.
    private func waitUntil(_ predicate: () -> Bool,
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

    // MARK: - Tests

    /// connect seeds sceneNames + currentScene and sets state .connected.
    func testConnectSeedsScenesAndState() async {
        let mock = MockOBSSocket()
        let controller = makeController(mock)

        let ok = await connect(controller, mock,
                               scenes: ["Cam", "Stars"], currentScene: "Cam")
        XCTAssertTrue(ok)
        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(controller.sceneNames, ["Cam", "Stars"])
        XCTAssertEqual(controller.currentScene, "Cam")
        XCTAssertFalse(controller.isRecording)

        controller.disconnect()
    }

    /// connect that seeds a streaming=true status lands in .streaming.
    func testConnectSeedsStreamingState() async {
        let mock = MockOBSSocket()
        let controller = makeController(mock)

        let ok = await connect(controller, mock, streaming: true)
        XCTAssertTrue(ok)
        XCTAssertEqual(controller.state, .streaming)

        controller.disconnect()
    }

    /// startStream → controller reaches .streaming when the StreamStateChanged
    /// event arrives (state is event-driven, not assumed from the request).
    func testStartStreamReachesStreamingOnEvent() async {
        let mock = MockOBSSocket()
        let controller = makeController(mock)
        _ = await connect(controller, mock)
        XCTAssertEqual(controller.state, .connected)

        // When StartStream is sent, also push a StreamStateChanged(active) event.
        mock.replyToLastSent { [self] sent in
            guard sent.contains("\"op\":6") else { return nil }
            let id = requestId(fromSent: sent)
            let type = requestType(fromSent: sent)
            if type == "StartStream" {
                mock.enqueueInbound(eventFrame(type: "StreamStateChanged",
                                               data: ["outputActive": true]))
            }
            return responseFrame(requestId: id, ok: true)
        }

        await controller.startStream()
        await waitUntil { controller.state == .streaming }
        XCTAssertEqual(controller.state, .streaming)

        controller.disconnect()
    }

    /// An out-of-band CurrentProgramSceneChanged event updates currentScene.
    func testOutOfBandSceneChangeUpdatesCurrentScene() async {
        let mock = MockOBSSocket()
        let controller = makeController(mock)
        _ = await connect(controller, mock,
                          scenes: ["A", "B"], currentScene: "A")
        XCTAssertEqual(controller.currentScene, "A")

        mock.enqueueInbound(eventFrame(type: "CurrentProgramSceneChanged",
                                       data: ["sceneName": "B"]))
        await waitUntil { controller.currentScene == "B" }
        XCTAssertEqual(controller.currentScene, "B")

        controller.disconnect()
    }

    /// A RecordStateChanged event updates isRecording live.
    func testRecordStateChangedEventUpdatesFlag() async {
        let mock = MockOBSSocket()
        let controller = makeController(mock)
        _ = await connect(controller, mock)
        XCTAssertFalse(controller.isRecording)

        mock.enqueueInbound(eventFrame(type: "RecordStateChanged",
                                       data: ["outputActive": true]))
        await waitUntil { controller.isRecording }
        XCTAssertTrue(controller.isRecording)

        controller.disconnect()
    }

    /// CRITICAL INVARIANT: disconnect() must emit NO StopStream frame.
    func testDisconnectSendsNoStopStream() async {
        let mock = MockOBSSocket()
        let controller = makeController(mock)
        _ = await connect(controller, mock, streaming: true)
        XCTAssertEqual(controller.state, .streaming)

        controller.disconnect()

        // Give any (erroneous) async send a chance to record before asserting.
        try? await Task.sleep(nanoseconds: 20_000_000)
        let sawStopStream = mock.sentFrames.contains { $0.contains("StopStream") }
        XCTAssertFalse(sawStopStream,
                       "disconnect() must never send StopStream — the stream keeps running")
    }

    /// Reconnect convergence: after a scripted drop the controller converges to
    /// .disconnected, and a fresh connect re-seeds state from new status.
    func testReconnectReseedsState() async {
        let mock1 = MockOBSSocket()
        var current = mock1
        // makeSocket returns whatever `current` points at, so a second connect
        // gets a fresh scripted socket.
        let controller = OBSController(
            makeClient: { OBSClient(socket: $0, requestTimeout: 1) },
            makeSocket: { current }
        )

        _ = await connect(controller, mock1, scenes: ["A"], currentScene: "A")
        XCTAssertEqual(controller.sceneNames, ["A"])

        // Scripted drop: make the client's receive loop fail.
        mock1.finishWithError(OBSSocketError.notConnected)

        // A request now fails; the controller converges to .disconnected.
        await controller.refreshScenes()
        await waitUntil { controller.state == .disconnected }
        XCTAssertEqual(controller.state, .disconnected)

        // Reconnect against a fresh socket with different scenes.
        let mock2 = MockOBSSocket()
        current = mock2
        let ok = await connect(controller, mock2,
                               scenes: ["X", "Y", "Z"], currentScene: "Y")
        XCTAssertTrue(ok)
        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(controller.sceneNames, ["X", "Y", "Z"])
        XCTAssertEqual(controller.currentScene, "Y")

        controller.disconnect()
    }

    /// connect failure (bad handshake) returns false and leaves .disconnected.
    func testConnectFailureReturnsFalse() async {
        let mock = MockOBSSocket()
        let controller = makeController(mock)

        // Hello, then answer the Identify with a wrong frame (not Identified) →
        // the handshake fails deterministically instead of hanging.
        mock.enqueueInbound(helloFrame())
        mock.replyToLastSent { sent in
            sent.contains("\"op\":1") ? #"{"op":5,"d":{"eventType":"Nope","eventData":{}}}"# : nil
        }
        let ok = await controller.connect(host: "localhost", port: 4455, password: nil)
        XCTAssertFalse(ok)
        XCTAssertEqual(controller.state, .disconnected)
    }
}