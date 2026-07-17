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

    private final class WeakBox<T: AnyObject> {
        weak var value: T?
        init(_ value: T?) { self.value = value }
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

    /// Phase 3 teardown fallback: if a connected controller is dropped without
    /// an explicit disconnect, it must still tear down its OBSClient/socket.
    /// Otherwise the receive loop and WebSocket can outlive the UI owner.
    func testDroppingConnectedControllerDisconnectsClient() async {
        let mock = MockOBSSocket()
        var controller: OBSController? = makeController(mock)
        let weakController = WeakBox(controller)
        _ = await connect(controller!, mock)

        controller = nil
        await waitUntil { weakController.value == nil }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertGreaterThanOrEqual(mock.closeCount, 1,
                                    "deinit must close the current OBS client/socket")
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

    // MARK: - review8 item 2: connect coalescing + epoch guarding

    /// Two rapid connects coalesce onto ONE in-flight attempt: a single
    /// handshake (one Identify), both callers get the same successful result.
    /// Pre-fix the second connect() tore down the first mid-handshake.
    func testConcurrentConnectsCoalesceToOneHandshake() async {
        let mock = MockOBSSocket()
        let controller = makeController(mock)
        mock.enqueueInbound(helloFrame())
        mock.replyToLastSent(sessionResponder())

        async let first = controller.connect(host: "localhost", port: 4455, password: nil)
        async let second = controller.connect(host: "localhost", port: 4455, password: nil)
        let (a, b) = await (first, second)

        XCTAssertTrue(a)
        XCTAssertTrue(b, "the second caller must await the same attempt's result")
        let identifies = mock.sentFrames.filter { $0.contains("\"op\":1") }.count
        XCTAssertEqual(identifies, 1, "two rapid connects must coalesce into one handshake")
        XCTAssertEqual(controller.state, .connected)
        controller.disconnect()
    }

    /// A request error surfacing from a STALE client (its socket died after a
    /// reconnect already established a new session) must not tear down the
    /// newer connection — only the client whose epoch generated the error may
    /// converge state.
    func testStaleRequestErrorDoesNotTearDownNewerConnection() async {
        let mock1 = MockOBSSocket()
        var current = mock1
        let controller = OBSController(
            makeClient: { OBSClient(socket: $0, requestTimeout: 10) },
            makeSocket: { current })

        _ = await connect(controller, mock1)
        XCTAssertEqual(controller.state, .connected)

        // Park a status request on the OLD client: no reply ever comes; the
        // request will fail with .notConnected once the old client dies.
        mock1.replyToLastSent { _ in nil }
        let sentBefore = mock1.sentFrames.count
        let parked = Task { await controller.streamStatus() }
        await waitUntil { mock1.sentFrames.count == sentBefore + 1 }

        // Reconnect: the prologue teardown kills the old client, whose parked
        // request now fails — AFTER the new session is (being) established.
        let mock2 = MockOBSSocket()
        current = mock2
        mock2.enqueueInbound(helloFrame())
        mock2.replyToLastSent(sessionResponder(scenes: ["X"], currentScene: "X"))
        let ok = await controller.connect(host: "localhost", port: 4455, password: nil)
        XCTAssertTrue(ok, "the reconnect itself must succeed")

        let stale = await parked.value
        XCTAssertNil(stale, "the old client's request fails, returning nil")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .connected,
                       "a stale client's request error must not tear down the newer connection")
        XCTAssertEqual(controller.sceneNames, ["X"], "the new session's seed is intact")
        controller.disconnect()
    }

    /// review10 finding 5: connect() must not report success after the
    /// connection already died. A seed-time socket failure converges the
    /// controller to .disconnected (and bumps the epoch) while the connect
    /// task is still running — pre-fix it returned true unconditionally after
    /// seedState, handing the caller a "connected" that wasn't.
    func testConnectReturnsFalseWhenSeedTimeSocketFailureKillsConnection() async {
        let mock = MockOBSSocket()
        let controller = makeController(mock)

        mock.enqueueInbound(helloFrame())
        mock.replyToLastSent { sent in
            if sent.contains("\"op\":1") { return identifiedFrame }
            guard sent.contains("\"op\":6") else { return nil }
            // The socket dies the moment the first seed request goes out.
            mock.finishWithError(OBSSocketError.notConnected)
            return nil
        }

        let ok = await controller.connect(host: "localhost", port: 4455, password: nil)
        XCTAssertFalse(ok, "connect must not report success after the connection died mid-seed")
        XCTAssertEqual(controller.state, .disconnected)
    }

    // MARK: - review11 finding 3: connect seeding must never overwrite
    // NEWER OBS events (per-field order stamps)

    /// Build a long-timeout controller connected against a ScriptedOBSServer
    /// with `parkTypes` pre-set, parked mid-seed on the given request type.
    /// Returns once the seed is parked. The caller resumes the parked
    /// request and awaits the connect task.
    private func makeSeedParkedController(
        parking type: String,
        configure: (ScriptedOBSServer) -> Void = { _ in }
    ) async -> (OBSController, MockOBSSocket, ScriptedOBSServer, Task<Bool, Never>) {
        let mock = MockOBSSocket()
        let controller = OBSController(
            makeClient: { OBSClient(socket: $0, requestTimeout: 10) },
            makeSocket: { mock })
        let server = ScriptedOBSServer()
        configure(server)
        server.parkTypes = [type]
        mock.enqueueInbound(helloFrame())
        mock.replyToLastSent(server.responder())
        let connectTask = Task { await controller.connect(host: "localhost", port: 4455,
                                                          password: nil) }
        await waitUntil { server.parked.count == 1 }
        return (controller, mock, server, connectTask)
    }

    /// A stream-started EVENT lands while the seed's GetStreamStatus answer
    /// is still in flight; the (older) seed answer then resumes with
    /// outputActive:false. Pre-fix the stale seed overwrote the event —
    /// .connected over an actually-streaming OBS, with nothing to repair the
    /// published state. The event must win.
    func testSeedStreamAnswerNeverOverwritesNewerStreamEvent() async {
        let (controller, mock, server, connectTask) =
            await makeSeedParkedController(parking: "GetStreamStatus")
        XCTAssertEqual(controller.state, .connected)

        // Newer truth arrives as an event while the seed answer is parked.
        mock.enqueueInbound(eventFrame(type: "StreamStateChanged",
                                       data: ["outputActive": true]))
        await waitUntil { controller.state == .streaming }

        // Resume the STALE seed answer (snapshot taken before the start).
        mock.enqueueInbound(responseFrame(requestId: server.parked[0].id, ok: true,
                                          responseData: ["outputActive": false]))
        let ok = await connectTask.value
        XCTAssertTrue(ok)
        XCTAssertEqual(controller.state, .streaming,
                       "the seed snapshot is OLDER than the event — the event wins")
        controller.disconnect()
    }

    /// Record flavor: a RecordStateChanged(active) event lands while the
    /// seed's GetRecordStatus answer is in flight — the stale answer must
    /// not clear isRecording.
    func testSeedRecordAnswerNeverOverwritesNewerRecordEvent() async {
        let (controller, mock, server, connectTask) =
            await makeSeedParkedController(parking: "GetRecordStatus")

        mock.enqueueInbound(eventFrame(type: "RecordStateChanged",
                                       data: ["outputActive": true]))
        await waitUntil { controller.isRecording }

        mock.enqueueInbound(responseFrame(requestId: server.parked[0].id, ok: true,
                                          responseData: ["outputActive": false]))
        let ok = await connectTask.value
        XCTAssertTrue(ok)
        XCTAssertTrue(controller.isRecording,
                      "the seed snapshot is OLDER than the record event — the event wins")
        controller.disconnect()
    }

    /// Scene flavor: a CurrentProgramSceneChanged event lands while the
    /// seed's GetSceneList answer is in flight — the stale answer must not
    /// roll currentScene back (sceneNames, which only fetches carry, still
    /// seed normally).
    func testSeedSceneListAnswerNeverOverwritesNewerSceneChangeEvent() async {
        let (controller, mock, server, connectTask) =
            await makeSeedParkedController(parking: "GetSceneList")

        mock.enqueueInbound(eventFrame(type: "CurrentProgramSceneChanged",
                                       data: ["sceneName": "Scope"]))
        await waitUntil { controller.currentScene == "Scope" }

        mock.enqueueInbound(responseFrame(requestId: server.parked[0].id, ok: true,
                                          responseData: [
                                              "currentProgramSceneName": "Stack",
                                              "scenes": [["sceneName": "Scope"], ["sceneName": "Stack"]]]))
        let ok = await connectTask.value
        XCTAssertTrue(ok)
        XCTAssertEqual(controller.currentScene, "Scope",
                       "the seeded program scene is OLDER than the scene-change event — the event wins")
        XCTAssertEqual(controller.sceneNames.sorted(), ["Scope", "Stack"],
                       "the scene NAMES still seed — only the superseded field is skipped")
        controller.disconnect()
    }

    /// Scene-list flavor: a SceneListChanged event triggers a newer
    /// refreshScenes() while the seed's GetSceneList answer is still parked.
    /// The newer refresh's list/current scene must win; the older seed answer
    /// must not roll either field back.
    func testSeedSceneListAnswerNeverOverwritesNewerSceneListRefresh() async {
        let (controller, mock, server, connectTask) =
            await makeSeedParkedController(parking: "GetSceneList") {
                $0.scenes = ["Old"]
                $0.currentScene = "Old"
            }

        server.parkTypes = []
        server.scenes = ["New A", "New B"]
        server.currentScene = "New B"
        mock.enqueueInbound(eventFrame(type: "SceneListChanged", data: [:]))
        await waitUntil {
            controller.sceneNames == ["New A", "New B"] &&
            controller.currentScene == "New B"
        }

        mock.enqueueInbound(responseFrame(requestId: server.parked[0].id, ok: true,
                                          responseData: [
                                              "currentProgramSceneName": "Old",
                                              "scenes": [["sceneName": "Old"]]
                                          ]))
        let ok = await connectTask.value
        XCTAssertTrue(ok)
        XCTAssertEqual(controller.sceneNames, ["New A", "New B"],
                       "the newer scene-list refresh must beat the older seed answer")
        XCTAssertEqual(controller.currentScene, "New B",
                       "the newer scene-list refresh's current scene must also win")
        controller.disconnect()
    }

    /// Per-FIELD stamps, not one global version: an UNRELATED event (a scene
    /// change) during the stream seed must not void the stream seed — a
    /// skipped-but-untouched field would stay unseeded with nothing to
    /// repair it.
    func testUnrelatedEventDoesNotVoidStreamSeed() async {
        let (controller, mock, server, connectTask) =
            await makeSeedParkedController(parking: "GetStreamStatus") { $0.streamActive = true }

        mock.enqueueInbound(eventFrame(type: "CurrentProgramSceneChanged",
                                       data: ["sceneName": "Scope"]))
        await waitUntil { controller.currentScene == "Scope" }

        // Resume the stream seed: OBS is streaming — the seed must apply.
        mock.enqueueInbound(responseFrame(requestId: server.parked[0].id, ok: true,
                                          responseData: ["outputActive": true]))
        let ok = await connectTask.value
        XCTAssertTrue(ok)
        XCTAssertEqual(controller.state, .streaming,
                       "an unrelated event must not void the stream seed")
        XCTAssertEqual(controller.currentScene, "Scope")
        controller.disconnect()
    }

    // MARK: - cold2 M-3: connect resets published output state before seeding

    /// Cold2 M-3 (red-first): isRecording/sceneNames/currentScene were never reset at
    /// connect — a NON-FATAL seed failure (requests answered ok:false; the link stays
    /// up) left the PREVIOUS session's values published behind a fresh .connected.
    /// Post-fix connect resets all three to neutral defaults at connect start (under
    /// the new epoch, before seeding), so a failed seed shows neutral, never stale.
    func testConnectResetsPublishedStateBeforeSeeding_failedSeedNeverShowsStale() async {
        let mock1 = MockOBSSocket()
        var current = mock1
        let controller = OBSController(
            makeClient: { OBSClient(socket: $0, requestTimeout: 1) },
            makeSocket: { current })

        _ = await connect(controller, mock1, scenes: ["A", "B"], currentScene: "A",
                          recording: true)
        XCTAssertEqual(controller.sceneNames, ["A", "B"])
        XCTAssertEqual(controller.currentScene, "A")
        XCTAssertTrue(controller.isRecording)
        controller.disconnect()

        // Second session: the handshake succeeds but EVERY seed request fails
        // non-fatally (ok:false — no liveness convergence, the link stays up).
        let mock2 = MockOBSSocket()
        current = mock2
        mock2.enqueueInbound(helloFrame())
        mock2.replyToLastSent { sent in
            if sent.contains("\"op\":1") { return identifiedFrame }
            guard sent.contains("\"op\":6") else { return nil }
            return responseFrame(requestId: requestId(fromSent: sent), ok: false, code: 500)
        }
        let ok = await controller.connect(host: "localhost", port: 4455, password: nil)
        XCTAssertTrue(ok, "the control link itself connected")
        XCTAssertEqual(controller.state, .connected)
        XCTAssertFalse(controller.isRecording,
                       "the previous session's recording flag must not survive a failed seed")
        XCTAssertEqual(controller.sceneNames, [],
                       "the previous session's scene list must not survive a failed seed")
        XCTAssertNil(controller.currentScene,
                     "the previous session's program scene must not survive a failed seed")
        controller.disconnect()
    }

    // MARK: - cold2 I-2: a wedged handshake must not poison connect coalescing

    /// Cold2 I-2 (red-first, controller level): a wedge (TCP accepts, no Hello) used to
    /// park connectTask forever — and because `connect` coalesces onto any in-flight
    /// attempt, EVERY later connect awaited the dead task; only a manual disconnect
    /// unwedged the controller. Post-fix the first attempt fails within the handshake
    /// bound, the epoch-guarded clearing releases `connectTask`, and a second attempt
    /// runs a FRESH handshake that succeeds.
    func testWedgedHandshakeFailsWithinBound_secondConnectDoesNotCoalesce() async {
        let wedged = MockOBSSocket()                  // never sends Hello
        let healthy = MockOBSSocket()
        var sockets = [wedged, healthy]
        let controller = OBSController(
            makeClient: { OBSClient(socket: $0, requestTimeout: 0.2) },
            makeSocket: { sockets.removeFirst() })

        var firstResult: Bool?
        Task { firstResult = await controller.connect(host: "localhost", port: 4455,
                                                      password: nil) }
        await waitUntil({ firstResult != nil }, timeout: 3)
        XCTAssertEqual(firstResult, false, "the wedged handshake must fail within the bound")
        XCTAssertEqual(controller.state, .disconnected)

        healthy.enqueueInbound(helloFrame())
        healthy.replyToLastSent(sessionResponder())
        var secondResult: Bool?
        Task { secondResult = await controller.connect(host: "localhost", port: 4455,
                                                       password: nil) }
        await waitUntil({ secondResult != nil }, timeout: 3)
        XCTAssertEqual(secondResult, true,
                       "the second attempt must start fresh, never coalesce onto the dead task")
        XCTAssertEqual(controller.state, .connected)
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
