import SwiftUI
import AppKit
import LiveAstroCore

/// Owns OBS connection, broadcast orchestration, and stall-driven scene
/// automation — the self-contained cluster extracted verbatim from `AppModel`
/// (T1 of the AppModel decomposition). Holds no `AppModel` reference: all
/// cross-cutting UI writes (log, error, session-running gate) flow through the
/// injected `AppSurface`. `AppModel` drives the three session hooks
/// (`sessionDidStart` / `sessionDidEnd` / `frameAccepted`) at the exact points
/// the moved logic used to run inline.
@MainActor
@Observable
final class BroadcastController {

    private let surface: AppSurface

    /// High-level OBS controller (Foundation/Combine, UI-free). Owned here; the
    /// app target does the AppKit-flavored choreography (launch, timers).
    let obs = OBSController()

    // OBS connection config (bound to the settings form).
    var obsHost = "localhost"
    var obsPort = 4455
    var obsPassword = ""
    /// Launch OBS via NSWorkspace if the first connect attempt fails.
    var obsAutoLaunch = true
    /// Also start OBS recording when the stream comes up.
    var obsRecord = false
    /// Master switch for stall-driven scene automation.
    var sceneAutomationOn = false
    /// Scene shown while stacking makes progress (the "hero" view).
    var stackSceneName = ""
    /// Scene shown when imaging stalls (e.g. a live scope/finder view).
    var scopeSceneName = ""

    // MARK: Broadcast state
    enum BroadcastState: Equatable { case idle, connecting, live, stopping }
    var broadcastState: BroadcastState = .idle
    var streamHealth: StreamHealth?
    private var healthPollTask: Task<Void, Never>?
    private var goLiveTask: Task<Void, Never>?

    /// bundle id used to resolve + launch OBS.
    private static let obsBundleID = "com.obsproject.obs-studio"

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

    init(surface: AppSurface) {
        self.surface = surface
        // Route OBS diagnostics into the session log. onLog fires on the main
        // actor (OBSController is @MainActor), so appending is safe.
        obs.onLog = { message in
            MainActor.assumeIsolated { surface.log("OBS: \(message)") }
        }
    }

    // MARK: - Session hooks (called by AppModel where the logic fired inline)

    /// Session start: begin scene automation. `subExposureSeconds` comes from the
    /// session profile (owned by AppModel) — passed in so the controller stays
    /// reference-free. Was the `startSceneAutomation()` call site in startSession.
    func sessionDidStart(subExposureSeconds: Double) {
        startSceneAutomation(subExposureSeconds: subExposureSeconds)
    }

    /// Session end: stop scene automation, reset any live broadcast state, and
    /// issue the deliberate end-of-session OBS stop. Was the stopSceneAutomation
    /// call + the broadcast-state reset + the deferred stopStream block in
    /// endSession.
    func sessionDidEnd() {
        // Scene automation stops immediately; the OBS stream/record stop is
        // deferred until AFTER the pipeline end/replay flow below.
        stopSceneAutomation()

        // If a broadcast is live, reset its state so the UI returns to idle.
        // The deliberate stopStream below acts as the safety net.
        if broadcastState == .live || broadcastState == .connecting {
            goLiveTask?.cancel()
            goLiveTask = nil
            healthPollTask?.cancel()
            healthPollTask = nil
            streamHealth = nil
            broadcastState = .idle
        }

        // Deliberate end-of-session stop — the ONLY place we ask OBS to stop the
        // stream. App quit / abort paths never call this. Runs after the pipeline
        // end() is kicked off above; ordering vs. replay generation is immaterial.
        Task { [weak self] in
            guard let self else { return }
            await self.obs.stopStream()
            await self.obs.setRecording(false)
        }
    }

    /// Per-accepted-frame hook. Was `onFrameAccepted()`'s scene-automation part.
    func frameAccepted() {
        onFrameAccepted()
    }

    // MARK: - OBS bring-up

    /// Connect to OBS, launching it if needed. Returns whether connected.
    /// Does NOT start any stream — broadcasting is deliberate (goLive()).
    private func connectOBS() async -> Bool {
        guard obs.state == .disconnected else { return true }  // already connected

        var connected = await obs.connect(host: obsHost, port: obsPort,
                                          password: obsPassword.isEmpty ? nil : obsPassword)

        if !connected && obsAutoLaunch {
            launchOBS()
            // Retry connect every 2 s until success or a 20 s budget elapses.
            let deadline = Date().addingTimeInterval(20)
            while !connected && Date() < deadline && !Task.isCancelled {
                // Cancellation-aware sleep: a cancel throws here, which we treat
                // as "stop retrying" — return false.
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return false }
                if obs.state == .disconnected {
                    connected = await obs.connect(host: obsHost, port: obsPort,
                                                 password: obsPassword.isEmpty ? nil : obsPassword)
                } else {
                    connected = obs.state != .disconnected
                }
            }
        }

        if !connected {
            surface.log("OBS: not connected")
        }
        return connected
    }

    // MARK: - Broadcast orchestration

    func goLive() {
        guard broadcastState == .idle else { return }
        broadcastState = .connecting
        goLiveTask = Task { @MainActor in
            let connected = await connectOBS()
            guard connected else {
                surface.presentError("OBS not reachable — is it installed and running?")
                broadcastState = .idle; return
            }
            let scene = stackSceneName.isEmpty ? nil : stackSceneName
            let live = await obs.startBroadcast(scene: scene)
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
                surface.presentError("OBS started but the stream didn't go live — check OBS ▸ Settings ▸ Stream (YouTube server + key).")
                broadcastState = .idle
            }
        }
    }

    func endBroadcast() {
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
            while !Task.isCancelled && broadcastState == .live {
                streamHealth = await obs.streamStatus()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// Launch OBS via NSWorkspace by bundle id; fall back to `open -a OBS`.
    /// NSWorkspace/AppKit is app-target-only (never in LiveAstroCore).
    private func launchOBS() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.obsBundleID) {
            surface.log("OBS: launching \(url.lastPathComponent)…")
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, error in
                if let error {
                    Task { @MainActor in self?.surface.log("OBS: launch failed: \(error.localizedDescription)") }
                }
            }
        } else {
            // Bundle id not resolvable — try the command-line fallback, and if
            // that isn't available either, just skip the launch and log.
            surface.log("OBS: app not found by bundle id — trying `open -a OBS`")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "OBS"]
            do {
                try process.run()
            } catch {
                surface.log("OBS: could not launch OBS (\(error.localizedDescription)) — skipping")
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

    /// Fires every 15 s. If imaging has stalled and we aren't already showing the
    /// scope scene, switch to it once. Honors the manual-override flag.
    private func sceneTick() {
        guard sceneAutomationOn, surface.isSessionRunning(), let detector = stall else { return }

        // Detect an operator-initiated program-scene change: if the current OBS
        // scene isn't the one automation last set (and isn't nil/unknown),
        // suspend automation until the next stall/resume boundary.
        detectManualOverride()

        let stalledNow = detector.isStalled(at: Date())
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
            surface.log("OBS: manual scene change detected (\(current)) — automation paused until next stall/resume")
        }
    }
}
