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
}
