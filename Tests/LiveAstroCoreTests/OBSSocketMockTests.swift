import XCTest
@testable import LiveAstroCore

/// Tests for MockOBSSocket — the trusted double used by Tasks 5-6.
///
/// Does NOT test URLSessionOBSSocket (that is covered by the Task 8 smoke test).
final class OBSSocketMockTests: XCTestCase {

    // MARK: - Send recording

    /// Frames passed to send() are recorded in order.
    func testSentFramesRecordedInOrder() async throws {
        let mock = MockOBSSocket()
        let url = URL(string: "ws://localhost:4455")!
        try await mock.connect(url: url)

        try await mock.send("frame-A")
        try await mock.send("frame-B")
        try await mock.send("frame-C")

        XCTAssertEqual(mock.sentFrames, ["frame-A", "frame-B", "frame-C"])
    }

    // MARK: - Scripted inbound receive ordering

    /// Inbound frames enqueued before receive() is called are returned in FIFO order.
    func testScriptedInboundFramesReceivedInOrder() async throws {
        let mock = MockOBSSocket()
        mock.enqueueInbound("server-frame-1")
        mock.enqueueInbound("server-frame-2")
        mock.enqueueInbound("server-frame-3")

        // Small yield to let the enqueue Tasks execute on the actor.
        await Task.yield()
        await Task.yield()

        let first  = try await mock.receive()
        let second = try await mock.receive()
        let third  = try await mock.receive()

        XCTAssertEqual(first,  "server-frame-1")
        XCTAssertEqual(second, "server-frame-2")
        XCTAssertEqual(third,  "server-frame-3")
    }

    /// receive() suspends until a frame is enqueued — verifies the
    /// await-not-busy-spin behaviour by racing a Task that delivers the frame.
    func testReceiveAwaitsFrameDeliveredConcurrently() async throws {
        let mock = MockOBSSocket()

        // Start receive() first — it must suspend, not throw.
        async let received: String = mock.receive()

        // Yield so the above task actually suspends.
        await Task.yield()

        // Now deliver the frame from "outside".
        mock.enqueueInbound("late-delivery")

        let result = try await received
        XCTAssertEqual(result, "late-delivery")
    }

    // MARK: - Reply hook (last-sent keyed reply)

    /// The reply hook fires after send() and its return value is enqueued as
    /// the next inbound frame. Models a synchronous server response.
    func testReplyHookEnqueuesInboundKeyedToLastSent() async throws {
        let mock = MockOBSSocket()

        // Install a hook that echoes the sent frame with a ">" prefix.
        mock.replyToLastSent { sent in
            return "reply-to:\(sent)"
        }

        try await mock.send("GetVersion")
        let reply = try await mock.receive()

        XCTAssertEqual(reply, "reply-to:GetVersion")
        XCTAssertEqual(mock.sentFrames, ["GetVersion"])
    }

    /// Multiple sends each trigger the hook independently, in order.
    func testReplyHookFiresForEachSend() async throws {
        let mock = MockOBSSocket()
        mock.replyToLastSent { sent in "ack:\(sent)" }

        try await mock.send("req-1")
        try await mock.send("req-2")

        // Yield to let enqueue Tasks settle on the actor.
        await Task.yield()
        await Task.yield()

        let r1 = try await mock.receive()
        let r2 = try await mock.receive()

        XCTAssertEqual(r1, "ack:req-1")
        XCTAssertEqual(r2, "ack:req-2")
    }

    // MARK: - Finish / error injection

    /// finishWithError makes receive() throw the supplied error.
    func testFinishWithErrorMakesReceiveThrow() async throws {
        struct TestError: Error, Equatable {}
        let mock = MockOBSSocket()

        mock.finishWithError(TestError())

        await Task.yield()
        await Task.yield()

        do {
            _ = try await mock.receive()
            XCTFail("Expected receive() to throw")
        } catch is TestError {
            // expected
        }
    }
}
