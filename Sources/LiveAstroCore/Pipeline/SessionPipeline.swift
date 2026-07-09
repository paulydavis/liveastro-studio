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
        let balanced = neutralizeBackground
            ? AutoStretch.neutralizeBackground(AutoStretch.neutralizeBackgroundAdditive(linear))
            : linear
        let display = balanced.sourceIsLinear ? AutoStretch.stretch(balanced) : balanced
        guard let cg = AutoStretch.makeCGImage(display) else {
            throw ImageLoaderError.decodeFailed("CGImage packing")
        }
        return cg
    }

    /// Processes one raw frame through the stack engine (native mode).
    private func handleNative(_ rawFrame: RawFrame, engine: StackEngine) {
        if cancelled.isSet { return }
        let frame = calibrator?.apply(rawFrame) ?? rawFrame
        let outcome = engine.process(frame)
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
        try session.endSession()
        guard let dir = session.sessionDirectory else {
            throw SessionError.notRunning
        }
        // Native mode: write the final mean stack as master.fit (TOP-DOWN, FITSWriter default).
        if let eng = engine, let master = eng.currentStack() {
            let masterData = FITSWriter.float32(width: master.width, height: master.height,
                                                channels: master.channels, pixels: master.pixels)
            try masterData.write(to: dir.appendingPathComponent("master.fit"))
        }
        return try ReplayService.regenerate(sessionDirectory: dir,
                                            replaySettings: replaySettings,
                                            maxKeyframes: maxKeyframes)
    }
}
