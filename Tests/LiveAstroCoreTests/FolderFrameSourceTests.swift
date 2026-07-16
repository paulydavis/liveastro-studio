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

    func testStopMidImportEndsStreamWithoutYieldingAllFiles() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 1...6 {
            _ = try writeFITS(dir, name: "Light_\(i).fit", value: Float(i) / 10)
        }

        let source = FolderFrameSource(folder: dir, mode: .importOnce, fileNamePrefix: "Light_")
        try source.start()
        var consumed = 0
        for await _ in source.frames {
            consumed += 1
            if consumed == 1 { source.stop() }
        }
        // Pull-based cursor: stop() must end the stream promptly. At most one frame
        // already in flight may still arrive, but never the whole folder.
        XCTAssertLessThan(consumed, 6, "stop() mid-import must not drain all files")
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

    /// Lock-protected log capture (live pull logs arrive off-thread).
    private final class LogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ s: String) { lock.withLock { lines.append(s) } }
        var all: [String] { lock.withLock { lines } }
    }

    /// Cold1 I2 (red-first: pre-fix the live task decoded EVERY emitted update eagerly
    /// into an unbounded AsyncStream buffer — restart onto a folder holding 1000+ subs
    /// meant multi-GB of buffered RawFrames while the serial consumer lagged): the live
    /// stream buffers LIGHT items (URL + identity); decode happens at PULL time, one
    /// frame in flight. Proxy for bounded peak memory: zero decode attempts while the
    /// consumer is parked, exactly one per next().
    func testLiveMode_decodeIsLazy_noDecodeUntilPull() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // The restart-onto-a-full-folder shape: subs already present when the source starts.
        for i in 1...3 { _ = try writeFITS(dir, name: "Light_00\(i).fit", value: Float(i) / 10) }

        let source = FolderFrameSource(folder: dir, mode: .live, fileNamePrefix: "Light_")
        defer { source.stop() }
        let buffered = expectation(description: "3 light updates buffered")
        buffered.expectedFulfillmentCount = 3
        source.liveSeams.onUpdateBuffered = { _ in buffered.fulfill() }
        try source.start()
        await fulfillment(of: [buffered], timeout: 15)

        XCTAssertEqual(source.liveDecodeCount, 0,
                       "no decode may happen while the consumer is parked — light items only")
        var it = source.frames.makeAsyncIterator()
        let first = await it.next()
        XCTAssertEqual(first?.sourceName, "Light_001.fit")
        XCTAssertEqual(source.liveDecodeCount, 1, "exactly one decode per pull")
        let second = await it.next()
        XCTAssertEqual(second?.sourceName, "Light_002.fit")
        XCTAssertEqual(source.liveDecodeCount, 2, "one frame in flight at a time")
    }

    /// Cold1 I2, pull-time identity mismatch: a buffered update whose file changed before
    /// the pull is SKIPPED with the existing honest log and next() advances to the
    /// following update — the frame is lost, the live stream (and session) is not.
    func testLiveMode_identityMismatchAtPull_skipsHonestly_deliversNext() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try writeFITS(dir, name: "Light_a.fit", value: 0.1)
        _ = try writeFITS(dir, name: "Light_b.fit", value: 0.2)

        let source = FolderFrameSource(folder: dir, mode: .live, fileNamePrefix: "Light_")
        defer { source.stop() }
        let logs = LogBox()
        source.onLog = { logs.append($0) }
        let buffered = expectation(description: "2 light updates buffered")
        buffered.expectedFulfillmentCount = 2
        source.liveSeams.onUpdateBuffered = { _ in buffered.fulfill() }
        try source.start()
        await fulfillment(of: [buffered], timeout: 15)

        // The file changes AFTER the watcher validated it, BEFORE the consumer pulls
        // (append one byte in place: same inode, new size/mtime — identity mismatch).
        let fh = try FileHandle(forWritingTo: a)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data([0xFF]))
        try fh.close()

        var it = source.frames.makeAsyncIterator()
        let got = await it.next()
        XCTAssertEqual(got?.sourceName, "Light_b.fit",
                       "the mismatching frame is skipped and the NEXT update delivered — " +
                       "a lost frame must never end a live stream")
        XCTAssertTrue(logs.all.contains(
            "file changed between validation and read — skipping Light_a.fit"),
            "the skip must appear honestly in the log — got \(logs.all)")
    }

    /// Cold1 M2 (red-first: pre-fix a second start() after stop() silently yielded into
    /// the dead stream — the session recorded empty with no error): the source is
    /// one-shot like the watcher. start() while running throws; start() after stop()
    /// throws terminally, so SessionPipeline's rollback reports it loudly.
    func testLiveMode_restartAfterStop_throwsLoudly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = FolderFrameSource(folder: dir, mode: .live)
        try source.start()
        XCTAssertThrowsError(try source.start()) {
            XCTAssertEqual($0 as? FolderFrameSourceError, .alreadyStarted)
        }
        source.stop()
        XCTAssertThrowsError(try source.start(), "start() after stop() must fail loudly") {
            XCTAssertEqual($0 as? FolderFrameSourceError, .stopped)
        }
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
