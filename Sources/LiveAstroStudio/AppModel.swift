import SwiftUI
import LiveAstroCore

/// Minimal thread-safe counter for pipeline callbacks that fire off the main actor.
private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@Observable
@MainActor
final class AppModel {

    enum SourceMode: String, CaseIterable {
        case stackerOutput = "Stacker output (Siril)"
        case nativeStack   = "Raw subs (native stacking)"

        /// Typical capture filename prefix for the mode (Siril writes live_stack_*,
        /// capture software writes Light_*).
        var defaultFileNamePrefix: String {
            switch self {
            case .stackerOutput: return "live_stack"
            case .nativeStack:   return "Light_"
            }
        }
    }

    // Session profile draft (bound to the control form)
    var targetName = ""
    var telescope = ""
    var camera = ""
    var mount = ""
    var filter = ""
    var locationLabel = ""
    var bortleText = ""
    var subExposureText = "60"
    var notes = ""

    var fileNamePrefix = SourceMode.stackerOutput.defaultFileNamePrefix
    var neutralizeBackground = false
    var watchFolder: URL?
    var sourceMode: SourceMode = .stackerOutput {
        didSet {
            // Swap the prefix default with the mode, but never clobber a user-edited value.
            guard sourceMode != oldValue else { return }
            if fileNamePrefix == oldValue.defaultFileNamePrefix {
                fileNamePrefix = sourceMode.defaultFileNamePrefix
            }
        }
    }
    var isRunning = false
    var isImporting = false
    var acceptedCount = 0
    var rejectedCount = 0
    var latestImage: CGImage?
    var latestRecord: SnapshotRecord?
    var sessionStart: Date?
    var sessionEnd: Date?
    var log: [String] = []
    var replayURL: URL?
    var isGeneratingReplay = false
    var errorMessage: String?

    private var pipeline: SessionPipeline?

    var profile: SessionProfile {
        SessionProfile(targetName: targetName, telescope: telescope, camera: camera,
                       mount: mount, filter: filter, locationLabel: locationLabel,
                       bortle: Int(bortleText), subExposureSeconds: Double(subExposureText) ?? 60,
                       notes: notes)
    }

    var integrationCaption: String {
        guard let rec = latestRecord else { return "waiting for first stack…" }
        return IntegrationFormat.caption(seconds: rec.estimatedIntegrationSeconds,
                                         frames: rec.index,
                                         subSeconds: profile.subExposureSeconds)
    }

    func startSession() {
        guard !isRunning else { return }
        guard !isImporting else { errorMessage = "Finish the import before starting a session."; return }
        guard let folder = watchFolder else { errorMessage = "Pick a watch folder first."; return }
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveAstro", isDirectory: true)

        let p: SessionPipeline
        switch sourceMode {
        case .stackerOutput:
            p = SessionPipeline(watchFolder: folder, profile: profile, rootDirectory: root,
                               fileNamePrefix: fileNamePrefix.isEmpty ? nil : fileNamePrefix,
                               neutralizeBackground: neutralizeBackground)
        case .nativeStack:
            let source = FolderFrameSource(folder: folder, mode: .live,
                                            fileNamePrefix: fileNamePrefix.isEmpty ? nil : fileNamePrefix)
            let engine = StackEngine()
            p = SessionPipeline(nativeSource: source, engine: engine, profile: profile,
                               rootDirectory: root, neutralizeBackground: neutralizeBackground)
        }

        acceptedCount = 0
        rejectedCount = 0

        p.onUpdate = { [weak self] image, record in
            Task { @MainActor in
                self?.latestImage = image
                self?.latestRecord = record
                if self?.sourceMode == .nativeStack { self?.acceptedCount += 1 }
                self?.log.append("✓ update \(record.index) — \(record.snapshotFile)")
            }
        }
        p.onRejected = { [weak self] reason, name in
            Task { @MainActor in
                self?.rejectedCount += 1
                self?.log.append("✗ rejected \(name): \(reason)")
            }
        }
        p.onLog = { [weak self] message in
            Task { @MainActor in self?.log.append("⚠ \(message)") }
        }
        do {
            try p.start()
            pipeline = p
            isRunning = true
            sessionStart = Date()
            sessionEnd = nil
            replayURL = nil
            log.append("Session started — watching \(folder.path)")
        } catch {
            errorMessage = "Start failed: \(error.localizedDescription)"
        }
    }

    /// Reseeds the stacking engine reference frame (native mode only).
    func reseedReference() {
        guard isRunning && sourceMode == .nativeStack && !isGeneratingReplay else { return }
        pipeline?.reseed()
        log.append("reference reseeded")
    }

    /// Imports raw FITS subs from `folder` as a one-shot batch.
    /// Runs start()+end() off the main thread; end() drains the finite import stream.
    func importSubs(from folder: URL) {
        guard !isRunning else { errorMessage = "End the session before importing."; return }
        guard !isImporting else { return }
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveAstro", isDirectory: true)
        let source = FolderFrameSource(folder: folder, mode: .importOnce,
                                        fileNamePrefix: fileNamePrefix.isEmpty ? nil : fileNamePrefix)
        let engine = StackEngine()
        let importPipeline = SessionPipeline(nativeSource: source, engine: engine, profile: profile,
                                              rootDirectory: root, neutralizeBackground: neutralizeBackground)
        // Counts every frame the source produced (accepted or rejected); it stays at zero
        // only when nothing in the folder matched the prefix at all. The pipeline callbacks
        // fire synchronously on the consume task, which end() drains before returning.
        let matchedFrames = AtomicCounter()
        importPipeline.onUpdate = { [weak self] image, record in
            matchedFrames.increment()
            Task { @MainActor in
                self?.latestImage = image
                self?.latestRecord = record
                self?.log.append("✓ update \(record.index) — \(record.snapshotFile)")
            }
        }
        importPipeline.onRejected = { [weak self] reason, name in
            matchedFrames.increment()
            Task { @MainActor in self?.log.append("✗ rejected \(name): \(reason)") }
        }
        importPipeline.onLog = { [weak self] message in
            Task { @MainActor in self?.log.append("⚠ \(message)") }
        }
        isImporting = true
        log.append("Importing subs from \(folder.path)…")
        let prefix = fileNamePrefix
        Task.detached { [weak self] in
            func zeroMatchMessage() -> String {
                prefix.isEmpty
                    ? "No .fit files found in the chosen folder."
                    : "No .fit files matching prefix '\(prefix)' in the chosen folder."
            }
            do {
                try importPipeline.start()
                let url = try importPipeline.end()
                await MainActor.run {
                    if matchedFrames.value == 0 {
                        self?.errorMessage = zeroMatchMessage()
                    } else {
                        self?.replayURL = url
                        self?.log.append("Import complete. Replay: \(url.path)")
                    }
                    self?.isImporting = false
                }
            } catch {
                await MainActor.run {
                    // A zero-match import may also surface as a downstream failure
                    // (nothing to render) — prefer the actionable message.
                    self?.errorMessage = matchedFrames.value == 0
                        ? zeroMatchMessage()
                        : "Import failed: \(error)"
                    self?.isImporting = false
                }
            }
        }
    }

    func regenerateReplay(sessionDirectory: URL) {
        guard !isRunning && !isGeneratingReplay else { return }
        isGeneratingReplay = true
        log.append("Regenerating replay for \(sessionDirectory.lastPathComponent)…")
        Task.detached { [weak self] in
            do {
                let url = try ReplayService.regenerate(sessionDirectory: sessionDirectory)
                await MainActor.run {
                    self?.replayURL = url
                    self?.log.append("Replay ready: \(url.lastPathComponent)")
                }
            } catch {
                await MainActor.run { self?.errorMessage = "Regenerate failed: \(error)" }
            }
            await MainActor.run { self?.isGeneratingReplay = false }
        }
    }

    func endSession() {
        guard let p = pipeline else { return }
        guard !isGeneratingReplay else { return }
        isGeneratingReplay = true
        log.append("Ending session — generating replay…")
        Task.detached { [weak self] in
            do {
                let url = try p.end()
                await MainActor.run {
                    self?.replayURL = url
                    self?.log.append("Replay ready: \(url.lastPathComponent)")
                }
            } catch {
                await MainActor.run { self?.errorMessage = "Replay failed: \(error)" }
            }
            await MainActor.run {
                self?.isRunning = false
                self?.isGeneratingReplay = false
                self?.pipeline = nil
                self?.sessionEnd = Date()
            }
        }
    }
}
