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
        try await waitUntil { await mock.sentFrames.filter { $0.contains("\"op\":6") }.count == 2 }

        let sent6 = await mock.sentFrames.filter { $0.contains("\"op\":6") }
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

        var iterator = await client.events.makeAsyncIterator()

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
        try await waitUntil { await mock.sentFrames.filter { $0.contains("\"op\":6") }.count == 1 }

        await client.disconnect()

        do {
            _ = try await pending
            XCTFail("Expected .notConnected")
        } catch OBSClient.OBSError.notConnected {
            // expected
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
        try await waitUntil { await mock.sentFrames.filter { $0.contains("\"op\":6") }.count == 1 }

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
