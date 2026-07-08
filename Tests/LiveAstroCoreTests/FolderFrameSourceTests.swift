import XCTest
@testable import LiveAstroCore

final class FolderFrameSourceTests: XCTestCase {
    func writeFITS(_ dir: URL, name: String, value: Float) throws -> URL {
        let px = [Float](repeating: value, count: 64 * 32)
        let data = FITSWriter.float32(width: 64, height: 32, channels: 1, pixels: px)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testImportOnceYieldsSortedFramesAndFinishes() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writeFITS(dir, name: "Light_B_002.fit", value: 0.2)
        _ = try writeFITS(dir, name: "Light_A_001.fit", value: 0.1)
        try "x".write(to: dir.appendingPathComponent("ignore.txt"),
                      atomically: true, encoding: .utf8)   // non-FITS ignored

        let source = FolderFrameSource(folder: dir, mode: .importOnce, fileNamePrefix: "Light_")
        try source.start()
        var names: [String] = []
        for await frame in source.frames { names.append(frame.sourceName) }
        XCTAssertEqual(names, ["Light_A_001.fit", "Light_B_002.fit"])
    }

    func testLoadRawFrameKeepsStoredOrderAndMetadata() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writeFITS(dir, name: "sub.fit", value: 0.5)
        let frame = try FolderFrameSource.loadRawFrame(url: url)
        XCTAssertEqual(frame.image.channels, 1)
        XCTAssertEqual(frame.image.width, 64)
        XCTAssertEqual(frame.sourceName, "sub.fit")
        XCTAssertNil(frame.bayerPattern)   // FITSWriter emits no BAYERPAT
    }

    func testLiveModeForwardsNewFiles() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = FolderFrameSource(folder: dir, mode: .live, fileNamePrefix: "Light_")
        try source.start()
        _ = try writeFITS(dir, name: "Light_live_001.fit", value: 0.3)
        var got: RawFrame?
        for await frame in source.frames { got = frame; break }
        source.stop()
        XCTAssertEqual(got?.sourceName, "Light_live_001.fit")
    }
}
