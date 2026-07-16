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

    /// The TRACKED send task of each pending request (review11 finding 1 —
    /// P1). Pre-fix the send lived in an untracked Task: a request resolved
    /// by timeout/cancellation left its send alive, and the frame could hit
    /// OBS arbitrarily late — a StartStream landing AFTER cleanup had
    /// confirmed OBS idle. Every resolution path (`failPending`, `failAll`,
    /// disconnect teardown) now cancels the tracked send: a send that has
    /// not yet reached `socket.send` when the cancel is observed is
    /// CONFIRMED never sent. A send already inside `socket.send` cannot be
    /// retracted (URLSession offers no mid-transmission abort guarantee) —
    /// that residual window stays "possibly issued" for callers, and the
    /// send CHAIN below guarantees no later frame can overtake it.
    private var sendTasks: [String: Task<Void, Never>] = [:]

    /// Tail of the outbound send chain (review11 finding 1, ordering half):
    /// every request send awaits the previous send task's completion before
    /// touching the socket, so outbound frames keep ISSUE order end to end
    /// regardless of transport internals. A cleanup StopStream can never
    /// overtake an earlier, still-unresolved StartStream — "Start delivered
    /// after Stop" is structurally impossible; if the ambiguous send never
    /// resolves, the queued stop times out and the caller settles
    /// `.stopUnconfirmed` (never a confirmed idle over an unprovable order).
    private var sendChainTail: Task<Void, Never>?

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
    ///
    /// Review10 finding 6 (SPLIT-SNAPSHOT/OWNERSHIP RACES — ownership half):
    /// once `socket.connect` has opened a connection, this method OWNS it.
    /// Every post-connect failure path (bad Hello, auth required but missing,
    /// send failure, bad Identified) closes the socket before throwing —
    /// pre-fix the failed handshakes leaked the open connection, and the
    /// auto-launch retry loop accumulated orphaned sockets.
    public func connect(url: URL, password: String?) async throws {
        try await socket.connect(url: url)
        do {
            try await performHandshake(password: password)
        } catch {
            socket.close()   // single exit for every post-connect failure
            throw error
        }
        connected = true
        startReceiveLoop()
    }

    /// The handshake proper — factored out so `connect` can guarantee the
    /// opened socket is closed on ANY failure path (review10 finding 6).
    private func performHandshake(password: String?) async throws {
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
    ///
    /// Review11 finding 1 tightens the enqueued-but-late window: a request
    /// that resolves (timeout/cancel/disconnect) while its send is still
    /// QUEUED — not yet inside `socket.send` — cancels that send, so the
    /// frame is confirmed never sent. Only a send already in the socket
    /// remains "possibly issued", and the outbound chain guarantees no later
    /// frame (e.g. a cleanup StopStream) is transmitted before it.
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
            // The send runs in a TRACKED child task (review11 finding 1),
            // chained behind the previous send so outbound order matches
            // issue order, and cancellable by every resolution path.
            let previous = sendChainTail
            let send = Task { [weak self] in
                await previous?.value          // FIFO: never overtake an earlier send
                await self?.performSend(id: id, frame: frame)
            }
            sendTasks[id] = send
            sendChainTail = send
        }
    }

    /// Body of a tracked send. Runs under actor isolation, so the
    /// cancellation check is strictly ordered against `failPending`/
    /// `failAll`: a request resolved before this segment runs observes
    /// `Task.isCancelled` here and the frame is CONFIRMED never sent. Past
    /// this check the frame is in the socket and can no longer be retracted
    /// — the caller-visible "possibly issued" window.
    private func performSend(id: String, frame: String) async {
        defer { sendTasks[id] = nil }
        guard !Task.isCancelled else { return }
        do {
            try await socket.send(frame)
        } catch {
            failPending(id: id, error: OBSError.notConnected)
        }
    }

    // MARK: - Disconnect

    /// Close the socket, cancel the receive loop, fail all pending requests
    /// (cancelling their tracked sends — review11 finding 1), and finish the
    /// events stream.
    public func disconnect() {
        receiveLoop?.cancel()
        receiveLoop = nil
        failAll(error: OBSError.notConnected)   // also sets connected = false
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
    /// Review11 finding 1: resolving a request CANCELS its tracked send —
    /// if the frame has not reached `socket.send` yet, it never will.
    private func failPending(id: String, error: Error) {
        if let send = sendTasks.removeValue(forKey: id) { send.cancel() }
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
    }

    /// Fail every pending request and cancel every tracked send (used when
    /// the socket dies and by disconnect teardown — review11 finding 1).
    private func failAll(error: Error) {
        connected = false
        for (_, send) in sendTasks { send.cancel() }
        sendTasks.removeAll()
        let inflight = pending
        pending.removeAll()
        for (_, continuation) in inflight {
            continuation.resume(throwing: error)
        }
    }
}
