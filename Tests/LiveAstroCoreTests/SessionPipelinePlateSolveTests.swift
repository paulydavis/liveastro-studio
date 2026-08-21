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
