import Foundation
import Observation
import LiveAstroCore

@MainActor @Observable
final class OBSLocalRecording {
    enum State: Equatable {
        case idle, starting, recording, stopping, checking
        case finished(String), refused(String), failed(String), uncertain(String)
    }
    private(set) var state: State = .idle
    var requiresAttention: Bool {
        switch state {
        case .starting, .recording, .stopping, .checking, .uncertain: return true
        default: return false
        }
    }
    var isBusy: Bool { state == .starting || state == .stopping || state == .checking }
    @ObservationIgnored private let makeSocket: () -> any OBSSocket
    @ObservationIgnored private let timeout: TimeInterval
    @ObservationIgnored private let transitionTimeout: TimeInterval
    @ObservationIgnored private let pollInterval: TimeInterval
    @ObservationIgnored private var socket: OBSRecordingSocket?
    @ObservationIgnored private var client: OBSClient?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var events: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var startIssued = false
    @ObservationIgnored private var stopIssued = false
    private(set) var recordingEndpoint: URL?
    private enum Failure: Error { case active, invalidResponse, transitionTimeout }

    init(makeSocket: @escaping () -> any OBSSocket = { URLSessionOBSSocket() },
         timeout: TimeInterval = 8, transitionTimeout: TimeInterval = 10,
         pollInterval: TimeInterval = 0.2) {
        self.makeSocket = makeSocket
        self.timeout = timeout
        self.transitionTimeout = transitionTimeout
        self.pollInterval = pollInterval
    }

    /// Explicit operator action only. Never called by session start or auto-start.
    func start(endpoint: URL?, password: String) {
        guard !requiresAttention else { return }
        guard let endpoint else { state = .failed("Enter a valid OBS host and port first."); return }
        let (client, socket, token) = prepare()
        recordingEndpoint = endpoint
        state = .starting // reserve before the first await / second click
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await client.connect(url: endpoint, password: password.isEmpty ? nil : password)
                try self.requireCurrent(token)
                self.observe(client, token: token)
                let version = try await client.request("GetVersion", data: nil)
                guard let names = version["availableRequests"] as? [String],
                      Set(["GetStreamStatus", "GetRecordStatus", "StartRecord", "StopRecord"]).isSubset(of: Set(names)) else { throw Failure.invalidResponse }
                let streaming = try Self.active(await client.request("GetStreamStatus", data: nil))
                let recording = try Self.active(await client.request("GetRecordStatus", data: nil))
                try self.requireCurrent(token)
                guard !streaming, !recording else { throw Failure.active }
                // The reads are not an atomic reservation. OBS has no recording
                // ownership token; another controller must not operate it concurrently.
                socket.allowStart()
                self.startIssued = true
                _ = try await client.request("StartRecord", data: nil)
                try await self.confirm(true, client: client, token: token)
                try self.requireCurrent(token)
                self.state = .recording
                self.operation = nil
            } catch {
                self.fail(error, token: token)
            }
        }
    }

    func stop() {
        guard state == .recording, let client, let socket else { return }
        let token = generation
        state = .stopping
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                // A fresh read and event monitoring narrow, but cannot eliminate,
                // OBS's lack of a compare-and-stop / per-recording identity API.
                guard try Self.active(await client.request("GetRecordStatus", data: nil)) else { throw Failure.invalidResponse }
                try self.requireCurrent(token)
                socket.allowStop()
                self.stopIssued = true
                let result = try await client.request("StopRecord", data: nil)
                try await self.confirm(false, client: client, token: token)
                try self.requireCurrent(token)
                guard let path = result["outputPath"] as? String, !path.isEmpty else { throw Failure.invalidResponse }
                self.retire()
                self.state = .finished(path)
            } catch {
                self.fail(error, token: token)
            }
        }
    }

    /// Recovery is deliberately read-only: never adopts an active recording and
    /// never reconnects in order to issue a stop after an ambiguous result.
    func checkStopped(endpoint: URL?, password: String) {
        guard !isBusy, state != .recording else { return }
        guard let endpoint else { return }
        guard recordingEndpoint == nil || recordingEndpoint == endpoint else { return }
        let (client, _, token) = prepare()
        state = .checking
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await client.connect(url: endpoint, password: password.isEmpty ? nil : password)
                let active = try Self.active(await client.request("GetRecordStatus", data: nil))
                try self.requireCurrent(token)
                self.retire()
                self.state = active ? .uncertain("OBS is recording. Manage it in OBS; LiveAstro will not take it over.") : .idle
            } catch {
                guard self.generation == token else { return }
                self.retire()
                self.state = .uncertain("Could not confirm that recording stopped. Check OBS directly.")
            }
        }
    }

    /// Disconnect/quit never means stop. End Session does not call this either.
    func disconnect() {
        let warn = requiresAttention
        retire()
        if warn { state = .uncertain("OBS may still be recording. Check OBS directly; disconnecting does not stop recording.") }
    }

    private func prepare() -> (OBSClient, OBSRecordingSocket, UUID) {
        retire()
        startIssued = false
        stopIssued = false
        let socket = OBSRecordingSocket(inner: makeSocket())
        let client = OBSClient(socket: socket, requestTimeout: timeout)
        self.socket = socket; self.client = client
        return (client, socket, generation)
    }

    private func requireCurrent(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }

    private func confirm(_ expected: Bool, client: OBSClient, token: UUID) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(transitionTimeout)
        while clock.now < deadline {
            try requireCurrent(token)
            let observed = try Self.active(await client.request("GetRecordStatus", data: nil))
            try requireCurrent(token)
            guard clock.now < deadline else { throw Failure.transitionTimeout }
            if observed == expected { return }
            try await Task.sleep(for: .seconds(pollInterval))
        }
        // Each in-flight request is separately bounded by OBSClient's timeout.
        throw Failure.transitionTimeout
    }

    private static func active(_ data: [String: Any]) throws -> Bool {
        guard let value = data["outputActive"] as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { throw Failure.invalidResponse }
        return value.boolValue
    }

    private func observe(_ client: OBSClient, token: UUID) {
        events = Task { [weak self] in
            for await event in client.events {
                guard !Task.isCancelled else { return }
                self?.received(event.type, data: event.data, token: token)
            }
        }
    }

    private func received(_ type: String, data: [String: Any], token: UUID) {
        guard token == generation else { return }
        if type == OBSClient.connectionLostEventType {
            fail(OBSClient.OBSError.notConnected, token: token)
            return
        }
        guard startIssued, type == "RecordStateChanged" else { return }
        guard let output = data["outputState"] as? String else {
            fail(Failure.invalidResponse, token: token); return
        }
        let ended = output == "OBS_WEBSOCKET_OUTPUT_STOPPED" || output == "OBS_WEBSOCKET_OUTPUT_STOPPING"
        let began = output == "OBS_WEBSOCKET_OUTPUT_STARTING" || output == "OBS_WEBSOCKET_OUTPUT_STARTED"
        if (ended && !stopIssued) || (began && state == .stopping)
            || (output == "OBS_WEBSOCKET_OUTPUT_STARTING" && state == .recording) {
            fail(Failure.invalidResponse, token: token)
        }
    }

    private func fail(_ error: Error, token: UUID) {
        guard token == generation else { return }
        let possiblyRecording = startIssued
        retire()
        if possiblyRecording {
            state = .uncertain("Recording could not be confirmed, or changed outside LiveAstro. OBS may still be recording. Check OBS; no reconnect or automatic stop was attempted.")
        } else if let failure = error as? Failure, failure == .active {
            state = .refused("OBS is already streaming or recording. No recording commands were sent; manage the existing output in OBS.")
        } else {
            state = .failed("Could not start recording. Check OBS's server, password and connection. No recording command was sent.")
        }
    }

    private func retire() {
        generation = UUID()
        operation?.cancel(); operation = nil
        events?.cancel(); events = nil
        socket?.close(); socket = nil
        if let client { Task { await client.disconnect() } }
        client = nil
    }

    deinit {
        operation?.cancel(); events?.cancel(); socket?.close()
        if let client { Task { await client.disconnect() } }
    }
}

/// Separate from the read-only check and the direct edition's controller.
/// Only local recording commands are possible, each armed once by the owner.
final class OBSRecordingSocket: OBSSocket {
    private let inner: any OBSSocket
    private let lock = NSLock()
    private var closed = false
    private var startAllowed = false
    private var stopAllowed = false
    private enum Refused: Error { case packet }
    init(inner: any OBSSocket) { self.inner = inner }
    func allowStart() { lock.withLock { startAllowed = true } }
    func allowStop() { lock.withLock { stopAllowed = true } }
    func connect(url: URL) async throws {
        try ensureOpen()
        try await inner.connect(url: url)
        do { try ensureOpen() } catch { inner.close(); throw error }
    }
    func receive() async throws -> String { try ensureOpen(); return try await inner.receive() }
    func send(_ text: String) async throws {
        try ensureOpen()
        guard let packet = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let op = packet["op"] as? Int, var d = packet["d"] as? [String: Any] else { throw Refused.packet }
        if op == 1 {
            d["eventSubscriptions"] = 64 // Output state events only; no high-volume subscriptions.
            let bytes = try JSONSerialization.data(withJSONObject: ["op": 1, "d": d])
            try await inner.send(String(decoding: bytes, as: UTF8.self))
            return
        }
        guard op == 6, let name = d["requestType"] as? String else { throw Refused.packet }
        let permitted = lock.withLock {
            guard !closed else { return false }
            switch name {
            case "GetVersion", "GetStreamStatus", "GetRecordStatus": return true
            case "StartRecord": defer { startAllowed = false }; return startAllowed
            case "StopRecord": defer { stopAllowed = false }; return stopAllowed
            default: return false
            }
        }
        guard permitted else { throw Refused.packet }
        try await inner.send(text)
    }
    private func ensureOpen() throws {
        try Task.checkCancellation()
        if lock.withLock({ closed }) { throw CancellationError() }
    }
    func close() {
        lock.withLock { closed = true; startAllowed = false; stopAllowed = false }
        inner.close()
    }
}
