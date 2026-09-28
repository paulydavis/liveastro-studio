import XCTest
import Darwin
@testable import LiveAstroCore

final class CameraShareDiscoveryTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func target(_ root: URL, _ path: String, age: Double = 0) throws -> URL {
        let dir = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var meta = SourceMetadata(); meta.exposureSeconds = 120
        try FITSWriter.float32(width: 2, height: 2, channels: 1, pixels: [0.1, 0.2, 0.3, 0.4], metadata: meta)
            .write(to: dir.appendingPathComponent("Light_M31_30.0s_IRCUT_20260927-010000.fit"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000 + age)], ofItemAtPath: dir.path)
        return dir
    }

    // Break caught: scanning siblings/parent rather than exactly the authorized share.
    func testBothCamerasIgnoreNewerTargetOutsideChosenShare() throws {
        for kind in CameraShareKind.allCases {
            let root = try root(), chosen = root.appendingPathComponent("chosen")
            let prefix = kind == .seestar ? "MyWorks/" : "Autorun/Light/"
            let suffix = kind == .seestar ? "_sub" : ""
            let wanted = try target(chosen, prefix + "M 31" + suffix)
            _ = try target(root, "other/" + prefix + "Wrong" + suffix, age: 100)
            let found = try XCTUnwrap(CameraShareDiscovery.detect(in: chosen, kind: kind))
            XCTAssertEqual(found.directory.path, wanted.path)
            XCTAssertEqual(found.name, "M 31")
            XCTAssertEqual(found.exposure, kind == .seestar ? 30 : 120)
        }
    }

    // Break caught: swallowing access/listing errors as an empty capture folder.
    func testMissingShareThrowsButReadableEmptyLayoutReturnsNoTarget() throws {
        for kind in CameraShareKind.allCases {
            let root = try root()
            XCTAssertThrowsError(try CameraShareDiscovery.detect(in: root.appendingPathComponent("absent"), kind: kind))
            try FileManager.default.createDirectory(at: root.appendingPathComponent(kind == .seestar ? "MyWorks" : "Autorun/Light"), withIntermediateDirectories: true)
            XCTAssertNil(try CameraShareDiscovery.detect(in: root, kind: kind))
        }
    }

    func testLinkedTargetCannotEscapeSelectedShare() throws {
        for kind in CameraShareKind.allCases {
            let root = try root(), chosen = root.appendingPathComponent("chosen")
            let outside = try target(root, "outside")
            let layout = chosen.appendingPathComponent(kind == .seestar ? "MyWorks" : "Autorun/Light")
            try FileManager.default.createDirectory(at: layout, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: layout.appendingPathComponent(kind == .seestar ? "escape_sub" : "escape"), withDestinationURL: outside)
            XCTAssertThrowsError(try CameraShareDiscovery.detect(in: chosen, kind: kind))
        }
    }

    func testASIAIRFITSLinkCannotReadHeaderOutsideSelectedShare() throws {
        let root = try root(), chosen = root.appendingPathComponent("chosen")
        let outside = try target(root, "outside")
        let dir = chosen.appendingPathComponent("Autorun/Light/M 31")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: outside, includingPropertiesForKeys: nil).first)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("escape.fit"), withDestinationURL: file)
        XCTAssertThrowsError(try CameraShareDiscovery.detect(in: chosen, kind: .asiair))
    }

    func testUnreadableASIAIRHeaderIsAnAccessFailureNotDefaultFITSession() throws {
        let root = try root()
        let dir = try target(root, "Autorun/Light/M 31")
        let original = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        let denied = dir.appendingPathComponent("only.fits")
        try FileManager.default.moveItem(at: original, to: denied)
        XCTAssertEqual(chmod(denied.path, 0), 0)
        defer { chmod(denied.path, 0o600) }
        XCTAssertThrowsError(try CameraShareDiscovery.detect(in: root, kind: .asiair))
    }

    // Break caught: an older readable header selecting the relay's extension
    // instead of the newest capture that is still being written.
    func testASIAIRPartialNewestHeaderKeepsItsExtensionWhenExposureFallsBack() throws {
        let root = try root()
        let dir = try target(root, "Autorun/Light/M 31")
        let older = dir.appendingPathComponent("Light_M31_30.0s_IRCUT_20260927-010000.fit")
        let newest = dir.appendingPathComponent("in-progress.fits")
        try Data().write(to: newest)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2000)], ofItemAtPath: newest.path)
        let found = try XCTUnwrap(CameraShareDiscovery.detect(in: root, kind: .asiair))
        XCTAssertEqual(found.fileExtension, "fits")
        XCTAssertEqual(found.exposure, 120)
    }

    func testASIAIRPartialHeaderKeepsObservedFITSExtension() throws {
        let root = try root(), dir = root.appendingPathComponent("Autorun/Light/M 31")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("in-progress.fits"))
        let found = try XCTUnwrap(CameraShareDiscovery.detect(in: root, kind: .asiair))
        XCTAssertEqual(found.fileExtension, "fits")
        XCTAssertNil(found.exposure)
    }
}
