import XCTest
@testable import LiveAstroCore

final class MasterBuilderTests: XCTestCase {
    /// Write a top-down mono FITS of constant value `v` (2×2 default).
    func writeConst(_ dir: URL, _ name: String, _ v: Float, w: Int = 2, h: Int = 2) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FITSWriter.float32(width: w, height: h, channels: 1,
                               pixels: [Float](repeating: v, count: w * h)).write(to: url)
        return url
    }

    func sandbox() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testDarkIsMeanOfFrames() throws {
        let dir = try sandbox(); defer { try? FileManager.default.removeItem(at: dir) }
        // values 0.2 and 0.4 in [0,1] → mean 0.3
        let a = try writeConst(dir, "d1.fit", 0.2)
        let b = try writeConst(dir, "d2.fit", 0.4)
        let master = try MasterBuilder.combine(fitsURLs: [a, b], kind: .dark, bias: nil)
        XCTAssertEqual(master.width, 2); XCTAssertEqual(master.channels, 1)
        for p in master.pixels { XCTAssertEqual(p, 0.3, accuracy: 1e-5) }
    }

    func testEmptyThrows() throws {
        XCTAssertThrowsError(try MasterBuilder.combine(fitsURLs: [], kind: .dark, bias: nil)) {
            XCTAssertEqual($0 as? MasterBuilder.BuildError, .noFrames)
        }
    }

    func testDimensionMismatchIsSkipped() throws {
        let dir = try sandbox(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try writeConst(dir, "d1.fit", 0.5, w: 2, h: 2)
        let odd = try writeConst(dir, "d2.fit", 0.9, w: 4, h: 4)     // mismatched → skipped
        let master = try MasterBuilder.combine(fitsURLs: [a, odd], kind: .dark, bias: nil)
        XCTAssertEqual(master.width, 2)
        for p in master.pixels { XCTAssertEqual(p, 0.5, accuracy: 1e-5) }   // only a counted
    }

    func testNoValidFramesThrows() throws {
        let dir = try sandbox(); defer { try? FileManager.default.removeItem(at: dir) }
        let garbage = dir.appendingPathComponent("x.fit")
        try Data([0x00, 0x01, 0x02]).write(to: garbage)     // not a FITS file → unreadable
        XCTAssertThrowsError(try MasterBuilder.combine(fitsURLs: [garbage], kind: .dark, bias: nil)) {
            XCTAssertEqual($0 as? MasterBuilder.BuildError, .noValidFrames)
        }
    }

    func testFlatBiasSubtractedAndNormalizedToMedianOne() throws {
        let dir = try sandbox(); defer { try? FileManager.default.removeItem(at: dir) }
        // flat frames constant 0.6; bias constant 0.1 → (0.6-0.1)=0.5 everywhere;
        // normalized to median 1 → all pixels 1.0
        let f1 = try writeConst(dir, "f1.fit", 0.6)
        let f2 = try writeConst(dir, "f2.fit", 0.6)
        let bias = AstroImage(width: 2, height: 2, channels: 1,
                              pixels: [0.1, 0.1, 0.1, 0.1], sourceIsLinear: true)
        let flat = try MasterBuilder.combine(fitsURLs: [f1, f2], kind: .flat, bias: bias)
        for p in flat.pixels { XCTAssertEqual(p, 1.0, accuracy: 1e-5) }
    }
}
