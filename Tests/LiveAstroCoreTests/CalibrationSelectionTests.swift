import XCTest
@testable import LiveAstroCore

final class CalibrationSelectionTests: XCTestCase {
    func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "cal-test-\(UUID().uuidString)")!
        return d
    }

    func testSelectionRoundTripsThroughUserDefaults() {
        let d = defaults()
        let sel = CalibrationSelection(darkPath: "/m/dark.fit", flatPath: "/m/flat.fit", biasPath: nil)
        CalibrationStore.save(sel, to: d)
        XCTAssertEqual(CalibrationStore.load(d), sel)
    }

    func testEmptySelectionByDefault() {
        XCTAssertEqual(CalibrationStore.load(defaults()),
                       CalibrationSelection(darkPath: nil, flatPath: nil, biasPath: nil))
    }

    func testMakeCalibratorNilWhenNoMasters() {
        let (cal, warnings) = CalibrationLoader.makeCalibrator(dark: nil, flat: nil)
        XCTAssertNil(cal); XCTAssertTrue(warnings.isEmpty)
    }

    func testMakeCalibratorWarnsOnMissingFile() {
        let missing = URL(fileURLWithPath: "/nope/dark.fit")
        let (cal, warnings) = CalibrationLoader.makeCalibrator(dark: missing, flat: nil)
        XCTAssertNil(cal)
        XCTAssertEqual(warnings.count, 1)
    }

    func testMakeCalibratorLoadsRealMaster() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("dark.fit")
        try MasterBuilder.save(AstroImage(width: 2, height: 2, channels: 1,
                                          pixels: [0.1, 0.1, 0.1, 0.1], sourceIsLinear: true), to: url)
        let (cal, warnings) = CalibrationLoader.makeCalibrator(dark: url, flat: nil)
        XCTAssertNotNil(cal); XCTAssertTrue(warnings.isEmpty)
    }
}
