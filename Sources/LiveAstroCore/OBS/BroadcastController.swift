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
    public enum BroadcastState: Equatable {
        case idle, connecting, live, endingSession, stopping, stopUnconfirmed
    }
    public private(set) var broadcastState: BroadcastState = .idle
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
    private var sceneTimer: Timer?
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
            // completions are stale from this instant) and return to idle immediately.
            broadcastGeneration += 1
            goLiveTask?.cancel()
            goLiveTask = nil
            healthPollTask?.cancel()
            healthPollTask = nil
            streamHealth = nil
            broadcastState = .idle
        case .idle, .endingSession, .stopping, .stopUnconfirmed:
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
            let confirmed = await self.obs.stopBroadcast(
                confirmPollSeconds: self.confirmPollSeconds,
                maxConfirmPolls: self.maxConfirmPolls)
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
    private func connectOBS() async -> Bool {
        guard obs.state == .disconnected else { return true }  // already connected

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
                if obs.state == .disconnected {
                    connected = await obs.connect(host: obsHost, port: obsPort,
                                                  password: obsPassword.isEmpty ? nil : obsPassword)
                } else {
                    connected = obs.state != .disconnected
                }
            }
        }

        if !connected {
            deps.log("OBS: not connected")
        }
        return connected
    }

    // MARK: - Broadcast orchestration

    public func goLive() {
        guard broadcastState == .idle else { return }
        // Every Go Live bumps the generation (review6 P1/P2): the deferred
        // session-end stop and any cancelled earlier attempt are stale from here.
        broadcastGeneration += 1
        let gen = broadcastGeneration
        broadcastState = .connecting
        goLiveTask = Task { @MainActor in
            let connected = await connectOBS()
            guard gen == broadcastGeneration else { return }   // stale: cancelled/superseded
            guard connected else {
                deps.presentError("OBS not reachable — is it installed and running?")
                broadcastState = .idle; return
            }
            let scene = stackSceneName.isEmpty ? nil : stackSceneName
            let live = await obs.startBroadcast(scene: scene,
                                                confirmPollSeconds: confirmPollSeconds,
                                                maxConfirmPolls: maxConfirmPolls)
            guard gen == broadcastGeneration else {
                // Stale completion: NEVER mutate state (a newer attempt may own it).
                // But if we just brought a stream up and no newer broadcast owns one
                // (.idle/.stopping/.stopUnconfirmed), undo our own side effect so
                // nothing keeps running behind the user's back.
                if live {
                    switch broadcastState {
                    case .connecting, .live, .endingSession:
                        break   // a newer broadcast owns the stream — leave it alone
                    case .idle, .stopping, .stopUnconfirmed:
                        await obs.stopBroadcast(confirmPollSeconds: confirmPollSeconds,
                                                maxConfirmPolls: maxConfirmPolls)
                    }
                }
                return
            }
            if live {
                broadcastState = .live
                // Review6 P2: "Record while streaming" — start recording only after
                // the stream is confirmed up. A recording failure never fails the
                // broadcast; log it honestly and stream on.
                if obsRecord {
                    let recording = await obs.setRecording(true)
                    guard gen == broadcastGeneration else { return }   // stale after await
                    if !recording {
                        deps.log("OBS: could not start recording — continuing the broadcast without it")
                    }
                }
                startHealthPoll()
            } else {
                deps.presentError("OBS started but the stream didn't go live — check OBS ▸ Settings ▸ Stream (YouTube server + key).")
                broadcastState = .idle
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
        case .live, .connecting, .endingSession: break
        case .idle, .stopping, .stopUnconfirmed: return
        }
        broadcastGeneration += 1
        let gen = broadcastGeneration
        broadcastState = .stopping
        goLiveTask?.cancel(); goLiveTask = nil
        healthPollTask?.cancel(); healthPollTask = nil
        Task { @MainActor in
            let confirmed = await obs.stopBroadcast(confirmPollSeconds: confirmPollSeconds,
                                                    maxConfirmPolls: maxConfirmPolls)
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
            let confirmed = await obs.stopBroadcast(confirmPollSeconds: confirmPollSeconds,
                                                    maxConfirmPolls: maxConfirmPolls)
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
            // Bring-up abandoned: invalidate it and return to idle (any stream a
            // stale attempt manages to start is undone by its stale-completion cleanup).
            broadcastGeneration += 1
            goLiveTask?.cancel(); goLiveTask = nil
            healthPollTask?.cancel(); healthPollTask = nil
            streamHealth = nil
            broadcastState = .idle
        case .idle, .stopUnconfirmed:
            break
        }
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
                streamHealth = health
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
