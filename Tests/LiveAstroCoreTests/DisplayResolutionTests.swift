import XCTest
import ImageIO
@testable import LiveAstroCore

final class DisplayResolutionTests: XCTestCase {
    private final class Deliveries: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [DisplayDelivery] = []
        private var inputs: [SessionPipeline.RenderInputFacts] = []
        func appendInput(_ input: SessionPipeline.RenderInputFacts) {
            lock.lock(); defer { lock.unlock() }; inputs.append(input)
        }
        var renderInputs: [SessionPipeline.RenderInputFacts] {
            lock.lock(); defer { lock.unlock() }; return inputs
        }
        func append(_ value: DisplayDelivery) {
            lock.lock(); defer { lock.unlock() }; values.append(value)
        }
        var all: [DisplayDelivery] {
            lock.lock(); defer { lock.unlock() }; return values
        }
    }

    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    // Wide, short fixture crosses the real cap without a 26 MP fixture's cost. Twenty
    // stars stay inside the image; this does not shrink/crop a full-size star fixture.
    private func field() -> AstroImage {
        let w = 2700, h = 320
        var pixels = [Float](repeating: 0.04, count: w * h)
        for row in 0..<4 { for column in 0..<5 {
            let sx = 100 + column * 510 + row * 13, sy = 40 + row * 70
            for dy in -8...8 { for dx in -8...8 {
                pixels[(sy + dy) * w + sx + dx] += Float(0.5 + Double(column) * 0.07)
                    * exp(-Float(dx * dx + dy * dy) / 12)
            } }
        } }
        return AstroImage(width: w, height: h, channels: 1, pixels: pixels, sourceIsLinear: true)
    }

    private func waitFor(_ message: String, _ predicate: @escaping () -> Bool) throws {
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        guard XCTWaiter.wait(for: [finished], timeout: 60) == .completed else {
            XCTFail("prerequisite did not complete: \(message)")
            throw NSError(domain: "DisplayResolutionTests", code: 1)
        }
    }

    private func native() throws -> (SessionPipeline, StubLiveSource, Deliveries) {
        let source = StubLiveSource(sequence: [])
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
            profile: SessionProfile(targetName: "Resolution", subExposureSeconds: 1),
            rootDirectory: try sandbox())
        pipeline.rendersReplay = false
        let deliveries = Deliveries()
        pipeline.onDisplayUpdate = { deliveries.append($0) }
        pipeline.displayRenderInputProbeForTest = { deliveries.appendInput($0) }
        try pipeline.start()
        addTeardownBlock { _ = try? pipeline.end() }
        source.send(RawFrame(image: field(), bayerPattern: nil, bottomUp: false,
            timestamp: Date(), sourceName: "one.fit"))
        try waitFor("native frame saved") { deliveries.all.contains { $0.record != nil } }
        return (pipeline, source, deliveries)
    }

    private func apply(_ pipeline: SessionPipeline, _ deliveries: Deliveries) throws -> DisplayDelivery {
        let revision = try XCTUnwrap(pipeline.applyCommittedAdjustments(DisplayAdjustments(blackPoint: 0.1)))
        try waitFor("Apply delivered") { deliveries.all.contains { $0.revision >= revision && $0.broadcastImage != nil } }
        return try XCTUnwrap(deliveries.all.last { $0.revision >= revision && $0.broadcastImage != nil })
    }

    private func assertCapped(_ delivery: DisplayDelivery, file: StaticString = #filePath, line: UInt = #line) throws {
        for image in [delivery.previewImage, delivery.broadcastImage] {
            let cg = try XCTUnwrap(image, file: file, line: line)
            XCTAssertEqual(cg.width, 2560, file: file, line: line)
            XCTAssertLessThan(cg.height, 320, file: file, line: line)
        }
    }

    // Fails if the native frame cap is missing OR only the PNG saver is capped.
    // The archival assertions catch accidentally downsampling the accumulator/master.
    func testNativeFrameApplyAndEndCapDisplaysButKeepMasterPixels() throws {
        let (pipeline, _, deliveries) = try native()
        let initial = try XCTUnwrap(deliveries.all.first { $0.record != nil })
        try assertCapped(initial)
        XCTAssertGreaterThan(try XCTUnwrap(initial.record).width, 2560)
        XCTAssertTrue(pipeline.writeMasterSnapshot())
        let directory = try XCTUnwrap(pipeline.sessionDir)
        let before = try FITSReader.read(Data(contentsOf: directory.appendingPathComponent("master.fit")))
        try assertCapped(apply(pipeline, deliveries))
        let inputs = deliveries.renderInputs
        XCTAssertTrue(inputs.contains { $0.origin == "frame" })
        XCTAssertTrue(inputs.contains { $0.origin == "refresh" })
        XCTAssertTrue(inputs.allSatisfy { $0.width == 2560 }, "cap before DBE/stretch, not after rendering")
        _ = try pipeline.end()
        try assertCapped(XCTUnwrap(deliveries.all.last))
        let after = try FITSReader.read(Data(contentsOf: directory.appendingPathComponent("master.fit")))
        XCTAssertGreaterThan(after.width, 2560)
        XCTAssertEqual(after.width, before.width)
        XCTAssertEqual(after.height, before.height)
        XCTAssertEqual(after.pixels, before.pixels, "display adjustment/cap must not alter archival pixels")
    }

    // Fails if the clean resolver bypasses the cap, or substitutes the online image.
    func testCleanMasterRefreshIsCappedAndStillDistinctFromOnline() throws {
        let (pipeline, source, deliveries) = try native()
        pipeline.configureLiveRejection(enabled: true)
        _ = try apply(pipeline, deliveries)
        pipeline.refinerForTest()?.quiesce()
        let clean = AstroImage(width: 2700, height: 320, channels: 1,
            pixels: [Float](repeating: 0.5, count: 2700 * 320), sourceIsLinear: true)
        pipeline.publishedMaster = PublishedMaster(image: clean,
            coverage: [Float](repeating: 1, count: 2700 * 320),
            survivorCount: 1, key: pipeline.currentFreshnessKey())
        XCTAssertNotNil(pipeline.publishedMasterIfCurrent())
        let delivery = try apply(pipeline, deliveries)
        try assertCapped(delivery)
        XCTAssertEqual(delivery.cleanMasterSubCount, 1)
        let broadcast = try XCTUnwrap(delivery.broadcastImage)
        let preview = try XCTUnwrap(delivery.previewImage)
        XCTAssertNotEqual(PreviewTestSupport.sha256(broadcast), PreviewTestSupport.sha256(preview))
        let expected = try pipeline.renderForTest(clean.downsampled(maxLongEdge: 2560),
            adjustments: DisplayAdjustments(blackPoint: 0.1))
        XCTAssertEqual(PreviewTestSupport.sha256(broadcast), PreviewTestSupport.sha256(expected))
        source.send(RawFrame(image: field(), bayerPattern: nil, bottomUp: false,
            timestamp: Date(), sourceName: "two.fit"))
        try waitFor("second native frame saved") { deliveries.all.contains { $0.record?.sourceFile == "two.fit" } }
        let next = try XCTUnwrap(deliveries.all.last { $0.record?.sourceFile == "two.fit" })
        try assertCapped(next)
        XCTAssertEqual(next.cleanMasterSubCount, 1)
        XCTAssertEqual(PreviewTestSupport.sha256(try XCTUnwrap(next.broadcastImage)), PreviewTestSupport.sha256(expected))
        let url = try XCTUnwrap(pipeline.sessionDir).appendingPathComponent("latest.png")
        let png = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let saved = try XCTUnwrap(CGImageSourceCreateImageAtIndex(png, 0, nil))
        XCTAssertEqual(PreviewTestSupport.sha256(saved), PreviewTestSupport.sha256(expected),
            "saved and delivered clean surfaces must agree")
    }

    // Fails if watcher frames are capped only at save, or their retained cap is nil on Apply.
    func testWatcherFrameAndApplyUseSameDisplayCap() throws {
        let root = try sandbox(), watch = try sandbox()
        let pipeline = SessionPipeline(watchFolder: watch,
            profile: SessionProfile(targetName: "Watcher", subExposureSeconds: 1), rootDirectory: root)
        pipeline.rendersReplay = false
        let deliveries = Deliveries()
        pipeline.onDisplayUpdate = { deliveries.append($0) }
        try pipeline.start()
        defer { _ = try? pipeline.end() }
        let image = field()
        try FITSWriter.float32(width: image.width, height: image.height, channels: image.channels,
            pixels: image.pixels).write(to: watch.appendingPathComponent("live_stack.fit"))
        try waitFor("watcher saved image") { deliveries.all.contains { $0.record != nil } }
        try assertCapped(XCTUnwrap(deliveries.all.first { $0.record != nil }))
        try assertCapped(apply(pipeline, deliveries))
    }
}
