import XCTest
@testable import LiveAstroCore

final class StackFileWatcherTests: XCTestCase {
    var tmp: URL!
    var watcher: StackFileWatcher!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        watcher?.stop()
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeFITS(_ value: Float, size: Int = 8) -> Data {
        FITSWriter.float32(width: size, height: size, channels: 1,
                           pixels: [Float](repeating: value, count: size * size))
    }

    /// Collects updates into an actor-guarded array.
    private func collect(_ watcher: StackFileWatcher) -> Collector {
        let c = Collector()
        Task { for await u in watcher.updates { await c.add(u) } }
        return c
    }

    actor Collector {
        private(set) var items: [StackUpdate] = []
        func add(_ u: StackUpdate) { items.append(u) }
        func waitForCount(_ n: Int, timeout: TimeInterval) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if items.count >= n { return true }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return items.count >= n
        }
    }

    func testStartThrowsForNonexistentFolder() {
        let w = StackFileWatcher(folder: URL(fileURLWithPath: "/nonexistent-\(UUID())"))
        XCTAssertThrowsError(try w.start())
    }

    func testEmitsOnCompleteFITSWrite() async throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 0.2, pollInterval: 0.5)
        let collector = collect(watcher)
        try watcher.start()
        try makeFITS(0.5).write(to: tmp.appendingPathComponent("live_stack.fit"))
        let got = await collector.waitForCount(1, timeout: 5)
        XCTAssertTrue(got, "expected one update for a complete FITS write")
    }

    func testIgnoresPartialFITSUntilComplete() async throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 0.2, pollInterval: 0.3)
        let collector = collect(watcher)
        try watcher.start()
        let full = makeFITS(0.5, size: 64)
        let url = tmp.appendingPathComponent("live_stack.fit")
        try full.prefix(full.count / 2).write(to: url)      // partial: header claims more data
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let premature = await collector.waitForCount(1, timeout: 0.1)
        XCTAssertFalse(premature, "must not emit for a partial FITS file")
        try full.write(to: url)                              // complete rewrite
        let got = await collector.waitForCount(1, timeout: 5)
        XCTAssertTrue(got)
    }

    func testDeduplicatesIdenticalContent() async throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 0.2, pollInterval: 0.3)
        let collector = collect(watcher)
        try watcher.start()
        let url = tmp.appendingPathComponent("live_stack.fit")
        let data = makeFITS(0.5)
        try data.write(to: url)
        _ = await collector.waitForCount(1, timeout: 5)
        try data.write(to: url)                              // same bytes again
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let items = await collector.items
        XCTAssertEqual(items.count, 1, "identical content must not re-emit")
    }

    func testEmitsAgainOnChangedContent() async throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 0.2, pollInterval: 0.3)
        let collector = collect(watcher)
        try watcher.start()
        let url = tmp.appendingPathComponent("live_stack.fit")
        try makeFITS(0.3).write(to: url)
        _ = await collector.waitForCount(1, timeout: 5)
        try makeFITS(0.6).write(to: url)
        let got = await collector.waitForCount(2, timeout: 5)
        XCTAssertTrue(got, "changed content must emit a second update")
    }

    func testFileNamePrefixFilter() async throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 0.2, pollInterval: 0.3, fileNamePrefix: "live_stack")
        let collector = collect(watcher)
        try watcher.start()
        try makeFITS(0.4).write(to: tmp.appendingPathComponent("Light_NGC6888_001.fit"))  // raw sub — must be ignored
        try makeFITS(0.5).write(to: tmp.appendingPathComponent("live_stack.fit"))          // stack — must emit
        let got = await collector.waitForCount(1, timeout: 5)
        XCTAssertTrue(got)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let items = await collector.items
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].url.lastPathComponent, "live_stack.fit")
    }

    func testIgnoresTempAndHiddenFiles() async throws {
        watcher = StackFileWatcher(folder: tmp, quietPeriod: 0.2, pollInterval: 0.3)
        let collector = collect(watcher)
        try watcher.start()
        try makeFITS(0.5).write(to: tmp.appendingPathComponent(".hidden.fit"))
        try Data("x".utf8).write(to: tmp.appendingPathComponent("scratch.tmp"))
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let items = await collector.items
        XCTAssertTrue(items.isEmpty)
    }
}
