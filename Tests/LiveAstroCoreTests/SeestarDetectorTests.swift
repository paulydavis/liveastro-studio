import XCTest
@testable import LiveAstroCore

final class SeestarDetectorTests: XCTestCase {
    func tmp() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
    }

    func testParseExposure() {
        XCTAssertEqual(SeestarDetector.parseExposure(fromFilename: "Light_M 8_10.0s_LP_x.fit"), 10.0)
        XCTAssertEqual(SeestarDetector.parseExposure(fromFilename: "Light_NGC 7000_20.0s_LP_x.fit"), 20.0)
        XCTAssertNil(SeestarDetector.parseExposure(fromFilename: "nope.fit"))
    }

    func testDetectPicksNewestSubFolder() throws {
        let vols = try tmp()
        let works = vols.appendingPathComponent("EMMC Images/MyWorks")
        try FileManager.default.createDirectory(at: works, withIntermediateDirectories: true)
        let older = works.appendingPathComponent("NGC 7000_sub")
        let newer = works.appendingPathComponent("M 8_sub")
        for d in [older, newer] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data(count: 8).write(to: newer.appendingPathComponent("Light_M 8_10.0s_LP_1.fit"))
        // make `newer` the most-recently-modified
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: newer.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: older.path)

        let found = SeestarDetector.detect(volumesRoot: vols)
        XCTAssertEqual(found?.target, "M 8")
        XCTAssertEqual(found?.subExposure, 10.0)
        XCTAssertEqual(found?.subDir.lastPathComponent, "M 8_sub")
    }

    func testDetectReturnsNilWhenNoSub() throws {
        XCTAssertNil(SeestarDetector.detect(volumesRoot: try tmp()))
    }
}
