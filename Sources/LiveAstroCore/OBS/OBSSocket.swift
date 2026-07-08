import Foundation

// MARK: - Protocol

/// Transport seam for the OBS WebSocket connection.
///
/// Callers connect once, then alternate send/receive calls for the
/// obs-websocket 5.x handshake and request/response loop.
/// Conforming types must be reference types (class or actor) so
/// they can hold mutable networking state.
public protocol OBSSocket: AnyObject {

    /// Open a WebSocket connection to `url`.
    /// Throws on network failure or protocol error.
    func connect(url: URL) async throws

    /// Send a UTF-8 text frame.
    /// Throws if the connection is not open or the write fails.
    func send(_ text: String) async throws

    /// Receive the next UTF-8 text frame from the server.
    /// Throws if the connection closes unexpectedly or a binary frame is received.
    func receive() async throws -> String

    /// Close the connection gracefully. Non-throwing; best-effort.
    func close()
}

// MARK: - URLSession implementation

/// Production `OBSSocket` backed by `URLSessionWebSocketTask`.
///
/// Usage:
/// ```swift
/// let socket = URLSessionOBSSocket()
/// try await socket.connect(url: URL(string: "ws://localhost:4455")!)
/// try await socket.send(OBSMessage.identify(...))
/// let frame = try await socket.receive()
/// socket.close()
/// ```
///
/// Unit tests do NOT exercise this class — the real-OBS smoke test (Task 8)
/// validates it. Use `MockOBSSocket` (in the test target) for unit testing.
public final class URLSessionOBSSocket: OBSSocket {

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private let openDelegate = OpenDelegate()

    public init() {}

    public func connect(url: URL) async throws {
        // URLSessionWebSocketTask.resume() returns immediately without waiting for
        // the WebSocket upgrade to complete. Sending/receiving before the socket is
        // actually open races the handshake and fails with ENOTCONN (POSIX 57).
        // Await the delegate's didOpenWithProtocol (success) / didCompleteWithError
        // (failure) so connect() only returns once the connection is truly live.
        let session = URLSession(configuration: .default, delegate: openDelegate, delegateQueue: nil)
        self.session = session
        let t = session.webSocketTask(with: url)
        task = t
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            openDelegate.awaitOpen(cont)
            t.resume()
        }
    }

    public func send(_ text: String) async throws {
        guard let task else {
            throw OBSSocketError.notConnected
        }
        try await task.send(.string(text))
    }

    public func receive() async throws -> String {
        guard let task else {
            throw OBSSocketError.notConnected
        }
        let message = try await task.receive()
        switch message {
        case .string(let text):
            return text
        case .data:
            throw OBSSocketError.unexpectedBinaryFrame
        @unknown default:
            throw OBSSocketError.unexpectedBinaryFrame
        }
    }

    public func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()   // release the delegate-retaining session
        session = nil
    }
}

// MARK: - Open delegate

/// Bridges URLSessionWebSocketTask's open/failure callbacks to the async
/// `connect()`. Resumes the pending continuation exactly once: on
/// didOpenWithProtocol (success) or didCompleteWithError (failure).
private final class OpenDelegate: NSObject, URLSessionWebSocketDelegate {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var settled = false

    func awaitOpen(_ cont: CheckedContinuation<Void, Error>) {
        lock.lock(); defer { lock.unlock() }
        continuation = cont
    }

    private func resume(_ result: Result<Void, Error>) {
        lock.lock()
        guard !settled, let cont = continuation else { lock.unlock(); return }
        settled = true
        continuation = nil
        lock.unlock()
        cont.resume(with: result)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol proto: String?) {
        resume(.success(()))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // Fires for connection failures (refused/unreachable) before an open,
        // and for normal closes after. Only the pre-open case still has a
        // pending continuation; post-open completions are a no-op here.
        resume(.failure(error ?? OBSSocketError.notConnected))
    }
}

// MARK: - Errors

public enum OBSSocketError: Error {
    case notConnected
    case unexpectedBinaryFrame
}
