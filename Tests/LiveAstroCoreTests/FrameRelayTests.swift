import XCTest
@testable import LiveAstroCore

final class FrameRelayTests: XCTestCase {
    func tmp() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
    }
    func write(_ dir: URL, _ name: String, bytes: Int = 32) throws {
        try Data(count: bytes).write(to: dir.appendingPathComponent(name))
    }
    /// Prime the stability gate: the FIRST tick after a file appears only records its
    /// stat and defers (P1-1); the copy happens on the NEXT tick once the file is stable.
    /// Tests that assert the copy therefore prime once, then assert the copying tick.
    @discardableResult
    func primeThenCopy(_ r: FrameRelay) throws -> Int {
        _ = try r.copyOnce()          // first tick: record stats, defer
        return try r.copyOnce()       // second tick: stable → copy
    }

    func testWildcardMatch() {
        XCTAssertTrue(FrameRelay.wildcardMatch("Light_M 8_10.0s_LP_20260709-034653.fit", "Light_*_10.0s_*.fit"))
        XCTAssertFalse(FrameRelay.wildcardMatch("Light_M 8_20.0s_LP_20260707-000534.fit", "Light_*_10.0s_*.fit"))
        XCTAssertFalse(FrameRelay.wildcardMatch("Light_M 8_10.0s_LP_x.jpg", "Light_*_10.0s_*.fit"))
        XCTAssertTrue(FrameRelay.wildcardMatch("ab.fit", "*.fit"))
    }

    func testCopyOnceCopiesNewMatchingSkipsRest() throws {
        let src = try tmp(), dst = try tmp()
        try write(src, "Light_M 8_10.0s_LP_1.fit")        // match
        try write(src, "Light_M 8_10.0s_LP_1.jpg")        // wrong ext
        try write(src, "Light_M 8_20.0s_LP_2.fit")        // wrong exposure
        let r = FrameRelay(source: src, destination: dst)
        let n = try primeThenCopy(r)
        XCTAssertEqual(n, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("Light_M 8_10.0s_LP_1.fit").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dst.path).filter { $0.hasSuffix(".fit") }.count, 1)
    }

    func testCopyOnceSkipsAlreadyPresent() throws {
        let src = try tmp(), dst = try tmp()
        try write(src, "Light_M 8_10.0s_LP_1.fit")
        let r = FrameRelay(source: src, destination: dst)
        XCTAssertEqual(try primeThenCopy(r), 1)   // prime + copying pass
        XCTAssertEqual(try r.copyOnce(), 0)       // next pass skips existing
        XCTAssertEqual(r.relayedCount, 1)
    }

    func testSnapshotBaselineExcludesBacklog() throws {
        let src = try tmp(), dst = try tmp()
        // 3 backlog subs present at "tap" time
        try write(src, "Light_M 8_10.0s_LP_20260709-000001.fit")
        try write(src, "Light_M 8_10.0s_LP_20260709-000002.fit")
        try write(src, "Light_M 8_10.0s_LP_20260709-000003.fit")
        let r = FrameRelay(source: src, destination: dst)   // sessionScoped defaults true
        r.snapshotBaseline()                                  // capture the 3 backlog names
        // 2 new subs arrive after the tap
        try write(src, "Light_M 8_10.0s_LP_20260711-010001.fit")
        try write(src, "Light_M 8_10.0s_LP_20260711-010002.fit")
        XCTAssertEqual(try primeThenCopy(r), 2)              // only the 2 new
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("Light_M 8_10.0s_LP_20260711-010001.fit").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.appendingPathComponent("Light_M 8_10.0s_LP_20260709-000001.fit").path))
    }

    func testSessionScopedFalseCopiesAll() throws {
        let src = try tmp(), dst = try tmp()
        try write(src, "Light_M 8_10.0s_LP_20260709-000001.fit")
        try write(src, "Light_M 8_10.0s_LP_20260709-000002.fit")
        let r = FrameRelay(source: src, destination: dst, sessionScoped: false)
        r.snapshotBaseline()                                  // no-op when not session-scoped
        try write(src, "Light_M 8_10.0s_LP_20260711-010001.fit")
        XCTAssertEqual(try primeThenCopy(r), 3)              // baseline empty → copies all 3
    }

    func testBaselineStillHonorsGlob() throws {
        let src = try tmp(), dst = try tmp()
        try write(src, "Light_M 8_10.0s_LP_20260709-000001.fit")
        let r = FrameRelay(source: src, destination: dst)
        r.snapshotBaseline()
        try write(src, "Light_M 8_20.0s_LP_20260711-010001.fit")   // new but wrong exposure
        try write(src, "Light_M 8_10.0s_LP_20260711-010002.fit")   // new and matches
        XCTAssertEqual(try primeThenCopy(r), 1)                    // only the matching new one
    }

    func testGrowingFileNotPublishedUntilStable() throws {
        let src = try tmp(), dst = try tmp()
        let name = "Light_M 8_10.0s_LP_grow.fit"
        let srcFile = src.appendingPathComponent(name)
        let r = FrameRelay(source: src, destination: dst)
        // Tick 1: file appears (initial partial write).
        try Data(count: 100).write(to: srcFile)
        XCTAssertEqual(try r.copyOnce(), 0, "first sighting of a partial file must not publish")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.appendingPathComponent(name).path))
        // Append more (slow writer still filling) — file changed between ticks.
        let fh = try FileHandle(forWritingTo: srcFile)
        fh.seekToEndOfFile(); fh.write(Data(count: 200)); try fh.close()
        // Tick 2: changed since last tick → still deferred.
        XCTAssertEqual(try r.copyOnce(), 0, "a file that grew between ticks must stay deferred")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.appendingPathComponent(name).path))
        // Tick 3: no further change → now stable → published complete (300 bytes).
        XCTAssertEqual(try r.copyOnce(), 1, "a file unchanged since the previous tick must publish")
        let published = dst.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: published.path))
        XCTAssertEqual(try Data(contentsOf: published).count, 300, "published copy must be complete")
    }

    func testStableFilePublishesOnce() throws {
        let src = try tmp(), dst = try tmp()
        try write(src, "Light_M 8_10.0s_LP_stable.fit", bytes: 64)
        let r = FrameRelay(source: src, destination: dst)
        XCTAssertEqual(try r.copyOnce(), 0, "first tick records the stat and defers")
        XCTAssertEqual(try r.copyOnce(), 1, "second tick: stable → published")
        XCTAssertEqual(try r.copyOnce(), 0, "already-present file is not re-published")
        XCTAssertEqual(r.relayedCount, 1)
    }

    func testBroadFitsGlobRelaysSessionScoped() throws {
        let src = try tmp(), dst = try tmp()
        try write(src, "old.fit")                        // backlog
        let r = FrameRelay(source: src, destination: dst, glob: "*.fit")
        r.snapshotBaseline()                             // exclude backlog
        try write(src, "new1.fit")
        try write(src, "note.txt")                       // non-FITS ignored
        XCTAssertEqual(try primeThenCopy(r), 1)         // only the new .fit
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("new1.fit").path))
    }
}
