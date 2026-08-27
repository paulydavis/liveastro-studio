import XCTest
@testable import LiveAstroCore

final class SubFrameRecordTests: XCTestCase {
    func testCodableRoundTripPreservesAllFields() throws {
        let r = SubFrameRecord(index: 7, timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                               sourceFile: "Light_007.fit", starCount: 212, backgroundSigma: 1.83,
                               weight: 1.94, outcome: .stacked, rejectionReason: nil, rejectedByUser: false)
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(SubFrameRecord.self, from: data)
        XCTAssertEqual(back, r)
    }

    func testRejectedRecordCarriesReason() throws {
        let r = SubFrameRecord(index: 3, timestamp: Date(timeIntervalSince1970: 0),
                               sourceFile: "Light_003.fit", starCount: 2, backgroundSigma: 4.1,
                               weight: 0, outcome: .rejected, rejectionReason: "insufficientStars(found: 2)",
                               rejectedByUser: false)
        let back = try JSONDecoder().decode(SubFrameRecord.self, from: try JSONEncoder().encode(r))
        XCTAssertEqual(back.outcome, .rejected)
        XCTAssertEqual(back.rejectionReason, "insufficientStars(found: 2)")
    }

    func testRejectedByUserIsMutable() {
        var r = SubFrameRecord(index: 1, timestamp: Date(timeIntervalSince1970: 0),
                               sourceFile: "a.fit", starCount: 100, backgroundSigma: 1.0,
                               weight: 1.0, outcome: .stacked, rejectionReason: nil, rejectedByUser: false)
        r.rejectedByUser = true
        XCTAssertTrue(r.rejectedByUser)
    }
}
