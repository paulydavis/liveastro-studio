import XCTest
@testable import LiveAstroCore

final class SubFrameCSVTests: XCTestCase {
    func testEmptyRecordsYieldsHeaderOnly() {
        let csv = SubFrameCSV.string(from: [])
        XCTAssertEqual(csv, "index,timestamp,source_file,star_count,background_sigma,weight,outcome,rejection_reason,rejected_by_user\n")
    }

    func testRowFormatting() {
        let r = SubFrameRecord(index: 5, timestamp: Date(timeIntervalSince1970: 0),
                               sourceFile: "Light_005.fit", starCount: 180, backgroundSigma: 1.5,
                               weight: 1.25, outcome: .stacked, rejectionReason: nil, rejectedByUser: true)
        let csv = SubFrameCSV.string(from: [r])
        let row = csv.split(separator: "\n").last!
        XCTAssertTrue(row.hasPrefix("5,"))
        XCTAssertTrue(row.contains("Light_005.fit"))
        XCTAssertTrue(row.contains("180"))
        XCTAssertTrue(row.contains("stacked"))
        XCTAssertTrue(row.hasSuffix("true"))
    }

    func testCommaInReasonIsQuoted() {
        let r = SubFrameRecord(index: 1, timestamp: Date(timeIntervalSince1970: 0),
                               sourceFile: "a.fit", starCount: 2, backgroundSigma: 4.0, weight: 0,
                               outcome: .rejected, rejectionReason: "insufficientStars, found 2",
                               rejectedByUser: false)
        let row = SubFrameCSV.string(from: [r]).split(separator: "\n").last!
        XCTAssertTrue(row.contains("\"insufficientStars, found 2\""))
    }
}
