import Foundation
@testable import LiveAstroCore

// MARK: - MockOBSSocket

/// A fully scripted, in-process OBSSocket double for unit tests.
///
/// ## Inbound frames (server → client)
/// Call `enqueueInbound(_:)` to push frames that `receive()` will return in
/// FIFO order. `receive()` suspends (does not busy-spin) until a frame is
/// available, using a `CheckedContinuation`. This means tests can enqueue
/// frames before OR after `receive()` is called:
///
/// ```swift
/// mock.enqueueInbound("""{"op":0,"d":{...}}""")   // before
/// let frame = try await mock.receive()             // pops immediately
/// ```
///
/// or (using a Task to supply the frame concurrently):
///
/// ```swift
/// let task = Task { mock.enqueueInbound("...") }
/// let frame = try await mock.receive()             // suspends, then wakes
/// await task.value
/// ```
///
/// ## Outbound frames (client → server)
/// `send(_:)` appends the text to `sentFrames` in call order.
///
/// ## Reply hook (keyed to last-sent frame)
/// Before calling `send`, install a handler with `replyToLastSent(_:)`. After
/// `send` records the outbound frame, the hook fires and `enqueueInbound` is
/// called with its return value. This models a synchronous server echo/reply:
///
/// ```swift
/// mock.replyToLastSent { sent in return makeResponse(for: sent) }
/// try await mock.send(myRequest)   // records in sentFrames, enqueues reply
/// let reply = try await mock.receive()
/// ```
///
/// ## "Finished" / error injection
/// Call `finishWithError(_:)` to make the next (or current) pending `receive()`
/// throw the supplied error. Call `finish()` to throw `CancellationError`.
///
/// ## Thread safety
/// All state is guarded by a simple actor (`InboundQueue`). Safe to call from
/// concurrent tasks in tests.
final class MockOBSSocket: OBSSocket {

    // MARK: - Public state (test-readable)

    /// All frames passed to `send(_:)`, in order.
    private(set) var sentFrames: [String] = []

    /// Number of `close()` calls observed (review10 finding 6: every failed
    /// post-connect handshake must close the socket it opened).
    private(set) var closeCount = 0

    /// Number of transport connect attempts observed.
    private(set) var connectStartedCount = 0

    // MARK: - Private

    private let queue = InboundQueue()

    /// Optional hook: fired synchronously inside `send(_:)` after recording
    /// the outbound frame. Returns a frame to inject as the next inbound, or
    /// `nil` to inject nothing.
    private var replyHook: ((String) -> String?)?
    private var lastCloseTask: Task<Void, Never>?

    // MARK: - OBSSocket

    func connect(url: URL) async throws {
        connectStartedCount += 1
        // Most tests use terminal errors to model a dead socket that stays
        // dead. A few OBSClient-level reconnect tests deliberately reuse the
        // same mock as a fresh transport; they opt in to clearing the receive
        // terminal state while preserving any queued Hello frame.
        if clearsTerminalOnConnect {
            await queue.resetForConnect()
        }
        if parkConnect {
            await withCheckedContinuation { parkedConnects.append($0) }
        }
    }

    func send(_ text: String) async throws {
        // Park-send knob (review11 finding 1): a matching frame suspends
        // HERE — in flight inside the socket, not yet on the wire — until
        // `releaseParkedSends()`. On release it completes normally (recorded
        // + reply hook): a frame whose `socket.send` began cannot be
        // retracted, mirroring URLSessionWebSocketTask semantics.
        if let match = parkSendsMatching, match(text) {
            parkedSendCount += 1
            await withCheckedContinuation { parkedSends.append($0) }
        }
        sentFrames.append(text)
        if let hook = replyHook, let reply = hook(text) {
            await queue.enqueue(reply)
        }
    }

    func receive() async throws -> String {
        return try await queue.dequeue()
    }

    func close() {
        closeCount += 1
        releaseParkedConnects()
        let task = Task { await queue.finish(throwing: CancellationError()) }
        lastCloseTask = task
    }

    // MARK: - Test-control API

    /// Enqueue a text frame that the next `receive()` call will return.
    func enqueueInbound(_ text: String) {
        Task { await queue.enqueue(text) }
    }

    /// Install a hook that fires after each `send(_:)`. The closure receives
    /// the just-sent frame and may return a reply frame to inject as inbound.
    /// Pass `nil` to clear the hook.
    func replyToLastSent(_ hook: ((String) -> String?)?) {
        replyHook = hook
    }

    /// Make the next (or pending) `receive()` throw `error`.
    func finishWithError(_ error: Error) {
        Task { await queue.finish(throwing: error) }
    }

    /// Make the next (or pending) `receive()` throw `CancellationError`.
    func finish() {
        Task { await queue.finish(throwing: CancellationError()) }
    }

    /// Wait until the actor-side effects of the most recent `close()` have
    /// landed. Tests that reconnect the same mock use this to avoid racing a
    /// fresh connect against the previous close's async receive termination.
    func waitForCloseEffects() async {
        await lastCloseTask?.value
    }

    /// Test seam: let a single mock model a fresh transport after close.
    var clearsTerminalOnConnect = false

    // MARK: - Park-send knob (review11 finding 1)

    /// When set, `send(_:)` calls whose frame matches suspend before the
    /// frame is recorded/answered, until `releaseParkedSends()` runs —
    /// deterministic "send in flight, delivery pending" parking.
    var parkSendsMatching: ((String) -> Bool)?
    /// Number of sends currently or ever parked (monotonic).
    private(set) var parkedSendCount = 0
    private var parkedSends: [CheckedContinuation<Void, Never>] = []

    /// Resume every parked send: the frames reach the wire in call order.
    func releaseParkedSends() {
        let waiting = parkedSends
        parkedSends = []
        for continuation in waiting { continuation.resume() }
    }

    // MARK: - Park-connect knob (Phase 3 transport-deadline regression)

    /// When set, `connect(url:)` suspends before the OBS Hello/Identify
    /// exchange begins, modeling a transport dial/WebSocket open that never
    /// completes.
    var parkConnect = false
    private var parkedConnects: [CheckedContinuation<Void, Never>] = []

    /// Resume every parked connect attempt.
    func releaseParkedConnects() {
        let waiting = parkedConnects
        parkedConnects = []
        for continuation in waiting { continuation.resume() }
    }
}

// MARK: - InboundQueue actor

/// An async FIFO queue backed by continuations.
///
/// Frames enqueued before `dequeue()` is called are buffered.
/// A single pending `dequeue()` awaits a continuation that is resumed by the
/// next `enqueue(_:)` or `finish(throwing:)`.
private actor InboundQueue {

    // Buffered frames not yet consumed by a `dequeue()`.
    private var buffer: [String] = []

    // At most one suspended `dequeue()` waits at a time (single-consumer).
    private var pending: CheckedContinuation<String, Error>?

    // Sticky terminal error — once set, all future dequeues throw immediately.
    private var terminalError: Error?

    func enqueue(_ text: String) {
        if let continuation = pending {
            // A dequeue() is already waiting — resume it directly.
            pending = nil
            continuation.resume(returning: text)
        } else {
            buffer.append(text)
        }
    }

    func finish(throwing error: Error) {
        terminalError = error
        if let continuation = pending {
            pending = nil
            continuation.resume(throwing: error)
        }
        // Future dequeue() calls will throw via the terminalError path.
    }

    func resetForConnect() {
        terminalError = nil
    }

    func dequeue() async throws -> String {
        // Throw immediately if already finished.
        if let err = terminalError { throw err }

        // Return buffered frame if available.
        if !buffer.isEmpty { return buffer.removeFirst() }

        // Otherwise suspend until enqueue or finish.
        return try await withCheckedThrowingContinuation { continuation in
            // Check again inside the actor to avoid a TOCTOU race on buffer.
            if let err = self.terminalError {
                continuation.resume(throwing: err)
                return
            }
            if !self.buffer.isEmpty {
                continuation.resume(returning: self.buffer.removeFirst())
                return
            }
            self.pending = continuation
        }
    }
}
