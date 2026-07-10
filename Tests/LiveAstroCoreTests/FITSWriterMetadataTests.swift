import XCTest
@testable import LiveAstroCore

final class FITSWriterMetadataTests: XCTestCase {
    private func headerText(_ data: Data) -> String {
        // read ASCII header blocks until END
        var text = ""
        var offset = 0
        while offset < data.count {
            let block = String(data: data.subdata(in: offset..<min(offset+2880, data.count)), encoding: .ascii) ?? ""
            text += block; offset += 2880
            if block.contains("END     ") { break }
        }
        return text
    }

    func testEmitsMetadataCards() {
        var m = SourceMetadata()
        m.object = "NGC 6960"; m.ra = 314.36667; m.dec = 31.834722
        m.focalLengthMM = 160; m.pixelSizeUM = 2.9; m.filter = "LP"
        m.exposureSeconds = 30; m.dateObs = "2026-07-10T03:51:36"
        let d = FITSWriter.float32(width: 2, height: 2, channels: 3,
                                   pixels: [Float](repeating: 0, count: 12),
                                   metadata: m, stackCount: 606, totalExposureSeconds: 18180)
        let h = headerText(d)
        XCTAssertTrue(h.contains("OBJECT  = 'NGC 6960"))
        XCTAssertTrue(h.contains("RA      ="))
        XCTAssertTrue(h.contains("314.36667"))
        XCTAssertTrue(h.contains("DEC     ="))
        XCTAssertTrue(h.contains("FOCALLEN="))
        XCTAssertTrue(h.contains("FILTER  = 'LP"))
        XCTAssertTrue(h.contains("STACKCNT="))
        XCTAssertTrue(h.contains("606"))
        XCTAssertTrue(h.contains("TOTALEXP="))
        XCTAssertTrue(h.contains("HISTORY"))
    }

    func testNeverEmitsBayerPatternOnRGB() {
        var m = SourceMetadata(); m.object = "X"
        let d = FITSWriter.float32(width: 2, height: 2, channels: 3,
                                   pixels: [Float](repeating: 0, count: 12), metadata: m)
        XCTAssertFalse(headerText(d).contains("BAYERPAT"))
    }

    func testNilFieldsOmitted() {
        var m = SourceMetadata(); m.object = "M31"   // everything else nil
        let d = FITSWriter.float32(width: 2, height: 2, channels: 1,
                                   pixels: [0,0,0,0], metadata: m)
        let h = headerText(d)
        XCTAssertTrue(h.contains("OBJECT  = 'M31"))
        XCTAssertFalse(h.contains("RA      ="))
        XCTAssertFalse(h.contains("FOCALLEN="))
        XCTAssertFalse(h.contains("FILTER  ="))
    }

    func testMetadataRoundTripsThroughReader() throws {
        var m = SourceMetadata(); m.object = "NGC 6960"; m.ra = 314.36667
        let d = FITSWriter.float32(width: 2, height: 2, channels: 3,
                                   pixels: [Float](repeating: 0, count: 12), metadata: m)
        let hdr = try FITSReader.readHeader(d)
        XCTAssertEqual(hdr.keywords["OBJECT"]?.replacingOccurrences(of: "'", with: "").trimmingCharacters(in: .whitespaces), "NGC 6960")
        XCTAssertEqual(Double(hdr.keywords["RA"]!.trimmingCharacters(in: .whitespaces))!, 314.36667, accuracy: 1e-5)
    }

    func testNoMetadataMatchesTask2Output() {
        let px = [Float](repeating: 0.25, count: 12)
        let a = FITSWriter.float32(width: 2, height: 2, channels: 3, pixels: px)
        let b = FITSWriter.float32(width: 2, height: 2, channels: 3, pixels: px, metadata: nil)
        XCTAssertEqual(a, b)   // defaulted metadata == no metadata
    }

    // MARK: - Regression: C1 — full-precision numeric must not trap

    /// A real SITELONG value with 22 chars in String(d) used to hit the
    /// precondition in card() and crash the writer, losing the master.
    func testFullPrecisionNumericDoesNotTrap() {
        var m = SourceMetadata()
        m.ra = 314.36667
        m.dec = -97.6027
        m.siteLon = -0.0019441035675527019   // 22-char String(d) — traps before fix

        // Must return Data without trapping
        let d = FITSWriter.float32(width: 2, height: 2, channels: 1,
                                   pixels: [0, 0, 0, 0], metadata: m)

        // Header must be 2880-byte aligned
        XCTAssertTrue(d.count % 2880 == 0, "FITS data must be 2880-byte aligned")

        // Verify SITELONG and RA cards are present and parse back to Doubles close to input
        let h = headerText(d)
        XCTAssertTrue(h.contains("SITELONG"), "SITELONG card must be written")
        XCTAssertTrue(h.contains("RA      ="), "RA card must be written")

        // RA must round-trip within 1e-4
        // Extract RA value by finding the card
        let lines = stride(from: 0, to: h.count, by: 80).map { i -> String in
            let start = h.index(h.startIndex, offsetBy: i)
            let end = h.index(start, offsetBy: min(80, h.count - i))
            return String(h[start..<end])
        }
        let raCard = lines.first(where: { $0.hasPrefix("RA      =") })
        XCTAssertNotNil(raCard, "RA card must be present")
        if let raCard = raCard {
            let valueField = String(raCard.dropFirst(10).prefix(20)).trimmingCharacters(in: .whitespaces)
            let parsed = Double(valueField)
            XCTAssertNotNil(parsed, "RA value must parse as Double")
            if let parsed = parsed {
                XCTAssertEqual(parsed, 314.36667, accuracy: 1e-4,
                               "RA must round-trip within 1e-4")
            }
        }
    }

    // MARK: - Regression: C2 — non-ASCII string metadata must not trap

    /// An em-dash in OBJECT used to make .data(using: .ascii)! return nil and crash.
    func testNonAsciiStringMetadataStaysAsciiAndAligned() {
        var m = SourceMetadata()
        m.object = "Caldwell 33 \u{2014} Eastern Veil"  // em-dash U+2014

        // Must return Data without trapping
        let d = FITSWriter.float32(width: 2, height: 2, channels: 1,
                                   pixels: [0, 0, 0, 0], metadata: m)

        // Header must be 2880-byte aligned
        XCTAssertTrue(d.count % 2880 == 0, "FITS data must be 2880-byte aligned")

        // Every 80-byte card slice must be valid ASCII
        let headerBytes = d.prefix(2880)
        XCTAssertEqual(headerBytes.count, 2880)
        for i in stride(from: 0, to: 2880, by: 80) {
            let slice = headerBytes[headerBytes.startIndex.advanced(by: i)..<headerBytes.startIndex.advanced(by: i + 80)]
            let cardStr = String(bytes: slice, encoding: .ascii)
            XCTAssertNotNil(cardStr, "Card at offset \(i) must be valid ASCII (non-ASCII bytes found)")
        }

        // OBJECT card must be present (ASCII-sanitized)
        let h = headerText(d)
        XCTAssertTrue(h.contains("OBJECT  ="), "OBJECT card must be present")
        XCTAssertTrue(h.contains("Caldwell 33"), "OBJECT card must contain ASCII portion of the name")
    }
}
