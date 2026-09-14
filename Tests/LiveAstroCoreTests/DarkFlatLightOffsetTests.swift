import XCTest
@testable import LiveAstroCore

final class DarkFlatLightOffsetTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func folder(_ name: String, pixels: [Float], width: Int = 4, channels: Int = 1) throws -> URL {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FITSWriter.float32(width: width, height: 4, channels: channels, pixels: pixels, bottomUp: false)
            .write(to: dir.appendingPathComponent("frame.fit"))
        return dir
    }
    private var metadata: SourceMetadata {
        var m = SourceMetadata()
        m.instrument = "OffsetTest"; m.gain = 100; m.exposureSeconds = 300
        m.setTempC = -10; m.binning = 1; m.width = 4; m.height = 4; m.channels = 1
        return m
    }
    private func resolve(enabled: Bool = false, dark: String? = nil, flats: URL?, offset: URL?,
                         library: CalibrationLibrary? = nil) -> CalibrationResolver.Resolution {
        CalibrationResolver.resolve(metadata: metadata,
            library: library ?? CalibrationLibrary(baseDirectory: root.appendingPathComponent("library")),
            scaleEnabled: true, flatsFolder: flats, darkFlatsFolder: offset,
            legacyDarkPath: dark, legacyFlatPath: nil, useDarkFlatAsLightOffset: enabled)
    }
    private func output(_ resolution: CalibrationResolver.Resolution, bottomUp: Bool = false) throws -> [Float] {
        let cal = try XCTUnwrap(resolution.calibrator)
        // Offset .1 plus uniform sky .2 attenuated to .1 in the dusty top row.
        let px: [Float] = bottomUp ? Array(repeating: 0.3, count: 12) + Array(repeating: 0.2, count: 4)
                                  : Array(repeating: 0.2, count: 4) + Array(repeating: 0.3, count: 12)
        let raw = RawFrame(image: AstroImage(width: 4, height: 4, channels: 1, pixels: px, sourceIsLinear: true),
                           bayerPattern: .rggb, bottomUp: bottomUp, timestamp: Date(), sourceName: "light.fit")
        return cal.apply(raw).image.pixels
    }
    private func fixture() throws -> (URL, URL) {
        // Subtract .1 offset from .3/.5 flat => .2/.4, normalized to .5/1.
        (try folder("flats", pixels: Array(repeating: 0.3, count: 4) + Array(repeating: 0.5, count: 12)),
         try folder("offset", pixels: Array(repeating: 0.1, count: 16)))
    }

    // Break: silently enabling the fallback changes existing flat-only pixels.
    func testDefaultPreservesFlatOnlyBehavior() throws {
        let (f, o) = try fixture(); let r = resolve(flats: f, offset: o)
        let px = try output(r)
        XCTAssertEqual(px[0], 0.4, accuracy: 0.00001)
        XCTAssertEqual(px[4], 0.3, accuracy: 0.00001)
        XCTAssertFalse(r.hasLightOffset); XCTAssertFalse(r.hasDark)
    }
    // Break: forgetting light subtraction leaves a .4/.3 bright imprint, not uniform .2.
    func testOptInRemovesPedestalBeforeFlatDivision() throws {
        let (f, o) = try fixture(); let r = resolve(enabled: true, flats: f, offset: o)
        for value in try output(r) { XCTAssertEqual(value, 0.2, accuracy: 0.00001) }
        XCTAssertTrue(r.hasLightOffset); XCTAssertTrue(r.hasFlat); XCTAssertFalse(r.hasDark)
        XCTAssertTrue(r.messages.contains { $0.contains("light offset") && $0.contains("not a matched") })
    }
    // Break: a second flip or missing flip moves the sensor correction to the wrong row.
    func testOptInAlignsBottomUpLight() throws {
        // Asymmetric offset: top row .05, remainder .1. Same .5/1 normalized flat.
        let f = try folder("flats", pixels: Array(repeating: 0.25, count: 4) + Array(repeating: 0.5, count: 12))
        let o = try folder("offset", pixels: Array(repeating: 0.05, count: 4) + Array(repeating: 0.1, count: 12))
        let r = resolve(enabled: true, flats: f, offset: o)
        let px: [Float] = Array(repeating: 0.3, count: 12) + Array(repeating: 0.15, count: 4)
        let raw = RawFrame(image: AstroImage(width: 4, height: 4, channels: 1, pixels: px, sourceIsLinear: true),
                           bayerPattern: .rggb, bottomUp: true, timestamp: Date(), sourceName: "light.fit")
        let cal = try XCTUnwrap(r.calibrator)
        for value in cal.apply(raw).image.pixels { XCTAssertEqual(value, 0.2, accuracy: 0.00001) }
    }
    // Break: applying offset in addition to, or instead of, the selected dark.
    func testLegacyDarkTakesPrecedenceWithoutDoubleSubtraction() throws {
        let (f, o) = try fixture()
        let d = try folder("dark", pixels: Array(repeating: 0.15, count: 16))
        let r = resolve(enabled: true, dark: d.appendingPathComponent("frame.fit").path, flats: f, offset: o)
        let px = try output(r)
        XCTAssertEqual(px[0], 0.1, accuracy: 0.00001)
        XCTAssertEqual(px[4], 0.15, accuracy: 0.00001)
        XCTAssertTrue(r.hasDark); XCTAssertFalse(r.hasLightOffset)
        XCTAssertTrue(r.messages.contains { $0.contains("light offset") && $0.contains("dark") && $0.contains("not applied") })
    }
    func testLibraryDarkAlsoTakesPrecedence() throws {
        let (f, o) = try fixture()
        let d = try folder("dark", pixels: Array(repeating: 0.15, count: 16))
        let lib = CalibrationLibrary(baseDirectory: root.appendingPathComponent("library"))
        try lib.add(kind: .dark, camera: "OffsetTest", gain: 100, exposureSeconds: 300,
                    setTempC: -10, binning: 1, fitsURLs: [d.appendingPathComponent("frame.fit")])
        let r = resolve(enabled: true, flats: f, offset: o, library: lib)
        XCTAssertEqual(try output(r)[0], 0.1, accuracy: 0.00001)
        XCTAssertFalse(r.hasLightOffset); XCTAssertTrue(r.hasDark)
    }
    // Break: falling back to a bias or claiming offset when the selected folder is unusable.
    func testMissingDarkFlatsDoesNotClaimOffset() throws {
        let (f, _) = try fixture(); let r = resolve(enabled: true, flats: f, offset: root.appendingPathComponent("absent"))
        XCTAssertFalse(r.hasLightOffset)
        XCTAssertTrue(r.messages.contains { $0.contains("light offset") && $0.contains("not applied") })
        XCTAssertEqual(try output(r)[0], 1.0 / 3.0, accuracy: 0.00001)
    }
    func testWrongSizeDarkFlatDoesNotClaimOffset() throws {
        let (f, _) = try fixture()
        let o = try folder("wrong", pixels: Array(repeating: 0.1, count: 32), width: 8)
        let r = resolve(enabled: true, flats: f, offset: o)
        XCTAssertFalse(r.hasLightOffset)
        XCTAssertEqual(try output(r)[0], 1.0 / 3.0, accuracy: 0.00001)
    }
    func testNoFlatDoesNotApplyOffsetAlone() throws {
        let (_, o) = try fixture(); let r = resolve(enabled: true, flats: nil, offset: o)
        XCTAssertNil(r.calibrator); XCTAssertFalse(r.hasLightOffset)
        XCTAssertTrue(r.messages.contains { $0.contains("light offset") && $0.contains("not applied") })
    }
    // Break: treating a bias fallback as if the selected dark-flat had loaded.
    func testUnusableDarkFlatCannotSilentlyUseLibraryBiasAsLightOffset() throws {
        let (f, _) = try fixture()
        let b = try folder("bias", pixels: Array(repeating: 0.1, count: 16))
        let lib = CalibrationLibrary(baseDirectory: root.appendingPathComponent("library"))
        try lib.add(kind: .bias, camera: "OffsetTest", gain: 100, exposureSeconds: nil,
                    setTempC: -10, binning: 1, fitsURLs: [b.appendingPathComponent("frame.fit")])
        let bad = root.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data([0, 1, 2]).write(to: bad.appendingPathComponent("broken.fit"))
        let r = resolve(enabled: true, flats: f, offset: bad, library: lib)
        XCTAssertFalse(r.hasLightOffset)
        XCTAssertEqual(try output(r)[0], 0.4, accuracy: 0.00001)
    }
    func testScaledDarkTakesPrecedenceWithoutDoubleSubtraction() throws {
        let (f, o) = try fixture()
        let d = try folder("dark", pixels: Array(repeating: 0.125, count: 16))
        let b = try folder("bias", pixels: Array(repeating: 0.1, count: 16))
        let lib = CalibrationLibrary(baseDirectory: root.appendingPathComponent("library"))
        try lib.add(kind: .dark, camera: "OffsetTest", gain: 100, exposureSeconds: 150,
                    setTempC: -10, binning: 1, fitsURLs: [d.appendingPathComponent("frame.fit")])
        try lib.add(kind: .bias, camera: "OffsetTest", gain: 100, exposureSeconds: nil,
                    setTempC: -10, binning: 1, fitsURLs: [b.appendingPathComponent("frame.fit")])
        // Dark at 300s = .1 + 2*(.125-.1) = .15; (.2-.15)/.5 = .1.
        let r = resolve(enabled: true, flats: f, offset: o, library: lib)
        XCTAssertTrue(r.hasDark); XCTAssertFalse(r.hasLightOffset)
        XCTAssertEqual(try output(r)[0], 0.1, accuracy: 0.00001)
    }
    func testWrongChannelDarkFlatIsNotSubtracted() throws {
        let (f, _) = try fixture()
        let o = try folder("rgb", pixels: Array(repeating: 0.1, count: 48), channels: 3)
        let r = resolve(enabled: true, flats: f, offset: o)
        XCTAssertFalse(r.hasLightOffset)
        XCTAssertEqual(try output(r)[0], 1.0 / 3.0, accuracy: 0.00001)
    }
}
