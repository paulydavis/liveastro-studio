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

    func testCodableRoundTripPreservesIdentity() throws {
        let id = FileIdentity(dev: 21, ino: 555, size: 6_312_960, mtimeSec: 1_700_000_001,
                              mtimeNsec: 42, digest: "abc123")
        let r = SubFrameRecord(index: 9, timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                               sourceFile: "Light_009.fit", starCount: 300, backgroundSigma: 1.1,
                               weight: 1.0, outcome: .stacked, rejectionReason: nil,
                               rejectedByUser: false, identity: id)
        let back = try JSONDecoder().decode(SubFrameRecord.self, from: try JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
        XCTAssertEqual(back.identity, id)
    }

    /// Back-compat: a LEGACY manifest record written before the `identity` field existed (no
    /// `identity` key) must decode to `identity == nil`, so old sessions re-stack unverified
    /// rather than failing to load.
    func testLegacyJSONWithoutIdentityDecodesToNil() throws {
        let legacyJSON = """
        {"index":4,"timestamp":0,"sourceFile":"Light_004.fit","starCount":150,
         "backgroundSigma":1.5,"weight":1.0,"outcome":"stacked","rejectedByUser":false}
        """
        let back = try JSONDecoder().decode(SubFrameRecord.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(back.identity)
        XCTAssertEqual(back.sourceFile, "Light_004.fit")
        XCTAssertEqual(back.outcome, .stacked)
    }

    func testRejectedByUserIsMutable() {
        var r = SubFrameRecord(index: 1, timestamp: Date(timeIntervalSince1970: 0),
                               sourceFile: "a.fit", starCount: 100, backgroundSigma: 1.0,
                               weight: 1.0, outcome: .stacked, rejectionReason: nil, rejectedByUser: false)
        r.rejectedByUser = true
        XCTAssertTrue(r.rejectedByUser)
    }
}
