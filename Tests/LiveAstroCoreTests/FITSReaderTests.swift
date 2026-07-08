import XCTest
@testable import LiveAstroCore

final class FITSReaderTests: XCTestCase {

    func testRejectsNonFITS() {
        XCTAssertThrowsError(try FITSReader.readHeader(Data(repeating: 0x41, count: 2880))) {
            XCTAssertEqual($0 as? FITSError, .notFITS)
        }
    }

    func testTruncatedHeaderThrows() {
        let full = FITSWriter.float32(width: 4, height: 4, channels: 1,
                                      pixels: [Float](repeating: 0.5, count: 16))
        XCTAssertThrowsError(try FITSReader.readHeader(full.prefix(100))) {
            XCTAssertEqual($0 as? FITSError, .truncatedHeader)
        }
    }

    func testFloat32RoundTripMono() throws {
        let px: [Float] = (0..<16).map { Float($0) / 15.0 }
        let data = FITSWriter.float32(width: 4, height: 4, channels: 1, pixels: px)
        let img = try FITSReader.read(data)
        XCTAssertEqual(img.width, 4); XCTAssertEqual(img.height, 4); XCTAssertEqual(img.channels, 1)
        for (a, b) in zip(img.pixels, px) { XCTAssertEqual(a, b, accuracy: 1e-6) }
    }

    func testFloat32RoundTripRGB() throws {
        let px = (0..<12).map { Float($0) / 11.0 }
        let data = FITSWriter.float32(width: 2, height: 2, channels: 3, pixels: Array(px))
        let img = try FITSReader.read(data)
        XCTAssertEqual(img.channels, 3)
        XCTAssertEqual(img.pixels.count, 12)
        for (a, b) in zip(img.pixels, px) { XCTAssertEqual(a, b, accuracy: 1e-6) }
    }

    func testBottomUpRowsAreFlipped() throws {
        // 2x2, values row-major top-down: [0.1, 0.4, 0.6, 0.9]. Written bottom-up they are stored [0.6, 0.9, 0.1, 0.4].
        let px: [Float] = [0.1, 0.4, 0.6, 0.9]
        let data = FITSWriter.float32(width: 2, height: 2, channels: 1,
                                      pixels: px, bottomUp: true)
        let img = try FITSReader.read(data)
        // reader restores top-down
        for (a, b) in zip(img.pixels, px) { XCTAssertEqual(a, b, accuracy: 1e-6) }
    }

    func testInt16WithBZeroNormalizes() throws {
        // Siril unsigned-16 convention: BZERO=32768. Raw -32768 -> physical 0 -> 0.0; raw 32767 -> 65535 -> ~1.0
        var data = FITSTestBuilder.header(cards: [
            ("SIMPLE", "T"), ("BITPIX", "16"), ("NAXIS", "2"),
            ("NAXIS1", "2"), ("NAXIS2", "1"), ("BZERO", "32768"), ("BSCALE", "1"),
        ])
        for raw in [Int16.min, Int16.max] {
            var be = raw.bigEndian
            withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        }
        data.append(Data(repeating: 0, count: 2880 - 4)) // pad data block
        let img = try FITSReader.read(data)
        XCTAssertEqual(img.pixels[0], 0.0, accuracy: 1e-4)
        XCTAssertEqual(img.pixels[1], 1.0, accuracy: 1e-4)
    }

    func testUnsupportedBitpixThrows() {
        let data = FITSTestBuilder.header(cards: [
            ("SIMPLE", "T"), ("BITPIX", "64"), ("NAXIS", "2"), ("NAXIS1", "1"), ("NAXIS2", "1"),
        ])
        XCTAssertThrowsError(try FITSReader.readHeader(data)) {
            XCTAssertEqual($0 as? FITSError, .unsupported("BITPIX 64"))
        }
    }

    func testMinimumFileSizeAndTruncatedData() throws {
        let px = [Float](repeating: 0, count: 100 * 100)
        let data = FITSWriter.float32(width: 100, height: 100, channels: 1, pixels: px)
        let h = try FITSReader.readHeader(data)
        XCTAssertEqual(h.minimumFileSize, h.headerBytes + 100 * 100 * 4)
        let truncated = h.minimumFileSize - 1
        XCTAssertThrowsError(try FITSReader.read(data.prefix(truncated))) {
            XCTAssertEqual($0 as? FITSError, .truncatedData(expected: h.minimumFileSize, actual: truncated))
        }
    }

    /// Regression (F1): Swift's min/max do not clamp NaN, so non-finite float samples
    /// used to survive the 0…1 clamp and poison downstream stacking arithmetic.
    func testNonFiniteFloat32SamplesClampToZero() throws {
        var data = FITSTestBuilder.header(cards: [
            ("SIMPLE", "T"), ("BITPIX", "-32"), ("NAXIS", "2"),
            ("NAXIS1", "4"), ("NAXIS2", "1"),
        ])
        for v: Float in [.nan, .infinity, 0.5, -0.25] {
            var be = v.bitPattern.bigEndian
            withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        }
        data.append(Data(repeating: 0, count: 2880 - 16)) // pad data block
        let img = try FITSReader.read(data)
        for v in img.pixels {
            XCTAssertTrue(v.isFinite, "output must contain only finite values")
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThanOrEqual(v, 1)
        }
        XCTAssertEqual(img.pixels[0], 0)                          // NaN → 0
        XCTAssertEqual(img.pixels[1], 0)                          // +Inf → 0
        XCTAssertEqual(img.pixels[2], 0.5, accuracy: 1e-6)        // finite passes through
        XCTAssertEqual(img.pixels[3], 0)                          // negative clamps to 0
    }

    /// Regression (F3): astronomically large NAXIS values used to trap on overflow in
    /// dataBytes/minimumFileSize instead of throwing.
    func testImplausibleDimensionsThrowInsteadOfTrapping() {
        let data = FITSTestBuilder.header(cards: [
            ("SIMPLE", "T"), ("BITPIX", "16"), ("NAXIS", "2"),
            ("NAXIS1", "4000000000"), ("NAXIS2", "4000000000"),
        ])
        XCTAssertThrowsError(try FITSReader.readHeader(data)) {
            XCTAssertEqual($0 as? FITSError, .malformedHeader("implausible dimensions"))
        }
    }

    func testHeaderKeywordsCaptured() throws {
        var header = ""
        func card(_ s: String) { header += s.padding(toLength: 80, withPad: " ", startingAt: 0) }
        card("SIMPLE  =                    T")
        card("BITPIX  =                   16")
        card("NAXIS   =                    2")
        card("NAXIS1  =                    4")
        card("NAXIS2  =                    2")
        card("BZERO   =                32768")
        card("BAYERPAT= 'GRBG    '")
        card("DATE-OBS= '2026-07-06T22:04:40.123'")
        card("END")
        var data = header.data(using: .ascii)!
        data.append(Data(repeating: 0x20, count: 2880 - data.count % 2880))
        data.append(Data(repeating: 0, count: 16))
        let h = try FITSReader.readHeader(data)
        XCTAssertEqual(h.bayerPattern, "GRBG")
        XCTAssertEqual(h.dateObs, "2026-07-06T22:04:40.123")
        XCTAssertEqual(h.keywords["BITPIX"], "16")
    }
}

/// Builds raw FITS headers for edge-case tests (FITSWriter covers the happy path).
enum FITSTestBuilder {
    static func card(_ key: String, _ value: String) -> String {
        let k = key.padding(toLength: 8, withPad: " ", startingAt: 0)
        return "\(k)= \(value)".padding(toLength: 80, withPad: " ", startingAt: 0)
    }
    static func header(cards: [(String, String)]) -> Data {
        var s = cards.map { card($0.0, $0.1) }.joined()
        s += "END".padding(toLength: 80, withPad: " ", startingAt: 0)
        while s.count % 2880 != 0 { s += String(repeating: " ", count: 80) }
        return s.data(using: .ascii)!
    }

    /// FITS standard: '/' inside a quoted string is NOT a comment delimiter,
    /// and a quote inside a string is escaped by doubling.
    func testQuotedValuesWithSlashesAndEscapes() throws {
        var header = ""
        func card(_ c: String) { header += c.padding(toLength: 80, withPad: " ", startingAt: 0) }
        card("SIMPLE  =                    T")
        card("BITPIX  =                   16")
        card("NAXIS   =                    2")
        card("NAXIS1  =                    4")
        card("NAXIS2  =                    2")
        card("FILTER  = 'Ha/OIII '           / dual-band filter")
        card("OBSERVER= 'O''HARA'")
        card("OBJECT  = 'M 101 / Pinwheel'")
        card("EXPTIME =                 30.0 / seconds")
        card("END")
        var data = header.data(using: .ascii)!
        data.append(Data(repeating: 0x20, count: 2880 - data.count % 2880))
        data.append(Data(repeating: 0, count: 16))
        let h = try FITSReader.readHeader(data)
        XCTAssertEqual(h.keywords["FILTER"], "Ha/OIII")
        XCTAssertEqual(h.keywords["OBSERVER"], "O'HARA")
        XCTAssertEqual(h.keywords["OBJECT"], "M 101 / Pinwheel")
        XCTAssertEqual(h.keywords["EXPTIME"], "30.0")
    }
}
