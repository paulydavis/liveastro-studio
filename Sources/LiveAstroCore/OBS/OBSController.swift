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

    /// Fired on the main actor for every output-affecting OBS event
    /// (StreamStateChanged / RecordStateChanged), AFTER the published state was
    /// updated — the broadcast orchestrator's reconciliation trigger (review8
    /// item 3).
    public var onOutputEvent: (() -> Void)?

    /// Fired on the main actor when the connection is lost UNEXPECTEDLY —
    /// receive-loop death (surfaced by the client finishing its events stream)
    /// or a request-error convergence — after this controller has already
    /// converged to `.disconnected`. NEVER fired for a deliberate
    /// `disconnect()` (review8 item 3).
    public var onConnectionLost: (() -> Void)?

    // MARK: - Dependencies

    private let makeClient: (OBSSocket) -> OBSClient
    private let makeSocket: () -> OBSSocket

    private var client: OBSClient?
    /// Task consuming `client.events`. Cancelled on disconnect / before a new connect.
    private var eventsTask: Task<Void, Never>?

    /// Monotonic connection identity (review8 item 2): bumped at every connect
    /// start and every disconnect/teardown. Every async consumer of a client —
    /// the connect completion AND failure paths, `seedState`, request-error
    /// convergence, and the event consumer — captures the epoch of the client
    /// it talks to and, after every await, touches NOTHING when the epoch has
    /// moved on: only the client whose epoch generated a signal may mutate
    /// published state or tear the session down.
    private(set) var connectionEpoch = 0
    /// The one in-flight connect attempt (review8 item 2): a second caller
    /// awaits this task's result instead of starting a competing handshake.
    private var connectTask: Task<Bool, Never>?

    /// Per-field event-order stamps (review11 finding 3): bumped by every
    /// EVENT apply that touches the field. `seedState`/`refreshScenes`
    /// capture the stamp BEFORE issuing the corresponding status request
    /// and apply the answer ONLY if no event touched that field since —
    /// otherwise the (newer) event wins and the stale snapshot is skipped.
    /// The connection epoch alone could not order a seed answer against an
    /// event of the SAME epoch: events flow from the moment the handshake
    /// completes, so an event could apply first and the older seed answer
    /// then overwrote it, with nothing left to repair the published state.
    /// Per-FIELD rather than one global version so an unrelated event (a
    /// scene change landing during the stream read) cannot void a
    /// still-valid seed field — a skipped-but-untouched field would stay
    /// unseeded with nothing to repair it either.
    private var streamStateVersion = 0
    private var recordStateVersion = 0
    private var sceneStateVersion = 0

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
    ///
    /// Coalescing (review8 item 2): concurrent connect attempts share ONE
    /// in-flight task — a second caller awaits the first attempt's result
    /// instead of tearing it down mid-handshake and starting a competitor.
    @discardableResult
    public func connect(host: String, port: Int, password: String?) async -> Bool {
        if let task = connectTask { return await task.value }

        // Tear down any prior session first (idempotent reconnect). This bumps
        // the epoch, so every consumer of the old client goes stale.
        teardown()

        guard let url = URL(string: "ws://\(host):\(port)") else {
            log("connect: invalid host/port \(host):\(port)")
            state = .disconnected
            return false
        }

        connectionEpoch += 1                 // connect start
        let epoch = connectionEpoch
        state = .connecting
        let socket = makeSocket()
        let client = makeClient(socket)
        self.client = client

        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            return await self.performConnect(client: client, url: url,
                                             password: password, epoch: epoch)
        }
        connectTask = task
        let ok = await task.value
        // Epoch-guarded clear: never nil out a NEWER attempt's slot from a
        // superseded completion.
        if epoch == connectionEpoch { connectTask = nil }
        return ok
    }

    /// The awaited half of `connect` — handshake, event subscription, seeding.
    /// Every landing past an await is epoch-guarded: a teardown/reconnect that
    /// happened mid-handshake owns the published state, and this (now stale)
    /// attempt touches nothing beyond closing its own orphaned client.
    private func performConnect(client: OBSClient, url: URL,
                                password: String?, epoch: Int) async -> Bool {
        do {
            try await client.connect(url: url, password: password)
        } catch {
            log("connect failed: \(error)")
            guard epoch == connectionEpoch else { return false }   // superseded: touch nothing
            self.client = nil
            state = .disconnected
            return false
        }
        guard epoch == connectionEpoch else {
            // Superseded mid-handshake: close the orphaned client quietly.
            Task { await client.disconnect() }
            return false
        }
        // Handshake succeeded. Start listening for events, then seed state.
        state = .connected
        subscribeToEvents(of: client, epoch: epoch)
        await seedState(epoch: epoch)
        // Review10 finding 5 (SPLIT-SNAPSHOT/OWNERSHIP RACES): the connection
        // may have DIED during the seed (a socket failure converges to
        // .disconnected and bumps the epoch) — returning true unconditionally
        // here reported success from a stale task over a dead session.
        // Revalidate identity and liveness before claiming success.
        guard epoch == connectionEpoch, self.client === client,
              state == .connected || state == .streaming else {
            return false
        }
        return true
    }

    /// Close the connection. NEVER sends StopStream — a running broadcast must
    /// survive the app quitting or the operator disconnecting the control link.
    public func disconnect() {
        teardown()
        state = .disconnected
    }

    /// Cancel the events task and disconnect the client without touching `state`.
    /// Bumps the epoch (review8 item 2): every in-flight consumer of the old
    /// client — including a mid-handshake connect — is stale from this instant.
    private func teardown() {
        connectionEpoch += 1
        connectTask?.cancel()
        connectTask = nil
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
    /// probably dropped) via `handle(error:epoch:)`. Every mutation is
    /// epoch-guarded: a reconnect mid-seed means these answers describe a dead
    /// session, so they must not overwrite the new one's state.
    private func seedState(epoch: Int) async {
        await refreshScenes()
        guard epoch == connectionEpoch else { return }

        // Review11 finding 3: stamp captured BEFORE the request goes out;
        // the answer applies only if no stream event landed in between.
        let streamStamp = streamStateVersion
        if let stream = await requestData("GetStreamStatus", nil) {
            guard epoch == connectionEpoch else { return }
            if let active = stream["outputActive"] as? Bool, state != .disconnected {
                if streamStamp == streamStateVersion {
                    state = active ? .streaming : .connected
                } else {
                    log("seed: a newer stream event superseded the GetStreamStatus answer — keeping the event's state")
                }
            }
        }
        guard epoch == connectionEpoch else { return }
        let recordStamp = recordStateVersion
        if let record = await requestData("GetRecordStatus", nil) {
            guard epoch == connectionEpoch else { return }
            if let active = record["outputActive"] as? Bool {
                if recordStamp == recordStateVersion {
                    isRecording = active
                } else {
                    log("seed: a newer record event superseded the GetRecordStatus answer — keeping the event's state")
                }
            }
        }
    }

    // MARK: - Operations (all swallow errors into onLog)

    /// Fetch the scene list and current program scene.
    public func refreshScenes() async {
        let epoch = connectionEpoch
        let sceneStamp = sceneStateVersion   // review11 finding 3
        guard let data = await requestData("GetSceneList", nil) else { return }
        guard epoch == connectionEpoch else { return }   // answered by a dead session

        if let scenes = data["scenes"] as? [[String: Any]] {
            // OBS returns scenes top-of-list first; UI convention lists them in
            // the natural order OBS presents, reversed to bottom→top display.
            // No event carries scene NAMES (SceneListChanged only triggers a
            // re-fetch), so the list itself has no event to lose against.
            let names = scenes.compactMap { $0["sceneName"] as? String }
            sceneNames = names.reversed()
        }
        if let current = data["currentProgramSceneName"] as? String {
            if sceneStamp == sceneStateVersion {
                currentScene = current
            } else {
                log("scene refresh: a newer scene-change event superseded the answer — keeping the event's scene")
            }
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
    ///
    /// Review10 finding 1 (SPLIT-SNAPSHOT/OWNERSHIP RACES): the confirmation
    /// here is assembled from TWO sequential status reads — a stream RESTART
    /// landing between them would be invisible to the second read and the
    /// stale pair would confirm a stop over a live stream. When the caller
    /// supplies `outputEventGeneration` (BroadcastController's output-event
    /// counter), each poll captures it BEFORE its first read and revalidates
    /// AFTER its last: a torn snapshot discards the conclusion and re-reads
    /// (bounded by `maxConfirmPolls`); exhaustion returns `false` — the caller
    /// settles `.stopUnconfirmed`, never `.idle`, from a torn confirmation.
    @discardableResult
    public func stopBroadcast(confirmPollSeconds: Double = 1.0,
                              maxConfirmPolls: Int = 5,
                              outputEventGeneration: (() -> Int)? = nil) async -> Bool {
        await stopStream()
        await setRecording(false)
        for i in 0..<max(1, maxConfirmPolls) {
            let snapshot = outputEventGeneration?()   // capture before the first read
            if let stream = await streamStatus(), !stream.active,
               let recording = await recordStatus(), !recording {
                if snapshot == outputEventGeneration?() {   // revalidate after the last
                    log("broadcast confirmed stopped")
                    return true
                }
                log("output event landed mid-confirmation — snapshot torn, re-reading")
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
    /// return nil. `.notConnected` failures converge state to `.disconnected`,
    /// but ONLY when the failing client is still the current one (review8 item
    /// 2): the epoch captured alongside the client identifies which session
    /// generated the error, so a stale client's death can never tear down a
    /// newer connection.
    ///
    /// Cold-review1 finding 3: whether the handshake was COMPLETE when the
    /// request was issued is captured alongside the epoch. A request issued
    /// mid-handshake (state `.connecting` — a scene-automation tick or a
    /// stop racing a Go Live's connect) throws `.notConnected` from the
    /// not-yet-identified client; that is NOT a liveness signal about an
    /// established session, and pre-fix it converged anyway — teardown()
    /// cancelled the in-flight connect. Such a request now fails alone.
    @discardableResult
    private func requestData(_ type: String, _ data: [String: Any]?) async -> [String: Any]? {
        guard let client else {
            log("\(type): not connected")
            return nil
        }
        let epoch = connectionEpoch
        let issuedAgainstCompletedHandshake = state == .connected || state == .streaming
        do {
            return try await client.request(type, data: data)
        } catch {
            log("\(type) failed: \(error)")
            handle(error: error, epoch: epoch,
                   issuedAgainstCompletedHandshake: issuedAgainstCompletedHandshake)
            return nil
        }
    }

    /// Converge state on a dropped connection — the failed request is a
    /// liveness signal. Epoch-guarded (review8 item 2): only the client whose
    /// epoch generated the error may tear the session down; errors surfacing
    /// from an already-superseded client touch nothing. Handshake-guarded
    /// (cold-review1 finding 3): only a request issued against a COMPLETED
    /// handshake carries liveness information — a mid-handshake
    /// `.notConnected` says "not connected YET", and converging on it killed
    /// the very connect it raced.
    private func handle(error: Error, epoch: Int,
                        issuedAgainstCompletedHandshake: Bool) {
        if case OBSClient.OBSError.notConnected = error {
            guard epoch == connectionEpoch else { return }
            guard issuedAgainstCompletedHandshake else {
                log("request issued mid-handshake failed — connect attempt unaffected")
                return
            }
            if state != .disconnected {
                log("connection lost — converging to .disconnected")
                teardown()
                state = .disconnected
                onConnectionLost?()
            }
        }
    }

    // MARK: - Events

    /// Consume the client's event stream and keep published state live.
    /// Epoch-guarded (review8 item 2): once the session is superseded, this
    /// consumer stops applying the dead client's events entirely.
    ///
    /// The stream FINISHING is a signal (review8 item 3): the client finishes
    /// it when its receive loop dies unexpectedly, so falling out of the loop
    /// at the CURRENT epoch (not cancelled, not superseded) means the socket
    /// is gone — converge to `.disconnected` and surface `onConnectionLost`.
    /// Deliberate disconnects cancel this task and bump the epoch first, so
    /// they can never reach the convergence.
    private func subscribeToEvents(of client: OBSClient, epoch: Int) {
        let events = client.events
        eventsTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                guard self.connectionEpoch == epoch else { return }
                // Task {} inherits this controller's main-actor isolation, so
                // apply(event:data:) is a same-actor synchronous call.
                self.apply(event: event.type, data: event.data)
            }
            guard let self, !Task.isCancelled else { return }
            guard self.connectionEpoch == epoch else { return }
            self.log("connection lost — converging to .disconnected")
            self.teardown()
            self.state = .disconnected
            self.onConnectionLost?()
        }
    }

    /// Apply a single OBS event to published state. Runs on the main actor.
    private func apply(event type: String, data: [String: Any]) {
        switch type {
        case "CurrentProgramSceneChanged":
            if let name = data["sceneName"] as? String {
                sceneStateVersion += 1   // review11 finding 3: the event outranks in-flight answers
                currentScene = name
            }

        case "StreamStateChanged":
            if let active = data["outputActive"] as? Bool {
                streamStateVersion += 1   // review11 finding 3
                state = active ? .streaming : .connected
            }
            onOutputEvent?()   // review8 item 3: reconcile broadcast state

        case "RecordStateChanged":
            if let active = data["outputActive"] as? Bool {
                recordStateVersion += 1   // review11 finding 3
                isRecording = active
            }
            onOutputEvent?()   // review8 item 3: reconcile broadcast state

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