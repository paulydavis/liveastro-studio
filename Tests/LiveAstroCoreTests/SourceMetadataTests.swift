import XCTest
@testable import LiveAstroCore

final class SourceMetadataTests: XCTestCase {
    // Real cards from a Seestar S30 Pro sub (values verbatim).
    private let seestar: [String: String] = [
        "OBJECT": "NGC 6960", "RA": "314.36667", "DEC": "31.834722",
        "FOCALLEN": "160.0", "XPIXSZ": "2.90000009536743", "YPIXSZ": "2.90000009536743",
        "INSTRUME": "imx585", "TELESCOP": "S30 Pro_041c45cb", "FILTER": "LP",
        "EXPTIME": "30.0", "DATE-OBS": "2026-07-10T03:51:36.210844",
        "GAIN": "200", "CCD-TEMP": "35.0", "SITELAT": "30.5699", "SITELONG": "-97.6027",
    ]

    func testParsesSeestarHeader() {
        let m = SourceMetadata(fitsKeywords: seestar)
        XCTAssertEqual(m.object, "NGC 6960")
        XCTAssertEqual(m.ra ?? 0, 314.36667, accuracy: 1e-5)
        XCTAssertEqual(m.dec ?? 0, 31.834722, accuracy: 1e-5)
        XCTAssertEqual(m.focalLengthMM ?? 0, 160.0, accuracy: 1e-6)
        XCTAssertEqual(m.pixelSizeUM ?? 0, 2.9, accuracy: 1e-3)
        XCTAssertEqual(m.instrument, "imx585")
        XCTAssertEqual(m.telescope, "S30 Pro_041c45cb")
        XCTAssertEqual(m.filter, "LP")
        XCTAssertEqual(m.exposureSeconds ?? 0, 30.0, accuracy: 1e-6)
        XCTAssertEqual(m.dateObs, "2026-07-10T03:51:36.210844")
        XCTAssertEqual(m.gain ?? 0, 200, accuracy: 1e-6)
        XCTAssertEqual(m.siteLat ?? 0, 30.5699, accuracy: 1e-4)
        XCTAssertEqual(m.siteLon ?? 0, -97.6027, accuracy: 1e-4)
    }

    func testStripsQuotesAndWhitespace() {
        let m = SourceMetadata(fitsKeywords: ["OBJECT": "'NGC 6960 '", "RA": " 314.5 "])
        XCTAssertEqual(m.object, "NGC 6960")   // quotes stripped, trailing space trimmed
        XCTAssertEqual(m.ra ?? 0, 314.5, accuracy: 1e-6)
    }

    func testMissingCardsAreNil() {
        let m = SourceMetadata(fitsKeywords: ["OBJECT": "M31"])
        XCTAssertEqual(m.object, "M31")
        XCTAssertNil(m.ra); XCTAssertNil(m.dec); XCTAssertNil(m.focalLengthMM)
        XCTAssertNil(m.filter); XCTAssertNil(m.dateObs); XCTAssertNil(m.gain)
    }

    func testEmptyIsAllNil() {
        let m = SourceMetadata(fitsKeywords: [:])
        XCTAssertEqual(m, SourceMetadata(fitsKeywords: [:]))
        XCTAssertNil(m.object); XCTAssertNil(m.ra)
    }
}
