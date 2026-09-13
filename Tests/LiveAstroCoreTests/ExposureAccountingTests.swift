import XCTest
@testable import LiveAstroCore

final class ExposureAccountingTests: XCTestCase {
    func testSessionAccessorUsesSnapshotTotalNotMixedScalar() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = SessionManager(rootDirectory: root)
        _ = try session.startSession(profile: SessionProfile(targetName: "Mixed", subExposureSeconds: 30))
        var exposure = ExposureSummary()
        for seconds in [30.0, 300] { exposure.add(FrameExposure(metadata: frame(seconds).metadata, fallback: 0)) }
        try session.recordSnapshot(SnapshotRecord(index: 2, timestamp: Date(), sourceFile: "2.fit", snapshotFile: "2.png",
            estimatedIntegrationSeconds: 330, width: 2, height: 2, mean: 0, median: 0, stddev: 0, exposure: exposure))
        XCTAssertEqual(session.estimatedIntegrationSeconds, 330)
    }

    private func frame(_ seconds: Double?, size: Int = 256) -> RawFrame {
        var px = [Float](repeating: 0.05, count: size * size)
        if size == 256 {
            for i in 0..<20 {
                let sx = (i * 47) % 230 + 12, sy = (i * 83) % 230 + 12
                for y in (sy - 6)...(sy + 6) { for x in (sx - 6)...(sx + 6) {
                    let dx = Double(x - sx), dy = Double(y - sy)
                    px[y * size + x] += 0.8 * Float(exp(-(dx * dx + dy * dy) / 8))
                } }
            }
        }
        var meta = SourceMetadata(); meta.exposureSeconds = seconds
        return RawFrame(image: AstroImage(width: size, height: size, channels: 1, pixels: px, sourceIsLinear: true),
                        bayerPattern: nil, bottomUp: false, timestamp: Date(), sourceName: "sub.fit", metadata: meta)
    }

    func testRejectedExposureCannotEnterStackAndReseedRetiresExposure() throws {
        let engine = StackEngine()
        engine.configureExposureFallback(20)
        _ = engine.process(frame(900, size: 1))
        _ = engine.process(frame(30))
        _ = engine.process(frame(300))
        let old = try XCTUnwrap(engine.displaySnapshot())
        XCTAssertEqual(old.count, 2)
        XCTAssertEqual(old.exposure.totalSeconds, 330)
        XCTAssertNil(old.exposure.uniformSeconds)
        engine.reseed()
        _ = engine.process(frame(nil))
        let next = try XCTUnwrap(engine.displaySnapshot())
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next.exposure.totalSeconds, 20)
        XCTAssertEqual(next.exposure.estimatedFrameCount, 1)
        XCTAssertEqual(old.exposure.totalSeconds, 330, "retained pixels retain their own accounting")
    }

    func testBatchCommitAndSeedUseOriginalMetadataAcrossPreparation() throws {
        let engine = StackEngine()
        engine.configureExposureFallback(20)
        let raw = frame(30)
        let stripped = RawFrame(image: raw.image, bayerPattern: nil, bottomUp: false,
                                timestamp: Date(), sourceName: "prepared.fit")
        XCTAssertTrue(engine.seedReference(stripped, minRows: .max, exposure: engine.resolvedExposure(raw.metadata)))
        var meta = SourceMetadata(); meta.exposureSeconds = 300
        engine.commit(image: raw.image, mask: [Float](repeating: 1, count: 256 * 256), minRows: .max, metadata: meta)
        let snapshot = try XCTUnwrap(engine.masterSnapshotState())
        XCTAssertEqual(snapshot.exposure.totalSeconds, 330)
        XCTAssertEqual(snapshot.exposure.estimatedFrameCount, 0)
    }

    func testMixedCaptionAndEstimateAreExplicit() {
        var summary = ExposureSummary()
        summary.add(FrameExposure(metadata: frame(30).metadata, fallback: 20))
        summary.add(FrameExposure(metadata: frame(300).metadata, fallback: 20))
        XCTAssertEqual(summary.caption, "5m 30s · 2 subs")
        summary.add(FrameExposure(metadata: nil, fallback: 20))
        XCTAssertEqual(summary.caption, "5m 50s · 3 subs (1 estimated)")
    }

    func testRestackUsesRecordedFallbackAndOnlyKeptFrames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var records = [SubFrameRecord]()
        for (i, seconds) in [nil, 30.0, 300.0].enumerated() {
            let raw = frame(seconds)
            let name = "\(i).fit"
            try FITSWriter.float32(width: 256, height: 256, channels: 1, pixels: raw.image.pixels,
                                  metadata: raw.metadata).write(to: dir.appendingPathComponent(name))
            records.append(SubFrameRecord(index: i, timestamp: Date(), sourceFile: name, starCount: 20,
                backgroundSigma: 0, weight: 1, outcome: .stacked, rejectionReason: nil, rejectedByUser: i == 1,
                exposure: FrameExposure(metadata: raw.metadata, fallback: 20)))
        }
        let subs = RestackPlanning.survivorSubs(subFrames: records, in: dir)
        let report = try RestackCoordinator.restack(subs: subs, makeEngine: { StackEngine() }, fallbackExposureSeconds: 999)
        XCTAssertEqual(report.stackedCount, 2)
        XCTAssertEqual(report.exposure?.totalSeconds, 320, "original 20s fallback survives a changed profile")
        XCTAssertEqual(report.exposure?.estimatedFrameCount, 1)
        let header = try FITSReader.readHeader(RestackPlanning.encodeMaster(report, neutralize: false,
                                                                          metadata: nil, subExposureSeconds: 999))
        XCTAssertEqual(Double(header.keywords["TOTALEXP"] ?? ""), 320)
        XCTAssertEqual(Int(header.keywords["EXPEST"] ?? ""), 1)
    }

    private final class LiveSource: FrameSource {
        let frames: AsyncStream<RawFrame>
        let continuation: AsyncStream<RawFrame>.Continuation
        let isFinite = false
        let totalCount: Int?
        init(_ values: [RawFrame]) {
            totalCount = values.count
            let pair = AsyncStream<RawFrame>.makeStream()
            frames = pair.stream; continuation = pair.continuation
            for value in values { continuation.yield(value) }
        }
        func start() throws {}
        func stop() { continuation.finish() }
    }

    func testNativeLiveDeliveryAndPersistedFramesCarryExposure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = SessionPipeline(nativeSource: LiveSource([frame(nil), frame(300), frame(300)]),
            engine: StackEngine(), profile: SessionProfile(targetName: "Mixed", subExposureSeconds: 20), rootDirectory: root,
            calibrator: Calibrator(dark: nil, flat: AstroImage(width: 256, height: 256, channels: 1,
                pixels: [Float](repeating: 1, count: 256 * 256), sourceIsLinear: true)))
        let delivered = DispatchSemaphore(value: 0)
        pipeline.onDisplayUpdate = { update in
            if update.exposure?.frameCount == 3 {
                XCTAssertEqual(update.integrationSeconds, 620)
                XCTAssertEqual(update.previewIntegrationSeconds, 620)
                XCTAssertEqual(update.exposure?.caption, "10m 20s · 3 subs (1 estimated)")
                delivered.signal()
            }
        }
        try pipeline.start()
        XCTAssertEqual(delivered.wait(timeout: .now() + 30), .success)
        let dir = try XCTUnwrap(pipeline.sessionDir)
        _ = try pipeline.end()
        let manifest = try ManifestCoding.decoder().decode(SessionManifest.self,
            from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.subFrames?.compactMap(\.exposure).map(\.seconds), [20, 300, 300])
        XCTAssertEqual(manifest.exposure?.totalSeconds, 620)
    }

    func testShallowCleanDeliveryAndFinalMasterKeepTheirOwnExposure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let values = [30.0, 300, 300, 300, 300, 600].enumerated().map { i, seconds -> RawFrame in
            let raw = frame(seconds)
            return RawFrame(image: raw.image, bayerPattern: nil, bottomUp: false, timestamp: raw.timestamp,
                sourceName: "\(i).fit", metadata: raw.metadata, sourceURL: root.appendingPathComponent("\(i).fit"))
        }
        let engine = StackEngine()
        let pipeline = SessionPipeline(nativeSource: LiveSource(values), engine: engine,
            profile: SessionProfile(targetName: "Clean", subExposureSeconds: 20), rootDirectory: root)
        let consumed = DispatchSemaphore(value: 0)
        let delivered = DispatchSemaphore(value: 0)
        pipeline.onDisplayUpdate = { update in
            if update.cleanMasterSubCount == 5 {
                XCTAssertEqual(update.integrationSeconds, 1230)
                XCTAssertEqual(update.previewIntegrationSeconds, 1830)
                delivered.signal()
            }
        }
        pipeline.onImportProgress = { count, _, _, _ in if count == 6 { consumed.signal() } }
        try pipeline.start()
        XCTAssertEqual(consumed.wait(timeout: .now() + 30), .success)
        pipeline.configureLiveRejection(enabled: true)
        let key = pipeline.currentFreshnessKey()
        XCTAssertEqual(key.survivorSubIndices.count, 6, "prerequisite: six registered contributors")
        let shallowKey = FreshnessKey(stackGeneration: key.stackGeneration,
            survivorSubIndices: Array(key.survivorSubIndices.prefix(5)), userRejectGeneration: key.userRejectGeneration,
            kappa: key.kappa, maxSampleBytes: key.maxSampleBytes, liveRejectionEpoch: key.liveRejectionEpoch)
        var exposure = ExposureSummary()
        for value in values.prefix(5) { exposure.add(FrameExposure(metadata: value.metadata, fallback: 20)) }
        // Represent an already-published five-sub result. Raw paths deliberately do not exist,
        // so End's deeper refine fails and must retain this servable result's own accounting.
        let publish = try XCTUnwrap(pipeline.refinerForTest()?.publish)
        publish(RefineResult(image: values[0].image, coverage: [Float](repeating: 5, count: 256 * 256),
            survivorCount: 5, skipped: 0, exposure: exposure), shallowKey)
        pipeline.refreshDisplay()
        XCTAssertEqual(delivered.wait(timeout: .now() + 30), .success)
        let dir = try XCTUnwrap(pipeline.sessionDir)
        _ = try pipeline.end()
        let header = try FITSReader.readHeader(Data(contentsOf: dir.appendingPathComponent("master.fit")))
        XCTAssertEqual(Int(header.keywords["STACKCNT"] ?? ""), 5)
        XCTAssertEqual(Double(header.keywords["TOTALEXP"] ?? ""), 1230)
        let manifest = try ManifestCoding.decoder().decode(SessionManifest.self,
            from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.exposure?.totalSeconds, 1230)
        XCTAssertEqual(manifest.exposure?.frameCount, 5)
    }
}
