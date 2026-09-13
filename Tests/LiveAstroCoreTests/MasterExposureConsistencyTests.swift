import XCTest
@testable import LiveAstroCore

/// master.fit must agree with itself. Found 2026-09-10 on a real session: OBJECT and EXPTIME
/// came from the subs' headers while TOTALEXP came from the typed profile, giving
/// STACKCNT=2, EXPTIME=300, TOTALEXP=360 in one file. 2 x 300 is 600.
final class MasterExposureConsistencyTests: XCTestCase {

    /// A registrable starfield whose header carries its own EXPTIME.
    private func writeSub(_ dir: URL, _ name: String, dx: Double, exposure: Double?) throws {
        var px = [Float](repeating: 0.05, count: 256 * 256)
        for i in 0..<20 {
            let sx = Double((i * 47) % 230 + 12) + dx, sy = Double((i * 83) % 230 + 12)
            for y in max(0, Int(sy) - 6)...min(255, Int(sy) + 6) {
                for x in max(0, Int(sx) - 6)...min(255, Int(sx) + 6) {
                    let ddx = Double(x) - sx, ddy = Double(y) - sy
                    px[y * 256 + x] += 0.8 * Float(exp(-(ddx * ddx + ddy * ddy) / 8))
                }
            }
        }
        var meta = SourceMetadata()
        meta.object = "NGC 6960"
        meta.exposureSeconds = exposure
        try FITSWriter.float32(width: 256, height: 256, channels: 1, pixels: px, metadata: meta)
            .write(to: dir.appendingPathComponent(name))
    }

    private func runImport(headerExposure: Double?, profileExposure: Double, exposures: [Double?]? = nil,
                           calibrated: Bool = false) throws -> (header: FITSHeader, manifest: SessionManifest) {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let subs = sandbox.appendingPathComponent("subs")
        try FileManager.default.createDirectory(at: subs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let values = exposures ?? [headerExposure, headerExposure, headerExposure]
        try writeSub(subs, "Light_001.fit", dx: 0, exposure: values[0])
        try writeSub(subs, "Light_002.fit", dx: 1.5, exposure: values[1])
        try writeSub(subs, "Light_003.fit", dx: 3.0, exposure: values[2])

        let profile = SessionProfile(targetName: "Typed", telescope: "T", camera: "C", mount: "M",
                                     filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: profileExposure, notes: "")
        let source = FolderFrameSource(folder: subs, mode: .importOnce, fileNamePrefix: "Light_")
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: profile, rootDirectory: sandbox.appendingPathComponent("sessions"),
                                       calibrator: calibrated ? Calibrator(dark: nil, flat: AstroImage(width: 256, height: 256,
                                           channels: 1, pixels: [Float](repeating: 1, count: 256 * 256), sourceIsLinear: true)) : nil)
        let processed = DispatchSemaphore(value: 0)
        pipeline.onImportProgress = { count, _, _, _ in if count == 3 { processed.signal() } }
        try pipeline.start()
        XCTAssertEqual(processed.wait(timeout: .now() + 30), .success)
        XCTAssertTrue(pipeline.writeMasterSnapshot())
        let snapshotDir = try XCTUnwrap(pipeline.sessionDir)
        let snapshotHeader = try FITSReader.readHeader(Data(contentsOf: snapshotDir.appendingPathComponent("master.fit")))
        let replay = try pipeline.end()
        let dir = replay.deletingLastPathComponent()
        let header = try FITSReader.readHeader(Data(contentsOf: dir.appendingPathComponent("master.fit")))
        let manifest = try ManifestCoding.decoder().decode(SessionManifest.self,
            from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        XCTAssertEqual(snapshotHeader.keywords["EXPTIME"], header.keywords["EXPTIME"])
        XCTAssertEqual(snapshotHeader.keywords["TOTALEXP"], header.keywords["TOTALEXP"])
        return (header, manifest)
    }

    func testMixedExposuresSumContributingFrames() throws {
        let r = try runImport(headerExposure: nil, profileExposure: 180, exposures: [30, 300, 300])
        XCTAssertEqual(Double(r.header.keywords["TOTALEXP"] ?? ""), 630)
        XCTAssertNil(r.header.keywords["EXPTIME"], "a mixed stack has no single sub exposure")
        XCTAssertEqual(r.manifest.snapshots.last?.estimatedIntegrationSeconds, 630)
        XCTAssertEqual(r.manifest.subExposureSeconds, 0, "legacy scalar must not assert 30s for a mixed stack")
        XCTAssertEqual(r.manifest.exposure?.frameCount, 3)
        XCTAssertEqual(r.manifest.snapshots.last?.integrationCaption(fallbackSubSeconds: 180), "10m 30s · 3 subs")
    }

    func testCalibratedImportPreservesOriginalHeaderExposures() throws {
        let r = try runImport(headerExposure: nil, profileExposure: 20, exposures: [30, 300, 300], calibrated: true)
        XCTAssertEqual(Double(r.header.keywords["TOTALEXP"] ?? ""), 630)
        XCTAssertEqual(r.manifest.exposure?.estimatedFrameCount, 0)
    }

    func testMissingFirstExposureFallsBackForThatFrameOnly() throws {
        let r = try runImport(headerExposure: nil, profileExposure: 20, exposures: [nil, 300, 300])
        XCTAssertEqual(Double(r.header.keywords["TOTALEXP"] ?? ""), 620)
        XCTAssertEqual(r.manifest.snapshots.last?.estimatedIntegrationSeconds, 620)
        XCTAssertEqual(Int(r.header.keywords["EXPEST"] ?? ""), 1, "FITS must disclose the fallback frame")
        XCTAssertEqual(r.manifest.exposure?.estimatedFrameCount, 1)
        XCTAssertEqual(r.manifest.importFrameExposures?.map(\.exposure.seconds), [20, 300, 300])
    }

    /// The real case: headers say 300 s, the profile still says 180 s from an earlier target.
    func testTotalExposureFollowsTheSubsHeaderNotTheTypedProfile() throws {
        let r = try runImport(headerExposure: 300, profileExposure: 180)
        XCTAssertEqual(Int(r.header.keywords["STACKCNT"] ?? ""), 3)
        XCTAssertEqual(Double(r.header.keywords["EXPTIME"] ?? ""), 300)
        XCTAssertEqual(Double(r.header.keywords["TOTALEXP"] ?? ""), 900,
                       "TOTALEXP must be STACKCNT x the EXPTIME written in the same header")
        XCTAssertEqual(r.manifest.snapshots.last?.estimatedIntegrationSeconds, 900,
                       "the manifest's integration must use the same exposure")
        XCTAssertEqual(r.manifest.subExposureSeconds, 300)
        XCTAssertEqual(r.manifest.targetName, "NGC 6960")
        let csvRows = SessionFrameCSV.render(manifest: r.manifest).split(separator: "\n").dropFirst()
        XCTAssertEqual(csvRows.last?.split(separator: ",")[4], "900.0")
        XCTAssertEqual(csvRows.last?.split(separator: ",")[5], "300.0")
        let summary = SessionSummaryMarkdown.render(manifest: r.manifest)
        XCTAssertTrue(summary.contains("NGC 6960"))
        XCTAssertFalse(summary.contains("180"))
    }

    /// Fallback: a sub with no EXPTIME in its header keeps today's behaviour — the profile.
    func testTotalExposureFallsBackToProfileWhenHeaderHasNoExposure() throws {
        let r = try runImport(headerExposure: nil, profileExposure: 20)
        XCTAssertNil(r.header.keywords["EXPTIME"])
        XCTAssertEqual(Double(r.header.keywords["TOTALEXP"] ?? ""), 60)
        XCTAssertEqual(r.manifest.snapshots.last?.estimatedIntegrationSeconds, 60)
    }

    func testZeroHeaderExposureIsOmittedWhenProfileSuppliesTheTotal() throws {
        let r = try runImport(headerExposure: 0, profileExposure: 20)
        XCTAssertNil(r.header.keywords["EXPTIME"])
        XCTAssertEqual(Double(r.header.keywords["TOTALEXP"] ?? ""), 60)
        XCTAssertEqual(r.manifest.subExposureSeconds, 20)
    }

    func testRestackOmitsInvalidExposureInsteadOfContradictingTheTotal() throws {
        let image = AstroImage(width: 2, height: 2, channels: 1,
                               pixels: [0.1, 0.2, 0.3, 0.4], sourceIsLinear: true)
        let report = RestackReport(master: image, stackedCount: 3, skippedMissing: 0,
                                   skippedMismatch: 0, unverifiedLegacy: false, coverage: nil)
        for invalid in [0.0, -1.0, Double.infinity, Double.nan] {
            var metadata = SourceMetadata()
            metadata.exposureSeconds = invalid
            let header = try FITSReader.readHeader(RestackPlanning.encodeMaster(report,
                neutralize: false, metadata: metadata, subExposureSeconds: 20))
            XCTAssertNil(header.keywords["EXPTIME"], "invalid exposure: \(invalid)")
            XCTAssertEqual(Double(header.keywords["TOTALEXP"] ?? ""), 60)
        }
    }

    /// Re-stack writes master.fit "at parity" with the live master — so it must make the
    /// same choice, or a re-stack would silently reintroduce the contradiction.
    func testRestackEncodeMasterPrefersHeaderExposureForParity() throws {
        let px = [Float](repeating: 0.5, count: 16)
        let master = AstroImage(width: 4, height: 4, channels: 1, pixels: px, sourceIsLinear: true)
        let report = RestackReport(master: master, stackedCount: 5, skippedMissing: 0,
                                   skippedMismatch: 0, unverifiedLegacy: false, coverage: nil)
        var meta = SourceMetadata()
        meta.exposureSeconds = 300
        let data = RestackPlanning.encodeMaster(report, neutralize: false,
                                                metadata: meta, subExposureSeconds: 180)
        let header = try FITSReader.readHeader(data)
        XCTAssertEqual(header.keywords["EXPTIME"], "300")
        XCTAssertEqual(header.keywords["TOTALEXP"], "1500", "5 x 300, not 5 x 180")
    }
}
