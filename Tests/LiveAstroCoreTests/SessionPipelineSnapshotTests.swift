import XCTest
@testable import LiveAstroCore

/// Task 3: SessionPipeline.writeMasterSnapshot — mid-session master.fit from the
/// CURRENT live stack. Native mode only, atomic via FileReplace, MUST NOT end the
/// session / stop the engine / stamp end_time.
final class SessionPipelineSnapshotTests: XCTestCase {

    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func profile(_ target: String = "Snapshot Field",
                         subExposureSeconds: Double = 30) -> SessionProfile {
        SessionProfile(targetName: target, telescope: "T", camera: "C",
                       mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                       subExposureSeconds: subExposureSeconds, notes: "")
    }

    private func wait(for expectation: XCTestExpectation, timeout: TimeInterval = 5) {
        wait(for: [expectation], timeout: timeout)
    }

    /// (1) Snapshot writes master.fit mid-session and the session keeps running.
    func testWriteMasterSnapshotProducesMasterMidSession() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        let source = NativePipelineTests.ControlledLiveSource()
        let engine = StackEngine()
        let pipeline = SessionPipeline(nativeSource: source, engine: engine,
                                       profile: profile(subExposureSeconds: 30),
                                       rootDirectory: sessions)
        let firstUpdate = expectation(description: "first accepted frame")
        let secondUpdate = expectation(description: "second accepted frame")
        let lock = NSLock()
        var accepted = 0
        pipeline.onUpdate = { _, _ in
            lock.withLock {
                accepted += 1
                if accepted == 1 { firstUpdate.fulfill() }
                else if accepted == 2 { secondUpdate.fulfill() }
            }
        }

        try pipeline.start()
        source.send(FaultMatrixLifecycleTests.starField(name: "snap_000.fit", dx: 0, dy: 0))
        wait(for: firstUpdate)

        XCTAssertTrue(pipeline.writeMasterSnapshot())
        let dir = try XCTUnwrap(pipeline.sessionDir)
        let master = dir.appendingPathComponent("master.fit")
        XCTAssertTrue(FileManager.default.fileExists(atPath: master.path))

        // Master round-trips and STACKCNT/TOTALEXP reflect the live stack (1 frame × 30 s).
        let header = try FITSReader.readHeader(Data(contentsOf: master))
        XCTAssertEqual(Int(header.keywords["STACKCNT"] ?? ""), 1)
        XCTAssertEqual(Double(header.keywords["TOTALEXP"] ?? ""), 30)

        // Session is STILL running: not ended, engine untouched, further frames commit.
        XCTAssertEqual(pipeline.session.state, .running)
        source.send(FaultMatrixLifecycleTests.starField(name: "snap_001.fit", dx: 1.1, dy: -0.9))
        wait(for: secondUpdate)
        XCTAssertEqual(engine.stackFrameCount, 2)

        // A second snapshot now reflects the advanced stack (idempotent, repeatable).
        XCTAssertTrue(pipeline.writeMasterSnapshot())
        let header2 = try FITSReader.readHeader(Data(contentsOf: master))
        XCTAssertEqual(Int(header2.keywords["STACKCNT"] ?? ""), 2)

        _ = try pipeline.end()
    }

    /// (1b) T3 review fix: the written STACKCNT is bound to the SAME single-locked read
    /// that produced the master pixels. After N commits the master's STACKCNT header == N
    /// (and TOTALEXP == N × subExposure) — image + count come from one atomic engine read,
    /// so a frame commit or reseed can't tear header vs. pixels.
    func testSnapshotStackcntMatchesFrameCountFromSameRead() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        let source = NativePipelineTests.ControlledLiveSource()
        let engine = StackEngine()
        let pipeline = SessionPipeline(nativeSource: source, engine: engine,
                                       profile: profile(subExposureSeconds: 30),
                                       rootDirectory: sessions)
        let lock = NSLock()
        var accepted = 0
        let n = 3
        var gates: [Int: XCTestExpectation] = [:]
        for i in 1...n { gates[i] = expectation(description: "accepted frame \(i)") }
        pipeline.onUpdate = { _, _ in
            lock.withLock { accepted += 1; gates[accepted]?.fulfill() }
        }

        try pipeline.start()
        let offsets: [(Double, Double)] = [(0, 0), (1.1, -0.9), (-0.8, 1.2)]
        for i in 1...n {
            let (dx, dy) = offsets[i - 1]
            source.send(FaultMatrixLifecycleTests.starField(name: "n_\(i).fit", dx: dx, dy: dy))
            wait(for: gates[i]!)
        }
        XCTAssertEqual(engine.stackFrameCount, n)

        XCTAssertTrue(pipeline.writeMasterSnapshot())
        let dir = try XCTUnwrap(pipeline.sessionDir)
        let header = try FITSReader.readHeader(
            Data(contentsOf: dir.appendingPathComponent("master.fit")))
        XCTAssertEqual(Int(header.keywords["STACKCNT"] ?? ""), n)
        XCTAssertEqual(Double(header.keywords["TOTALEXP"] ?? ""), Double(n) * 30)

        _ = try pipeline.end()
    }

    /// (2) No stack yet (zero commits) → false, and no master.fit is written.
    func testSnapshotReturnsFalseWithNoStack() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        let source = NativePipelineTests.ControlledLiveSource()
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: profile(), rootDirectory: sessions)
        try pipeline.start()

        XCTAssertFalse(pipeline.writeMasterSnapshot())
        let dir = try XCTUnwrap(pipeline.sessionDir)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("master.fit").path))

        _ = try pipeline.end()
    }

    /// (3) A failed snapshot write must NOT destroy the prior good master.
    func testPriorMasterSurvivesFailedSnapshot() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        let source = NativePipelineTests.ControlledLiveSource()
        let engine = StackEngine()
        let pipeline = SessionPipeline(nativeSource: source, engine: engine,
                                       profile: profile(), rootDirectory: sessions)
        let firstUpdate = expectation(description: "first accepted frame")
        let secondUpdate = expectation(description: "second accepted frame")
        let lock = NSLock()
        var accepted = 0
        pipeline.onUpdate = { _, _ in
            lock.withLock {
                accepted += 1
                if accepted == 1 { firstUpdate.fulfill() }
                else if accepted == 2 { secondUpdate.fulfill() }
            }
        }

        try pipeline.start()
        source.send(FaultMatrixLifecycleTests.starField(name: "good_000.fit", dx: 0, dy: 0))
        wait(for: firstUpdate)

        // Good master written first.
        XCTAssertTrue(pipeline.writeMasterSnapshot())
        let dir = try XCTUnwrap(pipeline.sessionDir)
        let master = dir.appendingPathComponent("master.fit")
        let goodBytes = try Data(contentsOf: master)

        // Advance the stack, then a snapshot whose atomic swap fails.
        source.send(FaultMatrixLifecycleTests.starField(name: "good_001.fit", dx: 1.1, dy: -0.9))
        wait(for: secondUpdate)
        pipeline.fileManager = ReplacementFailingFileManager()
        XCTAssertFalse(pipeline.writeMasterSnapshot())

        // Prior good master is byte-for-byte intact; no temp file left behind.
        XCTAssertEqual(try Data(contentsOf: master), goodBytes)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".master-snapshot-") }
        XCTAssertTrue(leftovers.isEmpty, "temp snapshot file must be cleaned up on failure")

        pipeline.fileManager = .default
        _ = try pipeline.end()
    }
}

/// Fails every swap primitive while leaving reads/writes/removes intact —
/// simulates "the final replacement failed" without touching earlier steps.
private final class ReplacementFailingFileManager: FileManager {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteUnknown)
    }
    override func replaceItem(at originalItemURL: URL, withItemAt newItemURL: URL,
                              backupItemName: String?,
                              options: FileManager.ItemReplacementOptions = [],
                              resultingItemURL resultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        throw CocoaError(.fileWriteUnknown)
    }
}
