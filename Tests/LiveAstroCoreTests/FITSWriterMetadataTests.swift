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
}
