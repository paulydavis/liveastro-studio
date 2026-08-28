import XCTest
@testable import LiveAstroCore

/// Codable conformance is what lets a `FileIdentity` ride inside a persisted `SubFrameRecord`
/// (manifest.json) so a re-stack can content-verify a recorded sub. These pin the round-trip
/// with and without a digest.
final class FileIdentityTests: XCTestCase {
    func testCodableRoundTripWithoutDigest() throws {
        let id = FileIdentity(dev: 42, ino: 1_000_003, size: 6_312_960,
                              mtimeSec: 1_700_000_000, mtimeNsec: 123_456_789)
        let back = try JSONDecoder().decode(FileIdentity.self, from: JSONEncoder().encode(id))
        XCTAssertEqual(back, id)
        XCTAssertNil(back.digest)
    }

    func testCodableRoundTripWithDigest() throws {
        let id = FileIdentity(dev: 1, ino: 2, size: 3, mtimeSec: 4, mtimeNsec: 5,
                              digest: "deadbeefcafef00d")
        let back = try JSONDecoder().decode(FileIdentity.self, from: JSONEncoder().encode(id))
        XCTAssertEqual(back, id)
        XCTAssertEqual(back.digest, "deadbeefcafef00d")
    }
}
