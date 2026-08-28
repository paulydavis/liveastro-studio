import XCTest
@testable import LiveAstroCore

/// Task 7: RestackCoordinator is the pure core of "rebuild the master from raw subs
/// minus a flagged set." The golden test (testRestackEqualsFreshStackOfSurvivors) pins
/// byte-identity against a fresh stack of the same survivors driven the identical way
/// (same loader, same process()-every-frame order) — see class doc in
/// RestackCoordinator.swift for why that equivalence is the whole point of the design.
final class RestackCoordinatorTests: XCTestCase {
    /// Mono starfield FITS subs written to disk (mirrors NativePipelineTests.writeSub),
    /// so the loader path under test (FolderFrameSource.loadRawFrame) is exercised for
    /// real, not bypassed with in-memory RawFrames.
    private let baseField: [(Double, Double)] = {
        var field: [(Double, Double)] = []
        for i in 0..<20 {
            field.append((Double((i * 47) % 240 + 8), Double((i * 83) % 240 + 8)))
        }
        return field
    }()

    private func writeSub(_ dir: URL, name: String, dx: Double, dy: Double) throws -> URL {
        let stars = baseField.map { ($0.0 + dx, $0.1 + dy) }
        var px = [Float](repeating: 0.05, count: 256 * 256)
        for s in stars {
            for y in max(0, Int(s.1) - 6)...min(255, Int(s.1) + 6) {
                for x in max(0, Int(s.0) - 6)...min(255, Int(s.0) + 6) {
                    let dx2 = Double(x) - s.0, dy2 = Double(y) - s.1
                    px[y * 256 + x] += 0.8 * Float(exp(-(dx2 * dx2 + dy2 * dy2) / (2 * 2.0 * 2.0)))
                }
            }
        }
        let url = dir.appendingPathComponent(name)
        try FITSWriter.float32(width: 256, height: 256, channels: 1, pixels: px).write(to: url)
        return url
    }

    /// Writes N synthetic FITS subs (small, distinct per-frame translations so
    /// registration against whichever frame becomes the reference is well-conditioned)
    /// to a fresh temp dir; returns their URLs in write order.
    private func writeSubs(_ n: Int) throws -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try (0..<n).map { i in
            try writeSub(dir, name: "sub_\(i).fit", dx: Double(i) * 1.3, dy: -Double(i) * 0.7)
        }
    }

    private func makeEngine() -> StackEngine { StackEngine() }

    /// Build the survivor `RestackSub`s the coordinator now takes: drop `excluding` basenames
    /// and map each remaining URL to a RestackSub with the given identity (nil = legacy/unverified,
    /// the same load path these tests used before identity threading).
    private func subs(_ urls: [URL], excluding: Set<String> = [],
                      identity: (URL) -> FileIdentity? = { _ in nil }) -> [RestackSub] {
        urls.filter { !excluding.contains($0.lastPathComponent) }
            .map { RestackSub(url: $0, expectedIdentity: identity($0)) }
    }

    /// Reference "fresh stack": load each URL through the SAME loader RestackCoordinator
    /// uses (FolderFrameSource.loadRawFrame) and process() each in order through a fresh
    /// engine — the exact sequence restack() performs. Any divergence here (loader,
    /// order, seeding mechanism) would make the byte-identity assertion meaningless.
    private func stackDirectly(_ urls: [URL]) throws -> AstroImage {
        let engine = makeEngine()
        for url in urls {
            let frame = try FolderFrameSource.loadRawFrame(url: url)
            _ = engine.process(frame)
        }
        return try XCTUnwrap(engine.currentStack())
    }

    func testRestackEqualsFreshStackOfSurvivors() throws {
        let urls = try writeSubs(5)
        let excluded: Set<String> = [urls[2].lastPathComponent]
        // Nil identities → unverified load, the SAME load path as before identity threading, so
        // the golden byte-identity property must still hold exactly.
        let report = try RestackCoordinator.restack(subs: subs(urls, excluding: excluded),
                                                    makeEngine: makeEngine)

        let survivors = urls.enumerated().filter { $0.offset != 2 }.map(\.element)
        let reference = try stackDirectly(survivors)

        XCTAssertEqual(report.master.pixels, reference.pixels)   // byte-identical, exact ==
        XCTAssertEqual(report.stackedCount, 4)
        XCTAssertEqual(report.skippedMissing, 0)
        XCTAssertEqual(report.skippedMismatch, 0)
        XCTAssertTrue(report.unverifiedLegacy)   // all nil-identity survivors → loaded unverified
    }

    func testFlagIsOrderIndependent() throws {
        let urls = try writeSubs(4)
        let a = try RestackCoordinator.restack(
            subs: subs(urls, excluding: [urls[1].lastPathComponent, urls[3].lastPathComponent]),
            makeEngine: makeEngine)
        let b = try RestackCoordinator.restack(
            subs: subs(urls, excluding: [urls[3].lastPathComponent, urls[1].lastPathComponent]),
            makeEngine: makeEngine)
        XCTAssertEqual(a.master.pixels, b.master.pixels)
    }

    func testAllExcludedThrowsNoSurviving() throws {
        let urls = try writeSubs(3)
        let all = Set(urls.map(\.lastPathComponent))
        XCTAssertThrowsError(try RestackCoordinator.restack(subs: subs(urls, excluding: all),
                                                             makeEngine: makeEngine)) {
            // All-excluded means no subs were even attempted, so the skip accounting is 0/0.
            XCTAssertEqual($0 as? RestackError, .noSurvivingSubs(skippedMissing: 0, skippedMismatch: 0))
        }
    }

    /// `.noSurvivingSubs` carries the skip accounting so the caller can report WHY nothing
    /// survived — here every recorded sub is missing on disk (review finding P2).
    func testAllMissingThrowsNoSurvivingWithMissingCount() throws {
        let urls = [
            URL(fileURLWithPath: "/nonexistent/ghost1.fit"),
            URL(fileURLWithPath: "/nonexistent/ghost2.fit"),
        ]
        XCTAssertThrowsError(try RestackCoordinator.restack(subs: subs(urls), makeEngine: makeEngine)) {
            XCTAssertEqual($0 as? RestackError, .noSurvivingSubs(skippedMissing: 2, skippedMismatch: 0))
        }
    }

    /// The `prepare` closure (production: the session's calibrator, Fix 1) must run on EVERY
    /// surviving loaded frame BEFORE it reaches the engine, and the prepared frame — not the
    /// raw one — is what gets stacked. Proves the AppModel wiring's contract: a calibrator
    /// passed as `prepare` actually calibrates the re-stacked master.
    func testPrepareAppliedToEverySurvivingFrame() throws {
        let urls = try writeSubs(4)
        let excluded: Set<String> = [urls[1].lastPathComponent]

        var prepareCount = 0
        let report = try RestackCoordinator.restack(
            subs: subs(urls, excluding: excluded), makeEngine: makeEngine,
            prepare: { frame in prepareCount += 1; return frame })
        XCTAssertEqual(prepareCount, 3, "prepare runs once per surviving loadable frame (4 written − 1 excluded)")
        XCTAssertEqual(report.stackedCount, 3)

        // A non-identity prepare must change the master vs. identity — i.e. the PREPARED
        // pixels are what the engine stacks, not the raw ones.
        let identity = try RestackCoordinator.restack(
            subs: subs(urls, excluding: excluded), makeEngine: makeEngine)
        let scaled = try RestackCoordinator.restack(
            subs: subs(urls, excluding: excluded), makeEngine: makeEngine,
            prepare: { frame in
                let img = AstroImage(width: frame.image.width, height: frame.image.height,
                                     channels: frame.image.channels,
                                     pixels: frame.image.pixels.map { $0 * 0.5 },
                                     sourceIsLinear: frame.image.sourceIsLinear)
                return RawFrame(image: img, bayerPattern: frame.bayerPattern, bottomUp: frame.bottomUp,
                                timestamp: frame.timestamp, sourceName: frame.sourceName,
                                metadata: frame.metadata)
            })
        XCTAssertNotEqual(identity.master.pixels, scaled.master.pixels)
    }

    func testMissingRawCountedAsSkipped() throws {
        var urls = try writeSubs(3)
        urls.append(URL(fileURLWithPath: "/nonexistent/ghost.fit"))
        let report = try RestackCoordinator.restack(subs: subs(urls), makeEngine: makeEngine)
        XCTAssertEqual(report.skippedMissing, 1)
        XCTAssertEqual(report.stackedCount, 3)
    }

    // MARK: identity revalidation (review finding P2-identity — now CONTENT-DIGEST, not stat)

    /// The digest identity a re-stack would have recorded for `url` at capture: the SHA-256 over
    /// the decoded bytes (stat fields zero). Load the frame and take its recorded identity.
    private func recordedIdentity(_ url: URL) throws -> FileIdentity {
        try XCTUnwrap(FolderFrameSource.loadRawFrame(url: url).identity)
    }

    /// A recorded sub whose on-disk BYTES no longer match its recorded content digest (same
    /// basename, different bytes — overwritten since capture) is SKIPPED as a mismatch, counted in
    /// `skippedMismatch`, and never enters the stack. The other (nil-digest) subs still stack.
    func testChangedSubIsSkippedAsMismatch() throws {
        let urls = try writeSubs(3)
        // Record the middle sub's real content digest, THEN overwrite the file with different
        // bytes → the digest-only loader throws FileIdentityMismatchError → the coordinator skips.
        let recorded = try recordedIdentity(urls[1])
        _ = try writeSub(urls[1].deletingLastPathComponent(),
                         name: urls[1].lastPathComponent, dx: 3, dy: -3)   // overwrite, new content (in bounds)
        let restackSubs = [
            RestackSub(url: urls[0], expectedIdentity: nil),
            RestackSub(url: urls[1], expectedIdentity: recorded),
            RestackSub(url: urls[2], expectedIdentity: nil),
        ]
        let report = try RestackCoordinator.restack(subs: restackSubs, makeEngine: makeEngine)
        XCTAssertEqual(report.skippedMismatch, 1)
        XCTAssertEqual(report.skippedMissing, 0)
        XCTAssertEqual(report.stackedCount, 2, "only the two matching/unverified subs stacked")
        XCTAssertTrue(report.unverifiedLegacy, "the two nil-digest survivors loaded unverified")
    }

    /// KEY REGRESSION (the whole point of the stat→digest fix): a sub whose file was replaced by
    /// a BYTE-IDENTICAL copy with a DIFFERENT inode/mtime (exactly what Google Drive mirror mode
    /// and the SMB relay do on a re-sync) must STILL load — the digest matches, stat is ignored.
    /// A stat-based check would wrongly skip it. Assert it stacks and `skippedMismatch == 0`.
    func testSameBytesNewInodeIsNotSkipped() throws {
        let urls = try writeSubs(3)
        let recorded = try urls.map { try recordedIdentity($0) }   // digests over the original bytes
        let statBefore = try XCTUnwrap(FileIdentity.capture(url: urls[1]))
        // Reproduce a mirror re-sync of the middle sub: read the exact bytes, delete the file
        // (frees the inode), then rewrite the SAME bytes → new inode/mtime, identical content.
        let bytes = try Data(contentsOf: urls[1])
        try FileManager.default.removeItem(at: urls[1])
        try bytes.write(to: urls[1])
        let statAfter = try XCTUnwrap(FileIdentity.capture(url: urls[1]))
        XCTAssertNotEqual(statBefore.ino, statAfter.ino, "delete+rewrite must produce a NEW inode")

        // The recorded digest is over the pre-replace bytes; the bytes are identical so the digest
        // still matches even though inode/mtime changed — a stat check would have wrongly skipped.
        let restackSubs = zip(urls, recorded).map { RestackSub(url: $0, expectedIdentity: $1) }
        let report = try RestackCoordinator.restack(subs: restackSubs, makeEngine: makeEngine)
        XCTAssertEqual(report.skippedMismatch, 0, "byte-identical re-sync (new inode/mtime) must NOT skip")
        XCTAssertEqual(report.skippedMissing, 0)
        XCTAssertEqual(report.stackedCount, 3, "all three subs — including the re-synced one — stacked")
        XCTAssertFalse(report.unverifiedLegacy, "every survivor carried a content digest")
    }

    /// A sub whose recorded content digest MATCHES the file on disk loads through the VERIFIED
    /// (digest) path, and `unverifiedLegacy` stays false when every survivor carries a digest.
    func testMatchingDigestLoadsVerified() throws {
        let urls = try writeSubs(3)
        let restackSubs = try urls.map { RestackSub(url: $0, expectedIdentity: try recordedIdentity($0)) }
        let report = try RestackCoordinator.restack(subs: restackSubs, makeEngine: makeEngine)
        XCTAssertEqual(report.skippedMismatch, 0)
        XCTAssertEqual(report.skippedMissing, 0)
        XCTAssertEqual(report.stackedCount, 3)
        XCTAssertFalse(report.unverifiedLegacy)
    }

    /// A survivor carrying NO digest (legacy record, or a stat-only identity with digest nil) is
    /// loaded UNVERIFIED and `unverifiedLegacy` is set — not skipped.
    func testNilDigestLoadsUnverified() throws {
        let urls = try writeSubs(3)
        // One nil identity, one stat-shaped identity whose digest is nil — both are "unverified".
        let statOnly = FileIdentity(dev: 1, ino: 2, size: 3, mtimeSec: 4, mtimeNsec: 5)  // digest nil
        let restackSubs = [
            RestackSub(url: urls[0], expectedIdentity: nil),
            RestackSub(url: urls[1], expectedIdentity: statOnly),
            RestackSub(url: urls[2], expectedIdentity: try recordedIdentity(urls[2])),
        ]
        let report = try RestackCoordinator.restack(subs: restackSubs, makeEngine: makeEngine)
        XCTAssertEqual(report.skippedMismatch, 0)
        XCTAssertEqual(report.skippedMissing, 0)
        XCTAssertEqual(report.stackedCount, 3, "nil-digest survivors load unverified, not skipped")
        XCTAssertTrue(report.unverifiedLegacy)
    }

    /// Review finding: `unverifiedLegacy` must reflect subs actually LOADED without content
    /// verification, not merely RECORDED without a digest. A legacy (nil-digest) sub that is
    /// MISSING on disk never loads, so it must NOT set the flag; a legacy sub that IS present
    /// loads unverified and DOES set it.
    func testLegacyFlagOnlySetAfterASuccessfulUnverifiedLoad() throws {
        let urls = try writeSubs(1)
        let restackSubs = [
            RestackSub(url: urls[0], expectedIdentity: nil),
            RestackSub(url: URL(fileURLWithPath: "/nonexistent/legacy-ghost.fit"), expectedIdentity: nil),
        ]
        let report = try RestackCoordinator.restack(subs: restackSubs, makeEngine: makeEngine)
        XCTAssertEqual(report.skippedMissing, 1)
        XCTAssertEqual(report.stackedCount, 1)
        XCTAssertTrue(report.unverifiedLegacy, "the one legacy sub that DID load set the flag")
    }

    /// Companion to the above: when the ONLY legacy sub is missing (never loads), the flag stays
    /// false — a missing/mismatched legacy record must not be reported as "loaded unverified".
    func testMissingLegacySubDoesNotSetUnverifiedFlag() throws {
        let urls = try writeSubs(1)
        let restackSubs = [
            RestackSub(url: urls[0], expectedIdentity: try recordedIdentity(urls[0])),   // verified, loads
            RestackSub(url: URL(fileURLWithPath: "/nonexistent/legacy-ghost.fit"), expectedIdentity: nil),   // legacy, missing
        ]
        let report = try RestackCoordinator.restack(subs: restackSubs, makeEngine: makeEngine)
        XCTAssertEqual(report.skippedMissing, 1)
        XCTAssertEqual(report.stackedCount, 1)
        XCTAssertFalse(report.unverifiedLegacy, "the missing legacy sub never loaded, so it must not set the flag")
    }
}
