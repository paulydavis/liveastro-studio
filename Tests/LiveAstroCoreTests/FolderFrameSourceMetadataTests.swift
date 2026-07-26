import XCTest
@testable import LiveAstroCore

final class FolderFrameSourceMetadataTests: XCTestCase {
    func testFrameCarriesSourceMetadata() throws {
        // Write a temp FITS sub with astro cards, point the source at it, read one frame.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var m = SourceMetadata()
        m.object = "NGC 6960"; m.ra = 314.36667; m.filter = "LP"; m.focalLengthMM = 160
        let fits = FITSWriter.float32(width: 2, height: 2, channels: 1,
                                     pixels: [0.1, 0.2, 0.3, 0.4], metadata: m)
        try fits.write(to: dir.appendingPathComponent("Light_NGC6960_30s_LP_0001.fit"))

        let frame = try FolderFrameSource.loadRawFrame(
            url: dir.appendingPathComponent("Light_NGC6960_30s_LP_0001.fit"))
        XCTAssertEqual(frame.metadata?.object, "NGC 6960")
        XCTAssertEqual(frame.metadata?.ra ?? 0, 314.36667, accuracy: 1e-5)
        XCTAssertEqual(frame.metadata?.filter, "LP")
    }

    func testDateObsWithoutTimezoneParsesAsUTCInsteadOfFallingBackToFileMTime() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var metadata = SourceMetadata()
        metadata.dateObs = "2026-07-10T03:51:36.210844"
        let url = dir.appendingPathComponent("Light_dateobs.fit")
        let fits = FITSWriter.float32(width: 2, height: 2, channels: 1,
                                      pixels: [0.1, 0.2, 0.3, 0.4],
                                      metadata: metadata)
        try fits.write(to: url)
        let fallbackMTime = Date(timeIntervalSince1970: 100)
        try FileManager.default.setAttributes([.modificationDate: fallbackMTime],
                                              ofItemAtPath: url.path)

        let frame = try FolderFrameSource.loadRawFrame(url: url)

        XCTAssertEqual(frame.timestamp.timeIntervalSince1970, 1_783_655_496.210844, accuracy: 0.001)
        XCTAssertNotEqual(frame.timestamp, fallbackMTime)
    }
}
