import XCTest
@testable import LiveAstroCore

/// Task 5: SessionPipeline captures a thread-safe cache of per-sub SubRegistration records so a
/// later background refiner (Task 6) can reuse each accepted sub's transform/leveling/scale
/// without re-registering.
final class GlobalRefinerTests: XCTestCase {
    /// A live (isFinite == false) source that yields a fixed sequence of RawFrames up front
    /// (buffered), stays open like a real live source, and finishes its stream on stop().
    /// Mirrors SessionPipelineShutdownTests.BacklogLiveSource.
    final class StubLiveSource: FrameSource {
        let frames: AsyncStream<RawFrame>
        private let cont: AsyncStream<RawFrame>.Continuation
        var isFinite: Bool { false }
        var totalCount: Int? { nil }
        init(sequence: [RawFrame]) {
            var c: AsyncStream<RawFrame>.Continuation!
            frames = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
            cont = c
            for f in sequence { cont.yield(f) }
            // Stream stays open (live source) until stop().
        }
        func start() throws {}
        func stop() { cont.finish() }
    }

    /// A ≥15-star field so the engine accepts every translated variant (mirrors
    /// StackEngineTests.field / starFrame).
    private let field: [(x: Double, y: Double)] = [
        (60.2, 80.5), (400.7, 90.1), (200.3, 300.9), (350.5, 420.2), (100.8, 380.4),
        (250.1, 150.6), (450.3, 250.8), (80.9, 200.2), (320.4, 60.7), (180.6, 460.3),
        (420.2, 380.5), (140.7, 120.9), (280.8, 400.1), (380.1, 160.3), (60.5, 300.7),
        (460.6, 460.9), (240.2, 240.4), (120.3, 40.6), (40.7, 440.8), (340.9, 340.2),
    ]

    private func starImage(dx: Double, dy: Double, width: Int = 512, height: Int = 512,
                           amp: Float = 0.8) -> AstroImage {
        var px = [Float](repeating: 0.05, count: width * height)
        for s in field {
            let sx = s.x + dx, sy = s.y + dy
            for y in max(0, Int(sy) - 8)...min(height - 1, Int(sy) + 8) {
                for x in max(0, Int(sx) - 8)...min(width - 1, Int(sx) + 8) {
                    let ddx = Double(x) - sx, ddy = Double(y) - sy
                    px[y * width + x] += amp * Float(exp(-(ddx * ddx + ddy * ddy) / (2 * 3.0 * 3.0)))
                }
            }
        }
        return AstroImage(width: width, height: height, channels: 1, pixels: px, sourceIsLinear: true)
    }

    private func stubIdentity(digest: String) -> FileIdentity {
        FileIdentity(dev: 0, ino: 0, size: 0, mtimeSec: 0, mtimeNsec: 0, digest: digest)
    }

    private func stubFrame(dx: Double, dy: Double, name: String, digest: String,
                           timestamp: TimeInterval) -> RawFrame {
        RawFrame(image: starImage(dx: dx, dy: dy), bayerPattern: nil, bottomUp: false,
                timestamp: Date(timeIntervalSince1970: timestamp), sourceName: name,
                identity: stubIdentity(digest: digest),
                sourceURL: URL(fileURLWithPath: "/tmp/globalrefiner/\(name)"))
    }

    /// Polls `subRegistrations()` until it reaches `count` entries or the deadline passes.
    private func waitForRegistrations(_ pipeline: SessionPipeline, count: Int,
                                      timeout: TimeInterval = 5) -> [SubRegistration] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let regs = pipeline.subRegistrations()
            if regs.count >= count { return regs }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return pipeline.subRegistrations()
    }

    /// Step 1: drive a native `.live` pipeline with 3 subs (each with a distinct sourceURL +
    /// identity) — `subRegistrations()` must have 3 entries with subIndex 1/2/3 (processedCount
    /// increments to 1 BEFORE the first SubFrameRecord.index → 1-based), the first is the
    /// reference (transform .identity), and all share one stackGeneration. A 4th sub with
    /// BYTE-IDENTICAL bytes to sub 3 must produce a DISTINCT entry (subIndex 4) — proving the
    /// subIndex key doesn't collapse duplicates.
    func testCapturesSubRegistrationCacheKeyedBySubIndexInCaptureOrder() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let profile = SessionProfile(targetName: "Refiner", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let engine = StackEngine()

        let sub1 = stubFrame(dx: 0, dy: 0, name: "sub1.fit", digest: "digest-1", timestamp: 0)
        let sub2 = stubFrame(dx: 1.0, dy: -0.5, name: "sub2.fit", digest: "digest-2", timestamp: 1)
        let sub3 = stubFrame(dx: 1.6, dy: 0.3, name: "sub3.fit", digest: "digest-3", timestamp: 2)
        // sub4 is BYTE-IDENTICAL to sub3 (same star field offset → same pixels, same digest) but
        // a distinct file (different sourceURL) — the classic "duplicate sub" case.
        let sub4 = stubFrame(dx: 1.6, dy: 0.3, name: "sub4.fit", digest: "digest-3", timestamp: 3)
        XCTAssertEqual(sub3.image.pixels, sub4.image.pixels, "test precondition: sub3/sub4 must be byte-identical")

        let source = StubLiveSource(sequence: [sub1, sub2, sub3, sub4])
        let pipeline = SessionPipeline(nativeSource: source, engine: engine,
                                       profile: profile, rootDirectory: sessions)
        try pipeline.start()

        let regs = waitForRegistrations(pipeline, count: 4)
        XCTAssertEqual(regs.count, 4, "all four subs must be captured (byte-identical subs must not collapse)")

        XCTAssertEqual(regs.map(\.subIndex), [1, 2, 3, 4],
                       "subIndex is 1-based capture order (processedCount increments before SubFrameRecord.index)")

        let reference = regs[0]
        XCTAssertEqual(reference.transform, .identity, "the first sub becomes the reference (identity transform)")

        let gen = reference.stackGeneration
        for reg in regs {
            XCTAssertEqual(reg.stackGeneration, gen, "all four subs share one stackGeneration")
        }

        // sub3 and sub4 are byte-identical (same digest) yet occupy DISTINCT cache entries.
        XCTAssertEqual(regs[2].contentDigest, regs[3].contentDigest)
        XCTAssertNotEqual(regs[2].subIndex, regs[3].subIndex)
        XCTAssertEqual(regs[3].subIndex, 4)

        // Cleanly stop the source so the test doesn't leak a running consume task.
        source.stop()
    }

    /// `currentSurvivors` returns subs of the given generation minus any subIndex the caller has
    /// flagged as user-rejected, in capture order — a reject actually removes the sub from the
    /// survivor set, not just bumps a counter.
    func testCurrentSurvivorsExcludesUserRejectedSubIndexes() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let profile = SessionProfile(targetName: "Survivors", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let engine = StackEngine()

        let sub1 = stubFrame(dx: 0, dy: 0, name: "sub1.fit", digest: "digest-1", timestamp: 0)
        let sub2 = stubFrame(dx: 1.0, dy: -0.5, name: "sub2.fit", digest: "digest-2", timestamp: 1)
        let sub3 = stubFrame(dx: 1.6, dy: 0.3, name: "sub3.fit", digest: "digest-3", timestamp: 2)

        let source = StubLiveSource(sequence: [sub1, sub2, sub3])
        let pipeline = SessionPipeline(nativeSource: source, engine: engine,
                                       profile: profile, rootDirectory: sessions)
        try pipeline.start()

        let regs = waitForRegistrations(pipeline, count: 3)
        XCTAssertEqual(regs.count, 3)
        let gen = regs[0].stackGeneration

        pipeline.setUserRejected([2])
        let survivors = pipeline.currentSurvivors(currentGeneration: gen)
        XCTAssertEqual(survivors.map(\.subIndex), [1, 3],
                       "subIndex 2 was flagged — it must be excluded from the survivor set")

        source.stop()
    }

    /// `currentSurvivorsLocked` must be safe to call from a context that already holds `regLock`
    /// (e.g. a Task 8 snapshot) — calling the locking `currentSurvivors` there would re-enter the
    /// non-recursive NSLock and deadlock. This test just exercises the no-lock entry point directly.
    func testCurrentSurvivorsLockedMatchesLockingVariant() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let profile = SessionProfile(targetName: "LockedSurvivors", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let engine = StackEngine()
        let sub1 = stubFrame(dx: 0, dy: 0, name: "sub1.fit", digest: "digest-1", timestamp: 0)
        let sub2 = stubFrame(dx: 1.0, dy: -0.5, name: "sub2.fit", digest: "digest-2", timestamp: 1)

        let source = StubLiveSource(sequence: [sub1, sub2])
        let pipeline = SessionPipeline(nativeSource: source, engine: engine,
                                       profile: profile, rootDirectory: sessions)
        try pipeline.start()

        let regs = waitForRegistrations(pipeline, count: 2)
        XCTAssertEqual(regs.count, 2)
        let gen = regs[0].stackGeneration

        XCTAssertEqual(pipeline.currentSurvivors(currentGeneration: gen).map(\.subIndex), [1, 2])

        source.stop()
    }
}
