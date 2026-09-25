import XCTest
@testable import LiveAstroCore

final class CleanStackCompletionTests: XCTestCase {
    private struct Loader: FrameLoader {
        var missing: String? = nil
        func loadRegisteredInput(url: URL, expectedContentDigest: String?) throws -> AstroImage {
            if url.lastPathComponent == missing { throw CocoaError(.fileReadNoSuchFile) }
            return AstroImage(width: 12, height: 12, channels: 1,
                pixels: [Float](repeating: 0.4, count: 144), sourceIsLinear: true)
        }
    }

    private func fixture(missing: String? = nil) throws -> (URL, CleanStackCompletion) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let session = SessionManager(rootDirectory: root)
        let dir = try session.startSession(profile: SessionProfile(targetName: "Clean retry", subExposureSeconds: 30), masterExpected: true)
        var expected = ExposureSummary(), saved = ExposureSummary()
        let regs = (0..<6).map { i -> SubRegistration in
            var metadata = SourceMetadata(); metadata.exposureSeconds = i == 0 ? 30 : 300
            let exposure = FrameExposure(metadata: metadata, fallback: 0)
            expected.add(exposure)
            if i < 5 { saved.add(exposure) }
            return SubRegistration(subIndex: i, contentDigest: nil,
                relayURL: dir.appendingPathComponent("\(i).fit"), stackGeneration: 0,
                referenceIdentity: nil, transform: .identity, effectiveScale: 1, weight: 1,
                leveling: nil, exposure: exposure)
        }
        let status = CleanStackStatus(expectedCount: 6, savedCount: 5, expectedExposure: expected,
            savedExposure: saved, savedClean: true, reason: .timedOut)
        try session.endSession(finalization: .init(masterOutcome: .written, stackFrameCount: 6,
            sessionAcceptedCount: 6, sessionRejectedCount: 0, exposure: saved, cleanStackStatus: status))
        try Data("previous good master".utf8).write(to: dir.appendingPathComponent("master.fit"))
        let request = try CleanStackCompletion(directory: dir, survivors: regs, generation: 0,
            kappa: 3, budget: 1_000_000, minSubs: 5, loader: Loader(missing: missing),
            metadata: nil, neutralize: false, fallbackSeconds: 30, status: status)
        return (dir, request)
    }

    func testFinishesAllSixWithRecordedExposuresAndPreservesOldMaster() throws {
        let (dir, request) = try fixture()
        let old = try Data(contentsOf: dir.appendingPathComponent("master.fit"))
        let result = try request.finish()
        XCTAssertEqual(result.report.stackedCount, 6)
        XCTAssertFalse(result.status.needsCompletion)
        let header = try FITSReader.readHeader(Data(contentsOf: dir.appendingPathComponent("master.fit")))
        XCTAssertEqual(header.keywords["STACKCNT"].flatMap(Int.init), 6)
        XCTAssertEqual(header.keywords["TOTALEXP"].flatMap(Double.init), 1530)
        let manifest = try ManifestCoding.decoder().decode(SessionManifest.self,
            from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.cleanStackStatus?.savedCount, 6)
        XCTAssertEqual(manifest.exposure?.totalSeconds, 1530)
        XCTAssertEqual(try Data(contentsOf: result.backupDirectory.appendingPathComponent("master.fit")), old)
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("session-summary.md")).contains("6 of 6"))
    }

    func testCancelAfterCalculationCannotReplaceAnyArtifact() throws {
        let (dir, request) = try fixture()
        let names = ["master.fit", "manifest.json", "session-summary.md"]
        let before = try names.map { try Data(contentsOf: dir.appendingPathComponent($0)) }
        var cancelled = false
        XCTAssertThrowsError(try request.finish(isCancelled: { cancelled }, progress: { stage in
            if stage.hasPrefix("Combining") { cancelled = true }
        })) { XCTAssertEqual($0 as? CleanStackFailure, .cancelled) }
        XCTAssertEqual(try names.map { try Data(contentsOf: dir.appendingPathComponent($0)) }, before)
    }

    func testMissingInputDoesNotReplaceWithAnotherPartialMaster() throws {
        let (dir, request) = try fixture(missing: "5.fit")
        let before = try Data(contentsOf: dir.appendingPathComponent("master.fit"))
        XCTAssertThrowsError(try request.finish()) { XCTAssertEqual($0 as? CleanStackFailure, .unreadableInputs) }
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("master.fit")), before)
    }

    func testCancelledBeforeWorkerStartsLeavesMasterAlone() throws {
        let (dir, request) = try fixture()
        let before = try Data(contentsOf: dir.appendingPathComponent("master.fit"))
        XCTAssertThrowsError(try request.finish(isCancelled: { true })) {
            XCTAssertEqual($0 as? CleanStackFailure, .cancelled)
        }
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("master.fit")), before)
    }

    func testManifestWriteFailureRollsBackMasterAndLeavesBackup() throws {
        let (dir, request) = try fixture()
        let names = ["master.fit", "manifest.json", "session-summary.md"]
        let before = try names.map { try Data(contentsOf: dir.appendingPathComponent($0)) }
        request.manifestWriter = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        XCTAssertThrowsError(try request.finish())
        XCTAssertEqual(try names.map { try Data(contentsOf: dir.appendingPathComponent($0)) }, before)
        let backups = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("clean-stack-backup-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first).appendingPathComponent("master.fit")), before[0])
    }

    func testChangedSavedSessionCannotBeOverwritten() throws {
        let (dir, request) = try fixture()
        let changed = Data("a different master".utf8)
        try changed.write(to: dir.appendingPathComponent("master.fit"))
        XCTAssertThrowsError(try request.finish())
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("master.fit")), changed)
    }

    func testOrdinaryRestackCannotKeepOldCleanMasterClaims() throws {
        let (dir, _) = try fixture()
        let original = try ManifestCoding.decoder().decode(SessionManifest.self,
            from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        let image = AstroImage(width: 2, height: 2, channels: 1, pixels: [0.1, 0.2, 0.3, 0.4], sourceIsLinear: true)
        let report = RestackReport(exposure: .estimated(count: 3, seconds: 30), master: image,
            stackedCount: 3, skippedMissing: 0, skippedMismatch: 0, unverifiedLegacy: false, coverage: nil)
        let updated = RestackPlanning.updatingMaster(in: original, report: report, fallbackExposureSeconds: 30)
        XCTAssertNil(updated.cleanStackStatus, "ordinary stacking has not performed the recorded clean refinement")
    }

    func testDeadlineAtCPUStageBoundaryIsReportedRatherThanSuccess() {
        for phase in ["Computing", "Combining"] {
            let deadline = DispatchTime.now() + .milliseconds(500)
            let refiner = GlobalRefiner(loader: Loader(), onLog: { _ in })
            let regs = (0..<6).map { SubRegistration(subIndex: $0, contentDigest: nil,
                relayURL: URL(fileURLWithPath: "/\($0).fit"), stackGeneration: 0,
                referenceIdentity: nil, transform: .identity, effectiveScale: 1, weight: 1, leveling: nil) }
            var reason: CleanStackFailure?
            var reachedStage = false
            let result = refiner.refine(survivors: regs, currentGeneration: 0, kappa: 3,
                minSubs: 5, maxSampleBytes: 1_000_000, deadline: deadline, isCancelled: { false },
                onFailure: { reason = $0 }, progress: { stage in
                    if stage.hasPrefix(phase) {
                        reachedStage = true
                        while DispatchTime.now() <= deadline { Thread.sleep(forTimeInterval: 0.001) }
                    }
                })
            XCTAssertNil(result, phase)
            XCTAssertEqual(reason, .timedOut, phase)
            XCTAssertTrue(reachedStage, "prerequisite: must reach the CPU stage before testing its deadline boundary")
        }
    }
}
