import XCTest
@testable import LiveAstroCore

/// Integration tests for the full resolve path (match → load master → scale → build
/// flat → Calibrator). Uses a real on-disk library + synthetic FITS, so it exercises
/// exactly what runs at Start and on the first sub.
final class CalibrationResolverTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// Write `n` synthetic 4×4 mono FITS frames (constant value) into a fresh subfolder.
    private func rawFolder(_ name: String, count: Int, value: Float) -> URL {
        let dir = tmp.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<count {
            let data = FITSWriter.float32(width: 4, height: 4, channels: 1,
                                          pixels: [Float](repeating: value, count: 16))
            try? data.write(to: dir.appendingPathComponent(String(format: "f_%02d.fit", i)))
        }
        return dir
    }

    /// Write `n` synthetic 4×4 THREE-channel FITS frames — a same-size, wrong-channel master source.
    private func rawFolder3ch(_ name: String, count: Int, value: Float) -> URL {
        let dir = tmp.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<count {
            let data = FITSWriter.float32(width: 4, height: 4, channels: 3,
                                          pixels: [Float](repeating: value, count: 48))
            try? data.write(to: dir.appendingPathComponent(String(format: "f_%02d.fit", i)))
        }
        return dir
    }

    /// Write `n` synthetic mono FITS frames of an arbitrary size (for wrong-size-master scenarios).
    private func rawFolderSized(_ name: String, count: Int, value: Float, w: Int, h: Int) -> URL {
        let dir = tmp.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<count {
            let data = FITSWriter.float32(width: w, height: h, channels: 1,
                                          pixels: [Float](repeating: value, count: w * h))
            try? data.write(to: dir.appendingPathComponent(String(format: "f_%02d.fit", i)))
        }
        return dir
    }

    private func library() -> CalibrationLibrary {
        CalibrationLibrary(baseDirectory: tmp.appendingPathComponent("lib", isDirectory: true))
    }

    private func light(camera: String = "ASI2600", gain: Double = 100,
                       exp: Double = 180, temp: Double = -10) -> SourceMetadata {
        var m = SourceMetadata()
        m.instrument = camera; m.gain = gain; m.exposureSeconds = exp; m.setTempC = temp; m.binning = 1
        return m
    }

    func testResolvesExactDark() throws {
        let lib = library()
        try lib.add(kind: .dark, camera: "ASI2600", gain: 100, exposureSeconds: 180,
                    setTempC: -10, binning: 1, fitsURLs: filesIn(rawFolder("d", count: 3, value: 0.2)))
        let r = CalibrationResolver.resolve(metadata: light(), library: lib, scaleEnabled: true,
                    flatsFolder: nil, darkFlatsFolder: nil, legacyDarkPath: nil, legacyFlatPath: nil)
        XCTAssertTrue(r.hasDark)
        XCTAssertNotNil(r.calibrator)
        XCTAssertTrue(r.messages.contains { $0.contains("matched") })
    }

    /// A corrupt/unloadable top-matched master must NOT block an otherwise-valid alternative dark —
    /// the resolver retries the next matching candidate instead of silently continuing dark-less.
    func testRetriesNextDarkWhenChosenMasterIsCorrupt() throws {
        let lib = library()
        // Two equally-matching darks (same key + exposure). The matcher prefers the first.
        let f1 = try lib.add(kind: .dark, camera: "ASI2600", gain: 100, exposureSeconds: 180,
                    setTempC: -10, binning: 1, fitsURLs: filesIn(rawFolder("d1", count: 2, value: 0.2)))
        _ = try lib.add(kind: .dark, camera: "ASI2600", gain: 100, exposureSeconds: 180,
                    setTempC: -10, binning: 1, fitsURLs: filesIn(rawFolder("d2", count: 2, value: 0.3)))
        // Corrupt the first-matched master's file on disk.
        let libDir = tmp.appendingPathComponent("lib", isDirectory: true)
        try Data([0x00, 0x01, 0x02]).write(to: libDir.appendingPathComponent(f1.fileName))

        let r = CalibrationResolver.resolve(metadata: light(), library: lib, scaleEnabled: true,
                    flatsFolder: nil, darkFlatsFolder: nil, legacyDarkPath: nil, legacyFlatPath: nil)
        XCTAssertTrue(r.hasDark, "a corrupt top master must not block the valid second dark")
        XCTAssertNotNil(r.calibrator)
    }

    /// A same-size but wrong-CHANNEL dark must be skipped (not accepted then silently dropped by the
    /// Calibrator) and a valid same-channel dark chosen instead.
    func testWrongChannelDarkSkippedAndValidOneChosen() throws {
        let lib = library()
        _ = try lib.add(kind: .dark, camera: "ASI2600", gain: 100, exposureSeconds: 180,   // 3-channel (wrong)
                    setTempC: -10, binning: 1, fitsURLs: filesIn(rawFolder3ch("d3", count: 2, value: 0.2)))
        _ = try lib.add(kind: .dark, camera: "ASI2600", gain: 100, exposureSeconds: 180,   // 1-channel (valid)
                    setTempC: -10, binning: 1, fitsURLs: filesIn(rawFolder("d1", count: 2, value: 0.3)))
        var l = light(); l.width = 4; l.height = 4; l.channels = 1
        let r = CalibrationResolver.resolve(metadata: l, library: lib, scaleEnabled: true,
                    flatsFolder: nil, darkFlatsFolder: nil, legacyDarkPath: nil, legacyFlatPath: nil)
        XCTAssertTrue(r.hasDark)
        XCTAssertTrue(r.messages.contains { $0.contains("trying another dark") },
                      "the wrong-channel dark must be skipped and retried")
    }

    /// A corrupt FIRST bias must not sink every scaled-dark attempt — the resolver retries the next
    /// valid bias and scales with it.
    func testScaledDarkRetriesPastCorruptBias() throws {
        let lib = library()
        _ = try lib.add(kind: .dark, camera: "ASI2600", gain: 100, exposureSeconds: 120,   // needs scaling to 180
                    setTempC: -10, binning: 1, fitsURLs: filesIn(rawFolder("d", count: 2, value: 0.2)))
        let bias1 = try lib.add(kind: .bias, camera: "ASI2600", gain: 100, exposureSeconds: nil,
                    setTempC: -10, binning: 1, fitsURLs: filesIn(rawFolder("b1", count: 2, value: 0.1)))
        _ = try lib.add(kind: .bias, camera: "ASI2600", gain: 100, exposureSeconds: nil,
                    setTempC: -10, binning: 1, fitsURLs: filesIn(rawFolder("b2", count: 2, value: 0.1)))
        let libDir = tmp.appendingPathComponent("lib", isDirectory: true)
        try Data([0x00, 0x01, 0x02]).write(to: libDir.appendingPathComponent(bias1.fileName))   // corrupt first bias

        let r = CalibrationResolver.resolve(metadata: light(exp: 180), library: lib, scaleEnabled: true,
                    flatsFolder: nil, darkFlatsFolder: nil, legacyDarkPath: nil, legacyFlatPath: nil)
        XCTAssertTrue(r.hasDark, "a corrupt first bias must not block scaling with the valid second bias")
    }

    /// A legacy explicitly-selected dark whose size doesn't match the lights must NOT report hasDark
    /// (the Calibrator would skip it) — it's validated before acceptance.
    func testLegacyDarkWrongSizeNotReportedActive() throws {
        // Build a 4×4 dark file, then point legacyDarkPath at it with lights declared 8×8.
        let darkURL = tmp.appendingPathComponent("legacydark.fit")
        try MasterBuilder.save(MasterBuilder.combine(fitsURLs: filesIn(rawFolder("ld", count: 2, value: 0.2)),
                                                     kind: .dark, bias: nil), to: darkURL)
        var l = light(); l.width = 8; l.height = 8; l.channels = 1
        let r = CalibrationResolver.resolve(metadata: l, library: library(), scaleEnabled: true,
                    flatsFolder: nil, darkFlatsFolder: nil, legacyDarkPath: darkURL.path, legacyFlatPath: nil)
        XCTAssertFalse(r.hasDark, "a wrong-size legacy dark must not be reported active")
        XCTAssertTrue(r.messages.contains { $0.contains("doesn't match") })
    }

    /// describe()/fmt() must not trap on a corrupt finite-but-huge exposure (Int(1e100) traps).
    func testDescribeDoesNotCrashOnHugeExposure() {
        let f = MasterFrame(id: UUID(), kind: .dark, camera: "ASI2600", gain: 100, exposureSeconds: 1e100,
                            setTempC: -10, binning: 1, width: 4, height: 4, channels: 1,
                            frameCount: 1, createdAt: Date(), fileName: "m.fit", sourcePath: nil)
        _ = CalibrationResolver.describe(f)   // must return, not fatalError
    }

    /// When the light carries no dimensions, a wrong-size bias must not sink a valid scaled dark —
    /// scaling falls back to a bias whose shape matches the dark, rather than excluding the dark.
    func testScaledDarkUsesShapeCompatibleBiasWhenLightDimsUnknown() throws {
        let lib = library()
        _ = try lib.add(kind: .dark, camera: "ASI2600", gain: 100, exposureSeconds: 120,   // 4×4, needs scaling to 180
                    setTempC: -10, binning: 1, fitsURLs: filesIn(rawFolder("d", count: 2, value: 0.2)))
        _ = try lib.add(kind: .bias, camera: "ASI2600", gain: 100, exposureSeconds: nil,     // 8×8 wrong size, index-first
                    setTempC: -10, binning: 1, fitsURLs: filesIn(rawFolderSized("bwrong", count: 2, value: 0.1, w: 8, h: 8)))
        _ = try lib.add(kind: .bias, camera: "ASI2600", gain: 100, exposureSeconds: nil,     // 4×4 compatible
                    setTempC: -10, binning: 1, fitsURLs: filesIn(rawFolder("bok", count: 2, value: 0.1)))
        // light() carries no width/height/channels → bias can't be pre-validated against the light.
        let r = CalibrationResolver.resolve(metadata: light(exp: 180), library: lib, scaleEnabled: true,
                    flatsFolder: nil, darkFlatsFolder: nil, legacyDarkPath: nil, legacyFlatPath: nil)
        XCTAssertTrue(r.hasDark, "scaling must fall back to a shape-compatible bias, not discard the valid dark")
    }

    func testNoDarkForDifferentCamera() throws {
        let lib = library()
        try lib.add(kind: .dark, camera: "ASI2600", gain: 100, exposureSeconds: 180,
                    setTempC: -10, binning: 1, fitsURLs: filesIn(rawFolder("d", count: 2, value: 0.2)))
        let r = CalibrationResolver.resolve(metadata: light(camera: "Seestar"), library: lib,
                    scaleEnabled: true, flatsFolder: nil, darkFlatsFolder: nil,
                    legacyDarkPath: nil, legacyFlatPath: nil)
        XCTAssertFalse(r.hasDark)
        XCTAssertNil(r.calibrator)
    }

    func testScalesDarkAcrossExposureWithBias() throws {
        let lib = library()
        try lib.add(kind: .dark, camera: "ASI2600", gain: 100, exposureSeconds: 120,
                    setTempC: -10, binning: 1, fitsURLs: filesIn(rawFolder("d", count: 2, value: 0.2)))
        try lib.add(kind: .bias, camera: "ASI2600", gain: 100, exposureSeconds: nil,
                    setTempC: -10, binning: 1, fitsURLs: filesIn(rawFolder("b", count: 2, value: 0.05)))
        // 180s light, no exact 180s dark → scale the 120s dark.
        let r = CalibrationResolver.resolve(metadata: light(exp: 180), library: lib, scaleEnabled: true,
                    flatsFolder: nil, darkFlatsFolder: nil, legacyDarkPath: nil, legacyFlatPath: nil)
        XCTAssertTrue(r.hasDark)
        XCTAssertNotNil(r.calibrator)
        XCTAssertTrue(r.messages.contains { $0.contains("scaled") })
    }

    func testBuildsSessionFlat() throws {
        let lib = library()
        let flats = rawFolder("flats", count: 4, value: 0.5)
        let r = CalibrationResolver.resolve(metadata: light(), library: lib, scaleEnabled: true,
                    flatsFolder: flats, darkFlatsFolder: nil, legacyDarkPath: nil, legacyFlatPath: nil)
        XCTAssertTrue(r.hasFlat)
        XCTAssertNotNil(r.calibrator)
        XCTAssertTrue(r.messages.contains { $0.contains("master flat") })
    }

    private func filesIn(_ dir: URL) -> [URL] { CalibrationLibrary.fitsFiles(in: dir) }
}
