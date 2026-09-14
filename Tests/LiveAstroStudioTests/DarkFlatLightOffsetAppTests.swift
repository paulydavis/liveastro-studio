import XCTest
@testable import LiveAstroStudio
@testable import LiveAstroCore

@MainActor
final class DarkFlatLightOffsetAppTests: XCTestCase {
    private func fixture() throws -> (AppModel, URL, SourceMetadata) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "DarkFlatLightOffsetAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try FileManager.default.removeItem(at: root)
        }
        let model = AppModel(userDefaults: defaults, calibrationLibrary: CalibrationLibrary(baseDirectory: root.appendingPathComponent("library")))
        let flats = root.appendingPathComponent("flats"), offsets = root.appendingPathComponent("offsets")
        try FileManager.default.createDirectory(at: flats, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: offsets, withIntermediateDirectories: true)
        try FITSWriter.float32(width: 4, height: 4, channels: 1, pixels: Array(repeating: 0.5, count: 16), bottomUp: false)
            .write(to: flats.appendingPathComponent("flat.fit"))
        try FITSWriter.float32(width: 4, height: 4, channels: 1, pixels: Array(repeating: 0.1, count: 16), bottomUp: false)
            .write(to: offsets.appendingPathComponent("offset.fit"))
        let light = root.appendingPathComponent("Light_001.fit")
        try FITSWriter.float32(width: 4, height: 4, channels: 1, pixels: Array(repeating: 0.3, count: 16), bottomUp: false)
            .write(to: light)
        let metadata = SourceMetadata(fitsKeywords: try FITSReader.readHeader(Data(contentsOf: light)).keywords)
        model.sessionFlatsFolder = flats; model.sessionDarkFlatsFolder = offsets
        return (model, root, metadata)
    }
    private func value(_ cal: Calibrator?) throws -> Float {
        let raw = RawFrame(image: AstroImage(width: 4, height: 4, channels: 1, pixels: Array(repeating: 0.3, count: 16), sourceIsLinear: true),
                           bayerPattern: .rggb, bottomUp: false, timestamp: Date(), sourceName: "Light_001.fit")
        return try XCTUnwrap(cal).apply(raw).image.pixels[0]
    }
    // Break: UI flag not forwarded to the populated-folder resolution path.
    func testPopulatedFolderResolvesOptInAndReportsOffsetNotDark() throws {
        let (model, root, _) = try fixture()
        model.useDarkFlatAsLightOffset = true
        let r = model.resolveCalibration(watchFolder: root, prefix: "Light_")
        XCTAssertTrue(r.foundMetadata)
        XCTAssertEqual(try value(r.calibrator), 0.2, accuracy: 0.00001)
        XCTAssertTrue(model.calibrationStatus.contains("light offset"))
        XCTAssertFalse(model.calibrationStatus.contains("dark + flat"))
    }
    // Break: provider forgets the option, or rereads the next session's option at first sub.
    func testFirstSubProviderCapturesOptInAtStart() throws {
        let (model, _, metadata) = try fixture()
        model.useDarkFlatAsLightOffset = true
        let provider = model.makeCalibratorProvider()
        model.useDarkFlatAsLightOffset = false
        XCTAssertEqual(try value(provider(metadata)), 0.2, accuracy: 0.00001)
    }
    func testFirstSubProviderDoesNotAdoptLaterOptIn() throws {
        let (model, _, metadata) = try fixture()
        let provider = model.makeCalibratorProvider()
        model.useDarkFlatAsLightOffset = true
        XCTAssertEqual(try value(provider(metadata)), 0.3, accuracy: 0.00001)
    }
    // Break: enabling the new fallback silently for an existing workflow.
    func testDefaultDoesNotSubtractLightOffset() throws {
        let (model, root, _) = try fixture()
        let r = model.resolveCalibration(watchFolder: root, prefix: "Light_")
        XCTAssertEqual(try value(r.calibrator), 0.3, accuracy: 0.00001)
        XCTAssertFalse(model.calibrationStatus.contains("light offset"))
    }
}
