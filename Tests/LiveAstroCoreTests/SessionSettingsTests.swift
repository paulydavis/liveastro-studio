import XCTest
@testable import LiveAstroCore

final class SessionSettingsTests: XCTestCase {
    func defaults() -> UserDefaults { UserDefaults(suiteName: "seamless-\(UUID().uuidString)")! }

    func testDefaultsWhenEmpty() {
        let s = SessionSettingsStore.load(defaults())
        XCTAssertEqual(s, SessionSettings.defaults)
        XCTAssertEqual(s.filePrefix, "live_stack")
        XCTAssertEqual(s.subExposureSeconds, 60)
    }

    func testRoundTrip() {
        let d = defaults()
        var s = SessionSettings.defaults
        s.sourceModeRaw = "Raw subs (native stacking)"
        s.filePrefix = "Light_"; s.neutralizeBackground = true; s.subExposureSeconds = 10
        s.targetName = "M8 Lagoon"; s.watchFolderPath = "/x/y"
        s.calibration = CalibrationSelection(darkPath: "/m/dark.fit", flatPath: nil, biasPath: nil)
        SessionSettingsStore.save(s, to: d)
        XCTAssertEqual(SessionSettingsStore.load(d), s)
    }

    func testCorruptDataFallsBackToDefaults() {
        let d = defaults()
        d.set(Data([0x00, 0x01]), forKey: "sessionSettings.v1")
        XCTAssertEqual(SessionSettingsStore.load(d), SessionSettings.defaults)
    }

    func testRejectionDefaults() {
        let d = SessionSettings.defaults
        XCTAssertTrue(d.rejectionEnabled)
        XCTAssertEqual(d.rejectionStrength, .medium)
    }

    func testRejectionRoundTrips() {
        let dd = defaults()
        var s = SessionSettings.defaults
        s.rejectionEnabled = false; s.rejectionStrength = .high
        SessionSettingsStore.save(s, to: dd)
        XCTAssertEqual(SessionSettingsStore.load(dd), s)
    }

    func testOldBlobWithoutRejectionKeysDecodesToDefaults() throws {
        // an older SessionSettings JSON (no rejection keys) must decode with rejection
        // defaults rather than failing the whole load and wiping other settings.
        let dd = defaults()
        let json = """
        {"sourceModeRaw":"Raw subs (native stacking)","watchFolderPath":null,
         "filePrefix":"Light_","neutralizeBackground":true,"subExposureSeconds":10,
         "targetName":"M8","calibration":{"darkPath":null,"flatPath":null,"biasPath":null}}
        """
        dd.set(Data(json.utf8), forKey: "sessionSettings.v1")
        let loaded = SessionSettingsStore.load(dd)
        XCTAssertEqual(loaded.targetName, "M8")            // old fields preserved
        XCTAssertTrue(loaded.rejectionEnabled)              // new fields defaulted
        XCTAssertEqual(loaded.rejectionStrength, .medium)
    }

    func testProcessorBackendDefaultAndRoundTrip() throws {
        XCTAssertEqual(SessionSettings.defaults.processorBackend, .none)
        var s = SessionSettings.defaults
        s.processorBackend = .graxpert
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(SessionSettings.self, from: data).processorBackend, .graxpert)
    }

    func testOldBlobWithoutProcessorBackendDecodesToNone() throws {
        // A prior-version blob: has the existing keys but NOT processorBackend.
        let json = """
        {"sourceModeRaw":"Raw subs (native stacking)","watchFolderPath":null,
         "filePrefix":"Light_","neutralizeBackground":true,"subExposureSeconds":10,
         "targetName":"M8","calibration":{"darkPath":null,"flatPath":null,"biasPath":null},
         "rejectionEnabled":true,"rejectionStrength":"medium"}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(SessionSettings.self, from: json)
        XCTAssertEqual(s.processorBackend, .none)     // missing key -> default
        XCTAssertEqual(s.targetName, "M8")            // existing fields intact
    }
}
