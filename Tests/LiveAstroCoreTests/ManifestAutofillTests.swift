import XCTest
@testable import LiveAstroCore

final class ManifestAutofillTests: XCTestCase {
    func testFillsBlankFieldsOnly() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let mgr = SessionManager(rootDirectory: tmp)
        // camera and telescope are blank; filter is user-set to "R"
        let profile = SessionProfile(
            targetName: "NGC 7000",
            telescope: "",
            camera: "",
            mount: "AM5N",
            filter: "R",
            locationLabel: "",
            subExposureSeconds: 300
        )
        try mgr.startSession(profile: profile)

        var meta = SourceMetadata()
        meta.instrument = "imx585"
        meta.telescope = "S30 Pro"
        meta.filter = "LP"
        mgr.fillMissingMetadata(from: meta)

        XCTAssertEqual(mgr.manifest?.camera, "imx585",    "blank camera should be filled from instrument")
        XCTAssertEqual(mgr.manifest?.telescope, "S30 Pro","blank telescope should be filled from meta")
        XCTAssertEqual(mgr.manifest?.filter, "R",         "user-set filter must not be overwritten")
    }

    func testNoOpWhenNoActiveSession() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let mgr = SessionManager(rootDirectory: tmp)
        var meta = SourceMetadata()
        meta.instrument = "imx585"
        // Should not crash or throw — manifest is nil
        mgr.fillMissingMetadata(from: meta)
        XCTAssertNil(mgr.manifest)
    }

    func testDoesNotOverwriteNonBlankCamera() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let mgr = SessionManager(rootDirectory: tmp)
        let profile = SessionProfile(
            targetName: "M42",
            telescope: "Askar 120",
            camera: "ASI2600",
            mount: "AM5N",
            filter: "",
            subExposureSeconds: 120
        )
        try mgr.startSession(profile: profile)

        var meta = SourceMetadata()
        meta.instrument = "imx585"
        meta.telescope = "S30 Pro"
        meta.filter = "LP"
        mgr.fillMissingMetadata(from: meta)

        // User-set values must not be overwritten
        XCTAssertEqual(mgr.manifest?.camera, "ASI2600")
        XCTAssertEqual(mgr.manifest?.telescope, "Askar 120")
        // Blank filter gets filled
        XCTAssertEqual(mgr.manifest?.filter, "LP")
    }
}
