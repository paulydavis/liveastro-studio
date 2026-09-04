import XCTest
@testable import LiveAstroCore

final class PreviewRenderTests: XCTestCase {

    /// The whole point of the staged model: rendering a preview must not move the state the
    /// broadcast reads. Pre-change, `renderCurrentDisplay(adjustments:)` assigned to
    /// `displayAdjustments` as a side effect (SessionPipeline.swift:1116).
    func testRenderPreviewDoesNotMutateCommittedAdjustments() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (pipeline, source) = try PreviewRenderTests.runningPipeline(sandbox: sandbox)
        defer { source.stop() }

        var committed = DisplayAdjustments.neutral
        committed.blackPoint = 0.01
        pipeline.displayAdjustments = committed

        var pending = DisplayAdjustments.neutral
        pending.blackPoint = 0.18
        _ = pipeline.renderPreview(source: .online, adjustments: pending)

        XCTAssertEqual(pipeline.displayAdjustments.blackPoint, 0.01,
                       "a preview render must leave the committed adjustments alone")
    }

    /// The preview must actually honour the adjustments passed in — otherwise it would show
    /// the committed look and silently mislead.
    func testRenderPreviewReflectsTheAdjustmentsPassedIn() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (pipeline, source) = try PreviewRenderTests.runningPipeline(sandbox: sandbox)
        defer { source.stop() }

        var dark = DisplayAdjustments.neutral;  dark.blackPoint = 0.0
        var light = DisplayAdjustments.neutral; light.blackPoint = 0.15
        let a = try XCTUnwrap(pipeline.renderPreview(source: .online, adjustments: dark))
        let b = try XCTUnwrap(pipeline.renderPreview(source: .online, adjustments: light))
        XCTAssertNotEqual(PreviewTestSupport.sha256(a), PreviewTestSupport.sha256(b),
                          "different adjustments must produce a different preview")
    }

    /// The preview renders from the downsampled proxy, so it is bounded by previewLongEdge.
    func testPreviewIsRenderedFromTheDownsampledProxy() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (pipeline, source) = try PreviewRenderTests.runningPipeline(sandbox: sandbox)
        defer { source.stop() }

        let cg = try XCTUnwrap(pipeline.renderPreview(source: .online, adjustments: .neutral))
        XCTAssertLessThanOrEqual(max(cg.width, cg.height), SessionPipeline.previewLongEdge)
    }

    /// Finding 2: the spec requires a CACHED proxy. Without one, every slider tick walks the
    /// full 26 MP stack to build the downsample, so the drag is still O(26 MP) and only the
    /// final render got cheaper. Adjustment-only re-renders must reuse the proxy.
    func testRepeatedPreviewRendersReuseTheCachedProxy() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (pipeline, source) = try PreviewRenderTests.runningPipeline(sandbox: sandbox)
        defer { source.stop() }

        var a = DisplayAdjustments.neutral; a.blackPoint = 0.02
        var b = DisplayAdjustments.neutral; b.blackPoint = 0.06
        _ = pipeline.renderPreview(source: .online, adjustments: a)
        let buildsAfterFirst = pipeline.previewProxyBuildCountForTest
        _ = pipeline.renderPreview(source: .online, adjustments: b)
        _ = pipeline.renderPreview(source: .online, adjustments: a)

        XCTAssertEqual(pipeline.previewProxyBuildCountForTest, buildsAfterFirst,
                       "changing only the adjustments must reuse the cached proxy — adjustments are "
                       + "deliberately NOT part of the cache key, the proxy is linear and pre-adjustment")
    }

    /// Pins the PER-SOURCE cache. The reuse test above only exercises one source, so a
    /// single-slot cache would still pass it — and hold-to-compare is exactly the
    /// clean -> online -> clean pattern a single slot handles worst, evicting and rebuilding
    /// from the full-resolution stack on every press AND release. This fails on a single slot.
    func testSwitchingSourceAndBackReusesEachProxy() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (pipeline, source) = try PreviewRenderTests.runningPipeline(sandbox: sandbox)
        defer { source.stop() }
        pipeline.configureLiveRejection(enabled: true)

        guard let (mean, coverage) = pipeline.engineForTest?.currentStackAndCoverage() else {
            return XCTFail("expected a stack")
        }
        pipeline.publishedMaster = PublishedMaster(
            image: mean,
            coverage: coverage ?? [Float](repeating: 1, count: mean.width * mean.height),
            survivorCount: pipeline.subRegistrations().count,
            key: pipeline.currentFreshnessKey())

        XCTAssertNotNil(pipeline.renderPreview(source: .clean, adjustments: .neutral))
        let afterClean = pipeline.previewProxyBuildCountForTest

        XCTAssertNotNil(pipeline.renderPreview(source: .online, adjustments: .neutral))
        let afterOnline = pipeline.previewProxyBuildCountForTest
        XCTAssertGreaterThan(afterOnline, afterClean,
                             "a different source is a different proxy — it is built once")

        // The blink release: back to clean. Its slot must still hold.
        XCTAssertNotNil(pipeline.renderPreview(source: .clean, adjustments: .neutral))
        XCTAssertEqual(pipeline.previewProxyBuildCountForTest, afterOnline,
                       "returning to clean must REUSE its slot — a single-slot cache rebuilds here, "
                       + "making every blink press and release the most expensive act in the panel")

        // And the next press likewise.
        XCTAssertNotNil(pipeline.renderPreview(source: .online, adjustments: .neutral))
        XCTAssertEqual(pipeline.previewProxyBuildCountForTest, afterOnline,
                       "and the online slot must still hold too")
    }

    /// ...but a new sub must invalidate it, or the preview would freeze on the first stack.
    func testANewSubInvalidatesTheCachedProxy() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (pipeline, source) = try PreviewRenderTests.runningPipeline(sandbox: sandbox)
        defer { source.stop() }

        _ = pipeline.renderPreview(source: .online, adjustments: .neutral)
        let before = pipeline.previewProxyBuildCountForTest
        let targetCount = pipeline.subRegistrations().count + 1

        source.send(RawFrame(image: PreviewRenderTests.richStarField(),
                             bayerPattern: nil, bottomUp: false,
                             timestamp: Date(timeIntervalSince1970: 99), sourceName: "pv9.fit",
                             identity: FileIdentity(dev: 0, ino: 0, size: 0, mtimeSec: 0,
                                                    mtimeNsec: 0, digest: "pv9"),
                             sourceURL: URL(fileURLWithPath: "/tmp/preview/pv9.fit")))
        // Capture the target BEFORE sending, or the count read may already include the new sub
        // and the wait becomes a no-op that passes for the wrong reason.
        let deadline = Date().addingTimeInterval(20)
        while pipeline.subRegistrations().count < targetCount && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        _ = pipeline.renderPreview(source: .online, adjustments: .neutral)
        XCTAssertGreaterThan(pipeline.previewProxyBuildCountForTest, before,
                             "a new sub changes the stack, so the proxy must be rebuilt")
    }

    /// The case a (generation, sub count) key would MISS: a user reject changes which master is
    /// servable while both of those stay put.
    ///
    /// The correct behaviour is NOT "rebuild the proxy" — it is "serve nothing". A reject makes
    /// the published master WRONG (it contains a now-rejected sub), so `isServable` fails and
    /// `publishedMasterFreshnessKeyIfCurrent()` returns nil: the clean preview must go away
    /// entirely until a NEW master publishes. Serving a rebuilt-but-stale clean master would
    /// make the blink comparison compare against a master that no longer exists.
    func testAUserRejectStopsServingTheCleanPreviewUntilANewMasterPublishes() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (pipeline, source) = try PreviewRenderTests.runningPipeline(sandbox: sandbox)
        defer { source.stop() }
        pipeline.configureLiveRejection(enabled: true)

        guard let (mean, coverage) = pipeline.engineForTest?.currentStackAndCoverage() else {
            return XCTFail("expected a stack")
        }
        let cov = coverage ?? [Float](repeating: 1, count: mean.width * mean.height)
        pipeline.publishedMaster = PublishedMaster(
            image: mean, coverage: cov,
            survivorCount: pipeline.subRegistrations().count,
            key: pipeline.currentFreshnessKey())

        XCTAssertNotNil(pipeline.renderPreview(source: .clean, adjustments: .neutral),
                        "precondition: a current clean master IS previewable")
        let buildsBefore = pipeline.previewProxyBuildCountForTest

        // Same generation, same sub count — only the reject state moves.
        pipeline.setUserRejected([1])
        pipeline.noteUserRejectChanged()

        XCTAssertNil(pipeline.renderPreview(source: .clean, adjustments: .neutral),
                     "a master containing a now-rejected sub must not be previewed at all")
        XCTAssertEqual(pipeline.previewProxyBuildCountForTest, buildsBefore,
                       "and nothing is rebuilt while there is nothing servable to build from")

        // A fresh pass publishes at the NEW key; the clean preview returns and is rebuilt.
        pipeline.publishedMaster = PublishedMaster(
            image: mean, coverage: cov,
            survivorCount: pipeline.subRegistrations().count - 1,
            key: pipeline.currentFreshnessKey())
        XCTAssertNotNil(pipeline.renderPreview(source: .clean, adjustments: .neutral))
        XCTAssertGreaterThan(pipeline.previewProxyBuildCountForTest, buildsBefore,
                             "the new master carries a different FreshnessKey, so the proxy is rebuilt")
    }

    /// Watcher / external-stacker mode has NO engine (SessionPipeline.swift:768 leaves it nil),
    /// so without `lastPreviewLinear` the preview would be permanently blank there.
    func testWatcherModeStillProducesAPreview() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let watch = sandbox.appendingPathComponent("watch", isDirectory: true)
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        let pipeline = SessionPipeline(watchFolder: watch, profile:
            SessionProfile(targetName: "Watch", telescope: "T", camera: "C", mount: "M",
                           filter: "F", locationLabel: "L", bortle: 5,
                           subExposureSeconds: 20, notes: ""),
            rootDirectory: sandbox.appendingPathComponent("sessions"))

        XCTAssertNil(pipeline.renderPreview(source: .online, adjustments: .neutral),
                     "no frame seen yet — the panel shows its placeholder")
        pipeline.noteWatcherFrame(PreviewTestSupport.starField(w: 2400, h: 1800))
        let cg = try XCTUnwrap(pipeline.renderPreview(source: .online, adjustments: .neutral),
                               "watcher mode must still preview, from the retained last frame")
        XCTAssertLessThanOrEqual(max(cg.width, cg.height), SessionPipeline.previewLongEdge)
    }

    /// The callback is the ACTUAL fix for "a clean master appeared but the UI never knew", and
    /// it lives in LiveAstroCore, so it gets a real test rather than a source-text grep. It must
    /// fire when a publish is INSTALLED and stay silent when one is dropped — a notification for
    /// a dropped publish would make the panel switch to a clean master that was never stored.
    func testOnCleanMasterPublishedFiresOnlyWhenAPublishIsActuallyInstalled() throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock(); private var n = 0
            func bump() { lock.withLock { n += 1 } }
            var count: Int { lock.withLock { n } }
        }
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (pipeline, source) = try PreviewRenderTests.runningPipeline(sandbox: sandbox)
        defer { source.stop() }
        pipeline.configureLiveRejection(enabled: true)

        let fired = Counter()
        pipeline.onCleanMasterPublished = { fired.bump() }
        let refiner = try XCTUnwrap(pipeline.refinerForTest())
        guard let (mean, coverage) = pipeline.engineForTest?.currentStackAndCoverage() else {
            return XCTFail("expected a stack")
        }
        let cov = coverage ?? [Float](repeating: 1, count: mean.width * mean.height)
        let key = pipeline.currentFreshnessKey()
        let result = RefineResult(image: mean, coverage: cov,
                                  survivorCount: pipeline.subRegistrations().count, skipped: 0)

        refiner.publish?(result, key)
        XCTAssertEqual(fired.count, 1, "a servable publish is installed, so the UI must be told")

        // Now make that key unservable — a user reject changes what the master MEANS — and
        // republish under it. publishRefineResult drops the result, so nothing may fire.
        pipeline.setUserRejected([1])
        pipeline.noteUserRejectChanged()
        refiner.publish?(result, key)
        XCTAssertEqual(fired.count, 1,
                       "a dropped (unservable) publish stores nothing, so it must not notify — "
                       + "otherwise the panel switches to a clean master that was never installed")
    }

    /// With live rejection off there is no clean master, and the caller must be able to tell —
    /// the blink control's disabled state depends on it.
    func testCleanSourceReturnsNilWhenNoCleanMasterIsPublished() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (pipeline, source) = try PreviewRenderTests.runningPipeline(sandbox: sandbox)
        defer { source.stop() }

        XCTAssertNil(pipeline.renderPreview(source: .clean, adjustments: .neutral),
                     "no published clean master means no clean preview")
    }

    /// `PreviewTestSupport.starField` places only 3 star blobs — plenty for the render/downsample
    /// tests it was built for (Task 1/2), but this is the first task to drive a REAL live
    /// `StackEngine` off it, and `StackEngine`'s default `seedMinStars` is 15: with only 3
    /// detectable stars every frame is rejected as `.insufficientStars` and no reference is ever
    /// seeded (confirmed by instrumenting `StarDetector.detectWithStats` directly on the base
    /// field: exactly 3 stars found). Rather than touch the shared, already-committed
    /// `PreviewTestSupport.swift` (risking its two existing consumers — the golden-hash-pinned
    /// `DisplayRenderParityTests` and `PreviewDownsampleHonestyTests`), this adds extra blobs
    /// LOCALLY on top of the same base field, at coordinates that stay outside the 320×240 crop
    /// `DisplayRenderParityTests` renders (so that pinned hash is provably untouched) and whose
    /// tiny pixel footprint doesn't move the median/MADN `PreviewDownsampleHonestyTests` checks.
    static func richStarField(w: Int = 2400, h: Int = 1800, channels: Int = 3) -> AstroImage {
        let base = PreviewTestSupport.starField(w: w, h: h, channels: channels)
        var px = base.pixels
        let plane = w * h
        let extraStars: [(Int, Int, Float)] = [
            (700, 900, 0.6), (1000, 300, 0.55), (1300, 1500, 0.65),
            (1600, 400, 0.5), (2100, 1000, 0.7), (450, 1300, 0.55),
            (1150, 700, 0.6), (1850, 1300, 0.5), (600, 1600, 0.65),
            (2000, 250, 0.55), (900, 1100, 0.6), (1700, 900, 0.5),
            (2200, 1500, 0.6), (500, 700, 0.55), (1450, 1650, 0.6)
        ]
        for c in 0..<channels {
            for (sx, sy, amp) in extraStars {
                for dy in -8...8 {
                    for dx in -8...8 {
                        let x = sx + dx, y = sy + dy
                        guard x >= 0, x < w, y >= 0, y < h else { continue }
                        let g = amp * exp(-Float(dx * dx + dy * dy) / 12.0)
                        px[c * plane + y * w + x] += g
                    }
                }
            }
        }
        return AstroImage(width: w, height: h, channels: channels, pixels: px,
                          sourceIsLinear: base.sourceIsLinear)
    }

    /// Reuses the established live-pipeline harness and the top-level `StubLiveSource`
    /// extracted in Task 1 Step 0.
    static func runningPipeline(sandbox: URL) throws -> (SessionPipeline, StubLiveSource) {
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let profile = SessionProfile(targetName: "Preview", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let engine = StackEngine()
        let frames = (0..<3).map { i in
            RawFrame(image: PreviewRenderTests.richStarField(),
                     bayerPattern: nil, bottomUp: false,
                     timestamp: Date(timeIntervalSince1970: TimeInterval(i)),
                     sourceName: "pv\(i).fit",
                     identity: FileIdentity(dev: 0, ino: 0, size: 0, mtimeSec: 0, mtimeNsec: 0,
                                            digest: "pv\(i)"),
                     sourceURL: URL(fileURLWithPath: "/tmp/preview/pv\(i).fit"))
        }
        let source = StubLiveSource(sequence: frames)
        let pipeline = SessionPipeline(nativeSource: source, engine: engine,
                                       profile: profile, rootDirectory: sessions)
        pipeline.rendersReplay = false
        try pipeline.start()
        let deadline = Date().addingTimeInterval(20)
        // Wait for ALL queued frames to settle, not just the first. `StubLiveSource` buffers
        // every frame up front, so waiting on only 1 hands callers a pipeline whose background
        // consumer is still mid-flight on frames 2 and 3 — those land moments later and bump
        // the preview cache's stack revision out from under a test that has already read
        // `previewProxyBuildCountForTest` as its baseline, producing a spurious rebuild that
        // looks like a caching bug. Settling fully here is what "running" means for this harness.
        while pipeline.subRegistrations().count < frames.count && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        return (pipeline, source)
    }
}
