import XCTest
@testable import LiveAstroCore
@testable import LiveAstroStudio

@MainActor final class OBSLocalRecordingTests: XCTestCase {
    private let endpoint = URL(string: "ws://127.0.0.1:4455")!
    private func controller(_ wire: RecordingSocket) -> OBSLocalRecording {
        OBSLocalRecording(makeSocket: { wire }, timeout: 0.15, transitionTimeout: 0.15, pollInterval: 0.001)
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        guard condition() else { XCTFail("controller did not reach expected state before watchdog"); throw TestFailure.watchdog }
    }
    private enum TestFailure: Error { case watchdog }

    private func modelFixture(store: Bool, wire: RecordingSocket) throws -> (AppModel, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "OBSLocalRecordingTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        }
        let config = StorePreviewConfiguration(bundleIdentifier: store ? "com.pauldavis.liveastrostudio.store-preview" : "com.pauldavis.liveastrostudio", containerRoot: root)
        return (AppModel(userDefaults: defaults, calibrationLibrary: CalibrationLibrary(baseDirectory: root.appendingPathComponent("library")), configuration: config, makeOBSRecordingSocket: { wire }), defaults)
    }

    func testStoreOwnsRecordingSeparatelyAndEndDoesNotStopItOrSavePassword() async throws {
        let wire = RecordingSocket(records: [false, true])
        let (model, defaults) = try modelFixture(store: true, wire: wire)
        let recording = try XCTUnwrap(model.obsLocalRecording)
        recording.start(endpoint: endpoint, password: "recording-secret")
        try await wait { recording.state == .recording }
        var prompts = 0
        let logBeforeEnd = model.log
        model.requestEndSession { prompts += 1; return false }
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(model.log, logBeforeEnd, "cancelling must not enter End Session")
        model.requestEndSession { prompts += 1; return true }
        XCTAssertEqual(prompts, 2)
        XCTAssertGreaterThan(model.log.count, logBeforeEnd.count, "confirmed End must record that OBS is left running")
        XCTAssertEqual(recording.state, .recording)
        XCTAssertEqual(model.broadcast.obs.state, .disconnected)
        XCTAssertFalse(wire.requests.contains("StopRecord"))
        model.saveSettings()
        XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains("recording-secret"))
        XCTAssertFalse(model.log.joined().contains("recording-secret"))
        recording.disconnect()
    }

    func testDirectEditionHasNoStoreRecordingController() throws {
        let (model, _) = try modelFixture(store: false, wire: RecordingSocket(records: [false]))
        XCTAssertNil(model.obsLocalRecording)
    }

    func testQuitRequiresAcknowledgmentButNeverSendsStop() async throws {
        let wire = RecordingSocket(records: [false, true])
        let (model, _) = try modelFixture(store: true, wire: wire)
        let recording = try XCTUnwrap(model.obsLocalRecording)
        recording.start(endpoint: endpoint, password: "")
        try await wait { recording.state == .recording }
        let delegate = AppDelegate()
        delegate.model = model
        var prompts = 0
        delegate.confirmRecordingQuit = { prompts += 1; return false }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(prompts, 1)
        delegate.confirmRecordingQuit = { prompts += 1; return true }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertEqual(prompts, 2)
        XCTAssertFalse(wire.requests.contains("StopRecord"))
        recording.disconnect()
    }

    // Acknowledgment != activation. This fails if either confirmation is one-shot,
    // or if a duplicate click issues a second command.
    func testDelayedStartAndStopAreConfirmedAndDuplicateClicksCoalesce() async throws {
        let wire = RecordingSocket(records: [false, false, true, true, true, false])
        let recording = controller(wire)
        recording.start(endpoint: endpoint, password: "secret")
        recording.start(endpoint: endpoint, password: "secret")
        XCTAssertEqual(recording.state, .starting)
        try await wait { recording.state == .recording }
        XCTAssertTrue(recording.requiresAttention)
        recording.stop(); recording.stop()
        try await wait { recording.state == .finished("/fixture/recording.mov") }
        XCTAssertEqual(wire.requests.filter { $0 == "StartRecord" }.count, 1)
        XCTAssertEqual(wire.requests.filter { $0 == "StopRecord" }.count, 1)
        XCTAssertFalse(wire.requests.contains("StartStream"))
        XCTAssertFalse(recording.requiresAttention)
        XCTAssertTrue(wire.closed)
    }

    func testAlreadyActiveRecordingOrStreamIsNeverTakenOver() async throws {
        for streaming in [false, true] {
            let wire = RecordingSocket(records: [!streaming], streaming: streaming)
            let recording = controller(wire)
            recording.start(endpoint: endpoint, password: "")
            try await wait { if case .refused = recording.state { return true }; return false }
            recording.stop()
            XCTAssertFalse(wire.requests.contains("StartRecord"))
            XCTAssertFalse(wire.requests.contains("StopRecord"))
            XCTAssertTrue(wire.closed)
        }
    }

    func testLostStartReplyIsUncertainAndNeverRetriedOrBlindlyStopped() async throws {
        let wire = RecordingSocket(records: [false], parkedRequest: "StartRecord")
        let recording = controller(wire)
        recording.start(endpoint: endpoint, password: "secret")
        try await wait { if case .uncertain = recording.state { return true }; return false }
        recording.start(endpoint: endpoint, password: "secret"); recording.stop()
        XCTAssertEqual(wire.requests.filter { $0 == "StartRecord" }.count, 1)
        XCTAssertFalse(wire.requests.contains("StopRecord"))
        XCTAssertTrue(recording.requiresAttention)
        XCTAssertTrue(wire.closed)
    }

    func testNeverActiveIsUncertainRatherThanSuccess() async throws {
        let wire = RecordingSocket(records: [false])
        let recording = controller(wire)
        recording.start(endpoint: endpoint, password: "")
        try await wait { if case .uncertain = recording.state { return true }; return false }
        XCTAssertFalse(wire.requests.contains("StopRecord"))
    }

    func testUnexpectedStopRevokesPermissionEvenIfOBSStartsAnotherRecording() async throws {
        let wire = RecordingSocket(records: [false, true])
        let recording = controller(wire)
        recording.start(endpoint: endpoint, password: "")
        try await wait { recording.state == .recording }
        wire.event("RecordStateChanged", state: "OBS_WEBSOCKET_OUTPUT_STOPPED", active: false)
        wire.event("RecordStateChanged", state: "OBS_WEBSOCKET_OUTPUT_STARTED", active: true)
        try await wait { if case .uncertain = recording.state { return true }; return false }
        recording.stop()
        XCTAssertFalse(wire.requests.contains("StopRecord"))
    }

    func testDisconnectLeavesRecordingAloneAndWarns() async throws {
        let wire = RecordingSocket(records: [false, true])
        let recording = controller(wire)
        recording.start(endpoint: endpoint, password: "")
        try await wait { recording.state == .recording }
        recording.disconnect()
        XCTAssertTrue(recording.requiresAttention)
        guard case .uncertain = recording.state else { return XCTFail("disconnect must not claim stopped") }
        XCTAssertFalse(wire.requests.contains("StopRecord"))
        XCTAssertTrue(wire.closed)
    }

    func testTransportLossRevokesStopPermission() async throws {
        let wire = RecordingSocket(records: [false, true])
        let recording = controller(wire)
        recording.start(endpoint: endpoint, password: "")
        try await wait { recording.state == .recording }
        wire.close()
        try await wait { if case .uncertain = recording.state { return true }; return false }
        recording.stop()
        XCTAssertFalse(wire.requests.contains("StopRecord"))
    }

    func testRecoveryOnlyReadsAndCannotAdoptAnExistingRecording() async throws {
        let wire = RecordingSocket(records: [true])
        let recording = controller(wire)
        recording.checkStopped(endpoint: endpoint, password: "")
        try await wait { if case .uncertain = recording.state { return true }; return false }
        recording.stop()
        XCTAssertEqual(wire.requests, ["GetRecordStatus"])
        XCTAssertTrue(wire.closed)
    }

    func testReadOnlyRecoveryConfirmsInactive() async throws {
        let wire = RecordingSocket(records: [false])
        let recording = controller(wire)
        recording.checkStopped(endpoint: endpoint, password: "")
        try await wait { wire.closed }
        try await wait { recording.state == .idle }
        XCTAssertEqual(wire.requests, ["GetRecordStatus"])
    }

    func testRecoveryCannotClearUncertaintyAgainstAnotherEndpoint() async throws {
        let original = RecordingSocket(records: [false, true])
        let other = RecordingSocket(records: [false])
        var calls = 0
        let recording = OBSLocalRecording(makeSocket: { calls += 1; return calls == 1 ? original : other }, pollInterval: 0.001)
        recording.start(endpoint: endpoint, password: "")
        try await wait { recording.state == .recording }
        recording.disconnect()
        recording.checkStopped(endpoint: URL(string: "ws://other.local:4455"), password: "")
        // Reserve/check must refuse synchronously without opening the other server.
        guard case .uncertain = recording.state else { return XCTFail("lost original endpoint's unresolved recording") }
        XCTAssertEqual(calls, 1)
    }

    func testLostStopReplyNeverReportsSuccessOrRetries() async throws {
        let wire = RecordingSocket(records: [false, true], parkedRequest: "StopRecord")
        let recording = controller(wire)
        recording.start(endpoint: endpoint, password: "")
        try await wait { recording.state == .recording }
        recording.stop()
        try await wait { if case .uncertain = recording.state { return true }; return false }
        recording.stop()
        XCTAssertEqual(wire.requests.filter { $0 == "StopRecord" }.count, 1)
    }

    func testStopAcknowledgmentWhileStillActiveIsNotSuccess() async throws {
        let wire = RecordingSocket(records: [false, true])
        let recording = controller(wire)
        recording.start(endpoint: endpoint, password: "")
        try await wait { recording.state == .recording }
        recording.stop()
        try await wait { if case .uncertain = recording.state { return true }; return false }
        XCTAssertTrue(recording.requiresAttention)
        XCTAssertEqual(wire.requests.filter { $0 == "StopRecord" }.count, 1)
    }

    func testMalformedRecordingStatusNeverBecomesInactiveOrStartsRecording() async throws {
        let wire = RecordingSocket(records: [false], malformedStatus: true)
        let recording = controller(wire)
        recording.start(endpoint: endpoint, password: "secret")
        try await wait { if case .failed = recording.state { return true }; return false }
        XCTAssertFalse(wire.requests.contains("StartRecord"))
        XCTAssertTrue(wire.closed)
    }

    func testOwnerReleaseClosesConnectionWithoutStoppingRecording() async throws {
        let wire = RecordingSocket(records: [false, true])
        var recording: OBSLocalRecording? = controller(wire)
        weak let weakRecording = recording
        recording?.start(endpoint: endpoint, password: "")
        try await wait { recording?.state == .recording }
        recording = nil
        XCTAssertNil(weakRecording)
        XCTAssertTrue(wire.closed)
        XCTAssertFalse(wire.requests.contains("StopRecord"))
    }

    func testStopEventDuringStopPrecheckRevokesPermissionBeforeCommand() async throws {
        let wire = RecordingSocket(records: [false, true])
        let recording = OBSLocalRecording(makeSocket: { wire }, timeout: 5, pollInterval: 0.001)
        recording.start(endpoint: endpoint, password: "")
        try await wait { recording.state == .recording }
        wire.parkNextRecordRead()
        recording.stop()
        try await wait { wire.hasParkedRead }
        wire.event("RecordStateChanged", state: "OBS_WEBSOCKET_OUTPUT_STOPPED", active: false)
        // Watchdog is shorter than request timeout: passing requires the event
        // to retire control, not merely waiting for the parked request to time out.
        try await wait { if case .uncertain = recording.state { return true }; return false }
        XCTAssertFalse(wire.requests.contains("StopRecord"))
    }

    func testWireBlocksStreamingScenesBatchesAndUnarmedOrRepeatedCommands() async throws {
        let wire = RecordingSocket(records: [false])
        let socket = OBSRecordingSocket(inner: wire)
        func packet(_ name: String) -> String { #"{"op":6,"d":{"requestType":""# + name + #"","requestId":"1"}}"# }
        for name in ["StartRecord", "StopRecord", "StartStream", "StopStream", "SetCurrentProgramScene", "GetStreamServiceSettings"] {
            do { try await socket.send(packet(name)); XCTFail("forwarded \(name)") } catch {}
        }
        do { try await socket.send(#"{"op":8,"d":{"requests":[]}}"#); XCTFail("forwarded batch") } catch {}
        XCTAssertTrue(wire.requests.isEmpty)
        socket.allowStart(); try await socket.send(packet("StartRecord"))
        do { try await socket.send(packet("StartRecord")); XCTFail("duplicate start") } catch {}
        socket.allowStop(); try await socket.send(packet("StopRecord"))
        do { try await socket.send(packet("StopRecord")); XCTFail("duplicate stop") } catch {}
        socket.close(); socket.allowStop()
        do { try await socket.send(packet("StopRecord")); XCTFail("write after close") } catch {}
        XCTAssertEqual(wire.requests, ["StartRecord", "StopRecord"])
    }
}

/// Only the external transport is simulated; OBSClient framing, correlation,
/// controller decisions and transition waits are real.
private final class RecordingSocket: OBSSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var inbound: [String] = []
    private var receiver: CheckedContinuation<String, Error>?
    private var sent: [String] = []
    private var isClosed = false
    private var records: [Bool]
    private let streaming: Bool
    private let parkedRequest: String?
    private let malformedStatus: Bool
    private var parkRead = false
    private var parkedRead = false
    private var subscriptions = 0
    init(records: [Bool], streaming: Bool = false, parkedRequest: String? = nil, malformedStatus: Bool = false) {
        self.records = records; self.streaming = streaming; self.parkedRequest = parkedRequest
        self.malformedStatus = malformedStatus
    }
    func parkNextRecordRead() { lock.withLock { parkRead = true } }
    var hasParkedRead: Bool { lock.withLock { parkedRead } }
    var requests: [String] { lock.withLock { sent } }
    var closed: Bool { lock.withLock { isClosed } }
    func connect(url: URL) async throws { enqueue(#"{"op":0,"d":{"obsWebSocketVersion":"5.0.0","rpcVersion":1}}"#) }
    func send(_ text: String) async throws {
        let packet = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        if packet["op"] as? Int == 1 {
            let identification = try XCTUnwrap(packet["d"] as? [String: Any])
            lock.withLock { subscriptions = identification["eventSubscriptions"] as? Int ?? 0 }
            enqueue(#"{"op":2,"d":{"negotiatedRpcVersion":1}}"#); return
        }
        let d = try XCTUnwrap(packet["d"] as? [String: Any])
        let name = try XCTUnwrap(d["requestType"] as? String)
        lock.withLock { sent.append(name) }
        if name == parkedRequest { return }
        if name == "GetRecordStatus", lock.withLock({
            if parkRead { parkRead = false; parkedRead = true; return true }
            return false
        }) { return }
        let data: [String: Any]
        switch name {
        case "GetVersion": data = ["obsVersion": "32.2.2", "obsWebSocketVersion": "5.0.0", "rpcVersion": 1, "availableRequests": ["GetRecordStatus", "GetStreamStatus", "StartRecord", "StopRecord"], "supportedImageFormats": ["png"], "platform": "macos", "platformDescription": "test"]
        case "GetStreamStatus": data = ["outputActive": streaming, "outputReconnecting": false, "outputTimecode": "00:00:00.000", "outputDuration": 0, "outputCongestion": 0, "outputBytes": 0, "outputSkippedFrames": 0, "outputTotalFrames": 0]
        case "GetRecordStatus":
            let active = lock.withLock { records.count > 1 ? records.removeFirst() : records[0] }
            data = ["outputActive": malformedStatus ? NSNumber(value: 0) : NSNumber(value: active), "outputPaused": false, "outputTimecode": "00:00:01.000", "outputDuration": 1000, "outputBytes": 100]
        case "StartRecord": data = [:]
        case "StopRecord": data = ["outputPath": "/fixture/recording.mov"]
        default: XCTFail("unexpected request \(name)"); throw OBSSocketError.notConnected
        }
        enqueue(try encode(["op": 7, "d": ["requestType": name, "requestId": d["requestId"]!, "requestStatus": ["result": true, "code": 100], "responseData": data]]))
    }
    func event(_ name: String, state: String, active: Bool) {
        guard lock.withLock({ subscriptions & 64 != 0 }) else { return }
        enqueue(try! encode(["op": 5, "d": ["eventType": name, "eventIntent": 64, "eventData": ["outputState": state, "outputActive": active]]]))
    }
    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if isClosed { lock.unlock(); c.resume(throwing: OBSSocketError.notConnected) }
            else if !inbound.isEmpty { let value = inbound.removeFirst(); lock.unlock(); c.resume(returning: value) }
            else { receiver = c; lock.unlock() }
        }
    }
    private func enqueue(_ value: String) {
        lock.lock(); let c = receiver; receiver = nil
        if c == nil && !isClosed { inbound.append(value) }
        lock.unlock(); c?.resume(returning: value)
    }
    func close() {
        lock.lock(); isClosed = true; let c = receiver; receiver = nil
        lock.unlock(); c?.resume(throwing: OBSSocketError.notConnected)
    }
    private func encode(_ object: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
}
