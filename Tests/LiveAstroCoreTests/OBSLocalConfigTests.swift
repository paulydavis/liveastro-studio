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
}
