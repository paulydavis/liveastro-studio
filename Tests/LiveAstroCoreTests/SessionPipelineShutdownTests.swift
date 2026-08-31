import XCTest
@testable import LiveAstroCore

final class SessionPipelineShutdownTests: XCTestCase {
    /// A live (isFinite == false) source that yields exactly one seed frame and then never
    /// finishes. Combined with a consumer callback that blocks forever (below), the consume
    /// task is wedged INSIDE synchronous frame handling — unresponsive even to cancellation,
    /// exactly the drain-timeout condition P1-3 must handle without finalizing a racing stack.
    final class WedgingLiveSource: FrameSource {
        let frames: AsyncStream<RawFrame>
        var isFinite: Bool { false }
        var totalCount: Int? { nil }
        init(seed: RawFrame) {
            frames = AsyncStream { cont in
                cont.yield(seed)
                // Never finish: the stream stays open so the consumer stays live.
            }
        }
        func start() throws {}
        func stop() {}
    }

    /// A live (isFinite == false) source that yields a BACKLOG of frames up front (all
    /// buffered before end()), stays open like a real live source, and finishes its stream
    /// on stop(). Models the 2026-08-28 ASI2600 real-data case: subs arrive faster than the
    /// consumer can register+stack 50 MB frames, so at end() a queue is still draining. The
    /// consumer is HEALTHY (each frame finalizes), just slow — the drain must wait it out,
    /// not cancel and discard the whole master.
    final class BacklogLiveSource: FrameSource {
        let frames: AsyncStream<RawFrame>
        private let cont: AsyncStream<RawFrame>.Continuation
        var isFinite: Bool { false }
        var totalCount: Int? { nil }
        init(seed: RawFrame, count: Int) {
            var c: AsyncStream<RawFrame>.Continuation!
            frames = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
            cont = c
            for i in 0..<count {
                cont.yield(RawFrame(image: seed.image, bayerPattern: nil, bottomUp: false,
                                    timestamp: Date(timeIntervalSince1970: TimeInterval(i)),
                                    sourceName: "sub\(i).fit"))
            }
            // Stream stays open (live source) until stop().
        }
        func start() throws {}
        func stop() { cont.finish() }
    }

    /// Like BacklogLiveSource but its stop() BLOCKS before finishing the stream — models a slow
    /// SMB/Drive watcher stop. The cold review (2026-08-28) PROVED that seeding the drain's first
    /// window from a deadline captured BEFORE this blocking stop shrank the first window to ~0 and
    /// discarded a healthy backlog. The fix must survive a slow stop.
    final class SlowStopBacklogLiveSource: FrameSource {
        let frames: AsyncStream<RawFrame>
        private let cont: AsyncStream<RawFrame>.Continuation
        private let stopDelay: TimeInterval
        var isFinite: Bool { false }
        var totalCount: Int? { nil }
        init(seed: RawFrame, count: Int, stopDelay: TimeInterval) {
            self.stopDelay = stopDelay
            var c: AsyncStream<RawFrame>.Continuation!
            frames = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
            cont = c
            for i in 0..<count {
                cont.yield(RawFrame(image: seed.image, bayerPattern: nil, bottomUp: false,
                                    timestamp: Date(timeIntervalSince1970: TimeInterval(i)),
                                    sourceName: "sub\(i).fit"))
            }
        }
        func start() throws {}
        func stop() { Thread.sleep(forTimeInterval: stopDelay); cont.finish() }
    }

    final class WedgingFiniteSource: FrameSource {
        let frames: AsyncStream<RawFrame>
        var isFinite: Bool { true }
        var totalCount: Int? { nil }
        init(seed: RawFrame) {
            frames = AsyncStream { cont in
                cont.yield(seed)
                // Never finish: finite import drain must eventually time out.
            }
        }
        func start() throws {}
        func stop() {}
    }

    final class SlowFirstFrameFiniteSource: FrameSource, FrameSourceActivityReporting {
        let frames: AsyncStream<RawFrame>
        private let cont: AsyncStream<RawFrame>.Continuation
        let frame: RawFrame
        var onActivity: ((FrameSourceActivity) -> Void)?
        var isFinite: Bool { true }
        var totalCount: Int? { 1 }

        init(frame: RawFrame) {
            self.frame = frame
            var c: AsyncStream<RawFrame>.Continuation!
            frames = AsyncStream { c = $0 }
            cont = c
        }

        func start() throws {
            Task.detached { [weak self] in
                guard let self else { return }
                self.onActivity?(.beginFrameRead(self.frame.sourceName))
                try? await Task.sleep(nanoseconds: 350_000_000)
                self.cont.yield(self.frame)
                self.onActivity?(.endFrameRead(self.frame.sourceName))
                self.cont.finish()
            }
        }

        func stop() { cont.finish() }
    }

    /// A finite source whose SECOND read spans MULTIPLE active-read windows before
    /// yielding — the ASI2600-over-WiFi case: a 50 MB sub read from a slow network share
    /// legitimately takes longer than one `importActiveReadTimeout` window. It emits
    /// `beginFrameRead` and holds the read (polling a stop flag) so `activeFrameReads`
    /// stays > 0 the whole time. If the drain cancels it (calls `stop()`), frame 2 is
    /// never delivered — so the stacked count distinguishes "kept waiting" (2) from
    /// "cancelled the live read as a stall" (1).
    final class SlowSecondReadFiniteSource: FrameSource, FrameSourceActivityReporting {
        let frames: AsyncStream<RawFrame>
        private let cont: AsyncStream<RawFrame>.Continuation
        private let seed: RawFrame
        private let readDelay: TimeInterval
        var onActivity: ((FrameSourceActivity) -> Void)?
        var isFinite: Bool { true }
        var totalCount: Int? { 2 }
        private let lock = NSLock()
        private var stopped = false

        init(seed: RawFrame, readDelay: TimeInterval) {
            self.seed = seed
            self.readDelay = readDelay
            var c: AsyncStream<RawFrame>.Continuation!
            frames = AsyncStream { c = $0 }
            cont = c
        }

        func start() throws {
            Task.detached { [weak self] in
                guard let self else { return }
                // Frame 1 (seed): a fast read that seeds the reference.
                self.onActivity?(.beginFrameRead("seed.fit"))
                self.cont.yield(self.seed)
                self.onActivity?(.endFrameRead("seed.fit"))
                // Frame 2: a read that legitimately spans several active-read windows.
                self.onActivity?(.beginFrameRead("slow2.fit"))
                let deadline = Date().addingTimeInterval(self.readDelay)
                while Date() < deadline {
                    if self.lock.withLock({ self.stopped }) {
                        self.cont.finish()   // cancelled mid-read: never deliver frame 2
                        return
                    }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                let f2 = RawFrame(image: self.seed.image, bayerPattern: nil, bottomUp: false,
                                  timestamp: Date(timeIntervalSince1970: 1), sourceName: "slow2.fit")
                self.cont.yield(f2)
                self.onActivity?(.endFrameRead("slow2.fit"))
                self.cont.finish()
            }
        }

        func stop() { lock.withLock { stopped = true }; cont.finish() }
    }

    /// A finite source that yields two frames with a gap of NO activity between them (no
    /// read events, activeReads stays 0) — models the tail of a 26MP import where the last
    /// frame's CPU-bound processing (register + warp + full-res snapshot) takes longer than
    /// the live drain's 10s window with no sibling frame to tick progress. The import is
    /// healthy, just slow; it must finalize, not be cancelled as a stall (2026-08-16).
    final class GapNoActivityFiniteSource: FrameSource {
        let frames: AsyncStream<RawFrame>
        private let cont: AsyncStream<RawFrame>.Continuation
        private let seed: RawFrame
        private let gap: TimeInterval
        var isFinite: Bool { true }
        var totalCount: Int? { 2 }
        init(seed: RawFrame, gap: TimeInterval) {
            self.seed = seed; self.gap = gap
            var c: AsyncStream<RawFrame>.Continuation!
            frames = AsyncStream { c = $0 }; cont = c
        }
        func start() throws {
            Task.detached { [weak self] in
                guard let self else { return }
                self.cont.yield(self.seed)   // frame 1 — no FrameSourceActivity emitted at all
                try? await Task.sleep(nanoseconds: UInt64(self.gap * 1_000_000_000))
                let f2 = RawFrame(image: self.seed.image, bayerPattern: nil, bottomUp: false,
                                  timestamp: Date(timeIntervalSince1970: 1), sourceName: "f2.fit")
                self.cont.yield(f2)
                self.cont.finish()
            }
        }
        func stop() { cont.finish() }
    }

    /// A finite source that emits ONE beginFrameRead and then hangs — a read that stays
    /// active but never progresses (a dead SMB read mid-syscall). The drain must declare it
    /// wedged after importPrimaryTimeout + importDeadReadWindowLimit × importActiveReadTimeout,
    /// NOT limit × (primary + active) (2026-08-17 review).
    final class HungReadFiniteSource: FrameSource, FrameSourceActivityReporting {
        let frames: AsyncStream<RawFrame>
        private let cont: AsyncStream<RawFrame>.Continuation
        var onActivity: ((FrameSourceActivity) -> Void)?
        var isFinite: Bool { true }
        var totalCount: Int? { 1 }
        init() {
            var c: AsyncStream<RawFrame>.Continuation!
            frames = AsyncStream { c = $0 }; cont = c
        }
        func start() throws { onActivity?(.beginFrameRead("hung")) }   // starts, never ends/yields
        func stop() { cont.finish() }                                  // cancel unblocks the consumer
    }

    /// A ≥15-star seed frame so the engine accepts it and fires onUpdate (our block point).
    private func seedFrame() -> RawFrame {
        let w = 256, h = 256
        var px = [Float](repeating: 0.05, count: w * h)
        var pts: [(Int, Int)] = []
        for i in 0..<20 { pts.append(((i * 47) % 240 + 8, (i * 83) % 240 + 8)) }
        for (sx, sy) in pts {
            for y in max(0, sy - 6)...min(h - 1, sy + 6) {
                for x in max(0, sx - 6)...min(w - 1, sx + 6) {
                    let dx = Double(x - sx), dy = Double(y - sy)
                    px[y * w + x] += 0.8 * Float(exp(-(dx * dx + dy * dy) / (2 * 2.0 * 2.0)))
                }
            }
        }
        let img = AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true)
        return RawFrame(image: img, bayerPattern: nil, bottomUp: false,
                        timestamp: Date(timeIntervalSince1970: 0), sourceName: "seed.fit")
    }

    func testEndThrowsShutdownTimeoutWhenConsumerWedged() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let profile = SessionProfile(targetName: "Hang Field", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let pipeline = SessionPipeline(nativeSource: WedgingLiveSource(seed: seedFrame()),
                                       engine: StackEngine(), profile: profile, rootDirectory: sessions)
        // Wedge the consumer inside synchronous frame handling: onUpdate blocks forever, so the
        // consume task cannot return even after cancellation → drain must give up and throw.
        let wedged = DispatchSemaphore(value: 0)
        pipeline.onUpdate = { _, _ in wedged.wait() }   // never signalled
        // Shrink the drain deadlines so the test runs fast. The live drain's wedge window is
        // liveDrainStallTimeout (not drainPrimaryTimeout), so shrink that too.
        pipeline.drainPrimaryTimeout = .milliseconds(200)
        pipeline.liveDrainStallTimeout = .milliseconds(200)
        pipeline.drainGraceTimeout = .milliseconds(200)
        try pipeline.start()
        // Give the consumer a moment to enter the wedged callback before ending.
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertThrowsError(try pipeline.end()) { error in
            XCTAssertEqual(error as? SessionPipelineError, .shutdownTimeout,
                           "end() must throw shutdownTimeout rather than finalizing a racing stack")
        }
        wedged.signal()   // release the wedged task so the process can exit cleanly
    }

    /// Regression (2026-08-28 ASI2600 real-data run): a LIVE session ended while the consumer
    /// is still draining a backlog of accepted frames — the frames arrived faster than the
    /// 50 MB register+stack could keep up — must DRAIN and write the master, not cancel the
    /// still-progressing consumer and discard the whole stack. Pre-fix the live drain waited a
    /// single flat `drainPrimaryTimeout` window and then cancelled, so a backlog that took
    /// longer than one window threw `.shutdownTimeout` and produced no master.fit (observed on
    /// three separate real sessions). Six frames × a 100 ms per-frame consumer cost = ~600 ms of
    /// draining, far past the 200 ms primary window; each frame finalizes within a window, so a
    /// PROGRESS-AWARE drain keeps waiting and all six stack.
    func testLiveDrainWaitsOutHealthyBacklogInsteadOfDiscardingMaster() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let profile = SessionProfile(targetName: "Backlog", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let engine = StackEngine()
        let pipeline = SessionPipeline(nativeSource: BacklogLiveSource(seed: seedFrame(), count: 6),
                                       engine: engine, profile: profile, rootDirectory: sessions)
        // Each accepted frame costs ~200 ms of consumer time (a Thread.sleep on top of the real
        // register + stack + snapshot-encode); the whole 6-frame backlog takes ~1.2 s+. Two things
        // are proven at once:
        //   • drainPrimaryTimeout is TINY (100 ms) — the wedge window must NOT be keyed on it, or
        //     the drain would cancel almost immediately (this pins the cold-review CRITICAL: a
        //     single 26 MP frame outlives the 10 s stop budget).
        //   • liveDrainStallTimeout (500 ms) is larger than one frame (~250 ms) but smaller than the
        //     whole backlog (1.2 s): a flat 500 ms window would cancel mid-backlog, but each frame
        //     finalizes within a window, so the progress-aware drain resets and waits it all out.
        pipeline.onUpdate = { _, _ in Thread.sleep(forTimeInterval: 0.2) }
        pipeline.drainPrimaryTimeout = .milliseconds(100)     // stop budget — deliberately tiny
        pipeline.liveDrainStallTimeout = .milliseconds(500)   // wedge window — one frame < this < backlog
        pipeline.drainGraceTimeout = .milliseconds(100)
        pipeline.rendersReplay = false   // exercise the drain, not the replay render

        try pipeline.start()
        // Let a couple of frames finalize so end() lands with the backlog still draining.
        Thread.sleep(forTimeInterval: 0.15)
        // Pre-fix this throws .shutdownTimeout (the flat window expires mid-backlog and cancels
        // the progressing consumer); post-fix it drains and returns the session dir.
        let dir = try pipeline.end()
        XCTAssertEqual(engine.stackFrameCount, 6,
                       "all six backlog subs must stack — the drain must wait out a progressing consumer")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("master.fit").path),
                      "the drained session must have written master.fit")
    }

    /// Cold-review PROVEN regression (2026-08-28): a SLOW `stop()` (dead/laggy SMB share) used to
    /// eat the drain's first window — it was seeded from a deadline captured BEFORE stop(), so by
    /// the time the drain ran the window was already expired and the consumer's during-stop progress
    /// was invisible → a healthy backlog was cancelled and the master discarded. The drain's wedge
    /// window must be a fresh full `liveDrainStallTimeout` independent of the (separately-bounded)
    /// stop time.
    func testLiveDrainSurvivesSlowStopWithBacklog() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let profile = SessionProfile(targetName: "SlowStop", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let engine = StackEngine()
        // stop() blocks 400 ms (≫ drainPrimaryTimeout 100 ms) while a 6-frame backlog drains.
        let source = SlowStopBacklogLiveSource(seed: seedFrame(), count: 6, stopDelay: 0.4)
        let pipeline = SessionPipeline(nativeSource: source, engine: engine,
                                       profile: profile, rootDirectory: sessions)
        pipeline.onUpdate = { _, _ in Thread.sleep(forTimeInterval: 0.15) }
        pipeline.drainPrimaryTimeout = .milliseconds(100)     // stop budget — far shorter than stop()
        pipeline.liveDrainStallTimeout = .milliseconds(500)   // wedge window — must be fresh & full
        pipeline.drainGraceTimeout = .milliseconds(100)
        pipeline.rendersReplay = false

        try pipeline.start()
        Thread.sleep(forTimeInterval: 0.05)
        let dir = try pipeline.end()
        XCTAssertEqual(engine.stackFrameCount, 6,
                       "a slow stop() must not shrink the drain window — all six backlog subs must stack")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("master.fit").path),
                      "the drained session must have written master.fit despite the slow stop")
    }

    func testFiniteImportDrainDoesNotCancelHealthySlowFirstRead() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let profile = SessionProfile(targetName: "Slow Import", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let pipeline = SessionPipeline(nativeSource: SlowFirstFrameFiniteSource(frame: seedFrame()),
                                       engine: StackEngine(), profile: profile, rootDirectory: sessions)
        pipeline.drainPrimaryTimeout = .milliseconds(100)
        pipeline.importPrimaryTimeout = .milliseconds(100)
        pipeline.drainGraceTimeout = .milliseconds(100)
        pipeline.importActiveReadTimeout = .seconds(2)
        pipeline.rendersReplay = false   // this test exercises the drain, not the replay render

        try pipeline.start()
        XCTAssertNoThrow(try pipeline.end(),
                         "a finite import actively reading its first sub must not be cancelled merely because no frame has finalized yet")
    }

    /// Regression (ASI2600-over-WiFi, 2026-08-16): a single 50 MB sub read from a slow SMB
    /// share exceeds one `importActiveReadTimeout` window. The stall-watchdog used to grant
    /// exactly one window and then cancel — killing the import after the seed and finalizing
    /// with 1 frame. A read that is genuinely in flight (activeReads > 0) is slow, not stalled,
    /// and must be allowed to complete. Both subs must stack.
    func testFiniteImportToleratesReadSpanningMultipleActiveWindows() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let profile = SessionProfile(targetName: "Slow Share", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let engine = StackEngine()
        // readDelay (450ms) spans ~3 active-read windows (150ms each), well past the single
        // window the old code tolerated, but under the dead-share cap (5 × 150ms = 750ms).
        // readDelay (500ms) spans ~2 active-read windows (300ms each) — comfortably past the
        // single window the old code tolerated, comfortably under the dead-share cap
        // (5 × 300ms = 1.5s). Margins are wide so scheduling jitter can't flip the outcome.
        let source = SlowSecondReadFiniteSource(seed: seedFrame(), readDelay: 0.5)
        let pipeline = SessionPipeline(nativeSource: source,
                                       engine: engine, profile: profile, rootDirectory: sessions)
        pipeline.drainPrimaryTimeout = .milliseconds(150)
        pipeline.importPrimaryTimeout = .milliseconds(150)
        pipeline.drainGraceTimeout = .milliseconds(150)
        pipeline.importActiveReadTimeout = .milliseconds(300)
        pipeline.rendersReplay = false   // this test exercises the drain, not the replay render

        try pipeline.start()
        XCTAssertNoThrow(try pipeline.end())
        XCTAssertEqual(engine.stackFrameCount, 2,
                       "a sub read spanning multiple active-read windows must not be cancelled as a stall — both subs must stack")
    }

    /// Regression (ASI2600, 2026-08-16): a healthy finite import whose frames finalize with a
    /// gap longer than the live drain window (`drainPrimaryTimeout`) but shorter than the
    /// import window (`importPrimaryTimeout`) must COMPLETE, not throw shutdownTimeout. This
    /// is the import tail: the last 26MP frame processes alone (no read activity, no sibling
    /// finalize) for longer than 10s. The finite drain must use the generous import window.
    func testFiniteImportToleratesProcessingGapLongerThanLiveWindow() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let profile = SessionProfile(targetName: "Slow Tail", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let engine = StackEngine()
        // gap (400ms) > live window (100ms) but < import window (1500ms) → old code (finite
        // drain on drainPrimaryTimeout) cancelled after the seed; new code waits it out.
        let source = GapNoActivityFiniteSource(seed: seedFrame(), gap: 0.4)
        let pipeline = SessionPipeline(nativeSource: source,
                                       engine: engine, profile: profile, rootDirectory: sessions)
        pipeline.drainPrimaryTimeout = .milliseconds(100)     // live window — deliberately tiny
        pipeline.importActiveReadTimeout = .milliseconds(100)
        pipeline.importPrimaryTimeout = .milliseconds(1500)   // import window — tolerates the gap
        pipeline.drainGraceTimeout = .milliseconds(100)
        pipeline.rendersReplay = false   // this test exercises the drain, not the replay render

        try pipeline.start()
        XCTAssertNoThrow(try pipeline.end())
        XCTAssertEqual(engine.stackFrameCount, 2,
                       "a healthy import with a processing gap > live window must finalize both frames, not cancel")
    }

    /// Regression (2026-08-17 review): a genuinely dead active read must be declared wedged
    /// after ≈ importPrimaryTimeout + importDeadReadWindowLimit × importActiveReadTimeout —
    /// NOT limit × (primary + active). The prior loop re-charged the primary window each
    /// dead-read cycle, inflating a documented ~5 min cap to ~15 min.
    func testDeadReadCapIsLimitTimesActiveWindowNotTimesPrimary() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let profile = SessionProfile(targetName: "Dead Read", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let pipeline = SessionPipeline(nativeSource: HungReadFiniteSource(),
                                       engine: StackEngine(), profile: profile, rootDirectory: sessions)
        pipeline.importPrimaryTimeout = .milliseconds(200)
        pipeline.importActiveReadTimeout = .milliseconds(50)
        pipeline.importDeadReadWindowLimit = 3
        pipeline.drainGraceTimeout = .milliseconds(100)
        pipeline.drainPrimaryTimeout = .milliseconds(50)

        try pipeline.start()
        let t = Date()
        _ = try? pipeline.end()            // returns/throws after cancelling the hung read
        let elapsed = Date().timeIntervalSince(t)
        // Expected ≈ 200 (primary) + 3×50 (dead-read) + 100 (grace) = 450 ms.
        // The pre-fix multiplied form would be 3×(200+50) + 100 = 850 ms.
        XCTAssertLessThan(elapsed, 0.65,
                          "dead-read cap must be primary + limit×active, not limit×(primary+active)")
        XCTAssertGreaterThan(elapsed, 0.30,
                             "must still wait the primary window + the dead-read windows before giving up")
    }

    // MARK: - review10 items 4+5 fixtures

    /// A live (isFinite == false) source that yields one seed, never finishes on its own,
    /// records stop() (lock-guarded), and finishes its stream when stopped — so end()'s
    /// live-mode drain can complete against it and deinit's stop is observable.
    final class FinishableLiveSource: FrameSource {
        let frames: AsyncStream<RawFrame>
        private let cont: AsyncStream<RawFrame>.Continuation
        private let stoppedFlag = NSLock_Flag()
        var isStopped: Bool { stoppedFlag.isSet }
        var isFinite: Bool { false }
        var totalCount: Int? { nil }
        init(seed: RawFrame) {
            var c: AsyncStream<RawFrame>.Continuation!
            frames = AsyncStream { c = $0 }
            cont = c
            cont.yield(seed)
        }
        func start() throws {}
        func stop() { stoppedFlag.set(); cont.finish() }
    }

    /// Lock-guarded error capture for a callback-thrown error.
    private final class ErrBox: @unchecked Sendable {
        private let lock = NSLock(); private var err: Error?
        func set(_ e: Error) { lock.withLock { err = e } }
        var value: Error? { lock.withLock { err } }
    }

    /// Review10 item 4 (red-first would deadlock/burn the drain timeout — bounded here by
    /// shrunken drain deadlines: pre-fix the reentrant end() burned primary+grace and came
    /// back as .shutdownTimeout): updates are delivered synchronously on the consumer task,
    /// so end() called from INSIDE an onUpdate callback waited on the very task executing
    /// the callback. It must fail fast with .reentrantEnd — promptly, without touching the
    /// pipeline — and a subsequent normal end() from outside must succeed.
    func testEndInsideUpdateCallback_throwsReentrantEnd_thenNormalEndSucceeds() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let profile = SessionProfile(targetName: "Reentrant", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let pipeline = SessionPipeline(nativeSource: FinishableLiveSource(seed: seedFrame()),
                                       engine: StackEngine(), profile: profile,
                                       rootDirectory: sessions)
        pipeline.drainPrimaryTimeout = .milliseconds(300)
        pipeline.drainGraceTimeout = .milliseconds(300)
        let threw = expectation(description: "end() inside the callback returned")
        let box = ErrBox()
        let t0 = DispatchTime.now()
        pipeline.onUpdate = { [weak pipeline] _, _ in
            do { _ = try pipeline?.end() } catch { box.set(error) }
            threw.fulfill()
        }
        try pipeline.start()
        wait(for: [threw], timeout: 5)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
        XCTAssertEqual(box.value as? SessionPipelineError, .reentrantEnd,
                       "end() inside a frame callback must fail fast with .reentrantEnd")
        XCTAssertLessThan(elapsed, 3.0,
                          "the rejection must be prompt — never a drain-timeout wait")
        XCTAssertEqual(pipeline.reseed(), .reseeded,
                       "a rejected reentrant end() must not claim the finalization barrier")
        // The rejection left the pipeline fully functional: a normal end() succeeds.
        XCTAssertNoThrow(try pipeline.end(),
                         "a subsequent end() from outside the delivery context must succeed")
    }

    /// Review10 item 5 (red-first: pre-fix the source was NEVER stopped — the detached
    /// consumer strongly retains source and engine and no deinit existed): dropping a
    /// running native-live pipeline without end() must deallocate the pipeline (everything
    /// long-lived captures it weakly) and its deinit must cancel the consumer and stop the
    /// live source.
    func testDroppedRunningLivePipeline_deinitStopsSourceAndConsumer() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let profile = SessionProfile(targetName: "Dropped", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let source = FinishableLiveSource(seed: seedFrame())
        weak var weakPipeline: SessionPipeline?
        try autoreleasepool {
            let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                           profile: profile, rootDirectory: sessions)
            try pipeline.start()
            weakPipeline = pipeline
        }   // all strong references dropped — the pipeline is released while RUNNING

        let deadline = Date().addingTimeInterval(5)
        while weakPipeline != nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertNil(weakPipeline,
                     "a dropped running pipeline must deallocate — nothing long-lived may retain it")
        while !source.isStopped && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(source.isStopped,
                      "deinit must stop the live source — pre-fix it ran forever")
    }

    /// Cold1 M1: on the native-live path end() used to call source.stop() UN-budgeted —
    /// FolderFrameSource.stop → inner watcher stop with its 5 s default — BEFORE the
    /// primary+grace drain, so end() could exceed the documented budget by the whole
    /// watcher stop. The source stop's timeout must be threaded from the SAME primary
    /// budget the watcher-mode branch charges. Plumbing assertion (not wall-clock): the
    /// stop is invoked with the budgeted timeout, not its default.
    func testEndLiveFolderSource_stopTimeoutChargedAgainstDrainBudget() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let watch = sandbox.appendingPathComponent("watch")
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let profile = SessionProfile(targetName: "Budget", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let source = FolderFrameSource(folder: watch, mode: .live)
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: profile, rootDirectory: sessions)
        pipeline.drainPrimaryTimeout = .milliseconds(700)
        try pipeline.start()
        // Empty session: the replay render may legitimately throw — the budget plumbing
        // is the assertion here, and stop() runs before any finalization.
        _ = try? pipeline.end()
        XCTAssertEqual(source.lastStopTimeout ?? -1, 0.7, accuracy: 1e-6,
                       "the live-source stop must run with the drain budget, not its 5 s default")
    }

    /// A source that throws on start(), and can be flipped to succeed on a retry.
    final class FlakyStartSource: FrameSource {
        let frames: AsyncStream<RawFrame>
        var isFinite: Bool { false }
        var totalCount: Int? { nil }
        var shouldThrow = true
        init() { frames = AsyncStream { $0.finish() } }
        func start() throws {
            if shouldThrow { throw NSError(domain: "test", code: 1) }
        }
        func stop() {}
    }

    func testStartRollsBackOnSourceStartFailure() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let profile = SessionProfile(targetName: "Flaky", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let source = FlakyStartSource()
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: profile, rootDirectory: sessions)

        // First start(): the source throws → start() must roll back the just-created session.
        XCTAssertThrowsError(try pipeline.start())
        XCTAssertNotEqual(pipeline.session.state, .running,
                          "a failed start must not leave the session marked running")

        // Retry must NOT hit alreadyRunning.
        source.shouldThrow = false
        XCTAssertNoThrow(try pipeline.start(),
                         "after a rolled-back start, a retry must succeed (not alreadyRunning)")
    }

    func testNeverStartedEndThrowsNotRunningAndDoesNotClaimFinalizationBarrier() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let profile = SessionProfile(targetName: "Never Started", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let pipeline = SessionPipeline(nativeSource: FinishableLiveSource(seed: seedFrame()),
                                       engine: StackEngine(), profile: profile,
                                       rootDirectory: sessions)

        XCTAssertThrowsError(try pipeline.end()) { error in
            XCTAssertEqual(error as? SessionError, .notRunning)
        }
        XCTAssertEqual(pipeline.reseed(), .reseeded,
                       "a never-started end() rejection must not claim the finalization barrier")
    }

    func testShutdownTimeoutReportsRetryPendingFinalizationBarrierBeforeRetry() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let profile = SessionProfile(targetName: "Sticky Timeout", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let pipeline = SessionPipeline(nativeSource: WedgingLiveSource(seed: seedFrame()),
                                       engine: StackEngine(), profile: profile, rootDirectory: sessions)
        let wedged = DispatchSemaphore(value: 0)
        pipeline.onUpdate = { _, _ in wedged.wait() }
        pipeline.drainPrimaryTimeout = .milliseconds(200)
        pipeline.liveDrainStallTimeout = .milliseconds(200)   // live wedge window (else the 120 s default)
        pipeline.drainGraceTimeout = .milliseconds(200)
        try pipeline.start()
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertThrowsError(try pipeline.end()) { error in
            XCTAssertEqual(error as? SessionPipelineError, .shutdownTimeout)
        }
        XCTAssertEqual(pipeline.reseed(), .finalizationRetryPending,
                       "shutdownTimeout happens after a valid running end() claims finalization, but the retry window should be named honestly")
        XCTAssertEqual(pipeline.reseed(), .finalizationRetryPending,
                       "the claimed finalization barrier must remain sticky before a retry")
        wedged.signal()
    }

    func testFiniteShutdownTimeoutReportsRetryPendingBeforeImportUnavailability() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let profile = SessionProfile(targetName: "Finite Sticky Timeout", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let pipeline = SessionPipeline(nativeSource: WedgingFiniteSource(seed: seedFrame()),
                                       engine: StackEngine(), profile: profile, rootDirectory: sessions)
        let wedged = DispatchSemaphore(value: 0)
        pipeline.onUpdate = { _, _ in wedged.wait() }
        pipeline.drainPrimaryTimeout = .milliseconds(200)
        pipeline.importPrimaryTimeout = .milliseconds(200)   // finite drain uses this window (else waits 120s)
        pipeline.drainGraceTimeout = .milliseconds(200)
        try pipeline.start()
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertThrowsError(try pipeline.end()) { error in
            XCTAssertEqual(error as? SessionPipelineError, .shutdownTimeout)
        }
        XCTAssertEqual(pipeline.reseed(), .finalizationRetryPending,
                       "a failed finalization barrier must outrank finite-import reseed refusal")
        wedged.signal()
    }

    // MARK: - Task 10: end() writes the clean survivor-counted master with online fallback

    /// A live (isFinite == false) source that yields a fixed sequence up front (buffered) and
    /// finishes its stream on stop() — mirrors GlobalRefinerTests.StubLiveSource. Unlike
    /// BacklogLiveSource (whose frames carry no `identity`/`sourceURL`, so they never append a
    /// SubRegistration), every frame here is expected to carry both — required for the
    /// registration cache the background refiner reproduces from.
    final class T10StubLiveSource: FrameSource {
        let frames: AsyncStream<RawFrame>
        private let cont: AsyncStream<RawFrame>.Continuation
        var isFinite: Bool { false }
        var totalCount: Int? { nil }
        init(sequence: [RawFrame]) {
            var c: AsyncStream<RawFrame>.Continuation!
            frames = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
            cont = c
            for f in sequence { cont.yield(f) }
        }
        func start() throws {}
        func stop() { cont.finish() }
    }

    private func t10Identity(digest: String) -> FileIdentity {
        FileIdentity(dev: 0, ino: 0, size: 0, mtimeSec: 0, mtimeNsec: 0, digest: digest)
    }

    /// A registration-eligible RawFrame (identity + sourceURL set) carrying the SAME star-field
    /// image for every sub — every sub registers with (at worst) a near-identity transform
    /// against the reference, and the very first sub's transform is EXACT identity by
    /// construction (Task 5: "the reference frame... transform=identity").
    private func t10Frame(name: String, digest: String, timestamp: TimeInterval, image: AstroImage) -> RawFrame {
        RawFrame(image: image, bayerPattern: nil, bottomUp: false,
                timestamp: Date(timeIntervalSince1970: timestamp), sourceName: name,
                identity: t10Identity(digest: digest),
                sourceURL: URL(fileURLWithPath: "/tmp/t10globalrefiner/\(name)"))
    }

    /// A flat 16x16 image with one elevated pixel roughly centered (8px margin on every side) —
    /// large enough that any sub-pixel registration/warp residual can't smear the elevated pixel
    /// out to the frame boundary (where mask/coverage cropping could hide whether it actually got
    /// clipped by the robust combine, vs. merely cropped away).
    private func t10TrailImage(base: Float, trail: Float, size: Int = 16) -> AstroImage {
        var px = [Float](repeating: base, count: size * size)
        px[(size / 2) * size + size / 2] = trail
        return AstroImage(width: size, height: size, channels: 1, pixels: px, sourceIsLinear: true)
    }

    private func t10ConstImage(_ v: Float, size: Int = 16) -> AstroImage {
        AstroImage(width: size, height: size, channels: 1,
                  pixels: [Float](repeating: v, count: size * size), sourceIsLinear: true)
    }

    /// Records every call (spy) and can optionally: throw for specific URLs, sleep before
    /// returning (simulates a slow per-sub reload), and PARK FOREVER on its very first-ever call
    /// (across ALL passes sharing this loader instance) until `parkFirstCallOn` is signalled —
    /// isolates an enabledRose-triggered BACKGROUND pass (which always reaches the loader first)
    /// from a later FINAL pass driven directly by `end()`, so a test can prove the final pass
    /// itself does the work, not a lucky pre-published background result.
    private final class T10SpyFrameLoader: FrameLoader {
        private let images: [URL: AstroImage]
        private let throwing: Set<URL>
        private let sleepPerCall: TimeInterval
        private let parkFirstCallOn: DispatchSemaphore?
        private let enteredSignal: DispatchSemaphore?
        private let lock = NSLock()
        private var _callCount = 0
        var callCount: Int { lock.withLock { _callCount } }

        init(images: [URL: AstroImage] = [:], throwing: Set<URL> = [], sleepPerCall: TimeInterval = 0,
            parkFirstCallOn: DispatchSemaphore? = nil, enteredSignal: DispatchSemaphore? = nil) {
            self.images = images; self.throwing = throwing; self.sleepPerCall = sleepPerCall
            self.parkFirstCallOn = parkFirstCallOn; self.enteredSignal = enteredSignal
        }

        func loadRegisteredInput(url: URL, expectedContentDigest: String?) throws -> AstroImage {
            let isFirst: Bool = lock.withLock { _callCount += 1; return _callCount == 1 }
            if isFirst, let sem = parkFirstCallOn {
                enteredSignal?.signal()
                sem.wait()
            }
            if sleepPerCall > 0 { Thread.sleep(forTimeInterval: sleepPerCall) }
            if throwing.contains(url) { throw NSError(domain: "t10loader", code: 1) }
            guard let img = images[url] else { throw NSError(domain: "t10loader", code: 2) }
            return img
        }
    }

    /// Cold-review regression loader: every call blocks FOREVER on a shared gate — models a
    /// genuinely wedged read (dead SMB / evicted-iCloud), per
    /// docs/history/specs/2026-08-24-watcher-async-reads-design.md: macOS cannot interrupt an
    /// in-flight regular-file `read()`, so this is NOT merely slow (like `T10SpyFrameLoader`'s
    /// `sleepPerCall`, which the existing between-loads deadline check already bounds) — it never
    /// returns at all unless released. Distinct from `GlobalRefinerTests.WedgedFirstCallFrameLoader`
    /// (which wedges only the very first-ever call): here EVERY call wedges, so quorum genuinely
    /// cannot be reached and the fallback-to-online path is exercised deterministically.
    private final class T10WedgedFrameLoader: FrameLoader {
        private let images: [URL: AstroImage]
        private let gate = DispatchSemaphore(value: 0)
        init(images: [URL: AstroImage] = [:]) { self.images = images }
        func loadRegisteredInput(url: URL, expectedContentDigest: String?) throws -> AstroImage {
            gate.wait()   // never signalled during the test body -> blocks forever
            guard let img = images[url] else { throw NSError(domain: "t10wedged", code: 1) }
            return img
        }
        /// Test hygiene only: release however many worker threads got leaked waiting on this gate
        /// (the bounded-load fix abandons the WAIT after `perSubLoadCap` but the dispatched
        /// closure itself stays blocked here forever, per the macOS uninterruptible-read
        /// limitation) — signal generously so none of them linger permanently-parked in the test
        /// process. Safe to over-signal (excess signals just leave the semaphore count positive).
        func releaseAll(times: Int = 32) { for _ in 0..<times { gate.signal() } }
    }

    /// Polls `subRegistrations()` until it reaches `count` entries or the deadline passes.
    private func t10WaitForRegistrations(_ pipeline: SessionPipeline, count: Int,
                                         timeout: TimeInterval = 5) -> [SubRegistration] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let regs = pipeline.subRegistrations()
            if regs.count >= count { return regs }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return pipeline.subRegistrations()
    }

    /// Drives 6 real subs (IDENTICAL star-field content, so every registration is at worst a
    /// near-identity transform and the reference's is EXACT identity) through a real native
    /// `.live` pipeline and returns the still-running pipeline/source/engine plus the 6
    /// registrations in capture order. Caller owns `source.stop()`/`pipeline.end()`.
    private func t10RegisterSixSubs(sandbox: URL) throws
        -> (pipeline: SessionPipeline, source: T10StubLiveSource, engine: StackEngine, regs: [SubRegistration]) {
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let profile = SessionProfile(targetName: "Task10", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let engine = StackEngine()
        let baseImage = seedFrame().image
        let frames = (0..<6).map { i in
            t10Frame(name: "t10sub\(i).fit", digest: "t10-digest-\(i)", timestamp: TimeInterval(i), image: baseImage)
        }
        let source = T10StubLiveSource(sequence: frames)
        let pipeline = SessionPipeline(nativeSource: source, engine: engine,
                                       profile: profile, rootDirectory: sessions)
        pipeline.rendersReplay = false   // these tests exercise the master write, not the replay render
        try pipeline.start()
        let regs = t10WaitForRegistrations(pipeline, count: 6)
        XCTAssertEqual(regs.count, 6, "test precondition: all 6 subs must register")
        XCTAssertEqual(regs[0].transform, .identity,
                       "test precondition: the reference sub's transform is EXACT identity")
        return (pipeline, source, engine, regs)
    }

    /// Step 1 (success path): feature ON, no published master current at end() (the
    /// enabledRose-triggered background pass is parked mid-load and never completes) — end()'s
    /// own FINAL synchronous refine pass must run, clip a trail only the multi-frame robust
    /// combine can see, and write master.fit with STACKCNT == the refine result's survivor
    /// count, which DIFFERS from the online engine's frame count (one sub always fails to
    /// reload for the clean pass, proving STACKCNT tracks the refine count, not the online one).
    func testEndFeatureOnRunsFinalRefinePassAndWritesCleanSurvivorCountedMaster() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (pipeline, source, engine, regs) = try t10RegisterSixSubs(sandbox: sandbox)
        defer { source.stop() }

        var images: [URL: AstroImage] = [:]
        for reg in regs { images[reg.relayURL] = t10ConstImage(0.1) }
        images[regs[0].relayURL] = t10TrailImage(base: 0.1, trail: 0.9)   // reference sub carries the trail
        let throwingURL = regs[3].relayURL                                // an arbitrary non-reference sub

        let entered = DispatchSemaphore(value: 0)
        let park = DispatchSemaphore(value: 0)
        let loader = T10SpyFrameLoader(images: images, throwing: [throwingURL],
                                       parkFirstCallOn: park, enteredSignal: entered)
        pipeline.refinerLoaderOverride = loader

        // enabledRose (OFF -> ON with 6 survivors already present) triggers an immediate
        // background pass — its first load parks here forever, so it never publishes. end()'s
        // own final synchronous pass (this task) must run and write the clean master instead.
        pipeline.configureLiveRejection(enabled: true, kappa: 3.0, maxSampleBytes: 10_000_000)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success,
                       "precondition: the background pass must reach the loader (and park there)")
        XCTAssertNil(pipeline.publishedMasterIfCurrent(),
                     "precondition: nothing published yet — the parked background pass never completes")

        let dir = try pipeline.end()
        park.signal()   // release the parked background pass so it can unwind (test hygiene)

        XCTAssertEqual(engine.stackFrameCount, 6,
                       "precondition: the ONLINE engine stacked all 6 — proves STACKCNT below deliberately differs from it")
        let masterURL = dir.appendingPathComponent("master.fit")
        XCTAssertTrue(FileManager.default.fileExists(atPath: masterURL.path))
        let header = try FITSReader.readHeader(Data(contentsOf: masterURL))
        XCTAssertEqual(Int(header.keywords["STACKCNT"] ?? ""), 5,
                      "STACKCNT must be the refine result's survivor count (6 registered minus the " +
                      "1 sub that always fails to reload), not the online engine's frame count (6)")

        let master = try FITSReader.read(Data(contentsOf: masterURL))
        XCTAssertLessThan(master.pixels.max() ?? 1, 0.5,
                          "the trail-region pixel must read background — the robust combine must " +
                          "clip it out, something the online per-frame winsorized engine (which " +
                          "never reproduces a sub from disk) cannot do")
    }

    /// Fault path: the refiner returns nil on every attempt (every reload throws) — end() must
    /// still write the ONLINE master (never throw, never leave master.fit missing).
    func testEndRefinerAlwaysNilFallsBackToOnlineMaster() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (pipeline, source, engine, regs) = try t10RegisterSixSubs(sandbox: sandbox)
        defer { source.stop() }

        let loader = T10SpyFrameLoader(throwing: Set(regs.map(\.relayURL)))   // every URL always fails
        pipeline.refinerLoaderOverride = loader
        pipeline.configureLiveRejection(enabled: true, kappa: 3.0, maxSampleBytes: 10_000_000)
        // Let the enabledRose background pass run to completion (it also fails and publishes
        // nothing) before ending, so end()'s own final pass is exercised deterministically.
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertNil(pipeline.publishedMasterIfCurrent(), "precondition: nothing was ever published")

        let dir = try pipeline.end()   // must not throw

        XCTAssertEqual(engine.stackFrameCount, 6)
        let masterURL = dir.appendingPathComponent("master.fit")
        let header = try FITSReader.readHeader(Data(contentsOf: masterURL))
        XCTAssertEqual(Int(header.keywords["STACKCNT"] ?? ""), 6,
                      "a refiner that always returns nil must fall back to the ONLINE master's frame count")
    }

    /// P2, feature-off parity: `liveRejectionActive == false` at end() must skip the clean path
    /// ENTIRELY — no additional refine/loader calls during end() itself — and write the ONLINE
    /// master. The feature is enabled-then-disabled (not left never-enabled) so `_globalRefiner`
    /// genuinely exists at end() — proving the `capturedActive` gate itself does the work, not
    /// just an absent refiner having nothing to call.
    func testEndFeatureOffSkipsCleanPathEntirelyNoRefineCallsDuringEnd() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (pipeline, source, engine, regs) = try t10RegisterSixSubs(sandbox: sandbox)
        defer { source.stop() }

        var images: [URL: AstroImage] = [:]
        for reg in regs { images[reg.relayURL] = t10ConstImage(0.1) }
        let loader = T10SpyFrameLoader(images: images)
        pipeline.refinerLoaderOverride = loader
        pipeline.configureLiveRejection(enabled: true, kappa: 3.0, maxSampleBytes: 10_000_000)
        Thread.sleep(forTimeInterval: 0.3)   // let the background pass finish and publish
        pipeline.configureLiveRejection(enabled: false)   // turn OFF before end()
        XCTAssertNil(pipeline.publishedMasterIfCurrent(), "feature off must hide the published master")

        let callsBeforeEnd = loader.callCount
        let dir = try pipeline.end()
        XCTAssertEqual(loader.callCount, callsBeforeEnd,
                       "a disabled feature must not run ANY refine pass at end() — zero additional loader calls")

        XCTAssertEqual(engine.stackFrameCount, 6)
        let masterURL = dir.appendingPathComponent("master.fit")
        let header = try FITSReader.readHeader(Data(contentsOf: masterURL))
        XCTAssertEqual(Int(header.keywords["STACKCNT"] ?? ""), 6,
                      "feature off at end() must write the ONLINE master")
    }

    /// C3, hang-safety: shrink `finalRefineBudget` and inject a refiner whose loader sleeps per
    /// sub — end() must still return promptly (bounded by the budget, not the sleep total) and
    /// fall back to the online master. Mirrors the shutdown-drain hang tests above.
    func testEndFinalRefineHangSafetyBoundedByFinalRefineBudget() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (pipeline, source, engine, regs) = try t10RegisterSixSubs(sandbox: sandbox)
        defer { source.stop() }

        var images: [URL: AstroImage] = [:]
        for reg in regs { images[reg.relayURL] = t10ConstImage(0.1) }
        // Each per-sub reload takes 100 ms — far longer than the shrunken 200 ms final budget,
        // so the final pass can load at most ~2 subs before its deadline check aborts it.
        let loader = T10SpyFrameLoader(images: images, sleepPerCall: 0.1)
        pipeline.refinerLoaderOverride = loader
        pipeline.finalRefineBudget = .milliseconds(200)

        // enabledRose fires a background pass too, but end() is called immediately — it is the
        // FINAL pass's own deadline that must bound end(), not a lucky pre-published result.
        pipeline.configureLiveRejection(enabled: true, kappa: 3.0, maxSampleBytes: 10_000_000)

        let t0 = Date()
        let dir = try pipeline.end()
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertLessThan(elapsed, 2.0,
                          "end() must be bounded by finalRefineBudget, not hang on a per-sub-slow refiner")

        XCTAssertEqual(engine.stackFrameCount, 6)
        let masterURL = dir.appendingPathComponent("master.fit")
        let header = try FITSReader.readHeader(Data(contentsOf: masterURL))
        XCTAssertEqual(Int(header.keywords["STACKCNT"] ?? ""), 6,
                      "a final pass that hits its deadline must fall back to the ONLINE master")
    }

    /// THE cold-review regression this task exists to fix (Manifestation A from the bug report):
    /// unlike the hang-safety test above (a loader that's merely SLOW per call — bounded today by
    /// the BETWEEN-loads deadline check), this loader's reads never return AT ALL. Before the fix,
    /// `refine`'s only liveness check runs between loads, never during one, so `end()`'s final
    /// pass would hang on the very first wedged read regardless of `finalRefineBudget` — "End
    /// Session" spins forever, master.fit never written. After the fix, `GlobalRefiner`'s bounded
    /// per-sub load wait (shrunk here via `refinerPerSubLoadCapOverride`, independent of and far
    /// below `finalRefineBudget`) caps the WAIT on each read; every one of the 6 survivors' reads
    /// times out, quorum can't be reached, `refine` returns nil, and `end()` falls back to writing
    /// the ONLINE master — never hanging.
    func testEndSessionWithWedgedSurvivorReadStillFinalizes() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (pipeline, source, engine, regs) = try t10RegisterSixSubs(sandbox: sandbox)
        defer { source.stop() }

        var images: [URL: AstroImage] = [:]
        for reg in regs { images[reg.relayURL] = t10ConstImage(0.1) }
        let loader = T10WedgedFrameLoader(images: images)
        pipeline.refinerLoaderOverride = loader
        // finalRefineBudget stays generous (30s default) — it must NOT be the thing that bounds
        // this test; perSubLoadCap is the bound under test, shrunk far below it.
        pipeline.refinerPerSubLoadCapOverride = .milliseconds(100)

        // enabledRose fires a background pass too (also on this wedged loader, also now bounded
        // by the shrunk perSubLoadCap) — end() is called immediately regardless.
        pipeline.configureLiveRejection(enabled: true, kappa: 3.0, maxSampleBytes: 10_000_000)

        let t0 = Date()
        let dir = try pipeline.end()
        let elapsed = Date().timeIntervalSince(t0)
        loader.releaseAll()   // test hygiene: let every leaked worker thread exit

        XCTAssertLessThan(elapsed, 5.0,
                          "end() must be bounded by perSubLoadCap even when reads never return at " +
                          "all (genuinely wedged, not merely slow) — must not hang past finalRefineBudget")

        XCTAssertEqual(engine.stackFrameCount, 6)
        let masterURL = dir.appendingPathComponent("master.fit")
        let header = try FITSReader.readHeader(Data(contentsOf: masterURL))
        XCTAssertEqual(Int(header.keywords["STACKCNT"] ?? ""), 6,
                      "every survivor's read is permanently wedged -> quorum can never be reached " +
                      "-> the final pass must fall back to writing the ONLINE master, not hang")
    }
}
