import XCTest
@testable import LiveAstroCore
@testable import LiveAstroStudio

final class RestackExposurePersistenceTests: XCTestCase {
    func testMissingManifestRefusesReplacement() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = Data([1, 2, 3])
        try old.write(to: dir.appendingPathComponent("master.fit"))
        let image = AstroImage(width: 2, height: 2, channels: 1, pixels: [0.1, 0.2, 0.3, 0.4], sourceIsLinear: true)
        let report = RestackReport(master: image, stackedCount: 2, skippedMissing: 0,
                                   skippedMismatch: 0, unverifiedLegacy: false, coverage: nil)
        let result = AppModel.writeRestackedMaster(report, to: dir, metadata: nil, neutralize: false, subExposureSeconds: 30)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("master.fit")), old)
    }

    func testSummaryFailureIsReportedAfterDurableAccountingSucceeds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = SessionManager(rootDirectory: root)
        let dir = try session.startSession(profile: SessionProfile(targetName: "Mixed", subExposureSeconds: 30))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("session-summary.md"), withIntermediateDirectories: false)
        let image = AstroImage(width: 2, height: 2, channels: 1, pixels: [0.1, 0.2, 0.3, 0.4], sourceIsLinear: true)
        let report = RestackReport(master: image, stackedCount: 2, skippedMissing: 0,
                                   skippedMismatch: 0, unverifiedLegacy: false, coverage: nil)
        let result = AppModel.writeRestackedMaster(report, to: dir, metadata: nil, neutralize: false, subExposureSeconds: 30)
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.logMessage?.contains("session-summary.md") == true)
        let manifest = try ManifestCoding.decoder().decode(SessionManifest.self,
            from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.exposure?.totalSeconds, 60)
    }

    @MainActor func testSuccessfulRestackStillReportsSummaryWarning() throws {
        let suite = "RestackExposurePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(userDefaults: defaults)
        let image = AstroImage(width: 2, height: 2, channels: 1, pixels: [0.1, 0.2, 0.3, 0.4], sourceIsLinear: true)
        let report = RestackReport(master: image, stackedCount: 2, skippedMissing: 0,
                                   skippedMismatch: 0, unverifiedLegacy: false, coverage: nil)
        model.finishRestack(report, excludedCount: 0,
            writeResult: .init(ok: true, logMessage: "summary refresh failed"), sessionDir: nil,
            neutralize: false, subExposureSeconds: 30)
        XCTAssertTrue(model.log.contains("summary refresh failed"))
    }

    @MainActor func testRealDeliveryHandlerKeepsMixedCleanAndOnlineCaptionsDistinct() async throws {
        let suite = "RestackExposurePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(userDefaults: defaults)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pipeline = SessionPipeline(watchFolder: root, profile: SessionProfile(targetName: "Mixed", subExposureSeconds: 180), rootDirectory: root)
        model.wireCallbacks(to: pipeline)
        var clean = ExposureSummary()
        for seconds in [30.0, 300] {
            var metadata = SourceMetadata(); metadata.exposureSeconds = seconds
            clean.add(FrameExposure(metadata: metadata, fallback: 180))
        }
        var online = clean
        online.add(FrameExposure(metadata: nil, fallback: 20))
        let image = try XCTUnwrap(AutoStretch.makeCGImage(AstroImage(width: 2, height: 2, channels: 1,
            pixels: [0.1, 0.2, 0.3, 0.4], sourceIsLinear: false)))
        pipeline.onDisplayUpdate?(DisplayDelivery(revision: 0, previewImage: image, broadcastImage: image,
            cleanMasterSubCount: 2, integrationSeconds: 330, previewIntegrationSeconds: 350, subExposureSeconds: 180,
            record: nil, exposure: clean, previewExposure: online))
        for _ in 0..<100 {
            if model.broadcastImage != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(model.broadcastImage, "prerequisite: real main-actor delivery ran")
        XCTAssertEqual(model.broadcastIntegrationCaption, "5m 30s · 2 subs")
        XCTAssertEqual(model.integrationCaption, "5m 50s · 3 subs (1 estimated)")
    }

    func testRestackUpdatesMasterManifestAndSummaryButPreservesSnapshotHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = SessionManager(rootDirectory: root)
        let dir = try session.startSession(profile: SessionProfile(targetName: "Mixed", subExposureSeconds: 30), masterExpected: true)
        var original = ExposureSummary()
        for seconds in [30.0, 300, 300] {
            var meta = SourceMetadata(); meta.exposureSeconds = seconds
            original.add(FrameExposure(metadata: meta, fallback: 0))
        }
        try session.recordSnapshot(SnapshotRecord(index: 3, timestamp: Date(), sourceFile: "3.fit", snapshotFile: "snapshots/0003.png",
            estimatedIntegrationSeconds: 630, width: 2, height: 2, mean: 0, median: 0, stddev: 0, exposure: original))
        try session.endSession(finalization: SessionFinalizationFacts(masterOutcome: .written, stackFrameCount: 3,
            sessionAcceptedCount: 3, sessionRejectedCount: 0, exposure: original))
        let image = AstroImage(width: 2, height: 2, channels: 1, pixels: [0.1, 0.2, 0.3, 0.4], sourceIsLinear: true)
        try FITSWriter.float32(width: 2, height: 2, channels: 1, pixels: image.pixels)
            .write(to: dir.appendingPathComponent("master.fit"))
        var exposure = ExposureSummary()
        var metadata = SourceMetadata(); metadata.exposureSeconds = 300
        exposure.add(FrameExposure(metadata: metadata, fallback: 0))
        exposure.add(FrameExposure(metadata: metadata, fallback: 0))
        let report = RestackReport(exposure: exposure, master: image, stackedCount: 2, skippedMissing: 0,
                                   skippedMismatch: 0, unverifiedLegacy: false, coverage: nil)
        let result = AppModel.writeRestackedMaster(report, to: dir, metadata: metadata, neutralize: false, subExposureSeconds: 30)
        XCTAssertTrue(result.ok, result.logMessage ?? "")
        let manifest = try ManifestCoding.decoder().decode(SessionManifest.self,
            from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.exposure?.totalSeconds, 600)
        XCTAssertEqual(manifest.stackFrameCount, 2)
        XCTAssertEqual(manifest.snapshots[0].exposure?.totalSeconds, 630)
        let summary = try String(contentsOf: dir.appendingPathComponent("session-summary.md"), encoding: .utf8)
        XCTAssertTrue(summary.contains("10m · 2 × 300s"))
        let header = try FITSReader.readHeader(Data(contentsOf: dir.appendingPathComponent("master.fit")))
        XCTAssertEqual(Double(header.keywords["TOTALEXP"] ?? ""), 600)
    }
}
