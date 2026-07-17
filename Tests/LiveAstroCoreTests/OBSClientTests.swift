import XCTest
@testable import LiveAstroCore

/// Tests for OBSClient — handshake, request/response correlation, events.
///
/// Drives the client through `MockOBSSocket` (the trusted double from Task 4).
/// The deterministic path is the reply hook (`replyToLastSent`), which enqueues
/// its reply synchronously inside `send(_:)` in send order. Handshake frames are
/// scripted by enqueueing Hello up front and answering the Identify send with
/// Identified via the hook.
final class OBSClientTests: XCTestCase {

    private let url = URL(string: "ws://localhost:4455")!

    // MARK: - Frame builders

    private func helloFrame(salt: String? = nil, challenge: String? = nil) -> String {
        var d: [String: Any] = ["rpcVersion": 1]
        if let salt, let challenge {
            d["authentication"] = ["salt": salt, "challenge": challenge]
        }
        return json(["op": 0, "d": d])
    }

    private let identifiedFrame = #"{"op":2,"d":{"negotiatedRpcVersion":1}}"#

    private func responseFrame(requestId: String,
                               requestType: String = "GetVersion",
                               ok: Bool,
                               code: Int,
                               comment: String? = nil,
                               responseData: [String: Any] = [:]) -> String {
        var status: [String: Any] = ["result": ok, "code": code]
        if let comment { status["comment"] = comment }
        let d: [String: Any] = [
            "requestId": requestId,
            "requestType": requestType,
            "requestStatus": status,
            "responseData": responseData
        ]
        return json(["op": 7, "d": d])
    }

    private func eventFrame(type: String, data: [String: Any]) -> String {
        let d: [String: Any] = ["eventType": type, "eventData": data]
        return json(["op": 5, "d": d])
    }

    private func json(_ obj: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }

    /// Extract `requestId` from a sent op-6 frame.
    private func requestId(fromSent frame: String) -> String {
        let data = frame.data(using: .utf8)!
        let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let d = obj["d"] as! [String: Any]
        return d["requestId"] as! String
    }

    private func requestType(fromSent frame: String) -> String {
        let data = frame.data(using: .utf8)!
        let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let d = obj["d"] as! [String: Any]
        return d["requestType"] as! String
    }

    /// Extract `authentication` string from a sent op-1 Identify frame (nil if absent).
    private func authString(fromSent frame: String) -> String? {
        let data = frame.data(using: .utf8)!
        let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let d = obj["d"] as! [String: Any]
        return d["authentication"] as? String
    }

    // MARK: - Handshake

    func testHandshakeNoAuth() async throws {
        let mock = MockOBSSocket()
        let client = OBSClient(socket: mock)

        mock.enqueueInbound(helloFrame())
        // Answer the Identify (op 1) with Identified (op 2).
        mock.replyToLastSent { [identifiedFrame] sent in
            sent.contains("\"op\":1") ? identifiedFrame : nil
        }

        try await client.connect(url: url, password: nil)

        // Exactly one frame sent: the Identify. No authentication key.
        XCTAssertEqual(mock.sentFrames.count, 1)
        XCTAssertNil(authString(fromSent: mock.sentFrames[0]),
                     "Identify must omit authentication when Hello has none")

        await client.disconnect()
    }

    func testHandshakeWithAuth() async throws {
        let mock = MockOBSSocket()
        let client = OBSClient(socket: mock)

        let salt = "someSalt"
        let challenge = "someChallenge"
        let password = "supersecret"
        let expected = OBSAuth.authString(password: password, salt: salt, challenge: challenge)

        mock.enqueueInbound(helloFrame(salt: salt, challenge: challenge))
        mock.replyToLastSent { [identifiedFrame] sent in
            sent.contains("\"op\":1") ? identifiedFrame : nil
        }

        try await client.connect(url: url, password: password)

        XCTAssertEqual(mock.sentFrames.count, 1)
        XCTAssertEqual(authString(fromSent: mock.sentFrames[0]), expected,
                       "Identify must carry the exact OBSAuth string")

        await client.disconnect()
    }

    // MARK: - Request / response correlation

    /// Connect helper: scripts Hello + Identified, returns after connected.
    /// Leaves a hook installed that only answers Identify; caller replaces it.
    private func connect(_ client: OBSClient,
                         _ mock: MockOBSSocket,
                         password: String? = nil) async throws {
        mock.enqueueInbound(helloFrame())
        mock.replyToLastSent { [identifiedFrame] sent in
            sent.contains("\"op\":1") ? identifiedFrame : nil
        }
        try await client.connect(url: url, password: password)
    }

    func testRequestResponseCorrelation() async throws {
        let mock = MockOBSSocket()
        let client = OBSClient(socket: mock)
        try await connect(client, mock)

        // Answer each op-6 with a matching op-7 carrying the same requestId.
        mock.replyToLastSent { [weak self] sent in
            guard let self, sent.contains("\"op\":6") else { return nil }
            let id = self.requestId(fromSent: sent)
            return self.responseFrame(requestId: id, ok: true, code: 100,
                                      responseData: ["obsVersion": "30.0"])
        }

        let result = try await client.request("GetVersion", data: nil)
        XCTAssertEqual(result["obsVersion"] as? String, "30.0")

        await client.disconnect()
    }

    func testRequestFailureThrows() async throws {
        let mock = MockOBSSocket()
        let client = OBSClient(socket: mock)
        try await connect(client, mock)

        mock.replyToLastSent { [weak self] sent in
            guard let self, sent.contains("\"op\":6") else { return nil }
            let id = self.requestId(fromSent: sent)
            return self.responseFrame(requestId: id, ok: false, code: 604,
                                      comment: "resource not found")
        }

        do {
            _ = try await client.request("SetCurrentProgramScene", data: ["sceneName": "x"])
            XCTFail("Expected .requestFailed")
        } catch let OBSClient.OBSError.requestFailed(code, comment) {
            XCTAssertEqual(code, 604)
            XCTAssertEqual(comment, "resource not found")
        }

        await client.disconnect()
    }

    /// Two in-flight requests get out-of-order responses; each caller gets its own.
    func testOutOfOrderResponsesCorrelate() async throws {
        let mock = MockOBSSocket()
        let client = OBSClient(socket: mock)
        try await connect(client, mock)

        // Capture the two request ids as they are sent, but DON'T auto-reply.
        // We enqueue responses in reverse order after both are in flight.
        mock.replyToLastSent(nil)

        async let r1 = client.request("First", data: nil)
        async let r2 = client.request("Second", data: nil)

        // Wait until both op-6 frames have been recorded.
        try await waitUntil { mock.sentFrames.filter { $0.contains("\"op\":6") }.count == 2 }

        let sent6 = mock.sentFrames.filter { $0.contains("\"op\":6") }
        // Match each id to its request TYPE, not its position in `sent6`. The two
        // `async let` requests send concurrently via child Tasks, so their frames
        // can be recorded in EITHER order — indexing sent6[0]/[1] would flip the
        // id↔request mapping under that race and mis-address the responses.
        let firstFrame = sent6.first { requestType(fromSent: $0) == "First" }!
        let secondFrame = sent6.first { requestType(fromSent: $0) == "Second" }!
        let firstId = requestId(fromSent: firstFrame)
        let secondId = requestId(fromSent: secondFrame)

        // Respond to the SECOND request first, then the first (out of order).
        mock.enqueueInbound(responseFrame(requestId: secondId, requestType: "Second", ok: true,
                                          code: 100, responseData: ["which": "second"]))
        mock.enqueueInbound(responseFrame(requestId: firstId, requestType: "First", ok: true,
                                          code: 100, responseData: ["which": "first"]))

        let d1 = try await r1
        let d2 = try await r2
        XCTAssertEqual(d1["which"] as? String, "first")
        XCTAssertEqual(d2["which"] as? String, "second")

        await client.disconnect()
    }

    // MARK: - Event routing

    func testEventRouting() async throws {
        let mock = MockOBSSocket()
        let client = OBSClient(socket: mock)
        try await connect(client, mock)

        var iterator = client.events.makeAsyncIterator()

        mock.enqueueInbound(eventFrame(type: "StreamStateChanged",
                                       data: ["outputActive": true]))

        let event = await iterator.next()
        XCTAssertEqual(event?.type, "StreamStateChanged")
        XCTAssertEqual(event?.data["outputActive"] as? Bool, true)

        await client.disconnect()
    }

    // MARK: - Timeout

    /// A request with no response times out. Uses an injected short interval so
    /// the test is fast (production default is 10 s).
    func testRequestTimeout() async throws {
        let mock = MockOBSSocket()
        let client = OBSClient(socket: mock, requestTimeout: 0.1)
        try await connect(client, mock)

        mock.replyToLastSent(nil)   // never answer

        do {
            _ = try await client.request("GetVersion", data: nil)
            XCTFail("Expected .timeout")
        } catch OBSClient.OBSError.timeout {
            // expected
        }

        await client.disconnect()
    }

    /// Requests pending at disconnect() fail with .notConnected.
    func testDisconnectFailsPendingRequests() async throws {
        let mock = MockOBSSocket()
        let client = OBSClient(socket: mock, requestTimeout: 5)
        try await connect(client, mock)

        mock.replyToLastSent(nil)   // never answer

        async let pending = client.request("GetVersion", data: nil)
        try await waitUntil { mock.sentFrames.filter { $0.contains("\"op\":6") }.count == 1 }

        await client.disconnect()

        do {
            _ = try await pending
            XCTFail("Expected .notConnected")
        } catch OBSClient.OBSError.notConnected {
            // expected
        }
    }

    // MARK: - Connection-loss signalling (review8 item 3)

    /// The receive loop's death must FINISH the events stream — that finish is
    /// the connection-loss signal consumers rely on. Pre-fix the stream was
    /// never finished when the loop died, so nothing downstream could tell.
    func testReceiveLoopFailureFinishesEventStream() async throws {
        let mock = MockOBSSocket()
        let client = OBSClient(socket: mock, requestTimeout: 10)
        try await connect(client, mock)

        let exp = expectation(description: "events stream finished")
        let consumer = Task {
            for await _ in client.events { }
            exp.fulfill()
        }

        mock.finishWithError(OBSSocketError.notConnected)   // the socket dies
        await fulfillment(of: [exp], timeout: 2)
        consumer.cancel()
        await client.disconnect()
    }

    // MARK: - Socket hygiene on handshake failure (review10 finding 6)

    /// A handshake that fails AFTER the socket opened must close that socket
    /// before throwing — pre-fix the auth-required-but-missing-password path
    /// (and every other post-connect failure) leaked the open connection.
    func testHandshakeAuthRequiredWithoutPasswordClosesSocket() async {
        let mock = MockOBSSocket()
        let client = OBSClient(socket: mock)
        mock.enqueueInbound(helloFrame(salt: "s", challenge: "c"))   // server demands auth

        do {
            try await client.connect(url: url, password: nil)
            XCTFail("Expected .authFailed")
        } catch OBSClient.OBSError.authFailed {
            // expected
        } catch {
            XCTFail("Expected .authFailed, got \(error)")
        }
        XCTAssertEqual(mock.closeCount, 1,
                       "a failed handshake must close the socket it opened")
    }

    /// A bad Identified reply (post-send failure path) also closes the socket.
    func testHandshakeBadIdentifiedClosesSocket() async {
        let mock = MockOBSSocket()
        let client = OBSClient(socket: mock)
        mock.enqueueInbound(helloFrame())
        // Answer the Identify with a non-Identified frame.
        mock.replyToLastSent { sent in
            sent.contains("\"op\":1")
                ? #"{"op":5,"d":{"eventType":"Nope","eventData":{}}}"# : nil
        }

        do {
            try await client.connect(url: url, password: nil)
            XCTFail("Expected .authFailed")
        } catch OBSClient.OBSError.authFailed {
            // expected
        } catch {
            XCTFail("Expected .authFailed, got \(error)")
        }
        XCTAssertEqual(mock.closeCount, 1)
    }

    /// N failed handshake retries → N closes, zero live sockets (the
    /// auto-launch retry loop must not accumulate orphaned connections).
    func testRepeatedHandshakeFailuresCloseEverySocket() async {
        let mock = MockOBSSocket()
        for n in 1...3 {
            let client = OBSClient(socket: mock)
            mock.enqueueInbound(helloFrame(salt: "s", challenge: "c"))
            do {
                try await client.connect(url: url, password: nil)
                XCTFail("Expected a handshake failure")
            } catch {
                // any failure path — the socket must still be closed
            }
            XCTAssertEqual(mock.closeCount, n,
                           "every failed handshake must close its socket")
        }
    }

    // MARK: - Cancellation (review8 item 1)

    /// A request whose task is cancelled BEFORE the request body runs resumes
    /// immediately with CancellationError and sends NOTHING — the cancel-before-
    /// continuation-registration race must not wait out the timeout.
    func testRequestCancelledBeforeStartResolvesImmediatelyAndSendsNothing() async throws {
        let mock = MockOBSSocket()
        let client = OBSClient(socket: mock, requestTimeout: 10)
        try await connect(client, mock)
        mock.replyToLastSent(nil)
        let sentBefore = mock.sentFrames.count

        let task = Task { try await client.request("GetVersion", data: nil) }
        task.cancel()   // before the request body ever runs

        let started = Date()
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2,
                          "a pre-cancelled request must not wait for the 10 s timeout")
        // The send must never have been enqueued — cancellation was confirmed
        // before the issuance boundary.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(mock.sentFrames.count, sentBefore,
                       "a request cancelled before enqueue must send no frame")
    }

    /// A request cancelled while in flight (sent, unanswered) resumes promptly
    /// with CancellationError instead of hanging until the timeout.
    func testRequestCancelledInFlightResolvesPromptly() async throws {
        let mock = MockOBSSocket()
        let client = OBSClient(socket: mock, requestTimeout: 10)
        try await connect(client, mock)
        mock.replyToLastSent(nil)   // never answer

        let task = Task { try await client.request("GetVersion", data: nil) }
        try await waitUntil { mock.sentFrames.filter { $0.contains("\"op\":6") }.count == 1 }

        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2,
                          "an in-flight cancel must resolve promptly, not at the timeout")
    }

    // MARK: - Tracked sends + outbound ordering (review11 finding 1)

    /// The send of a request resolved by CANCELLATION before its frame
    /// reached the socket must never transmit. Pre-fix the send lived in an
    /// UNTRACKED Task: the caller's cancellation resolved the continuation,
    /// but the frame still hit the socket arbitrarily late. The scheduling
    /// is made deterministic by parking an EARLIER send in the socket —
    /// outbound sends are FIFO, so the second request's frame is provably
    /// still queued (not in the socket) when the cancel lands.
    func testCancelledRequestQueuedBehindParkedSendNeverTransmits() async throws {
        let mock = MockOBSSocket()
        let client = OBSClient(socket: mock, requestTimeout: 10)
        try await connect(client, mock)
        mock.replyToLastSent(nil)

        // Request A: its send parks inside the socket (in flight).
        mock.parkSendsMatching = { $0.contains("First") }
        let taskA = Task { try await client.request("First", data: nil) }
        try await waitUntil { mock.parkedSendCount == 1 }

        // Request B: issued while A's send is in flight — B's frame must not
        // overtake A's (outbound FIFO), so it is still queued, not sent.
        let taskB = Task { try await client.request("Second", data: nil) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(mock.sentFrames.contains { $0.contains("Second") },
                       "a later send must never overtake an earlier in-flight send")

        // Cancel B while its send is still queued: confirmed never-sent.
        taskB.cancel()
        do {
            _ = try await taskB.value
            XCTFail("Expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }

        // Release A's send: A transmits; B's cancelled send must NOT follow.
        mock.releaseParkedSends()
        try await waitUntil { mock.sentFrames.contains { $0.contains("First") } }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(mock.sentFrames.contains { $0.contains("Second") },
                       "a request cancelled before its send reached the socket must never transmit")

        taskA.cancel()
        _ = try? await taskA.value
        await client.disconnect()
    }

    /// Timeout flavor: a request whose send is still queued behind an
    /// in-flight send when the timeout fires must never transmit either —
    /// every resolution path cancels the tracked send.
    func testTimedOutRequestQueuedBehindParkedSendNeverTransmits() async throws {
        let mock = MockOBSSocket()
        let client = OBSClient(socket: mock, requestTimeout: 0.1)
        try await connect(client, mock)
        mock.replyToLastSent(nil)

        mock.parkSendsMatching = { $0.contains("First") }
        let taskA = Task { try await client.request("First", data: nil) }
        try await waitUntil { mock.parkedSendCount == 1 }

        let taskB = Task { try await client.request("Second", data: nil) }
        do {
            _ = try await taskB.value
            XCTFail("Expected .timeout")
        } catch OBSClient.OBSError.timeout {
            // expected — resolved by the timeout while the send was queued
        }

        mock.releaseParkedSends()
        try await waitUntil { mock.sentFrames.contains { $0.contains("First") } }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(mock.sentFrames.contains { $0.contains("Second") },
                       "a timed-out request's queued send must never transmit")

        _ = try? await taskA.value
        await client.disconnect()
    }

    /// A parked send from a disconnected session must not poison the outbound
    /// FIFO chain for a later connection. Pre-fix `disconnect()` cancelled the
    /// tracked send task but left `sendChainTail` pointing at the parked task;
    /// the first request after reconnect waited behind that stale tail until
    /// its own timeout.
    func testDisconnectAbandonsParkedSendChainSoReconnectRequestsAreNotPoisoned() async throws {
        let mock = MockOBSSocket()
        mock.clearsTerminalOnConnect = true
        let client = OBSClient(socket: mock, requestTimeout: 0.1)
        try await connect(client, mock)

        mock.replyToLastSent(nil)
        mock.parkSendsMatching = { $0.contains("\"requestType\":\"GetVersion\"") }
        let poisoned = Task { try? await client.request("GetVersion", data: nil) }
        try await waitUntil { mock.parkedSendCount == 1 }
        await client.disconnect()
        await mock.waitForCloseEffects()

        mock.parkSendsMatching = nil
        mock.enqueueInbound(helloFrame())
        mock.replyToLastSent { [weak self, identifiedFrame] sent in
            guard let self else { return nil }
            if sent.contains("\"op\":1") { return identifiedFrame }
            if sent.contains("\"requestType\":\"GetStats\"") {
                return self.responseFrame(requestId: self.requestId(fromSent: sent),
                                          requestType: "GetStats",
                                          ok: true,
                                          code: 100,
                                          responseData: ["ok": true])
            }
            return nil
        }

        try await client.connect(url: url, password: nil)
        let response = try await client.request("GetStats", data: nil)
        XCTAssertEqual(response["ok"] as? Bool, true)

        mock.releaseParkedSends()
        _ = await poisoned.value
        await client.disconnect()
    }

    // MARK: - cold2 I-2: bounded handshake

    /// Lock-guarded outcome capture for a connect attempt that (pre-fix) never returns.
    private final class ConnectOutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _done = false
        private var _error: Error?
        func finish(error: Error?) { lock.withLock { _done = true; _error = error } }
        var isDone: Bool { lock.withLock { _done } }
        var error: Error? { lock.withLock { _error } }
    }

    /// Cold2 I-2 (P1, red-first): a wedge that ACCEPTS the connection but never sends
    /// Hello parked `connect` forever — the caller sat in `.connecting` indefinitely,
    /// auto-launch never engaged (its budget starts only after the first connect
    /// returns), and the wedged attempt poisoned OBSController's connect coalescing for
    /// every later attempt. The handshake is now BOUNDED (default: the request timeout);
    /// on expiry the socket is CLOSED (the review10 failed-handshake-closes-socket
    /// discipline) and connect throws `.timeout`.
    func testConnectTimesOutWhenHelloNeverArrives_closesSocket() async {
        let mock = MockOBSSocket()                     // accepts connect; Hello never comes
        let client = OBSClient(socket: mock, requestTimeout: 0.2)
        let box = ConnectOutcomeBox()
        Task { [url] in
            do {
                try await client.connect(url: url, password: nil)
                box.finish(error: nil)
            } catch {
                box.finish(error: error)
            }
        }
        let deadline = Date().addingTimeInterval(3)   // >> the 0.2 s handshake bound
        while !box.isDone && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(box.isDone,
                      "connect must fail within the handshake bound — a missing Hello must not park it forever")
        XCTAssertEqual(box.error as? OBSClient.OBSError, .timeout,
                       "the expiry is reported as a timeout — got \(String(describing: box.error))")
        XCTAssertGreaterThanOrEqual(mock.closeCount, 1,
                                    "the expired handshake must close the socket it opened")
    }

    /// The same deadline must cover the transport connect itself, not only
    /// Hello→Identify after `socket.connect` returns. This is bounded so the
    /// pre-fix hang fails quickly instead of waiting for XCTest's timeout.
    func testConnectTimeoutCoversTransportConnectBeforeHello() async {
        let mock = MockOBSSocket()
        mock.parkConnect = true
        let client = OBSClient(socket: mock, requestTimeout: 10, handshakeTimeout: 0.05)
        let box = ConnectOutcomeBox()

        Task { [url] in
            do {
                try await client.connect(url: url, password: nil)
                box.finish(error: nil)
            } catch {
                box.finish(error: error)
            }
        }

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(box.isDone,
                      "transport connect must be bounded by the OBS connect deadline")
        XCTAssertEqual(box.error as? OBSClient.OBSError, .timeout,
                       "transport wedge should report .timeout, got \(String(describing: box.error))")
        XCTAssertEqual(mock.connectStartedCount, 1)
        XCTAssertEqual(mock.closeCount, 1, "timeout closes the transport attempt")

        mock.releaseParkedConnects()
    }

    /// The watchdog must not fire on a HEALTHY handshake: connect succeeds well inside
    /// the bound and the socket stays open for the session.
    func testHandshakeWithinBoundConnectsAndSocketStaysOpen() async throws {
        let mock = MockOBSSocket()
        let client = OBSClient(socket: mock, requestTimeout: 0.5)
        try await connect(client, mock)
        try? await Task.sleep(nanoseconds: 700_000_000)   // past the (cancelled) watchdog
        XCTAssertEqual(mock.closeCount, 0,
                       "a completed handshake must never be closed by the expired watchdog")
        await client.disconnect()
    }

    // MARK: - Helpers

    /// Poll an async predicate until true or a deadline; fail the test on timeout.
    private func waitUntil(_ predicate: @escaping () async -> Bool,
                           timeout: TimeInterval = 2,
                           file: StaticString = #filePath,
                           line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 2_000_000)   // 2 ms
        }
        XCTFail("waitUntil timed out", file: file, line: line)
    }
}
