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
        let n = try r.copyOnce()
        XCTAssertEqual(n, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("Light_M 8_10.0s_LP_1.fit").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dst.path).filter { $0.hasSuffix(".fit") }.count, 1)
    }

    func testCopyOnceSkipsAlreadyPresent() throws {
        let src = try tmp(), dst = try tmp()
        try write(src, "Light_M 8_10.0s_LP_1.fit")
        let r = FrameRelay(source: src, destination: dst)
        XCTAssertEqual(try r.copyOnce(), 1)   // first pass copies
        XCTAssertEqual(try r.copyOnce(), 0)   // second pass skips existing
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
        XCTAssertEqual(try r.copyOnce(), 2)                   // only the 2 new
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
        XCTAssertEqual(try r.copyOnce(), 3)                   // baseline empty → copies all 3
    }

    func testBaselineStillHonorsGlob() throws {
        let src = try tmp(), dst = try tmp()
        try write(src, "Light_M 8_10.0s_LP_20260709-000001.fit")
        let r = FrameRelay(source: src, destination: dst)
        r.snapshotBaseline()
        try write(src, "Light_M 8_20.0s_LP_20260711-010001.fit")   // new but wrong exposure
        try write(src, "Light_M 8_10.0s_LP_20260711-010002.fit")   // new and matches
        XCTAssertEqual(try r.copyOnce(), 1)                        // only the matching new one
    }
}
