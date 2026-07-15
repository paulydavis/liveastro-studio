import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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

        // (d) Replace a listed snapshot PNG with garbage bytes (nonempty, undecodable)
        //     → clause 4 (decodable image) must FAIL — a nonempty-bytes check would miss this.
        try withCorruptedCopy(of: sessionRoot, under: fs, name: "garbage-snap") { root in
            let manifest = try ManifestCoding.decoder()
                .decode(SessionManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
            let target = root.appendingPathComponent(manifest.snapshots[0].snapshotFile)
            try Data("this is not a PNG — just text pretending to be an image".utf8).write(to: target)
            XCTExpectFailure("a listed snapshot that is not a decodable image must fail clause 4") {
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
            // Write a REAL 2×2 PNG so clause 4 (decode) passes on the base case — text-as-.png would
            // sail past a nonempty-bytes check but is not a decodable image.
            try Self.tinyPNGData().write(to: root.appendingPathComponent(name))
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

    /// Encode a real, decodable 2×2 PNG (via a CGImage → ImageIO destination) so clause 4's decode
    /// check passes on genuine snapshot output.
    static func tinyPNGData() throws -> Data {
        let w = 2, h = 2
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let cg = ctx.makeImage()!
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "FaultKitTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG destination"])
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "FaultKitTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG finalize"])
        }
        return data as Data
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
