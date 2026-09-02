import XCTest
@testable import LiveAstroCore

/// Task 12: whole-feature acceptance tests for live global rejection (T1–T11 wired end to end).
/// Four tests: (A) always-CI synthetic trail removal (feature ON vs OFF), (B) manual reject
/// actually removes a sub's contribution from the published clean master (C4 acceptance),
/// (C) env-gated real-M51 acceptance (skips cleanly without LAS_TRAIL_FRAMES), (D) feature-OFF
/// byte parity against a golden master.fit produced by the PRE-BRANCH build (76935de).
final class LiveGlobalRejectionTests: XCTestCase {

    // MARK: - Shared fixtures/helpers

    /// A live (isFinite == false) source that yields a fixed sequence of RawFrames up front
    /// (buffered), stays open like a real live source, and finishes its stream on stop().
    /// Mirrors GlobalRefinerTests.StubLiveSource / SessionPipelineShutdownTests.T10StubLiveSource.
    final class T12StubLiveSource: FrameSource {
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

    /// A `FrameLoader` backed by a fixed `URL -> AstroImage` map — the standard test-loader shape
    /// used throughout GlobalRefinerTests/SessionPipelineShutdownTests (Task 6/10).
    final class T12MapLoader: FrameLoader {
        private let images: [URL: AstroImage]
        init(images: [URL: AstroImage]) { self.images = images }
        func loadRegisteredInput(url: URL, expectedContentDigest: String?) throws -> AstroImage {
            guard let img = images[url] else { throw NSError(domain: "t12loader", code: 1) }
            return img
        }
    }

    /// The 20-star field used throughout this suite (`(i*47)%240+8, (i*83)%240+8` for i in 0..<20,
    /// same generator as SessionPipelineShutdownTests.seedFrame / the T10 helpers) — proven to
    /// register through the real StackEngine (≥15-star reference quorum, all followers match).
    private func t12StarPixels(width: Int = 256, height: Int = 256) -> [Float] {
        var px = [Float](repeating: 0.05, count: width * height)
        for i in 0..<20 {
            let sx = (i * 47) % 240 + 8, sy = (i * 83) % 240 + 8
            for y in max(0, sy - 6)...min(height - 1, sy + 6) {
                for x in max(0, sx - 6)...min(width - 1, sx + 6) {
                    let dx = Double(x - sx), dy = Double(y - sy)
                    px[y * width + x] += 0.8 * Float(exp(-(dx * dx + dy * dy) / (2 * 2.0 * 2.0)))
                }
            }
        }
        return px
    }

    /// The star field with an optional bright DIAGONAL STREAK baked in at x==y for x in [30,80) —
    /// a single-pixel-wide line. Under 4-connectivity (StarDetector's flood fill only looks at
    /// L/R/U/D neighbors, never diagonals) each streak pixel is an ISOLATED 1-px component, well
    /// below StarDetector's `minArea = 3` — so the streak is invisible to star detection/
    /// registration (verified: none of the 20 star centers land inside the [30,80)x[30,80) band,
    /// nearest is ~26px away, far outside the ±6px Gaussian falloff) while still being a real,
    /// bright, multi-pixel artifact for the robust combine / online accumulator to differ on.
    private func t12StarImageWithStreak(_ streak: Bool, width: Int = 256, height: Int = 256) -> AstroImage {
        var px = t12StarPixels(width: width, height: height)
        if streak {
            for i in 30..<80 { px[i * width + i] = 0.97 }
        }
        return AstroImage(width: width, height: height, channels: 1, pixels: px, sourceIsLinear: true)
    }

    private func t12Identity(_ digest: String) -> FileIdentity {
        FileIdentity(dev: 0, ino: 0, size: 0, mtimeSec: 0, mtimeNsec: 0, digest: digest)
    }

    private func t12Profile(_ name: String) -> SessionProfile {
        SessionProfile(targetName: name, telescope: "T", camera: "C", mount: "M", filter: "F",
                       locationLabel: "L", bortle: 5, subExposureSeconds: 20, notes: "")
    }

    /// Polls `subRegistrations()` until it reaches `count` entries or the deadline passes.
    private func t12WaitForRegistrations(_ pipeline: SessionPipeline, count: Int,
                                         timeout: TimeInterval = 5) -> [SubRegistration] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let regs = pipeline.subRegistrations()
            if regs.count >= count { return regs }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return pipeline.subRegistrations()
    }

    /// Polls `publishedMasterIfCurrent()` until non-nil or the deadline passes.
    private func t12WaitForPublished(_ pipeline: SessionPipeline, timeout: TimeInterval = 5)
        -> (image: AstroImage, coverage: [Float], survivorCount: Int)? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let m = pipeline.publishedMasterIfCurrent() { return m }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    // MARK: - A. Synthetic trail-removal (always-CI)

    /// Registers 11 subs (quorum + comfortably above the GlobalRefiner's hard `maxSampleFrames >=
    /// 11` budget floor) built from the SAME 20-star field; sub 0 (which becomes the reference —
    /// guaranteed EXACT identity transform, so the refiner's warp never interpolates/smears the
    /// single-pixel streak) also carries the diagonal streak. Drives TWO separate `.live` pipelines
    /// over byte-identical input: one feature ON, one feature OFF.
    ///
    /// Feature ON: the background/final refiner reproduces every sub (via a stub `FrameLoader`
    /// returning the SAME per-sub content the online engine saw) and robustly combines them —
    /// the streak is a single-frame outlier a multi-frame per-pixel median/MAD clip removes.
    /// Feature OFF: the online per-frame accumulator never compares frames against each other, so
    /// the streak survives (diluted into the mean, not clipped) — the two masters must differ
    /// exactly at the streak location, not at a control location neither run touches.
    func testSyntheticTrailRemovalFeatureOnVsOff() throws {
        let n = 11
        let streakIndex = 0   // the reference sub — guaranteed identity transform, no warp smear
        let streakLoc = (x: 55, y: 55)     // clear of all 20 star centers (nearest ~26px away)
        let controlLoc = (x: 220, y: 220)  // also clear of all stars and of the streak band

        func run(streakOn: Bool, featureOn: Bool, label: String) throws -> (streak: Float, control: Float) {
            let sandbox = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: sandbox) }
            let sessions = sandbox.appendingPathComponent("sessions")
            try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

            let frames = (0..<n).map { i -> RawFrame in
                let img = t12StarImageWithStreak(streakOn && i == streakIndex)
                return RawFrame(image: img, bayerPattern: nil, bottomUp: false,
                                timestamp: Date(timeIntervalSince1970: TimeInterval(i)),
                                sourceName: "\(label)sub\(i).fit",
                                identity: t12Identity("\(label)-digest-\(i)"),
                                sourceURL: URL(fileURLWithPath: "/tmp/t12livegr/\(label)/sub\(i).fit"))
            }
            let source = T12StubLiveSource(sequence: frames)
            let engine = StackEngine()
            let pipeline = SessionPipeline(nativeSource: source, engine: engine,
                                           profile: t12Profile("TrailRemoval-\(label)"), rootDirectory: sessions)
            pipeline.rendersReplay = false
            try pipeline.start()
            defer { source.stop() }
            let regs = t12WaitForRegistrations(pipeline, count: n)
            XCTAssertEqual(regs.count, n, "\(label): all \(n) subs must register")
            XCTAssertEqual(regs[0].transform, .identity,
                           "\(label): the reference (streak-bearing) sub must have an EXACT identity transform")

            if featureOn {
                var images: [URL: AstroImage] = [:]
                for (i, reg) in regs.enumerated() {
                    images[reg.relayURL] = t12StarImageWithStreak(streakOn && i == streakIndex)
                }
                pipeline.refinerLoaderOverride = T12MapLoader(images: images)
                pipeline.configureLiveRejection(enabled: true, kappa: 3.0, maxSampleBytes: 200_000_000)
            }

            let dir = try pipeline.end()
            let masterURL = dir.appendingPathComponent("master.fit")
            let master = try FITSReader.read(Data(contentsOf: masterURL))
            XCTAssertEqual(master.width, 256, "\(label): master must be uncropped (full-coverage identity registration)")
            let streakVal = master.pixels[streakLoc.y * master.width + streakLoc.x]
            let controlVal = master.pixels[controlLoc.y * master.width + controlLoc.x]
            return (streakVal, controlVal)
        }

        let off = try run(streakOn: true, featureOn: false, label: "off")
        XCTAssertGreaterThan(off.streak - off.control, 0.03,
                             "feature OFF: the online per-frame accumulator cannot compare frames " +
                             "against each other, so the streak must survive (diluted, still bright) " +
                             "relative to an untouched control pixel")

        let on = try run(streakOn: true, featureOn: true, label: "on")
        XCTAssertLessThan(abs(on.streak - on.control), 0.02,
                          "feature ON: the background/final refiner's multi-frame robust combine " +
                          "must clip the single-frame streak outlier — the streak pixel must read " +
                          "background, indistinguishable from the control pixel")
    }

    // MARK: - B. Reject -> clean master updates (C4 acceptance)

    private func t12FlatImage(_ v: Float, size: Int = 16) -> AstroImage {
        AstroImage(width: size, height: size, channels: 1,
                  pixels: [Float](repeating: v, count: size * size), sourceIsLinear: true)
    }

    /// Registers 11 subs (identical star field -> identity transforms), then publishes a clean
    /// master where ONE un-flagged sub carries a huge artifact. κ is deliberately astronomical
    /// (5e7 * the GlobalCombine scale floor 1e-7 = a 5.0 clip threshold, far above the 2.0 pixel
    /// deviation used below) so the robust combine's OWN auto-clip (already covered by test A)
    /// never removes it — isolating this test to the manual-reject wiring alone: the artifact
    /// must be visible in the initial published master and gone only after
    /// `setUserRejected`/`noteUserRejectChanged`, not merely because the freshness key changed.
    func testRejectRemovesArtifactFromPublishedMaster() throws {
        let n = 11
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let star = t12StarPixels()
        let starImage = AstroImage(width: 256, height: 256, channels: 1, pixels: star, sourceIsLinear: true)
        let frames = (0..<n).map { i -> RawFrame in
            RawFrame(image: starImage, bayerPattern: nil, bottomUp: false,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(i)), sourceName: "rejsub\(i).fit",
                    identity: t12Identity("rej-digest-\(i)"),
                    sourceURL: URL(fileURLWithPath: "/tmp/t12livegr/reject/sub\(i).fit"))
        }
        let source = T12StubLiveSource(sequence: frames)
        let engine = StackEngine()
        let pipeline = SessionPipeline(nativeSource: source, engine: engine,
                                       profile: t12Profile("RejectFlow"), rootDirectory: sessions)
        pipeline.rendersReplay = false
        try pipeline.start()
        defer { source.stop() }
        let regs = t12WaitForRegistrations(pipeline, count: n)
        XCTAssertEqual(regs.count, n, "precondition: all \(n) subs must register")

        let badArrayIndex = 5   // an arbitrary non-reference sub
        let background: Float = 0.1
        let artifact: Float = 2.1   // background + 2.0 — comfortably inside the deliberately-huge kappa*scaleFloor threshold
        var images: [URL: AstroImage] = [:]
        for reg in regs { images[reg.relayURL] = t12FlatImage(background) }
        images[regs[badArrayIndex].relayURL] = t12FlatImage(artifact)
        pipeline.refinerLoaderOverride = T12MapLoader(images: images)
        pipeline.configureLiveRejection(enabled: true, kappa: 50_000_000, maxSampleBytes: 200_000_000)

        let initial = try XCTUnwrap(t12WaitForPublished(pipeline),
                                    "the enabledRose background pass must publish an initial clean master")
        XCTAssertEqual(initial.survivorCount, n)
        // Weighted mean over 11 subs (10 * 0.1 + 1 * 2.1) / 11 ≈ 0.282 — well above the 0.1
        // background, clearly visible, and unambiguously NOT auto-clipped by the huge kappa.
        XCTAssertGreaterThan(initial.image.pixels[0], 0.2,
                             "precondition: the un-flagged bad sub's artifact must be visible in the " +
                             "initial published master (kappa deliberately huge so the robust combine's " +
                             "own auto-clip — already covered by test A — does not remove it)")

        let badSubIndex = regs[badArrayIndex].subIndex
        pipeline.setUserRejected([badSubIndex])
        pipeline.noteUserRejectChanged()

        // The stale (pre-reject) result must never be served as current, and a fresh pass must
        // republish over the new (10-survivor) set.
        let after = try XCTUnwrap(t12WaitForPublished(pipeline),
                                  "a fresh pass must republish over the post-reject survivor set")
        XCTAssertEqual(after.survivorCount, n - 1, "the rejected sub must be excluded from the survivor count")
        XCTAssertEqual(after.image.pixels[0], background, accuracy: 0.01,
                       "the bad sub's contribution must be GONE from the republished master's pixel " +
                       "value, not merely a changed freshnessKey")
    }

    // MARK: - C. Env-gated real data (skippable)

    /// Real-data acceptance (mirrors PlateSolverTests.testSolvesRealM63Frame's gating): set
    /// LAS_TRAIL_FRAMES to a directory of real subs (incl. one with a satellite/plane trail) to
    /// run. Reads the subs ONCE into RawFrames and drives them through TWO **live** pipelines
    /// (feature ON / OFF) via `T12StubLiveSource`, then (a) locates the trail as the pixel where
    /// the two masters diverge most (the ONLY thing this feature should change) and asserts the
    /// global (ON) master reads close to a robust LOCAL background estimate there, and (b)
    /// computes SNR = mean/σ over a flat background ROI (a corner block, chosen to avoid both the
    /// galaxy core and the detected trail location) for both masters and requires
    /// globalSNR >= 0.9 * onlineSNR (tolerance for the survivor-count difference — not a strict >=).
    ///
    /// Why a LIVE source, not `FolderFrameSource(mode: .importOnce)` (the original form, which
    /// validated nothing): the consume dispatch branches on `source.isFinite` — a finite import
    /// source takes the parallel `BatchImporter` path, which never captures the SubRegistration
    /// cache; only the live path (`handleNative`) does. Under import mode the refiner therefore had
    /// nothing to reload ("no surviving subs could be loaded"), no clean master was ever built,
    /// `end()` fell back to the online master, and ON == OFF byte-for-byte. Live rejection is a
    /// live-stacking feature; this test must exercise its real path. Unlike the synthetic tests
    /// (stub loader), the ON run here uses the PRODUCTION `FrameLoader`: the refiner re-reads
    /// the real files from `sourceURL` and content-digest-verifies them.
    ///
    /// Needs an OPTIMIZED build for real 26 MP subs — unoptimized star detection/registration is
    /// slow enough to trip the 120 s live-drain stall window. Run:
    ///   LAS_TRAIL_FRAMES=<dir> swift test -c release --filter LiveGlobalRejectionTests/testRealM51TrailRemovalPreservesSNR
    /// A debug build skips with that instruction instead of hanging.
    func testRealM51TrailRemovalPreservesSNR() throws {
        guard let dirPath = ProcessInfo.processInfo.environment["LAS_TRAIL_FRAMES"] else {
            throw XCTSkip("set LAS_TRAIL_FRAMES to a directory of real subs (incl. a trail sub) to run")
        }
        #if DEBUG
        throw XCTSkip("real 26 MP subs need an optimized build (debug star detection/registration trips the "
                      + "120 s drain window) — run: LAS_TRAIL_FRAMES=<dir> swift test -c release "
                      + "--filter LiveGlobalRejectionTests/testRealM51TrailRemovalPreservesSNR")
        #endif
        let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
        let subURLs = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "fit" }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: [.numeric]) == .orderedAscending }
        guard subURLs.count >= 11 else {
            throw XCTSkip("LAS_TRAIL_FRAMES needs >= 11 subs to clear the live-rejection quorum")
        }
        // Read once, replay twice. `loadRawFrame(url:)` sets BOTH `sourceURL` (the T5 cache-capture
        // gate requires it) and the content `identity` (the production loader re-verifies its digest
        // on reload) — exactly what a real live relay frame carries.
        let frames = try subURLs.map { try FolderFrameSource.loadRawFrame(url: $0) }

        func run(featureOn: Bool, label: String) throws -> URL {
            let sandbox = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let sessions = sandbox.appendingPathComponent("sessions")
            try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
            let source = T12StubLiveSource(sequence: frames)   // live (isFinite == false) → handleNative → cache captured
            let engine = StackEngine()
            let pipeline = SessionPipeline(nativeSource: source, engine: engine,
                                           profile: t12Profile("real-\(label)"), rootDirectory: sessions)
            pipeline.rendersReplay = false
            if featureOn {
                // Real 26 MP reload + warp + combine at end() can exceed the 30 s default; a too-short
                // budget would silently fall back to the online master and mask a real failure.
                pipeline.finalRefineBudget = .seconds(180)
                pipeline.configureLiveRejection(enabled: true, kappa: 3.0, maxSampleBytes: 6_000_000_000)
            }
            try pipeline.start()
            // Fail fast, never hang: every sub must register through the live path within the window
            // (registration capture is unconditional, so this also proves the OFF run consumed all frames).
            let regs = t12WaitForRegistrations(pipeline, count: frames.count, timeout: 180)
            XCTAssertEqual(regs.count, frames.count,
                           "[\(label)] all \(frames.count) real subs must register through the live path "
                           + "(got \(regs.count)) — with fewer there is nothing to reject")
            if featureOn {
                // Require a CURRENT clean master BEFORE end(): this is the production FrameLoader
                // re-reading + digest-verifying the real files and the refiner combining them.
                let published = t12WaitForPublished(pipeline, timeout: 240)
                XCTAssertNotNil(published, "the refiner must publish a current clean master over the real "
                                + "subs (production loader reload + digest verify + combine) before end()")
                if let published {
                    XCTAssertEqual(published.survivorCount, frames.count,
                                   "every real sub should survive into the clean master (none user-rejected)")
                }
            }
            let dir = try pipeline.end()
            return dir.appendingPathComponent("master.fit")
        }

        let onURL = try run(featureOn: true, label: "on")
        let offURL = try run(featureOn: false, label: "off")
        let onMaster = try FITSReader.read(Data(contentsOf: onURL))
        let offMaster = try FITSReader.read(Data(contentsOf: offURL))
        guard onMaster.width == offMaster.width, onMaster.height == offMaster.height,
              onMaster.channels == offMaster.channels else {
            throw XCTSkip("ON/OFF masters have different dimensions (survivor-set-dependent crop) — cannot compare pixel-for-pixel")
        }
        let w = onMaster.width, h = onMaster.height
        let plane = w * h

        // (a) Locate the trail (channel 0 plane only — a trail affects luminance in every channel
        // similarly, one plane is enough). The trail's signature is "OFF elevated where ON reads
        // BACKGROUND": a single-frame outlier the online mean keeps (diluted) and the robust
        // combine removes. A naive global argmax of |OFF - ON| lands on bright STAR CORES instead —
        // a clipped mean and a winsorized online mean legitimately disagree there by more than a
        // diluted trail — so restrict the search to near-background pixels of the clean master.
        // Robust global background (median/MAD of the ON master), subsampled for speed.
        var bgSample: [Float] = []
        bgSample.reserveCapacity(plane / 8 + 1)
        var si = 0
        while si < plane { bgSample.append(onMaster.pixels[si]); si += 8 }
        bgSample.sort()
        let bgMedian = bgSample[bgSample.count / 2]
        var bgDev = bgSample.map { abs($0 - bgMedian) }
        bgDev.sort()
        let bgSigma = max(1.4826 * bgDev[bgDev.count / 2], 1e-6)
        let bgCeiling = bgMedian + 3 * bgSigma
        var bestIdx = -1
        var bestDiff: Float = 0
        for i in 0..<plane where onMaster.pixels[i] <= bgCeiling {
            let d = offMaster.pixels[i] - onMaster.pixels[i]
            if d > bestDiff { bestDiff = d; bestIdx = i }
        }
        XCTAssertGreaterThan(bestDiff, 3 * bgSigma,
                             "the online master must carry a single-frame artifact over background that the "
                             + "clean master removed — largest OFF-ON over near-background pixels is only "
                             + "\(bestDiff) vs background noise σ=\(bgSigma)")
        guard bestIdx >= 0 else { XCTFail("no near-background pixel diverges between ON and OFF"); return }
        let tx = bestIdx % w, ty = bestIdx / w

        // Robust LOCAL background + noise around the trail point in the GLOBAL (ON) master: an
        // annulus (15..30 px radius) excluding the immediate trail neighborhood.
        var annulus: [Float] = []
        for dy in -30...30 {
            for dx in -30...30 {
                let r = (dx * dx + dy * dy)
                guard r >= 15 * 15, r <= 30 * 30 else { continue }
                let x = tx + dx, y = ty + dy
                guard x >= 0, x < w, y >= 0, y < h else { continue }
                annulus.append(onMaster.pixels[y * w + x])
            }
        }
        XCTAssertFalse(annulus.isEmpty,
                       "trail point too near a frame edge — background annulus is empty, so trail-removal " +
                       "cannot be verified; part (a) must not silently pass on the SNR check alone")
        if !annulus.isEmpty {
            annulus.sort()
            let localBackground = annulus[annulus.count / 2]
            var localDev = annulus.map { abs($0 - localBackground) }
            localDev.sort()
            let localSigma = max(1.4826 * localDev[localDev.count / 2], 1e-6)
            // Present online: the OFF master genuinely carried the artifact at this pixel.
            XCTAssertGreaterThan(offMaster.pixels[bestIdx] - localBackground, 3 * localSigma,
                                 "the online (feature-OFF) master must be elevated well above the local "
                                 + "background at the trail (OFF=\(offMaster.pixels[bestIdx]), "
                                 + "bg=\(localBackground), σ=\(localSigma)) — otherwise nothing was there to remove")
            // Removed globally: the ON master reads background there to within the local noise —
            // removed, not merely diluted (a diluted trail would still sit several σ above).
            XCTAssertEqual(onMaster.pixels[bestIdx], localBackground, accuracy: 3 * localSigma,
                           "the global (feature-ON) master must read the local background at the trail "
                           + "location (ON=\(onMaster.pixels[bestIdx]), bg=\(localBackground), σ=\(localSigma)) "
                           + "— the trail must be removed, not merely diluted")
        }

        // (b) SNR ROI: a corner block, sized to avoid both the trail (>= 40px from it) and the
        // (typically centered, post-registration) galaxy core.
        let roiSize = max(20, min(w, h) / 10)
        let corners = [(0, 0), (w - roiSize, 0), (0, h - roiSize), (w - roiSize, h - roiSize)]
        var chosenCorner: (x: Int, y: Int)? = nil
        for c in corners {
            let cx = c.0 + roiSize / 2, cy = c.1 + roiSize / 2
            if abs(cx - tx) > 40 || abs(cy - ty) > 40 { chosenCorner = (x: c.0, y: c.1); break }
        }
        guard let corner = chosenCorner else {
            XCTFail("no corner ROI clears the >40px trail exclusion — refusing to fall back to a " +
                    "possibly-contaminated (0,0) ROI for the SNR measurement")
            return
        }
        func snr(_ img: FITSImage) -> Double {
            var vals: [Double] = []
            for y in corner.y..<min(h, corner.y + roiSize) {
                for x in corner.x..<min(w, corner.x + roiSize) {
                    vals.append(Double(img.pixels[y * w + x]))
                }
            }
            guard !vals.isEmpty else { return 0 }
            let mean = vals.reduce(0, +) / Double(vals.count)
            let variance = vals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(vals.count)
            let sigma = variance.squareRoot()
            return sigma > 1e-9 ? mean / sigma : 0
        }
        let onSNR = snr(onMaster), offSNR = snr(offMaster)
        XCTAssertGreaterThanOrEqual(onSNR, 0.9 * offSNR,
                                    "removing a trail must not regress background SNR by more than the " +
                                    "survivor-count-difference tolerance (global >= 0.9 * online)")
    }

    // MARK: - D. Feature-OFF byte parity (I4)

    /// Byte-identical parity against a golden `master.fit` produced by the PRE-BRANCH base build
    /// (76935de8fb91dfbd612876f6008a05498be8c2d5) over the SAME 5 checked-in fixture subs
    /// (`Tests/LiveAstroCoreTests/Fixtures/parity_subs/Light_sub_00{0..4}.fit`), via
    /// `Sources/repro-runner` (already present at that commit — no feature code involved, just
    /// the ordinary `.live` FolderFrameSource -> StackEngine -> SessionPipeline path) run in a
    /// `git worktree add /private/tmp/las-base-parity 76935de` checkout with
    /// `SessionProfile(targetName: "watcher-stall-repro", subExposureSeconds: 10)` (repro-runner's
    /// hardcoded profile) against the fixture dir. The golden master (STACKCNT=5, TOTALEXP=50,
    /// 256x256, uncropped) is checked in at
    /// `Tests/LiveAstroCoreTests/Fixtures/parity_golden_master.fit`.
    ///
    /// This test drives the SAME 5 fixture subs (read via the real `FolderFrameSource(.live)`
    /// path, matching the golden generation exactly) through the CURRENT (head) build with the
    /// live-rejection feature never enabled, and asserts the written `master.fit` is byte-for-byte
    /// identical to the golden fixture — proving the feature-OFF online path is unchanged.
    func testFeatureOffMasterIsByteIdenticalToPreBranchGolden() throws {
        guard let fixturesDir = Bundle.module.resourceURL?.appendingPathComponent("Fixtures") else {
            return XCTFail("test bundle missing Fixtures resources")
        }
        let subsDir = fixturesDir.appendingPathComponent("parity_subs")
        let goldenURL = fixturesDir.appendingPathComponent("parity_golden_master.fit")
        let subFiles = try FileManager.default.contentsOfDirectory(at: subsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "fit" }
        XCTAssertEqual(subFiles.count, 5, "precondition: exactly 5 fixture subs")

        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

        // Same profile fields repro-runner hardcoded when the golden fixture was generated.
        let profile = SessionProfile(targetName: "watcher-stall-repro", subExposureSeconds: 10)
        let source = FolderFrameSource(folder: subsDir, mode: .live)
        let engine = StackEngine()
        let pipeline = SessionPipeline(nativeSource: source, engine: engine,
                                       profile: profile, rootDirectory: sessions)
        pipeline.rendersReplay = false
        try pipeline.start()
        // Feature-OFF: configureLiveRejection is never called — `liveRejectionActive` stays at its
        // default `false`, exactly matching the pre-branch build (where the API doesn't exist at all).
        let regs = t12WaitForRegistrations(pipeline, count: 5, timeout: 15)
        XCTAssertEqual(regs.count, 5, "precondition: all 5 fixture subs must register")

        let dir = try pipeline.end()
        let writtenData = try Data(contentsOf: dir.appendingPathComponent("master.fit"))
        let goldenData = try Data(contentsOf: goldenURL)
        XCTAssertEqual(writtenData, goldenData,
                       "feature-OFF master.fit must be byte-identical to the pre-branch golden fixture")
    }
}
