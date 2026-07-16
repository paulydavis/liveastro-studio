import Foundation
import Combine

/// High-level, UI-facing controller over `OBSClient`.
///
/// Owns the connection lifecycle and a small observable state machine
/// (`disconnected → connecting → connected → streaming`) plus scene/recording
/// state. All operations except `connect` swallow errors into `onLog` so the
/// UI never has to `try`; `connect` returns `Bool` so a caller (AppModel, Task 7)
/// can drive reconnect/backoff.
///
/// `@MainActor`: every `@Published` mutation happens on the main actor, so
/// SwiftUI observers update safely. The underlying `OBSClient` is an actor;
/// we `await` into it. Combine/`ObservableObject` is Foundation-level and keeps
/// LiveAstroCore free of SwiftUI/AppKit.
@MainActor
public final class OBSController: ObservableObject {

    // MARK: - State

    public enum OBSState: Equatable {
        case disconnected
        case connecting
        case connected
        case streaming
    }

    @Published public private(set) var state: OBSState = .disconnected
    @Published public private(set) var isRecording = false
    @Published public private(set) var sceneNames: [String] = []
    @Published public private(set) var currentScene: String?

    /// Diagnostic log sink. Every swallowed error and lifecycle note is emitted here.
    public var onLog: ((String) -> Void)?

    // MARK: - Dependencies

    private let makeClient: (OBSSocket) -> OBSClient
    private let makeSocket: () -> OBSSocket

    private var client: OBSClient?
    /// Task consuming `client.events`. Cancelled on disconnect / before a new connect.
    private var eventsTask: Task<Void, Never>?

    // MARK: - Init

    public init(makeClient: @escaping (OBSSocket) -> OBSClient = { OBSClient(socket: $0) },
                makeSocket: @escaping () -> OBSSocket = { URLSessionOBSSocket() }) {
        self.makeClient = makeClient
        self.makeSocket = makeSocket
    }

    // MARK: - Connect / disconnect

    /// Open a connection to `ws://host:port`, perform the handshake, and seed
    /// scene/stream/record state. Returns `true` on success. On failure the
    /// controller returns to `.disconnected` and logs the reason.
    @discardableResult
    public func connect(host: String, port: Int, password: String?) async -> Bool {
        // Tear down any prior session first (idempotent reconnect).
        teardown()

        guard let url = URL(string: "ws://\(host):\(port)") else {
            log("connect: invalid host/port \(host):\(port)")
            state = .disconnected
            return false
        }

        state = .connecting
        let socket = makeSocket()
        let client = makeClient(socket)
        self.client = client

        do {
            try await client.connect(url: url, password: password)
        } catch {
            log("connect failed: \(error)")
            self.client = nil
            state = .disconnected
            return false
        }

        // Handshake succeeded. Start listening for events, then seed state.
        state = .connected
        subscribeToEvents(of: client)
        await seedState()
        return true
    }

    /// Close the connection. NEVER sends StopStream — a running broadcast must
    /// survive the app quitting or the operator disconnecting the control link.
    public func disconnect() {
        teardown()
        state = .disconnected
    }

    /// Cancel the events task and disconnect the client without touching `state`.
    private func teardown() {
        eventsTask?.cancel()
        eventsTask = nil
        if let client {
            Task { await client.disconnect() }
        }
        client = nil
    }

    // MARK: - State seeding

    /// Query GetSceneList / GetStreamStatus / GetRecordStatus and populate the
    /// published state. Any failure moves us to `.disconnected` (the connection
    /// probably dropped) via `handle(error:)`.
    private func seedState() async {
        await refreshScenes()

        if let stream = await requestData("GetStreamStatus", nil),
           let active = stream["outputActive"] as? Bool,
           state != .disconnected {
            state = active ? .streaming : .connected
        }
        if let record = await requestData("GetRecordStatus", nil),
           let active = record["outputActive"] as? Bool {
            isRecording = active
        }
    }

    // MARK: - Operations (all swallow errors into onLog)

    /// Fetch the scene list and current program scene.
    public func refreshScenes() async {
        guard let data = await requestData("GetSceneList", nil) else { return }

        if let scenes = data["scenes"] as? [[String: Any]] {
            // OBS returns scenes top-of-list first; UI convention lists them in
            // the natural order OBS presents, reversed to bottom→top display.
            let names = scenes.compactMap { $0["sceneName"] as? String }
            sceneNames = names.reversed()
        }
        if let current = data["currentProgramSceneName"] as? String {
            currentScene = current
        }
    }

    public func setScene(_ name: String) async {
        _ = await requestData("SetCurrentProgramScene", ["sceneName": name])
    }

    public func startStream() async {
        _ = await requestData("StartStream", nil)
    }

    /// Stop the stream. Returns whether the StopStream request round-tripped
    /// ok — this is REQUEST success, not yet confirmation the output went
    /// inactive (use `stopBroadcast`'s confirm loop or `streamStatus()` for
    /// that). Errors are still swallowed into `onLog` as before.
    @discardableResult
    public func stopStream() async -> Bool {
        await requestData("StopStream", nil) != nil
    }

    /// Start/stop recording. Returns whether the request round-tripped ok
    /// (request success, not output-state confirmation).
    @discardableResult
    public func setRecording(_ on: Bool) async -> Bool {
        await requestData(on ? "StartRecord" : "StopRecord", nil) != nil
    }

    // MARK: - Broadcast operations

    /// Fetch the current stream health, or nil if unavailable.
    public func streamStatus() async -> StreamHealth? {
        guard let data = await requestData("GetStreamStatus", nil) else { return nil }
        return StreamHealth.parse(data)
    }

    /// Fetch whether the record output is active; nil if unavailable.
    public func recordStatus() async -> Bool? {
        guard let data = await requestData("GetRecordStatus", nil) else { return nil }
        return data["outputActive"] as? Bool
    }

    /// Confirm the record OUTPUT actually became active after an accepted
    /// StartRecord (review7 P2: acceptance ≠ output-state confirmation — see
    /// `setRecording`'s doc). Polls GetRecordStatus, mirroring
    /// `startBroadcast`'s stream confirm loop. Returns true once outputActive
    /// is confirmed; false when the polls expire or status is unavailable —
    /// the CALLER decides policy (BroadcastController warns and streams on;
    /// recording never fails a broadcast).
    /// At least one confirmation poll is always performed.
    @discardableResult
    public func confirmRecordingActive(confirmPollSeconds: Double = 1.0,
                                       maxConfirmPolls: Int = 5) async -> Bool {
        for i in 0..<max(1, maxConfirmPolls) {
            if let active = await recordStatus(), active {
                log("recording confirmed active")
                return true
            }
            if i < maxConfirmPolls - 1, confirmPollSeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(confirmPollSeconds * 1_000_000_000))
            }
        }
        log("record output did not go active")
        return false
    }

    /// Outcome of `startBroadcast` (review8 item 1) — a Bool hid the issuance
    /// boundary, so a cancelled start whose StartStream WAS sent got no cleanup.
    public enum StartOutcome: Equatable {
        /// Cancellation was CONFIRMED to have occurred before the StartStream
        /// send was enqueued — nothing was issued, there is nothing to undo.
        case notIssued
        /// StartStream was (or may have been) issued but going live was never
        /// confirmed: cancelled mid-request, confirm polls expired, or status
        /// unavailable. OBS may be live — the caller owes a confirmed cleanup.
        case issuedUnconfirmed
        /// GetStreamStatus confirmed outputActive — the broadcast is up.
        case confirmedLive
    }

    /// Deliberate broadcast: switch to `scene` (if given), start the stream, and
    /// confirm it went live by polling GetStreamStatus. The issuance boundary is
    /// CONSERVATIVE (review8 item 1): `.notIssued` is returned ONLY when
    /// cancellation is confirmed before the StartStream send was enqueued
    /// (`Task.isCancelled` checked immediately before issuing it; the client's
    /// request is itself cancellation-aware and never enqueues a send for a
    /// task already cancelled). Once the send has begun — or its status is
    /// ambiguous — the result is `.issuedUnconfirmed`, and on that outcome this
    /// method sends NOTHING further: the CALLER owns cleanup policy (review7
    /// P1: an internal StopStream-on-expiry here fired BEFORE the caller's
    /// generation check could run, so a stale attempt's cleanup could kill a
    /// newer broadcast's stream).
    /// At least one confirmation poll is always performed (maxConfirmPolls is floored to 1).
    @discardableResult
    public func startBroadcast(scene: String?, confirmPollSeconds: Double = 1.0,
                               maxConfirmPolls: Int = 5) async -> StartOutcome {
        if let scene, !scene.isEmpty { await setScene(scene) }
        // The issuance boundary: a cancellation observed HERE is confirmed to
        // precede the StartStream send. (A cancel that lands after this check
        // races the send and must be treated as possibly-issued.)
        if Task.isCancelled {
            log("start cancelled before StartStream was issued")
            return .notIssued
        }
        await startStream()
        for i in 0..<max(1, maxConfirmPolls) {
            if let h = await streamStatus(), h.active {
                log("broadcast live")
                return .confirmedLive
            }
            if i < maxConfirmPolls - 1, confirmPollSeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(confirmPollSeconds * 1_000_000_000))
            }
        }
        log("stream did not go active — check OBS ▸ Settings ▸ Stream")
        return .issuedUnconfirmed
    }

    /// Stop a broadcast: stop the stream, turn recording off, and CONFIRM both
    /// outputs went inactive by polling GetStreamStatus/GetRecordStatus (the
    /// mirror of `startBroadcast`'s confirm loop). Returns `true` only once
    /// stream AND record are confirmed inactive; `false` on request failure,
    /// no client, or an unconfirmed stop — the caller must then treat OBS as
    /// possibly still live (review6 P1: no idle-despite-unknown-remote-state).
    /// At least one confirmation poll is always performed.
    @discardableResult
    public func stopBroadcast(confirmPollSeconds: Double = 1.0,
                              maxConfirmPolls: Int = 5) async -> Bool {
        await stopStream()
        await setRecording(false)
        for i in 0..<max(1, maxConfirmPolls) {
            if let stream = await streamStatus(), !stream.active,
               let recording = await recordStatus(), !recording {
                log("broadcast confirmed stopped")
                return true
            }
            if i < maxConfirmPolls - 1, confirmPollSeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(confirmPollSeconds * 1_000_000_000))
            }
        }
        log("could not confirm stream/record inactive — OBS may still be live")
        return false
    }

    // MARK: - Request plumbing

    /// Issue a request; on success return its responseData, on failure log and
    /// return nil. `.notConnected` failures converge state to `.disconnected`
    /// (the socket died and the client won't push a signal — see design note).
    @discardableResult
    private func requestData(_ type: String, _ data: [String: Any]?) async -> [String: Any]? {
        guard let client else {
            log("\(type): not connected")
            return nil
        }
        do {
            return try await client.request(type, data: data)
        } catch {
            log("\(type) failed: \(error)")
            handle(error: error)
            return nil
        }
    }

    /// Converge state on a dropped connection. The client's `events` stream is
    /// NOT finished when its receive loop dies (Task 5 forward-note), so we
    /// detect the drop here — the failed request is our liveness signal — and
    /// tear down so the UI doesn't hang in `.streaming`/`.connected`.
    private func handle(error: Error) {
        if case OBSClient.OBSError.notConnected = error {
            if state != .disconnected {
                log("connection lost — converging to .disconnected")
                teardown()
                state = .disconnected
            }
        }
    }

    // MARK: - Events

    /// Consume the client's event stream and keep published state live.
    private func subscribeToEvents(of client: OBSClient) {
        let events = client.events
        eventsTask = Task { [weak self] in
            for await event in events {
                if Task.isCancelled { return }
                // Task {} inherits this controller's main-actor isolation, so
                // apply(event:data:) is a same-actor synchronous call.
                self?.apply(event: event.type, data: event.data)
            }
        }
    }

    /// Apply a single OBS event to published state. Runs on the main actor.
    private func apply(event type: String, data: [String: Any]) {
        switch type {
        case "CurrentProgramSceneChanged":
            if let name = data["sceneName"] as? String {
                currentScene = name
            }

        case "StreamStateChanged":
            if let active = data["outputActive"] as? Bool {
                state = active ? .streaming : .connected
            }

        case "RecordStateChanged":
            if let active = data["outputActive"] as? Bool {
                isRecording = active
            }

        case "SceneListChanged":
            // Scene set changed under us — re-fetch names.
            Task { [weak self] in await self?.refreshScenes() }

        default:
            break
        }
    }

    // MARK: - Logging

    private func log(_ message: String) {
        onLog?(message)
    }
}