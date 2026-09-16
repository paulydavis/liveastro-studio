import XCTest
@testable import LiveAstroCore
@testable import LiveAstroStudio

final class SetupPresentationTests: XCTestCase {
    // Break caught: substituting the decorative galaxy's name for an empty/changed target.
    func testTargetComesOnlyFromSessionField() {
        XCTAssertEqual(SetupPresentation.targetTitle("  M 51 \n"), "M 51")
        XCTAssertEqual(SetupPresentation.targetTitle(" \n"), "Untitled session")
        XCTAssertEqual(SetupPresentation.targetTitle("NGC 6960"), "NGC 6960")
    }

    // Break caught: inventing calibration readiness from merely selected folders.
    func testSelectedFoldersAreReportedWithoutClaimingTheyAreValidated() {
        let summary = SetupPresentation.calibration(
            flats: URL(fileURLWithPath: "/not-read/session-flats"),
            darkFlats: URL(fileURLWithPath: "/not-read/session-dark-flats"), library: [])
        XCTAssertEqual(summary.flats, "session-flats")
        XCTAssertEqual(summary.darkFlats, "session-dark-flats")
        XCTAssertEqual(summary.darks, "None in library")
        XCTAssertEqual(summary.bias, "None in library")
    }

    // Break caught: counting bias as darks, or claiming a library master is matched/active.
    func testDarkAndBiasInventoryAreSeparateFromSessionMatching() {
        let summary = SetupPresentation.calibration(flats: nil, darkFlats: nil,
            library: [master(.dark), master(.bias), master(.bias)])
        XCTAssertEqual(summary.darks, "1 in library")
        XCTAssertEqual(summary.bias, "2 in library")
        XCTAssertEqual(summary.flats, "Not selected")
        XCTAssertEqual(summary.darkFlats, "Not selected")
    }

    func testFlatLibraryEntryDoesNotMasqueradeAsDarkOrBias() {
        let summary = SetupPresentation.calibration(flats: nil, darkFlats: nil, library: [master(.flat)])
        XCTAssertEqual(summary.darks, "None in library")
        XCTAssertEqual(summary.bias, "None in library")
    }

    private func master(_ kind: MasterKind) -> MasterFrame {
        MasterFrame(id: UUID(), kind: kind, camera: "Other camera", gain: 100,
                    exposureSeconds: 30, setTempC: -10, binning: 1,
                    width: 4, height: 4, channels: 1, frameCount: 20,
                    createdAt: Date(timeIntervalSince1970: 0), fileName: "unused.fit", sourcePath: nil)
    }
}
