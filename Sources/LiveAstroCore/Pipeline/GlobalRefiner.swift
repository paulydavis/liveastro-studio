import Foundation

/// Reproduces a REGISTERED sub's calibrated, display-RGB, UN-warped frame for the
/// `GlobalRefiner` — exactly what the online `StackEngine` fed to `Warp.apply`.
/// **Digest-only verification**: `expectedContentDigest` is the content-SHA256 captured at
/// online-pass time (stat fields zeroed — see `SubRegistration.contentDigest`); a full
/// stat-inclusive `FileIdentity` check would spuriously fail on re-read (a Google-Drive
/// mirror / SMB re-sync recreates a byte-identical file with a new inode/mtime — the
/// re-stack P1b lesson). Tests inject a stub; `ProductionFrameLoader` below is the real impl.
protocol FrameLoader {
    func loadRegisteredInput(url: URL, expectedContentDigest: String?) throws -> AstroImage
}

/// Production `FrameLoader` (Task 6 I2): applies the session's ACTUALLY-APPLIED calibrator
/// (the caller must pass `SessionPipeline.effectiveCalibrator`, NOT a freshly-rebuilt one —
/// a rebuilt calibrator resolves to nil for an empty-folder live start), then the shared
/// `DisplayRGB.make` with the SAME `DemosaicMethod` the engine was built with — one
/// implementation, no drift between the online and refine domains a warped/leveled sub is
/// compared in.
///
/// T8 review fix: the calibrator is resolved LAZILY, at PASS time (inside
/// `loadRegisteredInput`), via a closure — never baked in at construction. Baking it in at
/// refiner-creation time (i.e. at `configureLiveRejection(enabled: true)`) was (a) a
/// cross-thread unsynchronized read of the pipeline's `calibrator`/`providerCalibrator`
/// (documented "serial consume task, no lock" fields) taken from whatever thread enables live
/// rejection, and (b) if live rejection was enabled before the first frame resolved the
/// provider calibrator (empty-folder live start), the refiner would bake in nil forever and
/// load UNcalibrated frames — diverging from the online (calibrated) path. Reading
/// `effectiveCalibrator` at pass time still satisfies I2 (it's the SAME stashed field, not a
/// freshly-rebuilt calibrator), just read later, by which point subs exist and it's resolved.
struct ProductionFrameLoader: FrameLoader {
    private let calibratorProvider: () -> Calibrator?
    private let demosaic: DemosaicMethod

    init(calibratorProvider: @escaping () -> Calibrator?, demosaic: DemosaicMethod) {
        self.calibratorProvider = calibratorProvider
        self.demosaic = demosaic
    }

    func loadRegisteredInput(url: URL, expectedContentDigest: String?) throws -> AstroImage {
        let raw = try FolderFrameSource.loadRawFrame(url: url, expectedDigest: expectedContentDigest)
        let calibrated = calibratorProvider()?.apply(raw) ?? raw
        return DisplayRGB.make(calibrated, demosaic: demosaic)
    }
}

/// Bounded, cancellable, background live-rejection pass (spec §3, GlobalCombine): reproduces
/// each surviving sub from the Task 5 registration cache (load calibrated frame → warp →
/// level), computes a robust per-pixel center over a RAM sample, then a weighted clipped mean
/// over ALL survivors — removing satellite trails / cosmic rays the online winsorized engine
/// can't (its per-pixel state only ever sees ONE frame at a time).
public final class GlobalRefiner {
    /// Aborts the CURRENT `refine` pass (cancel or past-deadline) — always unwinds to `nil`
    /// (the online master is kept; never a partial publish).
    private struct AbortPass: Error {}

    /// Cold-review fix (the M8 stall class, re-introduced): a heap-allocated, lock-guarded box
    /// carrying `boundedLoad`'s result from its concurrent worker back to the waiter. The
    /// `DispatchSemaphore` in `boundedLoad` already establishes happens-before ordering for the
    /// success path (the worker `set`s before `signal()`; the waiter only `get()`s after a
    /// successful `wait()`), but the box is guarded anyway so a late write from an abandoned
    /// (timed-out) worker — which nothing reads — can never race a future reuse of the box (it
    /// isn't reused; a fresh box is allocated per call, but the lock keeps this provably race-free
    /// rather than relying solely on the semaphore's ordering).
    private final class LoadResultBox {
        private let lock = NSLock()
        private var result: Result<AstroImage, Error>?
        func set(_ value: Result<AstroImage, Error>) { lock.withLock { result = value } }
        func get() -> Result<AstroImage, Error>? { lock.withLock { result } }
    }

    private let loader: FrameLoader
    private let onLog: (String) -> Void

    /// Concrete NSLock-guarded cancellation flag (C3/step 7) — NOT `Task.isCancelled`, since a
    /// pass runs on a caller-owned `DispatchQueue`, not a `Task`. Each `refine` call stamps a
    /// fresh, monotonically-incrementing `passId`; `cancel()` only ever records WHICHEVER id is
    /// current at the moment it's called. Because a passId is never reused and `cancelledPassId`
    /// is never reset, a `cancel()` that lands after its target pass already finished (and
    /// before the NEXT pass starts) leaves a stale id on record that can never equal a later
    /// pass's fresh id — so a late `cancel()` can't kill the next pass.
    ///
    /// IMPORTANT: `refine()` is NOT guaranteed to have at most one active caller. `cancel()`
    /// only flags a pass; it does not wait for it to unwind. `SessionPipeline.end()` calls
    /// `currentRefiner()?.cancel()` and then, WITHOUT waiting, runs its OWN final `refine(...)`
    /// call directly on the caller's thread against the SAME `GlobalRefiner` instance — whose
    /// background pass (on `triggerQueue`) may still be mid-unwind. So two `refine()` calls can
    /// genuinely execute concurrently on one instance. Every field `refine()` mutates that is
    /// visible across those two calls (currently: `currentPassId`, `cancelledPassId` via
    /// `stopRequested()`, and `lastMaterializedSampleCount`) MUST go through `passLock`. Anything
    /// added to `refine()` in the future that mutates `self` needs the same treatment unless it's
    /// provably pass-local (a local variable never assigned to a stored property).
    private let passLock = NSLock()
    private var currentPassId = 0
    private var cancelledPassId: Int?

    /// Test-only observability seam (P2-2 / brief step 1): the materialized RAM-sample size,
    /// AFTER the odd-invariant adjustment, from the most recently STARTED `refine` call.
    /// `GlobalCombine.robustCenter` is a pure static func with no spy seam, so a capped pass's
    /// selected-frame-failure → even → drop-last behavior is asserted observably through this
    /// rather than inferred indirectly from output pixels.
    ///
    /// T10 review fix: backed by `_lastMaterializedSampleCount` and read/written ONLY through
    /// `passLock` — see the concurrency note on `passLock` above. Two `refine()` calls (a
    /// background pass and `end()`'s final pass) can run concurrently on the same instance and
    /// both write this field; unlike `currentPassId`/`cancelledPassId` (already guarded), this
    /// field was previously read/written with no synchronization at all — a genuine data race
    /// under Swift's memory model, even though it's test-only and never reaches `master.fit`.
    private var _lastMaterializedSampleCount: Int?
    var lastMaterializedSampleCount: Int? {
        passLock.withLock { _lastMaterializedSampleCount }
    }

    init(loader: FrameLoader, onLog: @escaping (String) -> Void,
               maxConcurrentLoads: Int = GlobalRefiner.defaultMaxConcurrentLoads) {
        self.loader = loader
        self.onLog = onLog
        self.maxConcurrentLoads = maxConcurrentLoads
        self.loaderPool = DispatchSemaphore(value: maxConcurrentLoads)
    }

    // MARK: - Task 8: self-throttling trigger, off the online path
    //
    // `noteChanged()` is the ONLY entry point the online consumer calls, and it must return
    // immediately — it never blocks on I/O or on a pass in flight. Coalescing rule: idle → start
    // exactly one pass; a pass already running → set `dirty` so exactly ONE more pass runs after
    // the current one finishes (never N, however many times `noteChanged()` fires while busy).
    // `runCoalescedPasses()` runs the idle→busy→(rerun-if-dirty) loop on `triggerQueue`, a
    // dedicated serial queue distinct from `passLock`/`cancel()` above (which guard `refine`'s own
    // internal cancellation, not this coalescing state) — a WHILE loop, not recursion, so N rapid
    // `noteChanged()` calls can never grow the call stack.

    /// Injected by the owner (`SessionPipeline`, Task 8) — builds a race-checked snapshot of the
    /// current survivor set + generation + `FreshnessKey` for ONE pass. Returning nil DISCARDS the
    /// pass with no `refine` call (e.g. a reseed raced the snapshot build) — the mutation that
    /// caused the race is itself an invalidation hook that calls `noteChanged()`, so `dirty` is
    /// already set and a fresh pass follows. Never set ⇒ `noteChanged()` is a safe no-op (matches
    /// feature-OFF parity: the pipeline only wires this once live rejection is first enabled).
    var makeSnapshot: (() -> PassSnapshot?)?
    /// Injected by the owner — installs a COMPLETED pass's result. Called with the snapshot's OWN
    /// captured key, never a freshly-read one (the stale-result race fix: see `PassSnapshot` doc).
    var publish: ((RefineResult, FreshnessKey) -> Void)?
    /// Injected config seams, read fresh at the START of every pass (so a κ/budget change that
    /// lands between passes is picked up by the very next one). nil ⇒ the documented default.
    var kappaProvider: (() -> Float)?
    var maxSampleBytesProvider: (() -> Int)?
    var minSubsProvider: (() -> Int)?

    static let defaultKappa: Float = RejectionStrength.medium.kappa
    public static let defaultMinSubs = 5
    public static let defaultMaxSampleBytes = 6_000_000_000   // ~6 GB (spec §3 sample policy default)
    /// Hard floor for the materialized RAM-sample size (spec §3 Global Constraints) — below this,
    /// a robust median/MAD center is under-powered. Shared with `AppModel`'s advisory budget check
    /// so the two never drift.
    public static let minViableSampleFrames = 11
    /// Per-pass time budget for a BACKGROUND trigger pass (this file) — distinct from the Task 10
    /// `end()`-triggered final pass, which uses its own `finalRefineBudget`. The design spec's
    /// Global Constraints section does not pin a value for this trigger path (only the ~6 GB
    /// sample-budget default and the 11-frame hard floor are specified), so this is a deliberately
    /// chosen, named default: long enough for a deep real stack (dozens of 26 MP loads + warps +
    /// leveling passes) to complete in one pass, short enough that a wedged/dead-share read can't
    /// pin the trigger queue indefinitely — `refine`'s own between-sub deadline check (C3) aborts
    /// at this bound and `noteChanged()`'s coalescing (via whatever invalidation fired meanwhile)
    /// runs a fresh pass afterward regardless.
    static let defaultPassBudget: DispatchTimeInterval = .seconds(300)
    var passBudget: DispatchTimeInterval = GlobalRefiner.defaultPassBudget

    /// Cold-review fix (the M8 watcher-stall class, re-introduced HERE): macOS cannot interrupt
    /// an in-flight regular-file `read()` — `close()` does not unblock it, confirmed in
    /// `docs/history/specs/2026-08-24-watcher-async-reads-design.md` for this exact bug class in
    /// the live watcher. `refine`'s only liveness check (`stopRequested()`/`deadline` in
    /// `loadWarp`) runs BETWEEN loads, never DURING one — so a single evicted-iCloud/dead-SMB
    /// survivor's `Data(contentsOf:)` inside `ProductionFrameLoader` could wedge `refine` forever,
    /// past every deadline: `SessionPipeline.end()`'s final pass would never return (master.fit
    /// never written, "End Session" spins forever), and a wedged BACKGROUND pass would never let
    /// `runCoalescedPasses` reset `isRunning`, permanently stalling the coalescer.
    ///
    /// `boundedLoad` (see `refine`) is the fix: it can't interrupt the read either, but it stops
    /// WAITING on it — the blocking call runs on a shared concurrent `.utility` queue and the
    /// caller bounds its WAIT with a `DispatchSemaphore` timeout of
    /// `min(now + perSubLoadCap, passDeadline)`. `perSubLoadCap` is this bound: long enough that a
    /// healthy 26 MP read off local disk or a reasonable network share (well under a second in
    /// practice) never comes close to tripping it, short enough that one wedged file can't pin a
    /// pass for more than this long before the pass moves on. Tune-able; tests shrink it (and, via
    /// `SessionPipeline.refinerPerSubLoadCapOverride`, the pipeline's own refiner) to stay fast.
    ///
    /// On timeout, the abandoned worker's `read()` is NOT cancelled — it can't be (see above) — so
    /// its `DispatchQueue.global(qos: .utility)` thread leaks until the kernel eventually returns
    /// the call (SMB: on the order of minutes; an evicted-iCloud fileprovider: possibly never).
    /// This is the same accepted, documented tradeoff the watcher fix landed on: true interruption
    /// is impossible on macOS for a wedged regular-file read, so the achievable envelope is
    /// bounding the WAIT, not the read.
    var perSubLoadCap: DispatchTimeInterval = .seconds(20)

    /// Cold-review fix (the leak-multiplies class, re-introduced yet again): `boundedLoad`
    /// bounds the WAIT on a timed-out load but cannot cancel the underlying worker (macOS can't
    /// interrupt an in-flight regular-file `read()` — see `perSubLoadCap` above), so a timed-out
    /// worker is ABANDONED still blocked in `read()`, holding a ~400MB frame buffer and a
    /// `.utility` thread. Under a PERSISTENTLY dead share this leak multiplies: every pass
    /// re-attempts every survivor, leaking roughly `passBudget / perSubLoadCap` workers PER
    /// PASS — over a multi-hour session this climbs toward the process-wide pthread ceiling
    /// (~512), silently starving every other subsystem (the M8 stall class one layer out).
    ///
    /// The fix is a bounded pool: `loaderPool` caps the number of loader workers that may be
    /// LIVE (dispatched-but-not-yet-returned) at once, regardless of how many have timed out and
    /// been abandoned by their waiters. A wedged worker holds its pool slot until its `read()`
    /// actually returns (the worker signals the pool itself, in a `defer`, on every exit path —
    /// never the waiter, since the waiter has no way to know whether the worker is done). Once
    /// `maxConcurrentLoads` workers are all wedged, further loads skip (pool-wait times out) and
    /// the pass falls back to whatever it already has — degrading toward "keep the online
    /// master" rather than exhausting the process.
    ///
    /// 6 is a modest, deliberately chosen value: on a healthy share every load completes in
    /// milliseconds and signals the pool immediately, so 6 in-flight slots are never a
    /// throughput bottleneck (loads are effectively serialized-fast, not queued). Under a dead
    /// share, 6 is the hard cap on leaked workers/buffers — at most ~2.4 GB and 6 threads, ever,
    /// no matter how many passes run — after which the clean master quietly falls back to the
    /// online master. Bounded damage, the M8 philosophy.
    static let defaultMaxConcurrentLoads = 6
    /// Instance-settable so tests can shrink the pool without touching the `static let` default
    /// (tests inject a small pool + a controlled number of wedged loaders to prove the cap holds
    /// without needing hundreds of concurrent threads to observe it).
    let maxConcurrentLoads: Int
    private let loaderPool: DispatchSemaphore

    private let triggerLock = NSLock()
    private var isRunning = false
    private var dirty = false
    private let triggerQueue = DispatchQueue(label: "com.liveastro.globalrefiner.trigger")

    /// Test-only observability: number of passes actually EXECUTED (i.e. `performOnePass` ran,
    /// whether or not it produced/published a result) — distinguishes "coalesced away" from "ran".
    private(set) var passesRun = 0

    /// Notify the refiner that the survivor set (or config) may have changed. Coalesces: idle →
    /// dispatches exactly one pass; a pass already running → marks `dirty` so exactly one more
    /// pass follows. Always returns immediately — the actual pass runs on `triggerQueue`.
    func noteChanged() {
        let shouldStart: Bool = triggerLock.withLock {
            if isRunning {
                dirty = true
                return false
            }
            isRunning = true
            return true
        }
        guard shouldStart else { return }
        triggerQueue.async { [weak self] in self?.runCoalescedPasses() }
    }

    /// Runs on `triggerQueue`. A WHILE loop (not recursion) so any number of `noteChanged()` calls
    /// that land while busy still produce at most one extra pass, with bounded stack depth.
    private func runCoalescedPasses() {
        while true {
            performOnePass()
            let runAgain: Bool = triggerLock.withLock {
                if dirty {
                    dirty = false
                    return true
                }
                isRunning = false
                return false
            }
            if !runAgain { break }
        }
    }

    /// One background pass: snapshot → refine → publish. Any missing seam (no `makeSnapshot`, a
    /// discarded/nil snapshot, or a `refine` that returns nil) is a silent no-op — the caller keeps
    /// whatever master was already published; there is no partial/erroneous publish.
    private func performOnePass() {
        passesRun += 1
        guard let snapshot = makeSnapshot?() else { return }
        let kappa = kappaProvider?() ?? GlobalRefiner.defaultKappa
        let minSubs = minSubsProvider?() ?? GlobalRefiner.defaultMinSubs
        let maxSampleBytes = maxSampleBytesProvider?() ?? GlobalRefiner.defaultMaxSampleBytes
        let deadline = DispatchTime.now() + passBudget
        guard let result = refine(survivors: snapshot.survivors, currentGeneration: snapshot.currentGeneration,
                                  kappa: kappa, minSubs: minSubs, maxSampleBytes: maxSampleBytes,
                                  deadline: deadline, isCancelled: { false }) else { return }
        // NEVER re-read the current freshness key here — publish under the SNAPSHOT's key (see
        // the stale-result race doc on PassSnapshot/publish above). If a reject/κ/reseed landed
        // mid-pass, the pipeline's live key has already advanced past `snapshot.key`, so
        // `publishedMasterIfCurrent()` correctly refuses to serve this result as current, and the
        // invalidation that moved the key already called `noteChanged()` (dirty ⇒ a fresh pass
        // follows in the `while` loop above).
        publish?(result, snapshot.key)
    }

    /// Marks the pass CURRENTLY in flight (or about to start) as cancelled. See the `passLock`
    /// doc above for why a late call can't cancel a future pass.
    func cancel() {
        passLock.withLock { cancelledPassId = currentPassId }
    }

    /// - Parameters:
    ///   - survivors: already-snapshotted (M3, Task 8) — `refine` does not re-read the pipeline.
    ///   - currentGeneration: the generation to filter to, by EXPLICIT equality (never majority —
    ///     after a reseed, old-generation frames could outnumber the new ones).
    ///   - kappa: `GlobalCombine.clippedWeightedMean` clip multiple.
    ///   - minSubs: quorum floor, both for the materialized RAM sample and the final survivor
    ///     count (same value as the Task 11 online gate).
    ///   - maxSampleBytes: RAM budget for the robust-center sample; `maxSampleFrames` is derived
    ///     from the first successfully-loaded frame's actual size. `maxSampleFrames < minViableSampleFrames`
    ///     is a HARD floor — the pass logs and returns nil (online master kept) rather than
    ///     computing an under-powered robust center.
    ///   - deadline / isCancelled: checked BETWEEN every per-sub load+warp (the minutes-long
    ///     part); the per-pixel CPU reduction inside `robustCenter`/`clippedWeightedMean` (~
    ///     seconds at 26MP) is not interruptible mid-loop — acceptable, the between-sub work
    ///     dominates the bound.
    func refine(survivors: [SubRegistration], currentGeneration: Int, kappa: Float,
                       minSubs: Int, maxSampleBytes: Int, deadline: DispatchTime,
                       isCancelled: @escaping () -> Bool) -> RefineResult? {
        let thisPassId: Int = passLock.withLock {
            currentPassId += 1
            return currentPassId
        }
        func stopRequested() -> Bool {
            if isCancelled() { return true }
            return passLock.withLock { cancelledPassId == thisPassId }
        }
        // Bounds the WAIT on `loader.loadRegisteredInput`, not the read itself (uninterruptible
        // on macOS — see the `perSubLoadCap` doc). Dispatches the blocking load to a shared
        // concurrent `.utility` queue and waits with a semaphore timeout capped by BOTH
        // `perSubLoadCap` and this pass's own `deadline`, so the bound composes with the existing
        // per-pass budget instead of extending it. Returns:
        //   - the image, on a successful load within the bound;
        //   - throws the loader's own error, on a load failure within the bound (unchanged);
        //   - throws `AbortPass`, if the wait timed out AND the overall `deadline` has been
        //     reached (the pass-budget bound — same effect as today's between-loads check);
        //   - returns nil, if the wait timed out but `deadline` has NOT been reached (only
        //     `perSubLoadCap` elapsed) — a RECOVERABLE skip: this one sub is abandoned (its read
        //     may still be wedged; the worker thread leaks — see `perSubLoadCap` doc) but the pass
        //     continues with the remaining survivors, exactly like an ordinary load failure.
        func boundedLoad(url: URL, expectedContentDigest: String?) throws -> AstroImage? {
            // Same absolute deadline governs BOTH the pool-slot wait below and the
            // load-completion wait further down, so the total wait a caller can ever incur is
            // bounded by `perLoadDeadline` once, not twice.
            let perLoadDeadline = min(DispatchTime.now() + perSubLoadCap, deadline)

            // Acquire a pool slot BEFORE dispatching a worker — this is what caps the number of
            // concurrently-live (dispatched-but-not-returned) workers at `maxConcurrentLoads`,
            // even when every prior worker is permanently wedged in `read()`. Only the worker
            // itself ever signals this pool (see the `defer` below) — never here — because a
            // timed-out wait has no way to know whether its worker is actually done; signalling
            // from here would free a slot a still-blocked worker occupies, defeating the cap.
            if loaderPool.wait(timeout: perLoadDeadline) != .success {
                if DispatchTime.now() >= deadline { throw AbortPass() }   // pass-budget bound reached
                return nil   // no worker slot free (share wedged) — recoverable skip, budget remains
            }

            let box = LoadResultBox()
            let semaphore = DispatchSemaphore(value: 0)
            let loaderRef = loader
            let pool = loaderPool
            DispatchQueue.global(qos: .utility).async {
                // Releases the pool slot whenever THIS worker's read() actually returns — success,
                // failure, or (for an abandoned/wedged worker) however long that eventually takes.
                // This is the crux of the fix: a wedged worker holds its slot for its whole
                // (possibly unbounded) lifetime, so at most `maxConcurrentLoads` can ever be live.
                defer { pool.signal() }
                do {
                    let image = try loaderRef.loadRegisteredInput(url: url, expectedContentDigest: expectedContentDigest)
                    box.set(.success(image))
                } catch {
                    box.set(.failure(error))
                }
                semaphore.signal()
            }
            if semaphore.wait(timeout: perLoadDeadline) == .success {
                switch box.get() {
                case .success(let image): return image
                case .failure(let error): throw error
                case nil: return nil   // unreachable (set() always precedes signal()); safe fallback
                }
            }
            if DispatchTime.now() >= deadline { throw AbortPass() }   // pass-budget bound reached
            return nil   // perSubLoadCap bound only — recoverable skip, budget remains
        }

        // A load/digest failure RETURNS nil (recoverable — caller does skippedIds.insert).
        // Cancel/deadline THROWS AbortPass — unwinds the whole `refine` body below.
        func loadWarp(_ reg: SubRegistration) throws -> (image: AstroImage, mask: [Float])? {
            if stopRequested() || DispatchTime.now() >= deadline { throw AbortPass() }
            let rgb: AstroImage
            do {
                // Bounded wait: a wedged read can't block us past perSubLoadCap / the pass deadline.
                guard let image = try boundedLoad(url: reg.relayURL,
                                                  expectedContentDigest: reg.contentDigest) else {
                    return nil   // perSubLoadCap-only timeout → recoverable skip (budget remains)
                }
                rgb = image
            } catch is AbortPass {
                throw AbortPass()   // pass deadline reached — propagate, do NOT swallow as a skip
            } catch {
                onLog("live rejection: skipping sub \(reg.subIndex): \(error)")
                return nil          // loader/digest failure → recoverable skip
            }
            let (warped, mask) = Warp.apply(rgb, transform: reg.transform.liftedToFullResolution())
            guard let leveling = reg.leveling else { return (warped, mask) }
            let leveled = GradientLeveler.apply(warped, subModel: leveling.sub, refModel: leveling.ref,
                                                scale: reg.effectiveScale)
            return (leveled, mask)
        }

        // Skip tracking by subIndex for the WHOLE pass — never a scalar counter (a scalar could
        // double-count the same sub across the dim-probe / sample-build / output-stream phases).
        var skippedIds = Set<Int>()
        var loaded = [Int: (image: AstroImage, mask: [Float])]()
        var aborted = false

        do {
            // 1. Filter to the current generation by EXPLICIT equality — never majority.
            let inGen = survivors.filter { $0.stackGeneration == currentGeneration }

            // 2. Sizing: walk inGen in order; the FIRST reg whose loadWarp succeeds gives dims.
            var sampleFrameBytes: Int?
            for reg in inGen {
                if let result = try loadWarp(reg) {
                    loaded[reg.subIndex] = result
                    sampleFrameBytes = result.image.pixels.count * 4 + result.mask.count * 4
                    break
                }
                skippedIds.insert(reg.subIndex)
            }
            guard let sampleFrameBytes, sampleFrameBytes > 0 else {
                onLog("live rejection: no surviving subs could be loaded this pass")
                return nil   // none loaded → quorum fails
            }
            let maxSampleFrames = max(1, maxSampleBytes / sampleFrameBytes)
            guard maxSampleFrames >= GlobalRefiner.minViableSampleFrames else {
                onLog("live rejection off: insufficient sample budget "
                    + "(\(maxSampleFrames) < \(GlobalRefiner.minViableSampleFrames) frames)")
                return nil
            }

            // 3. Build the RAM sample (dimension-probe frame enters only if its index ∈ idxs).
            let idxs = SubRegistration.sampleIndices(count: inGen.count, maxSampleFrames: maxSampleFrames)
            var sample: [(image: AstroImage, mask: [Float])] = []
            for i in idxs {
                let reg = inGen[i]
                if let cached = loaded[reg.subIndex] {
                    sample.append(cached)
                } else if let result = try loadWarp(reg) {
                    loaded[reg.subIndex] = result
                    sample.append(result)
                } else {
                    skippedIds.insert(reg.subIndex)
                }
            }
            // Odd-invariant (P2-4): selected-frame load failures can leave the materialized
            // sample EVEN even though `idxs.count` was already odd (sampleIndices' own
            // reduction) — drop the last for a true per-pixel middle median, deterministically.
            if !sample.isEmpty, sample.count % 2 == 0 { sample.removeLast() }
            guard sample.count >= minSubs else { return nil }   // fail closed
            passLock.withLock { _lastMaterializedSampleCount = sample.count }

            guard let centerResult = GlobalCombine.robustCenter(sample: sample) else { return nil }
            let sampleCovered = centerResult.sampleCovered

            // 4. Output — reuse under budget, stream when capped.
            let combined: (image: AstroImage, coverage: [Float])?
            if inGen.count <= maxSampleFrames {
                // Under budget: idxs == all indices, so `loaded` already holds every survivor
                // that loaded successfully. Iterate in inGen ORDER (not loaded.values — dict
                // iteration is nondeterministic and Float summation order is byte-significant).
                let framesArr: [(image: AstroImage, mask: [Float], weight: Float)] = inGen.compactMap { reg in
                    loaded[reg.subIndex].map { (image: $0.image, mask: $0.mask, weight: reg.weight) }
                }
                combined = GlobalCombine.clippedWeightedMean(
                    frames: { AnyIterator(framesArr.makeIterator()) },
                    center: centerResult.center, scale: centerResult.scale,
                    sampleCovered: sampleCovered, kappa: kappa)
            } else {
                // Capped: stream fresh from the loader for subs not already cached from
                // sizing/sample-build. Two hazards (P2-3): (a) a per-sub load failure must NOT
                // return nil from the iterator (nil == "stream done", would truncate the
                // combine) — skip + advance instead; (b) an AbortPass sets the out-of-band
                // `aborted` flag and ends iteration; checked AFTER clippedWeightedMean below so
                // a cancel mid-stream can never publish a partial master as if it finished.
                var streamIdx = 0
                combined = GlobalCombine.clippedWeightedMean(
                    frames: {
                        AnyIterator<(image: AstroImage, mask: [Float], weight: Float)> {
                            while streamIdx < inGen.count {
                                let reg = inGen[streamIdx]
                                streamIdx += 1
                                if let cached = loaded[reg.subIndex] {
                                    return (cached.image, cached.mask, reg.weight)
                                }
                                do {
                                    if let result = try loadWarp(reg) {
                                        loaded[reg.subIndex] = result
                                        return (result.image, result.mask, reg.weight)
                                    }
                                    skippedIds.insert(reg.subIndex)   // recoverable — advance
                                } catch {
                                    aborted = true
                                    return nil                        // ends iteration only
                                }
                            }
                            return nil
                        }
                    },
                    center: centerResult.center, scale: centerResult.scale,
                    sampleCovered: sampleCovered, kappa: kappa)
            }
            if aborted { return nil }
            guard let combined else { return nil }

            // 5. Quorum over the WHOLE generation set (the frames that actually contributed —
            // what Task 10's STACKCNT/TOTALEXP use, not the pre-skip count).
            let contributing = inGen.count - skippedIds.count
            // defense-in-depth: unreachable given the sample-quorum check above (sample.count >=
            // minSubs) + loaded being monotonic across the pass, kept as a floor.
            guard contributing >= minSubs else { return nil }
            return RefineResult(image: combined.image, coverage: combined.coverage,
                                survivorCount: contributing, skipped: skippedIds.count)
        } catch {
            // Any AbortPass (cancel/deadline) thrown from the sizing or sample-build phases
            // unwinds here — never a partial publish; the caller keeps the last online master.
            return nil
        }
    }
}

struct RefineResult {
    let image: AstroImage
    let coverage: [Float]
    let survivorCount: Int
    let skipped: Int

    init(image: AstroImage, coverage: [Float], survivorCount: Int, skipped: Int) {
        self.image = image
        self.coverage = coverage
        self.survivorCount = survivorCount
        self.skipped = skipped
    }
}

/// Task 8: a race-checked, point-in-time snapshot of pipeline state for ONE background pass,
/// built by the owner's `makeSnapshot` closure. **The stale-result race fix lives in how this is
/// built, not in `GlobalRefiner` itself:** the owner must (1) read the engine's current stack
/// generation FIRST (its own lock, released immediately), (2) under its registration lock, snapshot
/// the survivors for that generation and the CACHED freshness-key field directly (never re-derive
/// it — that would re-acquire a non-recursive lock and deadlock), (3) release that lock, then
/// RE-READ the engine's generation — if it changed, return nil (a reseed raced the snapshot; the
/// pipeline's own reseed hook already called `noteChanged()`, so `dirty` reruns it). `key` is
/// stamped onto the eventual `RefineResult` at PUBLISH time UNCHANGED — never re-read at
/// completion — so a mutation that lands mid-pass is caught by the stored key going stale, not by
/// racing the publish itself.
struct PassSnapshot {
    let survivors: [SubRegistration]
    let currentGeneration: Int
    let key: FreshnessKey

    init(survivors: [SubRegistration], currentGeneration: Int, key: FreshnessKey) {
        self.survivors = survivors
        self.currentGeneration = currentGeneration
        self.key = key
    }
}
