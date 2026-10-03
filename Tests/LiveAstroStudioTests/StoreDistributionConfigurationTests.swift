import XCTest
@testable import LiveAstroStudio

final class StoreDistributionConfigurationTests: XCTestCase {
    func testBundleIdentifiersSelectTheirDistributionKinds() {
        let direct = StorePreviewConfiguration(bundleIdentifier: "com.pauldavis.liveastrostudio")
        let preview = StorePreviewConfiguration(bundleIdentifier: "com.pauldavis.liveastrostudio.store-preview")
        let appStore = StorePreviewConfiguration(bundleIdentifier: "com.pauldavis.liveastrostudio.appstore")

        XCTAssertEqual(direct.distribution, .direct)
        XCTAssertEqual(preview.distribution, .storePreview)
        XCTAssertEqual(appStore.distribution, .appStore)
    }

    func testOnlySandboxedDistributionsUseSandboxedStorageAndAccess() {
        let direct = StorePreviewConfiguration(bundleIdentifier: "com.pauldavis.liveastrostudio")
        let preview = StorePreviewConfiguration(bundleIdentifier: "com.pauldavis.liveastrostudio.store-preview")
        let appStore = StorePreviewConfiguration(bundleIdentifier: "com.pauldavis.liveastrostudio.appstore")

        XCTAssertFalse(direct.isSandboxedDistribution)
        XCTAssertTrue(preview.isSandboxedDistribution)
        XCTAssertTrue(appStore.isSandboxedDistribution)
        XCTAssertFalse(direct.isStorePreview)
        XCTAssertTrue(preview.isStorePreview)
        XCTAssertFalse(appStore.isStorePreview)
    }
}
