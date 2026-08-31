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
/// `publishedMasterIfCurrent()` invalidates the stored master the instant ANY of these change —
/// a reseed, a user reject, or a κ change — so broadcast/end() never consume a stale trail-free
/// master. `survivorSubIndices` is the SORTED list of survivor `subIndex`es (unique per sub —
/// byte-identical subs stay distinct entries, never collapsed to a digest set).
public struct FreshnessKey: Equatable {
    let stackGeneration: Int
    let survivorSubIndices: [Int]
    let userRejectGeneration: Int
    let kappa: Float
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

    /// Void the stored/in-flight solve and re-enable solving so the NEXT reference re-solves. Called
    /// on BOTH reseed paths — manual `reseed()` and the engine's internal auto-reseed. The generation
    /// bump discards any in-flight solve that lands after this point.
    private func invalidatePlateSolve() {
        plateSolveLock.withLock { solvedWCS = nil; solveAttempted = false; solveGeneration += 1 }
        onSolveStateChanged?()   // negative edge: reseed/auto-reseed dropped the solve — refresh the gate
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
            if stored { self.onSolveStateChanged?() }
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

    /// Called from `handleNative` POST-COMMIT, only when a `SubRegistration` was actually
    /// appended (an accepted sub with a registration payload). The T7 sub-append block already
    /// recomputes `_freshnessKey` there — this hook does NOT recompute again (would double the
    /// work every single sub); it only notifies.
    func noteSubAccepted() {
        currentRefiner()?.noteChanged()
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
        currentRefiner()?.noteChanged()
    }

    /// Reseed notification hook. `reseed()` itself already bumps the engine's generation and
    /// recomputes the cached key (T7 review fix) before calling this — so this hook only
    /// notifies, avoiding a double recompute.
    func noteReseeded() {
        currentRefiner()?.noteChanged()
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
                                             userRejectGeneration: 0, kappa: RejectionStrength.medium.kappa)
    /// The background refiner's most recently published trail-free master, stamped with the
    /// `FreshnessKey` it was computed from. `internal` — Task 6/11 publish here directly (and
    /// tests construct/inspect it via `@testable import`, which requires `internal`+, not
    /// `private` — a `private` property is invisible outside this file regardless of
    /// `@testable`).
    internal var publishedMaster: PublishedMaster?   // guarded by regLock
    /// RAM sample budget (bytes) the background refiner combines survivors with. NOT part of
    /// `FreshnessKey` (unlike κ) — a budget-only change can't be detected via key comparison, so
    /// `configureLiveRejection` clears `publishedMaster` explicitly when it changes (see below).
    private var liveRejectionMaxSampleBytes: Int = GlobalRefiner.defaultMaxSampleBytes   // guarded by regLock
    /// Quorum floor for the background refiner (both the materialized RAM sample and the final
    /// survivor count) — same value as the Task 11 online gate. Not currently configurable via
    /// `configureLiveRejection` (no brief-specified setter), so a plain constant.
    private let liveRejectionMinSubs: Int = GlobalRefiner.defaultMinSubs
    /// Task 8: the background refiner, OWNED by the pipeline and created LAZILY on the first
    /// `configureLiveRejection(enabled: true, ...)` call — never before. This is the ownership/
    /// lifetime choice that keeps feature-OFF parity trivially true: every Task 8 invalidation
    /// hook (`noteSubAccepted`/`noteUserRejectChanged`/`noteReseeded`) calls
    /// `currentRefiner()?.noteChanged()` UNCONDITIONALLY (no `liveRejectionActive` check) — if
    /// live rejection has never been turned on this session, `_globalRefiner` is nil, so those
    /// calls are no-ops: zero refiner queue activity, zero published master, byte-identical
    /// output to today. (Holding a refiner for the whole session and gating its activity on
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
                                     userRejectGeneration: userRejectGeneration, kappa: liveRejectionKappa)
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
    /// recompute `_freshnessKey` (κ IS part of the key, so a κ change alone already invalidates
    /// any published master via the key comparison), and explicitly CLEAR a now-stale
    /// `publishedMaster` when the feature just went OFF or the budget changed — budget is
    /// deliberately NOT part of `FreshnessKey` (unlike κ), so a budget-only change would otherwise
    /// leave a stale master's key still matching. Lazily creates `_globalRefiner` the first time
    /// `enabled` turns (or is passed) true. `shouldNotify` is computed UNDER the lock from
    /// lock-guarded state — never read again after releasing — then the refiner is notified
    /// OUTSIDE the lock. `enabledRose` (OFF→ON, survivors already present) is the key case: it
    /// must trigger a build immediately, not wait for the next sub/reject/reseed.
    public func configureLiveRejection(enabled: Bool? = nil, kappa: Float? = nil, maxSampleBytes: Int? = nil) {
        var shouldNotify = false
        var refinerToNotify: GlobalRefiner?
        regLock.withLock {
            let oldEnabled = liveRejectionActive
            let oldKappa = liveRejectionKappa
            let oldBudget = liveRejectionMaxSampleBytes
            let newEnabled = enabled ?? oldEnabled
            let newKappa = kappa ?? oldKappa
            let newBudget = maxSampleBytes ?? oldBudget

            let enabledRose = !oldEnabled && newEnabled
            let kappaChanged = newKappa != oldKappa
            let budgetChanged = newBudget != oldBudget

            liveRejectionActive = newEnabled
            liveRejectionKappa = newKappa
            liveRejectionMaxSampleBytes = newBudget
            recomputeCachedFreshnessKeyLocked()
            if !newEnabled || budgetChanged {
                publishedMaster = nil   // belt-and-suspenders: not caught by the key comparison alone
            }
            if newEnabled, _globalRefiner == nil {
                _globalRefiner = makeRefinerLocked()
            }
            shouldNotify = newEnabled && (enabledRose || kappaChanged || budgetChanged)
            if shouldNotify { refinerToNotify = _globalRefiner }
        }
        if shouldNotify { refinerToNotify?.noteChanged() }
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
        let (capturedSurvivors, capturedKey): ([SubRegistration], FreshnessKey) = regLock.withLock {
            (currentSurvivorsLocked(currentGeneration: capturedGen), _freshnessKey)
        }
        guard engine.currentStackGeneration == capturedGen else { return nil }   // reseed raced the snapshot
        return PassSnapshot(survivors: capturedSurvivors, currentGeneration: capturedGen, key: capturedKey)
    }

    /// The `GlobalRefiner.publish` seam — installs a completed pass's result stamped with the
    /// SNAPSHOT's own key (never a freshly-read one — see `makeRefinerSnapshot` doc and the
    /// stale-result race fix). If a reject/κ/reseed landed mid-pass, `_freshnessKey` has already
    /// advanced past this `key`, so `publishedMasterIfCurrent()` correctly refuses to serve this
    /// as current — the mutation that moved the key already triggered its own fresh pass.
    private func publishRefineResult(_ result: RefineResult, key: FreshnessKey) {
        regLock.withLock {
            publishedMaster = PublishedMaster(image: result.image, coverage: result.coverage,
                                              survivorCount: result.survivorCount, key: key)
        }
    }

    /// Returns the published master ONLY while the live-rejection feature is ON and its stored
    /// key still equals the CURRENT freshness key — i.e. no reseed, user reject, or κ change has
    /// landed since it was published. Both reads happen under one `regLock` acquisition so a
    /// concurrent publish/mutation can't be observed torn.
    public func publishedMasterIfCurrent() -> (image: AstroImage, coverage: [Float], survivorCount: Int)? {
        regLock.withLock {
            guard liveRejectionActive, let pm = publishedMaster, pm.key == _freshnessKey else { return nil }
            return (image: pm.image, coverage: pm.coverage, survivorCount: pm.survivorCount)
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
            regLock.withLock { recomputeCachedFreshnessKeyLocked() }
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
        let mean = cropToCoverage(mean0, coverage: coverage)   // online — feeds the PREVIEW, unchanged (Task 9)
        guard let recorder else { onLog?("recorder missing — frame dropped (\(sourceName))"); return }
        do {
            let displaySource = mean.downsampled(maxLongEdge: importPreviewLongEdge)
            let previewCG = try displayCGImage(from: displaySource)

            // BROADCAST/latest.png (Task 9): prefer the background refiner's clean published
            // master when it's still current (the T7 freshness gate — reject/κ/reseed/feature-off
            // all invalidate it inside publishedMasterIfCurrent() itself); otherwise this is the
            // SAME online source as the preview above — reuse its render rather than paying the
            // display pipeline twice on the common (no-clean-master) path. The per-sub PREVIEW
            // (onUpdate below) never consults publishedMasterIfCurrent() — it always renders from
            // the online mean, exactly as before this task.
            let published = publishedMasterIfCurrent()
            let broadcastCG: CGImage
            let broadcastMean: AstroImage
            // T9b: when the CLEAN master is served, its depth is `survivorCount` (smaller than
            // the online frame count after rejections) — use it so the overlay's integration time
            // matches the displayed image. The online-fallback branch is unchanged.
            let integrationFrames: Int
            if let published {
                broadcastMean = cropToCoverage(published.image, coverage: published.coverage)
                broadcastCG = try displayCGImage(from: broadcastMean.downsampled(maxLongEdge: importPreviewLongEdge))
                integrationFrames = published.survivorCount
            } else {
                broadcastMean = mean
                broadcastCG = previewCG
                integrationFrames = engine.stackFrameCount
            }

            let record = try recorder.save(
                cgImage: broadcastCG, linear: broadcastMean, sourceFile: sourceName,
                index: index, timestamp: timestamp,
                estimatedIntegrationSeconds: Double(integrationFrames) * profile.subExposureSeconds)
            try session.recordSnapshot(record)
            lastRenderedAcceptedIndex = index
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
        // North-up (3b): rotate the DISPLAY only, when toggled on AND a solve is available. Applied here
        // so broadcast, latest.png, snapshots and replay all inherit it; master.fit stays native. No-op
        // (return cg) when the toggle is off or nothing is solved.
        if adj.northUp, let wcs = currentWCS {
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
        return try? displayCGImage(from: mean)
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
                lastAutoReseedCount = engine.autoReseedCount
                // The engine dropped its reference and will re-seed on the next good sub — void the
                // stale WCS and re-enable solving so the NEW reference plate-solves (its center/rotation
                // can differ). MUST run before attemptPlateSolveIfNeeded below so this frame's attempt
                // sees the reset state (manual reseed() does the same via invalidatePlateSolve()).
                invalidatePlateSolve()
                // T8 review fix: an auto-reseed is a FreshnessKey mutation point (generation change)
                // exactly like manual reseed() (see reseed()'s matching block ~681-685) — refresh the
                // cached key HERE so publishedMasterIfCurrent() immediately stops serving a master built
                // from the just-discarded reference, instead of staying stale until the next accepted
                // sub's .becameReference append happens to recompute it. Lock-safety: neither `regLock`
                // nor the engine lock is held at this point — `engine.processDetailed` above already
                // acquired+released the engine's own lock — so this matches reseed()'s established
                // regLock -> engine.lock leaf-edge ordering with no new cycle. By this point
                // engine.autoReseedCount has already been bumped (checked just above), so the recompute
                // observes the POST-reseed generation.
                regLock.withLock { recomputeCachedFreshnessKeyLocked() }
                noteReseeded()
                onLog?("Auto-reseeded — the reference frame didn't match; re-seeding on the next good sub. (Earlier subs that couldn't register stay rejected.)")
            }
            attemptPlateSolveIfNeeded(engine: engine)   // idempotent; no-op until a reference is seeded
            processedCount += 1
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
                guard let (mean0, coverage) = engine.currentStackAndCoverage() else { return }
                let mean = cropToCoverage(mean0, coverage: coverage)   // online — feeds the PREVIEW, unchanged (Task 9)
                guard let recorder else {
                    onLog?("recorder missing — frame dropped (\(frame.sourceName))")
                    return
                }
                do {
                    let previewCG = try displayCGImage(from: mean)

                    // BROADCAST/latest.png (Task 9): prefer the background refiner's clean
                    // published master when it's still current, else this is the SAME online
                    // source as the preview above — reuse its render rather than paying the
                    // display pipeline twice on the common (no-clean-master) path. The per-sub
                    // PREVIEW (onUpdate below) never consults publishedMasterIfCurrent() — it
                    // always renders from the online mean, exactly as before this task.
                    let published = publishedMasterIfCurrent()
                    let broadcastCG: CGImage
                    let broadcastMean: AstroImage
                    // T9b: when the CLEAN master is served, its depth is `survivorCount` (smaller
                    // than the online frame count after rejections) — use it so the overlay's
                    // integration time matches the displayed image. The online-fallback branch is
                    // unchanged.
                    let integrationFrames: Int
                    if let published {
                        broadcastMean = cropToCoverage(published.image, coverage: published.coverage)
                        broadcastCG = try displayCGImage(from: broadcastMean)
                        integrationFrames = published.survivorCount
                    } else {
                        broadcastMean = mean
                        broadcastCG = previewCG
                        integrationFrames = engine.stackFrameCount
                    }

                    // Pass the raw un-neutralized mean as linear: stats stay raw for v1.1 cloud gate.
                    let record = try recorder.save(
                        cgImage: broadcastCG, linear: broadcastMean, sourceFile: frame.sourceName,
                        index: engine.acceptedCount, timestamp: frame.timestamp,
                        estimatedIntegrationSeconds: Double(integrationFrames) * profile.subExposureSeconds)
                    try session.recordSnapshot(record)
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
                currentRefiner()?.cancel()

                let final = try eng.finalizationState()
                let outcome: MasterOutcome
                switch final.stackState {
                case .active:
                    guard let master0 = final.image else {
                        throw StackEngine.FinalizationError.invariantBreach
                    }
                    // Choose the master using ONLY the frozen values above (never the live
                    // liveRejectionActive/_freshnessKey/publishedMaster — those may have moved).
                    var clean: (image: AstroImage, coverage: [Float], survivorCount: Int)?
                    if frozen.active {
                        if let pub = frozen.published, pub.key == frozen.key {
                            // A background pass already published a master current as of the
                            // freeze — use it, no final pass needed.
                            clean = (pub.image, pub.coverage, pub.survivorCount)
                        } else if let refiner = currentRefiner() {
                            // No current published master — run ONE bounded final pass against the
                            // FROZEN survivor set. The deadline alone bounds it (step 4 already
                            // cancelled the background pass, so nothing else cancels this one); a
                            // nil result (deadline/failure) falls back to the online master below.
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
                    }
                    // frozen.active == false → the clean path is skipped entirely (feature-off
                    // parity fix): no publishedMaster use, no final refine — `clean` stays nil and
                    // the online master below is written, byte-identical to today.

                    // All output goes through the shared crop-to-coverage + additive-neutralize +
                    // FITS-metadata path (RestackPlanning.encodeMaster) — same path a post-session
                    // re-stack uses — so master.fit never diverges pixel-for-pixel between the two.
                    let report: RestackReport
                    if let clean {
                        // CLEAN global result: STACKCNT/TOTALEXP reflect the count that actually
                        // combined into the written pixels, not the online engine's frame count.
                        report = RestackReport(master: clean.image, stackedCount: clean.survivorCount,
                                               skippedMissing: 0, skippedMismatch: 0, unverifiedLegacy: false,
                                               coverage: clean.coverage)
                    } else {
                        // Online fallback / feature-off: EXACTLY today's counts, for byte parity.
                        report = RestackReport(master: master0, stackedCount: final.frameCount,
                                               skippedMissing: 0, skippedMismatch: 0, unverifiedLegacy: false,
                                               coverage: final.coverage)
                    }
                    let masterData = RestackPlanning.encodeMaster(
                        report, neutralize: neutralizeBackground,
                        metadata: sourceMetadata, subExposureSeconds: profile.subExposureSeconds)
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
