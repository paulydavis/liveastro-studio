import SwiftUI
import AppKit
import LiveAstroCore

/// Owns the live-source orchestration cluster — the frame relay, its retention
/// policy + auto-prune, and the three auto-detect/configure paths (watch-folder,
/// Seestar, ASIAIR) — extracted verbatim from `AppModel` (T2 of the AppModel
/// decomposition). Holds no `AppModel` reference: all cross-cutting UI writes
/// (log, error, session start/save, profile draft, zoom/tab) flow through the
/// injected `AppSurface`. Each detect path's old inline profile-field writes
/// become one `surface.applyDetectedProfile(...)` call, and `startSession` /
/// `saveSettings` fire at the exact points the moved logic used to run inline.
@MainActor
@Observable
final class LiveSourceController {

    private let surface: AppSurface

    /// True while an auto-detect path is scanning for a share off the main
    /// thread. Gates the start*Live entry points and disables their buttons.
    var isDetecting = false

    /// How long relay sessions are kept before auto-prune (0 = off). Persisted
    /// via `SessionSettings.relayRetentionDays` (blob key unchanged); AppModel's
    /// `currentSettings()`/`loadSettings()` read/write this property.
    var relayRetentionDays = 7

    /// The active frame relay for a live session (nil unless a relay-backed
    /// session is running). Started by a configure path, stopped on session end
    /// / app terminate.
    private var frameRelay: FrameRelay?

    init(surface: AppSurface) {
        self.surface = surface
    }

    /// Stop the frame relay. Called by `AppModel.endSession()` (before the
    /// pipeline drains) and by the willTerminate observer. Idempotent.
    func stopRelay() {
        frameRelay?.stop()
        frameRelay = nil
    }

    /// Age-prune old relay sessions just before a new one is created (spec:
    /// relay auto-prune). `relayDir` is the incoming session — never pruned.
    private func pruneRelay(excluding relayDir: URL) {
        let relayRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("LiveAstro/relay", isDirectory: true)
        for r in RelayPruner.prune(root: relayRoot, olderThanDays: relayRetentionDays,
                                   excluding: relayDir) {
            let size = ByteCountFormatter.string(fromByteCount: r.bytes, countStyle: .file)
            surface.log("pruned relay \(r.name) (\(size))")
        }
    }

    func startWatchFolderLive(source: URL) {
        guard !surface.isSessionRunning(), !surface.isImporting(), !isDetecting else { return }
        surface.resetZoomPan?()
        isDetecting = true
        surface.log("Reading subs in \(source.lastPathComponent)…")
        Task.detached { [weak self] in
            guard let self else { return }   // Swift 6: nested closures need a let, not a weak var
            let meta = LiveSourceMetadata.newestFITSMetadata(inFolder: source)   // SMB header read, off main
            await MainActor.run {
                self.isDetecting = false
                self.configureAndStartWatchFolder(source: source, meta: meta)
            }
        }
    }

    private func configureAndStartWatchFolder(source: URL,
                                              meta: (object: String?, exposureSeconds: Double?, fileExtension: String)?) {
        var profile = DetectedProfile(sourceMode: .nativeStack, neutralizeBackground: true)
        if let object = meta?.object, !object.isEmpty { profile.targetName = object }        // else keep form value
        if let exp = meta?.exposureSeconds, exp > 0 { profile.subExposureText = String(format: "%g", exp) }
        surface.applyDetectedProfile?(profile)
        let currentTarget = surface.currentTargetName?() ?? ""
        let target = currentTarget.isEmpty ? "Live" : currentTarget
        let glob = "*.\(meta?.fileExtension ?? "fit")"       // *.fit or *.fits per the folder's subs
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let relayDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("LiveAstro/relay/\(target)-\(df.string(from: Date()))", isDirectory: true)
        pruneRelay(excluding: relayDir)
        let relay = FrameRelay(source: source, destination: relayDir, glob: glob)
        relay.onLog = { [weak self] msg in Task { @MainActor in self?.surface.log(msg) } }
        do { try relay.start() } catch { surface.presentError("Relay failed to start: \(error)"); return }
        frameRelay = relay
        surface.applyDetectedProfile?(DetectedProfile(watchFolder: relayDir))
        surface.saveSettings?()
        surface.startSession?()
        if !surface.isSessionRunning() { frameRelay?.stop(); frameRelay = nil; return }
        surface.selectLiveTab?()
    }

    func startSeestarLive() {
        guard !surface.isSessionRunning(), !surface.isImporting(), !isDetecting else { return }
        surface.resetZoomPan?()
        isDetecting = true
        surface.log("Looking for Seestar share…")
        Task.detached { [weak self] in
            guard let self else { return }   // Swift 6: nested closures need a let, not a weak var
            let found = SeestarDetector.detect()      // SMB directory work, off the main thread
            await MainActor.run {
                self.isDetecting = false
                guard let found else {
                    self.surface.presentError("No Seestar share found. Mount it first: Finder → Go → Connect to Server → the Seestar's smb:// address, then try again.")
                    return
                }
                self.configureAndStartSeestar(found)
            }
        }
    }

    /// The on-main configure + start body (unchanged from the old synchronous
    /// startSeestarLive, from `found` onward). Runs on the main actor.
    private func configureAndStartSeestar(_ found: SeestarDetector.Found) {
        let exp = found.subExposure
        surface.applyDetectedProfile?(DetectedProfile(sourceMode: .nativeStack,
                                                      neutralizeBackground: true,
                                                      targetName: found.target,
                                                      subExposureText: String(format: "%g", exp ?? 10),
                                                      fileNamePrefix: "Light_"))
        let expToken = exp.map { String(format: "%.1f", $0) }
        let glob = expToken.map { "Light_*_\($0)s_*.fit" } ?? "Light_*.fit"
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let relayDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("LiveAstro/relay/\(found.target)-\(df.string(from: Date()))\(expToken.map { "-\($0)s" } ?? "")",
                                    isDirectory: true)
        pruneRelay(excluding: relayDir)
        let relay = FrameRelay(source: found.subDir, destination: relayDir, glob: glob)
        relay.onLog = { [weak self] msg in
            Task { @MainActor in self?.surface.log(msg) }
        }
        do { try relay.start() } catch { surface.presentError("Relay failed to start: \(error)"); return }
        frameRelay = relay
        surface.applyDetectedProfile?(DetectedProfile(watchFolder: relayDir))
        surface.saveSettings?()
        surface.startSession?()
        if !surface.isSessionRunning() {
            frameRelay?.stop(); frameRelay = nil
            return
        }
        surface.selectLiveTab?()
    }

    func startASIAIRLive() {
        guard !surface.isSessionRunning(), !surface.isImporting(), !isDetecting else { return }
        surface.resetZoomPan?()
        isDetecting = true
        surface.log("Looking for ASIAIR share…")
        Task.detached { [weak self] in
            guard let self else { return }   // Swift 6: nested closures need a let, not a weak var
            let found = ASIAIRDetector.detect()       // SMB directory work, off the main thread
            await MainActor.run {
                self.isDetecting = false
                guard let found else {
                    self.surface.presentError("No ASIAIR share found. In the ASIAIR app: Settings → Network Share → Enable. Then on the Mac: Finder → Go → Connect to Server → smb://asiair.local, and try again.")
                    return
                }
                self.configureAndStartASIAIR(found)
            }
        }
    }

    /// On-main configure + start for an auto-detected ASIAIR target folder.
    /// Unlike the Seestar path, the relay glob is `*.<ext>` (the ASIAIR target
    /// folder is already target-scoped) and `fileNamePrefix` is cleared: the
    /// relay dir is glob-filtered AND session-scoped, so the native stacker must
    /// accept every FITS in it — ASIAIR light files are not guaranteed to start
    /// with "Light_" (the .nativeStack default prefix would otherwise drop them).
    private func configureAndStartASIAIR(_ found: ASIAIRDetector.Found) {
        surface.applyDetectedProfile?(DetectedProfile(sourceMode: .nativeStack,
                                                      neutralizeBackground: true,
                                                      targetName: found.target,
                                                      subExposureText: String(format: "%g", found.subExposure ?? 10),
                                                      fileNamePrefix: ""))     // accept-all: see doc comment above
        let glob = "*.\(found.subFileExtension)"
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let relayDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("LiveAstro/relay/\(found.target)-\(df.string(from: Date()))",
                                    isDirectory: true)
        pruneRelay(excluding: relayDir)
        let relay = FrameRelay(source: found.subDir, destination: relayDir, glob: glob)
        relay.onLog = { [weak self] msg in Task { @MainActor in self?.surface.log(msg) } }
        do { try relay.start() } catch { surface.presentError("Relay failed to start: \(error)"); return }
        frameRelay = relay
        surface.applyDetectedProfile?(DetectedProfile(watchFolder: relayDir))
        surface.saveSettings?()
        surface.startSession?()
        if !surface.isSessionRunning() { frameRelay?.stop(); frameRelay = nil; return }
        surface.selectLiveTab?()
    }
}
