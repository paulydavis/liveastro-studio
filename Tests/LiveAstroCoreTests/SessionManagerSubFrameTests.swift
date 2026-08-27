import XCTest
@testable import LiveAstroCore

final class SessionManagerSubFrameTests: XCTestCase {
    private func startedManager() throws -> (SessionManager, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mgr = SessionManager(rootDirectory: dir)
        _ = try mgr.startSession(profile: SessionProfile(targetName: "M63", subExposureSeconds: 20),
                                 masterExpected: true)
        return (mgr, dir)
    }

    private func rec(_ i: Int, rejected: Bool = false) -> SubFrameRecord {
        SubFrameRecord(index: i, timestamp: Date(timeIntervalSince1970: Double(i)),
                       sourceFile: "Light_\(i).fit", starCount: 100 + i, backgroundSigma: 1.5,
                       weight: 1.0, outcome: .stacked, rejectionReason: nil, rejectedByUser: rejected)
    }

    func testRecordSubFrameAppends() throws {
        let (mgr, _) = try startedManager()
        try mgr.recordSubFrame(rec(1))
        try mgr.recordSubFrame(rec(2))
        XCTAssertEqual(mgr.subFrames.map(\.index), [1, 2])
    }

    func testSetUserRejectedFlipsFlag() throws {
        let (mgr, _) = try startedManager()
        try mgr.recordSubFrame(rec(1))
        try mgr.setSubFrameUserRejected(index: 1, rejected: true)
        XCTAssertTrue(mgr.subFrames.first!.rejectedByUser)
        try mgr.setSubFrameUserRejected(index: 1, rejected: false)
        XCTAssertFalse(mgr.subFrames.first!.rejectedByUser)
    }

    func testSetUserRejectedUnknownIndexIsNoOp() throws {
        let (mgr, _) = try startedManager()
        try mgr.recordSubFrame(rec(1))
        try mgr.setSubFrameUserRejected(index: 999, rejected: true)   // must not throw
        XCTAssertFalse(mgr.subFrames.first!.rejectedByUser)
    }

    func testSetUserRejectedBeforeAnyRecordIsNoOp() throws {
        let (mgr, _) = try startedManager()
        XCTAssertNoThrow(try mgr.setSubFrameUserRejected(index: 1, rejected: true))
        XCTAssertTrue(mgr.subFrames.isEmpty)
    }

    func testSubFramesPersistAcrossReload() throws {
        let (mgr, _) = try startedManager()
        try mgr.recordSubFrame(rec(1, rejected: true))
        let data = try Data(contentsOf: mgr.sessionDirectory!.appendingPathComponent("manifest.json"))
        let reloaded = try ManifestCoding.decoder().decode(SessionManifest.self, from: data)
        XCTAssertEqual(reloaded.subFrames?.first?.rejectedByUser, true)
    }
}
