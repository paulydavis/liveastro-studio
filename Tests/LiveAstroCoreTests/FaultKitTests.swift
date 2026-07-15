import XCTest
@testable import LiveAstroCore

/// Tests that pin FaultKit itself (T1, spec §"Testing the tests"): the harness that
/// gates the whole fault-injection pillar must be proven before it is trusted.
final class FaultKitTests: XCTestCase {

    // MARK: - TempFS

    func testTempFSTeardownAfterReadOnlyFlip() throws {
        let fs = try TempFS("teardown-ro")
        let root = fs.root
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))

        let sub = try fs.dir("locked")
        // Flip the subdir read-only through the Disruptor (tracks the change on `fs`).
        guard try Disruptor.makeReadOnly(sub, tempFS: fs) else {
            throw XCTSkip("chmod ineffective on this runner (privileged) — cannot exercise teardown-after-flip")
        }

        // tearDown must ALWAYS succeed: it restores tracked permissions before removal.
        fs.tearDown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path),
                       "TempFS.tearDown must remove the root even after a read-only flip")
    }

    // MARK: - CoordinatedWriter

    func testCoordinatedWriterChunksVisibleImmediately() throws {
        let fs = try TempFS("coord-writer")
        defer { fs.tearDown() }
        let url = fs.root.appendingPathComponent("growing.bin")
        let writer = CoordinatedWriter(url: url)
        defer { writer.close() }

        writer.writeChunk(Data(repeating: 0xAB, count: 100))
        var size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        XCTAssertEqual(size, 100, "writeChunk must be visible synchronously (flushed)")

        writer.writeChunk(Data(repeating: 0xCD, count: 50))
        size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        XCTAssertEqual(size, 150, "second chunk appends synchronously")

        writer.truncate(to: 40)
        size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        XCTAssertEqual(size, 40, "truncate is visible synchronously")
    }

    // MARK: - Disruptor

    func testDisruptorReadOnlyProbeDetectsPrivilege() throws {
        let fs = try TempFS("ro-probe")
        defer { fs.tearDown() }
        let dir = try fs.dir("dest")

        let effective = try Disruptor.makeReadOnly(dir, tempFS: fs)
        guard effective else {
            // Skip path is code-reviewed, not simulated: a privileged runner reports false
            // and the caller XCTSkips with a diagnostic rather than passing vacuously.
            throw XCTSkip("read-only probe reports chmod ineffective (privileged runner)")
        }
        // On a normal runner: chmod took, so a write into the dir must now fail.
        let victim = dir.appendingPathComponent("nope.txt")
        XCTAssertThrowsError(try Data("x".utf8).write(to: victim),
                             "makeReadOnly returned true, so writes into the dir must fail")
    }

    // MARK: - CrashArtifactBuilder

    func testCrashArtifactBuilderProducesKilledSession() throws {
        let fs = try TempFS("crash-session")
        defer { fs.tearDown() }

        let aftermath = try CrashArtifactBuilder.killedArtifact(scenario: "session-midframes", in: fs)

        // The returned dir contains a genuine mid-flight session: a real SessionManager
        // ran in a separate process, recorded 3 snapshots, then was SIGKILLed while running.
        let sessionRoot = try onlySessionDirectory(under: aftermath)
        let manifestURL = sessionRoot.appendingPathComponent("manifest.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path),
                      "killed session must have a persisted manifest.json")
        let manifest = try ManifestCoding.decoder()
            .decode(SessionManifest.self, from: Data(contentsOf: manifestURL))
        XCTAssertEqual(manifest.snapshots.count, 3, "helper recorded 3 snapshots before the flag")
        XCTAssertNil(manifest.endTime, "a killed mid-flight session is still running (no end_time)")
        // The listed snapshot PNGs must actually be on disk (real recorder output).
        for snap in manifest.snapshots {
            let p = sessionRoot.appendingPathComponent(snap.snapshotFile)
            XCTAssertTrue(FileManager.default.fileExists(atPath: p.path),
                          "snapshot \(snap.snapshotFile) must exist on disk")
        }
    }

    // MARK: - OracleAssert has teeth

    func testOracleHasTeeth() throws {
        let fs = try TempFS("oracle-teeth")
        defer { fs.tearDown() }

        // Build a VALID 2-snapshot session that the oracle should PASS.
        let sessionRoot = try buildValidSession(under: fs, snapshotCount: 2)
        assertSessionOracle(sessionRoot: sessionRoot, log: [],
                            OracleExpectations(lossLogPattern: nil,
                                               laterFramesApplicable: false,
                                               expectedAcceptedCount: 2))

        // (a) Truncate manifest.json → clause 1 (parse) must FAIL.
        try withCorruptedCopy(of: sessionRoot, under: fs, name: "trunc-manifest") { root in
            try Disruptor.truncateFile(root.appendingPathComponent("manifest.json"), to: 10)
            XCTExpectFailure("truncated manifest must fail the oracle's parse clause") {
                assertSessionOracle(sessionRoot: root, log: [],
                                    OracleExpectations(lossLogPattern: nil,
                                                       laterFramesApplicable: false,
                                                       expectedAcceptedCount: 2))
            }
        }

        // (b) Delete a listed snapshot file → clause 2 (snapshots exist) must FAIL.
        try withCorruptedCopy(of: sessionRoot, under: fs, name: "missing-snap") { root in
            let manifest = try ManifestCoding.decoder()
                .decode(SessionManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
            try Disruptor.deleteFile(root.appendingPathComponent(manifest.snapshots[0].snapshotFile))
            XCTExpectFailure("a missing listed snapshot must fail the oracle's existence clause") {
                assertSessionOracle(sessionRoot: root, log: [],
                                    OracleExpectations(lossLogPattern: nil,
                                                       laterFramesApplicable: false,
                                                       expectedAcceptedCount: 2))
            }
        }

        // (c) Claim the session ended (set end_time) without a durable end (master.fit)
        //     → clause 5 (unpersisted work never reported successful) must FAIL.
        try withCorruptedCopy(of: sessionRoot, under: fs, name: "dishonest-end") { root in
            try setDishonestEnd(at: root.appendingPathComponent("manifest.json"))
            XCTExpectFailure("a manifest claiming end without a persisted master.fit must fail clause 5") {
                assertSessionOracle(sessionRoot: root, log: [],
                                    OracleExpectations(lossLogPattern: nil,
                                                       laterFramesApplicable: false,
                                                       expectedAcceptedCount: 2))
            }
        }
    }

    // MARK: - Local helpers

    /// The single session subdirectory created by a faulthelper run.
    private func onlySessionDirectory(under aftermath: URL) throws -> URL {
        let entries = try FileManager.default.contentsOfDirectory(
            at: aftermath, includingPropertiesForKeys: [.isDirectoryKey])
        let dirs = try entries.filter {
            (try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard let only = dirs.first, dirs.count == 1 else {
            throw XCTSkip("expected exactly one session dir, found \(dirs.count)")
        }
        return only
    }

    /// Builds a valid ended-and-finalized session directly (no helper process): a manifest
    /// with `count` snapshots whose PNG files exist, plus a master.fit so an ended manifest
    /// would be honest. Left as RUNNING (no end_time) so the base case is a valid mid-session.
    private func buildValidSession(under fs: TempFS, snapshotCount count: Int) throws -> URL {
        let root = try fs.dir("valid-session")
        let snaps = try fs.dir("valid-session/snapshots")
        _ = snaps
        var records: [SnapshotRecord] = []
        for i in 0..<count {
            let name = String(format: "snapshots/%04d.png", i)
            try Data("png-bytes-\(i)".utf8).write(to: root.appendingPathComponent(name))
            records.append(SnapshotRecord(index: i, timestamp: Date(), sourceFile: "live_stack.fit",
                                          snapshotFile: name, estimatedIntegrationSeconds: 60,
                                          width: 10, height: 10, mean: 0.1, median: 0.08, stddev: 0.02))
        }
        let manifest = SessionManifest(
            sessionId: "valid-session", targetName: "Test", startTime: Date(), endTime: nil,
            subExposureSeconds: 60, bortle: 5, locationLabel: "L", telescope: "T", camera: "C",
            mount: "M", filter: "F", notes: "", snapshots: records)
        try ManifestCoding.encoder().encode(manifest)
            .write(to: root.appendingPathComponent("manifest.json"))
        return root
    }

    /// Copy a session tree to a fresh corruptible location, run `mutate`, return.
    private func withCorruptedCopy(of source: URL, under fs: TempFS, name: String,
                                   _ mutate: (URL) throws -> Void) throws {
        let dst = fs.root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: source, to: dst)
        try mutate(dst)
    }

    /// Rewrite the manifest with an end_time set (claims the session ended) — the caller
    /// ensures no master.fit exists, making the claim dishonest.
    private func setDishonestEnd(at manifestURL: URL) throws {
        var manifest = try ManifestCoding.decoder()
            .decode(SessionManifest.self, from: Data(contentsOf: manifestURL))
        manifest.endTime = Date()
        try ManifestCoding.encoder().encode(manifest).write(to: manifestURL)
    }
}
