import Foundation
import CoreGraphics

public enum SessionPipelineError: Error, Equatable {
    /// The frame-consuming task did not acknowledge shutdown within the drain deadline,
    /// even after cancellation. Finalizing would race a still-running consumer against the
    /// accumulator/snapshots, so end() throws instead of writing a corrupt master.
    case shutdownTimeout
}

/// Simple atomic boolean flag backed by NSLock (Foundation only).
final class NSLock_Flag {
    private let lock = NSLock(); private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// Glue: watcher → loader → stretch → broadcast callback + snapshot + manifest (spec §5.1).
/// Also supports native stacking mode: FrameSource → StackEngine → snapshot + manifest.
/// UI-free so the end-to-end test and the app share the same wiring.
public final class SessionPipeline {
    public let session: SessionManager
    public var onUpdate: ((CGImage, SnapshotRecord) -> Void)?
    public var onLog: ((String) -> Void)?
    /// Called for every frame the stack engine rejects (native mode only).
    public var onRejected: ((RejectionReason, String) -> Void)?
    /// Called after each frame is processed (native import mode only).
    public var onImportProgress: ((_ processed: Int, _ total: Int,
                                   _ accepted: Int, _ rejected: Int) -> Void)?
    private let cancelled = NSLock_Flag()
    private var processedCount = 0
    private var sourceMetadata: SourceMetadata?
    private var lastAutoReseedCount = 0

    private let adjLock = NSLock()
    private var _displayAdjustments = DisplayAdjustments.neutral
    /// Display-path adjustments. Read once per render; lock-guarded because the
    /// frame loop and the live re-render access it from different threads.
    public var displayAdjustments: DisplayAdjustments {
        get { adjLock.lock(); defer { adjLock.unlock() }; return _displayAdjustments }
        set { adjLock.lock(); _displayAdjustments = newValue; adjLock.unlock() }
    }

    private let watcher: StackFileWatcher?
    private var source: FrameSource?
    private var engine: StackEngine?
    private let profile: SessionProfile
    private let replaySettings: ReplaySettings
    private let maxKeyframes: Int
    private let neutralizeBackground: Bool
    private let calibrator: Calibrator?
    private var recorder: SnapshotRecorder?
    private var consumeTask: Task<Void, Never>?
    private let consumeDone = DispatchSemaphore(value: 0)
    /// Drain deadlines for end() (P1-3). Internal so tests can shrink them; production uses 10s/5s.
    var drainPrimaryTimeout: DispatchTimeInterval = .seconds(10)
    var drainGraceTimeout: DispatchTimeInterval = .seconds(5)

    /// Watcher mode: monitors a folder for new Siril stacks and processes each update.
    public init(watchFolder: URL, profile: SessionProfile, rootDirectory: URL,
                replaySettings: ReplaySettings = .init(),
                maxKeyframes: Int = FrameSelector.defaultMaxKeyframes,
                fileNamePrefix: String? = nil, neutralizeBackground: Bool = false) {
        self.watcher = StackFileWatcher(folder: watchFolder, fileNamePrefix: fileNamePrefix)
        self.source = nil
        self.engine = nil
        self.profile = profile
        self.session = SessionManager(rootDirectory: rootDirectory)
        self.replaySettings = replaySettings
        self.maxKeyframes = maxKeyframes
        self.neutralizeBackground = neutralizeBackground
        self.calibrator = nil
    }

    /// Native stacking mode: pulls raw frames from a FrameSource, stacks them with StackEngine,
    /// and records each accepted frame as a snapshot.
    public init(nativeSource: FrameSource, engine: StackEngine, profile: SessionProfile,
                rootDirectory: URL, replaySettings: ReplaySettings = .init(),
                maxKeyframes: Int = FrameSelector.defaultMaxKeyframes,
                neutralizeBackground: Bool = false, calibrator: Calibrator? = nil) {
        self.watcher = nil
        self.source = nativeSource
        self.engine = engine
        self.profile = profile
        self.session = SessionManager(rootDirectory: rootDirectory)
        self.replaySettings = replaySettings
        self.maxKeyframes = maxKeyframes
        self.neutralizeBackground = neutralizeBackground
        self.calibrator = calibrator
    }

    /// Reseeds the stacking engine, discarding the current reference frame (native mode only).
    public func reseed() { engine?.reseed() }

    /// Cancel an in-progress import: stops feeding new frames; end() finalizes
    /// whatever completed into a valid master.fit + replay (not a hard abort).
    public func cancelImport() { cancelled.set(); source?.stop() }

    /// Finalize one committed frame (import batch path): snapshot + progress.
    /// Called serially by BatchImporter in completion order.
    private func finalizeCommitted(index: Int, sourceName: String, timestamp: Date, metadata: SourceMetadata?, engine: StackEngine) {
        if sourceMetadata == nil, let m = metadata { sourceMetadata = m }
        processedCount += 1
        guard let mean = engine.currentStack() else { return }
        guard let recorder else { onLog?("recorder missing — frame dropped (\(sourceName))"); return }
        do {
            let cg = try displayCGImage(from: mean)
            let record = try recorder.save(
                cgImage: cg, linear: mean, sourceFile: sourceName,
                index: index, timestamp: timestamp,
                estimatedIntegrationSeconds: Double(engine.stackFrameCount) * profile.subExposureSeconds)
            try session.recordSnapshot(record)
            onUpdate?(cg, record)
        } catch {
            onLog?("Skipped frame (\(sourceName)): \(error)")
        }
        if let total = source?.totalCount {
            onImportProgress?(processedCount, total, engine.acceptedCount, engine.rejectedCount)
        }
    }

    private func finalizeRejected(sourceName: String, engine: StackEngine) {
        processedCount += 1
        onRejected?(.noTransform, sourceName)
        onLog?("Rejected \(sourceName)")
        if let total = source?.totalCount {
            onImportProgress?(processedCount, total, engine.acceptedCount, engine.rejectedCount)
        }
    }

    private func captureMetadataAndFinalize(committed c: BatchImporter.Committed, engine: StackEngine) {
        finalizeCommitted(index: c.index, sourceName: c.sourceName, timestamp: c.timestamp, metadata: c.metadata, engine: engine)
    }

    public func start() throws {
        let dir = try session.startSession(profile: profile)
        // Transactional startup (P2-3): if anything after session creation throws (e.g. the
        // source/watcher fails to start), roll back the just-created running session so a
        // retry is clean (not blocked by alreadyRunning) and no stray dir stays marked running.
        do {
            try startSources(dir: dir)
        } catch {
            rollbackStartedSession(dir: dir)
            throw error
        }
    }

    /// Roll back a session that startSession() just created but that failed to fully start.
    /// Ends it (so state leaves .running) and removes the just-created directory.
    private func rollbackStartedSession(dir: URL) {
        recorder = nil
        consumeTask?.cancel()
        consumeTask = nil
        try? session.endSession()                       // leave .running so a retry is clean
        try? FileManager.default.removeItem(at: dir)    // drop the orphan session dir
    }

    private func startSources(dir: URL) throws {
        recorder = SnapshotRecorder(sessionDirectory: dir)

        if let src = source, let eng = engine {
            // Native stacking mode
            calibrator?.onLog = { [weak self] in self?.onLog?($0) }
            // Forward folder-disappearance log events from the watcher inside a live FolderFrameSource.
            if let folderSrc = src as? FolderFrameSource {
                folderSrc.onLog = { [weak self] msg in self?.onLog?(msg) }
            }
            try src.start()
            let done = consumeDone
            if src.isFinite {
                // IMPORT: frame-per-core parallel batch.
                let cal = calibrator
                let importer = BatchImporter(engine: eng)
                consumeTask = Task.detached(priority: .userInitiated) { [weak self] in
                    await importer.run(
                        source: src,
                        prepare: { cal?.apply($0) ?? $0 },
                        onCommitted: { c in
                            self?.captureMetadataAndFinalize(committed: c, engine: eng)
                        },
                        onRejected: { name in self?.finalizeRejected(sourceName: name, engine: eng) },
                        isCancelled: { self?.cancelled.isSet ?? true })
                    done.signal()
                }
            } else {
                // LIVE: serial (frames trickle in).
                consumeTask = Task.detached(priority: .userInitiated) { [weak self] in
                    for await frame in src.frames { self?.handleNative(frame, engine: eng) }
                    done.signal()
                }
            }
        } else {
            // Watcher mode
            watcher?.onLog = { [weak self] msg in self?.onLog?(msg) }
            try watcher?.start()
            let done = consumeDone
            consumeTask = Task.detached(priority: .userInitiated) { [weak self] in
                guard let stream = self?.watcher?.updates else {
                    done.signal()
                    return
                }
                for await update in stream {
                    self?.handle(update)
                }
                done.signal()
            }
        }
    }

    /// Shared display pipeline: optional background neutralization, then stretch
    /// if still linear, then pack to CGImage.
    private func displayCGImage(from linear: AstroImage) throws -> CGImage {
        let adj = displayAdjustments                         // single locked read
        // DBE first, on linear data. When on, it removes the per-channel spatial
        // background, so skip the additive neutralize (keep multiplicative WB).
        let flattened = adj.backgroundExtraction
            ? BackgroundExtraction.flattenMultiscale(linear, scale: adj.bgScale, smoothest: adj.bgSmoothest)
            : linear
        let balanced: AstroImage
        if neutralizeBackground {
            balanced = adj.backgroundExtraction
                ? AutoStretch.neutralizeBackground(flattened)                              // multiplicative only
                : AutoStretch.neutralizeBackground(AutoStretch.neutralizeBackgroundAdditive(flattened))
        } else {
            balanced = flattened
        }
        let stretched = balanced.sourceIsLinear
            ? AutoStretch.stretch(balanced, blackPoint: adj.blackPoint, midtoneStrength: adj.midtoneStrength)
            : balanced
        let display = AutoStretch.applySaturation(stretched, adj.saturation)
        guard let cg = AutoStretch.makeCGImage(display) else {
            throw ImageLoaderError.decodeFailed("CGImage packing")
        }
        return cg
    }

    /// Re-render the current stack with the given adjustments (live slider feedback).
    /// Stores the adjustments so the next frame's snapshot matches, then renders
    /// engine.currentStack(). nil when there is no stack yet.
    public func renderCurrentDisplay(adjustments: DisplayAdjustments) -> CGImage? {
        displayAdjustments = adjustments
        guard let mean = engine?.currentStack() else { return nil }
        return try? displayCGImage(from: mean)
    }

    /// Processes one raw frame through the stack engine (native mode).
    private func handleNative(_ rawFrame: RawFrame, engine: StackEngine) {
        if cancelled.isSet { return }
        if sourceMetadata == nil, let m = rawFrame.metadata { sourceMetadata = m }
        let frame = calibrator?.apply(rawFrame) ?? rawFrame
        let outcome = engine.process(frame)
        if engine.autoReseedCount != lastAutoReseedCount {
            lastAutoReseedCount = engine.autoReseedCount
            onLog?("Auto-reseeded — the reference frame didn't match; re-seeding on the next good sub. (Earlier subs that couldn't register stay rejected.)")
        }
        processedCount += 1
        switch outcome {
        case .becameReference, .stacked:
            guard let mean = engine.currentStack() else { return }
            guard let recorder else {
                onLog?("recorder missing — frame dropped (\(frame.sourceName))")
                return
            }
            do {
                let cg = try displayCGImage(from: mean)
                // Pass the raw un-neutralized mean as linear: stats stay raw for v1.1 cloud gate.
                let record = try recorder.save(
                    cgImage: cg, linear: mean, sourceFile: frame.sourceName,
                    index: engine.acceptedCount, timestamp: frame.timestamp,
                    estimatedIntegrationSeconds: Double(engine.stackFrameCount) * profile.subExposureSeconds)
                try session.recordSnapshot(record)
                onUpdate?(cg, record)
            } catch {
                onLog?("Skipped frame (\(frame.sourceName)): \(error)")
            }
        case .rejected(let reason):
            onRejected?(reason, frame.sourceName)
            onLog?("Rejected \(frame.sourceName): \(reason)")
        }
        if let total = source?.totalCount {
            onImportProgress?(processedCount, total, engine.acceptedCount, engine.rejectedCount)
        }
    }

    private func handle(_ update: StackUpdate) {
        guard let recorder else {
            onLog?("recorder missing — frame dropped (\(update.url.lastPathComponent))")
            return
        }
        do {
            // Verified read (review5 item 1): the bytes decoded here are checked — on the ONE
            // descriptor they are read from — against the identity (dev, ino, size, mtime ns,
            // digest) the watcher validated on ITS pinned descriptor, so a file replaced between
            // the watcher's validation and this read is skipped, never parsed.
            let linear = try ImageLoader.load(url: update.url, expectedIdentity: update.identity)
            let cg = try displayCGImage(from: linear)
            let index = session.acceptedCount + 1
            let record = try recorder.save(
                cgImage: cg, linear: linear, sourceFile: update.url.lastPathComponent,
                index: index, timestamp: Date(),
                estimatedIntegrationSeconds: Double(index) * profile.subExposureSeconds)
            try session.recordSnapshot(record)
            onUpdate?(cg, record)
        } catch let mismatch as FileIdentityMismatchError {
            // A boundary failure may lose one frame, never the session; it appears honestly here.
            onLog?("file changed between validation and read — skipping \(mismatch.fileName)")
        } catch {
            // Spec §7: skip bad updates, keep the last good frame on the broadcast.
            onLog?("Skipped update (\(update.url.lastPathComponent)): \(error)")
        }
    }

    /// Crop the master to its covered region (a copy). Returns the image
    /// unchanged when coverage is unavailable, the rect is nil, the rect is the
    /// full frame, or the crop would remove more than ~40% of the area.
    private func cropMaster(_ image: AstroImage, coverage: [Float]?) -> AstroImage {
        guard let cov = coverage,
              let rect = CoverageCrop.rect(coverage: cov, width: image.width, height: image.height)
        else { return image }
        if rect.x0 == 0 && rect.y0 == 0 && rect.x1 == image.width - 1 && rect.y1 == image.height - 1 {
            return image   // full-frame rect: no-op
        }
        let croppedArea = rect.width * rect.height
        guard croppedArea >= (image.width * image.height) * 6 / 10 else {
            onLog?("Crop-to-overlap: rect \(rect.width)x\(rect.height) would remove >40% — keeping full frame")
            return image
        }
        return image.cropped(to: rect)
    }

    /// Drain the frame-consuming task with a bounded wait. On the primary timeout the task is
    /// CANCELLED and given a further grace period to acknowledge. If it STILL has not signalled,
    /// throw SessionPipelineError.shutdownTimeout rather than proceeding to finalize — a
    /// still-running consumer would race the accumulator/snapshots during finalization and could
    /// write a corrupt master. The previous code discarded the wait result and finalized anyway.
    private func drainConsumeTaskOrThrow() throws {
        let primary = drainPrimaryTimeout, grace = drainGraceTimeout
        guard let task = consumeTask else { return }
        if consumeDone.wait(timeout: .now() + primary) == .success {
            consumeTask = nil
            return
        }
        // Timed out: stop the consumer cooperatively and wait a bounded grace period.
        task.cancel()
        if consumeDone.wait(timeout: .now() + grace) == .success {
            consumeTask = nil
            return
        }
        // Still not acknowledged — refuse to finalize a racing stack.
        onLog?("Shutdown timed out: the frame consumer did not stop — refusing to finalize.")
        throw SessionPipelineError.shutdownTimeout
    }

    /// Ends the session and renders replay.mp4. Synchronous — call off the main thread.
    ///
    /// In native (importOnce) mode, drains any in-flight frame processing before finalizing.
    /// Writes master.fit into the session directory BEFORE `endSession()` stamps `end_time` —
    /// that ordering is the commit point (F1): a manifest claiming an ended session always has
    /// its durable master; a failed master write throws with `end_time` still nil (truthful).
    /// In watcher mode, stops the watcher first so the stream terminates, then drains.
    public func end() throws -> URL {
        if source != nil {
            if source?.isFinite ?? false {
                // Import: the stream ends on its own; drain it completely (a long import
                // takes as long as it takes — end() runs off the main thread).
                if consumeTask != nil {
                    consumeDone.wait()
                    consumeTask = nil
                }
                source?.stop()
            } else {
                // Live source: the stream never ends by itself — stop it first, then drain.
                source?.stop()
                try drainConsumeTaskOrThrow()
            }
        } else {
            // Watcher mode: stop the watcher to terminate the updates stream, then drain.
            watcher?.stop()
            try drainConsumeTaskOrThrow()
        }
        if let meta = sourceMetadata { session.fillMissingMetadata(from: meta) }
        guard let dir = session.sessionDirectory else {
            throw SessionError.notRunning
        }
        // F1 (review2): write the failure-prone durable artifact (master.fit) BEFORE persisting
        // endTime. `endSession()` is the COMMIT POINT — it stamps end_time into the manifest, which
        // the oracle reads as "this session ended." If the master write fails AFTER that stamp, the
        // manifest dishonestly claims an ended session with no persisted master (oracle clause 5).
        // Ordering master-first means a master-write failure throws here, before the commit, leaving
        // the manifest still-running (end_time nil) — truthful — and the error surfaces to the caller.
        //
        // Native mode: write the final mean stack as master.fit (TOP-DOWN, FITSWriter default).
        // Crop to covered region first (Task 4), then additive-only background neutralization
        // (display path uses additive+multiplicative; the saved master gets additive-only so
        // colour ratios stay physically calibratable). Crop happens BEFORE balance so balance
        // operates on the final spatial extent.
        if let eng = engine, let master0 = eng.currentStack() {
            let master = cropMaster(master0, coverage: eng.currentCoverage())   // crop BEFORE balance
            let balanced = neutralizeBackground
                ? AutoStretch.neutralizeBackgroundAdditive(master)
                : master
            let totalExp = Double(eng.stackFrameCount) * profile.subExposureSeconds
            let masterData = FITSWriter.float32(
                width: balanced.width, height: balanced.height,
                channels: balanced.channels, pixels: balanced.pixels,
                metadata: sourceMetadata,
                stackCount: eng.acceptedCount,
                totalExposureSeconds: totalExp)
            try masterData.write(to: dir.appendingPathComponent("master.fit"))
        }
        // Commit point: master.fit is durable (native mode), so stamping end_time is now honest.
        try session.endSession()
        return try ReplayService.regenerate(sessionDirectory: dir,
                                            replaySettings: replaySettings,
                                            maxKeyframes: maxKeyframes)
    }
}
