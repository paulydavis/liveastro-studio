import XCTest
@testable import LiveAstroCore

final class CleanStackRealDataTests: XCTestCase {
    /// Separate from the default gate: six original Seestar subs, real decoder/digest loader,
    /// live registration and refiner. Deliberately expires ordinary End, then completes fully.
    func testRealSeestarFinishAfterExpiredEndBudget() throws {
        guard let input = ProcessInfo.processInfo.environment["LAS_CLEAN_COMPLETION_FIXTURE_DIR"] else {
            throw XCTSkip("Set LAS_CLEAN_COMPLETION_FIXTURE_DIR to the Seestar FITS folder")
        }
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: URL(fileURLWithPath: input), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "fit" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count >= 6 else { return XCTFail("prerequisite: six FITS inputs required") }
        let selected = Array(files.prefix(6))
        let hashes = try selected.map { FileIdentity.contentDigest(data: try Data(contentsOf: $0)) }
        let root = fm.temporaryDirectory.appendingPathComponent("clean-completion-real-\(UUID().uuidString)")
        // Preserve explicit real-data evidence, not the user's originals.
        let source = StubLiveSource(sequence: [])
        let engine = StackEngine()
        let pipeline = SessionPipeline(nativeSource: source, engine: engine,
            profile: SessionProfile(targetName: "Clean completion real-data test", subExposureSeconds: 30), rootDirectory: root)
        defer { source.stop() }
        pipeline.rendersReplay = false
        pipeline.configureLiveRejection(enabled: true)
        try pipeline.start()
        for file in selected.prefix(5) { source.send(try FolderFrameSource.loadRawFrame(url: file)) }
        let publishedDeadline = Date().addingTimeInterval(120)
        while pipeline.publishedMasterSurvivorCount() != 5 && Date() < publishedDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(pipeline.publishedMasterSurvivorCount(), 5, "prerequisite: real five-sub clean master published")
        guard pipeline.publishedMasterSurvivorCount() == 5 else { return }
        let refiner = try XCTUnwrap(pipeline.refinerForTest())
        refiner.quiesce(); refiner.cancel()
        source.send(try FolderFrameSource.loadRawFrame(url: selected[5]))
        let registrationDeadline = Date().addingTimeInterval(60)
        while pipeline.subRegistrations().count != 6 && Date() < registrationDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(pipeline.subRegistrations().count, 6, "prerequisite: sixth sub registered")
        pipeline.finalRefineBudget = .nanoseconds(0)
        let dir = try pipeline.end()
        XCTAssertEqual(pipeline.session.manifest?.cleanStackStatus?.savedCount, 5)
        XCTAssertEqual(pipeline.session.manifest?.cleanStackStatus?.reason, .timedOut)
        let request = try XCTUnwrap(pipeline.cleanStackCompletion)
        let result = try request.finish()
        XCTAssertEqual(result.report.stackedCount, 6)
        let header = try FITSReader.readHeader(Data(contentsOf: dir.appendingPathComponent("master.fit")))
        XCTAssertEqual(header.keywords["STACKCNT"].flatMap(Int.init), 6)
        XCTAssertEqual(header.keywords["TOTALEXP"].flatMap(Double.init), 180)
        XCTAssertEqual(try selected.map { FileIdentity.contentDigest(data: try Data(contentsOf: $0)) }, hashes)
        print("REAL CLEAN COMPLETION: 5 -> 6 frames, 180 seconds, six originals unchanged; artifacts \(dir.path)")
    }
}
