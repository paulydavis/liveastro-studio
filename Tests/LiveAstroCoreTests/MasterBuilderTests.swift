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

    /// combineDetailed reports frames that ACTUALLY contributed (not the input count) and whether
    /// the flat offset was truly subtracted — so callers can't record ×N or claim "offset subtracted"
    /// when a file was skipped or the offset size-mismatched.
    func testCombineDetailedReportsContributingCountAndOffset() throws {
        let dir = try sandbox(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try writeConst(dir, "d1.fit", 0.4, w: 2, h: 2)
        let b = try writeConst(dir, "d2.fit", 0.6, w: 2, h: 2)
        let odd = try writeConst(dir, "d3.fit", 0.9, w: 4, h: 4)      // skipped (wrong size)
        let dark = try MasterBuilder.combineDetailed(fitsURLs: [a, b, odd], kind: .dark, bias: nil)
        XCTAssertEqual(dark.contributingCount, 2, "the odd-sized frame must not inflate the count")
        XCTAssertFalse(dark.offsetApplied)

        let f = try writeConst(dir, "f1.fit", 0.6, w: 2, h: 2)
        let biasWrong = AstroImage(width: 4, height: 4, channels: 1,
                                   pixels: [Float](repeating: 0.1, count: 16), sourceIsLinear: true)
        let mismatched = try MasterBuilder.combineDetailed(fitsURLs: [f], kind: .flat, bias: biasWrong)
        XCTAssertFalse(mismatched.offsetApplied, "a size-mismatched offset must NOT be silently applied")

        let biasRight = AstroImage(width: 2, height: 2, channels: 1,
                                   pixels: [0.1, 0.1, 0.1, 0.1], sourceIsLinear: true)
        let applied = try MasterBuilder.combineDetailed(fitsURLs: [f], kind: .flat, bias: biasRight)
        XCTAssertTrue(applied.offsetApplied)
    }

    /// With `expected` dimensions, a stray wrong-size frame that sorts first must NOT hijack the
    /// reference and discard the valid same-size frames.
    func testExpectedDimensionsIgnoreOddSortedFirstFrame() throws {
        let dir = try sandbox(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writeConst(dir, "00_odd.fit", 0.9, w: 8, h: 8)   // sorts first, wrong size
        _ = try writeConst(dir, "a.fit", 0.4, w: 2, h: 2)
        _ = try writeConst(dir, "b.fit", 0.6, w: 2, h: 2)
        let urls = [dir.appendingPathComponent("00_odd.fit"),
                    dir.appendingPathComponent("a.fit"), dir.appendingPathComponent("b.fit")]
        let r = try MasterBuilder.combineDetailed(fitsURLs: urls, kind: .dark, bias: nil, expected: (2, 2, 1))
        XCTAssertEqual(r.image.width, 2); XCTAssertEqual(r.image.height, 2)
        XCTAssertEqual(r.contributingCount, 2, "only the target-size frames contribute")
        for p in r.image.pixels { XCTAssertEqual(p, 0.5, accuracy: 1e-5) }   // mean(0.4, 0.6)
    }

    /// A hostile/corrupt `expected` size (e.g. 1e6×1e6 from a bad FITS header) must NOT force a
    /// multi-terabyte allocation: the buffer is allocated only when a real frame matches, so with no
    /// matching frame it throws noValidFrames instead of OOM-ing.
    func testHostileExpectedDimensionsDoNotForceGiantAllocation() throws {
        let dir = try sandbox(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writeConst(dir, "a.fit", 0.5, w: 2, h: 2)
        let urls = [dir.appendingPathComponent("a.fit")]
        XCTAssertThrowsError(try MasterBuilder.combineDetailed(fitsURLs: urls, kind: .dark, bias: nil,
                                                               expected: (1_000_000, 1_000_000, 1))) {
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

    func testSaveLoadRoundTripPreservesPixels() throws {
        let dir = try sandbox(); defer { try? FileManager.default.removeItem(at: dir) }
        let master = AstroImage(width: 3, height: 2, channels: 1,
                                pixels: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6], sourceIsLinear: true)
        let url = dir.appendingPathComponent("master_dark.fit")
        try MasterBuilder.save(master, to: url)
        let loaded = try MasterBuilder.load(url)
        XCTAssertEqual(loaded.width, 3); XCTAssertEqual(loaded.height, 2)
        for (a, b) in zip(loaded.pixels, master.pixels) { XCTAssertEqual(a, b, accuracy: 1e-5) }
    }

    func testSavedNormalizedFlatRoundTripPreservesValuesAboveOne() throws {
        let dir = try sandbox(); defer { try? FileManager.default.removeItem(at: dir) }
        let flat = AstroImage(width: 2, height: 2, channels: 1,
                              pixels: [0.4, 0.8, 1.2, 1.6], sourceIsLinear: true)
        let url = dir.appendingPathComponent("master_flat.fit")
        try MasterBuilder.save(flat, to: url)

        let loaded = try MasterBuilder.load(url)

        XCTAssertEqual(loaded.width, 2)
        XCTAssertEqual(loaded.height, 2)
        XCTAssertEqual(loaded.channels, 1)
        for (got, expected) in zip(loaded.pixels, flat.pixels) {
            XCTAssertEqual(got, expected, accuracy: 1e-5)
        }
    }

    func testNormalizedFlatMakesMedianOne() throws {
        // pixels [1, 2, 3, 4] → median = (2+3)/2 = 2.5 → normalized [0.4, 0.8, 1.2, 1.6]
        let input = AstroImage(width: 2, height: 2, channels: 1,
                               pixels: [1.0, 2.0, 3.0, 4.0], sourceIsLinear: true)
        let normed = MasterBuilder.normalizedFlat(input)
        let expected: [Float] = [0.4, 0.8, 1.2, 1.6]
        for (got, exp) in zip(normed.pixels, expected) {
            XCTAssertEqual(got, exp, accuracy: 1e-5)
        }
        // median of normalized result must be 1.0
        let sorted = normed.pixels.sorted()
        let med = (sorted[1] + sorted[2]) / 2
        XCTAssertEqual(med, 1.0, accuracy: 1e-5)
        // idempotence: normalizing again leaves pixels unchanged
        let normed2 = MasterBuilder.normalizedFlat(normed)
        for (a, b) in zip(normed2.pixels, normed.pixels) {
            XCTAssertEqual(a, b, accuracy: 1e-5)
        }
    }

    func testLoadFlipsBottomUpFileToTopDown() throws {
        let dir = try sandbox(); defer { try? FileManager.default.removeItem(at: dir) }
        // A bottom-up file written with FITSWriter(bottomUp: true) stores the input flipped to disk;
        // load(normalizeRowOrder: true) flips it back, so the round-trip yields the original top-down input [0.9, 0.1].
        let url = dir.appendingPathComponent("bu.fit")
        try FITSWriter.float32(width: 1, height: 2, channels: 1,
                               pixels: [0.9, 0.1], bottomUp: true).write(to: url)
        let loaded = try MasterBuilder.load(url)
        XCTAssertEqual(loaded.pixels.count, 2)
        XCTAssertEqual(loaded.pixels[0], Float(0.9), accuracy: 1e-5)
        XCTAssertEqual(loaded.pixels[1], Float(0.1), accuracy: 1e-5)
    }
}
