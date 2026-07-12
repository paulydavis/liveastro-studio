import XCTest
@testable import LiveAstroCore

final class LiveSourceMetadataTests: XCTestCase {
    func tmp() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
    }
    // Write a 1-channel FITS carrying OBJECT/EXPTIME headers via SourceMetadata.
    func writeFITS(_ dir: URL, _ name: String, object: String?, exposure: Double?) throws {
        var meta = SourceMetadata()
        meta.object = object
        meta.exposureSeconds = exposure
        let px = [Float](repeating: 0.1, count: 8 * 8)
        try FITSWriter.float32(width: 8, height: 8, channels: 1, pixels: px, metadata: meta)
            .write(to: dir.appendingPathComponent(name))
    }

    func testReadsNewestFITSObjectAndExposure() throws {
        let dir = try tmp()
        try writeFITS(dir, "a.fit", object: "OLD", exposure: 10)
        // ensure b is newer
        try writeFITS(dir, "b.fit", object: "NGC 6960", exposure: 30)
        try FileManager.default.setAttributes([.modificationDate: Date()],
            ofItemAtPath: dir.appendingPathComponent("b.fit").path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)],
            ofItemAtPath: dir.appendingPathComponent("a.fit").path)
        let m = LiveSourceMetadata.newestFITSMetadata(inFolder: dir)
        XCTAssertEqual(m?.object, "NGC 6960")
        XCTAssertEqual(m?.exposureSeconds, 30)
        XCTAssertEqual(m?.fileExtension, "fit")
    }

    func testNoFITSReturnsNil() throws {
        let dir = try tmp()
        try Data("not fits".utf8).write(to: dir.appendingPathComponent("readme.txt"))
        XCTAssertNil(LiveSourceMetadata.newestFITSMetadata(inFolder: dir))
    }

    func testHandlesFitsExtension() throws {
        let dir = try tmp()
        try writeFITS(dir, "x.fits", object: "M8", exposure: 20)   // .fits extension
        let m = LiveSourceMetadata.newestFITSMetadata(inFolder: dir)
        XCTAssertEqual(m?.object, "M8")
        XCTAssertEqual(m?.exposureSeconds, 20)
        XCTAssertEqual(m?.fileExtension, "fits")   // caller builds "*.fits" glob from this
    }
}
