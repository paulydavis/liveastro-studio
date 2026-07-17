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

    func testShutdownTimeoutClaimsStickyFinalizationBarrierBeforeRetry() throws {
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
        XCTAssertEqual(pipeline.reseed(), .finalizationInProgress,
                       "shutdownTimeout happens after a valid running end() claims finalization")
        XCTAssertEqual(pipeline.reseed(), .finalizationInProgress,
                       "the claimed finalization barrier must remain sticky before a retry")
        wedged.signal()
    }

    func testFiniteShutdownTimeoutReportsFinalizationInProgressBeforeImportUnavailability() throws {
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
        pipeline.drainGraceTimeout = .milliseconds(200)
        try pipeline.start()
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertThrowsError(try pipeline.end()) { error in
            XCTAssertEqual(error as? SessionPipelineError, .shutdownTimeout)
        }
        XCTAssertEqual(pipeline.reseed(), .finalizationInProgress,
                       "a claimed finalization barrier must outrank finite-import reseed refusal")
        wedged.signal()
    }
}
