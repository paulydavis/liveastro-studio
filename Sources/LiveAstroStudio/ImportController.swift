import SwiftUI
import AppKit
import LiveAstroCore

/// Owns the import + post-processing cluster — one-shot batch import of raw FITS
/// subs, its progress/cancel state, and the two "operate on a finished session
/// directory" actions (replay regeneration, GraXpert master processing) —
/// extracted verbatim from `AppModel` (T3 of the AppModel decomposition). Holds
/// no `AppModel` reference: all cross-cutting UI writes (log, error, counts,
/// result publication) and the reads the moved bodies need (stacker engine,
/// calibration, draft fields, profile, root, callback wiring) flow through the
/// injected `AppSurface`. `replayURL`/`lastSessionDirectory` stay on `AppModel`
/// (session-shared with `endSession`); this controller publishes them via
/// `surface.setReplayURL` / `surface.setLastSessionDirectory`.
@MainActor
@Observable
final class ImportController {

    private let surface: AppSurface

    /// True while a one-shot batch import is draining. Gates the start*Live paths
    /// (read back through `AppSurface.isImporting`) and `startSession`; drives the
    /// import progress bar in the footer.
    var isImporting = false
    /// True while GraXpert is post-processing a master (processMaster).
    var isProcessing = false
    /// True while a replay render is in flight — set by both `regenerateReplay`
    /// here and `AppModel.endSession()`, which reads/writes it through this
    /// property since the two share the same "a replay is rendering" gate.
    var isGeneratingReplay = false

    /// Import progress counters (frames processed / total in the chosen folder).
    var importProcessed = 0
    var importTotal = 0

    /// The active one-shot import pipeline (nil unless an import is draining).
    private var importPipeline: SessionPipeline?
    private var importPrepareGeneration = 0

    init(surface: AppSurface) {
        self.surface = surface
    }

    /// Imports raw FITS subs from `folder` as a one-shot batch.
    /// Runs start()+end() off the main thread; end() drains the finite import stream.
    /// Not unit-testable: needs a detached task and a real folder; the
    /// zero-match path is covered via noMatchMessage(prefix:).
    func importSubs(from folder: URL) {
        surface.saveSettings?()
        guard !surface.isSessionRunning() else { surface.presentError("End the session before importing."); return }
        guard !isImporting else { return }
        let prefix = surface.currentFileNamePrefix?() ?? ""
        importProcessed = 0
        importTotal = 0
        isImporting = true
        importPrepareGeneration += 1
        let generation = importPrepareGeneration
        surface.log("Preparing import from \(folder.path)…")

        Task.detached { [weak self, folder, prefix] in
            guard let self else { return }
            let meta = LiveSourceMetadata.newestFITSMetadata(inFolder: folder)
            await MainActor.run {
                self.beginImport(from: folder, meta: meta, prefix: prefix, generation: generation)
            }
        }
    }

    private func beginImport(from folder: URL,
                             meta: (object: String?, exposureSeconds: Double?, fileExtension: String)?,
                             prefix: String,
                             generation: Int) {
        guard generation == importPrepareGeneration, isImporting else { return }
        guard !surface.isSessionRunning() else {
            surface.presentError("End the session before importing.")
            isImporting = false
            return
        }
        // Reflect the imported subs' actual target/exposure in the profile + Live
        // overlay instead of showing stale form values from a prior session (matches
        // the live/auto-detect paths, which fill these from the newest sub's header).
        if let meta {
            var detected = DetectedProfile()
            if let object = meta.object, !object.isEmpty { detected.targetName = object }
            if let exp = meta.exposureSeconds, exp > 0 { detected.subExposureText = String(format: "%g", exp) }
            surface.applyDetectedProfile?(detected)
            surface.saveSettings?()
        }
        let source = FolderFrameSource(folder: folder, mode: .importOnce,
                                        fileNamePrefix: prefix.isEmpty ? nil : prefix)
        let engine = surface.makeStackEngine!()
        let calibration = surface.currentCalibration!()
        let (importCalibrator, importCalWarnings) = CalibrationLoader.makeCalibrator(
            dark: calibration.darkPath.map { URL(fileURLWithPath: $0) },
            flat: calibration.flatPath.map { URL(fileURLWithPath: $0) })
        importCalWarnings.forEach { surface.log("⚠ \($0)") }
        CalibrationStore.save(calibration, to: .standard)
        let importPipeline = SessionPipeline(nativeSource: source, engine: engine, profile: surface.currentProfile!(),
                                              rootDirectory: surface.currentLiveAstroRoot!(),
                                              neutralizeBackground: surface.currentNeutralizeBackground!(),
                                              calibrator: importCalibrator)
        importPipeline.displayAdjustments = surface.currentDisplayAdjustments?() ?? .neutral
        importPipeline.onImportProgress = { [weak self] processed, total, accepted, rejected in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.importProcessed = processed; self?.importTotal = total
                    self?.surface.setAcceptedRejectedCounts?(accepted, rejected)
                }
            }
        }
        self.importPipeline = importPipeline
        // Counts every frame the source produced (accepted or rejected); it stays at zero
        // only when nothing in the folder matched the prefix at all. The pipeline callbacks
        // fire synchronously on the consume task, which end() drains before returning.
        let matchedFrames = AtomicCounter()
        surface.wireImportCallbacks?(importPipeline, { matchedFrames.increment() })
        surface.log("Importing subs from \(folder.path)…")
        Task.detached { [weak self] in
            guard let self else { return }   // Swift 6: nested closures need a let, not a weak var
            do {
                try importPipeline.start()
                let url = try importPipeline.end()
                await MainActor.run {
                    if matchedFrames.value == 0 {
                        self.surface.presentError(ImportController.noMatchMessage(prefix: prefix))
                    } else {
                        self.surface.setReplayURL?(url)
                        self.surface.setLastSessionDirectory?(url.deletingLastPathComponent())
                        self.surface.log("Import complete. Replay: \(url.path)")
                    }
                    self.isImporting = false
                    self.importPipeline = nil
                }
            } catch {
                await MainActor.run {
                    // A zero-match import may also surface as a downstream failure
                    // (nothing to render) — prefer the actionable message.
                    if let pipelineError = error as? SessionPipelineError, pipelineError == .shutdownTimeout {
                        self.surface.presentError("Import failed: the import stalled while reading frames. The session was not finalized; try again from a faster or more stable disk/share.")
                    } else {
                        self.surface.presentError(matchedFrames.value == 0
                            ? ImportController.noMatchMessage(prefix: prefix)
                            : "Import failed: \(error)")
                    }
                    self.isImporting = false
                    self.importPipeline = nil
                }
            }
        }
    }

    func cancelImport() {
        if importPipeline == nil {
            importPrepareGeneration += 1
            isImporting = false
            return
        }
        importPipeline?.cancelImport()
        importPipeline = nil
    }

    /// User-facing message for an import that matched zero files.
    private nonisolated static func noMatchMessage(prefix: String) -> String {
        prefix.isEmpty
            ? "No .fit files found in the chosen folder."
            : "No .fit files matching prefix '\(prefix)' in the chosen folder."
    }

    func regenerateReplay(sessionDirectory: URL) {
        guard !surface.isSessionRunning() && !isGeneratingReplay else { return }
        isGeneratingReplay = true
        surface.log("Regenerating replay for \(sessionDirectory.lastPathComponent)…")
        Task.detached { [weak self] in
            guard let self else { return }   // Swift 6: nested closures need a let, not a weak var
            do {
                let url = try ReplayService.regenerate(sessionDirectory: sessionDirectory)
                await MainActor.run {
                    self.surface.setReplayURL?(url)
                    self.surface.log("Replay ready: \(url.lastPathComponent)")
                }
            } catch {
                await MainActor.run { self.surface.presentError("Regenerate failed: \(error)") }
            }
            await MainActor.run { self.isGeneratingReplay = false }
        }
    }

    func processMaster(sessionDirectory: URL) {
        guard !isProcessing, !isImporting, !surface.isSessionRunning() else { return }
        guard surface.currentProcessorBackend?() == .graxpert, let exe = GraXpertProcessor.defaultExecutable() else {
            surface.presentError("GraXpert not found — install it from graxpert.com"); return
        }
        let master = sessionDirectory.appendingPathComponent("master.fit")
        guard FileManager.default.fileExists(atPath: master.path) else {
            surface.presentError("No master.fit in this session — post-processing needs a natively-stacked master (Raw subs mode).")
            return
        }
        isProcessing = true
        surface.log("Processing master with GraXpert…")
        Task.detached { [weak self] in
            guard let self else { return }   // Swift 6: nested closures need a let, not a weak var
            do {
                let out = sessionDirectory.appendingPathComponent("master_processed.fit")
                let proc = GraXpertProcessor(executable: exe)
                // process() runs synchronously within this task, so the strong `self`
                // let is safely captured by the progress callback for its duration.
                let produced = try proc.process(masterURL: master, outputURL: out) { m in
                    Task { @MainActor in self.surface.log(m) }
                }
                await MainActor.run {
                    self.isProcessing = false
                    self.surface.log("Processed → \(produced.lastPathComponent)")
                }
            } catch {
                await MainActor.run {
                    self.isProcessing = false
                    self.surface.presentError("Processing failed: \(error)")
                }
            }
        }
    }
}
