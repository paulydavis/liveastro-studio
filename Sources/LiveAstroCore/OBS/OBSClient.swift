import Foundation

/// obs-websocket 5.x client: drives the Hello→Identify→Identified handshake,
/// correlates request/response frames by `requestId`, and surfaces events.
///
/// Transport is injected via `OBSSocket` so the handshake and request loop can
/// be unit-tested against `MockOBSSocket` without a real WebSocket.
///
/// The actor serializes all mutable state (pending requests, connection flags,
/// the events continuation). A single detached receive loop reads frames from
/// the socket and feeds each one back into the actor via `handle(frame:)`, so
/// routing runs under actor isolation too.
public actor OBSClient {

    // MARK: - Errors

    public enum OBSError: Error, Equatable {
        case notConnected
        case timeout
        case requestFailed(code: Int, comment: String?)
        case authFailed
    }

    // MARK: - Constants

    private static let rpcVersion = 1
    /// Subscribe to all non-high-volume event categories (obs-websocket default set).
    private static let eventSubscriptions = 0x7FF

    // MARK: - Dependencies / config

    private let socket: OBSSocket
    private let requestTimeout: TimeInterval

    // MARK: - State

    private var connected = false
    private var receiveLoop: Task<Void, Never>?

    /// Pending request continuations keyed by the requestId (UUID string) we sent.
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]

    // MARK: - Events

    private nonisolated let eventStream: AsyncStream<(type: String, data: [String: Any])>
    private let eventContinuation: AsyncStream<(type: String, data: [String: Any])>.Continuation

    /// Stream of OBS events (op 5). Yields `(eventType, eventData)`.
    public nonisolated var events: AsyncStream<(type: String, data: [String: Any])> {
        eventStream
    }

    // MARK: - Init

    /// - Parameters:
    ///   - socket: transport seam.
    ///   - requestTimeout: seconds a `request(_:data:)` waits before throwing
    ///     `.timeout`. Defaults to 10 s; tests may inject a small value.
    public init(socket: OBSSocket, requestTimeout: TimeInterval = 10) {
        self.socket = socket
        self.requestTimeout = requestTimeout
        var cont: AsyncStream<(type: String, data: [String: Any])>.Continuation!
        self.eventStream = AsyncStream { cont = $0 }
        self.eventContinuation = cont
    }

    // MARK: - Connect

    /// Perform the obs-websocket handshake: receive Hello, send Identify
    /// (with auth computed from the Hello challenge when a password is supplied
    /// and the server requires it), and wait for Identified.
    public func connect(url: URL, password: String?) async throws {
        try await socket.connect(url: url)

        // 1. Hello (op 0).
        let helloText = try await socket.receive()
        guard case .hello(let hello)? = OBSMessage.parse(helloText) else {
            throw OBSError.notConnected
        }

        // 2. Compute auth if the server presented a challenge.
        let auth: String?
        if let challenge = hello.authentication {
            guard let password, !password.isEmpty else {
                throw OBSError.authFailed
            }
            auth = OBSAuth.authString(password: password,
                                      salt: challenge.salt,
                                      challenge: challenge.challenge)
        } else {
            auth = nil
        }

        // 3. Send Identify.
        let identify = OBSMessage.identify(rpcVersion: Self.rpcVersion,
                                           auth: auth,
                                           eventSubscriptions: Self.eventSubscriptions)
        try await socket.send(identify)

        // 4. Wait for Identified (op 2).
        let identifiedText = try await socket.receive()
        guard case .identified? = OBSMessage.parse(identifiedText) else {
            throw OBSError.authFailed
        }

        connected = true
        startReceiveLoop()
    }

    // MARK: - Request

    /// Send an op-6 request and await its op-7 response. Returns `responseData`
    /// on success; throws `.requestFailed` on `ok == false`, `.timeout` after
    /// `requestTimeout`, `.notConnected` if the client is/gets disconnected, or
    /// `CancellationError` when the calling task is cancelled.
    ///
    /// Cancellation-aware (review8 item 1): a caller cancelled BEFORE the send
    /// is enqueued resumes immediately with `CancellationError` and the frame is
    /// guaranteed NOT sent; a caller cancelled after the send is in flight also
    /// resumes with `CancellationError`, but the frame may have reached OBS —
    /// callers must treat that outcome as "possibly issued".
    public func request(_ type: String, data: [String: Any]?) async throws -> [String: Any] {
        guard connected else { throw OBSError.notConnected }

        let id = UUID().uuidString
        let frame = OBSMessage.request(type: type, id: id, data: data)

        // Arm a timeout that resolves the pending entry if no response arrives.
        let timeoutNanos = UInt64(requestTimeout * 1_000_000_000)
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanos)
            await self?.failPending(id: id, error: OBSError.timeout)
        }

        defer { timeoutTask.cancel() }
        return try await withTaskCancellationHandler {
            try await awaitResponse(id: id, frame: frame)
        } onCancel: {
            // Runs outside actor isolation — hop back in to resolve the pending
            // entry. If the entry isn't registered yet (cancel-before-
            // registration race), this no-ops and awaitResponse's own
            // Task.isCancelled check resumes the continuation instead.
            Task { [weak self] in
                await self?.failPending(id: id, error: CancellationError())
            }
        }
    }

    /// Register the continuation and enqueue the send, both under actor
    /// isolation in ONE synchronous segment.
    ///
    /// Cancel-BEFORE-registration race, handled explicitly: the cancellation
    /// handler may have fired before this body runs (it only spawns an actor
    /// hop, which cannot interleave mid-segment). `Task.isCancelled` is
    /// monotonic, so checking it here catches every such cancel — the request
    /// resumes with `CancellationError` immediately (never waits out the
    /// timeout) and, critically, the send is NEVER enqueued: cancellation
    /// observed before this check is a confirmed not-sent.
    private func awaitResponse(id: String, frame: String) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
                return
            }
            pending[id] = continuation
            // Send inside a child Task so we stay non-suspending here; if the
            // send fails, resolve the continuation with .notConnected.
            Task { [weak self] in
                do {
                    try await self?.sendFrame(frame)
                } catch {
                    await self?.failPending(id: id, error: OBSError.notConnected)
                }
            }
        }
    }

    private func sendFrame(_ frame: String) async throws {
        try await socket.send(frame)
    }

    // MARK: - Disconnect

    /// Close the socket, cancel the receive loop, fail all pending requests with
    /// `.notConnected`, and finish the events stream.
    public func disconnect() {
        connected = false
        receiveLoop?.cancel()
        receiveLoop = nil

        // Fail every in-flight request.
        let inflight = pending
        pending.removeAll()
        for (_, continuation) in inflight {
            continuation.resume(throwing: OBSError.notConnected)
        }

        eventContinuation.finish()
        socket.close()
    }

    // MARK: - Receive loop

    private func startReceiveLoop() {
        receiveLoop = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let text: String
                do {
                    text = try await self.receiveFrame()
                } catch {
                    // Deliberate disconnects cancel this loop BEFORE closing the
                    // socket — their teardown owns the signalling. Only an
                    // UNEXPECTED death may surface connection loss.
                    if Task.isCancelled { return }
                    await self.receiveLoopDied()
                    return
                }
                await self.handle(frame: text)
            }
        }
    }

    /// The receive loop died unexpectedly (socket closed or errored): fail all
    /// pending requests and FINISH the events stream. The stream's finish IS
    /// the connection-loss signal consumers rely on (review8 item 3 — pre-fix
    /// the stream was never finished on receive-loop death, so downstream
    /// state machines could not see the socket loss).
    private func receiveLoopDied() {
        failAll(error: OBSError.notConnected)   // also sets connected = false
        eventContinuation.finish()
    }

    private func receiveFrame() async throws -> String {
        try await socket.receive()
    }

    /// Route a single inbound frame. Runs under actor isolation.
    private func handle(frame text: String) {
        switch OBSMessage.parse(text) {
        case .response(let response):
            guard let continuation = pending.removeValue(forKey: response.requestId) else {
                // Unknown or already-resolved (timed-out) requestId — drop it.
                return
            }
            if response.ok {
                continuation.resume(returning: response.responseData)
            } else {
                continuation.resume(throwing: OBSError.requestFailed(
                    code: response.code, comment: response.comment))
            }

        case .event(let type, let data):
            eventContinuation.yield((type: type, data: data))

        case .hello, .identified, .unknown, .none:
            // Not expected during steady state — ignore.
            break
        }
    }

    // MARK: - Pending resolution helpers

    /// Resolve a single pending request with an error, if it is still pending.
    private func failPending(id: String, error: Error) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
    }

    /// Fail every pending request (used when the socket dies).
    private func failAll(error: Error) {
        connected = false
        let inflight = pending
        pending.removeAll()
        for (_, continuation) in inflight {
            continuation.resume(throwing: error)
        }
    }
}
