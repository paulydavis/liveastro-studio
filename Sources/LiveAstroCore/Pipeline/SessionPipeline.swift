import Foundation
import CoreGraphics

public enum SessionPipelineError: Error, Equatable {
    /// The frame-consuming task did not acknowledge shutdown within the drain deadline,
    /// even after cancellation. Finalizing would race a still-running consumer against the
    /// accumulator/snapshots, so end() throws instead of writing a corrupt master.
    case shutdownTimeout
    /// end() was called from INSIDE a synchronous frame/log callback (onUpdate, onLog,
    /// onRejected, onImportProgress — review10 item 4). The delivery context IS the
    /// consumer task end() must drain, so waiting would deadlock a finite import forever
    /// and burn the whole drain timeout in live modes. Call end() from outside the
    /// delivery context. Deliberately NOT made to work reentrantly: deferring finalization
    /// from inside delivery would silently change ordering semantics.
    case reentrantEnd
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
    /// Delivered SYNCHRONOUSLY on the frame-consumer task (review10 item 4): do NOT call
    /// end() from inside this callback — it throws `.reentrantEnd` (end() must drain the
    /// very task delivering the callback). Signal out and call end() from another context.
    public var onUpdate: ((CGImage, SnapshotRecord) -> Void)?
    /// May be delivered synchronously on the frame-consumer task — same reentrancy rule as
    /// `onUpdate`: end() from inside throws `.reentrantEnd`.
    public var onLog: ((String) -> Void)?
    /// Called for every frame the stack engine rejects (native mode only). Delivered on
    /// the frame-consumer task — same reentrancy rule as `onUpdate`.
    public var onRejected: ((RejectionReason, String) -> Void)?
    /// Called after each frame is processed (native import mode only). Delivered on the
    /// frame-consumer task — same reentrancy rule as `onUpdate`.
    public var onImportProgress: ((_ processed: Int, _ total: Int,
                                   _ accepted: Int, _ rejected: Int) -> Void)?
    private let cancelled = NSLock_Flag()

    // MARK: Reentrancy detection (review10 item 4)
    //
    // Callbacks are delivered synchronously from the consumer task; end() waits on that
    // task, so end() called from INSIDE a callback deadlocked a finite import forever and
    // burned the whole drain timeout in live modes. Every synchronous delivery site wraps
    // itself in withCallbackDelivery, recording the delivering THREAD (identity, not a
    // plain flag — end() from a different thread while a callback is in flight is the
    // normal case and must not be rejected); end() fails fast with .reentrantEnd when its
    // own thread is currently a delivery thread.

    private let deliveryLock = NSLock()
    private var deliveringThreads: Set<ObjectIdentifier> = []

    /// Run one synchronous frame/log delivery with the current thread marked as a delivery
    /// context. The wrapped sites (handle, handleNative, finalizeCommitted,
    /// finalizeRejected) never nest each other, so a plain set suffices.
    private func withCallbackDelivery(_ body: () -> Void) {
        let id = ObjectIdentifier(Thread.current)
        deliveryLock.withLock { _ = deliveringThreads.insert(id) }
        defer { deliveryLock.withLock { _ = deliveringThreads.remove(id) } }
        body()
    }

    /// True when the CALLING thread is currently inside synchronous callback delivery.
    private var isInsideCallbackDelivery: Bool {
        deliveryLock.withLock { deliveringThreads.contains(ObjectIdentifier(Thread.current)) }
    }

    private var processedCount = 0
    private var sourceMetadata: SourceMetadata?
    private var lastAutoReseedCount = 0

    // MARK: Plate-solve (sub-project 3a)
    //
    // Once a reference frame is established and its FITS metadata (RA/DEC/FOCALLEN/XPIXSZ) is known,
    // solve the reference against the star catalog OFF THE HOT PATH so 3b can orient the display
    // north-up. Optional end-to-end: any missing precondition (no catalog, no metadata, no reference)
    // makes it a silent no-op — the import is never affected. `plateSolveCatalog` is the injection seam
    // (tests set a real in-memory catalog; production reads the bundled one, nil until 3c ships data).
    private let plateSolveLock = NSLock()
    private var solvedWCS: WCS?                 // guarded by plateSolveLock
    private var solveAttempted = false          // guarded by plateSolveLock
    private var solveGeneration = 0             // guarded by plateSolveLock; bumped on reseed to void stale solves
    private let plateSolveQueue = DispatchQueue(label: "com.liveastro.platesolve")
    var plateSolveCatalog: StarCatalog? = StarCatalog.bundled()
    /// Test seam: invoked inside `attemptPlateSolveIfNeeded` AFTER the generation is claimed and BEFORE
    /// the reference stars are read, so a test can force a reseed into that exact window and prove no
    /// stale/stuck solve results. nil (no-op) in production.
    var onSolveClaimedForTest: (() -> Void)?

    /// The plate-solved WCS for the current reference frame, or nil if not (yet) solved / no catalog /
    /// missing metadata. 3b reads this to orient the display north-up. Thread-safe.
    public var currentWCS: WCS? { plateSolveLock.withLock { solvedWCS } }

    /// Void the stored/in-flight solve and re-enable solving so the NEXT reference re-solves. Called
    /// on BOTH reseed paths — manual `reseed()` and the engine's internal auto-reseed. The generation
    /// bump discards any in-flight solve that lands after this point.
    private func invalidatePlateSolve() {
        plateSolveLock.withLock { solvedWCS = nil; solveAttempted = false; solveGeneration += 1 }
    }

    /// Attempt the reference plate-solve once per reference generation, off the hot path. Idempotent
    /// and cheap to call from every finalize; guarded so preconditions failing (e.g. metadata not yet
    /// captured) leave the attempt un-consumed for a later frame, while a launched solve consumes it.
    private func attemptPlateSolveIfNeeded(engine: StackEngine) {
        guard let catalog = plateSolveCatalog,
              let m = sourceMetadata, let ra = m.ra, let dec = m.dec,
              let focal = m.focalLengthMM, focal > 0,
              let pix = m.pixelSizeUM, pix > 0 else { return }
        // Claim the single attempt for the CURRENT generation BEFORE reading the reference stars. Order
        // is load-bearing: reading the stars first and claiming second lets a reseed (main thread) slip
        // in between and tag STALE stars with the FRESH generation — a stale solve the store guard would
        // then wrongly accept, while also starving the real new reference (solveAttempted stuck true).
        // Claiming first means the only interleaving is a reseed CLEARING the stars, which we read back
        // as nil and bail. No NEW reference can appear between the claim and the read: references seed
        // only on this same serial consumer task, so nothing but reseed runs in that window.
        let gen: Int? = plateSolveLock.withLock {
            guard !solveAttempted, solvedWCS == nil else { return nil }
            solveAttempted = true
            return solveGeneration
        }
        guard let gen else { return }
        onSolveClaimedForTest?()   // test seam: force a reseed here to exercise the claim/read window
        guard let input = engine.referenceSolveInput() else {
            // A reseed cleared the reference after we claimed — release the claim (unless a reseed has
            // already bumped past our generation, which resets solveAttempted itself) so the next
            // reference for the live generation still solves.
            plateSolveLock.withLock { if gen == solveGeneration { solveAttempted = false } }
            return
        }
        // ×2: reference stars are half-res, so a half-res pixel subtends 2× the sky.
        let halfResScale = pix / focal * 206.264806 * 2
        plateSolveQueue.async { [weak self] in
            let wcs = PlateSolver.solve(stars: input.stars, width: input.width, height: input.height,
                                        pixelScaleArcsec: halfResScale, approxCenterRA: ra,
                                        approxCenterDec: dec, catalog: catalog)
            guard let self, let wcs else { return }
            // Store only if no reseed voided this generation while we solved.
            self.plateSolveLock.withLock { if gen == self.solveGeneration { self.solvedWCS = wcs } }
        }
    }

    // MARK: Import progress ticks (cold1 I1)
    //
    // The finite drain's deadline is PROGRESS-AWARE (see drainFiniteImportOrThrow): the
    // app calls end() right after start() to run the whole import, so the primary budget
    // bounds the time since the LAST finalized frame, never the import as a whole. One
    // tick per finalized frame (committed or rejected), lock-guarded because end() reads
    // it from the caller's thread while the consumer task writes it.
    private let progressLock = NSLock()
    private var progressTicks = 0
    private var activityTicks = 0
    private var activeFrameReads = 0
    private func noteFrameProgress() { progressLock.withLock { progressTicks += 1 } }
    private var progressSnapshot: Int { progressLock.withLock { progressTicks } }
    private var importActivitySnapshot: (progress: Int, activity: Int, activeReads: Int) {
        progressLock.withLock { (progressTicks, activityTicks, activeFrameReads) }
    }
    private func noteFrameSourceActivity(_ activity: FrameSourceActivity) {
        progressLock.withLock {
            activityTicks += 1
            switch activity {
            case .beginFrameRead:
                activeFrameReads += 1
            case .endFrameRead:
                activeFrameReads = max(0, activeFrameReads - 1)
            }
        }
    }

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
    /// Injectable for the master-snapshot atomic swap (FileReplace). Tests substitute a
    /// FileManager whose replace/move throws to prove a prior good master survives a
    /// failed write. Production uses `.default`.
    var fileManager: FileManager = .default
    private var recorder: SnapshotRecorder?
    private var consumeTask: Task<Void, Never>?
    private let consumeDone = DispatchSemaphore(value: 0)
    private let finalizationLock = NSLock()
    private var finalizationClaimed = false
    private var finalizationFailedAfterClaim = false
    /// Drain deadlines for end() (P1-3). Internal so tests can shrink them; production uses 10s/5s.
    var drainPrimaryTimeout: DispatchTimeInterval = .seconds(10)
    var drainGraceTimeout: DispatchTimeInterval = .seconds(5)
    var importActiveReadTimeout: DispatchTimeInterval = .seconds(60)
    /// Primary "no progress since the last finalized frame" window for the FINITE import
    /// drain — distinct from the live path's responsive `drainPrimaryTimeout` (10 s). A
    /// batch import legitimately has slow frames: a single 26MP sub can take ~12 s+ end to
    /// end (register + warp + rejection + the full-res snapshot encode), and at the tail —
    /// when the parallel pool drains to one frame processing alone with no sibling finalize
    /// to tick progress — a 10 s window cancelled a healthy import and threw shutdownTimeout
    /// (2026-08-16 ASI2600). 120 s tolerates a slow frame (even on modest hardware) while a
    /// genuinely wedged consumer is still caught. Internal so tests can shrink it.
    var importPrimaryTimeout: DispatchTimeInterval = .seconds(120)
    /// Long-edge cap for the import preview/snapshot render (Approach B): finalizeCommitted
    /// downsamples the stacked image to this before displayCGImage so the neutralize/stretch
    /// passes don't run on all 26 MP. Defaults to the SnapshotRecorder cap; internal so tests
    /// can shrink it to keep the call-site test off a full-size frame.
    var importPreviewLongEdge = SnapshotRecorder.maxSnapshotLongEdge
    /// Import-only: render (mean→downsample→neutralize→snapshot→preview) on a cadence so ~`snapshotBudget`
    /// snapshots are produced instead of one per accepted frame (the 1.78 s/frame finalize is 82% of the
    /// serial import cost, and the replay keeps only maxKeyframes). Internal `var` = test seam. Live/watcher
    /// mode ignores this and renders every frame.
    var snapshotBudget = 60
    private var importFinalizeStride = 1          // 1 = every frame; set from totalCount at import start
    private var lastRenderedAcceptedIndex = 0     // for the guaranteed final render in end()
    private var lastCommitted: (name: String, timestamp: Date)?
    /// Test seam: when false, end() finalizes the session (master + manifest) but skips the
    /// AVFoundation replay render and returns the session directory instead of replay.mp4.
    /// Drain/watchdog unit tests set this — the replay writer's setup/teardown is a fixed
    /// multi-second cost unrelated to what they exercise (2026-08-17 suite-speed note).
    /// Production leaves it true.
    var rendersReplay = true
    /// Per-read dead-share cap: how many consecutive `importActiveReadTimeout` windows a
    /// SINGLE in-flight read may span with no begin/end event before it is treated as a hung
    /// share and cancelled. A slow-but-live read (a 50 MB sub over WiFi — 2026-08-16 ASI2600
    /// regression) resets this the instant its endFrameRead, or the next read's begin, ticks
    /// activity; only a genuinely wedged read exhausts it. 5 × 60 s = 5 min in production.
    /// Internal so tests can shrink it.
    var importDeadReadWindowLimit = 5

    /// Watcher mode: monitors a folder for new Siril stacks and processes each update.
    public init(watchFolder: URL, profile: SessionProfile, rootDirectory: URL,
                replaySettings: ReplaySettings = .init(),
                maxKeyframes: Int = FrameSelector.defaultMaxKeyframes,
                fileNamePrefix: String? = nil, neutralizeBackground: Bool = false) {
        // Review7 P2 / review9 item 1: Siril watcher mode matches BOTH the classic
        // in-place live_stack.fit AND the immutable numbered revisions
        // (live_stack_00001.fit …) Siril 1.4+ writes under the same prefix.
        // `.mutableStackerOutput` handles this per entry: the classic file is
        // REWRITTEN in place, so identity (dev, ino, size, mtime-ns) never gates
        // its hashing (a coarse or cached filesystem timestamp could collide
        // across a real content change — full rehash every stable scan); numbered
        // revisions are written once, so after their confirmed first emission
        // (same stat-stability + digest-stability gates) they cost one fstat per
        // poll instead of re-hashing an ever-growing revision history.
        self.watcher = StackFileWatcher(folder: watchFolder, fileNamePrefix: fileNamePrefix,
                                        digestPolicy: .mutableStackerOutput)
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

    /// Review10 item 5: a RUNNING pipeline dropped without end() must not leak its live
    /// machinery. The detached consumer captures `self` weakly (which is why this deinit
    /// can run at all) but strongly retains the source and engine for its own lifetime —
    /// without this hook, releasing a native-live pipeline left the source running and the
    /// task parked on a never-ending stream forever. Cancel the stored task handle
    /// (AsyncStream iteration honors cancellation), stop the source, and stop the watcher
    /// (bounded — review10 item 3). Deliberately NO logging here: `onLog` may capture the
    /// very owner being torn down, and invoking user callbacks from deinit re-enters a
    /// half-deinitialized object graph.
    deinit {
        consumeTask?.cancel()
        source?.stop()
        watcher?.stop()
    }

    public enum ReseedResult: Equatable {
        case reseeded, notNative, unavailableDuringImport, finalizationInProgress, finalizationRetryPending
    }

    /// Reseeds the stacking engine, discarding the current reference frame (native mode only).
    @discardableResult
    public func reseed() -> ReseedResult {
        guard let engine else { return .notNative }
        return finalizationLock.withLock {
            guard !finalizationClaimed else {
                return finalizationFailedAfterClaim ? .finalizationRetryPending : .finalizationInProgress
            }
            guard source?.isFinite != true else { return .unavailableDuringImport }
            engine.reseed()
            // Void any stored/in-flight solve so the new reference re-solves against its (fresh) stars.
            // sourceMetadata is left as-is: reseed is a same-target re-establish (center unchanged), and
            // it's owned by the serial frame-processing path — clearing it here would race that writer.
            // (New-target metadata re-capture is out of 3a scope.)
            invalidatePlateSolve()
            return .reseeded
        }
    }

    /// Cancel an in-progress import: stops feeding new frames; end() finalizes
    /// whatever completed into a valid master.fit + replay (not a hard abort).
    public func cancelImport() { cancelled.set(); source?.stop() }

    /// Finalize one committed frame (import batch path): snapshot + progress.
    /// Called serially by BatchImporter in completion order. Callback deliveries inside are
    /// reentrancy-guarded (review10 item 4).
    private func finalizeCommitted(index: Int, sourceName: String, timestamp: Date, metadata: SourceMetadata?, engine: StackEngine) {
        noteFrameProgress()   // cold1 I1: a finalized frame is drain progress
        withCallbackDelivery {
            if sourceMetadata == nil, let m = metadata { sourceMetadata = m }
            attemptPlateSolveIfNeeded(engine: engine)
            processedCount += 1
            lastCommitted = (sourceName, timestamp)       // remembered for end()'s guaranteed final render
            if shouldRenderImport(acceptedIndex: index) {
                renderSnapshot(index: index, sourceName: sourceName, timestamp: timestamp, engine: engine)
            }
            if let total = source?.totalCount {
                onImportProgress?(processedCount, total, engine.acceptedCount, engine.rejectedCount)
            }
        }
    }

    /// Renders + saves one snapshot from the current stack and pushes the preview. Shared by the
    /// throttled per-frame path and end()'s guaranteed final render. Sets lastRenderedAcceptedIndex.
    private func renderSnapshot(index: Int, sourceName: String, timestamp: Date, engine: StackEngine) {
        guard let (mean0, coverage) = engine.currentStackAndCoverage() else { return }
        let mean = cropToCoverage(mean0, coverage: coverage)   // display shows the covered region (like master.fit)
        guard let recorder else { onLog?("recorder missing — frame dropped (\(sourceName))"); return }
        do {
            let displaySource = mean.downsampled(maxLongEdge: importPreviewLongEdge)
            let cg = try displayCGImage(from: displaySource)
            let record = try recorder.save(
                cgImage: cg, linear: mean, sourceFile: sourceName,
                index: index, timestamp: timestamp,
                estimatedIntegrationSeconds: Double(engine.stackFrameCount) * profile.subExposureSeconds)
            try session.recordSnapshot(record)
            lastRenderedAcceptedIndex = index
            onUpdate?(cg, record)
        } catch {
            onLog?("Skipped frame (\(sourceName)): \(error)")
        }
    }

    /// Live/watcher mode renders every committed frame; import mode renders the seed + every stride-th.
    private func shouldRenderImport(acceptedIndex index: Int) -> Bool {
        guard source?.isFinite == true else { return true }
        return index == 1 || index % importFinalizeStride == 0
    }

    private func finalizeRejected(sourceName: String, engine: StackEngine) {
        noteFrameProgress()   // cold1 I1: a finalized frame is drain progress
        withCallbackDelivery {
            processedCount += 1
            onRejected?(.noTransform, sourceName)
            onLog?("Rejected \(sourceName)")
            if let total = source?.totalCount {
                onImportProgress?(processedCount, total, engine.acceptedCount, engine.rejectedCount)
            }
        }
    }

    private func captureMetadataAndFinalize(committed c: BatchImporter.Committed, engine: StackEngine) {
        finalizeCommitted(index: c.index, sourceName: c.sourceName, timestamp: c.timestamp, metadata: c.metadata, engine: engine)
    }

    public func start() throws {
        // Review11 finding 2: the master expectation is decided HERE, from session semantics,
        // at session start — native stacking promises a durable master.fit at end(); watcher
        // mode never writes one (the stack lives with the external stacker). The field is
        // immutable thereafter: a failed master write must trip the oracle, not exempt itself.
        let dir = try session.startSession(profile: profile, masterExpected: engine != nil)
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
            if let activitySource = src as? FrameSourceActivityReporting {
                activitySource.onActivity = { [weak self] activity in
                    self?.noteFrameSourceActivity(activity)
                }
            }
            try src.start()
            let done = consumeDone
            if src.isFinite {
                // IMPORT: frame-per-core parallel batch. Throttle finalize to ~snapshotBudget renders.
                let total = src.totalCount ?? 0
                importFinalizeStride = total > 0
                    ? max(1, Int((Double(total) / Double(max(1, snapshotBudget))).rounded()))   // max(1,·): a 0 budget must not divide-by-zero
                    : 1
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
        // Denoise AFTER stretch + DBE (the targeted noise is the post-stretch
        // appearance) and BEFORE saturation/packing, so broadcast, snapshots,
        // latest.png and replay all inherit it while master.fit stays raw (spec §2.2).
        // Clamp on APPLY, not in the struct (DisplayAdjustments convention).
        let denoised = adj.denoiseStrength > 0
            ? Denoiser.apply(stretched, strength: Float(min(max(adj.denoiseStrength, 0), 1)))
            : stretched
        let display = AutoStretch.applySaturation(denoised, adj.saturation)
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
        // Crop to the covered region like renderSnapshot/handleNative, so a slider re-render
        // doesn't snap the preview back to the ragged full-union frame.
        guard let (mean0, coverage) = engine?.currentStackAndCoverage() else { return nil }
        let mean = cropToCoverage(mean0, coverage: coverage)
        return try? displayCGImage(from: mean)
    }

    /// Processes one raw frame through the stack engine (native mode). Callback deliveries
    /// inside are reentrancy-guarded (review10 item 4).
    private func handleNative(_ rawFrame: RawFrame, engine: StackEngine) {
        withCallbackDelivery {
            if cancelled.isSet { return }
            if sourceMetadata == nil, let m = rawFrame.metadata { sourceMetadata = m }
            let frame = calibrator?.apply(rawFrame) ?? rawFrame
            let outcome = engine.process(frame)
            if engine.autoReseedCount != lastAutoReseedCount {
                lastAutoReseedCount = engine.autoReseedCount
                // The engine dropped its reference and will re-seed on the next good sub — void the
                // stale WCS and re-enable solving so the NEW reference plate-solves (its center/rotation
                // can differ). MUST run before attemptPlateSolveIfNeeded below so this frame's attempt
                // sees the reset state (manual reseed() does the same via invalidatePlateSolve()).
                invalidatePlateSolve()
                onLog?("Auto-reseeded — the reference frame didn't match; re-seeding on the next good sub. (Earlier subs that couldn't register stay rejected.)")
            }
            attemptPlateSolveIfNeeded(engine: engine)   // idempotent; no-op until a reference is seeded
            processedCount += 1
            switch outcome {
            case .becameReference, .stacked:
                guard let (mean0, coverage) = engine.currentStackAndCoverage() else { return }
                let mean = cropToCoverage(mean0, coverage: coverage)   // display shows the covered region (like master.fit)
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
    }

    /// Processes one watcher update (watcher mode). Callback deliveries inside are
    /// reentrancy-guarded (review10 item 4).
    private func handle(_ update: StackUpdate) {
        withCallbackDelivery {
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
    }

    /// DispatchTimeInterval → seconds, for handing the drain budget to the watcher's
    /// bounded stop (review10 item 3). `.never` and unknown cases map to infinity.
    private static func seconds(_ interval: DispatchTimeInterval) -> TimeInterval {
        switch interval {
        case .seconds(let s):       return TimeInterval(s)
        case .milliseconds(let ms): return TimeInterval(ms) / 1_000
        case .microseconds(let us): return TimeInterval(us) / 1_000_000
        case .nanoseconds(let ns):  return TimeInterval(ns) / 1_000_000_000
        case .never:                return .infinity
        @unknown default:           return .infinity
        }
    }

    /// Crop the master to its covered region (a copy). Returns the image
    /// unchanged when coverage is unavailable, the rect is nil, the rect is the
    /// full frame, or the crop would remove more than ~40% of the area.
    private func cropToCoverage(_ image: AstroImage, coverage: [Float]?) -> AstroImage {
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

    /// The running session's directory (nil before start / after teardown). Internal so
    /// the snapshot path and tests can address `master.fit` without reaching through
    /// `session`.
    var sessionDir: URL? { session.sessionDirectory }

    /// Write `master.fit` from the CURRENT live stack WITHOUT ending the session
    /// (idle safeguard, spec §2). Native mode only. Mirrors the master write inside
    /// `end()` — cropToCoverage → additive-only neutralize (when the flag is set) →
    /// FITSWriter.float32 — but sources the image from the LIVE stack
    /// (`engine.currentStack()`), not the finalized state. The swap is atomic via
    /// FileReplace so a prior good master survives a failed write. Does NOT stamp
    /// `end_time`, stop the engine, or touch running state. Idempotent; callable
    /// repeatedly. Returns false when this is not a native session, there is no live
    /// stack yet, or the write failed.
    @discardableResult
    public func writeMasterSnapshot() -> Bool {
        guard let engine, let dir = session.sessionDirectory else { return false }
        // Single locked read of image + coverage + frameCount so a frame commit or
        // reseed landing mid-snapshot can't tear the file (pixels from one stack state,
        // STACKCNT/TOTALEXP from another). Nil ⇒ no live stack yet ⇒ write nothing.
        guard let snap = engine.masterSnapshotState() else {
            onLog?("master snapshot skipped — no live stack")
            return false
        }
        let frameCount = snap.frameCount                              // STACKCNT source (same read as pixels)
        let master = cropToCoverage(snap.image, coverage: snap.coverage)   // crop BEFORE balance
        let balanced = neutralizeBackground
            ? AutoStretch.neutralizeBackgroundAdditive(master)
            : master
        let totalExp = Double(frameCount) * profile.subExposureSeconds
        let data = FITSWriter.float32(
            width: balanced.width, height: balanced.height,
            channels: balanced.channels, pixels: balanced.pixels,
            metadata: sourceMetadata,
            stackCount: frameCount,
            totalExposureSeconds: totalExp)
        let target = dir.appendingPathComponent("master.fit")
        let tmp = dir.appendingPathComponent(".master-snapshot-\(UUID().uuidString).fit")
        do {
            try data.write(to: tmp)
            try FileReplace.replaceItem(at: target, withItemAt: tmp, fileManager: fileManager)
            onLog?("master snapshot written (\(frameCount) frames)")
            return true
        } catch {
            try? fileManager.removeItem(at: tmp)
            onLog?("master snapshot failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Drain the frame-consuming task with a bounded wait. On the primary timeout the task is
    /// CANCELLED and given a further grace period to acknowledge. If it STILL has not signalled,
    /// throw SessionPipelineError.shutdownTimeout rather than proceeding to finalize — a
    /// still-running consumer would race the accumulator/snapshots during finalization and could
    /// write a corrupt master. The previous code discarded the wait result and finalized anyway.
    /// `primaryDeadline` (review10 item 3) lets the watcher path charge its bounded
    /// watcher-stop against the SAME primary budget: stop + drain together never exceed
    /// drainPrimaryTimeout (+ grace). nil → the full primary budget from now (native paths).
    private func drainConsumeTaskOrThrow(primaryDeadline: DispatchTime? = nil) throws {
        let grace = drainGraceTimeout
        guard let task = consumeTask else { return }
        if consumeDone.wait(timeout: primaryDeadline ?? .now() + drainPrimaryTimeout) == .success {
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

    /// Cold1 I1: bounded drain for the FINITE import branch. The previous code waited on
    /// `consumeDone` with NO deadline, so one stalled read inside the import pull (a dead
    /// SMB share) pinned end() forever, outside every promised timeout. Unlike the live/
    /// watcher drains the deadline here is PROGRESS-AWARE: a healthy import must still
    /// drain COMPLETELY (the app calls end() right after start() to run the whole import),
    /// so `drainPrimaryTimeout` bounds the time since the LAST finalized frame — as long
    /// as frames keep landing, the wait continues. Once a full primary window passes with
    /// zero progress, the import is cancelled (cancelImport(): the source cursor stops
    /// feeding AND the importer's isCancelled flag flips) plus the task itself, and given
    /// `drainGraceTimeout` to acknowledge; a cancel that lands finalizes the partial-but-
    /// honest session exactly like a user cancelImport(). If even the grace expires,
    /// throw shutdownTimeout rather than finalize over a still-running consumer. A hung
    /// BLOCKING read cannot be interrupted mid-syscall — the bound is on OUR wait; the
    /// task is cancelled and abandoned honestly (consistent with the watcher-mode
    /// contract).
    private func drainFiniteImportOrThrow() throws {
        guard let task = consumeTask else { return }
        var last = importActivitySnapshot
        outer: while true {
            if consumeDone.wait(timeout: .now() + importPrimaryTimeout) == .success {
                consumeTask = nil
                return
            }
            var now = importActivitySnapshot
            if now.progress != last.progress || now.activity != last.activity {
                last = now
                continue   // progressing/starting or finishing reads — keep draining
            }
            // A full import-primary window passed with no finalized frame and no read event.
            // If a read is genuinely in flight it's slow, not stalled (a 50 MB sub over a
            // network share — 2026-08-16 ASI2600): grant it up to importDeadReadWindowLimit
            // ACTIVE-READ windows to progress before the share is treated as dead. The
            // dead-read patience is exactly limit × importActiveReadTimeout — it must NOT
            // re-charge importPrimaryTimeout each cycle (2026-08-17 review: the prior
            // `continue` looped back through the 120 s primary wait, inflating the cap to
            // limit × (primary + active) ≈ 15 min instead of the documented ~5 min).
            if now.activeReads > 0 {
                var deadReadWindows = 0
                while deadReadWindows < importDeadReadWindowLimit {
                    if consumeDone.wait(timeout: .now() + importActiveReadTimeout) == .success {
                        consumeTask = nil
                        return
                    }
                    let after = importActivitySnapshot
                    if after.progress != now.progress || after.activity != now.activity {
                        last = after
                        continue outer   // progressed — resume the primary-window watch
                    }
                    if after.activeReads == 0 { break }   // read ended with no progress → real stall
                    deadReadWindows += 1
                    now = after
                }
            }
            break                          // no active read + no progress, OR read wedged past the cap
        }
        onLog?("Import stalled with no progress — cancelling remaining frames and finalizing completed frames.")
        cancelImport()
        task.cancel()
        if consumeDone.wait(timeout: .now() + drainGraceTimeout) == .success {
            consumeTask = nil
            return
        }
        onLog?("Shutdown timed out: the import stalled with no progress — refusing to finalize.")
        throw SessionPipelineError.shutdownTimeout
    }

    /// Ends the session and renders replay.mp4. Synchronous — call off the main thread,
    /// and NEVER from inside one of this pipeline's callbacks (onUpdate / onLog /
    /// onRejected / onImportProgress): those are delivered synchronously on the
    /// frame-consumer task that end() must drain, so a reentrant end() throws
    /// `.reentrantEnd` immediately (review10 item 4) instead of deadlocking a finite
    /// import or burning the drain timeout.
    ///
    /// In native (importOnce) mode, drains any in-flight frame processing before finalizing.
    /// Writes master.fit into the session directory BEFORE `endSession()` stamps `end_time` —
    /// that ordering is the commit point (F1): a manifest claiming an ended session always has
    /// the durable master it PROMISED (masterExpected, review11 finding 2 — native sessions
    /// with accepted frames); a failed master write throws with `end_time` still nil
    /// (truthful). Watcher sessions and zero-frame native sessions promise/write no master and
    /// log that fact honestly.
    /// In watcher mode, stops the watcher first so the stream terminates, then drains.
    public func end() throws -> URL {
        // Review10 item 4: fail fast — this thread is currently DELIVERING a callback from
        // the consumer task, and every branch below waits on that task.
        guard !isInsideCallbackDelivery else { throw SessionPipelineError.reentrantEnd }
        // Cold2 M1: an already-ended (or never-started) session throws BEFORE touching
        // any durable artifact. Pre-fix a SECOND end() sailed past the drains
        // (consumeTask already nil), re-executed the whole master-write block
        // POST-COMMIT — rewriting master.fit behind the sealed manifest — and only then
        // threw notRunning from endSession(). A FAILED first end() (shutdownTimeout,
        // master-write failure) leaves the session .running, so retry is unaffected.
        guard session.state == .running else { throw SessionError.notRunning }
        finalizationLock.withLock {
            finalizationClaimed = true
            finalizationFailedAfterClaim = false
        }
        do {
            if source != nil {
                if source?.isFinite ?? false {
                    // Import: the stream ends on its own; drain it completely while frames
                    // keep landing, but BOUNDED (cold1 I1): a stalled read triggers
                    // cancel + grace → shutdownTimeout instead of pinning end() forever.
                    try drainFiniteImportOrThrow()
                    source?.stop()
                    // Guaranteed final snapshot: the last accepted frame may have been throttled, so
                    // render once from the completed stack → latest.png + last replay keyframe show full depth.
                    // Wrapped in withCallbackDelivery so this render's onUpdate marks the current thread as a
                    // delivery context: a client that re-enters end() from that callback hits the .reentrantEnd
                    // guard (line ~710) instead of nest-finalizing (double master write past the sealed manifest).
                    // The consumer task is already drained here, so this only sets the reentrancy marker — no
                    // mutual-exclusion contention and no deadlock (deliveryLock is not held by end()).
                    if let eng = engine, lastRenderedAcceptedIndex < eng.acceptedCount, let lc = lastCommitted {
                        withCallbackDelivery {
                            renderSnapshot(index: eng.acceptedCount, sourceName: lc.name, timestamp: lc.timestamp, engine: eng)
                        }
                    }
                } else {
                    // Live source: the stream never ends by itself — stop it first, then drain.
                    // Cold1 M1: the source's own bounded stop (FolderFrameSource → inner
                    // watcher, previously an un-budgeted 5 s default ON TOP of the drain) is
                    // charged against the SAME primary budget, mirroring the watcher-mode
                    // branch below: stop + drain together never exceed primary (+ grace).
                    let primaryDeadline = DispatchTime.now() + drainPrimaryTimeout
                    if let folderSource = source as? FolderFrameSource {
                        folderSource.stop(timeout: Self.seconds(drainPrimaryTimeout))
                    } else {
                        source?.stop()
                    }
                    try drainConsumeTaskOrThrow(primaryDeadline: primaryDeadline)
                }
            } else {
                // Watcher mode: stop the watcher to terminate the updates stream, then drain.
                // Review10 item 3: the watcher stop is itself BOUNDED and shares the primary
                // drain budget — a scan stalled on a dead share can no longer pin end()
                // outside the documented primary+grace timeout. The deadline is captured
                // before the stop so stop-time is charged against the same budget.
                let primaryDeadline = DispatchTime.now() + drainPrimaryTimeout
                watcher?.stop(timeout: Self.seconds(drainPrimaryTimeout))
                try drainConsumeTaskOrThrow(primaryDeadline: primaryDeadline)
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
            var finalization: SessionFinalizationFacts?
            if let eng = engine {
                let final = try eng.finalizationState()
                let outcome: MasterOutcome
                switch final.stackState {
                case .active:
                    guard let master0 = final.image else {
                        throw StackEngine.FinalizationError.invariantBreach
                    }
                    let master = cropToCoverage(master0, coverage: final.coverage)   // crop BEFORE balance
                    let balanced = neutralizeBackground
                        ? AutoStretch.neutralizeBackgroundAdditive(master)
                        : master
                    let totalExp = Double(final.frameCount) * profile.subExposureSeconds
                    let masterData = FITSWriter.float32(
                        width: balanced.width, height: balanced.height,
                        channels: balanced.channels, pixels: balanced.pixels,
                        metadata: sourceMetadata,
                        stackCount: final.frameCount,
                        totalExposureSeconds: totalExp)
                    try masterData.write(to: dir.appendingPathComponent("master.fit"))
                    outcome = .written
                case .awaitingSeedAfterReseed:
                    onLog?("reference cleared by reseed (manual or automatic) and never re-seeded — no master available (\(final.sessionAcceptedCount) snapshots retained)")
                    outcome = .awaitingSeed
                case .initialEmpty:
                    // Review11 finding 2, empty native session: zero accepted frames — there is
                    // no stack to persist. `masterExpected` stays true (immutable since start);
                    // the manifest records the zero-frame fact (empty snapshots) and the oracle's
                    // clause 5 keys on masterExpected && frames recorded, so ending without a
                    // master here is honest — and it is SAID, not silent.
                    onLog?("no frames accepted — no master written")
                    outcome = .noFrames
                }
                finalization = SessionFinalizationFacts(
                    masterOutcome: outcome,
                    stackFrameCount: final.frameCount,
                    sessionAcceptedCount: final.sessionAcceptedCount,
                    sessionRejectedCount: final.sessionRejectedCount)
            } else {
                // Review11 finding 2, watcher mode: the stack is the external stacker's artifact;
                // this session never promises a master (masterExpected == false since start).
                // State the expectation once so the ended-without-master manifest reads honestly.
                onLog?("watcher session — the stack lives with the external stacker; no master.fit")
            }
            // Commit point: master.fit is durable (native mode), so stamping end_time is now honest.
            try session.endSession(finalization: finalization)
            guard rendersReplay else { return dir }   // test seam: skip the AVFoundation render
            return try ReplayService.regenerate(sessionDirectory: dir,
                                                replaySettings: replaySettings,
                                                maxKeyframes: maxKeyframes)
        } catch {
            finalizationLock.withLock {
                if finalizationClaimed {
                    finalizationFailedAfterClaim = true
                }
            }
            throw error
        }
    }
}
