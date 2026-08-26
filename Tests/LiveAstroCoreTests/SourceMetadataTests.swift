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

    func testParsesBinningAndSetTemp() {
        // XBINNING is an integer; SET-TEMP the cooler set-point, distinct from CCD-TEMP.
        let m = SourceMetadata(fitsKeywords: [
            "XBINNING": "2", "SET-TEMP": "-10.0", "CCD-TEMP": "-9.6", "GAIN": "100",
        ])
        XCTAssertEqual(m.binning, 2)
        XCTAssertEqual(m.setTempC ?? 0, -10.0, accuracy: 1e-6)
        XCTAssertEqual(m.ccdTempC ?? 0, -9.6, accuracy: 1e-6)
    }

    func testBinningRoundsFloatFormattedValue() {
        // Some writers emit "2.0" for XBINNING; it must land as Int 2.
        XCTAssertEqual(SourceMetadata(fitsKeywords: ["XBINNING": "2.0"]).binning, 2)
    }

    func testBinningAndSetTempNilWhenAbsent() {
        let m = SourceMetadata(fitsKeywords: ["OBJECT": "M31"])
        XCTAssertNil(m.binning); XCTAssertNil(m.setTempC)
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

    /// Non-finite numeric cards must NOT crash. XBINNING = NaN previously reached
    /// Int(Double.nan.rounded()), which traps — a malformed header could kill the app.
    func testNonFiniteNumericsAreRejectedNotTrapped() {
        let m = SourceMetadata(fitsKeywords: ["XBINNING": "nan", "EXPTIME": "inf", "GAIN": "NaN"])
        XCTAssertNil(m.binning)
        XCTAssertNil(m.exposureSeconds)
        XCTAssertNil(m.gain)
        // Nonpositive binning is invalid → rejected (not 0).
        XCTAssertNil(SourceMetadata(fitsKeywords: ["XBINNING": "0"]).binning)
        XCTAssertNil(SourceMetadata(fitsKeywords: ["XBINNING": "-1"]).binning)
    }

    /// A FINITE but astronomically large value passes isFinite yet traps Int(_:). It must be
    /// rejected by the bounded parser, not crash. (Double("1e100")!.isFinite == true.)
    func testHugeFiniteNumericsDoNotTrapIntConversion() {
        let m = SourceMetadata(fitsKeywords: ["XBINNING": "1e100", "NAXIS1": "1e300", "NAXIS2": "9e99", "NAXIS3": "1e40"])
        XCTAssertNil(m.binning)
        XCTAssertNil(m.width)
        XCTAssertNil(m.height)
        XCTAssertNil(m.channels)
        // In-range values still parse; a 2-D frame reports 1 channel.
        let ok = SourceMetadata(fitsKeywords: ["NAXIS1": "6248", "NAXIS2": "4176", "XBINNING": "2"])
        XCTAssertEqual(ok.width, 6248); XCTAssertEqual(ok.height, 4176)
        XCTAssertEqual(ok.binning, 2); XCTAssertEqual(ok.channels, 1)
        XCTAssertEqual(SourceMetadata(fitsKeywords: ["NAXIS1": "100", "NAXIS2": "100", "NAXIS3": "3"]).channels, 3)
    }

    /// Fortran-style FITS D/d exponents (1.8D+02) are valid FITS but Swift's Double(_:) returns nil.
    /// They must parse, else exposure silently goes nil and calibration matching turns ambiguous.
    func testFortranStyleDExponentParses() {
        let m = SourceMetadata(fitsKeywords: ["EXPTIME": "1.8D+02", "GAIN": "1.0d2", "FOCALLEN": "6.72D2"])
        XCTAssertEqual(m.exposureSeconds ?? 0, 180, accuracy: 1e-9)
        XCTAssertEqual(m.gain ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(m.focalLengthMM ?? 0, 672, accuracy: 1e-9)
    }
}
