import XCTest
@testable import LiveAstroCore

final class ASIAIRDetectorTests: XCTestCase {
    func tmp() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
    }

    /// Create <vol>/Autorun/Light/<target>/ and return that target folder URL.
    @discardableResult
    func makeTarget(_ vol: URL, _ target: String) throws -> URL {
        let dir = vol.appendingPathComponent("Autorun/Light/\(target)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write a 1-channel FITS carrying OBJECT/EXPTIME via SourceMetadata (mirrors LiveSourceMetadataTests).
    func writeFITS(_ dir: URL, _ name: String, object: String?, exposure: Double?) throws {
        var meta = SourceMetadata()
        meta.object = object
        meta.exposureSeconds = exposure
        let px = [Float](repeating: 0.1, count: 8 * 8)
        try FITSWriter.float32(width: 8, height: 8, channels: 1, pixels: px, metadata: meta)
            .write(to: dir.appendingPathComponent(name))
    }

    func testTargetIsFolderNameNewestWins() throws {
        let volumes = try tmp()
        let vol = volumes.appendingPathComponent("ASIAIR", isDirectory: true)
        let older = try makeTarget(vol, "NGC 7000")
        let newer = try makeTarget(vol, "M 31")
        try writeFITS(older, "a.fit", object: "x", exposure: 60)
        try writeFITS(newer, "b.fit", object: "y", exposure: 120)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: newer.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: older.path)

        let found = ASIAIRDetector.detect(volumesRoot: volumes)
        XCTAssertEqual(found?.target, "M 31")
        XCTAssertEqual(found?.subDir.lastPathComponent, "M 31")
    }

    func testExposureAndExtensionFromHeader() throws {
        let volumes = try tmp()
        let vol = volumes.appendingPathComponent("ASIAIR", isDirectory: true)
        let t = try makeTarget(vol, "M 42")
        try writeFITS(t, "light.fit", object: "M 42", exposure: 180)
        let found = ASIAIRDetector.detect(volumesRoot: volumes)
        XCTAssertEqual(found?.subExposure, 180)
        XCTAssertEqual(found?.subFileExtension, "fit")
    }

    func testIgnoresTargetFolderWithoutFITS() throws {
        let volumes = try tmp()
        let vol = volumes.appendingPathComponent("ASIAIR", isDirectory: true)
        let empty = try makeTarget(vol, "EMPTY")               // newer, but no FITS
        let withFits = try makeTarget(vol, "M 13")             // older, has FITS
        try writeFITS(withFits, "a.fit", object: "M 13", exposure: 90)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: empty.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: withFits.path)
        let found = ASIAIRDetector.detect(volumesRoot: volumes)
        XCTAssertEqual(found?.target, "M 13")   // containment guard beats "newest"
    }

    func testReturnsNilWhenNoAutorunLight() throws {
        let volumes = try tmp()
        let vol = volumes.appendingPathComponent("ASIAIR", isDirectory: true)
        try FileManager.default.createDirectory(at: vol.appendingPathComponent("SomethingElse"),
                                                withIntermediateDirectories: true)
        XCTAssertNil(ASIAIRDetector.detect(volumesRoot: volumes))
    }

    func testReturnsNilWhenNoFITSAnywhere() throws {
        let volumes = try tmp()
        let vol = volumes.appendingPathComponent("ASIAIR", isDirectory: true)
        let t = try makeTarget(vol, "M 45")
        try Data("nope".utf8).write(to: t.appendingPathComponent("readme.txt"))
        XCTAssertNil(ASIAIRDetector.detect(volumesRoot: volumes))
    }

    func testScansMultipleVolumes() throws {
        let volumes = try tmp()
        let volA = volumes.appendingPathComponent("EMPTYVOL", isDirectory: true)
        try FileManager.default.createDirectory(at: volA, withIntermediateDirectories: true)   // no Autorun/Light
        let volB = volumes.appendingPathComponent("ASIAIR", isDirectory: true)
        let t = try makeTarget(volB, "IC 1396")
        try writeFITS(t, "a.fit", object: "IC 1396", exposure: 300)
        let found = ASIAIRDetector.detect(volumesRoot: volumes)
        XCTAssertEqual(found?.target, "IC 1396")
    }

    func testFitsExtensionSupported() throws {
        let volumes = try tmp()
        let vol = volumes.appendingPathComponent("ASIAIR", isDirectory: true)
        let t = try makeTarget(vol, "M 8")
        try writeFITS(t, "a.fits", object: "M 8", exposure: 45)   // .fits, not .fit
        let found = ASIAIRDetector.detect(volumesRoot: volumes)
        XCTAssertEqual(found?.subFileExtension, "fits")
        XCTAssertEqual(found?.subExposure, 45)
    }
}
