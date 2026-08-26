import XCTest
@testable import LiveAstroCore

final class CalibrationLibraryTests: XCTestCase {
    private var tmp: URL!
    private var rawDir: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("caltest-\(UUID().uuidString)", isDirectory: true)
        rawDir = tmp.appendingPathComponent("raws", isDirectory: true)
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Write `n` synthetic 4×4 mono FITS frames (constant value) into rawDir.
    private func writeRaws(_ n: Int, value: Float, w: Int = 4, h: Int = 4) -> [URL] {
        var urls: [URL] = []
        for i in 0..<n {
            let px = [Float](repeating: value, count: w * h)
            let data = FITSWriter.float32(width: w, height: h, channels: 1, pixels: px)
            let u = rawDir.appendingPathComponent(String(format: "dark_%02d.fit", i))
            try? data.write(to: u); urls.append(u)
        }
        return urls
    }

    private func lib() -> CalibrationLibrary {
        CalibrationLibrary(baseDirectory: tmp.appendingPathComponent("lib", isDirectory: true))
    }

    /// One malformed/legacy entry in the index must not hide every good master — all() skips it.
    func testTolerantDecodeSkipsMalformedEntry() throws {
        let l = lib()
        _ = try l.add(kind: .dark, camera: "ASI2600", gain: 100, exposureSeconds: 180,
                      setTempC: -10, binning: 1, fitsURLs: writeRaws(2, value: 0.2))
        XCTAssertEqual(l.all().count, 1)
        // Append a malformed entry to the on-disk JSON array.
        let indexURL = tmp.appendingPathComponent("lib/index.json")
        var arr = try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as! [Any]
        arr.append(["totally": "not a master frame"])
        try JSONSerialization.data(withJSONObject: arr).write(to: indexURL)
        XCTAssertEqual(l.all().count, 1, "the good master must survive a single malformed entry")
    }

    func testAddBuildsMasterAndIndexes() throws {
        let urls = writeRaws(3, value: 0.2)
        let l = lib()
        let f = try l.add(kind: .dark, camera: "ASI2600", gain: 100, exposureSeconds: 180,
                          setTempC: -10, binning: 1, fitsURLs: urls)
        XCTAssertEqual(f.kind, .dark)
        XCTAssertEqual(f.camera, "ASI2600")
        XCTAssertEqual(f.exposureSeconds, 180)
        XCTAssertEqual(f.setTempC, -10)
        XCTAssertEqual(f.frameCount, 3)
        XCTAssertEqual(f.width, 4); XCTAssertEqual(f.height, 4); XCTAssertEqual(f.channels, 1)

        XCTAssertEqual(l.all().count, 1)
        let master = l.master(for: f)
        XCTAssertNotNil(master)
        // mean of three 0.2 frames = 0.2
        XCTAssertEqual(master!.pixels[0], 0.2, accuracy: 1e-5)
        XCTAssertEqual(master!.pixels.count, 16)
    }

    func testIndexPersistsAcrossInstances() throws {
        let l = lib()
        _ = try l.add(kind: .bias, camera: "ASI2600", gain: 100, exposureSeconds: nil,
                      setTempC: -10, binning: 1, fitsURLs: writeRaws(2, value: 0.05))
        // A fresh library object pointed at the same dir sees the entry.
        let reopened = lib()
        XCTAssertEqual(reopened.all().count, 1)
        XCTAssertEqual(reopened.all().first?.kind, .bias)
    }

    func testRemoveDeletesEntryAndFile() throws {
        let l = lib()
        let f = try l.add(kind: .dark, camera: "cam", gain: nil, exposureSeconds: 60,
                          setTempC: nil, binning: nil, fitsURLs: writeRaws(2, value: 0.1))
        XCTAssertNotNil(l.master(for: f))
        try l.remove(id: f.id)
        XCTAssertTrue(l.all().isEmpty)
        XCTAssertNil(l.master(for: f))   // backing file gone
    }

    func testRebuildRecombinesFromSource() throws {
        let l = lib()
        let f = try l.add(kind: .dark, camera: "cam", gain: 100, exposureSeconds: 180,
                          setTempC: -10, binning: 1, fitsURLs: writeRaws(2, value: 0.2))
        // Add a third raw to the source folder, then rebuild.
        _ = writeRaws(3, value: 0.2)   // overwrites 00,01 + adds 02 → 3 frames present
        try l.rebuild(id: f.id)
        XCTAssertEqual(l.all().first?.frameCount, 3)
        XCTAssertNotNil(l.master(for: f))
    }
}
