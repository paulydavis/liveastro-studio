import Foundation
import Observation
import LiveAstroCore

struct OBSConnectionSnapshot: Equatable {
    let endpoint: String
    let streaming: Bool
    let recording: Bool
    let checkedAt: Date
}

@MainActor @Observable
final class OBSConnectionCheck {
    enum State: Equatable {
        case idle, checking, cancelled
        case checked(OBSConnectionSnapshot)
        case failed(String)
    }
    var host = "127.0.0.1" { didSet { if host != oldValue { invalidate() } } }
    var port = "4455" { didSet { if port != oldValue { invalidate() } } }
    // Deliberately memory-only. Never discover OBS settings, persist credentials,
    // or adopt the inspected stream into BroadcastController's lifecycle.
    var password = "" { didSet { if password != oldValue { invalidate() } } }
    private(set) var state: State = .idle
    var isChecking: Bool { state == .checking }
    @ObservationIgnored private let makeSocket: () -> any OBSSocket
    @ObservationIgnored private let timeout: TimeInterval
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var socket: OBSStatusOnlySocket?
    @ObservationIgnored private var generation = UUID()

    init(makeSocket: @escaping () -> any OBSSocket = { URLSessionOBSSocket() }, timeout: TimeInterval = 8) {
        self.makeSocket = makeSocket
        self.timeout = timeout
    }

    func start() {
        guard !isChecking else { return }
        guard let url = endpointURL else {
            state = .failed("Enter a hostname or IP address (without ws:// or a path), and a port from 1 to 65535.")
            return
        }
        let endpoint = "\(host.trimmingCharacters(in: .whitespacesAndNewlines)):\(url.port!)"
        let password = self.password
        let generation = UUID()
        self.generation = generation
        let socket = OBSStatusOnlySocket(inner: makeSocket())
        self.socket = socket
        let client = OBSClient(socket: socket, requestTimeout: timeout)
        state = .checking
        task = Task { @MainActor [weak self] in
            let outcome: State
            do {
                try Task.checkCancellation()
                try await client.connect(url: url, password: password.isEmpty ? nil : password)
                let version = try await client.request("GetVersion", data: nil)
                guard let value = version["obsVersion"] as? String, !value.isEmpty else {
                    throw CheckError.malformedStatus
                }
                let stream = try await client.request("GetStreamStatus", data: nil)
                let record = try await client.request("GetRecordStatus", data: nil)
                guard let streaming = Self.boolean(stream["outputActive"]),
                      let recording = Self.boolean(record["outputActive"]) else {
                    throw CheckError.malformedStatus
                }
                outcome = .checked(OBSConnectionSnapshot(endpoint: endpoint, streaming: streaming,
                    recording: recording, checkedAt: Date()))
            } catch {
                outcome = .failed(Self.explanation(for: error))
            }
            await client.disconnect()
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            self.socket = nil
            self.task = nil
            self.state = outcome
        }
    }

    func cancel() {
        guard isChecking else { return }
        retire()
        state = .cancelled
    }

    private func invalidate() {
        retire()
        state = .idle
    }

    private func retire() {
        generation = UUID()
        task?.cancel()
        task = nil
        socket?.close()
        socket = nil
    }

    deinit {
        task?.cancel()
        socket?.close()
    }

    var endpointURL: URL? {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]")
        guard !host.isEmpty, host.unicodeScalars.allSatisfy(allowed.contains),
              !port.isEmpty, port.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(port), (1...65535).contains(number) else { return nil }
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = number
        return components.url
    }

    private enum CheckError: Error { case malformedStatus }

    private static func boolean(_ value: Any?) -> Bool? {
        // NSNumber bridges 0/1 to Bool too; missing/numeric statuses are not
        // evidence that an OBS output is inactive (or active).
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func explanation(for error: Error) -> String {
        if let error = error as? OBSClient.OBSError {
            switch error {
            case .authFailed: return "OBS authentication failed. Paste the password from OBS → Tools → WebSocket Server Settings."
            case .timeout: return "OBS did not respond in time. Check that OBS and its WebSocket server are running, then retry."
            case .requestFailed: return "OBS refused a status request. No output status was confirmed."
            case .notConnected: break
            }
        }
        if error is CheckError { return "OBS returned an incomplete or invalid status. No output status was confirmed." }
        // Do not surface server comments or arbitrary transport error text; they
        // can contain credentials. Connection failure says nothing about output.
        return "Could not check OBS. Open OBS, enable its WebSocket server, and verify host, port and password."
    }
}

/// A wire-level restriction as well as a restricted UI. This short-lived client
/// cannot send commands that start/stop outputs, configure capture or change scenes.
final class OBSStatusOnlySocket: OBSSocket {
    private let inner: any OBSSocket
    private let lock = NSLock()
    private var closed = false
    private static let requests: Set<String> = ["GetVersion", "GetStreamStatus", "GetRecordStatus"]
    private enum Refused: Error { case packet }
    init(inner: any OBSSocket) { self.inner = inner }
    func connect(url: URL) async throws {
        try ensureOpen()
        try await inner.connect(url: url)
        do { try ensureOpen() }
        catch { inner.close(); throw error }
    }
    func receive() async throws -> String {
        try ensureOpen()
        return try await inner.receive()
    }
    func send(_ text: String) async throws {
        try ensureOpen()
        guard let packet = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let op = packet["op"] as? Int, var data = packet["d"] as? [String: Any] else {
            throw Refused.packet
        }
        if op == 1 {
            data["eventSubscriptions"] = 0
            let bytes = try JSONSerialization.data(withJSONObject: ["op": 1, "d": data])
            try await inner.send(String(decoding: bytes, as: UTF8.self))
        } else {
            guard op == 6, let request = data["requestType"] as? String,
                  Self.requests.contains(request) else { throw Refused.packet }
            try await inner.send(text)
        }
    }
    private func ensureOpen() throws {
        try Task.checkCancellation()
        if lock.withLock({ closed }) { throw CancellationError() }
    }
    func close() {
        lock.withLock { closed = true }
        inner.close()
    }
}
