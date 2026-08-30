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
        /// Task 7: push an additional frame after construction (e.g. post-reseed), so a test can
        /// drive a NEW reference through the real handleNative path instead of poking pipeline
        /// state directly.
        func send(_ frame: RawFrame) { cont.yield(frame) }
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

    // MARK: - Task 6: GlobalRefiner (reproduce + robust combine)

    private enum StubLoadError: Error { case simulated, missing }

    /// Records every call (URL + count) so tests can assert the loader was invoked at most
    /// once per survivor, or never at all (cancellation / past-deadline).
    private final class StubFrameLoader: FrameLoader {
        private var images: [URL: AstroImage]
        var throwing: Set<URL> = []
        private(set) var callCount = 0
        private(set) var calledURLs: [URL] = []
        init(images: [URL: AstroImage]) { self.images = images }
        func loadRegisteredInput(url: URL, expectedContentDigest: String?) throws -> AstroImage {
            callCount += 1
            calledURLs.append(url)
            if throwing.contains(url) { throw StubLoadError.simulated }
            guard let img = images[url] else { throw StubLoadError.missing }
            return img
        }
    }

    private func constImage(_ v: Float, w: Int = 4, h: Int = 4) -> AstroImage {
        AstroImage(width: w, height: h, channels: 1, pixels: [Float](repeating: v, count: w * h), sourceIsLinear: true)
    }

    /// A flat frame with ONE pixel elevated — simulates a satellite-trail/cosmic-ray hit that
    /// only the multi-frame robust combine (not the online single-pass winsorized clip) can see.
    private func trailImage(base: Float, trail: Float, w: Int = 4, h: Int = 4) -> AstroImage {
        var px = [Float](repeating: base, count: w * h)
        px[0] = trail
        return AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true)
    }

    private func refinerReg(subIndex: Int, url: URL, gen: Int = 0, weight: Float = 1.0) -> SubRegistration {
        SubRegistration(subIndex: subIndex, contentDigest: nil, relayURL: url, stackGeneration: gen,
                        referenceIdentity: nil, transform: .identity, effectiveScale: 1.0,
                        weight: weight, leveling: nil)
    }

    /// Core case: the multi-frame robust combine removes a satellite-trail pixel the online
    /// single-pass winsorized engine can't see (each frame only ever sees itself online).
    func testRefineRemovesSatelliteTrailViaRobustCombine() throws {
        var images = [URL: AstroImage]()
        var regs: [SubRegistration] = []
        for i in 0..<5 {
            let url = URL(fileURLWithPath: "/tmp/globalrefiner/refine-trail-\(i).fit")
            images[url] = i == 2 ? trailImage(base: 0.1, trail: 0.9) : constImage(0.1)
            regs.append(refinerReg(subIndex: i + 1, url: url))
        }
        let loader = StubFrameLoader(images: images)
        let refiner = GlobalRefiner(loader: loader, onLog: { _ in })
        let result = refiner.refine(survivors: regs, currentGeneration: 0, kappa: 3.0, minSubs: 5,
                                    maxSampleBytes: 10_000_000, deadline: .distantFuture, isCancelled: { false })
        let unwrapped = try XCTUnwrap(result)
        XCTAssertEqual(unwrapped.survivorCount, 5)
        XCTAssertEqual(unwrapped.skipped, 0)
        XCTAssertEqual(unwrapped.image.pixels[0], 0.1, accuracy: 1e-6,
                       "the trail pixel must be clipped out by the robust combine, not blended in")
        XCTAssertEqual(unwrapped.image.pixels[1], 0.1, accuracy: 1e-6)
    }

    /// After a reseed, old-generation frames could be the majority — filtering MUST be exact
    /// equality, never majority. Also proves excluded subs are never even loaded.
    func testRefineExcludesDifferentStackGenerationSurvivors() throws {
        var images = [URL: AstroImage]()
        var regs: [SubRegistration] = []
        for i in 0..<5 {
            let url = URL(fileURLWithPath: "/tmp/globalrefiner/refine-gen0-\(i).fit")
            images[url] = constImage(0.2)
            regs.append(refinerReg(subIndex: i + 1, url: url, gen: 0))
        }
        for i in 0..<3 {
            let url = URL(fileURLWithPath: "/tmp/globalrefiner/refine-gen1-\(i).fit")
            images[url] = constImage(0.9)
            regs.append(refinerReg(subIndex: 100 + i, url: url, gen: 1))
        }
        let loader = StubFrameLoader(images: images)
        let refiner = GlobalRefiner(loader: loader, onLog: { _ in })
        let result = refiner.refine(survivors: regs, currentGeneration: 0, kappa: 3.0, minSubs: 5,
                                    maxSampleBytes: 10_000_000, deadline: .distantFuture, isCancelled: { false })
        let unwrapped = try XCTUnwrap(result)
        XCTAssertEqual(unwrapped.survivorCount, 5)
        XCTAssertEqual(unwrapped.image.pixels.first, 0.2)
        XCTAssertFalse(loader.calledURLs.contains { $0.absoluteString.contains("gen1") },
                       "a different-generation sub must never even be loaded")
    }

    /// A single sub's URL throws (mid-set, not the first) → counted once by subIndex, the pass
    /// still returns.
    func testRefineSkipsOneFailedLoadAndStillReturns() throws {
        var images = [URL: AstroImage]()
        var regs: [SubRegistration] = []
        var urls: [URL] = []
        for i in 0..<5 {
            let url = URL(fileURLWithPath: "/tmp/globalrefiner/refine-onethrow-\(i).fit")
            urls.append(url)
            images[url] = constImage(0.3)
            regs.append(refinerReg(subIndex: i + 1, url: url))
        }
        let loader = StubFrameLoader(images: images)
        loader.throwing = [urls[2]]
        let refiner = GlobalRefiner(loader: loader, onLog: { _ in })
        let result = refiner.refine(survivors: regs, currentGeneration: 0, kappa: 3.0, minSubs: 3,
                                    maxSampleBytes: 10_000_000, deadline: .distantFuture, isCancelled: { false })
        let unwrapped = try XCTUnwrap(result)
        XCTAssertEqual(unwrapped.skipped, 1)
        XCTAssertEqual(unwrapped.survivorCount, 4)
    }

    /// A throw for the FIRST survivor's URL — sizing must fall through to the next successful
    /// load rather than failing outright.
    func testRefineFirstSurvivorFailureFallsThroughForSizing() throws {
        var images = [URL: AstroImage]()
        var regs: [SubRegistration] = []
        var urls: [URL] = []
        for i in 0..<5 {
            let url = URL(fileURLWithPath: "/tmp/globalrefiner/refine-firstthrow-\(i).fit")
            urls.append(url)
            images[url] = constImage(0.4)
            regs.append(refinerReg(subIndex: i + 1, url: url))
        }
        let loader = StubFrameLoader(images: images)
        loader.throwing = [urls[0]]
        let refiner = GlobalRefiner(loader: loader, onLog: { _ in })
        let result = refiner.refine(survivors: regs, currentGeneration: 0, kappa: 3.0, minSubs: 3,
                                    maxSampleBytes: 10_000_000, deadline: .distantFuture, isCancelled: { false })
        let unwrapped = try XCTUnwrap(result, "sizing must fall through to the next successful load")
        XCTAssertEqual(unwrapped.skipped, 1)
    }

    /// Under budget (`inGen.count <= maxSampleFrames`): output reuses the cached sample —
    /// each survivor is loaded AT MOST ONCE (no disk re-read to build the output).
    func testRefineUnderBudgetReusesCachedFramesNoExtraLoads() throws {
        var images = [URL: AstroImage]()
        var regs: [SubRegistration] = []
        for i in 0..<5 {
            let url = URL(fileURLWithPath: "/tmp/globalrefiner/refine-reuse-\(i).fit")
            images[url] = constImage(0.5)
            regs.append(refinerReg(subIndex: i + 1, url: url))
        }
        let loader = StubFrameLoader(images: images)
        let refiner = GlobalRefiner(loader: loader, onLog: { _ in })
        let result = refiner.refine(survivors: regs, currentGeneration: 0, kappa: 3.0, minSubs: 5,
                                    maxSampleBytes: 10_000_000, deadline: .distantFuture, isCancelled: { false })
        XCTAssertNotNil(result)
        XCTAssertEqual(loader.callCount, 5, "each survivor must be loaded at most once under budget")
    }

    /// HARD floor: `maxSampleFrames < 11` → onLog the insufficient-budget message and return
    /// nil (online master kept), never a robust center computed from too few RAM samples.
    func testRefineInsufficientSampleBudgetLogsAndReturnsNil() throws {
        var images = [URL: AstroImage]()
        var regs: [SubRegistration] = []
        for i in 0..<5 {
            let url = URL(fileURLWithPath: "/tmp/globalrefiner/refine-budget-\(i).fit")
            images[url] = constImage(0.5, w: 2, h: 2)
            regs.append(refinerReg(subIndex: i + 1, url: url))
        }
        let loader = StubFrameLoader(images: images)
        var logs: [String] = []
        let refiner = GlobalRefiner(loader: loader, onLog: { logs.append($0) })
        // 2x2x1 frame -> sampleFrameBytes = 4·4(pixels) + 4·4(mask) = 32; budget 32 -> maxSampleFrames = 1 < 11.
        let result = refiner.refine(survivors: regs, currentGeneration: 0, kappa: 3.0, minSubs: 1,
                                    maxSampleBytes: 32, deadline: .distantFuture, isCancelled: { false })
        XCTAssertNil(result)
        XCTAssertEqual(logs, ["live rejection off: insufficient sample budget (1 < 11 frames)"])
    }

    /// Odd-sample invariant (P2-2/P2-4), asserted observably via the debug hook: a CAPPED pass
    /// (maxSampleFrames < inGen.count) where one SELECTED sample index fails to load must drop
    /// the materialized sample's last element to keep it odd (a true middle median) rather than
    /// leaving it even.
    func testRefineCappedPassDropsToOddSampleOnSelectedFrameFailure() throws {
        let n = 15
        var images = [URL: AstroImage]()
        var regs: [SubRegistration] = []
        var urls: [URL] = []
        for i in 0..<n {
            let url = URL(fileURLWithPath: "/tmp/globalrefiner/refine-capped-\(i).fit")
            urls.append(url)
            images[url] = constImage(0.1, w: 2, h: 2)
            regs.append(refinerReg(subIndex: i + 1, url: url))
        }
        // Pin the selected sample indices so the induced failure lands on a SELECTED one.
        let idxs = SubRegistration.sampleIndices(count: 15, maxSampleFrames: 12)
        XCTAssertEqual(idxs, [0, 1, 2, 4, 5, 7, 8, 9, 11, 12, 14], "test precondition")
        let loader = StubFrameLoader(images: images)
        loader.throwing = [urls[5]]   // index 5 is a SELECTED sample index
        let refiner = GlobalRefiner(loader: loader, onLog: { _ in })
        // sampleFrameBytes = 32 (2x2x1); maxSampleBytes = 12*32 = 384 -> maxSampleFrames = 12 (>= 11 floor).
        let result = refiner.refine(survivors: regs, currentGeneration: 0, kappa: 3.0, minSubs: 5,
                                    maxSampleBytes: 384, deadline: .distantFuture, isCancelled: { false })
        let unwrapped = try XCTUnwrap(result)
        XCTAssertEqual(refiner.lastMaterializedSampleCount, 9,
                       "11 selected - 1 failure = 10 (even) -> drop-last keeps it odd at 9")
        XCTAssertEqual(unwrapped.skipped, 1)
        XCTAssertEqual(unwrapped.survivorCount, 14)
    }

    /// If selected-frame load failures drop the materialized sample below `minSubs`, fail
    /// closed (return nil) rather than computing a robust center from too few frames.
    func testRefineBelowMinSubsAfterSampleFailuresReturnsNil() throws {
        var images = [URL: AstroImage]()
        var regs: [SubRegistration] = []
        var urls: [URL] = []
        for i in 0..<5 {
            let url = URL(fileURLWithPath: "/tmp/globalrefiner/refine-belowmin-\(i).fit")
            urls.append(url)
            images[url] = constImage(0.6)
            regs.append(refinerReg(subIndex: i + 1, url: url))
        }
        let loader = StubFrameLoader(images: images)
        loader.throwing = [urls[2]]
        let refiner = GlobalRefiner(loader: loader, onLog: { _ in })
        // 5 survivors, 1 fails -> materialized sample 4 (even) -> drop-last -> 3, below minSubs=5.
        let result = refiner.refine(survivors: regs, currentGeneration: 0, kappa: 3.0, minSubs: 5,
                                    maxSampleBytes: 10_000_000, deadline: .distantFuture, isCancelled: { false })
        XCTAssertNil(result)
    }

    func testRefineIsCancelledReturnsNilWithoutLoading() throws {
        var images = [URL: AstroImage]()
        var regs: [SubRegistration] = []
        for i in 0..<5 {
            let url = URL(fileURLWithPath: "/tmp/globalrefiner/refine-cancel-\(i).fit")
            images[url] = constImage(0.7)
            regs.append(refinerReg(subIndex: i + 1, url: url))
        }
        let loader = StubFrameLoader(images: images)
        let refiner = GlobalRefiner(loader: loader, onLog: { _ in })
        let result = refiner.refine(survivors: regs, currentGeneration: 0, kappa: 3.0, minSubs: 5,
                                    maxSampleBytes: 10_000_000, deadline: .distantFuture, isCancelled: { true })
        XCTAssertNil(result)
        XCTAssertEqual(loader.callCount, 0, "cancellation must stop before the first load")
    }

    func testRefinePastDeadlineReturnsNilWithoutLoading() throws {
        var images = [URL: AstroImage]()
        var regs: [SubRegistration] = []
        for i in 0..<5 {
            let url = URL(fileURLWithPath: "/tmp/globalrefiner/refine-deadline-\(i).fit")
            images[url] = constImage(0.8)
            regs.append(refinerReg(subIndex: i + 1, url: url))
        }
        let loader = StubFrameLoader(images: images)
        let refiner = GlobalRefiner(loader: loader, onLog: { _ in })
        let past = DispatchTime.now() - 1.0
        let result = refiner.refine(survivors: regs, currentGeneration: 0, kappa: 3.0, minSubs: 5,
                                    maxSampleBytes: 10_000_000, deadline: past, isCancelled: { false })
        XCTAssertNil(result)
        XCTAssertEqual(loader.callCount, 0, "an already-past deadline must stop before the first load")
    }

    /// The passId mechanism (step 7): a cancel() that lands before any pass has ever started
    /// records against passId 0 — it must not poison the FIRST real pass (passId 1).
    func testRefineCancelBeforeFirstPassDoesNotPoisonIt() throws {
        var images = [URL: AstroImage]()
        var regs: [SubRegistration] = []
        for i in 0..<5 {
            let url = URL(fileURLWithPath: "/tmp/globalrefiner/refine-passid-\(i).fit")
            images[url] = constImage(0.9)
            regs.append(refinerReg(subIndex: i + 1, url: url))
        }
        let loader = StubFrameLoader(images: images)
        let refiner = GlobalRefiner(loader: loader, onLog: { _ in })
        refiner.cancel()
        let result = refiner.refine(survivors: regs, currentGeneration: 0, kappa: 3.0, minSubs: 5,
                                    maxSampleBytes: 10_000_000, deadline: .distantFuture, isCancelled: { false })
        XCTAssertNotNil(result, "a pre-emptive cancel() targeting passId 0 must not kill passId 1")
    }

    // MARK: - Task 7: FreshnessKey + publishedMaster

    /// Step 1: a master published under the CURRENT `FreshnessKey` is returned; it goes stale
    /// (returns nil) the instant ANY of the key's four components changes underneath it — a
    /// user reject (`userRejectGeneration`), a κ change, a reseed (`stackGeneration`) — and is
    /// hidden AND cleared the instant the live-rejection feature is turned off, regardless of
    /// whether the key still matches (feature-off parity: `FreshnessKey` does not encode
    /// enabled-ness).
    func testPublishedMasterIfCurrentGoesStaleOnRejectKappaReseedAndFeatureOff() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let profile = SessionProfile(targetName: "Freshness", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let engine = StackEngine()

        let sub1 = stubFrame(dx: 0, dy: 0, name: "f1.fit", digest: "d1", timestamp: 0)
        let sub2 = stubFrame(dx: 1.0, dy: -0.5, name: "f2.fit", digest: "d2", timestamp: 1)
        let sub3 = stubFrame(dx: 1.6, dy: 0.3, name: "f3.fit", digest: "d3", timestamp: 2)

        let source = StubLiveSource(sequence: [sub1, sub2, sub3])
        let pipeline = SessionPipeline(nativeSource: source, engine: engine,
                                       profile: profile, rootDirectory: sessions)
        try pipeline.start()

        let regs = waitForRegistrations(pipeline, count: 3)
        XCTAssertEqual(regs.count, 3)

        // Feature ON — required before any published master is ever served.
        pipeline.configureLiveRejection(enabled: true)

        let dummyMaster = constImage(0.42)
        func publishAtCurrentKey() {
            let key = pipeline.currentFreshnessKey()
            pipeline.publishedMaster = (image: dummyMaster, coverage: [1, 1, 1, 1], survivorCount: 3, key: key)
        }

        // 1. Publish at the CURRENT key -> served.
        publishAtCurrentKey()
        XCTAssertNotNil(pipeline.publishedMasterIfCurrent(),
                        "a master published under the current key must be served")

        // 2. User-reject bumps userRejectGeneration -> currentFreshnessKey() changes -> stale.
        pipeline.setUserRejected([2])
        XCTAssertNil(pipeline.publishedMasterIfCurrent(),
                     "a user reject must invalidate a previously-published master")

        // 3. Republish at the new key, then a kappa change -> stale again.
        publishAtCurrentKey()
        XCTAssertNotNil(pipeline.publishedMasterIfCurrent())
        pipeline.configureLiveRejection(kappa: 5.0)
        XCTAssertNil(pipeline.publishedMasterIfCurrent(),
                     "a kappa change must invalidate a previously-published master")

        // 4. Republish, then reseed. `reseed()` itself now refreshes the cached freshness key
        //    (T7 review fix — a manual reseed is a mutation point, same as reject/kappa), so the
        //    master is already stale the instant reseed() returns, with no further frame needed.
        //    Still feed one more sub afterward and confirm it lands in a NEW generation, matching
        //    the other sub-cases' end-to-end style.
        publishAtCurrentKey()
        XCTAssertNotNil(pipeline.publishedMasterIfCurrent())
        XCTAssertEqual(pipeline.reseed(), .reseeded)
        XCTAssertNil(pipeline.publishedMasterIfCurrent(),
                     "a reseed (new stackGeneration) must invalidate a previously-published master immediately")
        let sub4 = stubFrame(dx: 0, dy: 0, name: "f4.fit", digest: "d4", timestamp: 3)
        source.send(sub4)
        let regsAfterReseed = waitForRegistrations(pipeline, count: 4)
        XCTAssertEqual(regsAfterReseed.count, 4)
        XCTAssertNotEqual(regsAfterReseed[3].stackGeneration, regsAfterReseed[0].stackGeneration,
                          "test precondition: the post-reseed sub must land in a NEW generation")
        XCTAssertNil(pipeline.publishedMasterIfCurrent(),
                     "still stale after the post-reseed sub lands")

        // 5. Republish, then turn the feature off -> hidden AND cleared.
        publishAtCurrentKey()
        XCTAssertNotNil(pipeline.publishedMasterIfCurrent())
        pipeline.configureLiveRejection(enabled: false)
        XCTAssertNil(pipeline.publishedMasterIfCurrent(), "feature off must hide any published master")
        XCTAssertNil(pipeline.publishedMaster, "feature off must CLEAR publishedMaster (belt-and-suspenders)")

        source.stop()
    }

    /// T7 review regression: `recomputeCachedFreshnessKeyLocked()` was refreshed on sub-append,
    /// `setUserRejected`, and `configureLiveRejection(kappa:)`, but NOT on a manual `reseed()` —
    /// leaving a window from the reseed call until the next accepted frame during which
    /// `publishedMasterIfCurrent()` kept serving the pre-reseed master (observable by a
    /// broadcast/end consumer that samples on a timer independent of frame arrival). This test
    /// asserts the master goes stale IMMEDIATELY on `reseed()` — deliberately WITHOUT sending any
    /// further frame afterward, unlike the multi-mutation test above which also drives a
    /// post-reseed sub for end-to-end coverage.
    func testReseedInvalidatesPublishedMasterImmediatelyWithoutAFollowUpSub() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let profile = SessionProfile(targetName: "ReseedFreshness", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let engine = StackEngine()

        let sub1 = stubFrame(dx: 0, dy: 0, name: "r1.fit", digest: "rd1", timestamp: 0)
        let sub2 = stubFrame(dx: 1.0, dy: -0.5, name: "r2.fit", digest: "rd2", timestamp: 1)
        let sub3 = stubFrame(dx: 1.6, dy: 0.3, name: "r3.fit", digest: "rd3", timestamp: 2)

        let source = StubLiveSource(sequence: [sub1, sub2, sub3])
        let pipeline = SessionPipeline(nativeSource: source, engine: engine,
                                       profile: profile, rootDirectory: sessions)
        try pipeline.start()

        let regs = waitForRegistrations(pipeline, count: 3)
        XCTAssertEqual(regs.count, 3)

        pipeline.configureLiveRejection(enabled: true)

        let dummyMaster = constImage(0.42)
        let key = pipeline.currentFreshnessKey()
        pipeline.publishedMaster = (image: dummyMaster, coverage: [1, 1, 1, 1], survivorCount: 3, key: key)
        XCTAssertNotNil(pipeline.publishedMasterIfCurrent(),
                        "precondition: a master published under the current key must be served")

        XCTAssertEqual(pipeline.reseed(), .reseeded)

        // No frame sent after reseed(). The staleness must come from reseed() itself.
        XCTAssertNil(pipeline.publishedMasterIfCurrent(),
                     "a manual reseed must invalidate a previously-published master IMMEDIATELY, " +
                     "with no further frame required to refresh the cached freshness key")

        source.stop()
    }

    /// A star field with NO correspondence to `field` (a tight grid packed into one corner,
    /// unlike `field`'s spread-out pattern) — TriangleMatcher/TransformSolver can't find a
    /// consistent transform against a `field`-seeded reference, so every frame is rejected
    /// `.noTransform`. Mirrors `SessionPipelinePlateSolveTests.unmatchedFrame`, sized to match
    /// `starImage`'s default 512×512 so it can drive an auto-reseed against a `stubFrame` reference.
    private func unmatchedFrame(name: String, width: Int = 512, height: Int = 512) -> RawFrame {
        var px = [Float](repeating: 0.05, count: width * height)
        for gy in 0..<4 { for gx in 0..<4 {
            let sx = 30 + gx * 12, sy = 30 + gy * 12
            for y in sy - 3...sy + 3 { for x in sx - 3...sx + 3 {
                let dx = Double(x - sx), dy = Double(y - sy)
                px[y * width + x] += 0.8 * Float(exp(-(dx * dx + dy * dy) / (2 * 2.0 * 2.0)))
            } }
        } }
        let img = AstroImage(width: width, height: height, channels: 1, pixels: px, sourceIsLinear: true)
        return RawFrame(image: img, bayerPattern: nil, bottomUp: false,
                        timestamp: Date(timeIntervalSince1970: 0), sourceName: name)
    }

    /// T8 review regression (Fix 1): the engine's internal AUTO-reseed (systematic
    /// `.noTransform` after `autoReseedThreshold` consecutive failures) drops the reference and
    /// bumps `engine.autoReseedCount`/`currentStackGeneration` in the SAME `handleNative` call
    /// that returns `.rejected(.noTransform)` — no `SubRegistration` is appended for that frame,
    /// so the T7 sub-append recompute doesn't run, and the cached `_freshnessKey` (and therefore
    /// `publishedMasterIfCurrent()`) would silently keep serving a master built from the
    /// just-discarded reference until whatever LATER sub happens to become the new reference.
    /// Mirrors `testReseedInvalidatesPublishedMasterImmediatelyWithoutAFollowUpSub` (the manual-
    /// reseed analogue) but for the auto-reseed path: publish a dummy master under the
    /// pre-auto-reseed key, drive a real auto-reseed with unmatched frames, and assert the
    /// master goes stale THE INSTANT the "Auto-reseeded" log line lands — before any post-reseed
    /// sub is ever sent (none is: no accepted sub == no `SubRegistration` append == the T7 hook
    /// never fires — this test would have caught the bug even before the T7 fix existed).
    func testAutoReseedInvalidatesPublishedMasterImmediatelyWithoutAFollowUpSub() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let profile = SessionProfile(targetName: "AutoReseedFreshness", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let engine = StackEngine(autoReseedThreshold: 3)   // small threshold — fast, deterministic test

        // Seed the reference from the real `field` pattern (via stubFrame/starImage).
        let seed = stubFrame(dx: 0, dy: 0, name: "ar-seed.fit", digest: "ar-seed", timestamp: 0)
        let source = StubLiveSource(sequence: [seed])
        let pipeline = SessionPipeline(nativeSource: source, engine: engine,
                                       profile: profile, rootDirectory: sessions)
        var log = ""
        let logLock = NSLock()
        pipeline.onLog = { msg in logLock.withLock { log += msg } }
        try pipeline.start()

        let regs = waitForRegistrations(pipeline, count: 1)
        XCTAssertEqual(regs.count, 1, "the seed frame must become the reference")
        let preReseedGeneration = pipeline.currentFreshnessKey().stackGeneration

        // Feature ON — required before any published master is ever served.
        pipeline.configureLiveRejection(enabled: true)

        // Publish a dummy master under the PRE-auto-reseed key.
        let dummyMaster = constImage(0.42)
        let preReseedKey = pipeline.currentFreshnessKey()
        pipeline.publishedMaster = (image: dummyMaster, coverage: [1, 1, 1, 1], survivorCount: 1, key: preReseedKey)
        XCTAssertNotNil(pipeline.publishedMasterIfCurrent(),
                        "precondition: a master published under the current key must be served")

        // Drive the engine's internal auto-reseed with unmatched frames, ONE AT A TIME, stopping
        // the instant it fires — mirrors SessionPipelinePlateSolveTests.testAutoReseedVoidsStoredWCS
        // so no extra unmatched frame seeds a stray reference past the one auto-reseed we're testing.
        var u = 0
        let deadline = Date().addingTimeInterval(15)
        while !(logLock.withLock { log.contains("Auto-reseeded") }) && Date() < deadline {
            source.send(unmatchedFrame(name: "u\(u).fit")); u += 1
            let step = Date().addingTimeInterval(1)
            while !(logLock.withLock { log.contains("Auto-reseeded") }) && Date() < step { usleep(30_000) }
        }
        XCTAssertTrue(logLock.withLock { log.contains("Auto-reseeded") },
                     "unmatched frames should trigger the engine's internal auto-reseed")

        // The generation must have advanced (auto-reseed bumps engine.currentStackGeneration).
        let postReseedKey = pipeline.currentFreshnessKey()
        XCTAssertNotEqual(postReseedKey.stackGeneration, preReseedGeneration,
                          "auto-reseed detection must advance the cached freshness key's generation")

        // Core assertion: the pre-reseed master must be stale IMMEDIATELY — no post-reseed sub was
        // ever sent (the auto-reseed frame itself is a rejection, not an accepted sub), so if this
        // were still nil-safe only via the LATER sub-append recompute, it would still (wrongly)
        // report the stale master as current here.
        XCTAssertNil(pipeline.publishedMasterIfCurrent(),
                     "an auto-reseed must invalidate a previously-published master IMMEDIATELY, " +
                     "with no post-reseed sub required to refresh the cached freshness key")
        XCTAssertEqual(pipeline.subRegistrations().count, 1,
                       "no accepted sub landed after the auto-reseed — proves the invalidation didn't " +
                       "come from the (T7) sub-append recompute path")

        source.stop()
    }

    // MARK: - Task 8: trigger + self-throttle (background, off the online path)

    /// A `FrameLoader` that signals `entered` on EVERY call (so the test can observe each pass
    /// reaching the loader) but only BLOCKS on `release` for the literal first-ever call — every
    /// subsequent call (including a later pass's) returns immediately. Models "a pass parked
    /// mid-load" for exactly one interleaving window, while still being observable across passes.
    private final class FirstCallGatedLoader: FrameLoader {
        private let lock = NSLock()
        private(set) var callCount = 0
        private let entered: DispatchSemaphore
        private let release: DispatchSemaphore
        private let image: AstroImage
        init(image: AstroImage, entered: DispatchSemaphore, release: DispatchSemaphore) {
            self.image = image; self.entered = entered; self.release = release
        }
        func loadRegisteredInput(url: URL, expectedContentDigest: String?) throws -> AstroImage {
            let isFirst: Bool = lock.withLock { callCount += 1; return callCount == 1 }
            entered.signal()
            if isFirst {
                release.wait()
            }
            return image
        }
    }

    /// A plain `FrameLoader` returning a constant image for any URL — no gating, for tests that
    /// just need a background pass to complete quickly.
    private final class ConstFrameLoader: FrameLoader {
        private let image: AstroImage
        init(image: AstroImage) { self.image = image }
        func loadRegisteredInput(url: URL, expectedContentDigest: String?) throws -> AstroImage { image }
    }

    /// Registers `count` distinct, successfully-registering subs against a fresh reference through
    /// a REAL native `.live` pipeline (small, monotonically increasing translations so every sub
    /// registers against sub 1) and returns the pipeline once all `count` registrations have
    /// landed. Caller must `source.stop()` when done.
    private func pipelineWithRegisteredSubs(count: Int, sandbox: URL) throws
        -> (pipeline: SessionPipeline, source: StubLiveSource) {
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let profile = SessionProfile(targetName: "Trigger", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let engine = StackEngine()
        let frames = (0..<count).map { i in
            stubFrame(dx: Double(i) * 0.1, dy: -Double(i) * 0.05, name: "trig\(i).fit",
                     digest: "trig-digest-\(i)", timestamp: TimeInterval(i))
        }
        let source = StubLiveSource(sequence: frames)
        let pipeline = SessionPipeline(nativeSource: source, engine: engine,
                                       profile: profile, rootDirectory: sessions)
        try pipeline.start()
        let regs = waitForRegistrations(pipeline, count: count, timeout: 30)
        XCTAssertEqual(regs.count, count, "test precondition: all \(count) subs must register")
        return (pipeline, source)
    }

    /// (a) Coalescing: firing `noteChanged()` 5× rapidly while a pass is in flight must run AT
    /// MOST one pass concurrently and run EXACTLY one extra pass after the first completes — never
    /// 5. The calling thread must never block (every `noteChanged()` call returns immediately, even
    /// while a pass is parked behind a blocked loader).
    func testNoteChangedCoalescesRapidFireIntoAtMostOneConcurrentPlusOneRerun() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let loader = FirstCallGatedLoader(image: constImage(0.5), entered: entered, release: release)
        let refiner = GlobalRefiner(loader: loader, onLog: { _ in })

        let url = URL(fileURLWithPath: "/tmp/globalrefiner/trigger-coalesce.fit")
        let reg = refinerReg(subIndex: 1, url: url)
        let key = FreshnessKey(stackGeneration: 0, survivorSubIndices: [1], userRejectGeneration: 0, kappa: 3.0)
        refiner.makeSnapshot = { PassSnapshot(survivors: [reg], currentGeneration: 0, key: key) }
        refiner.minSubsProvider = { 1 }
        refiner.maxSampleBytesProvider = { 10_000_000 }

        let publishLock = NSLock()
        var publishedCount = 0
        let bothPublished = DispatchSemaphore(value: 0)
        refiner.publish = { _, _ in
            let count: Int = publishLock.withLock { publishedCount += 1; return publishedCount }
            if count == 2 { bothPublished.signal() }
        }

        refiner.noteChanged()   // pass 1 starts, blocks on the loader's first call
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success, "pass 1 must reach the loader")

        // Fire 4 more rapidly while pass 1 is in flight — each must return essentially instantly.
        for _ in 0..<4 {
            let callStart = Date()
            refiner.noteChanged()
            XCTAssertLessThan(Date().timeIntervalSince(callStart), 0.25,
                              "noteChanged() must never block the calling thread")
        }

        // At most one pass concurrent: the loader has been entered exactly once so far.
        XCTAssertEqual(loader.callCount, 1, "at most one pass may be in flight concurrently")

        release.signal()   // let pass 1 finish
        // The 4 coalesced calls must produce exactly ONE rerun, not 4 — pass 2 starts next.
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success, "exactly one coalesced pass must follow")
        XCTAssertEqual(loader.callCount, 2)
        release.signal()   // let pass 2 finish

        XCTAssertEqual(bothPublished.wait(timeout: .now() + 2), .success, "both passes must complete")
        XCTAssertEqual(publishedCount, 2, "5 rapid-fire notifications must coalesce into 2 total passes")
        XCTAssertEqual(refiner.passesRun, 2)
    }

    /// (b) Parked-pass / stale-result race: a pass starts and blocks mid-load; while it's parked,
    /// a user reject lands (`setUserRejected` + `noteUserRejectChanged`, mirroring the expected
    /// Task 11 `AppModel.toggleReject` call pattern). The in-flight pass must publish under its
    /// OWN (now stale) captured key — `publishedMasterIfCurrent()` must refuse to serve it — and
    /// the dirty flag must trigger a fresh pass over the NEW (post-reject) survivor set.
    func testParkedPassPublishesUnderStaleKeyAndDirtyFlagRerunsOverNewSurvivors() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (pipeline, source) = try pipelineWithRegisteredSubs(count: 15, sandbox: sandbox)
        defer { source.stop() }

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let loader = FirstCallGatedLoader(image: constImage(0.3), entered: entered, release: release)
        pipeline.refinerLoaderOverride = loader

        // enabledRose (OFF -> ON with 15 survivors already present) triggers pass 1 immediately.
        pipeline.configureLiveRejection(enabled: true, kappa: 3.0, maxSampleBytes: 10_000_000)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success, "pass 1 must start and reach the loader")

        // Mid-pass: a user reject lands. This changes the survivor set AND bumps
        // userRejectGeneration (twice — setUserRejected then noteUserRejectChanged, the expected
        // Task 11 pairing) — both harmless per the noteUserRejectChanged doc.
        pipeline.setUserRejected([2])
        pipeline.noteUserRejectChanged()

        release.signal()   // let the parked pass 1 finish and publish under its STALE captured key

        // Pass 1's result must NOT be served as current — its key predates the reject.
        let staleDeadline = Date().addingTimeInterval(2)
        var sawStaleWindow = false
        while Date() < staleDeadline {
            if pipeline.publishedMasterIfCurrent() == nil { sawStaleWindow = true; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(sawStaleWindow,
                     "the parked pass's result, published under its stale captured key, " +
                     "must never be served as current")

        // The dirty flag must trigger a fresh pass over the NEW survivor set (14 subs, sub 2 excluded).
        let freshDeadline = Date().addingTimeInterval(5)
        var freshMaster: (image: AstroImage, coverage: [Float], survivorCount: Int)?
        while Date() < freshDeadline {
            if let m = pipeline.publishedMasterIfCurrent() { freshMaster = m; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let unwrapped = try XCTUnwrap(freshMaster, "a fresh pass must run over the new survivor set and publish")
        XCTAssertEqual(unwrapped.survivorCount, 14, "the fresh pass must reflect the rejected sub's exclusion")
    }

    /// (c) OFF -> ON with survivors already present must trigger an immediate build — not wait for
    /// the next sub/reject/reseed.
    func testEnablingFeatureMidSessionWithSurvivorsPresentTriggersImmediateBuild() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (pipeline, source) = try pipelineWithRegisteredSubs(count: 15, sandbox: sandbox)
        defer { source.stop() }

        // Feature-off parity: nothing published before enabling.
        XCTAssertNil(pipeline.publishedMasterIfCurrent())

        pipeline.refinerLoaderOverride = ConstFrameLoader(image: constImage(0.4))
        pipeline.configureLiveRejection(enabled: true, kappa: 3.0, maxSampleBytes: 10_000_000)

        let deadline = Date().addingTimeInterval(5)
        var master: (image: AstroImage, coverage: [Float], survivorCount: Int)?
        while Date() < deadline {
            if let m = pipeline.publishedMasterIfCurrent() { master = m; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let unwrapped = try XCTUnwrap(master, "turning the feature ON with survivors present must build immediately")
        XCTAssertEqual(unwrapped.survivorCount, 15, "no sub was rejected — all 15 survivors contribute")
    }
}
