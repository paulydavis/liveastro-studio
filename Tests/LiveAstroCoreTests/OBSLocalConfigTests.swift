import XCTest
@testable import LiveAstroCore

final class OBSLocalConfigTests: XCTestCase {
    private func write(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("obs-ws-\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: url)
        return url
    }
    func testParsesNormalConfig() throws {
        let url = try write(#"{"server_enabled": true, "server_port": 4455, "server_password": "abc123", "auth_required": true}"#)
        let c = OBSLocalConfig.read(from: url)
        XCTAssertEqual(c, OBSLocalConfig(serverEnabled: true, port: 4455, password: "abc123"))
    }
    func testServerDisabled() throws {
        let url = try write(#"{"server_enabled": false, "server_port": 4455, "server_password": "abc"}"#)
        XCTAssertEqual(OBSLocalConfig.read(from: url)?.serverEnabled, false)
    }
    func testMissingFieldsUseDefaults() throws {
        // Absent port → 4455 default; absent password → nil; absent enabled → false.
        let url = try write(#"{}"#)
        let c = OBSLocalConfig.read(from: url)
        XCTAssertEqual(c, OBSLocalConfig(serverEnabled: false, port: 4455, password: nil))
    }
    func testCorruptFileReturnsNil() throws {
        let url = try write("not json {")
        XCTAssertNil(OBSLocalConfig.read(from: url))
    }
    func testAbsentFileReturnsNil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("definitely-missing-\(UUID().uuidString).json")
        XCTAssertNil(OBSLocalConfig.read(from: url))
    }
    func testDefaultURLPointsAtOBSPluginConfig() {
        XCTAssertTrue(OBSLocalConfig.defaultURL.path.hasSuffix(
            "Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json"))
    }

    // MARK: - activeProfileHasLinkedAccount (spec §3 amendment, 2026-08-06)
    //
    // OAuth account-linked services store NO stream key — their tokens live in
    // the active profile's basic.ini. Section/RefreshToken PRESENCE only; the
    // token value must never be stored, returned, or logged (the function
    // returns Bool and contains no logging — nothing here may add any).

    /// Build a fixture obs-root tree. `globalProfileDir` nil skips global.ini;
    /// `profiles` maps profile directory name → basic.ini content.
    private func makeOBSRoot(globalProfileDir: String?,
                             profiles: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obs-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("basic/profiles"),
            withIntermediateDirectories: true)
        if let dir = globalProfileDir {
            let ini = "[General]\nPro=false\n\n[Basic]\nProfile=Untitled\nProfileDir=\(dir)\nSceneCollection=Untitled\n"
            try Data(ini.utf8).write(to: root.appendingPathComponent("global.ini"))
        }
        for (dir, basicINI) in profiles {
            let profileDir = root.appendingPathComponent("basic/profiles/\(dir)")
            try FileManager.default.createDirectory(at: profileDir,
                                                    withIntermediateDirectories: true)
            try Data(basicINI.utf8).write(to: profileDir.appendingPathComponent("basic.ini"))
        }
        return root
    }

    func testLinkedYouTubeAccountViaGlobalINIIsDetected() throws {
        let root = try makeOBSRoot(globalProfileDir: "Untitled", profiles: [
            "Untitled": """
            [General]
            Name=Untitled

            [YouTube]
            RefreshToken=fixture-refresh-token-aa11
            DocID=fixture-doc
            """])
        XCTAssertTrue(OBSLocalConfig.activeProfileHasLinkedAccount(obsRoot: root))
    }

    func testEmptyRefreshTokenIsNotLinked() throws {
        let root = try makeOBSRoot(globalProfileDir: "Untitled", profiles: [
            "Untitled": "[General]\nName=Untitled\n\n[YouTube]\nRefreshToken=\n"])
        XCTAssertFalse(OBSLocalConfig.activeProfileHasLinkedAccount(obsRoot: root))
    }

    func testNoTokenSectionsIsNotLinked() throws {
        let root = try makeOBSRoot(globalProfileDir: "Untitled", profiles: [
            "Untitled": "[General]\nName=Untitled\n\n[Output]\nMode=Simple\n"])
        XCTAssertFalse(OBSLocalConfig.activeProfileHasLinkedAccount(obsRoot: root))
    }

    func testMissingGlobalINIFallsBackToSingleProfile() throws {
        // No global.ini, exactly one profile dir with a Twitch link → true.
        let root = try makeOBSRoot(globalProfileDir: nil, profiles: [
            "OnlyOne": "[General]\nName=OnlyOne\n\n[Twitch]\nRefreshToken=fixture-tw-tok\n"])
        XCTAssertTrue(OBSLocalConfig.activeProfileHasLinkedAccount(obsRoot: root))
    }

    func testMissingGlobalINIWithTwoProfilesIsNotLinked() throws {
        // Ambiguous active profile (no global.ini, two dirs): never guess.
        let root = try makeOBSRoot(globalProfileDir: nil, profiles: [
            "A": "[YouTube]\nRefreshToken=fixture-tok-a\n",
            "B": "[YouTube]\nRefreshToken=fixture-tok-b\n"])
        XCTAssertFalse(OBSLocalConfig.activeProfileHasLinkedAccount(obsRoot: root))
    }

    func testMissingEverythingIsNotLinked() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obs-root-missing-\(UUID().uuidString)")
        XCTAssertFalse(OBSLocalConfig.activeProfileHasLinkedAccount(obsRoot: root))
    }
}
