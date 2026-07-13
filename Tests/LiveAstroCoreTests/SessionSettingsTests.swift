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

final class SessionSettingsDisplayAdjTests: XCTestCase {
    func testDefaultsHaveNeutralAdjustments() {
        XCTAssertEqual(SessionSettings.defaults.displayAdjustments, .neutral)
    }

    func testRoundTripPreservesAdjustments() throws {
        var s = SessionSettings.defaults
        s.displayAdjustments = DisplayAdjustments(blackPoint: 0.05, midtoneStrength: 0.3, saturation: 1.4)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(SessionSettings.self, from: data)
        XCTAssertEqual(back.displayAdjustments, s.displayAdjustments)
    }

    func testOldBlobWithoutKeyDecodesNeutral() throws {
        // A settings JSON written before this field existed must decode to neutral.
        let json = """
        {"sourceModeRaw":"nativeStack","filePrefix":"Light_","neutralizeBackground":true,
         "subExposureSeconds":30,"targetName":"NGC 6960",
         "calibration":\(try calibrationJSON()),
         "rejectionEnabled":true,"rejectionStrength":"medium","processorBackend":"none"}
        """
        let s = try JSONDecoder().decode(SessionSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.displayAdjustments, .neutral)
    }

    func testFrameWeightingDefaultsTrueAndBackwardCompat() throws {
        // An old settings blob without the key decodes to true (default on).
        let old = #"{"sourceModeRaw":"Raw subs (native stacking)","filePrefix":"Light_","neutralizeBackground":false,"subExposureSeconds":10,"targetName":"M8","calibration":{},"rejectionEnabled":true,"rejectionStrength":"medium"}"#
        let s = try JSONDecoder().decode(SessionSettings.self, from: Data(old.utf8))
        XCTAssertTrue(s.frameWeightingEnabled)
    }

    func testBackgroundNormalizationDefaultsOnAndRoundTrips() throws {
        var s = SessionSettings()
        XCTAssertTrue(s.backgroundNormalizationEnabled)               // default on
        s.backgroundNormalizationEnabled = false
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(SessionSettings.self, from: data)
        XCTAssertFalse(back.backgroundNormalizationEnabled)
    }

    func testBackgroundNormalizationBackwardCompatDefaultsOn() throws {
        let json = #"{"sourceModeRaw":"Raw subs (native stacking)","filePrefix":"Light_","neutralizeBackground":false,"subExposureSeconds":60,"targetName":"","calibration":{},"rejectionEnabled":true}"#
        let s = try JSONDecoder().decode(SessionSettings.self, from: Data(json.utf8))
        XCTAssertTrue(s.backgroundNormalizationEnabled)
    }

    // Encode the current default calibration so the old-blob JSON stays valid if
    // CalibrationSelection's shape changes.
    private func calibrationJSON() throws -> String {
        String(data: try JSONEncoder().encode(SessionSettings.defaults.calibration), encoding: .utf8)!
    }
}
