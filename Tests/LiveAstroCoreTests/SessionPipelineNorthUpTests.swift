import XCTest
import CoreGraphics
@testable import LiveAstroCore

/// 3b task 3: when `northUp` is on AND a solve is available, `displayCGImage` (hence broadcast /
/// latest.png / snapshots / replay) is rotated to north-up; otherwise it's a no-op.
final class SessionPipelineNorthUpTests: XCTestCase {
    private let ARCSEC_PER_RAD = 206264.806247
    private let SUB = 256
    private let CRA = 150.0, CDEC = 22.0
    private let FULL_SCALE = 2.0, ROT = 30.0            // frames carry a 30° rotation → solve recovers it
    private let XPIXSZ = 3.76, FOCALLEN = 387.778

    private func catalog() -> StarCatalog {
        var stars: [CatalogStar] = []
        var seed: UInt64 = 0x77
        for _ in 0..<40 {
            seed = seed &* 6364136223846793005 &+ 1
            let dra = (Double((seed >> 33) & 0xFFFF)/65535 - 0.5) * 0.12 / cos(CDEC * .pi/180)
            seed = seed &* 6364136223846793005 &+ 1
            let ddec = (Double((seed >> 33) & 0xFFFF)/65535 - 0.5) * 0.12
            seed = seed &* 6364136223846793005 &+ 1
            let mag = 5.0 + Double((seed >> 40) & 0xFF)/255 * 3.0
            stars.append(CatalogStar(ra: Float(CRA + dra), dec: Float(CDEC + ddec), mag: Float(mag)))
        }
        return try! StarCatalog(data: StarCatalog.encode(stars))
    }

    /// Catalog star → full-res frame pixel through a WCS rotated by ROT.
    private func project(ra: Double, dec: Double) -> (x: Double, y: Double) {
        let p = GnomonicProjection.project(ra: ra, dec: dec, centerRA: CRA, centerDec: CDEC)
        let gx = Double(SUB)/2 + (p.xi * ARCSEC_PER_RAD) / FULL_SCALE
        let gy = Double(SUB)/2 - (p.eta * ARCSEC_PER_RAD) / FULL_SCALE
        let cx = Double(SUB)/2, cy = Double(SUB)/2, th = -ROT * .pi/180
        let dx = gx - cx, dy = gy - cy
        return (cx + cos(th)*dx - sin(th)*dy, cy + sin(th)*dx + cos(th)*dy)
    }

    private func meta() -> SourceMetadata {
        var m = SourceMetadata(); m.ra = CRA; m.dec = CDEC; m.focalLengthMM = FOCALLEN; m.pixelSizeUM = XPIXSZ
        return m
    }

    private func writeSub(_ dir: URL, name: String, cat: StarCatalog, dither: (Double, Double), meta: SourceMetadata?) throws {
        var px = [Float](repeating: 0.05, count: SUB * SUB)
        for cs in cat.stars {
            let p = project(ra: Double(cs.ra), dec: Double(cs.dec))
            let sx = p.x + dither.0, sy = p.y + dither.1
            guard sx >= 6, sx < Double(SUB)-6, sy >= 6, sy < Double(SUB)-6 else { continue }
            let amp = Float(pow(10, -0.4 * (Double(cs.mag) - 5))) * 0.8
            for y in Int(sy)-5...Int(sy)+5 { for x in Int(sx)-5...Int(sx)+5 {
                let dx = Double(x)-sx, dy = Double(y)-sy
                px[y*SUB+x] += amp * Float(exp(-(dx*dx+dy*dy)/(2*2.0*2.0)))
            } }
        }
        try FITSWriter.float32(width: SUB, height: SUB, channels: 1, pixels: px, metadata: meta)
            .write(to: dir.appendingPathComponent(name))
    }

    /// Runs an import; returns the pipeline (solved if `catalogInjected` != nil) for renderCurrentDisplay.
    private func runSolvedSession(catalogInjected: StarCatalog?) throws -> SessionPipeline {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let subsDir = sandbox.appendingPathComponent("subs"), sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: subsDir, withIntermediateDirectories: true)
        let cat = catalog()
        for (i, d) in [(0.0,0.0),(2.0,1.0),(-1.0,2.0),(1.0,-2.0),(0.0,3.0)].enumerated() {
            try writeSub(subsDir, name: String(format: "Light_%03d.fit", i+1), cat: cat, dither: d, meta: i == 0 ? meta() : nil)
        }
        let profile = SessionProfile(targetName: "NU", telescope: "T", camera: "C", mount: "M",
                                     filter: "L", locationLabel: "L", bortle: 5, subExposureSeconds: 60, notes: "")
        let source = FolderFrameSource(folder: subsDir, mode: .importOnce, fileNamePrefix: "Light_")
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: profile, rootDirectory: sessions, neutralizeBackground: false)
        pipeline.plateSolveCatalog = catalogInjected
        try pipeline.start()
        _ = try pipeline.end()
        if catalogInjected != nil {
            let deadline = Date().addingTimeInterval(10)
            while pipeline.currentWCS == nil && Date() < deadline { usleep(50_000) }
        }
        return pipeline
    }

    func testNorthUpRotatesDisplayWhenSolved() throws {
        let pipeline = try runSolvedSession(catalogInjected: catalog())
        XCTAssertNotNil(pipeline.currentWCS, "precondition: session solved")
        XCTAssertTrue(pipeline.hasSolvedWCS, "hasSolvedWCS gates the toggle")
        var off = DisplayAdjustments.neutral; off.northUp = false
        var on = DisplayAdjustments.neutral; on.northUp = true
        let a = try XCTUnwrap(pipeline.renderCurrentDisplay(adjustments: off))
        let b = try XCTUnwrap(pipeline.renderCurrentDisplay(adjustments: on))
        // 30° rotation → letterbox bounding box → strictly larger than the un-rotated frame.
        XCTAssertTrue(b.width != a.width || b.height != a.height,
                      "north-up should change the display dimensions (a=\(a.width)x\(a.height) b=\(b.width)x\(b.height))")
        XCTAssertGreaterThanOrEqual(b.width, a.width)
        XCTAssertGreaterThanOrEqual(b.height, a.height)
    }

    func testNorthUpNoOpWhenUnsolved() throws {
        let pipeline = try runSolvedSession(catalogInjected: nil)   // no catalog → currentWCS nil
        XCTAssertNil(pipeline.currentWCS)
        XCTAssertFalse(pipeline.hasSolvedWCS, "no solve → toggle stays disabled")
        var off = DisplayAdjustments.neutral; off.northUp = false
        var on = DisplayAdjustments.neutral; on.northUp = true
        let a = try XCTUnwrap(pipeline.renderCurrentDisplay(adjustments: off))
        let b = try XCTUnwrap(pipeline.renderCurrentDisplay(adjustments: on))
        XCTAssertEqual(b.width, a.width, "northUp with no solve must be a no-op")
        XCTAssertEqual(b.height, a.height)
    }
}
