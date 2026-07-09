import XCTest
@testable import LiveAstroCore

final class SeestarRelayTests: XCTestCase {
    func tmp() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
    }
    func write(_ dir: URL, _ name: String, bytes: Int = 32) throws {
        try Data(count: bytes).write(to: dir.appendingPathComponent(name))
    }

    func testWildcardMatch() {
        XCTAssertTrue(SeestarRelay.wildcardMatch("Light_M 8_10.0s_LP_20260709-034653.fit", "Light_*_10.0s_*.fit"))
        XCTAssertFalse(SeestarRelay.wildcardMatch("Light_M 8_20.0s_LP_20260707-000534.fit", "Light_*_10.0s_*.fit"))
        XCTAssertFalse(SeestarRelay.wildcardMatch("Light_M 8_10.0s_LP_x.jpg", "Light_*_10.0s_*.fit"))
        XCTAssertTrue(SeestarRelay.wildcardMatch("ab.fit", "*.fit"))
    }

    func testCopyOnceCopiesNewMatchingSkipsRest() throws {
        let src = try tmp(), dst = try tmp()
        try write(src, "Light_M 8_10.0s_LP_1.fit")        // match
        try write(src, "Light_M 8_10.0s_LP_1.jpg")        // wrong ext
        try write(src, "Light_M 8_20.0s_LP_2.fit")        // wrong exposure
        let r = SeestarRelay(source: src, destination: dst)
        let n = try r.copyOnce()
        XCTAssertEqual(n, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("Light_M 8_10.0s_LP_1.fit").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dst.path).filter { $0.hasSuffix(".fit") }.count, 1)
    }

    func testCopyOnceSkipsAlreadyPresent() throws {
        let src = try tmp(), dst = try tmp()
        try write(src, "Light_M 8_10.0s_LP_1.fit")
        let r = SeestarRelay(source: src, destination: dst)
        XCTAssertEqual(try r.copyOnce(), 1)   // first pass copies
        XCTAssertEqual(try r.copyOnce(), 0)   // second pass skips existing
        XCTAssertEqual(r.relayedCount, 1)
    }
}
