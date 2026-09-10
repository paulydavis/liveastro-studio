import XCTest
import Darwin
@testable import LiveAstroCore

final class CommittedFlattenCacheTests: XCTestCase {
    private var adjustments: DisplayAdjustments {
        DisplayAdjustments(blackPoint: 0.1, backgroundExtraction: true, bgScale: 2, bgSmoothest: 0.5)
    }

    private func sandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // Fractional star positions keep registration viable at small test dimensions. Pixels vary
    // spatially so a stale DBE result cannot masquerade as parity on a constant image.
    private func frame(_ index: Int, width w: Int = 640, height h: Int = 480) -> RawFrame {
        var pixels = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w {
            pixels[y * w + x] = 0.03 + Float(x) / Float(w) * 0.025
                + Float((x * 7 + y * 13 + index * 17) % 23) * 0.0002
        } }
        for row in 0..<4 { for column in 0..<5 {
            let sx = (55 + column * 117 + (row % 2) * 11) * w / 640
            let sy = (48 + row * 109 + (column % 3) * 7) * h / 480
            for dy in -8...8 { for dx in -8...8 {
                pixels[(sy + dy) * w + sx + dx] += Float(0.4 + Double(column) * 0.07)
                    * exp(-Float(dx * dx + dy * dy) / 12)
            } }
        } }
        // DBE passes mono through unchanged; RGB is essential to exercise the cached work.
        let rgb = pixels + pixels.map { $0 * 0.87 + 0.012 } + pixels.map { $0 * 1.13 + 0.004 }
        return RawFrame(image: AstroImage(width: w, height: h, channels: 3,
                                          pixels: rgb, sourceIsLinear: true),
                        bayerPattern: nil, bottomUp: false, timestamp: Date(),
                        sourceName: "cache-\(index).fit")
    }

    private func native() throws -> (SessionPipeline, StubLiveSource) {
        let source = StubLiveSource(sequence: [])
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
            profile: SessionProfile(targetName: "CacheTest", subExposureSeconds: 1),
            rootDirectory: try sandbox())
        pipeline.rendersReplay = false
        pipeline.displayAdjustments = adjustments
        try pipeline.start()
        addTeardownBlock { _ = try? pipeline.end() }
        try ingest(frame(0), into: pipeline, source: source)
        return (pipeline, source)
    }

    private func ingest(_ frame: RawFrame, into pipeline: SessionPipeline, source: StubLiveSource,
                        timeout: TimeInterval = 30) throws {
        let completed = expectation(description: "native frame recorded")
        completed.assertForOverFulfill = false
        pipeline.onUpdate = { _, _ in completed.fulfill() }
        source.send(frame)
        wait(for: [completed], timeout: timeout)
        XCTAssertGreaterThan(pipeline.committedFlattenRetainedBytesForTest, 0,
                             "prerequisite: native frame rendered and populated DBE cache")
    }

    private func apply(_ adjustments: DisplayAdjustments, to pipeline: SessionPipeline) throws -> CGImage {
        let completed = expectation(description: "committed image delivered")
        completed.assertForOverFulfill = false
        let images = ImageLog()
        pipeline.onDisplayUpdate = { update in
            if let image = update.broadcastImage { images.set(image); completed.fulfill() }
        }
        XCTAssertNotNil(pipeline.applyCommittedAdjustments(adjustments))
        wait(for: [completed], timeout: 30)
        return try XCTUnwrap(images.image)
    }

    private final class ImageLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CGImage?
        func set(_ image: CGImage) { lock.lock(); stored = image; lock.unlock() }
        var image: CGImage? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    func testDisablingBeforeStartBypassesRetentionWithoutChangingPixels() throws {
        let source = StubLiveSource(sequence: [])
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
            profile: SessionProfile(targetName: "CacheOff", subExposureSeconds: 1), rootDirectory: try sandbox())
        pipeline.rendersReplay = false
        pipeline.displayAdjustments = adjustments
        XCTAssertTrue(pipeline.disableCommittedFlattenCacheBeforeStartForTesting())
        let recorded = expectation(description: "cache-off frame recorded")
        pipeline.onUpdate = { _, _ in recorded.fulfill() }
        try pipeline.start()
        defer { _ = try? pipeline.end() }
        source.send(frame(0))
        wait(for: [recorded], timeout: 30)
        let delivered = try apply(adjustments, to: pipeline)
        let fresh = try XCTUnwrap(pipeline.renderSelectedSource(.online, adjustments: adjustments))
        XCTAssertEqual(PreviewTestSupport.sha256(delivered), PreviewTestSupport.sha256(fresh))
        XCTAssertEqual(pipeline.committedFlattenMetrics.hits, 0)
        XCTAssertEqual(pipeline.committedFlattenMetrics.misses, 0)
        XCTAssertEqual(pipeline.committedFlattenMetrics.retainedBytes, 0)
    }

    func testDisablingAfterStartIsRefusedAndPreservesCache() throws {
        let (pipeline, _) = try native()
        let bytes = pipeline.committedFlattenMetrics.retainedBytes
        XCTAssertFalse(pipeline.disableCommittedFlattenCacheBeforeStartForTesting())
        XCTAssertEqual(pipeline.committedFlattenMetrics.retainedBytes, bytes)
    }

    // Break caught: refreshDisplay treating a watcher's saved-snapshot index as pixel identity.
    func testWatcherApplyDoesNotRetainACommittedFlatten() throws {
        let root = try sandbox()
        let watch = root.appendingPathComponent("watch")
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        let pipeline = SessionPipeline(watchFolder: watch,
            profile: SessionProfile(targetName: "WatcherCache", subExposureSeconds: 1),
            rootDirectory: root.appendingPathComponent("sessions"))
        pipeline.rendersReplay = false
        pipeline.displayAdjustments = adjustments
        let recorded = expectation(description: "watcher frame recorded")
        recorded.assertForOverFulfill = false
        pipeline.onUpdate = { _, _ in recorded.fulfill() }
        try pipeline.start()
        defer { _ = try? pipeline.end() }
        let image = frame(0).image
        try FITSWriter.float32(width: image.width, height: image.height, channels: image.channels,
                               pixels: image.pixels).write(to: watch.appendingPathComponent("live_stack.fit"))
        wait(for: [recorded], timeout: 30)
        _ = try apply(adjustments, to: pipeline)
        XCTAssertEqual(pipeline.committedFlattenRetainedBytesForTest, 0,
                       "watcher sources have no native pixel identity and must bypass the cache")
        XCTAssertEqual(pipeline.committedFlattenMetrics.hits, 0)
        XCTAssertEqual(pipeline.committedFlattenMetrics.misses, 0)
    }

    func testCacheHitIsPixelIdenticalToUncachedCommittedRenderer() throws {
        let (pipeline, _) = try native()
        let before = pipeline.committedFlattenMetrics
        var edited = adjustments
        edited.blackPoint = 0.25
        let cached = try apply(edited, to: pipeline)
        let fresh = try XCTUnwrap(pipeline.renderSelectedSource(.online, adjustments: edited))
        XCTAssertEqual(PreviewTestSupport.sha256(cached), PreviewTestSupport.sha256(fresh))
        XCTAssertEqual(pipeline.committedFlattenMetrics.hits, before.hits + 1)
        XCTAssertEqual(pipeline.committedFlattenMetrics.misses, before.misses)
        var noDBE = edited
        noDBE.backgroundExtraction = false
        let without = try XCTUnwrap(pipeline.renderSelectedSource(.online, adjustments: noDBE))
        XCTAssertNotEqual(PreviewTestSupport.sha256(fresh), PreviewTestSupport.sha256(without),
                          "prerequisite: fixture must make DBE observable in the rendered output")
    }

    func testEachDBEParameterChangeMissesAndMatchesFreshOutput() throws {
        for parameter in 0..<2 {
            let (pipeline, _) = try native()
            var edited = adjustments
            let baseline = try XCTUnwrap(pipeline.renderSelectedSource(.online, adjustments: edited))
            let before = pipeline.committedFlattenMetrics
            // At this size 0.5 and 0.8 round to the same blur radius: use a distinct radius.
            if parameter == 0 { edited.bgScale = 3 } else { edited.bgSmoothest = 2 }
            let cached = try apply(edited, to: pipeline)
            let fresh = try XCTUnwrap(pipeline.renderSelectedSource(.online, adjustments: edited))
            XCTAssertNotEqual(PreviewTestSupport.sha256(baseline), PreviewTestSupport.sha256(fresh),
                              "prerequisite: parameter \(parameter) must change the rendered pixels")
            XCTAssertEqual(PreviewTestSupport.sha256(cached), PreviewTestSupport.sha256(fresh))
            XCTAssertEqual(pipeline.committedFlattenMetrics.misses, before.misses + 1)
            XCTAssertEqual(pipeline.committedFlattenMetrics.hits, before.hits)
        }
    }

    // Break caught: treating a retained flatten as applicable while DBE is disabled.
    func testDBEOffThenOnPreservesBothOutputs() throws {
        let (pipeline, _) = try native()
        let before = pipeline.committedFlattenMetrics
        var off = adjustments
        off.backgroundExtraction = false
        let disabled = try apply(off, to: pipeline)
        let freshDisabled = try XCTUnwrap(pipeline.renderSelectedSource(.online, adjustments: off))
        XCTAssertEqual(PreviewTestSupport.sha256(disabled), PreviewTestSupport.sha256(freshDisabled))
        XCTAssertEqual(pipeline.committedFlattenMetrics.hits, before.hits)
        let enabled = try apply(adjustments, to: pipeline)
        let freshEnabled = try XCTUnwrap(pipeline.renderSelectedSource(.online, adjustments: adjustments))
        XCTAssertEqual(PreviewTestSupport.sha256(enabled), PreviewTestSupport.sha256(freshEnabled))
        XCTAssertNotEqual(PreviewTestSupport.sha256(enabled), PreviewTestSupport.sha256(disabled))
        XCTAssertEqual(pipeline.committedFlattenMetrics.hits, before.hits + 1)
        XCTAssertEqual(pipeline.committedFlattenMetrics.misses, before.misses)
    }

    // Break caught: supplying cached online pixels to the resolved clean broadcast.
    // Publication is controlled here; this tests source isolation, not a publication/render race.
    func testOnlineCacheHitCannotReplacePublishedCleanBroadcast() throws {
        let (pipeline, _) = try native()
        pipeline.configureLiveRejection(enabled: true)
        _ = try apply(adjustments, to: pipeline)
        pipeline.refinerForTest()?.quiesce()
        let clean = frame(7).image
        pipeline.publishedMaster = PublishedMaster(image: clean,
            coverage: [Float](repeating: 1, count: clean.width * clean.height),
            survivorCount: 1, key: pipeline.currentFreshnessKey())
        XCTAssertNotNil(pipeline.publishedMasterIfCurrent(), "prerequisite: clean master must be eligible")
        let before = pipeline.committedFlattenMetrics
        let delivered = try apply(adjustments, to: pipeline)
        let expected = try XCTUnwrap(pipeline.renderSelectedSource(.clean, adjustments: adjustments))
        let online = try XCTUnwrap(pipeline.renderSelectedSource(.online, adjustments: adjustments))
        XCTAssertNotEqual(PreviewTestSupport.sha256(expected), PreviewTestSupport.sha256(online),
                          "prerequisite: clean and online sources must render differently")
        XCTAssertEqual(PreviewTestSupport.sha256(delivered), PreviewTestSupport.sha256(expected))
        XCTAssertEqual(pipeline.committedFlattenMetrics.hits, before.hits + 1)
        XCTAssertEqual(pipeline.committedFlattenMetrics.misses, before.misses,
                       "clean render must bypass the native online cache")
    }

    func testNewFrameMissesAndSubsequentApplyMatchesFreshOutput() throws {
        let (pipeline, source) = try native()
        let before = pipeline.committedFlattenMetrics
        try ingest(frame(1), into: pipeline, source: source)
        XCTAssertEqual(pipeline.committedFlattenMetrics.misses, before.misses + 1)
        let cached = try apply(adjustments, to: pipeline)
        let fresh = try XCTUnwrap(pipeline.renderSelectedSource(.online, adjustments: adjustments))
        XCTAssertEqual(PreviewTestSupport.sha256(cached), PreviewTestSupport.sha256(fresh))
        XCTAssertEqual(pipeline.committedFlattenMetrics.hits, before.hits + 1)
    }

    private func key(_ generation: Int = 0, count: Int = 1) -> CommittedFlattenCache.Key {
        .init(generation: generation, count: count, width: 640, height: 480, channels: 3,
              scale: 2, smoothest: 0.5)
    }

    func testInvalidationDuringComputationCannotRepopulateCache() {
        let cache = CommittedFlattenCache()
        let image = frame(0).image
        _ = cache.image(for: key()) {
            cache.invalidate(minimumGeneration: 1)
            return image
        }
        XCTAssertEqual(cache.metrics.retainedBytes, 0)
        // Also catches old work entering the cache AFTER invalidation, rather than before it.
        _ = cache.image(for: key()) { image }
        XCTAssertEqual(cache.metrics.retainedBytes, 0)
        _ = cache.image(for: key(1)) { image }
        XCTAssertEqual(cache.metrics.retainedBytes, image.pixels.count * MemoryLayout<Float>.size)
    }

    func testRetirementDuringComputationPreventsAllLaterRetention() {
        let cache = CommittedFlattenCache()
        let image = frame(0).image
        _ = cache.image(for: key()) { cache.invalidate(retiring: true); return image }
        XCTAssertEqual(cache.metrics.retainedBytes, 0)
        _ = cache.image(for: key(1)) { image }
        XCTAssertEqual(cache.metrics.retainedBytes, 0)
    }

    func testReplacementEvictsBeforeComputingAndNewerMissWins() {
        let cache = CommittedFlattenCache()
        let image = frame(0).image
        _ = cache.image(for: key()) { image }
        _ = cache.image(for: key(count: 2)) {
            XCTAssertEqual(cache.metrics.retainedBytes, 0)
            _ = cache.image(for: key(count: 3)) { image }
            return image
        }
        _ = cache.image(for: key(count: 3)) { XCTFail("older computation overwrote newer entry"); return image }
        XCTAssertEqual(cache.metrics.hits, 1)
        XCTAssertEqual(cache.metrics.misses, 3)
    }

    // Break caught: keeping the old source's flattened pixels after a manual reseed.
    func testReseedDropsTheRetainedFlatten() throws {
        let (pipeline, source) = try native()
        let before = pipeline.committedFlattenMetrics
        XCTAssertEqual(pipeline.reseed(), .reseeded)
        XCTAssertEqual(pipeline.committedFlattenRetainedBytesForTest, 0)
        // The new reference reuses count=1 and dimensions; generation must distinguish it.
        try ingest(frame(1), into: pipeline, source: source)
        XCTAssertEqual(pipeline.committedFlattenMetrics.misses, before.misses + 1)
        let cached = try apply(adjustments, to: pipeline)
        let fresh = try XCTUnwrap(pipeline.renderSelectedSource(.online, adjustments: adjustments))
        XCTAssertEqual(PreviewTestSupport.sha256(cached), PreviewTestSupport.sha256(fresh))
    }

    // Break caught: the final display render repopulating a cache that is no longer useful.
    func testEndDropsTheRetainedFlatten() throws {
        let (pipeline, _) = try native()
        _ = try pipeline.end()
        XCTAssertEqual(pipeline.committedFlattenRetainedBytesForTest, 0)
    }

    /// Native online fallback only, two frames: no clean master, draft preview, or refiner overlap.
    /// Both input Arrays remain alive throughout, and their allocation precedes the RSS baseline.
    func testNativeCacheReplacementMemory() throws {
        guard ProcessInfo.processInfo.environment["LAS_RUN_COMMITTED_CACHE_MEMORY"] == "1" else {
            throw XCTSkip("set LAS_RUN_COMMITTED_CACHE_MEMORY=1; release-mode 26 MP native memory measurement")
        }
        let first = frame(0, width: 6236, height: 4159)
        let second = frame(1, width: 6236, height: 4159)
        let source = StubLiveSource(sequence: [])
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
            profile: SessionProfile(targetName: "CacheMemory", subExposureSeconds: 1),
            rootDirectory: try sandbox())
        pipeline.rendersReplay = false
        var settings = adjustments
        settings.bgScale = 2.9611440772720226
        pipeline.displayAdjustments = settings
        try pipeline.start()
        defer { _ = try? pipeline.end() }
        let baseline = try XCTUnwrap(Self.residentBytes())
        try ingest(first, into: pipeline, source: source, timeout: 240)
        let firstResident = try XCTUnwrap(Self.residentBytes())
        let sampler = ResidentSampler()
        sampler.start()
        defer { sampler.stop() }
        try ingest(second, into: pipeline, source: source, timeout: 240)
        sampler.stop()
        let replacedResident = try XCTUnwrap(Self.residentBytes())
        let beforeApply = pipeline.committedFlattenMetrics
        settings.blackPoint = 0.25
        _ = try apply(settings, to: pipeline)
        let afterApply = pipeline.committedFlattenMetrics
        XCTAssertEqual(beforeApply.misses, 2)
        XCTAssertEqual(afterApply.hits, beforeApply.hits + 1)
        XCTAssertEqual(afterApply.misses, beforeApply.misses)
        XCTAssertGreaterThan(sampler.samples, 0, "RSS sampler must actually run")
        XCTAssertLessThanOrEqual(afterApply.retainedBytes, first.image.pixels.count * MemoryLayout<Float>.size)
        print("CACHE-MEM bytes: baseline=\(baseline) firstRecorded=\(firstResident) "
              + "replacementPeakSampled=\(sampler.peak) replacementRecorded=\(replacedResident) "
              + "retained=\(afterApply.retainedBytes) samples=\(sampler.samples)")
        _ = try pipeline.end()
        XCTAssertEqual(pipeline.committedFlattenMetrics.retainedBytes, 0)
        withExtendedLifetime((first, second)) {}
    }

    private static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }

    private final class ResidentSampler: @unchecked Sendable {
        private let lock = NSLock()
        private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "cache-memory-sampler"))
        private var maximum: UInt64 = 0
        private var count = 0
        var peak: UInt64 { lock.lock(); defer { lock.unlock() }; return maximum }
        var samples: Int { lock.lock(); defer { lock.unlock() }; return count }
        func start() {
            timer.schedule(deadline: .now(), repeating: .milliseconds(5))
            timer.setEventHandler { [weak self] in
                guard let self, let bytes = CommittedFlattenCacheTests.residentBytes() else { return }
                self.lock.lock()
                self.maximum = max(self.maximum, bytes)
                self.count += 1
                self.lock.unlock()
            }
            timer.resume()
        }
        func stop() { timer.cancel() }
    }
}
