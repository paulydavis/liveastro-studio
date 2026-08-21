import XCTest
@testable import LiveAstroCore

/// Sub-project 3a: SessionPipeline runs the plate-solver off the hot path once a reference frame with
/// FITS metadata (RA/DEC/FOCALLEN/XPIXSZ) is established, and exposes the WCS via `currentWCS`.
/// Optional end-to-end — any missing precondition (no catalog / no metadata) leaves `currentWCS` nil.
final class SessionPipelinePlateSolveTests: XCTestCase {
    private let ARCSEC_PER_RAD = 206264.806247
    private let SUB = 256
    private let CRA = 150.0, CDEC = 22.0
    private let FULL_SCALE = 2.0                 // arcsec/px at full-res
    // FOCALLEN/XPIXSZ chosen so XPIXSZ/FOCALLEN*206.265 == FULL_SCALE.
    private let XPIXSZ = 3.76, FOCALLEN = 387.778   // 3.76/387.778*206.265 ≈ 2.0

    /// A catalog of celestial stars spread to fill the sub's FOV (256px * 2"/px ≈ 8.5').
    private func catalog() -> StarCatalog {
        var stars: [CatalogStar] = []
        var seed: UInt64 = 0x1234
        for _ in 0..<40 {
            seed = seed &* 6364136223846793005 &+ 1
            let dra = (Double((seed >> 33) & 0xFFFF)/65535 - 0.5) * 0.14 / cos(CDEC * .pi/180)
            seed = seed &* 6364136223846793005 &+ 1
            let ddec = (Double((seed >> 33) & 0xFFFF)/65535 - 0.5) * 0.14
            seed = seed &* 6364136223846793005 &+ 1
            let mag = 5.0 + Double((seed >> 40) & 0xFF)/255 * 3.0
            stars.append(CatalogStar(ra: Float(CRA + dra), dec: Float(CDEC + ddec), mag: Float(mag)))
        }
        return try! StarCatalog(data: StarCatalog.encode(stars))
    }

    /// Full-res pixel where a north-up camera at (CRA,CDEC), FULL_SCALE, zero rotation sees a catalog star.
    private func project(ra: Double, dec: Double) -> (x: Double, y: Double) {
        let p = GnomonicProjection.project(ra: ra, dec: dec, centerRA: CRA, centerDec: CDEC)
        let gx = Double(SUB)/2 + (p.xi * ARCSEC_PER_RAD) / FULL_SCALE
        let gy = Double(SUB)/2 - (p.eta * ARCSEC_PER_RAD) / FULL_SCALE
        return (gx, gy)
    }

    private func meta(withWCS: Bool) -> SourceMetadata {
        var m = SourceMetadata()
        m.object = "Test"
        if withWCS { m.ra = CRA; m.dec = CDEC; m.focalLengthMM = FOCALLEN; m.pixelSizeUM = XPIXSZ }
        else { m.focalLengthMM = nil; m.pixelSizeUM = nil }   // metadata present but no WCS keys
        return m
    }

    /// Write a mono sub whose stars are the catalog projected through the known WCS (+ per-sub dither).
    private func writeSub(_ dir: URL, name: String, cat: StarCatalog, dither: (Double, Double),
                          metadata: SourceMetadata?) throws {
        var px = [Float](repeating: 0.05, count: SUB * SUB)
        for cs in cat.stars {
            let p = project(ra: Double(cs.ra), dec: Double(cs.dec))
            let sx = p.x + dither.0, sy = p.y + dither.1
            guard sx >= 6, sx < Double(SUB) - 6, sy >= 6, sy < Double(SUB) - 6 else { continue }
            let amp = Float(pow(10, -0.4 * (Double(cs.mag) - 5))) * 0.8
            for y in Int(sy) - 5...Int(sy) + 5 {
                for x in Int(sx) - 5...Int(sx) + 5 {
                    let dx = Double(x) - sx, dy = Double(y) - sy
                    px[y * SUB + x] += amp * Float(exp(-(dx*dx + dy*dy) / (2 * 2.0 * 2.0)))
                }
            }
        }
        try FITSWriter.float32(width: SUB, height: SUB, channels: 1, pixels: px, metadata: metadata)
            .write(to: dir.appendingPathComponent(name))
    }

    private func runImport(catalogInjected: StarCatalog?, withWCS: Bool) throws -> WCS? {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let subsDir = sandbox.appendingPathComponent("subs")
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: subsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let cat = catalog()
        let dithers: [(Double, Double)] = [(0, 0), (2, 1), (-1, 2), (1, -2), (0, 3)]
        for (i, d) in dithers.enumerated() {
            try writeSub(subsDir, name: String(format: "Light_%03d.fit", i + 1), cat: cat,
                         dither: d, metadata: i == 0 ? meta(withWCS: withWCS) : nil)
        }
        let profile = SessionProfile(targetName: "PS", telescope: "T", camera: "C", mount: "M",
                                     filter: "L", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 60, notes: "")
        let source = FolderFrameSource(folder: subsDir, mode: .importOnce, fileNamePrefix: "Light_")
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: profile, rootDirectory: sessions,
                                       neutralizeBackground: false)
        pipeline.plateSolveCatalog = catalogInjected
        try pipeline.start()
        _ = try pipeline.end()
        // The solve runs on a background queue; give it a bounded moment to land after the last frame.
        let deadline = Date().addingTimeInterval(10)
        while pipeline.currentWCS == nil && Date() < deadline { usleep(50_000) }
        return pipeline.currentWCS
    }

    // MARK: live source for the reseed test

    private final class LiveSource: FrameSource {
        let frames: AsyncStream<RawFrame>
        private let cont: AsyncStream<RawFrame>.Continuation
        var isFinite: Bool { false }
        var totalCount: Int? { nil }
        init() { var c: AsyncStream<RawFrame>.Continuation!; frames = AsyncStream { c = $0 }; cont = c }
        func start() throws {}
        func stop() { cont.finish() }
        func send(_ f: RawFrame) { cont.yield(f) }
    }

    /// A live RawFrame: catalog projected through the WCS (+ dither), mono, optional metadata.
    private func frame(_ cat: StarCatalog, name: String, dither: (Double, Double), withMeta: Bool) -> RawFrame {
        var px = [Float](repeating: 0.05, count: SUB * SUB)
        for cs in cat.stars {
            let p = project(ra: Double(cs.ra), dec: Double(cs.dec))
            let sx = p.x + dither.0, sy = p.y + dither.1
            guard sx >= 6, sx < Double(SUB) - 6, sy >= 6, sy < Double(SUB) - 6 else { continue }
            let amp = Float(pow(10, -0.4 * (Double(cs.mag) - 5))) * 0.8
            for y in Int(sy) - 5...Int(sy) + 5 {
                for x in Int(sx) - 5...Int(sx) + 5 {
                    let dx = Double(x) - sx, dy = Double(y) - sy
                    px[y * SUB + x] += amp * Float(exp(-(dx*dx + dy*dy) / (2 * 2.0 * 2.0)))
                }
            }
        }
        let img = AstroImage(width: SUB, height: SUB, channels: 1, pixels: px, sourceIsLinear: true)
        return RawFrame(image: img, bayerPattern: nil, bottomUp: false,
                        timestamp: Date(timeIntervalSince1970: 0), sourceName: name,
                        metadata: withMeta ? meta(withWCS: true) : nil)
    }

    /// Reseed voids the stored WCS and the new reference re-solves against its fresh stars.
    func testReseedVoidsThenReSolves() throws {
        let cat = catalog()
        let source = LiveSource()
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let profile = SessionProfile(targetName: "PS", telescope: "T", camera: "C", mount: "M",
                                     filter: "L", locationLabel: "L", bortle: 5, subExposureSeconds: 60, notes: "")
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: profile, rootDirectory: sandbox, neutralizeBackground: false)
        pipeline.plateSolveCatalog = cat
        var accepted = 0
        pipeline.onUpdate = { _, _ in accepted += 1 }
        try pipeline.start()

        func pollWCS(_ present: Bool, _ msg: String) {
            let deadline = Date().addingTimeInterval(10)
            while (pipeline.currentWCS != nil) != present && Date() < deadline { usleep(50_000) }
            XCTAssertEqual(pipeline.currentWCS != nil, present, msg)
        }
        func waitFrames(_ n: Int) {
            let deadline = Date().addingTimeInterval(10)
            while accepted < n && Date() < deadline { usleep(20_000) }
        }

        // First field → seed + solve
        source.send(frame(cat, name: "a0.fit", dither: (0, 0), withMeta: true))
        source.send(frame(cat, name: "a1.fit", dither: (2, 1), withMeta: false))
        waitFrames(2)
        pollWCS(true, "first reference should solve")

        // Reseed → stored WCS voided
        XCTAssertEqual(pipeline.reseed(), .reseeded)
        pollWCS(false, "reseed should void the stored WCS")

        // New reference (same field) → re-solves
        source.send(frame(cat, name: "b0.fit", dither: (0, 0), withMeta: false))
        source.send(frame(cat, name: "b1.fit", dither: (-1, 2), withMeta: false))
        waitFrames(4)
        pollWCS(true, "new reference should re-solve after reseed")
        let wcs = pipeline.currentWCS!
        let sep = 3600 * hypot((wcs.centerRA - CRA) * cos(CDEC * .pi/180), wcs.centerDec - CDEC)
        XCTAssertLessThan(sep, 180, "re-solved center off by \(sep)\"")
        source.stop()
    }

    /// A distinct star field (tight grid in one corner) that will NOT triangle-match the catalog field,
    /// so it fails registration and drives the engine's internal auto-reseed.
    private func unmatchedFrame(_ name: String) -> RawFrame {
        var px = [Float](repeating: 0.05, count: SUB * SUB)
        for gy in 0..<4 { for gx in 0..<4 {
            let sx = 30 + gx * 12, sy = 30 + gy * 12
            for y in sy - 3...sy + 3 { for x in sx - 3...sx + 3 {
                let dx = Double(x - sx), dy = Double(y - sy)
                px[y * SUB + x] += 0.8 * Float(exp(-(dx*dx + dy*dy) / (2 * 2.0 * 2.0)))
            } }
        } }
        let img = AstroImage(width: SUB, height: SUB, channels: 1, pixels: px, sourceIsLinear: true)
        return RawFrame(image: img, bayerPattern: nil, bottomUp: false,
                        timestamp: Date(timeIntervalSince1970: 0), sourceName: name, metadata: nil)
    }

    /// Auto-reseed regression: when the engine drops its reference internally (auto-reseed after repeated
    /// registration failures), the stored WCS must be voided AND the new reference must re-solve — the
    /// two halves of `invalidatePlateSolve()` (clear `solvedWCS`, reset `solveAttempted`). Pinning both
    /// locally: a regression that cleared the WCS but forgot to reset `solveAttempted` would blank the
    /// display correctly yet never re-solve, and the nil check alone wouldn't catch it.
    func testAutoReseedVoidsStoredWCS() throws {
        let cat = catalog()
        let source = LiveSource()
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let profile = SessionProfile(targetName: "PS", telescope: "T", camera: "C", mount: "M",
                                     filter: "L", locationLabel: "L", bortle: 5, subExposureSeconds: 60, notes: "")
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),   // default autoReseedThreshold 6
                                       profile: profile, rootDirectory: sandbox, neutralizeBackground: false)
        pipeline.plateSolveCatalog = cat
        var log = ""
        pipeline.onLog = { log += $0 }
        var accepted = 0
        pipeline.onUpdate = { _, _ in accepted += 1 }
        try pipeline.start()

        // Seed the catalog field and solve.
        source.send(frame(cat, name: "a0.fit", dither: (0, 0), withMeta: true))
        source.send(frame(cat, name: "a1.fit", dither: (2, 1), withMeta: false))
        var d = Date().addingTimeInterval(10)
        while pipeline.currentWCS == nil && Date() < d { usleep(50_000) }
        XCTAssertNotNil(pipeline.currentWCS, "seeded reference should solve")

        // Drive an auto-reseed with unmatched frames, ONE AT A TIME, stopping the instant it fires — so
        // no extra unmatched frame seeds a stray reference (which would need a second reseed cycle to
        // clear and muddy the clean re-solve below).
        var u = 0
        d = Date().addingTimeInterval(15)
        while !log.contains("Auto-reseeded") && Date() < d {
            source.send(unmatchedFrame("u\(u).fit")); u += 1
            let step = Date().addingTimeInterval(1)        // let this frame process before the next
            while !log.contains("Auto-reseeded") && Date() < step { usleep(30_000) }
        }
        XCTAssertTrue(log.contains("Auto-reseeded"), "unmatched frames should trigger auto-reseed")

        // Half 1 — the stored WCS must be voided (RED before the fix: it stayed = old solve).
        d = Date().addingTimeInterval(10)
        while pipeline.currentWCS != nil && Date() < d { usleep(50_000) }
        XCTAssertNil(pipeline.currentWCS, "auto-reseed must void the stale WCS")

        // Half 2 — the fresh catalog reference must RE-SOLVE (proves solveAttempted was reset, not just
        // solvedWCS cleared). The reference was cleared with no stray frame, so these seed it directly.
        source.send(frame(cat, name: "b0.fit", dither: (0, 0), withMeta: false))
        source.send(frame(cat, name: "b1.fit", dither: (1, -1), withMeta: false))
        d = Date().addingTimeInterval(10)
        while pipeline.currentWCS == nil && Date() < d { usleep(50_000) }
        let wcs = try XCTUnwrap(pipeline.currentWCS, "new reference must re-solve after auto-reseed")
        let sep = 3600 * hypot((wcs.centerRA - CRA) * cos(CDEC * .pi/180), wcs.centerDec - CDEC)
        XCTAssertLessThan(sep, 180, "re-solved center off by \(sep)\"")
        source.stop()
    }

    /// Race regression (adversarial review Finding 1): a reseed landing in the window between claiming
    /// the solve generation and reading the reference stars must NOT produce a stale WCS tagged with the
    /// new generation, and must NOT wedge `solveAttempted` so the real new reference can never solve.
    /// The test fires a reseed from exactly that window via `onSolveClaimedForTest`, then feeds a fresh
    /// reference and asserts it solves correctly (proving neither a stale store nor a stuck attempt).
    func testReseedDuringSolveClaimDoesNotStaleOrStick() throws {
        let cat = catalog()
        let source = LiveSource()
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let profile = SessionProfile(targetName: "PS", telescope: "T", camera: "C", mount: "M",
                                     filter: "L", locationLabel: "L", bortle: 5, subExposureSeconds: 60, notes: "")
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: profile, rootDirectory: sandbox, neutralizeBackground: false)
        pipeline.plateSolveCatalog = cat
        var accepted = 0
        pipeline.onUpdate = { _, _ in accepted += 1 }
        // Fire a reseed the FIRST time a solve is claimed — i.e. right after the seeding frame claims the
        // generation, before it reads the stars. One-shot so later (post-reseed) attempts run normally.
        var firedReseed = false
        pipeline.onSolveClaimedForTest = { [weak pipeline] in
            if !firedReseed { firedReseed = true; _ = pipeline?.reseed() }
        }
        try pipeline.start()
        func waitFrames(_ n: Int) {
            let deadline = Date().addingTimeInterval(10)
            while accepted < n && Date() < deadline { usleep(20_000) }
        }
        // Seeding frame → claims solve → hook reseeds mid-claim → this attempt must bail (stars cleared).
        source.send(frame(cat, name: "s0.fit", dither: (0, 0), withMeta: true))
        waitFrames(1)
        XCTAssertTrue(firedReseed, "the claim hook should have fired on the seeding frame")
        // Now feed a fresh reference; it must solve (not be starved by a stuck solveAttempted) and the
        // stored WCS must be the CORRECT current-field solve, never a stale one.
        source.send(frame(cat, name: "n0.fit", dither: (1, 1), withMeta: false))
        source.send(frame(cat, name: "n1.fit", dither: (-1, 2), withMeta: false))
        waitFrames(3)
        let deadline = Date().addingTimeInterval(10)
        while pipeline.currentWCS == nil && Date() < deadline { usleep(50_000) }
        let wcs = try XCTUnwrap(pipeline.currentWCS, "fresh reference must solve after a mid-claim reseed")
        let sep = 3600 * hypot((wcs.centerRA - CRA) * cos(CDEC * .pi/180), wcs.centerDec - CDEC)
        XCTAssertLessThan(sep, 180, "must be the correct current-field solve, not stale (off \(sep)\")")
        source.stop()
    }

    func testSolvesReferenceAndExposesWCS() throws {
        guard let wcs = try runImport(catalogInjected: catalog(), withWCS: true) else {
            return XCTFail("expected a plate solve, got nil")
        }
        let sep = 3600 * hypot((wcs.centerRA - CRA) * cos(CDEC * .pi/180), wcs.centerDec - CDEC)
        XCTAssertLessThan(sep, 180, "solved center off by \(sep)\" (inliers \(wcs.inlierCount))")
    }

    func testNoCatalogLeavesWCSNil() throws {
        XCTAssertNil(try runImport(catalogInjected: nil, withWCS: true))
    }

    func testMissingMetadataLeavesWCSNil() throws {
        XCTAssertNil(try runImport(catalogInjected: catalog(), withWCS: false))
    }

    /// The ×2 half-res scale is what places the recovered center correctly: solving the same reference
    /// stars with the un-doubled (full-res) scale misplaces the center well beyond tolerance. Guards the
    /// factor against silent regression. (Direct solver call — the pipeline path is covered above.)
    func testHalfResScaleFactorIsRequired() throws {
        let cat = catalog()
        // half-res reference stars = catalog projected through the WCS, at half-res positions.
        var stars: [Star] = []
        for cs in cat.stars {
            let p = project(ra: Double(cs.ra), dec: Double(cs.dec))
            stars.append(Star(x: p.x / 2, y: p.y / 2, flux: pow(10, -0.4 * Double(cs.mag))))
        }
        let halfScale = XPIXSZ / FOCALLEN * 206.264806 * 2
        let good = PlateSolver.solve(stars: stars, width: SUB/2, height: SUB/2, pixelScaleArcsec: halfScale,
                                     approxCenterRA: CRA, approxCenterDec: CDEC, catalog: cat)
        XCTAssertNotNil(good, "doubled half-res scale should solve")
        let goodSep = 3600 * hypot((good!.centerRA - CRA) * cos(CDEC * .pi/180), good!.centerDec - CDEC)
        XCTAssertLessThan(goodSep, 180)
        // Un-doubled scale: either fails to solve, or lands far from the true center.
        if let bad = PlateSolver.solve(stars: stars, width: SUB/2, height: SUB/2,
                                       pixelScaleArcsec: halfScale / 2, approxCenterRA: CRA,
                                       approxCenterDec: CDEC, catalog: cat) {
            let badSep = 3600 * hypot((bad.centerRA - CRA) * cos(CDEC * .pi/180), bad.centerDec - CDEC)
            XCTAssertGreaterThan(badSep, 180, "un-doubled scale must not land near the true center")
        }
    }
}
