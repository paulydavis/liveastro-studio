import XCTest
@testable import LiveAstroCore

final class SessionManagerTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private var profile: SessionProfile {
        SessionProfile(targetName: "NGC 6888 Crescent Nebula", telescope: "120 APO",
                       camera: "ASI2600MC Air", mount: "AM5N", filter: "Dual-band",
                       locationLabel: "Round Rock, TX", bortle: 7,
                       subExposureSeconds: 120, notes: "")
    }

    func testSessionIdSlug() {
        let d = ISO8601DateFormatter().date(from: "2026-07-05T22:15:00-05:00")!
        let id = SessionManager.sessionId(date: d, targetName: "NGC 6888")
        XCTAssertTrue(id.hasSuffix("-ngc6888"), "got \(id)")
        XCTAssertTrue(id.hasPrefix("2026-07-0")) // day depends on local zone; prefix is stable enough
    }

    func testStartCreatesDirectoryAndManifest() throws {
        let mgr = SessionManager(rootDirectory: tmp)
        let dir = try mgr.startSession(profile: profile)
        XCTAssertEqual(mgr.state, .running)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("snapshots").path))
        let json = try String(contentsOf: dir.appendingPathComponent("manifest.json"), encoding: .utf8)
        XCTAssertTrue(json.contains("\"session_id\""), "keys must be snake_case")
        XCTAssertTrue(json.contains("\"sub_exposure_seconds\""))
    }

    func testRecordSnapshotAppendsAndPersists() throws {
        let mgr = SessionManager(rootDirectory: tmp)
        let dir = try mgr.startSession(profile: profile)
        // Use an ISO8601-formatted date string to ensure millisecond-precision round-trip through encoding/decoding
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = iso.date(from: "2026-07-05T21:30:45.123Z")!
        let rec = SnapshotRecord(index: 1, timestamp: timestamp, sourceFile: "live_stack.fit",
                                 snapshotFile: "snapshots/0001.png",
                                 estimatedIntegrationSeconds: 120, width: 100, height: 80,
                                 mean: 0.1, median: 0.08, stddev: 0.02)
        try mgr.recordSnapshot(rec)
        XCTAssertEqual(mgr.acceptedCount, 1)
        XCTAssertEqual(mgr.estimatedIntegrationSeconds, 120)
        let data = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
        let loaded = try ManifestCoding.decoder().decode(SessionManifest.self, from: data)
        XCTAssertEqual(loaded.snapshots.count, 1)
        XCTAssertEqual(loaded.snapshots[0], rec)
    }

    func testEndSessionSetsEndTime() throws {
        let mgr = SessionManager(rootDirectory: tmp)
        let dir = try mgr.startSession(profile: profile)
        try mgr.endSession()
        XCTAssertEqual(mgr.state, .ended)
        let loaded = try ManifestCoding.decoder()
            .decode(SessionManifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        XCTAssertNotNil(loaded.endTime)
    }

    func testRecordBeforeStartThrows() {
        let mgr = SessionManager(rootDirectory: tmp)
        let rec = SnapshotRecord(index: 1, timestamp: Date(), sourceFile: "a", snapshotFile: "b",
                                 estimatedIntegrationSeconds: 0, width: 1, height: 1,
                                 mean: 0, median: 0, stddev: 0)
        XCTAssertThrowsError(try mgr.recordSnapshot(rec))
    }

    func testRecordAfterEndThrows() throws {
        let mgr = SessionManager(rootDirectory: tmp)
        _ = try mgr.startSession(profile: profile)
        try mgr.endSession()
        let rec = SnapshotRecord(index: 1, timestamp: Date(), sourceFile: "a", snapshotFile: "b",
                                 estimatedIntegrationSeconds: 0, width: 1, height: 1,
                                 mean: 0, median: 0, stddev: 0)
        XCTAssertThrowsError(try mgr.recordSnapshot(rec)) {
            XCTAssertEqual($0 as? SessionError, .notRunning)
        }
    }

    func testEndedManagerCanStartNewSession() throws {
        let mgr = SessionManager(rootDirectory: tmp)
        let dir1 = try mgr.startSession(profile: profile)
        try mgr.endSession()
        // Reuse across sessions is intentional (watcher-mode reuse in startSession).
        let dir2 = try mgr.startSession(profile: profile)
        XCTAssertEqual(mgr.state, .running)
        XCTAssertNotEqual(dir1, dir2)
    }

    func testCaptionFormat() {
        XCTAssertEqual(IntegrationFormat.caption(seconds: 8040, frames: 402, subSeconds: 20),
                       "2h 14m · 402 × 20s")
        XCTAssertEqual(IntegrationFormat.caption(seconds: 870, frames: 12, subSeconds: 72.5),
                       "14m 30s · 12 × 72.5s")
    }

    func testSessionDirCollisionUniquifiesAndPreservesFirst() throws {
        // Use a fixed date so both starts produce the same base session id.
        let date = ISO8601DateFormatter().date(from: "2026-07-05T22:15:00Z")!

        // First session: start and end.
        let mgr1 = SessionManager(rootDirectory: tmp)
        let dir1 = try mgr1.startSession(profile: profile, at: date)
        try mgr1.endSession()

        // Capture the first manifest before the second session is created.
        let manifest1Data = try Data(contentsOf: dir1.appendingPathComponent("manifest.json"))
        let manifest1 = try ManifestCoding.decoder().decode(SessionManifest.self, from: manifest1Data)

        // Second session with same profile + date (reuses same manager or a new one on same root).
        let mgr2 = SessionManager(rootDirectory: tmp)
        let dir2 = try mgr2.startSession(profile: profile, at: date)

        // The two directories must differ.
        XCTAssertNotEqual(dir1.lastPathComponent, dir2.lastPathComponent,
                          "second session must get a unique directory")

        // The second directory's manifest sessionId must match its directory name.
        let manifest2Data = try Data(contentsOf: dir2.appendingPathComponent("manifest.json"))
        let manifest2 = try ManifestCoding.decoder().decode(SessionManifest.self, from: manifest2Data)
        XCTAssertEqual(manifest2.sessionId, dir2.lastPathComponent,
                       "manifest sessionId must match directory name")

        // The first session's manifest.json must still be intact and decodable with its original id.
        let manifest1Again = try ManifestCoding.decoder().decode(SessionManifest.self, from:
            Data(contentsOf: dir1.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest1Again.sessionId, manifest1.sessionId,
                       "first session manifest must be untouched")
    }

    func testManifestCodingDecodesOffsetAndFractionalDates() throws {
        // Test offset-style date (no fractional seconds)
        let offsetDateStr = "2026-07-05T22:15:00-05:00"
        let offsetFormatter = ISO8601DateFormatter()
        offsetFormatter.formatOptions = [.withInternetDateTime]
        let expectedOffsetDate = offsetFormatter.date(from: offsetDateStr)!

        // Test fractional date (with microseconds)
        let fractionalDateStr = "2026-07-05T03:15:00.123456Z"
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expectedFractionalDate = fractionalFormatter.date(from: fractionalDateStr)!

        // Build minimal manifest JSON with each date format
        let manifestWithOffset = """
        {
          "session_id": "test-session",
          "target_name": "NGC 6888",
          "start_time": "\(offsetDateStr)",
          "end_time": null,
          "sub_exposure_seconds": 120,
          "bortle": 7,
          "location_label": "Test",
          "telescope": "120 APO",
          "camera": "ASI2600MC",
          "mount": "AM5N",
          "filter": "Dual-band",
          "notes": "",
          "snapshots": []
        }
        """

        let manifestWithFractional = """
        {
          "session_id": "test-session",
          "target_name": "NGC 6888",
          "start_time": "\(fractionalDateStr)",
          "end_time": null,
          "sub_exposure_seconds": 120,
          "bortle": 7,
          "location_label": "Test",
          "telescope": "120 APO",
          "camera": "ASI2600MC",
          "mount": "AM5N",
          "filter": "Dual-band",
          "notes": "",
          "snapshots": []
        }
        """

        // Verify both decode successfully
        let decodedOffset = try ManifestCoding.decoder()
            .decode(SessionManifest.self, from: manifestWithOffset.data(using: .utf8)!)
        XCTAssertEqual(decodedOffset.startTime, expectedOffsetDate)

        let decodedFractional = try ManifestCoding.decoder()
            .decode(SessionManifest.self, from: manifestWithFractional.data(using: .utf8)!)
        XCTAssertEqual(decodedFractional.startTime, expectedFractionalDate)
    }
}
