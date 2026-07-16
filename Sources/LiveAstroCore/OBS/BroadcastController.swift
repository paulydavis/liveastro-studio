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

    /// `endingSession` (review5 P2): End Session was clicked while live — the stream DELIBERATELY
    /// stays up until replay generation finishes (review4 P2), so the UI must not claim idle
    /// (which offered a Go Live that the deferred stop would then kill, hid End Broadcast, and
    /// hid health while actually streaming). Health polling keeps reporting truth in this state;
    /// `stopBroadcastAfterSessionEnd()` advances it to `.stopping` → `.idle`.
    public enum BroadcastState: Equatable { case idle, connecting, live, endingSession, stopping }
    public private(set) var broadcastState: BroadcastState = .idle
    public private(set) var streamHealth: StreamHealth?
    private var healthPollTask: Task<Void, Never>?
    private var goLiveTask: Task<Void, Never>?

    // MARK: Timing knobs (injectable for tests — production uses the defaults)

    /// Delay between connect retries while waiting for a just-launched OBS.
    var launchRetryDelaySeconds: Double = 2
    /// Total budget for the post-launch connect retry loop.
    var launchRetryBudgetSeconds: Double = 20
    /// Confirm-poll pacing forwarded to `OBSController.startBroadcast`.
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
            // stopBroadcastAfterSessionEnd() performs the actual stop after the replay.
            goLiveTask?.cancel()
            goLiveTask = nil
            broadcastState = .endingSession
        case .connecting:
            // Nothing live yet — cancel the bring-up and return to idle immediately. The
            // deferred stopBroadcastAfterSessionEnd() is just a safety net here.
            goLiveTask?.cancel()
            goLiveTask = nil
            healthPollTask?.cancel()
            healthPollTask = nil
            streamHealth = nil
            broadcastState = .idle
        case .idle, .endingSession, .stopping:
            break
        }
    }

    /// Session end, DEFERRED part: the deliberate end-of-session stop — the
    /// ONLY place we ask OBS to stop the stream. Called by the app strictly
    /// AFTER the pipeline's end()/replay generation returned or threw (a
    /// replay failure still stops the stream). App quit / abort / crash paths
    /// never call this — an accidental quit must never kill the broadcast.
    public func stopBroadcastAfterSessionEnd() {
        // Mirror endBroadcast()'s sequencing: transition synchronously so the UI shows
        // "Stopping…" the moment the replay is done, then await the stops and settle to idle.
        // When nothing was live (.idle after a .connecting cancel, or no broadcast at all) the
        // stops below are just the safety net — no state churn.
        let deliberateStop = broadcastState == .endingSession
        if deliberateStop { broadcastState = .stopping }
        Task { [weak self] in
            guard let self else { return }
            await self.obs.stopStream()
            await self.obs.setRecording(false)
            if deliberateStop {
                self.healthPollTask?.cancel()
                self.healthPollTask = nil
                self.streamHealth = nil
                self.broadcastState = .idle
            }
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
        broadcastState = .connecting
        goLiveTask = Task { @MainActor in
            let connected = await connectOBS()
            guard connected else {
                deps.presentError("OBS not reachable — is it installed and running?")
                broadcastState = .idle; return
            }
            let scene = stackSceneName.isEmpty ? nil : stackSceneName
            let live = await obs.startBroadcast(scene: scene,
                                                confirmPollSeconds: confirmPollSeconds,
                                                maxConfirmPolls: maxConfirmPolls)
            // The user may have hit End Broadcast / End Session while we were
            // connecting. If so, don't transition to .live — instead undo the
            // broadcast we just started so nothing keeps running behind their back.
            guard broadcastState == .connecting else {
                if live { await obs.stopBroadcast() }
                return
            }
            if live {
                broadcastState = .live
                startHealthPoll()
            } else {
                deps.presentError("OBS started but the stream didn't go live — check OBS ▸ Settings ▸ Stream (YouTube server + key).")
                broadcastState = .idle
            }
        }
    }

    public func endBroadcast() {
        guard broadcastState == .live || broadcastState == .connecting else { return }
        broadcastState = .stopping
        goLiveTask?.cancel(); goLiveTask = nil
        healthPollTask?.cancel(); healthPollTask = nil
        Task { @MainActor in
            await obs.stopBroadcast()
            streamHealth = nil
            broadcastState = .idle
        }
    }

    private func startHealthPoll() {
        healthPollTask?.cancel()
        healthPollTask = Task { @MainActor in
            // Poll through .endingSession too (review5 P2): the stream is deliberately still
            // live while the replay renders, so health keeps reporting truth until the stop.
            while !Task.isCancelled && (broadcastState == .live || broadcastState == .endingSession) {
                streamHealth = await obs.streamStatus()
                try? await Task.sleep(nanoseconds: UInt64(healthPollIntervalSeconds * 1_000_000_000))
            }
        }
    }

    // MARK: - Scene automation

    /// Start the 15 s stall-check timer. Active only while a session runs AND
    /// scene automation is enabled. Seeds a StallDetector from the sub-exposure.
    private func startSceneAutomation(subExposureSeconds: Double) {
        stopSceneAutomation()   // idempotent
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
        sceneTimer?.invalidate()
        sceneTimer = nil
        stall = nil
        showingScopeDueToStall = false
        manualOverride = false
        lastAutomationScene = nil
    }

    /// Fires every 15 s (timer), internal so tests can drive a tick with a
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
            Task { [weak self] in await self?.setSceneViaAutomation(scene) }
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
                Task { [weak self] in await self?.setSceneViaAutomation(scene) }
            }
        }
    }

    /// Set a scene *as automation*, remembering the name so a later
    /// CurrentProgramSceneChanged we caused isn't mistaken for a manual change.
    private func setSceneViaAutomation(_ name: String) async {
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
