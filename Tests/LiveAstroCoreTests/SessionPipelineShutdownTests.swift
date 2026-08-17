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
        // Shrink the drain deadlines so the test runs fast.
        pipeline.drainPrimaryTimeout = .milliseconds(200)
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
}
