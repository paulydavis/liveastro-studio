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
            // Route through the controller (review7): the initial state is
            // .unknown until a connect RECONCILES with actual OBS output state —
            // against this quiet scripted server that lands the confirmed .idle
            // every pre-review7 test starts from.
            let ok = await controller.connectAndReconcile()
            XCTAssertTrue(ok, "harness connect must succeed", file: file, line: line)
            XCTAssertEqual(controller.broadcastState, .idle,
                           "quiet OBS must reconcile to confirmed idle", file: file, line: line)
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
        h.server.parkSkip = ["GetStreamStatus": 1]   // let the reconcile's status query through
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

    // MARK: - (4b) review7 FIX 1: stale go-live completions never send StopStream

    /// The reviewer's exact repro: attempt A parks at its confirm poll, the
    /// operator cancels it, attempt B goes live — then A resumes with
    /// outputActive:false, a FAILED confirm. Pre-fix, OBSController.startBroadcast
    /// itself sent StopStream on confirm expiry BEFORE goLive's generation check
    /// ever ran, killing B's stream while the UI stayed .live. A's path must send
    /// ZERO StopStream and leave B untouched.
    func testStaleFailedGoLiveConfirmDoesNotStopNewerBroadcast() async {
        let h = await makeHarness(requestTimeout: 10)
        h.controller.maxConfirmPolls = 1

        // Attempt A: park its (single) confirm poll.
        h.server.parkTypes = ["GetStreamStatus"]
        h.server.parkSkip = ["GetStreamStatus": 1]   // let the reconcile's status query through
        h.controller.goLive()
        await waitUntil { h.server.parked.count == 1 }
        XCTAssertEqual(h.controller.broadcastState, .connecting)

        // Cancel A (confirmed stop → .idle), then attempt B goes live.
        h.server.parkTypes = []
        h.controller.endBroadcast()
        await waitUntil { h.controller.broadcastState == .idle }
        h.controller.goLive()
        await waitUntil { h.controller.broadcastState == .live }
        let stopsBefore = sent("StopStream", h.mock)

        // Resume A's parked confirm poll with outputActive:false — a stale
        // FAILED confirm. A must stop nothing, log once, and leave B live.
        let parked = h.server.parked[0]
        h.mock.enqueueInbound(responseFrame(requestId: parked.id, ok: true, responseData: [
            "outputActive": false, "outputDuration": 0, "outputTotalFrames": 0,
            "outputSkippedFrames": 0, "outputCongestion": 0]))
        await settle()

        XCTAssertEqual(sent("StopStream", h.mock), stopsBefore,
                       "a stale failed confirm must never send StopStream")
        XCTAssertTrue(h.server.streamActive, "B's stream must still be up")
        XCTAssertEqual(h.controller.broadcastState, .live)
        XCTAssertTrue(h.box.logs.contains { $0.contains("stale go-live attempt discarded") })
    }

    /// A stale SUCCESS with no newer owner cleans up its own stream — and that
    /// cleanup stop must be CONFIRMED: when OBS ignores it, the state escalates
    /// honestly from .idle to .stopUnconfirmed instead of staying a false idle.
    func testStaleGoLiveSuccessNoOwnerUnconfirmedCleanupLandsStopUnconfirmed() async {
        let h = await makeHarness(requestTimeout: 10)
        h.controller.maxConfirmPolls = 1

        h.server.parkTypes = ["GetStreamStatus"]
        h.server.parkSkip = ["GetStreamStatus": 1]   // let the reconcile's status query through
        h.controller.goLive()
        await waitUntil { h.server.parked.count == 1 }

        // Cancel A (confirmed stop → .idle). No newer broadcast starts.
        h.server.parkTypes = []
        h.controller.endBroadcast()
        await waitUntil { h.controller.broadcastState == .idle }
        let stopsBefore = sent("StopStream", h.mock)

        // The stale stream "really" came up, and OBS now ignores stops.
        h.server.streamActive = true
        h.server.streamReactsToRequests = false
        let parked = h.server.parked[0]
        h.mock.enqueueInbound(responseFrame(requestId: parked.id, ok: true, responseData: [
            "outputActive": true, "outputDuration": 1, "outputTotalFrames": 1,
            "outputSkippedFrames": 0, "outputCongestion": 0]))

        await waitUntil { h.controller.broadcastState == .stopUnconfirmed }
        XCTAssertGreaterThan(sent("StopStream", h.mock), stopsBefore,
                             "the no-owner cleanup stop must actually be sent")
        XCTAssertTrue(h.box.logs.contains { $0.contains("cleanup stop not confirmed") })
    }

    /// A stale SUCCESS with no newer owner whose cleanup stop CONFIRMS keeps
    /// the confirmed .idle (regression pin for the happy cleanup path).
    func testStaleGoLiveSuccessNoOwnerConfirmedCleanupStaysIdle() async {
        let h = await makeHarness(requestTimeout: 10)
        h.controller.maxConfirmPolls = 1

        h.server.parkTypes = ["GetStreamStatus"]
        h.server.parkSkip = ["GetStreamStatus": 1]   // let the reconcile's status query through
        h.controller.goLive()
        await waitUntil { h.server.parked.count == 1 }

        h.server.parkTypes = []
        h.controller.endBroadcast()
        await waitUntil { h.controller.broadcastState == .idle }
        let stopsBefore = sent("StopStream", h.mock)

        h.server.streamActive = true                       // the zombie stream is up
        let parked = h.server.parked[0]
        h.mock.enqueueInbound(responseFrame(requestId: parked.id, ok: true, responseData: [
            "outputActive": true, "outputDuration": 1, "outputTotalFrames": 1,
            "outputSkippedFrames": 0, "outputCongestion": 0]))

        await waitUntil { self.sent("StopStream", h.mock) > stopsBefore }
        await settle()
        XCTAssertEqual(h.controller.broadcastState, .idle,
                       "a CONFIRMED cleanup stop keeps the confirmed idle")
        XCTAssertFalse(h.server.streamActive, "the zombie stream was actually stopped")
    }

    /// A failed go-live confirm at the CURRENT generation performs the cleanup
    /// stop with confirmed-stop semantics: OBS leaving an output active lands
    /// .stopUnconfirmed (honest), never a false .idle. StartRecord is parked so
    /// the recording can get stuck active AFTER the connect-time reconcile
    /// passed (both outputs were genuinely inactive at reconcile time).
    func testFailedGoLiveConfirmUnconfirmedCleanupLandsStopUnconfirmed() async {
        let h = await makeHarness(requestTimeout: 10)
        h.server.streamReactsToRequests = false            // StartStream accepted, no effect
        h.server.parkTypes = ["StartStream"]
        h.controller.goLive()
        await waitUntil { h.server.parked.count == 1 }

        // Recording gets stuck active mid-flight — the cleanup stop can down
        // nothing it can't reach, so the stop must not confirm.
        h.server.recordActive = true
        h.server.recordReactsToRequests = false
        h.server.parkTypes = []
        h.mock.enqueueInbound(responseFrame(requestId: h.server.parked[0].id, ok: true))

        await waitUntil { h.controller.broadcastState == .stopUnconfirmed }
        XCTAssertTrue(h.box.errors.contains { $0.contains("may still be live") })
    }

    /// A failed go-live confirm at the CURRENT generation whose cleanup stop
    /// CONFIRMS lands .idle with the existing "didn't go live" failure error.
    func testFailedGoLiveConfirmConfirmedCleanupLandsIdleWithError() async {
        let h = await makeHarness()
        h.server.streamReactsToRequests = false            // StartStream accepted, no effect
        h.controller.goLive()
        await waitUntil { h.controller.broadcastState == .idle
                          && h.box.errors.contains { $0.contains("didn't go live") } }
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

    // MARK: - (5b) review7 FIX 2: reconcile .idle with actual OBS state

    /// FIX 2c: an EXTERNAL stop (operator clicks Stop Streaming in OBS itself)
    /// seen by the health poll must end the broadcast honestly — OBS has
    /// CONFIRMED the stream inactive, so with recording also inactive the state
    /// settles .idle and the poll stops. Pre-fix the poll ignored health.active
    /// and reported .live forever.
    func testExternalStopSeenByHealthPollLandsIdle() async {
        let h = await makeHarness()
        h.controller.goLive()
        await waitUntil { h.controller.broadcastState == .live }

        h.server.streamActive = false      // stopped IN OBS, not via our requests
        await waitUntil { h.controller.broadcastState == .idle }
        XCTAssertTrue(h.box.logs.contains { $0.contains("stream ended in OBS") })
        XCTAssertNil(h.controller.streamHealth)
    }

    /// FIX 2c honesty edge: the external stop confirms the STREAM inactive, but
    /// .idle also requires recording confirmed inactive — recording still
    /// running lands .stopUnconfirmed (Go Live stays blocked; Retry reconciles).
    func testExternalStopWhileRecordingStillActiveLandsStopUnconfirmed() async {
        let h = await makeHarness()
        h.controller.goLive()
        await waitUntil { h.controller.broadcastState == .live }

        h.server.recordActive = true       // recording started/left running in OBS
        h.server.streamActive = false      // stream stopped in OBS
        await waitUntil { h.controller.broadcastState == .stopUnconfirmed }
        XCTAssertTrue(h.box.logs.contains { $0.contains("recording is still active") })

        h.controller.retryStop()           // Retry stops the recording and confirms
        await waitUntil { h.controller.broadcastState == .idle }
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
    /// (test-shortened) budget, then fails honestly back to where it started —
    /// review7: from a cold .unknown it returns to .unknown (never a fabricated
    /// confirmed idle).
    func testGoLiveUnreachableRequestsLaunchThenFailsHonestly() async {
        let h = await makeHarness(connect: false)
        h.mock.finishWithError(OBSSocketError.notConnected)   // every connect fails fast

        XCTAssertEqual(h.controller.broadcastState, .unknown)
        h.controller.goLive()
        await waitUntil { h.controller.broadcastState == .unknown && h.box.launchRequests == 1 }
        XCTAssertTrue(h.box.errors.contains { $0.contains("OBS not reachable") })
    }

    // MARK: - review7 FIX 2: .unknown initial state + connect-time reconcile

    /// The initial state is .unknown (never an unconfirmed idle claim), and a
    /// disconnect from .unknown stays .unknown.
    func testInitialStateIsUnknownAndDisconnectKeepsUnknown() async {
        let h = await makeHarness(connect: false)
        XCTAssertEqual(h.controller.broadcastState, .unknown)
        h.controller.disconnect()
        await settle()
        XCTAssertEqual(h.controller.broadcastState, .unknown)
        XCTAssertEqual(sent("StopStream", h.mock), 0)
    }

    /// Manual Connect to an ALREADY-STREAMING OBS adopts the external
    /// broadcast: .live, health polling, Go Live blocked, End Broadcast works.
    /// Pre-fix, ControlView called obs.connect directly and the footer kept
    /// offering a Go Live that would have double-started the stream.
    func testConnectToAlreadyStreamingOBSAdoptsLiveBroadcast() async {
        let h = await makeHarness(connect: false)
        h.server.streamActive = true                      // OBS is streaming on its own
        h.mock.enqueueInbound(helloFrame())
        h.mock.replyToLastSent(h.server.responder())

        let ok = await h.controller.connectAndReconcile()
        XCTAssertTrue(ok)
        XCTAssertEqual(h.controller.broadcastState, .live)
        XCTAssertTrue(h.box.logs.contains { $0.contains("adopted the live broadcast") })
        await waitUntil { h.controller.streamHealth != nil }   // health poll is running

        // Go Live is blocked on the adopted broadcast — no second StartStream.
        let startsBefore = sent("StartStream", h.mock)
        h.controller.goLive()
        await settle()
        XCTAssertEqual(sent("StartStream", h.mock), startsBefore)
        XCTAssertEqual(h.controller.broadcastState, .live)

        // End Broadcast works on the adopted stream.
        h.controller.endBroadcast()
        await waitUntil { h.controller.broadcastState == .idle }
        XCTAssertFalse(h.server.streamActive)
    }

    /// Manual Connect to a quiet OBS lands the (now genuinely confirmed) .idle.
    func testConnectToQuietOBSReconcilesToConfirmedIdle() async {
        let h = await makeHarness(connect: false)
        h.mock.enqueueInbound(helloFrame())
        h.mock.replyToLastSent(h.server.responder())
        let ok = await h.controller.connectAndReconcile()
        XCTAssertTrue(ok)
        XCTAssertEqual(h.controller.broadcastState, .idle)
    }

    /// Reconcile matrix: a failing status query means OBS MAY be live — land
    /// .stopUnconfirmed (Go Live blocked), never a fabricated .idle.
    func testConnectReconcileStatusFailureLandsStopUnconfirmed() async {
        let h = await makeHarness(connect: false)
        h.server.failTypes = ["GetStreamStatus"]
        h.mock.enqueueInbound(helloFrame())
        h.mock.replyToLastSent(h.server.responder())
        let ok = await h.controller.connectAndReconcile()
        XCTAssertTrue(ok, "the control link itself did connect")
        XCTAssertEqual(h.controller.broadcastState, .stopUnconfirmed)
    }

    /// Reconcile matrix: stream off + recording ON is NOT idle (the invariant
    /// requires both outputs confirmed inactive) — .stopUnconfirmed, and Retry
    /// stops the recording and reconfirms to .idle.
    func testConnectReconcileRecordingOnlyLandsStopUnconfirmedAndRetryRecovers() async {
        let h = await makeHarness(connect: false)
        h.server.recordActive = true                      // OBS is recording, not streaming
        h.mock.enqueueInbound(helloFrame())
        h.mock.replyToLastSent(h.server.responder())
        let ok = await h.controller.connectAndReconcile()
        XCTAssertTrue(ok)
        XCTAssertEqual(h.controller.broadcastState, .stopUnconfirmed)
        XCTAssertTrue(h.box.logs.contains { $0.contains("recording is active in OBS") })

        h.controller.retryStop()
        await waitUntil { h.controller.broadcastState == .idle }
        XCTAssertFalse(h.server.recordActive)
    }

    /// Cold start stays one-click: goLive() from .unknown against a QUIET OBS
    /// connects, reconciles both outputs inactive, and proceeds to .live.
    func testColdGoLiveFromUnknownQuietOBSGoesLive() async {
        let h = await makeHarness(connect: false)
        h.mock.enqueueInbound(helloFrame())
        h.mock.replyToLastSent(h.server.responder())

        XCTAssertEqual(h.controller.broadcastState, .unknown)
        h.controller.goLive()
        await waitUntil { h.controller.broadcastState == .live }
        let types = sentTypes(h.mock)
        XCTAssertLessThan(types.firstIndex(of: "GetStreamStatus")!,
                          types.firstIndex(of: "StartStream")!,
                          "the reconcile must run before the bring-up")
    }

    /// Cold start against an ALREADY-STREAMING OBS: one goLive() call adopts
    /// the live broadcast without ever sending StartStream.
    func testColdGoLiveFromUnknownAlreadyStreamingAdoptsWithoutStartStream() async {
        let h = await makeHarness(connect: false)
        h.server.streamActive = true
        h.mock.enqueueInbound(helloFrame())
        h.mock.replyToLastSent(h.server.responder())

        h.controller.goLive()
        await waitUntil { h.controller.broadcastState == .live }
        XCTAssertEqual(sent("StartStream", h.mock), 0,
                       "adoption must never double-start the stream")
        XCTAssertTrue(h.box.logs.contains { $0.contains("adopted the live broadcast") })
    }
}
