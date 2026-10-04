import XCTest
@testable import LiveAstroStudio

final class StoreDistributionCapabilityTests: XCTestCase {
    func testSandboxedEditionsKeepOBSStatusAndLocalRecording() {
        let preview = StorePreviewConfiguration(bundleIdentifier: "com.pauldavis.liveastrostudio.store-preview")
        let appStore = StorePreviewConfiguration(bundleIdentifier: "com.pauldavis.liveastrostudio.appstore")

        XCTAssertTrue(preview.supportsOBSStatus)
        XCTAssertTrue(preview.supportsOBSLocalRecording)
        XCTAssertTrue(appStore.supportsOBSStatus)
        XCTAssertTrue(appStore.supportsOBSLocalRecording)
    }

    func testSandboxedEditionsDoNotExposeDirectOnlyCapabilities() {
        let direct = StorePreviewConfiguration(bundleIdentifier: "com.pauldavis.liveastrostudio")
        let preview = StorePreviewConfiguration(bundleIdentifier: "com.pauldavis.liveastrostudio.store-preview")
        let appStore = StorePreviewConfiguration(bundleIdentifier: "com.pauldavis.liveastrostudio.appstore")

        XCTAssertTrue(direct.supportsExternalProcessor)
        XCTAssertTrue(direct.supportsPublicStreamAutomation)
        XCTAssertTrue(direct.supportsSceneAutomation)
        XCTAssertFalse(preview.supportsExternalProcessor)
        XCTAssertFalse(preview.supportsPublicStreamAutomation)
        XCTAssertFalse(preview.supportsSceneAutomation)
        XCTAssertFalse(appStore.supportsExternalProcessor)
        XCTAssertFalse(appStore.supportsPublicStreamAutomation)
        XCTAssertFalse(appStore.supportsSceneAutomation)
    }
}
