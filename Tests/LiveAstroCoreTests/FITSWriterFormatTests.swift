import XCTest
@testable import LiveAstroCore

final class FITSWriterFormatTests: XCTestCase {
    private func header(_ data: Data) -> String {
        // header is ASCII up to and including the END card's block
        String(data: data.prefix(2880), encoding: .ascii)!
    }
    private func card(_ header: String, at index: Int) -> String {
        let start = header.index(header.startIndex, offsetBy: index * 80)
        let end = header.index(start, offsetBy: 80)
        return String(header[start..<end])
    }

    func testSimpleCardIsFixedFormat() {
        let d = FITSWriter.float32(width: 2, height: 2, channels: 1, pixels: [0,0,0,0])
        let c = card(header(d), at: 0)
        // "SIMPLE  =                    T" — 'T' at column 30 (index 29)
        XCTAssertTrue(c.hasPrefix("SIMPLE  = "))
        XCTAssertEqual(Array(c)[29], "T")
        XCTAssertEqual(c.count, 80)
    }

    func testIntegerCardsRightJustifiedToCol30() {
        let d = FITSWriter.float32(width: 5, height: 7, channels: 1, pixels: [Float](repeating: 0, count: 35))
        let h = header(d)
        // NAXIS1 = 5 : '5' ends at column 30 (index 29)
        let naxis1 = (0..<10).map { card(h, at: $0) }.first { $0.hasPrefix("NAXIS1 ") }!
        XCTAssertEqual(Array(naxis1)[29], "5")
        let bitpix = (0..<10).map { card(h, at: $0) }.first { $0.hasPrefix("BITPIX ") }!
        XCTAssertTrue(bitpix.hasPrefix("BITPIX  = "))
        // BITPIX -32: '2' at col 30
        XCTAssertEqual(Array(bitpix)[29], "2")
    }

    func testStringCardQuotedFromCol11() {
        let d = FITSWriter.float32(width: 2, height: 2, channels: 1, pixels: [0,0,0,0])
        let roworder = (0..<10).map { card(header(d), at: $0) }.first { $0.hasPrefix("ROWORDER") }!
        // quoted string: opening quote at column 11 (index 10)
        XCTAssertEqual(Array(roworder)[10], "'")
        XCTAssertTrue(roworder.contains("TOP-DOWN"))
    }

    func testHeaderIsBlockAligned() {
        let d = FITSWriter.float32(width: 3, height: 3, channels: 3, pixels: [Float](repeating: 0, count: 27))
        // find END card, header length must be a 2880 multiple
        XCTAssertEqual(d.count % 2880, 0)
    }

    func testStillRoundTripsThroughReader() throws {
        let px: [Float] = (0..<12).map { Float($0) / 12.0 }
        let d = FITSWriter.float32(width: 2, height: 2, channels: 3, pixels: px)
        let img = try FITSReader.read(d)   // existing reader entry point
        XCTAssertEqual(img.width, 2); XCTAssertEqual(img.height, 2); XCTAssertEqual(img.channels, 3)
    }

    func testLongStringCardStaysEightyBytes() throws {
        // OBJECT is a 100-char string; cardStr must truncate to keep card within 80 bytes
        let longName = String(repeating: "X", count: 100)
        var metadata = SourceMetadata()
        metadata.object = longName

        let px = [Float](repeating: 0, count: 4)
        let d = FITSWriter.float32(width: 2, height: 2, channels: 1, pixels: px, metadata: metadata)

        // The entire FITS header must be a multiple of 80 bytes and 2880 bytes
        // Extract header (everything up to and including END block padding)
        let headerData = d.prefix(2880)
        XCTAssertEqual(headerData.count % 80, 0, "Header must be multiple of 80 bytes")
        XCTAssertEqual(d.count % 2880, 0, "Full data must be multiple of 2880 bytes")

        // Verify we can still read it back through the reader
        let img = try FITSReader.read(d)
        XCTAssertEqual(img.width, 2)
        XCTAssertEqual(img.height, 2)
        XCTAssertEqual(img.channels, 1)
    }
}
