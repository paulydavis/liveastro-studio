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
        return { sent in
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

    // Frame builders/inspectors (identifiedFrame, helloFrame, responseFrame,
    // eventFrame, requestId/requestType(fromSent:)) and waitUntil live in
    // OBSTestScripting.swift, shared with BroadcastControllerTests.

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
        mock.replyToLastSent { sent in
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

    // MARK: - Broadcast helper

    /// Build a fully connected OBSController whose responder is pre-scripted to
    /// answer SetCurrentProgramScene / StartStream / StopStream with ok:true, and
    /// GetStreamStatus with outputActive set to `streamStatusActive`.
    private func makeConnectedController(
        streamStatusActive: Bool
    ) async throws -> (OBSController, MockOBSSocket) {
        let mock = MockOBSSocket()
        let controller = makeController(mock)

        mock.enqueueInbound(helloFrame())
        mock.replyToLastSent { sent in
            // Identify → Identified
            if sent.contains("\"op\":1") { return identifiedFrame }
            guard sent.contains("\"op\":6") else { return nil }
            let id = requestId(fromSent: sent)
            let type = requestType(fromSent: sent)
            switch type {
            case "GetSceneList":
                return responseFrame(requestId: id, ok: true, responseData: [
                    "currentProgramSceneName": "Stack",
                    "scenes": [["sceneName": "Stack"]]
                ])
            case "GetStreamStatus":
                return responseFrame(requestId: id, ok: true, responseData: [
                    "outputActive": streamStatusActive,
                    "outputDuration": 1000,
                    "outputTotalFrames": 100,
                    "outputSkippedFrames": 0,
                    "outputCongestion": 0
                ])
            case "GetRecordStatus":
                return responseFrame(requestId: id, ok: true,
                                     responseData: ["outputActive": false])
            default:
                // Covers SetCurrentProgramScene, StartStream, StopStream,
                // StartRecord, StopRecord, and anything else.
                return responseFrame(requestId: id, ok: true, responseData: [:])
            }
        }

        let ok = await controller.connect(host: "localhost", port: 4455, password: nil)
        XCTAssertTrue(ok, "makeConnectedController: connect must succeed")
        return (controller, mock)
    }

    // MARK: - Broadcast tests

    func testStartBroadcastSendsSceneThenStreamAndConfirmsActive() async throws {
        let (controller, mock) = try await makeConnectedController(streamStatusActive: true)
        let outcome = await controller.startBroadcast(scene: "Stack", confirmPollSeconds: 0, maxConfirmPolls: 3)
        XCTAssertEqual(outcome, .confirmedLive)
        let types = mock.sentFrames.filter { $0.contains("\"op\":6") }
                                   .map { requestType(fromSent: $0) }
        XCTAssertTrue(types.contains("SetCurrentProgramScene"))
        XCTAssertTrue(types.contains("StartStream"))
        // SetCurrentProgramScene comes before StartStream
        XCTAssertLessThan(types.firstIndex(of: "SetCurrentProgramScene")!,
                          types.firstIndex(of: "StartStream")!)
        XCTAssertFalse(types.contains("StopStream"))   // success must NOT stop the stream
        controller.disconnect()
    }

    func testStartBroadcastNoSceneSkipsSetScene() async throws {
        let (controller, mock) = try await makeConnectedController(streamStatusActive: true)
        _ = await controller.startBroadcast(scene: nil as String?, confirmPollSeconds: 0, maxConfirmPolls: 3)
        let types = mock.sentFrames.filter { $0.contains("\"op\":6") }
                                   .map { requestType(fromSent: $0) }
        XCTAssertFalse(types.contains("SetCurrentProgramScene"))
        XCTAssertTrue(types.contains("StartStream"))
        controller.disconnect()
    }

    func testStartBroadcastNeverActiveReturnsIssuedUnconfirmedAndSendsNoStop() async throws {
        // GetStreamStatus always reports outputActive:false → give up, return
        // .issuedUnconfirmed (review8: StartStream WAS sent, so the boundary is
        // "issued but never confirmed"), and send NOTHING further. Review7 P1:
        // the CALLER owns cleanup — an internal StopStream-on-expiry here fired
        // before the caller's generation check could run, so a stale attempt
        // could kill a newer broadcast's stream.
        let (controller, mock) = try await makeConnectedController(streamStatusActive: false)
        let outcome = await controller.startBroadcast(scene: "Stack", confirmPollSeconds: 0, maxConfirmPolls: 3)
        XCTAssertEqual(outcome, .issuedUnconfirmed)
        let types = mock.sentFrames.filter { $0.contains("\"op\":6") }
                                   .map { requestType(fromSent: $0) }
        XCTAssertTrue(types.contains("StartStream"))
        XCTAssertFalse(types.contains("StopStream"),
                       "startBroadcast must not stop on failure — the caller owns cleanup")
        controller.disconnect()
    }

    /// Review8 item 1: a startBroadcast whose task is already cancelled at the
    /// issuance boundary returns .notIssued and sends NO StartStream — the
    /// conservative boundary's only "confirmed not sent" case.
    func testStartBroadcastCancelledBeforeIssuanceReturnsNotIssued() async throws {
        let (controller, mock) = try await makeConnectedController(streamStatusActive: false)
        let task = Task { await controller.startBroadcast(scene: nil as String?,
                                                          confirmPollSeconds: 0,
                                                          maxConfirmPolls: 1) }
        task.cancel()   // before the body runs — we're on the same actor
        let outcome = await task.value
        XCTAssertEqual(outcome, .notIssued)
        try? await Task.sleep(nanoseconds: 30_000_000)
        let types = mock.sentFrames.filter { $0.contains("\"op\":6") }
                                   .map { requestType(fromSent: $0) }
        XCTAssertFalse(types.contains("StartStream"),
                       "a .notIssued outcome guarantees StartStream was never sent")
        controller.disconnect()
    }

    func testStopBroadcastSendsStopStream() async throws {
        // streamStatusActive stays true, so the stop is (deliberately) never
        // confirmed here — confirm with 1 instant poll; this test only pins
        // that StopStream is sent. Confirmation semantics are pinned in
        // BroadcastControllerTests.
        let (controller, mock) = try await makeConnectedController(streamStatusActive: true)
        await controller.stopBroadcast(confirmPollSeconds: 0, maxConfirmPolls: 1)
        let types = mock.sentFrames.filter { $0.contains("\"op\":6") }
                                   .map { requestType(fromSent: $0) }
        XCTAssertTrue(types.contains("StopStream"))
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