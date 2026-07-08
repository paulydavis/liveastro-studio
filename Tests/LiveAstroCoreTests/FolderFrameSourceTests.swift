import XCTest
@testable import LiveAstroCore

final class FolderFrameSourceTests: XCTestCase {
    func writeFITS(_ dir: URL, name: String, value: Float) throws -> URL {
        let px = [Float](repeating: value, count: 64 * 32)
        let data = FITSWriter.float32(width: 64, height: 32, channels: 1, pixels: px)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testImportOnceYieldsSortedFramesAndFinishes() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writeFITS(dir, name: "Light_B_002.fit", value: 0.2)
        _ = try writeFITS(dir, name: "Light_A_001.fit", value: 0.1)
        try "x".write(to: dir.appendingPathComponent("ignore.txt"),
                      atomically: true, encoding: .utf8)   // non-FITS ignored

        let source = FolderFrameSource(folder: dir, mode: .importOnce, fileNamePrefix: "Light_")
        try source.start()
        var names: [String] = []
        for await frame in source.frames { names.append(frame.sourceName) }
        XCTAssertEqual(names, ["Light_A_001.fit", "Light_B_002.fit"])
    }

    /// Regression (F6): plain lexicographic sort put Light_10 before Light_2;
    /// import order must be numeric-aware (capture sequence order).
    func testImportOnceSortsNumerically() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writeFITS(dir, name: "Light_2.fit", value: 0.2)
        _ = try writeFITS(dir, name: "Light_10.fit", value: 0.3)
        _ = try writeFITS(dir, name: "Light_1.fit", value: 0.1)

        let source = FolderFrameSource(folder: dir, mode: .importOnce, fileNamePrefix: "Light_")
        try source.start()
        var names: [String] = []
        for await frame in source.frames { names.append(frame.sourceName) }
        XCTAssertEqual(names, ["Light_1.fit", "Light_2.fit", "Light_10.fit"])
    }

    func testLoadRawFrameKeepsStoredOrderAndMetadata() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writeFITS(dir, name: "sub.fit", value: 0.5)
        let frame = try FolderFrameSource.loadRawFrame(url: url)
        XCTAssertEqual(frame.image.channels, 1)
        XCTAssertEqual(frame.image.width, 64)
        XCTAssertEqual(frame.sourceName, "sub.fit")
        XCTAssertNil(frame.bayerPattern)   // FITSWriter emits no BAYERPAT
    }

    func testLiveModeForwardsNewFiles() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = FolderFrameSource(folder: dir, mode: .live, fileNamePrefix: "Light_")
        try source.start()
        try await Task.sleep(nanoseconds: 10_000_000)   // let the kqueue source arm
        _ = try writeFITS(dir, name: "Light_live_001.fit", value: 0.3)
        var got: RawFrame?
        for await frame in source.frames { got = frame; break }
        source.stop()
        XCTAssertEqual(got?.sourceName, "Light_live_001.fit")
    }

    /// Regression: a BOTTOM-UP GRBG file must reach the engine in STORED row order —
    /// FITSReader's display flip would shift the Bayer phase and swap R/B (the
    /// 2026-07-06 "cyan nebula" bug class). Pins loadRawFrame to raw stored bytes.
    func testLoadRawFrameKeepsBottomUpStoredOrder() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Hand-craft a 4x4 16-bit FITS: ROWORDER=BOTTOM-UP, BAYERPAT=GRBG.
        // Stored pixel value = row index (0,1,2,3) so any flip is detectable.
        var header = ""
        func card(_ c: String) { header += c.padding(toLength: 80, withPad: " ", startingAt: 0) }
        card("SIMPLE  =                    T")
        card("BITPIX  =                   16")
        card("NAXIS   =                    2")
        card("NAXIS1  =                    4")
        card("NAXIS2  =                    4")
        card("BZERO   =                32768")
        card("BSCALE  =                    1")
        card("ROWORDER= 'BOTTOM-UP'")
        card("BAYERPAT= 'GRBG    '")
        card("END")
        var data = header.padding(toLength: 2880, withPad: " ", startingAt: 0).data(using: .ascii)!
        for row in 0..<4 {
            for _ in 0..<4 {
                // physical value row*8192 -> stored int16 = row*8192 - 32768, big-endian
                let stored = Int16(row * 8192 - 32768)
                var be = UInt16(bitPattern: stored).bigEndian
                withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
            }
        }
        data.append(Data(repeating: 0, count: 2880 - 32))
        let url = dir.appendingPathComponent("bottomup.fit")
        try data.write(to: url)

        let frame = try FolderFrameSource.loadRawFrame(url: url)
        XCTAssertTrue(frame.bottomUp)
        XCTAssertEqual(frame.bayerPattern, .grbg)
        // STORED order: row 0 must hold the smallest value, row 3 the largest.
        let px = frame.image.pixels
        XCTAssertLessThan(px[0], px[3 * 4])
        XCTAssertEqual(px[0], 0.0, accuracy: 1e-4)                    // row 0 as stored
        XCTAssertEqual(px[3 * 4], Float(3 * 8192) / 65535, accuracy: 1e-4) // row 3 as stored
    }
}
