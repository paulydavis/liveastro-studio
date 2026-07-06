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
}
