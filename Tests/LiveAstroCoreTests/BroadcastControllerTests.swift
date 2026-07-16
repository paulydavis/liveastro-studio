import XCTest
@testable import LiveAstroCore

/// Lifecycle tests for `BroadcastController` — the Go Live state machine,
/// confirmed stops, generation tokens, and scene automation — driving the
/// injected `OBSController` end-to-end through `MockOBSSocket` +
/// `ScriptedOBSServer` (see OBSTestScripting.swift).
///
/// Pins the review6 state invariant:
/// - `.idle` means OBS has confirmed stream and recording inactive.
/// - `.stopUnconfirmed` means OBS may still be live; Go Live is blocked and
///   Retry is available.
/// - Every asynchronous completion must match the current generation before
///   changing state.
/// - Core requests launch; the app adapter owns every platform detail.
@MainActor
final class BroadcastControllerTests: XCTestCase {

    // MARK: - Harness

    /// Main-actor mutable capture boxes for the injected deps.
    final class Box {
        var logs: [String] = []
        var errors: [String] = []
        var sessionRunning = true
        var launchRequests = 0
    }

    struct Harness {
        let controller: BroadcastController
        let obs: OBSController
        let mock: MockOBSSocket
        let server: ScriptedOBSServer
        let box: Box
    }

    /// Build a BroadcastController over a mocked socket. All timing knobs are
    /// short-circuited (confirm polls instant, retry budget tiny, health poll
    /// fast) so no test waits on wall-clock delays for correctness.
    private func makeHarness(connect: Bool = true,
                             requestTimeout: TimeInterval = 1,
                             file: StaticString = #filePath,
                             line: UInt = #line) async -> Harness {
        let mock = MockOBSSocket()
        let server = ScriptedOBSServer()
        let box = Box()
        let obs = OBSController(
            makeClient: { OBSClient(socket: $0, requestTimeout: requestTimeout) },
            makeSocket: { mock })
        let controller = BroadcastController(obs: obs, deps: BroadcastDeps(
            log: { box.logs.append($0) },
            presentError: { box.errors.append($0) },
            isSessionRunning: { box.sessionRunning },
            launchOBS: { box.launchRequests += 1 }))
        controller.confirmPollSeconds = 0
        controller.maxConfirmPolls = 2
        controller.launchRetryDelaySeconds = 0.01
        controller.launchRetryBudgetSeconds = 0.05
        controller.healthPollIntervalSeconds = 0.02

        if connect {
            mock.enqueueInbound(helloFrame())
            mock.replyToLastSent(server.responder())
            let ok = await obs.connect(host: "localhost", port: 4455, password: nil)
            XCTAssertTrue(ok, "harness connect must succeed", file: file, line: line)
        }
        return Harness(controller: controller, obs: obs, mock: mock, server: server, box: box)
    }

    /// Count of op-6 requests of `type` sent so far.
    private func sent(_ type: String, _ mock: MockOBSSocket) -> Int {
        mock.sentFrames.filter { $0.contains("\"op\":6") && requestType(fromSent: $0) == type }
            .count
    }

    /// Order of all op-6 request types sent so far.
    private func sentTypes(_ mock: MockOBSSocket) -> [String] {
        mock.sentFrames.filter { $0.contains("\"op\":6") }.map { requestType(fromSent: $0) }
    }

    /// Let any (erroneously) queued async work run before asserting absence.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    // MARK: - (1) FIX 1: deferred session stop vs. a newer Go Live

    /// End Session while OBS is idle, then Go Live during the replay render:
    /// the deferred end-of-session stop must NO-OP against the newer broadcast
    /// (the review6 P1 repro — it used to send StopStream unconditionally and
    /// kill the fresh stream while the state stayed .live).
    func testDeferredStopSkipsNewerBroadcast() async {
        let h = await makeHarness()

        h.controller.sessionDidEnd()                      // End Session, nothing live
        XCTAssertEqual(h.controller.broadcastState, .idle)

        h.controller.goLive()                             // Go Live during replay render
        await waitUntil { h.controller.broadcastState == .live }
        XCTAssertEqual(sent("StopStream", h.mock), 0)

        h.controller.stopBroadcastAfterSessionEnd()       // replay finished
        await settle()

        XCTAssertEqual(h.controller.broadcastState, .live,
                       "deferred stop must not touch the newer broadcast")
        XCTAssertEqual(sent("StopStream", h.mock), 0,
                       "deferred stop must not send StopStream at a newer generation")
        XCTAssertTrue(h.box.logs.contains { $0.contains("deferred stop skipped") })
    }

    /// The normal deferred path stays intact: End Session while live →
    /// .endingSession; after the replay the deferred stop confirms and lands .idle.
    func testDeferredStopAfterEndingSessionConfirmsToIdle() async {
        let h = await makeHarness()
        h.controller.goLive()
        await waitUntil { h.controller.broadcastState == .live }

        h.controller.sessionDidEnd()
        XCTAssertEqual(h.controller.broadcastState, .endingSession)

        h.controller.stopBroadcastAfterSessionEnd()
        XCTAssertEqual(h.controller.broadcastState, .stopping,
                       "UI shows Stopping… the instant the replay is done")
        await waitUntil { h.controller.broadcastState == .idle }
        XCTAssertEqual(sent("StopStream", h.mock), 1)
        XCTAssertNil(h.controller.streamHealth)
    }

    // MARK: - (2)+(3) FIX 2: stops must be confirmed

    /// A stop whose request round-trips ok but never takes effect (OBS still
    /// reports outputActive) lands in .stopUnconfirmed, blocks Go Live, and
    /// retryStop() recovers to .idle once OBS actually stops.
    func testUnconfirmedStopBlocksGoLiveAndRetryRecovers() async {
        let h = await makeHarness()
        h.controller.goLive()
        await waitUntil { h.controller.broadcastState == .live }

        h.server.streamReactsToRequests = false           // StopStream "succeeds", no effect
        h.controller.endBroadcast()
        await waitUntil { h.controller.broadcastState == .stopUnconfirmed }
        XCTAssertTrue(h.box.errors.contains { $0.contains("may still be live") })

        // Go Live is blocked while the stop is unconfirmed.
        let startsBefore = sent("StartStream", h.mock)
        h.controller.goLive()
        XCTAssertEqual(h.controller.broadcastState, .stopUnconfirmed)
        await settle()
        XCTAssertEqual(sent("StartStream", h.mock), startsBefore)

        // Retry once OBS actually honors the stop.
        h.server.streamReactsToRequests = true
        h.controller.retryStop()
        await waitUntil { h.controller.broadcastState == .idle }
    }

    /// .idle requires BOTH stream and recording confirmed inactive: a stop
    /// that downs the stream but leaves the recording running is unconfirmed.
    func testConfirmedStopRequiresStreamAndRecordInactive() async {
        let h = await makeHarness()
        h.controller.goLive()
        await waitUntil { h.controller.broadcastState == .live }

        h.server.recordActive = true                      // recording running in OBS
        h.server.recordReactsToRequests = false           // StopRecord never takes effect
        h.controller.endBroadcast()
        await waitUntil { h.controller.broadcastState == .stopUnconfirmed }

        h.server.recordReactsToRequests = true
        h.controller.retryStop()
        await waitUntil { h.controller.broadcastState == .idle }
        XCTAssertFalse(h.server.streamActive)
        XCTAssertFalse(h.server.recordActive)
    }

    // MARK: - (4) FIX 3: stale Go Live cannot mutate a newer attempt

    /// Attempt A parks mid-await (its confirm poll is left unanswered), the
    /// operator ends the broadcast, attempt B goes live — then A's stale
    /// completion resumes. A must neither change state nor stop B's stream.
    func testStaleGoLiveCompletionCannotMutateNewerAttempt() async {
        // Long request timeout so A's parked poll outlives the choreography.
        let h = await makeHarness(requestTimeout: 10)
        h.controller.maxConfirmPolls = 1

        // Attempt A: park its (single) confirm poll.
        h.server.parkTypes = ["GetStreamStatus"]
        h.controller.goLive()
        await waitUntil { h.server.parked.count == 1 }
        let genA = h.controller.broadcastGeneration
        XCTAssertEqual(h.controller.broadcastState, .connecting)

        // Cancel A: End Broadcast while connecting (confirmed stop → .idle).
        h.server.parkTypes = []
        h.controller.endBroadcast()
        await waitUntil { h.controller.broadcastState == .idle }

        // Attempt B goes live.
        h.controller.goLive()
        await waitUntil { h.controller.broadcastState == .live }
        let genB = h.controller.broadcastGeneration
        XCTAssertNotEqual(genA, genB)
        let stopsBefore = sent("StopStream", h.mock)

        // Resume A's parked confirm poll with outputActive:true — a stale
        // success. B owns the stream: A must return silently.
        let parked = h.server.parked[0]
        h.mock.enqueueInbound(responseFrame(requestId: parked.id, ok: true, responseData: [
            "outputActive": true, "outputDuration": 1, "outputTotalFrames": 1,
            "outputSkippedFrames": 0, "outputCongestion": 0]))
        await settle()

        XCTAssertEqual(h.controller.broadcastState, .live, "stale A must not mutate B's state")
        XCTAssertEqual(h.controller.broadcastGeneration, genB)
        XCTAssertEqual(sent("StopStream", h.mock), stopsBefore,
                       "stale A must not stop B's stream")
    }

    // MARK: - (5) FIX 4: "Record while streaming"

    /// obsRecord=true → StartRecord is sent AFTER the stream is confirmed up.
    func testObsRecordStartsRecordingAfterStreamUp() async {
        let h = await makeHarness()
        h.controller.obsRecord = true
        h.controller.goLive()
        await waitUntil { h.controller.broadcastState == .live }
        await waitUntil { self.sent("StartRecord", h.mock) == 1 }

        let types = sentTypes(h.mock)
        XCTAssertLessThan(types.firstIndex(of: "StartStream")!,
                          types.firstIndex(of: "StartRecord")!,
                          "recording starts only after the stream is up")
        XCTAssertTrue(h.server.recordActive)
    }

    /// obsRecord=false → no StartRecord ever.
    func testObsRecordOffSendsNoStartRecord() async {
        let h = await makeHarness()
        h.controller.obsRecord = false
        h.controller.goLive()
        await waitUntil { h.controller.broadcastState == .live }
        await settle()
        XCTAssertEqual(sent("StartRecord", h.mock), 0)
    }

    /// A recording failure is logged honestly but never fails the broadcast.
    func testObsRecordFailureDoesNotFailBroadcast() async {
        let h = await makeHarness()
        h.controller.obsRecord = true
        h.server.failTypes = ["StartRecord"]
        h.controller.goLive()
        await waitUntil { h.controller.broadcastState == .live }
        await waitUntil { h.box.logs.contains { $0.contains("could not start recording") } }
        XCTAssertEqual(h.controller.broadcastState, .live)
    }

    // MARK: - (6) FIX 5: scene automation generation

    /// Positive control: a stall tick actually switches to the scope scene.
    func testSceneAutomationSwitchesToScopeOnStall() async {
        let h = await makeHarness()
        h.controller.sceneAutomationOn = true
        h.controller.stackSceneName = "Stack"
        h.controller.scopeSceneName = "Scope"
        h.controller.sessionDidStart(subExposureSeconds: 1)

        h.controller.sceneTick(now: Date().addingTimeInterval(1000))   // way past stall threshold
        await waitUntil { self.sent("SetCurrentProgramScene", h.mock) == 1 }
        XCTAssertTrue(h.mock.sentFrames.contains { $0.contains("Scope") })
    }

    /// A scene-change task queued by a stall tick sends NOTHING if
    /// stopSceneAutomation() (session end) runs before it fires.
    func testQueuedSceneChangeAfterAutomationStopSendsNothing() async {
        let h = await makeHarness()
        h.controller.sceneAutomationOn = true
        h.controller.stackSceneName = "Stack"
        h.controller.scopeSceneName = "Scope"
        h.controller.sessionDidStart(subExposureSeconds: 1)

        // Queue the scene change and end the session in the SAME main-actor
        // turn — the queued task resumes only after sessionDidEnd bumped the
        // automation generation, so it must no-op.
        h.controller.sceneTick(now: Date().addingTimeInterval(1000))
        h.controller.sessionDidEnd()
        await settle()

        XCTAssertEqual(sent("SetCurrentProgramScene", h.mock), 0,
                       "queued scene automation must not fire after stopSceneAutomation()")
    }

    // MARK: - (7) Emergency override: End Broadcast during .endingSession

    /// The operator can force the stream down while the replay renders: the
    /// generation bumps SYNCHRONOUSLY at entry (the deferred stop is stale
    /// from that instant), and .idle is entered only on a confirmed stop.
    func testEmergencyEndBroadcastDuringEndingSession() async {
        let h = await makeHarness()
        h.controller.goLive()
        await waitUntil { h.controller.broadcastState == .live }
        h.controller.sessionDidEnd()
        XCTAssertEqual(h.controller.broadcastState, .endingSession)

        let genBefore = h.controller.broadcastGeneration
        h.controller.endBroadcast()
        XCTAssertEqual(h.controller.broadcastGeneration, genBefore + 1,
                       "generation must bump synchronously at endBroadcast entry")
        XCTAssertEqual(h.controller.broadcastState, .stopping)

        await waitUntil { h.controller.broadcastState == .idle }   // confirmed stop
        XCTAssertEqual(sent("StopStream", h.mock), 1)

        // The replay finishes later: the deferred stop is stale and must no-op.
        h.controller.stopBroadcastAfterSessionEnd()
        await settle()
        XCTAssertEqual(h.controller.broadcastState, .idle)
        XCTAssertEqual(sent("StopStream", h.mock), 1, "no second StopStream")
        XCTAssertTrue(h.box.logs.contains { $0.contains("deferred stop skipped") })
    }

    /// The override lands .idle ONLY on confirmation — an ignored stop lands
    /// .stopUnconfirmed even on the emergency path.
    func testEmergencyEndBroadcastUnconfirmedLandsStopUnconfirmed() async {
        let h = await makeHarness()
        h.controller.goLive()
        await waitUntil { h.controller.broadcastState == .live }
        h.controller.sessionDidEnd()
        XCTAssertEqual(h.controller.broadcastState, .endingSession)

        h.server.streamReactsToRequests = false
        h.controller.endBroadcast()
        await waitUntil { h.controller.broadcastState == .stopUnconfirmed }
    }

    // MARK: - (8) Quit-safety: disconnect ≠ stop

    /// A disconnect never sends StopStream — and a disconnect that strands a
    /// live stream lands .stopUnconfirmed (honest state), never .idle.
    func testDisconnectWhileLiveSendsNoStopStreamAndLandsStopUnconfirmed() async {
        let h = await makeHarness()
        h.controller.goLive()
        await waitUntil { h.controller.broadcastState == .live }

        h.controller.disconnect()
        XCTAssertEqual(h.controller.broadcastState, .stopUnconfirmed)
        await settle()
        XCTAssertEqual(sent("StopStream", h.mock), 0,
                       "disconnect() must never send StopStream — the stream keeps running")
        XCTAssertTrue(h.box.logs.contains { $0.contains("disconnect ≠ stop") })
        XCTAssertTrue(h.server.streamActive, "OBS really is still streaming")
    }

    /// A plain disconnect with nothing live stays .idle and sends no StopStream.
    func testDisconnectWhileIdleStaysIdle() async {
        let h = await makeHarness()
        h.controller.disconnect()
        await settle()
        XCTAssertEqual(h.controller.broadcastState, .idle)
        XCTAssertEqual(sent("StopStream", h.mock), 0)
    }

    // MARK: - Launch boundary

    /// When OBS is unreachable, goLive requests exactly launchOBS() from the
    /// app adapter (core owns no platform detail), keeps retrying within the
    /// (test-shortened) budget, then fails honestly back to .idle.
    func testGoLiveUnreachableRequestsLaunchThenFailsHonestly() async {
        let h = await makeHarness(connect: false)
        h.mock.finishWithError(OBSSocketError.notConnected)   // every connect fails fast

        h.controller.goLive()
        await waitUntil { h.controller.broadcastState == .idle }
        XCTAssertEqual(h.box.launchRequests, 1)
        XCTAssertTrue(h.box.errors.contains { $0.contains("OBS not reachable") })
    }
}
