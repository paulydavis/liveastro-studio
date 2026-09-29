import XCTest
@testable import LiveAstroCore
@testable import LiveAstroStudio

@MainActor final class StoreProcessorSettingsTests: XCTestCase {
    // Catches restoring a hidden, unavailable backend into the Store picker.
    func testStoreRestoresGraXpertAsNoneAndPersistsTheSupportedSelection() throws {
        let (model, defaults) = try fixture(store: true, saved: .graxpert)
        XCTAssertEqual(model.processorBackend, .none)
        model.saveSettings()
        XCTAssertEqual(SessionSettingsStore.load(defaults).processorBackend, .none)
        model.loadSettings()
        XCTAssertEqual(model.processorBackend, .none)
    }

    func testStorePreservesSupportedSavedChoices() throws {
        for backend in [ProcessorBackend.none, .nativeDenoise] {
            let (model, defaults) = try fixture(store: true, saved: backend)
            XCTAssertEqual(model.processorBackend, backend)
            model.saveSettings()
            XCTAssertEqual(SessionSettingsStore.load(defaults).processorBackend, backend)
        }
    }

    func testDirectEditionPreservesGraXpert() throws {
        let (model, defaults) = try fixture(store: false, saved: .graxpert)
        XCTAssertEqual(model.processorBackend, .graxpert)
        model.saveSettings()
        XCTAssertEqual(SessionSettingsStore.load(defaults).processorBackend, .graxpert)
    }

    private func fixture(store: Bool, saved: ProcessorBackend) throws -> (AppModel, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "StoreProcessorSettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        }
        var settings = SessionSettings.defaults
        settings.processorBackend = saved
        SessionSettingsStore.save(settings, to: defaults)
        let config = StorePreviewConfiguration(bundleIdentifier: store ? "com.pauldavis.liveastrostudio.store-preview" : "com.pauldavis.liveastrostudio", containerRoot: root)
        return (AppModel(userDefaults: defaults, calibrationLibrary: CalibrationLibrary(baseDirectory: root.appendingPathComponent("library")), configuration: config), defaults)
    }
}
