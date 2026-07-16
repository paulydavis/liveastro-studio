import Foundation
import Observation

/// The app/platform boundaries `BroadcastController` needs, as injected
/// closures (the core-side mirror of the app target's `AppSurface` idiom).
///
/// Core never touches NSWorkspace/AppKit: `launchOBS` is an opaque request —
/// the app adapter owns every platform detail (bundle-id resolution, the
/// `open -a` fallback, and launch logging). Defaults are no-ops so a test
/// harness only supplies the closures it exercises.
public struct BroadcastDeps {

    /// Appends a line to the session log (main-actor).
    public var log: (String) -> Void
    /// Presents a user-facing error (drives the app's error alert).
    public var presentError: (String) -> Void
    /// Reads whether an imaging session is currently running (gates scene
    /// automation ticks).
    public var isSessionRunning: () -> Bool
    /// Requests that the OBS application be launched. Core only asks; the app
    /// adapter owns bundle-id resolution, fallbacks, and launch logging.
    public var launchOBS: () -> Void

    public init(log: @escaping (String) -> Void = { _ in },
                presentError: @escaping (String) -> Void = { _ in },
                isSessionRunning: @escaping () -> Bool = { false },
                launchOBS: @escaping () -> Void = {}) {
        self.log = log
        self.presentError = presentError
        self.isSessionRunning = isSessionRunning
        self.launchOBS = launchOBS
    }
}

/// Owns OBS broadcast orchestration: the Go Live state machine, stream-health
/// polling, stall-driven scene automation, and the deferred end-of-session
/// stop. Extracted from the app target into core (review6) so the lifecycle
/// is pinned by unit tests driving the injected `OBSController` through a
/// mocked socket.
///
/// The `OBSController` is injected (never constructed here) and all app/
/// platform boundaries flow through `BroadcastDeps` — no back-references, no
/// AppKit. The app drives the session hooks (`sessionDidStart` /
/// `sessionDidEnd` / `frameAccepted`) at the exact points the logic used to
/// run inline, plus the deferred `stopBroadcastAfterSessionEnd()` once replay
/// generation has completed or failed (review4 P2 — replay first, then stop
/// the stream).
///
/// ## State invariant (review6 — honest states, no lying UI)
/// - `.idle` means OBS has confirmed stream and recording inactive.
/// - `.unknown` is the initial state (review7): nothing is claimed until a
///   connect RECONCILES with OBS's actual output state — an already-streaming
///   OBS is adopted as the live broadcast, never offered a second Go Live.
/// - `.stopUnconfirmed` means OBS may still be live; Go Live is blocked and
///   Retry is available.
/// - Every asynchronous completion must match the current generation before
///   changing state.
/// - Core requests launch; the app adapter owns every platform detail.
@MainActor
@Observable
public final class BroadcastController {

    private let deps: BroadcastDeps

    /// High-level OBS controller (Foundation/Combine, UI-free). Injected so
    /// tests drive the full lifecycle through a mocked socket.
    public let obs: OBSController

    // OBS connection config (bound to the settings form).
    public var obsHost = "localhost"
    public var obsPort = 4455
    public var obsPassword = ""
    /// Launch OBS (via the app adapter) if the first connect attempt fails.
    public var obsAutoLaunch = true
    /// Also start OBS recording when the stream comes up.
    public var obsRecord = false
    /// Master switch for stall-driven scene automation.
    public var sceneAutomationOn = false
    /// Scene shown while stacking makes progress (the "hero" view).
    public var stackSceneName = ""
    /// Scene shown when imaging stalls (e.g. a live scope/finder view).
    public var scopeSceneName = ""

    // MARK: Broadcast state

    /// - `endingSession` (review5 P2): End Session was clicked while live — the stream
    ///   DELIBERATELY stays up until replay generation finishes (review4 P2), so the UI
    ///   must not claim idle. Health polling keeps reporting truth in this state; the UI
    ///   offers **End Broadcast** as an operator override (stream down NOW while the
    ///   replay renders); otherwise `stopBroadcastAfterSessionEnd()` advances it to
    ///   `.stopping` → `.idle`.
    /// - `stopUnconfirmed` (review6 P1): a stop was requested but OBS never confirmed
    ///   stream+record inactive (request failed, no client, or status still active).
    ///   OBS may still be live: Go Live stays blocked and `retryStop()` re-attempts.
    /// - `unknown` (review7 P1): the INITIAL state — OBS's output state has never been
    ///   confirmed, so claiming `.idle` would violate the invariant. Go Live still works
    ///   one-click from here (it connects and RECONCILES with actual OBS state first);
    ///   manual Connect (`connectAndReconcile()`) reconciles too. Disconnecting from
    ///   `.unknown` stays `.unknown`.
    public enum BroadcastState: Equatable {
        case unknown, idle, connecting, live, endingSession, stopping, stopUnconfirmed
    }
    public private(set) var broadcastState: BroadcastState = .unknown
    public private(set) var streamHealth: StreamHealth?
    private var healthPollTask: Task<Void, Never>?
    private var goLiveTask: Task<Void, Never>?

    // MARK: Generations (review6 P1/P2 — stale async completions must not mutate state)

    /// Monotonic token for the broadcast lifecycle. Bumped by every Go Live,
    /// End Broadcast, Retry, and any path that invalidates an in-flight
    /// bring-up. EVERY async completion in the broadcast choreography captures
    /// the generation it belongs to and re-checks it after each await before
    /// touching state; stale completions return silently.
    private(set) var broadcastGeneration = 0
    /// The generation `sessionDidEnd()` intends the deferred stop to clean up
    /// (review6 P1). If a newer Go Live / End Broadcast bumped past it, the
    /// deferred stop no-ops instead of killing the newer broadcast.
    private var pendingSessionEndGeneration: Int?
    /// Monotonic token for scene automation (review6 P2): queued scene-change
    /// tasks re-check it before sending SetCurrentProgramScene, so a task that
    /// was already in flight when `stopSceneAutomation()` ran sends nothing.
    private(set) var automationGeneration = 0

    // MARK: Output-event generation (review10 — SPLIT-SNAPSHOT/OWNERSHIP RACES)

    /// The structural primitive against the SPLIT-SNAPSHOT/OWNERSHIP RACES
    /// defect class (review10): any conclusion assembled from MULTIPLE
    /// sequential status reads (stream, then recording) is stale the moment an
    /// output event lands between them; any cleanup that awaits without first
    /// reserving state lets a newer owner start and then kills it.
    ///
    /// This counter is bumped SYNCHRONOUSLY by every OBS output event arrival
    /// — the same hooks that mark the reconcile drain dirty (stream started/
    /// stopped, record started/stopped, connection loss). Every multi-read
    /// confirmation captures it BEFORE its first status read and revalidates
    /// AFTER its last: if it moved, the snapshot is torn — the conclusion is
    /// discarded and the confirmation re-runs (bounded retries; on exhaustion
    /// it settles `.stopUnconfirmed`, never `.idle`).
    private(set) var outputEventGeneration = 0

    /// True exactly while an app-issued StartStream (goLive's
    /// `obs.startBroadcast`) is in flight — set immediately before the call,
    /// cleared the instant its `StartOutcome` settles. Review10 finding 2:
    /// this is the OWNERSHIP-precise replacement for the drain's old blanket
    /// ".connecting ignores events" rule — only the app's OWN StartStream echo
    /// may be deferred to the in-flight goLive confirmation; during a manual
    /// connect/reconcile an external stream start must reconcile.
    private var appStartInFlight = false

    /// Set when the drain must defer to an owner in flight (an app-issued
    /// start, or the stop machinery during `.stopping` when a stream RESTART
    /// is observed — review10 finding 1: `.stopping` never blanket-discards
    /// output events any more). The owner's settlement re-runs the drain.
    private var reconcileWhenOwnerSettles = false

    /// The state the current `.connecting` attempt STARTED from (review10
    /// finding 4): cancellation/teardown of a connect returns to this origin —
    /// a connect begun at `.unknown` never confirmed anything, so it must not
    /// manufacture a confirmed `.idle` on the way out.
    private var connectingOrigin: BroadcastState = .unknown

    /// Bound on split-snapshot re-reads before giving up (torn snapshots keep
    /// discarding conclusions; exhaustion settles `.stopUnconfirmed`).
    var maxSnapshotRetries = 3

    // MARK: Timing knobs (injectable for tests — production uses the defaults)

    /// Delay between connect retries while waiting for a just-launched OBS.
    var launchRetryDelaySeconds: Double = 2
    /// Total budget for the post-launch connect retry loop.
    var launchRetryBudgetSeconds: Double = 20
    /// Confirm-poll pacing forwarded to `OBSController.start/stopBroadcast`.
    var confirmPollSeconds: Double = 1
    var maxConfirmPolls: Int = 5
    /// Stream-health poll period while live.
    var healthPollIntervalSeconds: Double = 2

    // Scene-automation runtime state (nil unless a session + automation is live).
    /// Internal for tests (cold-review1 minor 5): the deinit-invalidation pin
    /// needs to grab the timer before the controller is released.
    /// `@ObservationIgnored` keeps it a plain stored property (no UI observes
    /// it) so `nonisolated(unsafe)` genuinely applies; that in turn exists
    /// ONLY so deinit (nonisolated by language rule) can invalidate it —
    /// every live access is main-actor code in this class, and deinit has
    /// exclusive access to the dying instance.
    @ObservationIgnored nonisolated(unsafe) var sceneTimer: Timer?
    private var stall: StallDetector?
    /// True while we're showing `scopeSceneName` *because* of a detected stall,
    /// so the accepted-frame hook knows to switch back to the stack scene once.
    private var showingScopeDueToStall = false
    /// Set when the operator changes the program scene by hand (an event we
    /// didn't cause). Suspends automation until the next stall/resume boundary.
    private var manualOverride = false
    /// The scene name automation last requested, so an incoming
    /// CurrentProgramSceneChanged can tell "us" from "the operator".
    private var lastAutomationScene: String?

    public init(obs: OBSController, deps: BroadcastDeps) {
        self.obs = obs
        self.deps = deps
        // Route OBS diagnostics into the session log. onLog fires on the main
        // actor (OBSController is @MainActor), so forwarding is safe.
        let log = deps.log
        obs.onLog = { message in log("OBS: \(message)") }
        // Review8 item 3: output events and unexpected connection loss reach
        // the broadcast state machine — both hooks fire on the main actor.
        obs.onOutputEvent = { [weak self] in self?.noteOBSStateMayHaveChanged() }
        obs.onConnectionLost = { [weak self] in self?.handleConnectionLoss() }
    }

    deinit {
        // Cold-review1 minor 5: the repeating scene timer is retained by the
        // main RunLoop — the timer holds only a weak self, so the controller
        // deallocates fine, but WITHOUT this the timer itself leaked and kept
        // firing forever when the controller was released without
        // sessionDidEnd(). The controller is main-actor-owned, so
        // deallocation runs on the main thread — the thread the timer was
        // scheduled on, as invalidate() requires.
        sceneTimer?.invalidate()
    }

    // MARK: - Session hooks (called by the app where the logic fired inline)

    /// Session start: begin scene automation. `subExposureSeconds` comes from the
    /// session profile (owned by the app) — passed in so the controller stays
    /// reference-free.
    public func sessionDidStart(subExposureSeconds: Double) {
        startSceneAutomation(subExposureSeconds: subExposureSeconds)
    }

    /// Session end, IMMEDIATE part: stop scene automation and reset any live
    /// broadcast state — runs at the End Session click, so automation never
    /// stays active during a (possibly long) replay render. The OBS
    /// stream/record stop is NOT here: the app calls
    /// `stopBroadcastAfterSessionEnd()` only after replay generation completes
    /// or fails (review4 P2 — the README promises "replay first, then — and
    /// only then — stop the stream", and now the code matches).
    public func sessionDidEnd() {
        stopSceneAutomation()

        // Review5 P2: while the stream deliberately stays live until replay generation
        // finishes, do NOT report idle — that offered a Go Live the deferred stop would kill,
        // hid End Broadcast, and hid health while actually streaming.
        switch broadcastState {
        case .live:
            // Still streaming: enter .endingSession and KEEP the health poll + streamHealth
            // alive (keep reporting truth). goLive() is blocked (guard requires .idle);
            // stopBroadcastAfterSessionEnd() performs the actual stop after the replay —
            // unless the operator overrides with End Broadcast first.
            goLiveTask?.cancel()
            goLiveTask = nil
            broadcastState = .endingSession
        case .connecting:
            // Nothing live yet — invalidate the in-flight bring-up (generation bump: its
            // completions are stale from this instant) and return to the attempt's ORIGIN
            // (review10 finding 4): a connect begun at .unknown never confirmed any output
            // state, so hardcoding .idle here manufactured a confirmation that never
            // happened. Only a previously CONFIRMED .idle may be reclaimed.
            broadcastGeneration += 1
            goLiveTask?.cancel()
            goLiveTask = nil
            healthPollTask?.cancel()
            healthPollTask = nil
            streamHealth = nil
            broadcastState = teardownLanding(from: connectingOrigin)
        case .unknown, .idle, .endingSession, .stopping, .stopUnconfirmed:
            break
        }

        // Review6 P1: remember which generation this session-end intends to clean up.
        // Captured AFTER any bump above; a Go Live during the replay render bumps past
        // it and the deferred stop no-ops instead of killing the new broadcast.
        pendingSessionEndGeneration = broadcastGeneration
    }

    /// Session end, DEFERRED part: the deliberate end-of-session stop. Called
    /// by the app strictly AFTER the pipeline's end()/replay generation
    /// returned or threw (a replay failure still stops the stream). App quit /
    /// abort / crash paths never call this — an accidental quit must never
    /// kill the broadcast.
    ///
    /// Review6 P1: only acts on the generation `sessionDidEnd()` captured. If a
    /// newer Go Live (End-Session-while-idle → Go Live during replay) or an
    /// operator End Broadcast bumped the generation, this no-ops.
    public func stopBroadcastAfterSessionEnd() {
        guard let captured = pendingSessionEndGeneration else { return }
        pendingSessionEndGeneration = nil
        guard captured == broadcastGeneration else {
            deps.log("OBS: deferred stop skipped — a newer broadcast is live")
            return
        }
        // Nothing deliberately live for this generation (session ended from idle, or the
        // .connecting bring-up was cancelled at the click): nothing to stop. A stream a
        // stale bring-up managed to start is undone by goLive's stale-completion cleanup.
        guard broadcastState == .endingSession else { return }

        // Transition synchronously so the UI shows "Stopping…" the moment the replay is
        // done, then await the CONFIRMED stop and settle to .idle / .stopUnconfirmed.
        broadcastState = .stopping
        let gen = broadcastGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let confirmed = await self.confirmedStop()
            guard gen == self.broadcastGeneration else { return }   // stale: someone took over
            self.healthPollTask?.cancel()
            self.healthPollTask = nil
            self.streamHealth = nil
            self.settleAfterStop(confirmed: confirmed)
        }
    }

    /// Per-accepted-frame hook. Resets the stall clock and drives the
    /// automation "resume" boundary.
    public func frameAccepted() {
        onFrameAccepted()
    }

    // MARK: - OBS bring-up

    /// Connect to OBS, requesting an app-side launch if needed. Returns whether
    /// connected. Does NOT start any stream — broadcasting is deliberate (goLive()).
    ///
    /// Review8 item 2: the OBS client's `.connecting` state is NOT connected —
    /// only a completed handshake counts. `obs.connect` coalesces onto any
    /// in-flight attempt and returns its ACTUAL outcome, so awaiting it here
    /// never reports success from a half-open client (whose seed/reconcile
    /// queries would fail and tear down the connection being established).
    private func connectOBS() async -> Bool {
        if obs.state == .connected || obs.state == .streaming { return true }

        var connected = await obs.connect(host: obsHost, port: obsPort,
                                          password: obsPassword.isEmpty ? nil : obsPassword)

        if !connected && obsAutoLaunch {
            deps.launchOBS()
            // Retry connect every `launchRetryDelaySeconds` until success or
            // the `launchRetryBudgetSeconds` budget elapses.
            let deadline = Date().addingTimeInterval(launchRetryBudgetSeconds)
            while !connected && Date() < deadline && !Task.isCancelled {
                // Cancellation-aware sleep: a cancel throws here, which we treat
                // as "stop retrying" — return false.
                do {
                    try await Task.sleep(nanoseconds: UInt64(launchRetryDelaySeconds * 1_000_000_000))
                } catch { return false }
                if obs.state == .connected || obs.state == .streaming {
                    connected = true    // someone else's attempt completed
                } else {
                    // .disconnected starts a fresh attempt; .connecting coalesces
                    // onto the in-flight one — either way the result is real.
                    connected = await obs.connect(host: obsHost, port: obsPort,
                                                  password: obsPassword.isEmpty ? nil : obsPassword)
                }
            }
        }

        if !connected {
            deps.log("OBS: not connected")
        }
        return connected
    }

    // MARK: - Reconcile (review7 P1 — .idle must be CONFIRMED, never assumed)

    private enum ReconcileOutcome {
        /// OBS confirmed stream AND recording inactive — genuinely idle.
        case bothInactive
        /// OBS is already streaming: the broadcast was ADOPTED (.live, health
        /// polling started). End Broadcast works on it; Go Live stays blocked.
        case adoptedLive
        /// Status unavailable, or recording still active: `.stopUnconfirmed`
        /// was entered (Go Live blocked, Retry reconciles by stopping).
        case unconfirmed
        /// The generation moved on mid-reconcile; state untouched.
        case stale
    }

    /// Align `broadcastState` with OBS's ACTUAL output state, right after a
    /// successful connect (manual Connect or the Go Live path). The matrix:
    /// - stream off + recording off → confirmed idle (`.bothInactive`; the
    ///   CALLER sets `.idle` or proceeds with its bring-up)
    /// - stream on → adopt the external broadcast (`.live` + health poll)
    /// - stream off + recording on → `.stopUnconfirmed` (never `.idle` while
    ///   any output is active; Retry stops the recording and reconfirms)
    /// - either status unavailable → `.stopUnconfirmed` (may be live, can't
    ///   confirm)
    /// Runs under the caller's generation `gen`; every await re-checks it.
    ///
    /// Review10 finding 2 (SPLIT-SNAPSHOT/OWNERSHIP RACES): the `.bothInactive`
    /// conclusion is assembled from TWO sequential status reads — an output
    /// event landing between them (an external stream start while the record
    /// read is in flight) tears the snapshot. The output-event generation is
    /// captured BEFORE the first read and revalidated AFTER the last; torn →
    /// the conclusion is discarded and the reads re-run (bounded); exhausted →
    /// `.stopUnconfirmed`, never a fabricated `.idle`.
    private func reconcile(gen: Int) async -> ReconcileOutcome {
        for _ in 0..<max(1, maxSnapshotRetries) {
            let snapshot = outputEventGeneration
            let stream = await obs.streamStatus()
            guard gen == broadcastGeneration else { return .stale }
            guard let stream else {
                broadcastState = .stopUnconfirmed
                deps.log("OBS: could not confirm stream state after connect — OBS may be live")
                return .unconfirmed
            }
            if stream.active {
                // Single-read conclusion: atomic with its own read (the switch
                // below runs in the same synchronous segment) — no tear possible.
                broadcastState = .live
                streamHealth = stream
                deps.log("OBS already streaming — adopted the live broadcast")
                startHealthPoll()
                return .adoptedLive
            }
            let recording = await obs.recordStatus()
            guard gen == broadcastGeneration else { return .stale }
            guard let recording else {
                broadcastState = .stopUnconfirmed
                deps.log("OBS: could not confirm recording state after connect — OBS may be live")
                return .unconfirmed
            }
            guard snapshot == outputEventGeneration else {
                deps.log("OBS: output event landed during reconcile — re-reading")
                continue   // torn snapshot: discard the conclusion, re-read
            }
            if recording {
                broadcastState = .stopUnconfirmed
                deps.log("OBS: recording is active in OBS — Retry stops it, or stop it in OBS")
                return .unconfirmed
            }
            return .bothInactive
        }
        // Retries exhausted: events kept tearing the snapshot — never claim .idle.
        broadcastState = .stopUnconfirmed
        deps.log("OBS: output state kept changing during reconcile — OBS may be live")
        return .unconfirmed
    }

    /// Whether manual Connect is currently legal (cold-review1 finding 2).
    /// Only states with NO live broadcast machinery may start a reconnect:
    /// from `.live`/`.endingSession` the health poll + event stream own truth
    /// over a WORKING session, and from `.stopping` an in-flight stop owns its
    /// settlement — a reconnect would bump the generation (orphaning the
    /// owner) and tear the working control session down. ControlView's
    /// Connect button mirrors this for its enable-state.
    public var connectAllowed: Bool {
        switch broadcastState {
        case .unknown, .idle, .stopUnconfirmed: return true
        case .connecting, .live, .endingSession, .stopping: return false
        }
    }

    /// Manual Connect, SYNCHRONOUS entry (review8 item 2 — mirrors goLive()'s
    /// shape): reserves `.connecting` and bumps the generation AT the click,
    /// so a Go Live during the connect/seed/reconcile await is rejected by its
    /// own state guard and every in-flight completion is stale from this
    /// instant. Then launches the connect+reconcile task. ControlView's
    /// Connect button calls this directly — no Task wrapper at the call site.
    ///
    /// Cold-review1 finding 2: entry is guarded to {.unknown, .idle,
    /// .stopUnconfirmed} — from a rich state this no-ops with an honest log
    /// instead of killing the working session's machinery.
    public func beginConnectAndReconcile() {
        guard broadcastState != .connecting else { return }   // one attempt at a time
        guard connectAllowed else {
            deps.log("OBS: already connected/stopping — not reconnecting")
            return
        }
        broadcastGeneration += 1
        let gen = broadcastGeneration
        let origin = broadcastState
        connectingOrigin = origin   // review10 finding 4: teardown returns here
        broadcastState = .connecting
        Task { @MainActor [weak self] in
            await self?.runConnectAndReconcile(gen: gen, origin: origin)
        }
    }

    /// Manual Connect (review7 P1): bring the control link up (NEVER launching
    /// OBS — that is a Go Live-only affordance) and reconcile `broadcastState`
    /// with OBS's actual output state, so connecting to an already-streaming
    /// OBS adopts the broadcast instead of offering a Go Live that would
    /// double-start it. Returns whether the control link connected.
    ///
    /// Awaitable variant of `beginConnectAndReconcile()` (used by tests and
    /// programmatic callers). The reservation is identical and happens before
    /// this function's first await.
    @discardableResult
    public func connectAndReconcile() async -> Bool {
        guard broadcastState != .connecting else {
            return obs.state == .connected || obs.state == .streaming
        }
        // Cold-review1 finding 2: same entry guard as the synchronous entry.
        guard connectAllowed else {
            deps.log("OBS: already connected/stopping — not reconnecting")
            return obs.state == .connected || obs.state == .streaming
        }
        broadcastGeneration += 1
        let gen = broadcastGeneration
        let origin = broadcastState
        connectingOrigin = origin   // review10 finding 4: teardown returns here
        broadcastState = .connecting
        return await runConnectAndReconcile(gen: gen, origin: origin)
    }

    /// The awaited half of manual Connect. Runs under the generation captured
    /// at the click.
    ///
    /// Failure landing (cold-review1 finding 2): `obs.connect` tore down
    /// whatever link existed and the reconnect FAILED, so no origin whose
    /// claim depended on that link may be restored verbatim. With the entry
    /// guard the only origins here are `.unknown`, `.idle` and
    /// `.stopUnconfirmed`:
    /// - `.unknown` → `.unknown` (nothing was ever claimed);
    /// - `.idle` → `.unknown` — the confirmation predates the (now dead)
    ///   link, so it is no longer confirmable (the reviewer's own
    ///   connection-loss map: loss from `.idle` lands `.unknown`);
    /// - `.stopUnconfirmed` → `.stopUnconfirmed` (already honest; retryStop
    ///   reconnects for itself).
    /// The invariant: a failure never lands a state whose machinery (health
    /// poll, stop ownership, confirmed-idle claim) is dead.
    @discardableResult
    private func runConnectAndReconcile(gen: Int, origin: BroadcastState) async -> Bool {
        let connected = await obs.connect(host: obsHost, port: obsPort,
                                          password: obsPassword.isEmpty ? nil : obsPassword)
        guard gen == broadcastGeneration else { return connected }   // superseded: owner governs
        guard connected else {
            broadcastState = origin == .stopUnconfirmed ? .stopUnconfirmed : .unknown
            if origin == .idle {
                deps.log("OBS: reconnect failed — the confirmed idle is no longer confirmable")
            }
            return false
        }
        if await reconcile(gen: gen) == .bothInactive {
            broadcastState = .idle   // now genuinely confirmed
        }
        return true
    }

    // MARK: - Broadcast orchestration

    public func goLive() {
        // Review7 P1: .unknown keeps one-click Go Live from a cold start — the
        // task below connects AND reconciles first, and only starts a broadcast
        // when the reconcile confirmed both outputs inactive.
        guard broadcastState == .idle || broadcastState == .unknown else { return }
        let origin = broadcastState
        // Every Go Live bumps the generation (review6 P1/P2): the deferred
        // session-end stop and any cancelled earlier attempt are stale from here.
        broadcastGeneration += 1
        let gen = broadcastGeneration
        connectingOrigin = origin   // review10 finding 4: teardown returns here
        broadcastState = .connecting
        goLiveTask = Task { @MainActor in
            let connected = await connectOBS()
            guard gen == broadcastGeneration else { return }   // stale: cancelled/superseded
            guard connected else {
                deps.presentError("OBS not reachable — is it installed and running?")
                // A confirmed .idle stays confirmed; from .unknown stay honest.
                broadcastState = origin
                return
            }
            // Review7 P1: reconcile with ACTUAL OBS output state before starting
            // anything. Adopting an already-live stream or failing to confirm
            // state ends the attempt right here (never a double StartStream).
            switch await reconcile(gen: gen) {
            case .stale:
                deps.log("OBS: stale go-live attempt discarded")
                return
            case .adoptedLive:
                return
            case .unconfirmed:
                deps.presentError("OBS may already be live — check OBS, then Retry.")
                return
            case .bothInactive:
                break   // genuinely nothing running — proceed with the bring-up
            }
            let scene = stackSceneName.isEmpty ? nil : stackSceneName
            // Review10 finding 2: an app-issued StartStream is in flight from
            // here until its StartOutcome settles — the ONLY window in which
            // the drain defers a stream-started event (it is our own echo;
            // the confirmation below owns it).
            appStartInFlight = true
            let outcome = await obs.startBroadcast(scene: scene,
                                                   confirmPollSeconds: confirmPollSeconds,
                                                   maxConfirmPolls: maxConfirmPolls)
            appStartInFlight = false
            runDeferredReconcileIfNeeded()
            guard gen == broadcastGeneration else {
                settleStaleStart(outcome: outcome)
                return
            }
            switch outcome {
            case .confirmedLive:
                broadcastState = .live
                // Review6 P2: "Record while streaming" — start recording only after
                // the stream is confirmed up. A recording failure never fails the
                // broadcast; log it honestly and stream on.
                if obsRecord {
                    let recording = await obs.setRecording(true)
                    guard gen == broadcastGeneration else { return }   // stale after await
                    if !recording {
                        deps.log("OBS: could not start recording — continuing the broadcast without it")
                    } else {
                        // Review7 P2: an accepted StartRecord is NOT output-state
                        // confirmation — poll GetRecordStatus until the record
                        // output is active or the polls expire. Expiry warns
                        // honestly and streams on (unchanged policy).
                        let active = await obs.confirmRecordingActive(
                            confirmPollSeconds: confirmPollSeconds,
                            maxConfirmPolls: maxConfirmPolls)
                        guard gen == broadcastGeneration else { return }
                        if !active {
                            deps.log("OBS: recording did not activate — check OBS; continuing the broadcast without it")
                        }
                    }
                }
                startHealthPoll()
            case .issuedUnconfirmed:
                // Review7 P1: startBroadcast no longer stops on a failed confirm —
                // this CALLER owns cleanup, and only at the CURRENT generation
                // (validated above). Confirmed-stop semantics: .idle only when OBS
                // confirmed both outputs inactive; otherwise .stopUnconfirmed.
                //
                // Cold-review1 finding 1: the cleanup must own itself the way the
                // STALE paths do. Pre-fix it awaited confirmedStop() INSIDE this
                // (UI-cancellable) goLiveTask with state still .connecting —
                // Disconnect or sessionDidEnd cancelled the cleanup instantly
                // (the client's requests are cancellation-aware) and their
                // teardownLanding reclaimed the origin (.idle): an issued,
                // never-confirmed-stopped StartStream behind a "confirmed idle".
                // Mirror settleStaleStart: reserve .stopping SYNCHRONOUSLY
                // (generation bump — goLive is guarded, and both cancellers now
                // land honestly: disconnect's .stopping branch escalates to
                // .stopUnconfirmed; sessionDidEnd's .stopping branch leaves the
                // cleanup alone) and run the confirmed stop in a fresh
                // unstructured task that no UI cancellation reaches.
                broadcastGeneration += 1
                let cleanupGen = broadcastGeneration
                broadcastState = .stopping
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let confirmed = await self.confirmedStop()
                    guard cleanupGen == self.broadcastGeneration else { return }   // superseded mid-cleanup
                    if confirmed {
                        self.deps.presentError("OBS started but the stream didn't go live — check OBS ▸ Settings ▸ Stream (YouTube server + key).")
                        self.broadcastState = .idle
                        self.runDeferredReconcileIfNeeded()
                    } else {
                        self.settleAfterStop(confirmed: false)
                    }
                }
            case .notIssued:
                // Nothing was issued (cancellation confirmed before StartStream
                // was enqueued): return to the origin state honestly — a
                // confirmed .idle stays confirmed; from .unknown stay .unknown.
                deps.log("OBS: go-live cancelled before anything was issued")
                broadcastState = origin
            }
        }
    }

    /// Landing for a go-live completion that lost the generation race (review7
    /// P1, extended by review8 item 1 for the outcome-typed boundary):
    /// - `.notIssued`: cancellation was confirmed BEFORE StartStream was
    ///   enqueued — nothing to undo, log and leave every state alone.
    /// - `.confirmedLive`: the existing stale-success rules (never stop past a
    ///   newer active owner; a no-owner orphan gets a CONFIRMED cleanup or an
    ///   honest `.stopUnconfirmed`).
    /// - `.issuedUnconfirmed`: StartStream may have been issued and nothing has
    ///   confirmed the result. If a newer owner is active its machinery
    ///   governs; with NO newer owner, `.stopping` is reserved SYNCHRONOUSLY
    ///   before any await (goLive guards on .idle/.unknown, so a new Go Live
    ///   cannot begin while the orphan cleanup is awaiting OBS) and the cleanup
    ///   settles `.idle` only on confirmation, else `.stopUnconfirmed`.
    /// Invariant: anything that MAY have issued StartStream never settles
    /// `.idle` without a confirmed cleanup.
    ///
    /// Synchronous ON PURPOSE: the caller is usually a CANCELLED task (that's
    /// why its start went stale), and cancellation-aware requests issued from
    /// it would resolve instantly without ever sending StopStream. All state
    /// reservations happen in this synchronous segment; the cleanup awaits run
    /// in a fresh unstructured task that does not inherit the cancellation.
    private func settleStaleStart(outcome: OBSController.StartOutcome) {
        switch outcome {
        case .notIssued:
            deps.log("OBS: stale go-live attempt discarded — nothing was issued")

        case .confirmedLive:
            discardStaleGoLive()

        case .issuedUnconfirmed:
            switch broadcastState {
            case .connecting, .live, .endingSession:
                // A newer broadcast owner is active: its own confirm/stop
                // machinery governs the stream — never stop past it.
                deps.log("OBS: stale go-live attempt discarded — a newer broadcast owns the stream")
            case .unknown, .idle, .stopping, .stopUnconfirmed:
                // No newer owner: the possibly-issued StartStream is an orphan
                // only we can clean up. Take ownership SYNCHRONOUSLY (generation
                // bump + .stopping reservation happen before any await, so a
                // new Go Live is rejected while the cleanup is in flight).
                deps.log("OBS: stale go-live attempt discarded — StartStream may have been issued; stopping and confirming")
                broadcastGeneration += 1
                let gen = broadcastGeneration
                broadcastState = .stopping
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let confirmed = await self.confirmedStop()
                    guard gen == self.broadcastGeneration else { return }   // superseded mid-cleanup
                    self.settleAfterStop(confirmed: confirmed)
                }
            }
        }
    }

    /// Stale-SUCCESS landing (review7 P1). NEVER sends StopStream while a
    /// newer broadcast is active or connecting — that stop would kill the
    /// newer owner's stream (the exact bug the internal StopStream-on-expiry
    /// in OBSController used to cause). Only a stale success with no newer
    /// owner may undo the stream it started, and that stop must be CONFIRMED:
    /// an unconfirmed cleanup escalates a (previously confirmed) .idle to
    /// .stopUnconfirmed honestly rather than leaving a possibly-live OBS
    /// behind an idle UI. (Review8: with the cancellation-aware client a stale
    /// SUCCESS needs the confirm response to beat the cancel — rare but real —
    /// so this path is kept; the cleanup runs in a fresh task for the same
    /// reason as `settleStaleStart`.)
    /// Internal for tests: the `.confirmedLive`-stale landing requires the
    /// confirm response to beat an in-flight cancel, which cannot be scheduled
    /// deterministically through the public API — tests invoke this directly.
    func discardStaleGoLive() {
        switch broadcastState {
        case .connecting, .live, .endingSession, .unknown:
            // .unknown: OBS state is unconfirmed — a stop could kill a stream we
            // never owned, so leave it alone (same honesty as the newer-owner case).
            deps.log("OBS: stale go-live attempt discarded — a newer broadcast owns the stream")
        case .idle, .stopping, .stopUnconfirmed:
            // Review10 finding 3 (SPLIT-SNAPSHOT/OWNERSHIP RACES — ownership
            // half): mirror the .issuedUnconfirmed path EXACTLY. Pre-fix this
            // cleanup awaited StopStream while the state stayed .idle, so a
            // new Go Live could begin during the await and the stale cleanup
            // then killed it. Ownership is reserved SYNCHRONOUSLY before any
            // await (generation bump + .stopping — goLive guards on
            // .idle/.unknown, so nothing new can start), and every post-await
            // step is generation-checked.
            deps.log("OBS: stale go-live attempt discarded — stopping the stream it started")
            broadcastGeneration += 1
            let gen = broadcastGeneration
            broadcastState = .stopping
            Task { @MainActor [weak self] in
                guard let self else { return }
                let confirmed = await self.confirmedStop()
                guard gen == self.broadcastGeneration else { return }   // superseded mid-cleanup
                self.settleAfterStop(confirmed: confirmed)
            }
        }
    }

    /// Deliberate stop. Accepts `.endingSession` too (operator override while
    /// the replay renders — stream down NOW): the generation bumps
    /// SYNCHRONOUSLY at entry, so the deferred session-end stop is stale from
    /// that instant. Settles to `.idle` ONLY on a confirmed stream+record
    /// inactive; otherwise `.stopUnconfirmed` with Retry.
    public func endBroadcast() {
        switch broadcastState {
        case .live, .endingSession: break
        case .connecting:
            // Cold-review1 minor 4: with NO app-issued StartStream in flight,
            // a .connecting attempt provably issued nothing — StartStream is
            // only sent inside obs.startBroadcast, whose in-flight window is
            // exactly `appStartInFlight` (a settled outcome leaves .connecting
            // in the same synchronous segment). Aborting the attempt lands the
            // honest teardown mapping of its ORIGIN — never a "OBS may still
            // be live" claim about a stream that was never started. With a
            // start possibly issued, fall through to the confirmed stop
            // (finding 1 composition: possibly-issued → confirmed cleanup /
            // .stopUnconfirmed; provably-not-issued → origin).
            guard appStartInFlight else {
                broadcastGeneration += 1
                goLiveTask?.cancel(); goLiveTask = nil
                healthPollTask?.cancel(); healthPollTask = nil
                streamHealth = nil
                broadcastState = teardownLanding(from: connectingOrigin)
                deps.log("OBS: broadcast attempt aborted — nothing was started")
                return
            }
        case .unknown, .idle, .stopping, .stopUnconfirmed: return
        }
        broadcastGeneration += 1
        let gen = broadcastGeneration
        broadcastState = .stopping
        goLiveTask?.cancel(); goLiveTask = nil
        healthPollTask?.cancel(); healthPollTask = nil
        Task { @MainActor in
            let confirmed = await confirmedStop()
            guard gen == broadcastGeneration else { return }
            streamHealth = nil
            settleAfterStop(confirmed: confirmed)
        }
    }

    /// Re-attempt a stop that could not be confirmed (`.stopUnconfirmed`).
    /// Reconnects the control link first if it dropped (a stranded-live
    /// disconnect lands here) — but never launches OBS.
    public func retryStop() {
        guard broadcastState == .stopUnconfirmed else { return }
        broadcastGeneration += 1
        let gen = broadcastGeneration
        broadcastState = .stopping
        Task { @MainActor in
            if obs.state == .disconnected {
                await obs.connect(host: obsHost, port: obsPort,
                                  password: obsPassword.isEmpty ? nil : obsPassword)
                guard gen == broadcastGeneration else { return }
            }
            let confirmed = await confirmedStop()
            guard gen == broadcastGeneration else { return }
            streamHealth = nil
            settleAfterStop(confirmed: confirmed)
        }
    }

    /// Disconnect the OBS control link. Disconnect ≠ stop, BY DESIGN: no
    /// StopStream is ever sent (an accidental quit/disconnect must never kill
    /// a broadcast). But honesty demands the state say so: a disconnect that
    /// strands a live (or stopping-but-unconfirmed) stream lands in
    /// `.stopUnconfirmed`, never `.idle`.
    public func disconnect() {
        obs.disconnect()
        switch broadcastState {
        case .live, .endingSession, .stopping:
            broadcastGeneration += 1
            goLiveTask?.cancel(); goLiveTask = nil
            healthPollTask?.cancel(); healthPollTask = nil
            streamHealth = nil
            broadcastState = .stopUnconfirmed
            deps.log("OBS: control link disconnected while the stream is live — OBS keeps streaming (disconnect ≠ stop). Reconnect and Retry to stop it, or stop it in OBS.")
        case .connecting:
            // Bring-up abandoned: invalidate it and return to the attempt's ORIGIN
            // (review10 finding 4 — a connect begun at .unknown confirmed nothing, so
            // .idle here was a fabricated confirmation). Any stream a stale attempt
            // manages to start is undone by its stale-completion cleanup.
            broadcastGeneration += 1
            goLiveTask?.cancel(); goLiveTask = nil
            healthPollTask?.cancel(); healthPollTask = nil
            streamHealth = nil
            broadcastState = teardownLanding(from: connectingOrigin)
        case .unknown, .idle, .stopUnconfirmed:
            // Review7 P1: disconnecting from .unknown stays .unknown — nothing
            // was ever confirmed, so nothing gets claimed now either.
            break
        }
    }

    // MARK: - Event-driven reconciliation (review8 item 3 — the dirty-drain)

    /// Coalescing dirty flag: any OBS output event (or the health poll's
    /// inactive detection) sets it; ONE drain task serializes every
    /// reconciliation pass so there is a single reconciliation authority.
    private var reconcileDirty = false
    private var reconcileDrainTask: Task<Void, Never>?

    /// Note that OBS's output state may have changed. The drain invariant:
    /// an event sets `dirty = true` (and spawns the drain task if none is
    /// active); the active drain clears `dirty` immediately before each
    /// reconciliation pass; any event arriving during an await sets it again,
    /// forcing another pass; drain-task teardown and the FINAL dirty check
    /// occur in ONE main-actor synchronous segment — if dirty was re-set, the
    /// drain loops again instead of exiting, so a wakeup can never be lost.
    func noteOBSStateMayHaveChanged() {
        // Review10 SPLIT-SNAPSHOT primitive: every output-event arrival bumps
        // the output-event generation in the SAME synchronous segment that
        // marks the drain dirty — any multi-read confirmation that captured an
        // older value now holds a torn snapshot and must discard its conclusion.
        outputEventGeneration += 1
        reconcileDirty = true
        guard reconcileDrainTask == nil else { return }
        reconcileDrainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while true {
                self.reconcileDirty = false        // cleared immediately before the pass
                await self.reconcilePass()
                // ONE synchronous segment: the final dirty check and the
                // drain teardown — no await between them.
                if self.reconcileDirty { continue }
                self.reconcileDrainTask = nil
                return
            }
        }
    }

    /// One serialized reconciliation pass — aligns `broadcastState` with OBS's
    /// ACTUAL output state using the review7 matrix (stream on → adopt .live;
    /// stream off + record off → .idle; stream off + record on →
    /// .stopUnconfirmed; status unavailable → .stopUnconfirmed), plus the
    /// OWNERSHIP-precise rules (review10 findings 1+2 — no state may
    /// blanket-discard events):
    /// - a stream START while an APP-ISSUED StartStream is in flight never
    ///   steals ownership from it — it is our own echo, the goLive
    ///   confirmation governs; the pass re-runs when that owner settles.
    ///   A manual connect/reconcile owns no output transition, so external
    ///   events during `.connecting` reconcile normally (they also tear the
    ///   manual reconcile's split-snapshot guard).
    /// - a stream START during `.stopping` (a restart racing the stop) is
    ///   deferred to a post-settlement pass, never dropped;
    /// - a stream STOP during `.stopping` never claims `.idle` before
    ///   recording is ALSO confirmed inactive, and every other landing from
    ///   `.stopping` belongs to the stop machinery's own settlement.
    /// Captures (broadcastGeneration, connectionEpoch, outputEventGeneration)
    /// at entry and revalidates after every await — the two-read conclusion
    /// at the bottom is a SPLIT SNAPSHOT (review10) and is discarded when an
    /// output event tears it (the same event re-marked the drain dirty, so
    /// the drain re-runs with fresh reads).
    private func reconcilePass() async {
        // Reconciliation needs OBS truth: with no completed link there is
        // nothing to query (connection loss has its own synchronous rules).
        guard obs.state == .connected || obs.state == .streaming else { return }
        // OWNERSHIP (review10 finding 2): defer ONLY to an app-issued
        // StartStream in flight — the scoped replacement for the old blanket
        // ".connecting ignores events" rule. Its settlement re-runs the drain.
        if appStartInFlight {
            reconcileWhenOwnerSettles = true
            return
        }
        let gen = broadcastGeneration
        let epoch = obs.connectionEpoch
        let snapshot = outputEventGeneration   // SPLIT-SNAPSHOT capture (review10)

        let stream = await obs.streamStatus()
        guard gen == broadcastGeneration, epoch == obs.connectionEpoch else { return }
        guard let stream else {
            // Status unavailable → OBS may be live and nothing is confirmable.
            // .stopping's landing belongs to the stop machinery; an existing
            // .stopUnconfirmed is already honest; a .connecting attempt's own
            // (equally failing) reads settle it honestly.
            if broadcastState != .stopping && broadcastState != .stopUnconfirmed
                && broadcastState != .connecting {
                settleReconcile(to: .stopUnconfirmed,
                                log: "OBS: could not confirm stream state — OBS may be live")
            }
            return
        }

        if stream.active {
            switch broadcastState {
            case .live, .endingSession:
                streamHealth = stream          // expected-live: refresh truth
            case .stopping:
                // Review10 finding 1: a stream RESTART during .stopping is no
                // longer blanket-discarded — the stop machinery owns .stopping
                // until it settles, then the deferred pass adopts the restart
                // honestly (never .idle over a live stream).
                reconcileWhenOwnerSettles = true
            case .idle, .unknown, .stopUnconfirmed, .connecting:
                // .connecting here is a manual connect/reconcile (no app start
                // in flight — guarded above): reality takes over; the manual
                // attempt's completions go stale on the generation bump.
                settleReconcile(to: .live,
                                log: "OBS: stream is active in OBS — adopted the live broadcast")
                streamHealth = stream
                startHealthPoll()
            }
            return
        }

        // Stream inactive: .idle additionally requires recording confirmed off.
        let recording = await obs.recordStatus()
        guard gen == broadcastGeneration, epoch == obs.connectionEpoch else { return }
        // SPLIT-SNAPSHOT revalidation (review10): an output event between the
        // stream and record reads tears this two-read conclusion. The same
        // event already re-marked the drain dirty, so discard and re-run.
        guard snapshot == outputEventGeneration else { return }

        switch broadcastState {
        case .stopping:
            // Only the FULLY confirmed outcome may land .idle from here —
            // anything less stays with the in-flight stop's own settlement.
            if recording == false {
                settleReconcile(to: .idle,
                                log: "OBS: stream and recording confirmed inactive — broadcast over")
            }
        case .live, .endingSession:
            if recording == false {
                settleReconcile(to: .idle, log: "OBS: stream ended in OBS — broadcast over")
            } else if recording == true {
                settleReconcile(to: .stopUnconfirmed,
                                log: "OBS: stream ended in OBS but recording is still active — Retry stops it")
            } else {
                settleReconcile(to: .stopUnconfirmed,
                                log: "OBS: stream ended in OBS — could not confirm recording state")
            }
        case .idle, .unknown, .stopUnconfirmed:
            if recording == false {
                if broadcastState != .idle {
                    settleReconcile(to: .idle,
                                    log: "OBS: stream and recording confirmed inactive")
                }
            } else if broadcastState != .stopUnconfirmed {
                settleReconcile(to: .stopUnconfirmed,
                                log: recording == true
                                    ? "OBS: recording is active in OBS — Retry stops it, or stop it in OBS"
                                    : "OBS: could not confirm recording state — OBS may be live")
            }
        case .connecting:
            // Inactive-output conclusions during a manual connect belong to
            // the connect's own reconcile — it holds the current generation
            // and its split-snapshot guard covers these exact reads.
            break
        }
    }

    /// Reconcile settlement: reality takes over — bump the generation so every
    /// in-flight completion of the superseded state is stale, then transition.
    /// Runs in the synchronous segment after the pass's last (revalidated) await.
    private func settleReconcile(to state: BroadcastState, log message: String) {
        broadcastGeneration += 1
        goLiveTask?.cancel(); goLiveTask = nil
        healthPollTask?.cancel(); healthPollTask = nil
        if state != .live { streamHealth = nil }
        broadcastState = state
        deps.log(message)
    }

    /// Unexpected control-link loss (review8 item 3) — deliberate
    /// `disconnect()` never comes through here. The reviewer-specified rules:
    /// - `.idle` → `.unknown`: the confirmed idle is no longer confirmable;
    ///   reconnect-and-reconcile stays one click.
    /// - `.live` / `.endingSession` / `.stopping` → `.stopUnconfirmed`: OBS
    ///   keeps streaming without a control link (disconnect ≠ stop).
    /// - `.connecting` (review11 finding 2): NOT ignored — see the branch.
    /// - `.unknown` / `.stopUnconfirmed`: already honest, unchanged.
    private func handleConnectionLoss() {
        // Review10 SPLIT-SNAPSHOT primitive: connection loss is an output
        // event too — any multi-read snapshot spanning it is torn.
        outputEventGeneration += 1
        switch broadcastState {
        case .idle:
            broadcastGeneration += 1
            broadcastState = .unknown
            deps.log("OBS: control link lost — OBS state unknown until the next connect")
        case .live, .endingSession, .stopping:
            broadcastGeneration += 1
            goLiveTask?.cancel(); goLiveTask = nil
            healthPollTask?.cancel(); healthPollTask = nil
            streamHealth = nil
            broadcastState = .stopUnconfirmed
            deps.log("OBS: control link lost while the broadcast was active — OBS may still be live (disconnect ≠ stop). Reconnect and Retry to stop it, or stop it in OBS.")
        case .connecting:
            // Review11 finding 2: loss during a connect attempt must NOT be
            // discarded. A status answer already routed back to the attempt
            // could otherwise land .live over a dead link (the attempt's
            // generation was never bumped), leaving a health poll that reads
            // nil forever with no event link left to correct it. Bump the
            // generation — every in-flight completion of the attempt is
            // stale from this instant (each .live-setting site re-checks the
            // generation in the same synchronous segment as its mutation) —
            // and land the attempt honestly NOW, per the possibly-issued
            // rules: an app-issued StartStream in flight can only settle
            // .stopUnconfirmed; with nothing issued, the origin's loss-map
            // landing (.unknown; .stopUnconfirmed if a stop was already owed).
            broadcastGeneration += 1
            goLiveTask?.cancel(); goLiveTask = nil
            healthPollTask?.cancel(); healthPollTask = nil
            streamHealth = nil
            if appStartInFlight {
                broadcastState = .stopUnconfirmed
                deps.log("OBS: control link lost during the broadcast bring-up — StartStream may have been issued; OBS may be live (disconnect ≠ stop). Reconnect and Retry to stop it, or check OBS.")
            } else {
                broadcastState = connectingOrigin == .stopUnconfirmed ? .stopUnconfirmed : .unknown
                deps.log("OBS: control link lost during the connect attempt — OBS state unknown until the next connect")
            }
        case .unknown, .stopUnconfirmed:
            break
        }
    }

    /// The confirmed stop with the SPLIT-SNAPSHOT guard wired in (review10
    /// finding 1): `obs.stopBroadcast`'s two-read confirmation (stream, then
    /// recording) validates against `outputEventGeneration`, so a stream
    /// restart landing between the reads tears the snapshot and the
    /// confirmation re-reads instead of settling a false `.idle`.
    private func confirmedStop() async -> Bool {
        await obs.stopBroadcast(
            confirmPollSeconds: confirmPollSeconds,
            maxConfirmPolls: maxConfirmPolls,
            outputEventGeneration: { [weak self] in self?.outputEventGeneration ?? 0 })
    }

    /// Common landing for every confirmed-stop attempt (deferred session-end
    /// stop, End Broadcast, Retry): `.idle` only when OBS confirmed stream and
    /// recording inactive — otherwise `.stopUnconfirmed` with an honest error.
    private func settleAfterStop(confirmed: Bool) {
        if confirmed {
            broadcastState = .idle
        } else {
            broadcastState = .stopUnconfirmed
            deps.log("OBS: stop not confirmed — OBS may still be live")
            deps.presentError("OBS may still be live — check OBS, then Retry.")
        }
        // Review10 finding 1: if the drain observed a stream RESTART while the
        // stop machinery owned .stopping, the deferred pass runs NOW — the
        // settled state above is re-reconciled against OBS truth (an active
        // stream is adopted honestly instead of being discarded).
        runDeferredReconcileIfNeeded()
    }

    /// Review10: an owner (an app-issued start, or a stop in `.stopping`)
    /// settled — if the drain deferred a pass to that owner, run it now.
    private func runDeferredReconcileIfNeeded() {
        if reconcileWhenOwnerSettles {
            reconcileWhenOwnerSettles = false
            noteOBSStateMayHaveChanged()
        }
    }

    /// Review10 finding 4: the state a torn-down `.connecting` attempt lands
    /// in — its ORIGIN, honestly mapped. From `.unknown` nothing was ever
    /// confirmed, so nothing is claimed now either; a previously CONFIRMED
    /// `.idle` may be reclaimed; any origin that implied a possibly-live
    /// stream stays honest as `.stopUnconfirmed`.
    private func teardownLanding(from origin: BroadcastState) -> BroadcastState {
        switch origin {
        case .unknown, .connecting: return .unknown
        case .idle: return .idle
        case .live, .endingSession, .stopping, .stopUnconfirmed: return .stopUnconfirmed
        }
    }

    private func startHealthPoll() {
        healthPollTask?.cancel()
        let gen = broadcastGeneration
        healthPollTask = Task { @MainActor in
            // Poll through .endingSession too (review5 P2): the stream is deliberately still
            // live while the replay renders, so health keeps reporting truth until the stop.
            while !Task.isCancelled && gen == broadcastGeneration
                    && (broadcastState == .live || broadcastState == .endingSession) {
                let health = await obs.streamStatus()
                guard gen == broadcastGeneration,
                      broadcastState == .live || broadcastState == .endingSession else { return }
                if let health, !health.active {
                    // OBS CONFIRMED the stream inactive while we claim it live —
                    // an external stop. Review8 item 3: don't transition HERE;
                    // route the detection into the SAME serialized reconcile
                    // authority that handles output events. The drain settles
                    // (.idle only with recording also confirmed inactive) and
                    // its generation bump ends this poll.
                    noteOBSStateMayHaveChanged()
                } else {
                    streamHealth = health
                }
                try? await Task.sleep(nanoseconds: UInt64(healthPollIntervalSeconds * 1_000_000_000))
            }
        }
    }

    // MARK: - Scene automation

    /// Start the 15 s stall-check timer. Active only while a session runs AND
    /// scene automation is enabled. Seeds a StallDetector from the sub-exposure.
    private func startSceneAutomation(subExposureSeconds: Double) {
        stopSceneAutomation()   // idempotent; bumps automationGeneration
        guard sceneAutomationOn else { return }

        var detector = StallDetector(subExposureSeconds: subExposureSeconds)
        // Seed the clock so we don't report a stall before the first frame.
        detector.recordUpdate(at: Date())
        stall = detector
        showingScopeDueToStall = false
        manualOverride = false
        lastAutomationScene = nil

        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sceneTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sceneTimer = timer
    }

    private func stopSceneAutomation() {
        // Review6 P2: bump the automation generation so any already-queued
        // scene-change task (created by a tick/frame hook that ran before this
        // stop) no-ops instead of switching scenes after the session ended.
        automationGeneration += 1
        sceneTimer?.invalidate()
        sceneTimer = nil
        stall = nil
        showingScopeDueToStall = false
        manualOverride = false
        lastAutomationScene = nil
    }

    /// Fires every 15 s (timer); internal so tests can drive a tick with a
    /// controlled clock. If imaging has stalled and we aren't already showing
    /// the scope scene, switch to it once. Honors the manual-override flag.
    func sceneTick(now: Date = Date()) {
        guard sceneAutomationOn, deps.isSessionRunning(), let detector = stall else { return }

        // Detect an operator-initiated program-scene change: if the current OBS
        // scene isn't the one automation last set (and isn't nil/unknown),
        // suspend automation until the next stall/resume boundary.
        detectManualOverride()

        let stalledNow = detector.isStalled(at: now)
        if stalledNow && !showingScopeDueToStall && !manualOverride && !scopeSceneName.isEmpty {
            showingScopeDueToStall = true
            let scene = scopeSceneName
            let gen = automationGeneration
            Task { [weak self] in await self?.setSceneViaAutomation(scene, generation: gen) }
        }
    }

    /// Called on each accepted frame (main actor). Resets the stall clock and, if
    /// we were showing the scope scene due to a stall, switches back to the stack
    /// scene once. This is the "resume" boundary that also clears manual override.
    private func onFrameAccepted() {
        guard sceneAutomationOn, var detector = stall else { return }
        detector.recordUpdate(at: Date())
        stall = detector

        if showingScopeDueToStall {
            showingScopeDueToStall = false
            manualOverride = false   // resume boundary clears the override
            if !stackSceneName.isEmpty {
                let scene = stackSceneName
                let gen = automationGeneration
                Task { [weak self] in await self?.setSceneViaAutomation(scene, generation: gen) }
            }
        }
    }

    /// Set a scene *as automation*, remembering the name so a later
    /// CurrentProgramSceneChanged we caused isn't mistaken for a manual change.
    /// No-ops when `generation` is stale (review6 P2: stopSceneAutomation()
    /// already ran — never send SetCurrentProgramScene after the session ended).
    private func setSceneViaAutomation(_ name: String, generation: Int) async {
        guard generation == automationGeneration else { return }
        lastAutomationScene = name
        await obs.setScene(name)
    }

    /// If OBS's current program scene differs from what automation last set (and
    /// is a real, known scene), the operator changed it by hand — suspend
    /// automation until the next stall/resume boundary.
    private func detectManualOverride() {
        guard let current = obs.currentScene else { return }
        if let expected = lastAutomationScene, current != expected, !manualOverride {
            manualOverride = true
            deps.log("OBS: manual scene change detected (\(current)) — automation paused until next stall/resume")
        }
    }
}
