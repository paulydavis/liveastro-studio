import XCTest
@testable import LiveAstroCore

final class SessionManifestSubFramesTests: XCTestCase {
    private func manifest() -> SessionManifest {
        SessionManifest(sessionId: "s1", targetName: "M63", startTime: Date(timeIntervalSince1970: 0),
                        endTime: nil, subExposureSeconds: 20, bortle: 4, locationLabel: "yard",
                        telescope: "Askar120", camera: "2600MC", mount: "AM5N", filter: "none",
                        notes: "", snapshots: [], masterExpected: true)
    }

    func testSubFramesRoundTrip() throws {
        var m = manifest()
        m.subFrames = [SubFrameRecord(index: 1, timestamp: Date(timeIntervalSince1970: 10),
                                      sourceFile: "a.fit", starCount: 100, backgroundSigma: 1.0,
                                      weight: 1.0, outcome: .reference, rejectionReason: nil,
                                      rejectedByUser: false)]
        let back = try JSONDecoder().decode(SessionManifest.self, from: try JSONEncoder().encode(m))
        XCTAssertEqual(back.subFrames?.count, 1)
        XCTAssertEqual(back.subFrames?.first?.outcome, .reference)
    }

    func testLegacyManifestWithoutSubFramesDecodesToNil() throws {
        // A manifest JSON that predates the field must decode with subFrames == nil.
        let m = manifest()
        var json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(m)) as! [String: Any]
        json.removeValue(forKey: "subFrames")
        let data = try JSONSerialization.data(withJSONObject: json)
        let back = try JSONDecoder().decode(SessionManifest.self, from: data)
        XCTAssertNil(back.subFrames)
    }
}
