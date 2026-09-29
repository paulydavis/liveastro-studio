import XCTest
@testable import LiveAstroCore
@testable import LiveAstroStudio

@MainActor
final class OBSConnectionCheckTests: XCTestCase {
    func testStoreModelOwnsReadOnlyCheckWithoutEnablingBroadcastOrSavingPassword() async throws {
        let wire = CheckSocket(streaming: true, recording: true)
        let (model, defaults) = try modelFixture(preview: true, wire: wire)
        let check = try XCTUnwrap(model.obsConnectionCheck)
        check.password = "operator-secret"
        check.start()
        try await settled(check)
        guard case .checked = check.state else { return XCTFail("integration did not check OBS") }
        XCTAssertEqual(model.broadcast.broadcastState, .unknown, "inspection must not adopt remote output ownership")
        XCTAssertEqual(model.broadcast.obs.state, .disconnected)
        model.broadcast.sceneAutomationOn = true
        model.broadcast.sessionDidStart(subExposureSeconds: 5)
        model.broadcast.sessionDidEnd()
        model.broadcast.stopBroadcastAfterSessionEnd()
        model.broadcast.goLive()
        let allowed = await model.broadcast.connectAndReconcile()
        XCTAssertFalse(allowed)
        XCTAssertEqual(model.broadcast.broadcastState, .unknown)
        XCTAssertEqual(wire.requests, ["GetVersion", "GetStreamStatus", "GetRecordStatus"])
        model.saveSettings()
        XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains("operator-secret"))
        XCTAssertFalse(model.log.joined().contains("operator-secret"))
    }

    func testDirectEditionDoesNotOfferStoreCheck() throws {
        let (model, _) = try modelFixture(preview: false, wire: CheckSocket())
        XCTAssertNil(model.obsConnectionCheck)
    }

    private func modelFixture(preview: Bool, wire: CheckSocket) throws -> (AppModel, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "OBSConnectionCheckTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        }
        let config = StorePreviewConfiguration(bundleIdentifier: preview ? "com.pauldavis.liveastrostudio.store-preview" : "com.pauldavis.liveastrostudio", containerRoot: root)
        return (AppModel(userDefaults: defaults, calibrationLibrary: CalibrationLibrary(baseDirectory: root.appendingPathComponent("library")), configuration: config, makeOBSCheckSocket: { wire }), defaults)
    }

    // Break caught: treating a check as a broadcast session, or treating an active
    // remote output as our own. Only the wire boundary is simulated.
    func testReadsActiveOutputsWithoutAdoptingOrChangingThemAndDisconnects() async throws {
        let wire = CheckSocket(streaming: true, recording: true)
        let check = OBSConnectionCheck(makeSocket: { wire })
        check.host = "127.0.0.1"
        check.port = "4456"
        check.password = "operator-secret"
        check.start()
        XCTAssertTrue(check.isChecking, "reserve the check synchronously")
        try await settled(check)
        guard case .checked(let result) = check.state else { return XCTFail("\(check.state)") }
        XCTAssertTrue(result.streaming)
        XCTAssertTrue(result.recording)
        XCTAssertEqual(result.endpoint, "127.0.0.1:4456")
        XCTAssertEqual(wire.urls.map(\.absoluteString), ["ws://127.0.0.1:4456"])
        XCTAssertEqual(wire.requests, ["GetVersion", "GetStreamStatus", "GetRecordStatus"])
        XCTAssertTrue(wire.closed)
        XCTAssertEqual(wire.identification?["eventSubscriptions"] as? Int, 0)
        XCTAssertEqual(wire.identification?["authentication"] as? String,
            OBSAuth.authString(password: "operator-secret", salt: "fixture-salt", challenge: "fixture-challenge"))
        XCTAssertFalse(wire.frames.joined().contains("operator-secret"))
    }

    func testReadOnlyTransportRefusesWritesBatchesAndUnknownRequests() async throws {
        let wire = CheckSocket()
        let socket = OBSStatusOnlySocket(inner: wire)
        let forbidden: [[String: Any]] = [
            ["op": 6, "d": ["requestType": "StartStream", "requestId": "1"]],
            ["op": 6, "d": ["requestType": "StopStream", "requestId": "2"]],
            ["op": 6, "d": ["requestType": "StartRecord", "requestId": "3"]],
            ["op": 6, "d": ["requestType": "SetCurrentProgramScene", "requestId": "4"]],
            ["op": 8, "d": ["requests": [["requestType": "StartStream"]]]],
            ["op": 6, "d": ["requestType": "GetStreamServiceSettings", "requestId": "5"]]
        ]
        for packet in forbidden {
            do { try await socket.send(try json(packet)); XCTFail("forwarded forbidden request") }
            catch { /* expected: never reaches the actual transport */ }
        }
        XCTAssertTrue(wire.frames.isEmpty)
        socket.close()
    }

    func testInvalidEndpointNeverOpensASocket() {
        var made = 0
        let check = OBSConnectionCheck(makeSocket: { made += 1; return CheckSocket() })
        for (host, port) in [("", "4455"), ("ws://localhost", "4455"),
                             ("user@localhost", "4455"), ("localhost/path", "4455"),
                             ("localhost", "0"), ("localhost", "65536"), ("localhost", "bad")] {
            check.host = host; check.port = port
            check.start()
            guard case .failed = check.state else { XCTFail("accepted invalid endpoint"); continue }
        }
        XCTAssertEqual(made, 0)
    }

    func testMissingMalformedOrFailedStatusIsNotReportedAsInactive() async throws {
        for mode in [CheckSocket.Mode.missing, .numeric, .refused] {
            let wire = CheckSocket(mode: mode)
            let check = OBSConnectionCheck(makeSocket: { wire })
            check.password = "operator-secret"
            check.start()
            try await settled(check)
            guard case .failed(let message) = check.state else { XCTFail("\(check.state)"); continue }
            XCTAssertFalse(message.contains("operator-secret"), "server comments must not leak into UI/logs")
            XCTAssertTrue(wire.closed)
        }
    }

    func testAuthenticationChallengeWithoutPasswordFailsBeforeStatusRequests() async throws {
        let wire = CheckSocket()
        let check = OBSConnectionCheck(makeSocket: { wire })
        check.start()
        try await settled(check)
        guard case .failed = check.state else { return XCTFail("\(check.state)") }
        XCTAssertTrue(wire.requests.isEmpty)
        XCTAssertTrue(wire.closed)
    }

    func testTimeoutFailsAndClosesConnection() async throws {
        let wire = CheckSocket(mode: .parked)
        let check = OBSConnectionCheck(makeSocket: { wire }, timeout: 0.1)
        check.password = "secret"
        check.start()
        try await settled(check)
        guard case .failed = check.state else { return XCTFail("\(check.state)") }
        XCTAssertTrue(wire.closed)
    }

    func testCancelClosesPendingCheckAndAllowsRetryWithoutDuplicateClick() async throws {
        let reached = expectation(description: "first status request parked")
        let old = CheckSocket(mode: .parked, onPark: { reached.fulfill() })
        let current = CheckSocket(streaming: false, recording: true)
        var made = 0
        let check = OBSConnectionCheck(makeSocket: { made += 1; return made == 1 ? old : current })
        check.password = "secret"
        check.start()
        check.start()
        await fulfillment(of: [reached], timeout: 3)
        XCTAssertEqual(made, 1)
        check.cancel()
        XCTAssertEqual(check.state, .cancelled)
        XCTAssertTrue(old.closed)
        check.start()
        try await settled(check)
        guard case .checked(let result) = check.state else { return XCTFail("\(check.state)") }
        XCTAssertFalse(result.streaming)
        XCTAssertTrue(result.recording)
        XCTAssertEqual(made, 2)
    }

    func testEditingSettingsInvalidatesPriorSuccessAndCancelsPendingCheck() async throws {
        let ready = CheckSocket()
        let reached = expectation(description: "status request parked")
        let parked = CheckSocket(mode: .parked, onPark: { reached.fulfill() })
        var made = 0
        let check = OBSConnectionCheck(makeSocket: { made += 1; return made == 1 ? ready : parked })
        check.password = "secret"
        check.start()
        try await settled(check)
        guard case .checked = check.state else { return XCTFail("prerequisite check failed") }
        check.host = "other.local"
        XCTAssertEqual(check.state, .idle)
        check.start()
        await fulfillment(of: [reached], timeout: 3)
        check.password = "replacement"
        XCTAssertEqual(check.state, .idle)
        XCTAssertTrue(parked.closed)
    }

    func testDroppingOwnerClosesInFlightSocket() async throws {
        let reached = expectation(description: "status request parked")
        let wire = CheckSocket(mode: .parked, onPark: { reached.fulfill() })
        var check: OBSConnectionCheck? = OBSConnectionCheck(makeSocket: { wire })
        weak let weakCheck = check
        check?.password = "secret"
        check?.start()
        await fulfillment(of: [reached], timeout: 3)
        check = nil
        XCTAssertNil(weakCheck, "in-flight task must not retain its owner")
        XCTAssertTrue(wire.closed)
    }

    private func settled(_ check: OBSConnectionCheck) async throws {
        let deadline = Date().addingTimeInterval(3)
        while check.isChecking && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(check.isChecking, "check did not terminate before watchdog")
    }
}

private func json(_ object: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

/// Thread-safe wire fixture. Every Get reply echoes the actual issued request ID;
/// only the external WebSocket is simulated, not client auth or response parsing.
private final class CheckSocket: OBSSocket, @unchecked Sendable {
    enum Mode { case normal, missing, numeric, refused, parked }
    private let lock = NSLock()
    private var sent: [String] = []
    private var connectedURLs: [URL] = []
    private var isClosed = false
    private var inbound: [String] = []
    private var receiver: CheckedContinuation<String, Error>?
    private let mode: Mode
    private let streaming: Bool
    private let recording: Bool
    private let onPark: @Sendable () -> Void
    init(streaming: Bool = false, recording: Bool = false, mode: Mode = .normal,
         onPark: @escaping @Sendable () -> Void = {}) {
        self.streaming = streaming; self.recording = recording; self.mode = mode; self.onPark = onPark
    }
    var frames: [String] { lock.withLock { sent } }
    var urls: [URL] { lock.withLock { connectedURLs } }
    var closed: Bool { lock.withLock { isClosed } }
    var packets: [[String: Any]] { frames.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } }
    var requests: [String] { packets.compactMap { ($0["d"] as? [String: Any])?["requestType"] as? String } }
    var identification: [String: Any]? { packets.first { $0["op"] as? Int == 1 }?["d"] as? [String: Any] }
    func connect(url: URL) async throws {
        lock.withLock { connectedURLs.append(url) }
        enqueue(#"{"op":0,"d":{"obsWebSocketVersion":"5.0.0","rpcVersion":1,"authentication":{"salt":"fixture-salt","challenge":"fixture-challenge"}}}"#)
    }
    func send(_ text: String) async throws {
        lock.withLock { sent.append(text) }
        let packet = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        if packet["op"] as? Int == 1 {
            enqueue(#"{"op":2,"d":{"negotiatedRpcVersion":1}}"#); return
        }
        let d = try XCTUnwrap(packet["d"] as? [String: Any])
        let type = try XCTUnwrap(d["requestType"] as? String)
        if mode == .parked { onPark(); return }
        var data: [String: Any]
        switch type {
        case "GetVersion": data = ["obsVersion": "31.1.0", "obsWebSocketVersion": "5.0.0", "rpcVersion": 1, "availableRequests": ["GetStreamStatus", "GetRecordStatus"], "supportedImageFormats": ["png"], "platform": "macos", "platformDescription": "test"]
        case "GetStreamStatus": data = ["outputActive": streaming, "outputReconnecting": false, "outputTimecode": "00:00:00.000", "outputDuration": 0, "outputCongestion": 0, "outputBytes": 0, "outputSkippedFrames": 0, "outputTotalFrames": 0]
        case "GetRecordStatus": data = ["outputActive": recording, "outputPaused": false, "outputTimecode": "00:00:00.000", "outputDuration": 0, "outputBytes": 0]
        default: throw OBSSocketError.notConnected
        }
        if type == "GetRecordStatus" {
            if mode == .missing { data.removeValue(forKey: "outputActive") }
            if mode == .numeric { data["outputActive"] = 1 }
        }
        enqueue(try json(["op": 7, "d": ["requestType": type, "requestId": d["requestId"]!,
            "requestStatus": ["result": mode != .refused, "code": mode == .refused ? 500 : 100, "comment": "operator-secret"],
            "responseData": data]]))
    }
    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if isClosed { lock.unlock(); continuation.resume(throwing: OBSSocketError.notConnected) }
            else if !inbound.isEmpty { let next = inbound.removeFirst(); lock.unlock(); continuation.resume(returning: next) }
            else { receiver = continuation; lock.unlock() }
        }
    }
    private func enqueue(_ value: String) {
        lock.lock()
        let waiting = receiver; receiver = nil
        if waiting == nil && !isClosed { inbound.append(value) }
        lock.unlock()
        waiting?.resume(returning: value)
    }
    func close() {
        lock.lock(); isClosed = true
        let waiting = receiver; receiver = nil
        lock.unlock()
        waiting?.resume(throwing: OBSSocketError.notConnected)
    }
}
