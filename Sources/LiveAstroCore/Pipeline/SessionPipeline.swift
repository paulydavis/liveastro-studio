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

/// Composite freshness key for a background-refiner-published master (Task 7): identifies exactly
/// which generation / survivor-set / user-reject-state / κ a published master was computed from.
/// `publishedMasterIfCurrent()` invalidates the stored master the instant anything that changes
/// what it MEANS changes — a reseed, a user reject, a κ change, a sample-budget change, or an
/// enable-state transition — so broadcast/end() never consume a stale trail-free master. A
/// GROWN survivor set is the deliberate exception: subs arriving during a pass make the
/// published master merely SHALLOW, not wrong, and it keeps being served until the next pass
/// publishes (see `isServable(against:)` — without this a busy session starves and never serves
/// a clean master at all). `end()` does NOT settle for shallow: it prefers an exactly-current
/// master, else runs the bounded final pass, and only falls back to a shallower servable master
/// if that pass fails — `master.fit` is archival and must be the deepest available.
/// `survivorSubIndices` is the SORTED list of survivor
/// `subIndex`es (unique per sub — byte-identical subs stay distinct entries, never collapsed to
/// a digest set). `maxSampleBytes` is in the key (review P2) because clearing `publishedMaster`
/// on a budget change was not enough: a pass already in flight snapshotted the OLD key, and
/// with the budget absent from it that pass could publish a master computed under the old
/// budget and have it read as "current" again.
public struct FreshnessKey: Equatable {
    let stackGeneration: Int
    let survivorSubIndices: [Int]
    let userRejectGeneration: Int
    let kappa: Float
    let maxSampleBytes: Int
    /// Monotonic counter bumped on every live-rejection enable-state TRANSITION, so each
    /// contiguous ON period has its own epoch (review P3). Without it the key is identical
    /// before and after an OFF→ON cycle — nothing else in the key changes — so a pass cancelled
    /// at OFF that reaches `publish` after a quick re-enable would satisfy both
    /// `liveRejectionActive` and `key == _freshnessKey` and store its result, violating
    /// "OFF cancels this pass; re-enable starts a fresh pass". (The window is real because a
    /// pass cancelled during the per-pixel combine — which is not interruptible mid-loop — still
    /// runs to its publish call.) The epoch makes the pre-OFF key unequal to every later key.
    let liveRejectionEpoch: Int

    /// Everything that makes a published master WRONG rather than merely SHALLOW. A reseed
    /// (`stackGeneration`), a user reject (`userRejectGeneration`), a κ or sample-budget change,
    /// or an enable-state transition (`liveRejectionEpoch`) each change what the master MEANS, so
    /// one computed before any of them must never be served. `survivorSubIndices` is deliberately
    /// NOT here — see `isServable(against:)`.
    private var validityCore: [AnyHashable] {
        [stackGeneration, userRejectGeneration, kappa, maxSampleBytes, liveRejectionEpoch]
    }

    /// Whether a master computed under `self` may still be served while the live state is
    /// `current`.
    ///
    /// Exact key equality was the original rule, and it STARVES a live session: a refine pass over
    /// 26 MP subs can take longer than the sub cadence, so by the time it finishes another sub has
    /// landed, `survivorSubIndices` has grown, the key differs, and the finished result is thrown
    /// away — repeatedly, at 100% CPU, with the broadcast silently serving the online master the
    /// whole time. Observed on a real 17-sub M51 session: `latest.png` stayed byte-identical to the
    /// online snapshot from the first sub to the last.
    ///
    /// A master built from subs 1…11 is not WRONG when sub 12 lands — it is one sub shallower and
    /// still trail-free. So the validity fields must match exactly, and the master's survivor set
    /// must be a SUBSET of the current one. Given equal validity fields that set can only have
    /// GROWN (a sub leaves only via a reject or a generation change, and both live in
    /// `validityCore`), so the subset test says precisely "only new subs arrived since".
    func isServable(against current: FreshnessKey) -> Bool {
        guard validityCore == current.validityCore else { return false }
        return Set(survivorSubIndices).isSubset(of: Set(current.survivorSubIndices))
    }
}

/// The background refiner's most recently published trail-free master (Task 6/7), stamped with
/// the `FreshnessKey` it was computed from (D11: named replacement for the previously-anonymous
/// 4-field tuple `(image:coverage:survivorCount:key:)` — no compiler check kept the tuple's
/// shape in sync across its several call sites; this struct gives that a single definition).
/// `Equatable` for the same test-assertion purpose the tuple served: `AstroImage` itself is not
/// `Equatable` (its `pixels` array makes a full conformance expensive/undesirable), so equality
/// here compares the scalar/key fields plus the image's dimensions rather than its pixel data.
struct PublishedMaster: Equatable {
    let image: AstroImage
    let coverage: [Float]
    let survivorCount: Int
    let key: FreshnessKey

    static func == (lhs: PublishedMaster, rhs: PublishedMaster) -> Bool {
        lhs.coverage == rhs.coverage && lhs.survivorCount == rhs.survivorCount && lhs.key == rhs.key
            && lhs.image.width == rhs.image.width && lhs.image.height == rhs.image.height
            && lhs.image.channels == rhs.image.channels && lhs.image.sourceIsLinear == rhs.image.sourceIsLinear
    }
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
    /// Paired operator/broadcast delivery, including transitions between accepted frames.
    /// Like onUpdate, callbacks must not synchronously call end().
    public var onDisplayUpdate: ((DisplayDelivery) -> Void)?
    private let displayRenderLock = NSRecursiveLock()
    private let displayRevisionLock = NSLock()
    private var displayRevision: UInt64 = 0
    private var displayFinished = false
    private let displayQueue = DispatchQueue(label: "com.liveastro.display-transitions")
    // Guarded by displayRenderLock. Retain linear data for watcher re-renders too.
    /// Image, crop, and provenance travel together after the engine's atomic displaySnapshot.
    /// Within a pipeline-managed native engine, (generation, count) identifies pixels and coverage:
    /// seedReference is startup-only (BatchImporter); callers must not replace its accumulator
    /// directly while this pipeline owns it. Accepted
    /// additions advance count, and manual/automatic reseeds advance generation. The fixed crop
    /// policy is deterministic for that coverage, including same-size crops at different origins.
    private struct OnlineDisplaySnapshot {
        let image: AstroImage
        let count: Int
        let cap: Int?
        let generation: Int?  // nil for watcher sources: never cache their saved-snapshot index
    }
    private var displayOnline: OnlineDisplaySnapshot?
    private struct DisplayRenderContext {
        let adjustments: DisplayAdjustments
        let wcs: WCS?
    }
    private func displayContext() -> DisplayRenderContext {
        DisplayRenderContext(adjustments: displayAdjustments, wcs: currentWCS)
    }

    /// Current display revision — bumped whenever the pipeline's committed surfaces need
    /// re-rendering. `AppModel` reads it to know when its cached "currently live" preview has
    /// gone stale, so a slider drag can skip re-rendering a pane that cannot have changed.
    public var currentDisplayRevision: UInt64 { displayRevisionLock.withLock { displayRevision } }

    /// Lifecycle of a unit of pipeline work, for measurement tests that must distinguish work
    /// that RAN from work that was scheduled and then superseded. `superseded` means the revision
    /// was overtaken before its render started, so it did no work and consumed no memory — a
    /// measurement that counts it as a completed operation overstates what overlapped.
    public enum WorkProbeEvent: Sendable { case began, finished, superseded }

    /// Phase timings for one display-render request, so waiting can be told apart from rendering
    /// and from repeated invalidation. Instrumentation ONLY — nothing here alters scheduling.
    public enum DisplayRenderPhase: Sendable {
        case requested        // revision claimed by refreshDisplay()
        case workerStarted    // the displayQueue block began executing
        case lockAcquired     // displayRenderLock taken
        case renderBegan      // past the supersession check
        case renderFinished   // render returned, lock about to be released
        case deliveryEmitted  // deliverDisplay passed isCurrentDisplay and fired the callback
        case superseded       // the request was invalidated before rendering
        case diskWriteBegan   // renderSnapshot's recorder.save
        case diskWriteEnded
        case frameLockRequested   // the FRAME path asking for displayRenderLock (revision 0)
        case frameLockAcquired
        case frameLockReleased
    }
    /// nil in production.
    public var displayRenderPhaseProbeForTest: (@Sendable (UInt64, DisplayRenderPhase) -> Void)?

    /// EXPERIMENT: cache of the pre-stretch DBE (flatten) result for the COMMITTED path.
    ///
    /// Keyed by the identity of the source actually rendered, its post-crop dimensions, and the
    /// two DBE parameters. Only native online snapshots participate; watcher and clean-master
    /// renders bypass the cache entirely.
    ///
    /// This cannot accelerate NEW FRAMES — each frame is a different stack, so every frame render
    /// is a miss by construction. The win it targets is narrow and specific: an Apply re-rendering
    /// the SAME source a frame just rendered, which currently repeats ~15 s of DBE.
    private let committedFlattenCache = CommittedFlattenCache()
    /// One locked snapshot; unkeyed renders (watcher, clean, preview, parity oracle) do not count
    /// as cache misses. Individual accessors remain for the existing measurement harnesses.
    var committedFlattenMetrics: CommittedFlattenCache.Metrics { committedFlattenCache.metrics }
    /// Configure before start, on the same thread as start(). No cache object escapes to tests.
    @discardableResult
    func disableCommittedFlattenCacheBeforeStartForTesting() -> Bool {
        guard session.state == .idle else { return false }
        committedFlattenCache.invalidate(retiring: true)
        return true
    }
    public var committedFlattenHitsForTest: Int { committedFlattenCache.metrics.hits }
    public var committedFlattenMissesForTest: Int { committedFlattenCache.metrics.misses }
    /// Test seam: bytes currently retained by the cache (0 when empty).
    public var committedFlattenRetainedBytesForTest: Int {
        committedFlattenCache.metrics.retainedBytes
    }

    /// The FACTS of what actually entered `displayCGImage` — dimensions, channels, colour space
    /// status, and the captured DBE settings. Printing settings alone could not explain a 214 ms
    /// render against a 19.6 s full-resolution measurement; only the actual inputs can.
    public struct RenderInputFacts: Sendable {
        public let revision: UInt64
        public let origin: String
        public let width: Int
        public let height: Int
        public let channels: Int
        public let sourceIsLinear: Bool
        public let backgroundExtraction: Bool
        public let bgScale: Double
        public let bgSmoothest: Double
        public let blackPoint: Double
    }
    public var displayRenderInputProbeForTest: (@Sendable (RenderInputFacts) -> Void)?

    /// What SETTINGS each render actually captured, and where the render came from. Supersession
    /// alone does not explain a delay: if the superseding frame render reads the committed
    /// adjustments, it satisfies the Apply. Deciding that needs the settings per revision and the
    /// render's origin, not just its lifecycle.
    public var displayRenderSettingsProbeForTest:
        (@Sendable (UInt64, DisplayAdjustments, String) -> Void)?

    /// nil in production. Reports display-render lifecycle by revision.
    public var displayRenderProbeForTest: (@Sendable (UInt64, WorkProbeEvent) -> Void)?
    /// nil in production. Reports watcher frame-processing lifecycle by file name.
    public var frameProcessingProbeForTest: (@Sendable (String, WorkProbeEvent) -> Void)?

    /// False from the moment `end()` captures the context its FINAL render will use, not merely
    /// from when the display is torn down.
    ///
    /// Those are far apart: `finalContext` is captured before master processing — a refiner pass
    /// and a full-resolution master write, seconds on a 26 MP session — while `displayFinished`
    /// is set at the very end. An Apply landing in that window committed, cleared its badge and
    /// set `displayAdjustments`, and was then silently overwritten by the final delivery rendering
    /// with the older captured context. Acceptance and capture now flip together.
    public var acceptsDisplayUpdates: Bool {
        displayAcceptanceLock.withLock {
            displayContextFrozen ? false : displayRevisionLock.withLock { !displayFinished }
        }
    }
    /// Guards `displayContextFrozen` AND serialises it against adjustment writes.
    ///
    /// Deliberately NOT the existing `finalizationLock`, which guards `finalizationClaimed` and is
    /// held across reseed and end() work — entangling display acceptance with that would put an
    /// adjustment write inside an unrelated critical section. Ordering here is always
    /// displayAcceptanceLock -> displayRevisionLock / adjLock / plateSolveLock, never the reverse;
    /// nothing holding those calls back into these three entry points.
    private let displayAcceptanceLock = NSLock()
    private var displayContextFrozen = false

    /// Captures the context the final render will use and closes acceptance in ONE critical
    /// section, so no adjustment can be accepted after the context it would have to affect is
    /// already fixed.
    private func freezeDisplayContextForFinalRender() -> DisplayRenderContext {
        displayAcceptanceLock.lock()
        defer { displayAcceptanceLock.unlock() }
        displayContextFrozen = true
        return displayContext()
    }

    /// Takes committed adjustments only if the display is still accepting them, with the check and
    /// the assignment in the SAME critical section. A caller that reads `acceptsDisplayUpdates` and
    /// then assigns separately can be frozen in between — it would report success for a change the
    /// final render then overwrites.
    ///
    /// Returns the display REVISION the resulting render will carry, or nil if the adjustments were
    /// refused. Callers use that revision to know when the change has actually reached the screen:
    /// the committed surfaces re-render asynchronously, and under load (full-resolution DBE while
    /// stacking) that can take tens of seconds, during which anything labelled "currently live" is
    /// showing the PREVIOUS look.
    @discardableResult
    public func applyCommittedAdjustments(_ adjustments: DisplayAdjustments) -> UInt64? {
        displayAcceptanceLock.lock()
        defer { displayAcceptanceLock.unlock() }
        guard !displayContextFrozen, displayRevisionLock.withLock({ !displayFinished }) else {
            return nil
        }
        displayAdjustments = adjustments   // its setter schedules refreshDisplay()
        // Read AFTER the setter: refreshDisplay() has already claimed the revision this change
        // will render under.
        return displayRevisionLock.withLock { displayRevision }
    }

    public func isCurrentDisplay(_ update: DisplayDelivery) -> Bool {
        displayRevisionLock.withLock { update.revision == displayRevision }
    }

    private func nextDisplayRevision() -> UInt64 {
        displayRevisionLock.withLock { displayRevision &+= 1; return displayRevision }
    }

    /// Coalesces non-frame mutations. Revision advances before dispatch, invalidating a render
    /// already in flight; the serial worker resolves the newest source and committed settings.
    public func refreshDisplay() {
        let requested = displayRevisionLock.withLock { () -> UInt64? in
            guard !displayFinished else { return nil }
            displayRevision &+= 1
            return displayRevision
        }
        guard let revision = requested else { return }
        displayRenderPhaseProbeForTest?(revision, .requested)
        displayQueue.async { [weak self] in
            guard let self else { return }
            self.displayRenderPhaseProbeForTest?(revision, .workerStarted)
            self.displayRenderLock.lock()
            self.displayRenderPhaseProbeForTest?(revision, .lockAcquired)
            defer { self.displayRenderLock.unlock() }
            guard self.displayRevisionLock.withLock({ !self.displayFinished && revision == self.displayRevision }) else {
                self.displayRenderProbeForTest?(revision, .superseded)
                self.displayRenderPhaseProbeForTest?(revision, .superseded)
                return
            }
            self.displayRenderProbeForTest?(revision, .began)
            self.displayRenderPhaseProbeForTest?(revision, .renderBegan)
            self.withCallbackDelivery { self.renderDisplayTransition(revision: revision) }
            self.displayRenderPhaseProbeForTest?(revision, .renderFinished)
            self.displayRenderProbeForTest?(revision, .finished)
        }
    }

    private func deliverDisplay(revision: UInt64, preview: CGImage?, broadcast: CGImage?,
                                cleanCount: Int?, count: Int, record: SnapshotRecord? = nil) {
        let update = DisplayDelivery(revision: revision, previewImage: preview,
                                     broadcastImage: broadcast, cleanMasterSubCount: cleanCount,
                                     integrationSeconds: Double(count) * profile.subExposureSeconds,
                                     previewIntegrationSeconds: preview == nil ? 0 : Double(displayOnline?.count ?? count) * profile.subExposureSeconds,
                                     subExposureSeconds: profile.subExposureSeconds,
                                     record: record)
        guard isCurrentDisplay(update) else { return }
        displayRenderPhaseProbeForTest?(revision, .deliveryEmitted)
        onDisplayUpdate?(update)
    }

    private func renderDisplayTransition(revision: UInt64,
        finalBroadcast: (image: AstroImage, count: Int, cleanCount: Int?)? = nil,
        context: DisplayRenderContext? = nil) {
        guard let online = displayOnline,
              online.generation == nil || online.generation == engine?.currentStackGeneration else {
            deliverDisplay(revision: revision, preview: nil, broadcast: nil, cleanCount: nil, count: 0)
            return
        }
        do {
            let context = context ?? displayContext()
            // Probe the context ACTUALLY captured for this render. Reading displayAdjustments
            // separately at the call site could log settings the render did not use, if an Apply
            // landed between the two reads.
            displayRenderSettingsProbeForTest?(revision, context.adjustments, "refresh")
            let preview = try renderOnlineDisplay(online, context: context,
                                                  revision: revision, origin: "refresh")
            if let finalBroadcast {
                let image = online.cap.map { finalBroadcast.image.downsampled(maxLongEdge: $0) } ?? finalBroadcast.image
                let broadcast = try displayCGImage(from: image, context: context)
                deliverDisplay(revision: revision, preview: preview, broadcast: broadcast,
                               cleanCount: finalBroadcast.cleanCount, count: finalBroadcast.count)
                return
            }
            let resolved = try resolveBroadcastRender(onlineMean: online.image, onlinePreviewCG: preview,
                onlineFrameCount: online.count, downsampleLongEdge: online.cap, context: context)
            deliverDisplay(revision: revision, preview: preview, broadcast: resolved.cgImage,
                           cleanCount: resolved.cleanCount, count: resolved.integrationFrames)
        } catch {
            onLog?("Display refresh failed: \(error)")
            // Do not keep claiming a clean image after its source has been invalidated.
            deliverDisplay(revision: revision, preview: nil, broadcast: nil, cleanCount: nil, count: 0)
        }
    }
    /// May be delivered synchronously on the frame-consumer task — same reentrancy rule as
    /// `onUpdate`: end() from inside throws `.reentrantEnd`.
    public var onLog: ((String) -> Void)?
    /// Fired when a live folder watcher's detection stalls (a hung read froze its queue).
    /// The app surfaces it as a prominent alert + notification.
    public var onStall: (() -> Void)?
    /// Called for every frame the stack engine rejects (native mode only). Delivered on
    /// the frame-consumer task — same reentrancy rule as `onUpdate`.
    public var onRejected: ((RejectionReason, String) -> Void)?
    /// Called after each frame is processed (native import mode only). Delivered on the
    /// frame-consumer task — same reentrancy rule as `onUpdate`.
    public var onImportProgress: ((_ processed: Int, _ total: Int,
                                   _ accepted: Int, _ rejected: Int) -> Void)?
    /// Fired once per processed native sub with its measured quality (spec §Data flow).
    /// Same delivery context as onUpdate/onRejected. Watcher mode does not fire this
    /// (no per-sub stacking there).
    public var onSubFrame: ((SubFrameRecord) -> Void)?
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
    private var _plateSolveCatalog: StarCatalog? = StarCatalog.installed()   // guarded by plateSolveLock
    /// The catalog plate-solving uses (the injection seam for tests; `installed()` in production).
    /// Lock-guarded because `reloadCatalog()` may swap it from the UI thread while the frame path reads it.
    var plateSolveCatalog: StarCatalog? {
        get { plateSolveLock.withLock { _plateSolveCatalog } }
        set { plateSolveLock.withLock { _plateSolveCatalog = newValue } }
    }
    /// Test seam: invoked inside `attemptPlateSolveIfNeeded` AFTER the generation is claimed and BEFORE
    /// the reference stars are read, so a test can force a reseed into that exact window and prove no
    /// stale/stuck solve results. nil (no-op) in production.
    var onSolveClaimedForTest: (() -> Void)?

    /// The plate-solved WCS for the current reference frame, or nil if not (yet) solved / no catalog /
    /// missing metadata. 3b reads this to orient the display north-up. Thread-safe.
    public var currentWCS: WCS? { plateSolveLock.withLock { solvedWCS } }

    /// True once the reference frame has been plate-solved — the UI enables the "North up" toggle only
    /// when this is true (no solve → nothing to orient). Thread-safe.
    public var hasSolvedWCS: Bool { plateSolveLock.withLock { solvedWCS != nil } }

    /// Fired whenever the solved-WCS state CHANGES — both edges: a solve landing (`hasSolvedWCS` →
    /// true) and an invalidation from manual/auto reseed (→ false). The UI recomputes the North-up
    /// toggle's availability from `hasSolvedWCS` here, since neither edge emits a display update of its
    /// own (the solve runs off the hot path; reseed just clears state). May fire on a background queue.
    public var onSolveStateChanged: (() -> Void)?

    /// Fired after a refiner pass installs a SERVABLE clean master. The staged preview needs it
    /// because `AppModel.liveRejectionStatus` is computed with no change notification, so there
    /// is no transition to observe: without this the preview would keep showing the online
    /// master after the first clean one publishes.
    public var onCleanMasterPublished: (() -> Void)?

    /// Void the stored/in-flight solve and re-enable solving so the NEXT reference re-solves. Called
    /// on BOTH reseed paths — manual `reseed()` and the engine's internal auto-reseed. The generation
    /// bump discards any in-flight solve that lands after this point.
    private func invalidatePlateSolve() {
        plateSolveLock.withLock { solvedWCS = nil; solveAttempted = false; solveGeneration += 1 }
        onSolveStateChanged?()   // negative edge: reseed/auto-reseed dropped the solve — refresh the gate
        refreshDisplay()
    }

    /// Re-read the installed catalog (call after a catalog download completes) and void any prior solve
    /// state, so the current reference re-solves against the freshly-available catalog with no app
    /// restart. A no-op-safe: if nothing is installed, plateSolveCatalog becomes nil and plate-solve
    /// stays the usual no-op.
    public func reloadCatalog() {
        plateSolveCatalog = StarCatalog.installed()
        invalidatePlateSolve()
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
            let stored = self.plateSolveLock.withLock { () -> Bool in
                guard gen == self.solveGeneration else { return false }
                self.solvedWCS = wcs; return true
            }
            // Notify OUTSIDE the lock so the UI can enable the North-up toggle the moment the solve lands.
            if stored { self.onSolveStateChanged?(); self.refreshDisplay() }
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

    // MARK: SubRegistration cache (Task 5)
    //
    // Thread-safe cache of per-sub registration payloads so a later background refiner
    // (Task 6) can reuse each accepted sub's transform/leveling/scale without re-registering.
    // Keyed by `subIndex` (== `processedCount`, the monotonic per-sub ID also used for
    // SubFrameRecord.index) — an ARRAY in capture order, NOT a FileIdentity/digest dict, so
    // byte-identical subs still produce distinct entries.
    private let regLock = NSLock()
    private var _subRegistrations: [SubRegistration] = []          // guarded by regLock
    private var _userRejected: Set<Int> = []                       // guarded by regLock; subIndexes

    /// Test seam: the captured registrations in capture order. Thread-safe.
    func subRegistrations() -> [SubRegistration] {
        regLock.withLock { _subRegistrations }
    }

    /// The pipeline's own reject set (subIndexes), distinct from AppModel's UI array —
    /// AppModel pushes the flagged subIndexes here (Task 11). Bumps `userRejectGeneration`
    /// (part of `FreshnessKey`) and recomputes the cached key so a previously-published
    /// master immediately goes stale. Thread-safe. `public` so `AppModel.toggleReject`
    /// (a separate module) can call it — Task 8 left this `internal`, callable only from
    /// `@testable import` test code, which would not compile from `LiveAstroStudio`.
    public func setUserRejected(_ ids: Set<Int>) {
        regLock.withLock {
            _userRejected = ids
            userRejectGeneration += 1
            recomputeCachedFreshnessKeyLocked()
        }
        refreshDisplay()
    }

    // MARK: Task 8 invalidation hooks — trigger the background GlobalRefiner
    //
    // Each hook is a named mutation point: it (re)establishes the cached `_freshnessKey` under
    // `regLock` if it hasn't already been done at the call site, THEN notifies the refiner
    // OUTSIDE the lock (`noteChanged()` itself never blocks, but keeping the notify out of the
    // lock avoids growing `regLock`'s critical section for no reason). `currentRefiner()` is nil
    // until live rejection is first enabled (see `configureLiveRejection` below) — every hook is
    // therefore a safe no-op for feature-OFF parity: no refiner activity, no published master.

    /// The lazily-created background refiner, or nil before live rejection has ever been enabled
    /// this session. Thread-safe.
    private func currentRefiner() -> GlobalRefiner? { regLock.withLock { _globalRefiner } }

    /// Review P2/P3: the refiner to NOTIFY — nil while the feature is OFF, so the invalidation
    /// hooks (`noteSubAccepted` / `noteUserRejectChanged` / `noteReseeded`) start no background
    /// work once the user has turned live rejection off (the cache still updates; only the
    /// trigger is suppressed). `configureLiveRejection` notifies through its own captured
    /// reference when the feature turns ON, so enable-ON-mid-session still builds immediately.
    private func activeRefiner() -> GlobalRefiner? {
        regLock.withLock { liveRejectionActive ? _globalRefiner : nil }
    }

    /// Test seam (review P2/P3): the owned refiner regardless of enabled state, so a test can
    /// observe `passesRun` and prove the invalidation hooks start NO pass while the feature is
    /// off — and that enable-ON still does. Mirrors the other `...ForTest` seams; not for product code.
    func refinerForTest() -> GlobalRefiner? { currentRefiner() }

    /// Test seam: the owned engine, so a test can read the online stack directly. Mirrors
    /// `refinerForTest()`; not for product code.
    var engineForTest: StackEngine? { engine }

    /// Survivor count of the clean master that would be SERVED right now, or nil if none is
    /// current. The caption needs this rather than `currentSurvivorCount()`: the two differ
    /// exactly when a pass hasn't published yet, which is precisely the state the operator
    /// otherwise cannot distinguish from a working one (the broadcast looks the same either way).
    public func publishedMasterSurvivorCount() -> Int? {
        regLock.withLock {
            guard liveRejectionActive, let pm = publishedMaster,
                  pm.key.isServable(against: _freshnessKey) else { return nil }
            return pm.survivorCount
        }
    }

    /// The FreshnessKey of the clean master currently being SERVED, or nil if none is. The
    /// preview proxy cache keys `.clean` on this so a kappa change or a user reject invalidates
    /// it — generation and sub count would both miss those.
    func publishedMasterFreshnessKeyIfCurrent() -> FreshnessKey? {
        regLock.withLock {
            guard liveRejectionActive, let pm = publishedMaster,
                  pm.key.isServable(against: _freshnessKey) else { return nil }
            return pm.key
        }
    }

    /// Survivor count of the CURRENT stack generation, minus user-rejected subs — what the
    /// refiner actually combines. For the operator caption (review P3): the app-side count of
    /// all accepted records kept counting pre-reseed subs the refiner had already discarded.
    /// Reads the engine generation first (engine lock, released) and only then takes `regLock`
    /// — the established leaf ordering; never nests them.
    public func currentSurvivorCount() -> Int {
        let gen = engine?.currentStackGeneration ?? 0
        return regLock.withLock { currentSurvivorsLocked(currentGeneration: gen).count }
    }

    /// Called from `handleNative` POST-COMMIT, only when a `SubRegistration` was actually
    /// appended (an accepted sub with a registration payload). The T7 sub-append block already
    /// recomputes `_freshnessKey` there — this hook does NOT recompute again (would double the
    /// work every single sub); it only notifies.
    func noteSubAccepted() {
        activeRefiner()?.noteChanged()
    }

    /// User-reject-set-change notification hook (Task 11's `AppModel.toggleReject` calls this,
    /// not the refiner directly). Bumps `userRejectGeneration` and recomputes the cached key —
    /// mirrors what `setUserRejected` already does for its own callers, so calling both back to
    /// back (the expected Task 11 usage: `setUserRejected(ids)` then `noteUserRejectChanged()`)
    /// double-bumps the generation. That's harmless: `userRejectGeneration` only needs to differ
    /// from whatever a previously-stamped `FreshnessKey` recorded, not increment exactly once per
    /// logical event. `public` for the same cross-module reason as `setUserRejected` above.
    public func noteUserRejectChanged() {
        regLock.withLock {
            userRejectGeneration += 1
            recomputeCachedFreshnessKeyLocked()
        }
        activeRefiner()?.noteChanged()
        refreshDisplay()
    }

    /// Reseed notification hook. `reseed()` itself already bumps the engine's generation and
    /// recomputes the cached key (T7 review fix) before calling this — so this hook only
    /// notifies, avoiding a double recompute.
    func noteReseeded() {
        activeRefiner()?.noteChanged()
        refreshDisplay()
    }

    /// Subs of `currentGeneration`, minus any `subIndex` the user has flagged, in capture
    /// order. Locks `regLock` — do NOT call from a context already holding it (use
    /// `currentSurvivorsLocked` there instead, or it deadlocks the non-recursive NSLock).
    func currentSurvivors(currentGeneration: Int) -> [SubRegistration] {
        regLock.withLock { currentSurvivorsLocked(currentGeneration: currentGeneration) }
    }

    /// Same as `currentSurvivors`, but assumes the caller already holds `regLock` (e.g. the
    /// Task 8 snapshot). No locking — calling `currentSurvivors` instead here re-enters the
    /// non-recursive NSLock and deadlocks.
    func currentSurvivorsLocked(currentGeneration: Int) -> [SubRegistration] {
        _subRegistrations.filter { $0.stackGeneration == currentGeneration && !_userRejected.contains($0.subIndex) }
    }

    // MARK: FreshnessKey + publishedMaster (Task 7)
    //
    // A later background refiner (Task 6, GlobalRefiner) recombines the current survivor set
    // off the hot path and publishes a trail-free master here. Broadcast/end() must consume it
    // ONLY while it is still current — not stale after a reseed, a user reject, or a κ change —
    // AND only while the live-rejection feature is on. `FreshnessKey` is the composite identity
    // that pins all of that; `_freshnessKey` is a CACHE (M1) refreshed at every mutation point
    // so the per-render broadcast path (`currentFreshnessKey()`) never re-sorts N survivor ids.
    private var userRejectGeneration: Int = 0                      // guarded by regLock; part of FreshnessKey
    /// Live-rejection feature gate (Task 11 wires this from AppModel via `configureLiveRejection`).
    /// Deliberately NOT encoded in `FreshnessKey` — see `publishedMasterIfCurrent`.
    private var liveRejectionActive: Bool = false                  // guarded by regLock
    /// κ (sigma-clip multiple) the background refiner combines survivors with — part of
    /// `FreshnessKey` so a κ change invalidates any published master computed with the old κ.
    /// Defaults to `RejectionStrength.medium.kappa`: the engine's own `RejectionMethod` is a
    /// private, non-introspectable instance (no public κ accessor), so there is no single
    /// "current engine value" to read at init; Task 11's `configureLiveRejection(kappa:)` sets
    /// the real value from `SessionSettings.rejectionStrength.kappa` once AppModel wires it.
    private var liveRejectionKappa: Float = RejectionStrength.medium.kappa   // guarded by regLock
    /// Cached composite key (M1) — refreshed by `recomputeCachedFreshnessKeyLocked()` at every
    /// mutation point (sub appended, `setUserRejected`, κ change, generation change). Given a
    /// sensible pre-first-sub initial value so `currentFreshnessKey()` is well-defined from t=0.
    private var _freshnessKey = FreshnessKey(stackGeneration: 0, survivorSubIndices: [],
                                             userRejectGeneration: 0, kappa: RejectionStrength.medium.kappa,
                                             maxSampleBytes: GlobalRefiner.defaultMaxSampleBytes,
                                             liveRejectionEpoch: 0)

    /// Bumped on every live-rejection enable-state transition and folded into `FreshnessKey`, so
    /// each contiguous ON period is distinguishable from every earlier one — see the key's own
    /// `liveRejectionEpoch` doc for the OFF→ON race it closes. Guarded by `regLock`.
    private var liveRejectionEpoch: Int = 0
    /// The background refiner's most recently published trail-free master, stamped with the
    /// `FreshnessKey` it was computed from. `internal` — Task 6/11 publish here directly (and
    /// tests construct/inspect it via `@testable import`, which requires `internal`+, not
    /// `private` — a `private` property is invisible outside this file regardless of
    /// `@testable`).
    internal var publishedMaster: PublishedMaster?   // guarded by regLock
    /// RAM sample budget (bytes) the background refiner combines survivors with. Part of
    /// `FreshnessKey` alongside κ (review P2), so a budget change invalidates any published
    /// master via the key comparison — including one an in-flight pass publishes LATER under the
    /// key it snapshotted before the change. `configureLiveRejection` additionally clears
    /// `publishedMaster` on a budget change as belt-and-suspenders (see below).
    private var liveRejectionMaxSampleBytes: Int = GlobalRefiner.defaultMaxSampleBytes   // guarded by regLock
    /// Quorum floor for the background refiner (both the materialized RAM sample and the final
    /// survivor count) — same value as the Task 11 online gate. Not currently configurable via
    /// `configureLiveRejection` (no brief-specified setter), so a plain constant.
    private let liveRejectionMinSubs: Int = GlobalRefiner.defaultMinSubs
    /// Task 8: the background refiner, OWNED by the pipeline and created LAZILY on the first
    /// `configureLiveRejection(enabled: true, ...)` call — never before. This is the ownership/
    /// lifetime choice that keeps feature-OFF parity trivially true: every Task 8 invalidation
    /// hook (`noteSubAccepted`/`noteUserRejectChanged`/`noteReseeded`) calls
    /// `activeRefiner()?.noteChanged()` — if live rejection has never been turned on this
    /// session, `_globalRefiner` is nil, so those calls are no-ops: zero refiner queue activity,
    /// zero published master, byte-identical output to today. Review P2/P3 added the second
    /// layer: `activeRefiner()` is ALSO nil while the feature is currently OFF, so a refiner
    /// created earlier in the session does no hidden reload/warp/combine work after the user
    /// turns the feature off (its output would have been hidden anyway; its CPU/I/O was not).
    /// (Holding a refiner for the whole session and gating its activity on
    /// `liveRejectionActive` inside each hook would work too, but would need that check
    /// duplicated at every call site instead of centralized in one nil check here.)
    private var _globalRefiner: GlobalRefiner?   // guarded by regLock
    /// Test seam: overrides the `FrameLoader` used when `_globalRefiner` is lazily created (nil =
    /// production `ProductionFrameLoader`). Must be set BEFORE the first
    /// `configureLiveRejection(enabled: true, ...)` call to take effect.
    var refinerLoaderOverride: FrameLoader?
    /// Task 10: the time budget for the ONE synchronous final refiner pass `end()` runs when
    /// live rejection is active but no published master is current at shutdown (e.g. the last
    /// accepted sub's background pass hadn't finished/published yet). This is the ONLY bound on
    /// that final pass — step 4 already cancelled any in-flight background pass, so nothing else
    /// cancels it; `refine`'s own between-sub deadline check (C3) aborts at this bound and `end()`
    /// falls back to the online master, so `end()` can never hang on a wedged/slow final pass.
    /// Distinct from `GlobalRefiner.passBudget` (the background trigger's own, longer, budget) —
    /// this one gates end() itself, so it defaults shorter: long enough for a modest stack the
    /// background pass hasn't yet caught up on, short enough that shutdown still feels bounded.
    /// Internal so tests can shrink it (hang-safety test, C3).
    var finalRefineBudget: DispatchTimeInterval = .seconds(30)
    /// Test seam (cold-review wedged-read fix): overrides `GlobalRefiner.perSubLoadCap` on the
    /// lazily-created `_globalRefiner`, so a shutdown test can shrink the per-sub bounded-load
    /// wait far below `finalRefineBudget` and still run fast. nil = leave `GlobalRefiner`'s own
    /// default. Must be set BEFORE the first `configureLiveRejection(enabled: true, ...)` call
    /// (same timing requirement as `refinerLoaderOverride`).
    var refinerPerSubLoadCapOverride: DispatchTimeInterval?

    /// Recompute `_freshnessKey` from the current generation/survivors/reject-generation/κ.
    /// Assumes the caller already holds `regLock` — calling `currentFreshnessKey()` (or any
    /// other locking accessor) from here re-enters the non-recursive NSLock and deadlocks.
    private func recomputeCachedFreshnessKeyLocked() {
        let gen = engine?.currentStackGeneration ?? 0
        let survivors = currentSurvivorsLocked(currentGeneration: gen).map(\.subIndex).sorted()
        _freshnessKey = FreshnessKey(stackGeneration: gen, survivorSubIndices: survivors,
                                     userRejectGeneration: userRejectGeneration, kappa: liveRejectionKappa,
                                     maxSampleBytes: liveRejectionMaxSampleBytes,
                                     liveRejectionEpoch: liveRejectionEpoch)
    }

    /// O(1) locked read of the cached key (M1) — the broadcast-preference path calls this once
    /// per render instead of re-sorting N survivor ids. Code already holding `regLock` (e.g. the
    /// Task 8 snapshot) reads `_freshnessKey` directly instead of calling this.
    public func currentFreshnessKey() -> FreshnessKey { regLock.withLock { _freshnessKey } }

    /// Live-rejection config gate (Task 11 wires this from AppModel) — the ONE config-change
    /// invalidation path (brief §Task 8). Every parameter is optional and defaults to "leave
    /// unchanged", so the Task 7 single-parameter call sites (`configureLiveRejection(enabled:)`,
    /// `configureLiveRejection(kappa:)`) still compile and behave exactly as before against this
    /// widened signature — no call-site adaptation needed.
    ///
    /// Under `regLock`: compute old-vs-new enabled/κ/budget, update the three stored fields,
    /// recompute `_freshnessKey` (κ AND the sample budget are both part of the key, so either
    /// change alone already invalidates any published master via the key comparison — and,
    /// review P2, also invalidates a master an in-flight pass publishes LATER under the key it
    /// snapshotted before the change), and explicitly CLEAR a now-stale `publishedMaster` when
    /// the feature just went OFF or the budget changed (belt-and-suspenders on top of the key —
    /// the OFF case is what the key cannot express). Lazily creates `_globalRefiner` the first time
    /// `enabled` turns (or is passed) true. `shouldNotify` is computed UNDER the lock from
    /// lock-guarded state — never read again after releasing — then the refiner is notified
    /// OUTSIDE the lock. `enabledRose` (OFF→ON, survivors already present) is the key case: it
    /// must trigger a build immediately, not wait for the next sub/reject/reseed.
    public func configureLiveRejection(enabled: Bool? = nil, kappa: Float? = nil, maxSampleBytes: Int? = nil) {
        var shouldNotify = false
        var refinerToNotify: GlobalRefiner?
        var refinerToCancel: GlobalRefiner?
        regLock.withLock {
            let oldEnabled = liveRejectionActive
            let oldKappa = liveRejectionKappa
            let oldBudget = liveRejectionMaxSampleBytes
            let newEnabled = enabled ?? oldEnabled
            let newKappa = kappa ?? oldKappa
            let newBudget = maxSampleBytes ?? oldBudget

            let enabledRose = !oldEnabled && newEnabled
            let enabledFell = oldEnabled && !newEnabled
            let kappaChanged = newKappa != oldKappa
            let budgetChanged = newBudget != oldBudget

            liveRejectionActive = newEnabled
            liveRejectionKappa = newKappa
            liveRejectionMaxSampleBytes = newBudget
            // Review P3: a transition in EITHER direction opens a new epoch, so the key of the
            // period being left can never equal the key of any later one. Bumped before the
            // recompute below so the new key carries it.
            if enabledRose || enabledFell { liveRejectionEpoch += 1 }
            recomputeCachedFreshnessKeyLocked()
            if !newEnabled || budgetChanged {
                publishedMaster = nil   // belt-and-suspenders on top of the key: OFF is what the key can't express
            }
            if newEnabled, _globalRefiner == nil {
                _globalRefiner = makeRefinerLocked()
            }
            shouldNotify = newEnabled && (enabledRose || kappaChanged || budgetChanged)
            if shouldNotify { refinerToNotify = _globalRefiner }
            // Follow-on review P2: "off" must mean STOP WORKING NOW, not just "hide the output".
            // Gating the hooks/snapshot stops FUTURE passes, but a pass that already captured its
            // snapshot keeps loading/warping/combining until it naturally finishes — for minutes
            // on real 26 MP data — after the user turned the feature off precisely because it was
            // burning CPU/I/O. Cancel it: the pass observes the stop between loads (and within
            // one bounded load), unwinds to nil, and never publishes.
            if enabledFell { refinerToCancel = _globalRefiner }
        }
        // Both outside regLock: cancel() takes only the refiner's passLock, noteChanged() only its
        // triggerLock — neither needs (or may re-enter) regLock.
        refinerToCancel?.cancel()
        if shouldNotify { refinerToNotify?.noteChanged() }
        refreshDisplay()
    }

    /// Builds a `GlobalRefiner` and wires its Task 8 closures back into the pipeline. Assumes the
    /// caller already holds `regLock` (only ever called from inside `configureLiveRejection`) —
    /// constructing the loader/closures here does not itself re-enter `regLock` or block.
    private func makeRefinerLocked() -> GlobalRefiner {
        let demosaic = engine?.demosaicMethod ?? .bilinear
        // T8 review fix: pass the calibrator LAZILY (a closure re-read at pass time), not baked
        // in here at refiner-creation time — see ProductionFrameLoader's doc for why. `[weak
        // self]` because the loader can outlive a single pipeline reference in principle; nil
        // (uncalibrated) is the same safe fallback `effectiveCalibrator` itself uses elsewhere.
        let loader: FrameLoader = refinerLoaderOverride
            ?? ProductionFrameLoader(calibratorProvider: { [weak self] in self?.effectiveCalibrator },
                                     demosaic: demosaic)
        let refiner = GlobalRefiner(loader: loader, onLog: { [weak self] msg in self?.onLog?(msg) })
        if let cap = refinerPerSubLoadCapOverride { refiner.perSubLoadCap = cap }
        refiner.makeSnapshot = { [weak self] in self?.makeRefinerSnapshot() }
        refiner.publish = { [weak self] result, key in self?.publishRefineResult(result, key: key) }
        refiner.kappaProvider = { [weak self] in self?.currentLiveRejectionKappa() ?? GlobalRefiner.defaultKappa }
        refiner.maxSampleBytesProvider = { [weak self] in
            self?.currentLiveRejectionMaxSampleBytes() ?? GlobalRefiner.defaultMaxSampleBytes
        }
        refiner.minSubsProvider = { [weak self] in self?.liveRejectionMinSubs ?? GlobalRefiner.defaultMinSubs }
        return refiner
    }

    private func currentLiveRejectionKappa() -> Float { regLock.withLock { liveRejectionKappa } }
    private func currentLiveRejectionMaxSampleBytes() -> Int { regLock.withLock { liveRejectionMaxSampleBytes } }

    /// The `GlobalRefiner.makeSnapshot` seam — implements the stale-result race fix (brief
    /// §"Stale-result race", exact order): (1) read the engine's CURRENT stack generation FIRST,
    /// its own lock, released immediately — never hold `regLock` while touching the engine lock;
    /// (2) under `regLock`, snapshot the survivors for that generation (non-locking variant — we
    /// already hold the lock) and the CACHED `_freshnessKey` FIELD directly (never
    /// `currentFreshnessKey()` — it re-acquires `regLock` and deadlocks); (3) release `regLock`,
    /// then RE-READ the engine's generation — if it changed, a reseed raced the snapshot: discard
    /// (return nil). The reseed that caused the race already called `noteReseeded()` →
    /// `noteChanged()`, so `dirty` is set and a fresh pass follows.
    private func makeRefinerSnapshot() -> PassSnapshot? {
        guard let engine else { return nil }
        let capturedGen = engine.currentStackGeneration
        let snap: ([SubRegistration], FreshnessKey)? = regLock.withLock {
            // Review P2/P3: a pass that starts while the feature is OFF must do no work. Its output
            // would be hidden by publishedMasterIfCurrent() anyway, but the reload/warp/combine
            // CPU + I/O would still burn while the user believes the feature is off.
            guard liveRejectionActive else { return nil }
            return (currentSurvivorsLocked(currentGeneration: capturedGen), _freshnessKey)
        }
        guard let snap else { return nil }
        let (capturedSurvivors, capturedKey) = snap
        guard engine.currentStackGeneration == capturedGen else { return nil }   // reseed raced the snapshot
        return PassSnapshot(survivors: capturedSurvivors, currentGeneration: capturedGen, key: capturedKey)
    }

    /// The `GlobalRefiner.publish` seam — installs a completed pass's result stamped with the
    /// SNAPSHOT's own key (never a freshly-read one — see `makeRefinerSnapshot` doc and the
    /// stale-result race fix). Stores ONLY while the feature is on AND the key is still current
    /// (follow-on review P3): turning the feature OFF clears `publishedMaster` under `regLock`
    /// and cancels the in-flight pass OUTSIDE it, so a pass already at its publish call could
    /// slip in between and re-fill the slot while disabled — hidden by
    /// `publishedMasterIfCurrent()`, but it broke the "OFF clears publishedMaster" invariant and
    /// could be served immediately on a quick re-enable if nothing had moved the key. Likewise a
    /// result whose snapshot key a reject/κ/reseed/budget change has already moved past is stale
    /// on arrival; the mutation that moved the key already triggered its own fresh pass, so it
    /// is dropped rather than stored-then-refused.
    private func publishRefineResult(_ result: RefineResult, key: FreshnessKey) {
        let installed = regLock.withLock { () -> Bool in
            // Servable-not-identical (see FreshnessKey.isServable): subs that landed while this
            // pass ran must NOT discard its result, or a live session never publishes at all.
            guard liveRejectionActive, key.isServable(against: _freshnessKey) else { return false }
            publishedMaster = PublishedMaster(image: result.image, coverage: result.coverage,
                                              survivorCount: result.survivorCount, key: key)
            return true
        }
        if installed {
            refreshDisplay()              // committed surfaces, via DisplayDelivery
            onCleanMasterPublished?()     // pending draft preview may need to switch source
        }
    }

    /// Returns the published master ONLY while the live-rejection feature is ON and its stored
    /// key still equals the CURRENT freshness key — i.e. none of a reseed, a user reject, a κ
    /// change, a sample-budget change, or an enable-state transition (the epoch) has landed
    /// since it was published. Both reads happen under one `regLock` acquisition so a concurrent
    /// publish/mutation can't be observed torn.
    public func publishedMasterIfCurrent() -> (image: AstroImage, coverage: [Float], survivorCount: Int)? {
        regLock.withLock {
            guard liveRejectionActive, let pm = publishedMaster,
                  pm.key.isServable(against: _freshnessKey) else { return nil }
            return (image: pm.image, coverage: pm.coverage, survivorCount: pm.survivorCount)
        }
    }

    private let adjLock = NSLock()
    private var _displayAdjustments = DisplayAdjustments.neutral
    /// Display-path adjustments. Read once per render; lock-guarded because the
    /// frame loop and the live re-render access it from different threads.
    public var displayAdjustments: DisplayAdjustments {
        get { adjLock.lock(); defer { adjLock.unlock() }; return _displayAdjustments }
        set {
            adjLock.lock(); _displayAdjustments = newValue; adjLock.unlock()
            refreshDisplay()
        }
    }

    private let watcher: StackFileWatcher?
    private var source: FrameSource?
    private var engine: StackEngine?
    private let profile: SessionProfile
    private let replaySettings: ReplaySettings
    private let maxKeyframes: Int
    private let neutralizeBackground: Bool
    private let calibrator: Calibrator?
    /// Native-only fallback: resolves a Calibrator from the FIRST frame's header
    /// metadata when no explicit `calibrator` was supplied — e.g. a live session
    /// started on an empty folder, where the lights' camera/gain/exposure aren't
    /// known until the first sub lands. Called at most once, on the serial consume
    /// task inside handleNative, so its state needs no extra locking.
    private let calibratorProvider: ((SourceMetadata) -> Calibrator?)?
    private var providerCalibrator: Calibrator?
    private var providerAttempted = false
    /// The calibrator the pipeline ACTUALLY applied to frames before stacking: the
    /// explicit `calibrator` if one was supplied, otherwise the one lazily auto-resolved
    /// from the first frame's metadata (`providerCalibrator`). This is the calibrator a
    /// post-session re-stack must reuse — rebuilding one from legacy config paths would
    /// overwrite a calibrated master.fit with an uncalibrated one. `Calibrator.apply` is
    /// NSLock-guarded, so the returned instance is safe to call off the main actor.
    public var effectiveCalibrator: Calibrator? { calibrator ?? providerCalibrator }
    /// The astronomical source metadata (RA/DEC/FOCALLEN/…) the pipeline resolved from the
    /// first frame's FITS header — the same value stamped into master.fit by end()/
    /// writeMasterSnapshot. Captured by the app layer before the pipeline is released so a
    /// post-session re-stack writes a master with the SAME metadata as the live one, instead
    /// of a bare header (Fix P1b). Nil = no metadata was resolved this session.
    public var capturedSourceMetadata: SourceMetadata? { sourceMetadata }
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
    /// Live/watcher analogue of `importPrimaryTimeout`: the "no finalized frame for this long →
    /// the consumer is wedged" window for the LIVE drain (`drainConsumeTaskOrThrow`). It is
    /// deliberately NOT `drainPrimaryTimeout` (the 10 s stop budget): a single healthy 26 MP sub
    /// takes ~12 s+ to finalize (register + warp + full-res snapshot encode — see the
    /// importPrimaryTimeout note), so keying the wedge check on the 10 s stop budget cancels a
    /// healthy slow frame and discards the master — the exact failure this fix exists to cure
    /// (2026-08-28 ASI2600 real-data run + cold review). 120 s tolerates the slowest single frame
    /// while still catching a genuinely wedged consumer. Internal so tests can shrink it.
    var liveDrainStallTimeout: DispatchTimeInterval = .seconds(120)
    /// Long-edge cap for the import preview/snapshot render (Approach B): finalizeCommitted
    /// downsamples the stacked image to this before displayCGImage so the neutralize/stretch
    /// passes don't run on all 26 MP. Defaults to the SnapshotRecorder cap; internal so tests
    /// can shrink it to keep the call-site test off a full-size frame.
    var importPreviewLongEdge = SnapshotRecorder.maxSnapshotLongEdge
    /// Long edge the STAGED PREVIEW renders at. A 26 MP 6236x4159 stack lands ~1200x800, so a
    /// slider drag re-renders ~1 MP instead of 26 MP. Downsampling (not cropping) is what keeps
    /// the preview honest: it preserves both the statistics `AutoStretch` derives its transform
    /// from and DBE's dimension-relative radius (`BackgroundExtraction.swift:281`).
    /// Long edge the STAGED PREVIEW renders at.
    ///
    /// Raised from 1200 after driving the real app: at 1200 a 6236x4159 stack downsamples ~6x, and
    /// operations with a FIXED-PIXEL kernel — the denoiser above all — then cover 6x more sky than
    /// they will at full resolution, so the preview looked visibly softer than what Apply produces.
    /// (The earlier honesty test only proved the STRETCH survives downsampling; it never covered
    /// denoise or DBE, which is how that shipped.) At 2400 the factor drops to ~2.6x, which both
    /// shrinks that discrepancy and gives the panel enough pixels to judge denoise and DBE at all.
    /// Still a small fraction of a 26 MP render, so a slider drag stays cheap.
    static let previewLongEdge = 2400
    /// Long edge used while the operator is actively DRAGGING. Interaction and fidelity pull in
    /// opposite directions: 2400 puts a settled preview MUCH closer to the broadcast than 1200
    /// does (measured curve gap 5.98/255 vs 38.89/255 on a noisy fixture; a fixed-pixel denoise
    /// kernel also covers ~3x more sky instead of ~6x) — closer, not equal, since the stretch is
    /// still derived from the proxy. But 2400 is 4x the pixels of 1200, and this app is
    /// already CPU-bound on a 26 MP live session. So a drag renders cheap and the SETTLED image
    /// renders sharp — the coalesced trailing render, Apply, Revert, blink and new frames all use
    /// the full-quality path.
    static let previewDraftLongEdge = 1200

    public enum PreviewQuality {
        case draft      // mid-drag: cheap, refreshed continuously
        case settled    // the image the operator actually judges
        var longEdge: Int { self == .draft ? SessionPipeline.previewDraftLongEdge : SessionPipeline.previewLongEdge }
    }
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
        self.calibratorProvider = nil
    }

    /// Native stacking mode: pulls raw frames from a FrameSource, stacks them with StackEngine,
    /// and records each accepted frame as a snapshot.
    public init(nativeSource: FrameSource, engine: StackEngine, profile: SessionProfile,
                rootDirectory: URL, replaySettings: ReplaySettings = .init(),
                maxKeyframes: Int = FrameSelector.defaultMaxKeyframes,
                neutralizeBackground: Bool = false, calibrator: Calibrator? = nil,
                calibratorProvider: ((SourceMetadata) -> Calibrator?)? = nil) {
        self.watcher = nil
        self.source = nativeSource
        self.engine = engine
        self.profile = profile
        self.session = SessionManager(rootDirectory: rootDirectory)
        self.replaySettings = replaySettings
        self.maxKeyframes = maxKeyframes
        self.neutralizeBackground = neutralizeBackground
        self.calibrator = calibrator
        self.calibratorProvider = calibratorProvider
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
        let result = finalizationLock.withLock { () -> ReseedResult in
            guard !finalizationClaimed else {
                return finalizationFailedAfterClaim ? .finalizationRetryPending : .finalizationInProgress
            }
            guard source?.isFinite != true else { return .unavailableDuringImport }
            engine.reseed()
            return .reseeded
        }
        // Task 7 review fix: a manual reseed is a FreshnessKey mutation point (generation change)
        // just like a sub append / setUserRejected / kappa change — refresh the cached key so
        // publishedMasterIfCurrent() stops serving the pre-reseed master immediately, without
        // waiting for the next accepted frame to happen to refresh it. Done AFTER finalizationLock
        // is released (not nested inside it) to match the only other path that nests locks around
        // recomputeCachedFreshnessKeyLocked() — the sub-append path in handleNative, which takes
        // ONLY regLock (recomputeCachedFreshnessKeyLocked reads engine.currentStackGeneration,
        // which independently acquires+releases the engine's own `lock`; the engine never calls
        // back into the pipeline, so regLock -> engine.lock is a one-way leaf edge, not a cycle).
        // No other path holds engine.lock while waiting on regLock, so this ordering is safe.
        // By this point engine.reseed() (inside the block above) has already bumped the engine's
        // generation, so the recompute observes the POST-reseed generation.
        if result == .reseeded {
            committedFlattenCache.invalidate(minimumGeneration: engine.currentStackGeneration)
            // Correctness-wave defect 3: recompute the freshness key FIRST, before
            // invalidatePlateSolve() fires onSolveStateChanged. onSolveStateChanged is a public
            // callback (AppModel hops it onto the main actor and calls refreshPreview) — it runs
            // async, on a different thread, with no synchronization back to this one, so calling
            // it before the recompute let that render observe the PRE-reseed freshness key and
            // serve the clean master this reseed has just invalidated, with nothing later
            // guaranteed to correct it (the triggering frame is itself rejected). Recomputing
            // first means publishedMasterIfCurrent() already refuses the stale master by the time
            // any callback can act on it.
            regLock.withLock { recomputeCachedFreshnessKeyLocked() }
            // Void any stored/in-flight solve so the new reference re-solves against its (fresh)
            // stars. sourceMetadata is left as-is: reseed is a same-target re-establish (center
            // unchanged), and it's owned by the serial frame-processing path — clearing it here
            // would race that writer. (New-target metadata re-capture is out of 3a scope.)
            // Cold-review MINOR fix: moved OUTSIDE finalizationLock (matches the AUTO-reseed path
            // below, which already calls this with no lock held) — invalidatePlateSolve() calls
            // the user's onSolveStateChanged? closure, and calling out to a UI closure under a
            // non-recursive lock is a latent self-deadlock trap (e.g. a re-entrant reseed() call
            // from inside that closure). No other behavior change: this still only runs once, only
            // on the .reseeded outcome, and engine.reseed() has already run by this point.
            invalidatePlateSolve()
            // Task 8: notify the background refiner AFTER the recompute above (this hook does not
            // recompute again — reseed already did). A no-op when live rejection has never been
            // enabled this session.
            noteReseeded()
        }
        return result
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
            bumpPreviewStackRevision()
            lastCommitted = (sourceName, timestamp)       // remembered for end()'s guaranteed final render
            if shouldRenderImport(acceptedIndex: index) {
                renderSnapshot(index: index, sourceName: sourceName, timestamp: timestamp, engine: engine)
            }
            if let total = source?.totalCount {
                onImportProgress?(processedCount, total, engine.acceptedCount, engine.rejectedCount)
            }
        }
    }

    /// BROADCAST/latest.png (Task 9, extracted D10): prefer the background refiner's clean
    /// published master when it's still current (the T7 freshness gate — reject/κ/reseed/
    /// feature-off all invalidate it inside `publishedMasterIfCurrent()` itself); otherwise fall
    /// back to the SAME online source the caller already rendered for its preview, reusing that
    /// render rather than paying the display pipeline twice on the common (no-clean-master) path.
    /// `onlineMean`/`onlinePreviewCG` are the caller's already-cropped-to-coverage online mean and
    /// its already-rendered preview image; `onlineFrameCount` is the engine's frame-count fallback
    /// for `integrationFrames`. `downsampleLongEdge`, when non-nil, is applied to the
    /// published-master branch exactly as the caller applied it to its own online branch — this is
    /// the ONE asymmetry between the two call sites (renderSnapshot's import/live-preview render
    /// downsamples to a long-edge preview; handleNative's live broadcast render stays full-res) and
    /// is preserved by threading it through rather than being unified away. T9b: when the CLEAN
    /// master is served, its depth is `survivorCount` (smaller than the online frame count after
    /// rejections) — used so the overlay's integration time matches the displayed image; the
    /// online-fallback branch is unchanged. The per-sub PREVIEW callers pass separately (onUpdate)
    /// never consults `publishedMasterIfCurrent()` — it always renders from the online mean, exactly
    /// as before this extraction.
    private func resolveBroadcastRender(
        onlineMean: AstroImage,
        onlinePreviewCG: CGImage,
        onlineFrameCount: Int,
        downsampleLongEdge: Int?, context: DisplayRenderContext? = nil
    ) throws -> (mean: AstroImage, cgImage: CGImage, integrationFrames: Int, cleanCount: Int?) {
        guard let published = publishedMasterIfCurrent() else {
            return (onlineMean, onlinePreviewCG, onlineFrameCount, nil)
        }
        let broadcastMean = cropToCoverage(published.image, coverage: published.coverage)
        let displaySource = downsampleLongEdge.map { broadcastMean.downsampled(maxLongEdge: $0) } ?? broadcastMean
        let broadcastCG = try displayCGImage(from: displaySource, context: context)
        return (broadcastMean, broadcastCG, published.survivorCount, published.survivorCount)
    }

    /// Renders + saves one snapshot from the current stack and pushes the preview. Shared by the
    /// throttled per-frame path and end()'s guaranteed final render. Sets lastRenderedAcceptedIndex.
    private func renderSnapshot(index: Int, sourceName: String, timestamp: Date, engine: StackEngine) {
        // Instrumentation only: this path takes displayRenderLock DIRECTLY, without going through
        // refreshDisplay, so its hold is invisible to the request-side phases. An Apply waiting on
        // this lock is the starvation hypothesis, and it cannot be measured without marking here.
        displayRenderPhaseProbeForTest?(0, .frameLockRequested)
        displayRenderLock.lock()
        displayRenderPhaseProbeForTest?(0, .frameLockAcquired)
        defer {
            displayRenderPhaseProbeForTest?(0, .frameLockReleased)
            displayRenderLock.unlock()
        }
        let revision = nextDisplayRevision()
        let context = displayContext()
        displayRenderSettingsProbeForTest?(revision, context.adjustments, "frame")
        guard let (mean0, coverage, frameCount, generation) = engine.displaySnapshot() else {
            displayOnline = nil
            deliverDisplay(revision: revision, preview: nil, broadcast: nil, cleanCount: nil, count: 0)
            return
        }
        let mean = cropToCoverage(mean0, coverage: coverage)   // online — feeds the PREVIEW, unchanged (Task 9)
        let online = OnlineDisplaySnapshot(image: mean, count: frameCount,
                                           cap: importPreviewLongEdge, generation: generation)
        displayOnline = online
        guard let recorder else { onLog?("recorder missing — frame dropped (\(sourceName))"); return }
        do {
            let previewCG = try renderOnlineDisplay(online, context: context,
                                                    revision: revision, origin: "frame")

            // BROADCAST/latest.png: prefer the clean published master over the online mean, with
            // the downsample applied to whichever is served (D10: see resolveBroadcastRender).
            let (broadcastMean, broadcastCG, integrationFrames, cleanCount) = try resolveBroadcastRender(
                onlineMean: mean, onlinePreviewCG: previewCG, onlineFrameCount: frameCount,
                downsampleLongEdge: importPreviewLongEdge, context: context)

            let record = try recorder.save(
                cgImage: broadcastCG, linear: broadcastMean, sourceFile: sourceName,
                index: index, timestamp: timestamp,
                estimatedIntegrationSeconds: Double(integrationFrames) * profile.subExposureSeconds)
            try session.recordSnapshot(record)
            lastRenderedAcceptedIndex = index
            deliverDisplay(revision: revision, preview: previewCG, broadcast: broadcastCG,
                           cleanCount: cleanCount, count: integrationFrames, record: record)
            onUpdate?(previewCG, record)
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
            bumpPreviewStackRevision()
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
                folderSrc.onStall = { [weak self] in self?.onStall?() }
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
    /// Build a render context that overrides the committed adjustments — the seam the staged
    /// preview needs. `wcs` still comes from live state so north-up matches the broadcast.
    private func displayContext(overriding adjustments: DisplayAdjustments) -> DisplayRenderContext {
        DisplayRenderContext(adjustments: adjustments, wcs: currentWCS)
    }

    /// The only entry point that supplies a cache key. It derives pixels and key from the same
    /// captured snapshot; a caller cannot separately pair a newer key with an older image.
    private func renderOnlineDisplay(_ online: OnlineDisplaySnapshot, context: DisplayRenderContext,
                                     revision: UInt64, origin: String) throws -> CGImage {
        let image = online.cap.map { online.image.downsampled(maxLongEdge: $0) } ?? online.image
        let key: CommittedFlattenCache.Key?
        if let generation = online.generation, generation == engine?.currentStackGeneration {
            key = CommittedFlattenCache.Key(generation: generation, count: online.count,
                width: image.width, height: image.height, channels: image.channels,
                scale: context.adjustments.bgScale, smoothest: context.adjustments.bgSmoothest)
        } else {
            key = nil
        }
        return try displayCGImage(from: image, context: context, probeRevision: revision,
                                  probeOrigin: origin, flattenKey: key)
    }

    /// `preflattened` means DBE was already applied by the draft-preview cache. Skip flattening,
    /// but preserve downstream decisions that depend on DBE being enabled.
    private func displayCGImage(from linear: AstroImage, context: DisplayRenderContext? = nil,
                                preflattened: Bool = false,
                                probeRevision: UInt64? = nil,
                                probeOrigin: String? = nil,
                                flattenKey: CommittedFlattenCache.Key? = nil) throws -> CGImage {
        let context = context ?? displayContext()
        let adj = context.adjustments
        if let probeRevision, let probeOrigin {
            displayRenderInputProbeForTest?(RenderInputFacts(
                revision: probeRevision, origin: probeOrigin,
                width: linear.width, height: linear.height, channels: linear.channels,
                sourceIsLinear: linear.sourceIsLinear,
                backgroundExtraction: adj.backgroundExtraction, bgScale: adj.bgScale,
                bgSmoothest: adj.bgSmoothest, blackPoint: adj.blackPoint))
        }
        // DBE first, on linear data. When on, it removes the per-channel spatial
        // background, so skip the additive neutralize (keep multiplicative WB).
        let flattened: AstroImage
        if adj.backgroundExtraction && !preflattened {
            if let key = flattenKey, key.generation == engine?.currentStackGeneration {
                flattened = committedFlattenCache.image(for: key) {
                    BackgroundExtraction.flattenMultiscale(
                        linear, scale: adj.bgScale, smoothest: adj.bgSmoothest)
                }
            } else {
                flattened = BackgroundExtraction.flattenMultiscale(
                    linear, scale: adj.bgScale, smoothest: adj.bgSmoothest)
            }
        } else {
            flattened = linear
        }
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
        // North-up (3b): rotate the DISPLAY only, when toggled on AND a solve is available. Applied here
        // so broadcast, latest.png, snapshots and replay all inherit it; master.fit stays native. No-op
        // (return cg) when the toggle is off or nothing is solved.
        if adj.northUp, let wcs = context.wcs {
            return NorthUpRotation.apply(cg, wcs: wcs, autoZoom: true)
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
        return try? displayCGImage(from: mean, context: displayContext(overriding: adjustments))
    }

    /// Which master the staged preview shows. `.clean` is the trail-rejected master when one
    /// is being served; `.online` is the un-rejected running stack. The blink control swaps
    /// between them through the SAME adjustments, so the comparison isolates rejection rather
    /// than confounding it with a stretch difference.
    public enum PreviewSource: Hashable {
        case clean
        case online
    }

    /// Cached preview proxy, keyed on everything that changes the PIXELS — per source.
    ///
    /// `.clean` is keyed on the published master's FreshnessKey, NOT on generation/sub count: a
    /// kappa change, a user reject, a budget change or an enable-state transition each produce a
    /// different clean master while generation and count stay put, so a weaker key would serve a
    /// STALE clean master — and the blink comparison would then be comparing against something
    /// that no longer exists.
    ///
    /// Adjustments are deliberately absent from every case: the proxy is linear and
    /// pre-adjustment, so a slider drag reuses it.
    private enum PreviewProxyKey: Equatable {
        case online(generation: Int, revision: Int, quality: PreviewQuality)
        case clean(FreshnessKey, quality: PreviewQuality)
        case watcher(token: Int, quality: PreviewQuality)
    }
    /// Flattened (DBE-applied) preview proxies, keyed by the proxy AND the two DBE parameters.
    /// Measured on a 1200x800 proxy, `flattenMultiscale` costs roughly 4x a denoise pass, 15x a
    /// stretch and 200x a histogram — it dominates a preview render completely. It depends only
    /// on the image and its own two parameters, so dragging black point, stretch, saturation or
    /// denoise re-ran it for an identical result and made the panel feel sluggish.
    private struct FlattenedKey: Equatable {
        let proxy: PreviewProxyKey
        let scale: Double
        let smoothest: Double
    }
    private var flattenedProxy: (key: FlattenedKey, image: AstroImage)?

    private let previewProxyLock = NSLock()
    /// One slot PER SOURCE, not a single slot. Hold-to-compare alternates clean -> online ->
    /// clean, so a single slot would evict and rebuild from the full-resolution stack on every
    /// press AND every release — the interaction that has to feel instant would be the most
    /// expensive one in the panel.
    /// One slot per (source, quality). Keying on source ALONE meant the two qualities evicted
    /// each other, so every drag paid an extra full-resolution walk of the stack: the first draft
    /// tick rebuilt the proxy the previous settle had just replaced. Bounded at 2 sources x 2
    /// qualities; the draft entries are ~1/4 the pixels of the settled ones.
    private struct ProxySlot: Hashable {
        let source: PreviewSource
        let quality: PreviewQuality
    }
    private var previewProxies: [ProxySlot: (key: PreviewProxyKey, image: AstroImage)] = [:]
    /// Test seam: how many times the proxy has actually been rebuilt.
    private(set) var previewProxyBuildCountForTest = 0

    /// Monotonic stack revision for the preview cache key. `processedCount` is a private var
    /// mutated on the consume task, so reading it from a preview render — which runs on a
    /// detached task — would be a data race. Bumped under the lock at ALL THREE places
    /// `processedCount` is incremented, including the native live path; missing that one
    /// freezes a live session's preview.
    private let previewRevLock = NSLock()
    private var previewStackRevision = 0
    private func bumpPreviewStackRevision() {
        previewRevLock.lock(); previewStackRevision += 1; previewRevLock.unlock()
    }
    private var currentPreviewStackRevision: Int {
        previewRevLock.lock(); defer { previewRevLock.unlock() }; return previewStackRevision
    }

    /// The most recent rendered linear image, at FULL resolution, with the monotonic token it
    /// was retained under. Watcher / external-stacker mode has NO engine — it loads and renders
    /// each incoming file — so without this neither the preview nor Apply would have anything
    /// to render from there, even though display adjustments apply exactly as they do natively.
    /// Kept at full resolution (not pre-downsampled) so `renderSelectedSource(.online, ...)` (the
    /// Apply path's watcher-mode fallback — correctness-wave fix) can render the main view at
    /// full resolution too, not just the preview's downsampled proxy; `renderPreview` downsamples
    /// its own copy on demand below, and only pays that cost once per incoming frame (the cache
    /// keyed on `token` absorbs repeats).
    /// Keyed by a monotonic TOKEN, not the file digest: `StackUpdate.identity` is
    /// `FileIdentity?` and `FileIdentity.digest` is `String?`, so a digest key would need a
    /// double unwrap and a fallback for the nil case.
    private let lastPreviewLock = NSLock()
    private var watcherFrameToken = 0
    private var lastPreviewLinear: (token: Int, image: AstroImage)?
    func noteWatcherFrame(_ linear: AstroImage) {
        lastPreviewLock.lock()
        watcherFrameToken += 1
        lastPreviewLinear = (watcherFrameToken, linear)
        lastPreviewLock.unlock()
    }

    /// Full-resolution image (and coverage mask) that `PreviewSource.online` currently resolves
    /// to: `engine.currentStackAndCoverage()` in native/import mode, or the retained last frame
    /// in watcher/external-stacker mode (full-weight coverage — `handle()` doesn't crop watcher
    /// frames either, so this makes the `cropToCoverage` below a no-op for them). nil means
    /// nothing to render yet (no stack, or no watcher frame seen yet).
    private func onlineSourceFullRes() -> (image: AstroImage, coverage: [Float]?)? {
        if let engine, let (mean, coverage) = engine.currentStackAndCoverage() {
            return (mean, coverage)
        }
        lastPreviewLock.lock()
        let cached = lastPreviewLinear?.image
        lastPreviewLock.unlock()
        guard let cached else { return nil }
        return (cached, nil)   // watcher frames arrive already coverage-cropped by the external stacker
    }

    /// Full-resolution image (and coverage) `source` resolves to right now: `.clean` is the
    /// published clean master when one is servable, `.online` is `onlineSourceFullRes()` above.
    /// Shared by `renderPreview` (which downsamples the result and DOES choose between `.clean`
    /// and `.online`) and `renderSelectedSource` (Apply's full-resolution counterpart). Apply
    /// itself always calls `renderSelectedSource(.online, ...)` — the pipeline's contract keeps
    /// the main view ONLINE, matching the per-frame broadcast render (see
    /// `testBroadcastRendersPublishedMasterWhilePreviewStaysOnline`) — so in practice only the
    /// `.online` branch here is reached from Apply; `.clean` exists for `renderPreview`'s use.
    private func selectedSourceFullRes(_ source: PreviewSource) -> (image: AstroImage, coverage: [Float]?)? {
        switch source {
        case .clean:
            guard let published = publishedMasterIfCurrent() else { return nil }
            return (published.image, published.coverage)
        case .online:
            return onlineSourceFullRes()
        }
    }

    /// Renders the staged preview WITHOUT touching committed state — the property
    /// `renderCurrentDisplay(adjustments:)` deliberately does not have (it commits, and is
    /// retained for the Apply path). Returns nil when the requested source has nothing to
    /// show: no stack yet, or `.clean` with no published master.
    public func renderPreview(source: PreviewSource,
                              adjustments: DisplayAdjustments,
                              quality: PreviewQuality = .settled) -> CGImage? {
        // Resolve the cache key FIRST — it decides what may be reused, and for `.clean` it is
        // the FreshnessKey of the master actually being served.
        let key: PreviewProxyKey
        switch source {
        case .clean:
            guard let publishedKey = publishedMasterFreshnessKeyIfCurrent() else { return nil }
            key = .clean(publishedKey, quality: quality)
        case .online:
            if let engine {
                key = .online(generation: engine.currentStackGeneration,
                              revision: currentPreviewStackRevision, quality: quality)
            } else {
                lastPreviewLock.lock()
                let token = lastPreviewLinear?.token
                lastPreviewLock.unlock()
                guard let token else { return nil }       // watcher mode, no frame yet
                key = .watcher(token: token, quality: quality)
            }
        }
        var proxy: AstroImage?
        previewProxyLock.lock()
        let slot = ProxySlot(source: source, quality: quality)
        if let cached = previewProxies[slot], cached.key == key { proxy = cached.image }
        previewProxyLock.unlock()

        if proxy == nil {
            guard let (image, coverage) = selectedSourceFullRes(source) else { return nil }
            let built = cropToCoverage(image, coverage: coverage)
                .downsampled(maxLongEdge: quality.longEdge)
            previewProxyLock.lock()
            previewProxies[slot] = (key, built)
            previewProxyBuildCountForTest += 1
            previewProxyLock.unlock()
            proxy = built
        }
        guard let proxy else { return nil }

        // Hoist the DBE stage out of the per-tick render and cache it.
        var working = proxy
        var preflattened = false
        if adjustments.backgroundExtraction {
            let fk = FlattenedKey(proxy: key, scale: adjustments.bgScale,
                                  smoothest: adjustments.bgSmoothest)
            previewProxyLock.lock()
            let cached = (flattenedProxy?.key == fk) ? flattenedProxy?.image : nil
            previewProxyLock.unlock()
            if let cached {
                working = cached
            } else {
                working = BackgroundExtraction.flattenMultiscale(
                    proxy, scale: adjustments.bgScale, smoothest: adjustments.bgSmoothest)
                previewProxyLock.lock()
                flattenedProxy = (fk, working)
                previewProxyLock.unlock()
            }
            preflattened = true
        }
        return try? displayCGImage(from: working,
                                   context: displayContext(overriding: adjustments),
                                   preflattened: preflattened)
    }

    /// Renders `source` at FULL resolution — the Apply-path counterpart to `renderPreview`,
    /// which renders the same sources downsampled. Apply always calls this with `.online`: the
    /// pipeline's contract keeps the main view ONLINE (matching the per-frame broadcast render;
    /// see `testBroadcastRendersPublishedMasterWhilePreviewStaysOnline`), so this exists mainly
    /// to fix a real gap in `renderCurrentDisplay(adjustments:)` — it always reads
    /// `engine.currentStack()`, which is nil in watcher/external-stacker mode (no engine there),
    /// so Apply produced no image at all there; this falls back to the retained last watcher
    /// frame instead. Deliberately has NO committing side effect (unlike
    /// `renderCurrentDisplay(adjustments:)`, which callers use when they need
    /// `displayAdjustments` written as well); returns nil when the requested source has nothing
    /// to render.
    public func renderSelectedSource(_ source: PreviewSource,
                                     adjustments: DisplayAdjustments) -> CGImage? {
        guard let (image, coverage) = selectedSourceFullRes(source) else { return nil }
        let cropped = cropToCoverage(image, coverage: coverage)
        return try? displayCGImage(from: cropped, context: displayContext(overriding: adjustments))
    }

    /// Test seam: render an arbitrary image through the SAME path the broadcast uses.
    /// Exists so `DisplayRenderParityTests` can pin the committed output by hash.
    func renderForTest(_ image: AstroImage, adjustments: DisplayAdjustments) throws -> CGImage {
        try displayCGImage(from: image, context: displayContext(overriding: adjustments))
    }

    /// Processes one raw frame through the stack engine (native mode). Callback deliveries
    /// inside are reentrancy-guarded (review10 item 4).
    private func handleNative(_ rawFrame: RawFrame, engine: StackEngine) {
        withCallbackDelivery {
            if cancelled.isSet { return }
            if sourceMetadata == nil, let m = rawFrame.metadata {
                sourceMetadata = m
                // No explicit calibrator (empty-folder live start): resolve one now from
                // this first frame's header. Once only; serial consume task → no lock.
                if calibrator == nil, !providerAttempted, let provider = calibratorProvider {
                    providerAttempted = true
                    providerCalibrator = provider(m)
                    providerCalibrator?.onLog = { [weak self] in self?.onLog?($0) }
                }
            }
            let frame = (calibrator ?? providerCalibrator)?.apply(rawFrame) ?? rawFrame
            let result = engine.processDetailed(frame)
            let outcome = result.outcome
            if engine.autoReseedCount != lastAutoReseedCount {
                committedFlattenCache.invalidate(minimumGeneration: engine.currentStackGeneration)
                lastAutoReseedCount = engine.autoReseedCount
                // T8 review fix: an auto-reseed is a FreshnessKey mutation point (generation change)
                // exactly like manual reseed() (see reseed()'s matching block) — refresh the
                // cached key HERE so publishedMasterIfCurrent() immediately stops serving a master built
                // from the just-discarded reference, instead of staying stale until the next accepted
                // sub's .becameReference append happens to recompute it. Lock-safety: neither `regLock`
                // nor the engine lock is held at this point — `engine.processDetailed` above already
                // acquired+released the engine's own lock — so this matches reseed()'s established
                // regLock -> engine.lock leaf-edge ordering with no new cycle. By this point
                // engine.autoReseedCount has already been bumped (checked just above), so the recompute
                // observes the POST-reseed generation.
                //
                // Correctness-wave defect 3: this recompute MUST run BEFORE invalidatePlateSolve()
                // below, not after. invalidatePlateSolve() fires the public onSolveStateChanged
                // callback, which AppModel hops onto the main actor to call refreshPreview() —
                // asynchronously, on a different thread, with no synchronization back to this
                // (serial consume) thread. With the old order (invalidate, then recompute), that
                // async render could run before the recompute landed and serve the clean master
                // this reseed just invalidated — and since the triggering frame is itself
                // rejected, nothing later was guaranteed to correct it, leaving a stale master on
                // screen indefinitely. Recomputing first closes the window: by the time the
                // callback can act, publishedMasterIfCurrent() already refuses the stale master.
                regLock.withLock { recomputeCachedFreshnessKeyLocked() }
                // The engine dropped its reference and will re-seed on the next good sub — void the
                // stale WCS and re-enable solving so the NEW reference plate-solves (its center/rotation
                // can differ). MUST run before attemptPlateSolveIfNeeded below so this frame's attempt
                // sees the reset state (manual reseed() does the same via invalidatePlateSolve()).
                invalidatePlateSolve()
                noteReseeded()
                onLog?("Auto-reseeded — the reference frame didn't match; re-seeding on the next good sub. (Earlier subs that couldn't register stay rejected.)")
            }
            attemptPlateSolveIfNeeded(engine: engine)   // idempotent; no-op until a reference is seeded
            processedCount += 1
            bumpPreviewStackRevision()
            // A frame the engine has finalized (accepted OR rejected) is drain progress for the
            // progress-aware live drain in end() — ticked HERE, before the snapshot-render guards
            // below (which can early-return on a nil coverage/recorder), so an accepted frame whose
            // render is skipped still counts as progress. Live never ticked before, so progressTicks
            // was frozen and the live drain could never see progress (2026-08-28).
            noteFrameProgress()
            // Emitted BEFORE the switch's snapshot-rendering (which can early-return on a
            // guard/do-catch failure) so onSubFrame fires exactly once per sub regardless of
            // downstream render success. Indexed by processedCount for EVERY sub (accepted and
            // rejected alike) — processedCount and engine.acceptedCount overlap (acceptedCount
            // <= processedCount), so using acceptedCount for accepted subs and processedCount
            // for rejected ones could collide (e.g. a rejection followed by an accept can land
            // on the same index), which broke StatsView's ForEach(id: \.index) and
            // toggleReject's firstIndex(by index) lookup. processedCount is monotonic and
            // unique per sub, so it can't collide. Note this decouples subRecord.index from the
            // SnapshotRecord's index (engine.acceptedCount) for accepted subs — the
            // SnapshotRecord-shared-index property isn't consumed anywhere.
            let subOutcome: SubFrameOutcome
            var rejectionReason: String? = nil
            switch outcome {
            case .becameReference: subOutcome = .reference
            case .stacked:         subOutcome = .stacked
            case .rejected(let r): subOutcome = .rejected; rejectionReason = "\(r)"
            }
            let subRecord = SubFrameRecord(
                index: processedCount,
                timestamp: frame.timestamp, sourceFile: frame.sourceName,
                starCount: result.starCount, backgroundSigma: result.backgroundSigma,
                weight: result.weight, outcome: subOutcome, rejectionReason: rejectionReason,
                rejectedByUser: false, identity: frame.identity)
            onSubFrame?(subRecord)
            // Persist every sub (accepted AND rejected) on this same callback-delivery
            // thread — the same serial context recordSnapshot runs on below, so this is
            // race-free against AppModel's main-actor mirror (Task 8 Refinement).
            do {
                try session.recordSubFrame(subRecord)
            } catch {
                onLog?("Failed to record sub-frame stats for \(frame.sourceName): \(error)")
            }
            // Task 5: capture the registration cache for a later background refiner. No URL
            // (e.g. an in-memory/synthetic frame) skips ONLY the cache insertion — the rest of
            // handleNative (online render/progress) must continue regardless.
            if let reg = result.registration, let relayURL = frame.sourceURL {
                regLock.withLock {
                    _subRegistrations.append(SubRegistration(
                        subIndex: processedCount, contentDigest: frame.identity?.digest, relayURL: relayURL,
                        stackGeneration: reg.stackGeneration, referenceIdentity: reg.referenceIdentity,
                        transform: reg.transform, effectiveScale: reg.effectiveScale,
                        weight: reg.weight, leveling: reg.leveling))
                    // Task 7: a sub append changes the survivor set (and possibly the generation,
                    // on the first sub of a new reference) — refresh the cached freshness key.
                    recomputeCachedFreshnessKeyLocked()
                }
                // Task 8: notify the background refiner OUTSIDE regLock. The recompute above
                // already refreshed `_freshnessKey` for this sub — noteSubAccepted() does NOT
                // recompute again (would double the work every sub); it only notifies. A no-op
                // when live rejection has never been enabled this session (currentRefiner() nil).
                noteSubAccepted()
            }
            switch outcome {
            case .becameReference, .stacked:
                // Instrumentation only: the native live path takes the lock directly, so its hold
                // is invisible to the request-side phases. An Apply waiting behind THIS is the
                // starvation hypothesis and cannot be measured without marking it.
                displayRenderPhaseProbeForTest?(0, .frameLockRequested)
                displayRenderLock.lock()
                displayRenderPhaseProbeForTest?(0, .frameLockAcquired)
                defer {
                    displayRenderPhaseProbeForTest?(0, .frameLockReleased)
                    displayRenderLock.unlock()
                }
                let revision = nextDisplayRevision()
                let context = displayContext()
                guard let (mean0, coverage, frameCount, generation) = engine.displaySnapshot() else {
                    displayOnline = nil
                    deliverDisplay(revision: revision, preview: nil, broadcast: nil, cleanCount: nil, count: 0)
                    return
                }
                let mean = cropToCoverage(mean0, coverage: coverage)   // online — feeds the PREVIEW, unchanged (Task 9)
                let online = OnlineDisplaySnapshot(image: mean, count: frameCount,
                                                   cap: nil, generation: generation)
                displayOnline = online
                guard let recorder else {
                    onLog?("recorder missing — frame dropped (\(frame.sourceName))")
                    return
                }
                do {
                    // NATIVE LIVE renders inline here, not through renderSnapshot (which is the
                    // IMPORT path). Instrumenting only renderSnapshot left live-mode frame renders
                    // unlabelled, so the prerequisite saw deliveries but no "frame" origin.
                    displayRenderSettingsProbeForTest?(revision, context.adjustments, "frame")
                    let previewCG = try renderOnlineDisplay(online, context: context,
                                                            revision: revision, origin: "frame")

                    // BROADCAST/latest.png: prefer the clean published master over the online
                    // mean, full-resolution (live, unlike renderSnapshot's downsampled preview) —
                    // D10: see resolveBroadcastRender.
                    let (broadcastMean, broadcastCG, integrationFrames, cleanCount) = try resolveBroadcastRender(
                        onlineMean: mean, onlinePreviewCG: previewCG, onlineFrameCount: frameCount,
                        downsampleLongEdge: nil, context: context)

                    // Pass the raw un-neutralized mean as linear: stats stay raw for v1.1 cloud gate.
                    displayRenderPhaseProbeForTest?(revision, .diskWriteBegan)
                    defer { displayRenderPhaseProbeForTest?(revision, .diskWriteEnded) }
                    let record = try recorder.save(
                        cgImage: broadcastCG, linear: broadcastMean, sourceFile: frame.sourceName,
                        index: engine.acceptedCount, timestamp: frame.timestamp,
                        estimatedIntegrationSeconds: Double(integrationFrames) * profile.subExposureSeconds)
                    try session.recordSnapshot(record)
                    deliverDisplay(revision: revision, preview: previewCG, broadcast: broadcastCG,
                                   cleanCount: cleanCount, count: integrationFrames, record: record)
                    onUpdate?(previewCG, record)
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
        let probeName = update.url.lastPathComponent
        frameProcessingProbeForTest?(probeName, .began)
        defer { frameProcessingProbeForTest?(probeName, .finished) }
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
                noteWatcherFrame(linear)
                displayRenderLock.lock()
                defer { displayRenderLock.unlock() }
                let revision = nextDisplayRevision()
                let cg = try displayCGImage(from: linear)
                let index = session.acceptedCount + 1
                displayOnline = OnlineDisplaySnapshot(image: linear, count: index,
                                                      cap: nil, generation: nil)
                let record = try recorder.save(
                    cgImage: cg, linear: linear, sourceFile: update.url.lastPathComponent,
                    index: index, timestamp: Date(),
                    estimatedIntegrationSeconds: Double(index) * profile.subExposureSeconds)
                try session.recordSnapshot(record)
                deliverDisplay(revision: revision, preview: cg, broadcast: cg,
                               cleanCount: nil, count: index, record: record)
                onUpdate?(cg, record)
            } catch let mismatch as FileIdentityMismatchError {
                // A boundary failure may lose one frame, never the session; it appears honestly here.
                onLog?("file changed between validation and read — skipping \(mismatch.fileName)")
            } catch {
                // Spec §7: skip bad updates, keep the last good frame on the broadcast.
                onLog?("Skipped update (\(update.url.lastPathComponent)): \(error)")
            }
            // A processed update is drain progress (parity with handleNative) so the shared
            // progress-aware live drain waits out a watcher-mode backlog instead of cancelling it.
            noteFrameProgress()
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
        let out = CoverageCrop.cropToCoverage(image, coverage: coverage)
        // The shared util is pure; preserve this method's "keeping full frame" log for the
        // one case the util declines silently: a valid non-full-frame rect existed but was
        // rejected for removing >40% of the area (out keeps the original dimensions).
        if out.width == image.width, out.height == image.height,
           let cov = coverage,
           let rect = CoverageCrop.rect(coverage: cov, width: image.width, height: image.height),
           !(rect.x0 == 0 && rect.y0 == 0 && rect.x1 == image.width - 1 && rect.y1 == image.height - 1) {
            onLog?("Crop-to-overlap: rect \(rect.width)x\(rect.height) would remove >40% — keeping full frame")
        }
        return out
    }

    /// The running session's directory (nil before start / after teardown). Public so the
    /// snapshot path, tests, and the app layer (a committed-but-replay-failed End Session,
    /// Fix 3) can address `master.fit` / `sub-frames.csv` without reaching through `session`.
    public var sessionDir: URL? { session.sessionDirectory }

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
        // NOTE: this always sources the ONLINE stack (`engine.masterSnapshotState()`), never the
        // background refiner's clean/trail-rejected `publishedMaster` — even when live rejection
        // is ON. This is a documented SCOPE gap, not a parity regression: a proper `end()` still
        // writes the clean artifact via the frozen-facts path above; a synchronous refine on the
        // idle-tick path was judged too risky (unbounded I/O on a timer). Logged below so the gap
        // is discoverable from the session log rather than silent.
        guard let snap = engine.masterSnapshotState() else {
            onLog?("master snapshot skipped — no live stack")
            return false
        }
        if regLock.withLock({ liveRejectionActive }) {
            onLog?("master snapshot: writing ONLINE stack (idle safeguard does not use the clean "
                + "live-rejection master — the clean master.fit is written at End Session)")
        }
        let frameCount = snap.frameCount                              // STACKCNT source (same read as pixels)
        let master = cropToCoverage(snap.image, coverage: snap.coverage)   // crop BEFORE balance
        let balanced = neutralizeBackground
            ? AutoStretch.neutralizeBackgroundAdditive(master)
            : master
        let totalExp = Double(frameCount) * profile.subExposureSeconds
        // THEORETICAL: cross-thread read of sourceMetadata from the idle-safeguard tick; written
        // once on first frame, safeguard fires only on 30s idle boundaries, so a torn read is
        // vanishingly unlikely. Left un-locked to avoid burdening the hot consume path.
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

    /// Drain the frame-consuming task, PROGRESS-AWARE (mirrors drainFiniteImportOrThrow). A live
    /// session ended while the consumer is still draining a BACKLOG of accepted frames is
    /// progressing, not wedged; the pre-fix flat single window cancelled it and threw
    /// shutdownTimeout, discarding the whole master (2026-08-28 ASI2600 real-data run, three
    /// sessions lost). As long as the consumer keeps FINALIZING frames (progressTicks advances —
    /// handleNative/handle tick it), keep draining; only a full `liveDrainStallTimeout` window with
    /// ZERO progress means it is genuinely wedged, at which point the task is CANCELLED and given a
    /// grace period, then shutdownTimeout is thrown rather than finalizing over a still-running
    /// consumer (which would race the accumulator/snapshots and could write a corrupt master).
    ///
    /// The wedge window is `liveDrainStallTimeout` (120 s), NOT `drainPrimaryTimeout` (10 s): one
    /// healthy 26 MP frame takes longer than the stop budget to finalize (cold review 2026-08-28).
    /// The source/watcher stop is bounded SEPARATELY by its own `stop(timeout: drainPrimaryTimeout)`
    /// in end(), so this drain does NOT re-charge it — an earlier version seeded the first window
    /// from a pre-stop deadline, which a slow stop() shrank to ~0 and discarded a healthy backlog
    /// (cold-review PROVEN). Every window here is a full fresh `liveDrainStallTimeout`.
    ///
    /// TRADE-OFF: end() is no longer hard-bounded to ~primary+grace — a large healthy backlog
    /// drains fully (bounded by the backlog size, since the source stream ends on stop()). Losing
    /// the whole master to a fixed deadline was the worse outcome.
    private func drainConsumeTaskOrThrow() throws {
        let grace = drainGraceTimeout
        guard let task = consumeTask else { return }
        // The common case (an idle consumer at end()) returns on the first wait at once.
        var last = progressSnapshot
        while true {
            if consumeDone.wait(timeout: .now() + liveDrainStallTimeout) == .success {
                consumeTask = nil
                return
            }
            let now = progressSnapshot
            if now != last {
                last = now
                continue   // progressed within the window → keep draining
            }
            break          // a full stall window passed with no finalized frame → wedged
        }
        // No progress across a full window: stop the consumer cooperatively, bounded grace.
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

    /// D20: the clean-vs-online master-selection policy for shutdown, and the `RestackReport`
    /// built from it; `end()` still does the `encodeMaster`/write. The policy, in order —
    ///
    ///   1. a published master computed over EXACTLY the frozen survivor set (nothing deeper
    ///      exists, so no pass is worth running);
    ///   2. otherwise ONE bounded final pass over the frozen survivor set — `master.fit` is
    ///      archival, so end() reaches for full depth even when a shallower master is servable;
    ///   3. otherwise a servable-but-SHALLOWER published master, if that pass could not run — a
    ///      shallow CLEAN master still beats the online one, which rejects nothing;
    ///   4. otherwise the online `master0`.
    ///
    /// Step 2 taking precedence over step 3 is a deliberate divergence from the live broadcast,
    /// which serves any servable master (review P2): serving shallow keeps the broadcast clean
    /// during a pass, but WRITING shallow would silently drop a sub's integration from the
    /// archived master. (This method began as a pure extraction of `end()`'s `.active` case;
    /// the ordering above is a real behavior change on top of that.)
    ///
    /// Must run using ONLY the frozen snapshot (`frozen`/`frozenGen`) taken by `end()` AFTER
    /// stop/drain/freeze/cancel (never the live `liveRejectionActive`/`_freshnessKey`/
    /// `publishedMaster`/`currentFreshnessKey()`/`publishedMasterIfCurrent()` — those may have
    /// moved past the freeze). `frozen.active == false` skips the clean path entirely (feature-off
    /// parity): no publishedMaster use, no final pass — the online master is written, byte-identical
    /// to today. Not lock-guarded itself: it only touches the frozen locals passed in plus
    /// `currentRefiner()` (which takes `regLock` internally, same as it did inline in `end()`).
    private func selectMasterReport(
        frozen: (survivors: [SubRegistration], key: FreshnessKey, active: Bool,
                 kappa: Float, budget: Int, published: PublishedMaster?),
        frozenGen: Int,
        master0: AstroImage,
        final: StackEngine.FinalizationState
    ) -> (report: RestackReport, cleanCount: Int?) {
        var clean: (image: AstroImage, coverage: [Float], survivorCount: Int)?
        if frozen.active {
            if let pub = frozen.published, pub.key == frozen.key {
                // A background pass already published a master computed over EXACTLY the
                // frozen survivor set — nothing deeper is available, so no final pass.
                clean = (pub.image, pub.coverage, pub.survivorCount)
            } else {
                // Either nothing is published, or what is published is merely SHALLOW (subs
                // arrived after it was computed — `isServable` keeps serving it to the live
                // broadcast). end() must NOT settle for shallow: master.fit is the archival
                // output, so run ONE bounded final pass against the FROZEN survivor set to
                // get full depth. Serving a 5-sub master while a 6th survivor sits in the
                // frozen set would write STACKCNT=5 and silently discard a sub's integration.
                // The deadline alone bounds the pass (step 4 already cancelled the background
                // pass, so nothing else cancels this one).
                if let refiner = currentRefiner() {
                    let result = refiner.refine(
                        survivors: frozen.survivors, currentGeneration: frozenGen,
                        kappa: frozen.kappa, minSubs: liveRejectionMinSubs,
                        maxSampleBytes: frozen.budget,
                        deadline: .now() + finalRefineBudget,
                        isCancelled: { false })
                    if let result {
                        clean = (result.image, result.coverage, result.survivorCount)
                    }
                }
                if clean == nil, let pub = frozen.published,
                   pub.key.isServable(against: frozen.key) {
                    // The final pass hit its deadline or failed. A shallower CLEAN master is
                    // still strictly better than the online master (which rejects nothing), so
                    // fall back to it rather than dropping to `master0` and losing trail
                    // rejection entirely. Only reached when full depth was actually attempted.
                    clean = (pub.image, pub.coverage, pub.survivorCount)
                }
            }
        }
        // frozen.active == false → the clean path is skipped entirely (feature-off
        // parity fix): no publishedMaster use, no final refine — `clean` stays nil and
        // the online master below is written, byte-identical to today.

        // All output goes through the shared crop-to-coverage + additive-neutralize +
        // FITS-metadata path (RestackPlanning.encodeMaster) — same path a post-session
        // re-stack uses — so master.fit never diverges pixel-for-pixel between the two.
        if let clean {
            // CLEAN global result: STACKCNT/TOTALEXP reflect the count that actually
            // combined into the written pixels, not the online engine's frame count.
            return (RestackReport(master: clean.image, stackedCount: clean.survivorCount,
                                 skippedMissing: 0, skippedMismatch: 0, unverifiedLegacy: false,
                                 coverage: clean.coverage), clean.survivorCount)
        } else {
            // Online fallback / feature-off: EXACTLY today's counts, for byte parity.
            return (RestackReport(master: master0, stackedCount: final.frameCount,
                                 skippedMissing: 0, skippedMismatch: 0, unverifiedLegacy: false,
                                 coverage: final.coverage), nil)
        }
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
        // Includes failed shutdown/master writes. An in-flight miss cannot reattach its buffer
        // after this retirement; a retry of end() simply renders without retaining DBE data.
        defer { committedFlattenCache.invalidate(retiring: true) }
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
                    // watcher, previously an un-budgeted 5 s default) is bounded by the stop
                    // budget. The stop is a SEPARATE bound from the progress-aware drain below:
                    // a dead share can no longer pin end() outside stop's own timeout, while a
                    // healthy backlog drains without the stop time eating the drain's window.
                    if let folderSource = source as? FolderFrameSource {
                        folderSource.stop(timeout: Self.seconds(drainPrimaryTimeout))
                    } else {
                        source?.stop()
                    }
                    try drainConsumeTaskOrThrow()
                }
            } else {
                // Watcher mode: stop the watcher to terminate the updates stream, then drain.
                // The watcher stop is itself BOUNDED (a scan stalled on a dead share can no longer
                // pin end() outside stop's own timeout); the progress-aware drain then waits out
                // any healthy backlog without the stop time shrinking its window.
                watcher?.stop(timeout: Self.seconds(drainPrimaryTimeout))
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
            // Task 10: FREEZE every clean-master input before computing/choosing anything, so
            // nothing that lands after this point (a late configureLiveRejection, a reject —
            // reject is separately blocked once finalization begins, Task 11 P2-1) can alter the
            // written master. Order matters: read the engine's generation FIRST, its own lock,
            // released immediately, THEN snapshot the rest under regLock in ONE acquisition —
            // never hold regLock while touching the engine lock. `frozen.key`/`frozen.active`/
            // `frozen.kappa`/`frozen.budget`/`frozen.published` are direct field reads (never
            // `currentFreshnessKey()`/`publishedMasterIfCurrent()`, which re-acquire regLock and
            // would deadlock here since we already hold it).
            var finalization: SessionFinalizationFacts?
            let finalContext = freezeDisplayContextForFinalRender()
            var finalBroadcast: (image: AstroImage, count: Int, cleanCount: Int?)?
            if let eng = engine {
                let frozenGen = eng.currentStackGeneration
                let frozen: (survivors: [SubRegistration], key: FreshnessKey, active: Bool,
                            kappa: Float, budget: Int,
                            published: PublishedMaster?)
                frozen = regLock.withLock {
                    (currentSurvivorsLocked(currentGeneration: frozenGen), _freshnessKey, liveRejectionActive,
                     liveRejectionKappa, liveRejectionMaxSampleBytes, publishedMaster)
                }

                // Cancel any in-flight background refiner pass. Bounded: the running pass checks
                // the cancellation flag BETWEEN subs (C3), so it unwinds on its own within one
                // sub's load time — end() does not block waiting for it; the final pass below (if
                // any) is bounded independently by its own deadline.
                //
                // F6 (cold-review minor): `cancel()` alone only stamps the CURRENT pass — the
                // background coalescer (`noteChanged`/`runCoalescedPasses`) can still start pass
                // K+1 with a fresh, un-cancelled id while end() runs below. `quiesce()` is a
                // separate, terminal stop: it blocks the coalescer from starting or continuing any
                // FURTHER pass, without affecting the direct `refine()` call `selectMasterReport`
                // makes below (quiesce is never consulted by `refine()` itself). Output was already
                // safe either way (a stale background pass publishes under an old snapshot key that
                // `publishedMasterIfCurrent` refuses) — this just stops wasted background work
                // during shutdown.
                currentRefiner()?.cancel()
                currentRefiner()?.quiesce()

                let final = try eng.finalizationState()
                let outcome: MasterOutcome
                switch final.stackState {
                case .active:
                    guard let master0 = final.image else {
                        throw StackEngine.FinalizationError.invariantBreach
                    }
                    let (report, cleanCount) = selectMasterReport(frozen: frozen, frozenGen: frozenGen,
                                                    master0: master0, final: final)
                    let masterData = RestackPlanning.encodeMaster(
                        report, neutralize: neutralizeBackground,
                        metadata: sourceMetadata, subExposureSeconds: profile.subExposureSeconds)
                    try masterData.write(to: dir.appendingPathComponent("master.fit"))
                    finalBroadcast = (cropToCoverage(report.master, coverage: report.coverage),
                                      report.stackedCount, cleanCount)
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
            // Drain the display renderer and publish one final, frozen pair. Late refiner or
            // adjustment requests cannot resurrect an ended session's display.
            displayRenderLock.lock()
            let revision = displayRevisionLock.withLock { () -> UInt64 in
                displayFinished = true
                displayRevision &+= 1
                return displayRevision
            }
            withCallbackDelivery {
                renderDisplayTransition(revision: revision, finalBroadcast: finalBroadcast,
                                        context: finalContext)
            }
            committedFlattenCache.invalidate(retiring: true)
            displayRenderLock.unlock()
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
