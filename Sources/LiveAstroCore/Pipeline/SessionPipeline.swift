import Foundation
import CoreGraphics

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

    public func start() throws {
        let dir = try session.startSession(profile: profile)
        recorder = SnapshotRecorder(sessionDirectory: dir)

        if let src = source, let eng = engine {
            // Native stacking mode
            calibrator?.onLog = { [weak self] in self?.onLog?($0) }
            try src.start()
            let done = consumeDone
            consumeTask = Task.detached(priority: .userInitiated) { [weak self] in
                for await frame in src.frames {
                    self?.handleNative(frame, engine: eng)
                }
                done.signal()
            }
        } else {
            // Watcher mode
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
            ? BackgroundExtraction.flatten(linear, degree: adj.backgroundDegree)
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
            let linear = try ImageLoader.load(url: update.url)
            let cg = try displayCGImage(from: linear)
            let index = session.acceptedCount + 1
            let record = try recorder.save(
                cgImage: cg, linear: linear, sourceFile: update.url.lastPathComponent,
                index: index, timestamp: Date(),
                estimatedIntegrationSeconds: Double(index) * profile.subExposureSeconds)
            try session.recordSnapshot(record)
            onUpdate?(cg, record)
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

    /// Ends the session and renders replay.mp4. Synchronous — call off the main thread.
    ///
    /// In native (importOnce) mode, drains any in-flight frame processing before finalizing.
    /// After the manifest is finalized, writes master.fit into the session directory.
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
                if consumeTask != nil {
                    _ = consumeDone.wait(timeout: .now() + 10)
                    consumeTask = nil
                }
            }
        } else {
            // Watcher mode: stop the watcher to terminate the updates stream, then drain.
            watcher?.stop()
            if consumeTask != nil {
                _ = consumeDone.wait(timeout: .now() + 10)
                consumeTask = nil
            }
        }
        if let meta = sourceMetadata { session.fillMissingMetadata(from: meta) }
        try session.endSession()
        guard let dir = session.sessionDirectory else {
            throw SessionError.notRunning
        }
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
        return try ReplayService.regenerate(sessionDirectory: dir,
                                            replaySettings: replaySettings,
                                            maxKeyframes: maxKeyframes)
    }
}
