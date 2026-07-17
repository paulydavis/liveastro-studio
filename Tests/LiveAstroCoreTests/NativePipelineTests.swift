import XCTest
@testable import LiveAstroCore

final class NativePipelineTests: XCTestCase {
    final class ControlledLiveSource: FrameSource {
        let frames: AsyncStream<RawFrame>
        private let continuation: AsyncStream<RawFrame>.Continuation
        var isFinite: Bool { false }
        var totalCount: Int? { nil }

        init() {
            var cont: AsyncStream<RawFrame>.Continuation!
            frames = AsyncStream { cont = $0 }
            continuation = cont
        }

        func start() throws {}
        func stop() { continuation.finish() }
        func send(_ frame: RawFrame) { continuation.yield(frame) }
    }

    /// Mono starfield FITS subs (no BAYERPAT — engine's mono path), one starless.
    func writeSub(_ dir: URL, name: String, stars: [(Double, Double)]) throws {
        var px = [Float](repeating: 0.05, count: 256 * 256)
        for s in stars {
            for y in max(0, Int(s.1) - 6)...min(255, Int(s.1) + 6) {
                for x in max(0, Int(s.0) - 6)...min(255, Int(s.0) + 6) {
                    let dx = Double(x) - s.0, dy = Double(y) - s.1
                    px[y * 256 + x] += 0.8 * Float(exp(-(dx * dx + dy * dy) / (2 * 2.0 * 2.0)))
                }
            }
        }
        try FITSWriter.float32(width: 256, height: 256, channels: 1, pixels: px)
            .write(to: dir.appendingPathComponent(name))
    }

    private func profile(_ target: String = "Test Field", subExposureSeconds: Double = 20) -> SessionProfile {
        SessionProfile(targetName: target, telescope: "T", camera: "C",
                       mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                       subExposureSeconds: subExposureSeconds, notes: "")
    }

    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func readManifest(_ dir: URL) throws -> SessionManifest {
        try ManifestCoding.decoder().decode(SessionManifest.self,
            from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
    }

    private func readMasterHeader(_ dir: URL) throws -> FITSHeader {
        try FITSReader.readHeader(Data(contentsOf: dir.appendingPathComponent("master.fit")))
    }

    private func wait(for expectation: XCTestExpectation, timeout: TimeInterval = 5) {
        wait(for: [expectation], timeout: timeout)
    }

    private static func unmatchedField(name: String) -> RawFrame {
        let width = 512, height = 512
        let points: [(Double, Double)] = [
            (30, 30), (470, 35), (70, 470), (460, 460), (250, 40),
            (40, 250), (470, 250), (250, 470), (130, 70), (390, 120),
            (100, 380), (390, 390), (190, 210), (320, 280), (260, 350),
            (170, 430), (430, 180), (80, 150), (220, 90), (340, 450),
        ]
        var px = [Float](repeating: 0.05, count: width * height)
        for (cx, cy) in points {
            for y in max(0, Int(cy) - 8)...min(height - 1, Int(cy) + 8) {
                for x in max(0, Int(cx) - 8)...min(width - 1, Int(cx) + 8) {
                    let ex = Double(x) - cx, ey = Double(y) - cy
                    px[y * width + x] += 0.8 * Float(exp(-(ex * ex + ey * ey) / (2 * 3.0 * 3.0)))
                }
            }
        }
        let img = AstroImage(width: width, height: height, channels: 1, pixels: px, sourceIsLinear: true)
        return RawFrame(image: img, bayerPattern: .grbg, bottomUp: false,
                        timestamp: Date(timeIntervalSince1970: 0), sourceName: name)
    }

    func testImportEndToEnd() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let subsDir = sandbox.appendingPathComponent("subs")
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: subsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        var field: [(Double, Double)] = []
        for i in 0..<20 {
            field.append((Double((i * 47) % 240 + 8), Double((i * 83) % 240 + 8)))
        }
        try writeSub(subsDir, name: "Light_001.fit", stars: field)
        try writeSub(subsDir, name: "Light_002.fit", stars: field.map { ($0.0 + 2.4, $0.1 - 1.1) })
        try writeSub(subsDir, name: "Light_003.fit", stars: [])          // rejected
        try writeSub(subsDir, name: "Light_004.fit", stars: field.map { ($0.0 - 1.2, $0.1 + 0.8) })

        let profile = SessionProfile(targetName: "Test Field", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let source = FolderFrameSource(folder: subsDir, mode: .importOnce, fileNamePrefix: "Light_")
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: profile, rootDirectory: sessions)
        var rejected: [String] = []
        pipeline.onRejected = { _, name in rejected.append(name) }
        try pipeline.start()
        let replayURL = try pipeline.end()   // end() drains the finite import stream first

        XCTAssertEqual(rejected, ["Light_003.fit"])
        let sessionDir = replayURL.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: replayURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("master.fit").path))
        let manifest = try ManifestCoding.decoder().decode(SessionManifest.self,
            from: Data(contentsOf: sessionDir.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.snapshots.count, 3)
        XCTAssertEqual(manifest.snapshots.last?.estimatedIntegrationSeconds, 60)   // 3 accepted × 20 s
        XCTAssertEqual(manifest.masterOutcome, .written)
        XCTAssertEqual(manifest.stackFrameCount, 3)
        XCTAssertEqual(manifest.sessionAcceptedCount, 3)
        XCTAssertEqual(manifest.sessionRejectedCount, 1)
        // master.fit round-trips through our own reader.
        // The subs use small sub-pixel offsets so crop-to-overlap may trim a few
        // edge pixels; assert a sensible positive width rather than an exact 256.
        let master = try FITSReader.read(Data(contentsOf: sessionDir.appendingPathComponent("master.fit")))
        // Crop-to-overlap trims ~2–3 px of ragged partial-coverage border from the subs' small drift offsets
        XCTAssertEqual(master.width, 251)
        XCTAssertEqual(master.height, 253)
        let header = try readMasterHeader(sessionDir)
        XCTAssertEqual(Int(header.keywords["STACKCNT"] ?? ""), 3)
        XCTAssertEqual(Double(header.keywords["TOTALEXP"] ?? ""), 60)
    }

    /// Cold2 M1 (red-first): a SECOND end() on an already-ended native pipeline
    /// re-executed the whole master-write block POST-COMMIT — rewriting master.fit
    /// (new mtime) behind the sealed manifest — before endSession() finally threw
    /// notRunning. end() must throw BEFORE touching any durable artifact.
    func testSecondEndThrowsBeforeTouchingDurableArtifacts() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let subsDir = sandbox.appendingPathComponent("subs")
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: subsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        var field: [(Double, Double)] = []
        for i in 0..<20 {
            field.append((Double((i * 47) % 240 + 8), Double((i * 83) % 240 + 8)))
        }
        try writeSub(subsDir, name: "Light_001.fit", stars: field)
        try writeSub(subsDir, name: "Light_002.fit", stars: field.map { ($0.0 + 1.5, $0.1 - 0.9) })

        let profile = SessionProfile(targetName: "Double End", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let source = FolderFrameSource(folder: subsDir, mode: .importOnce, fileNamePrefix: "Light_")
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: profile, rootDirectory: sessions)
        try pipeline.start()
        let replayURL = try pipeline.end()
        let masterURL = replayURL.deletingLastPathComponent().appendingPathComponent("master.fit")
        let bytesBefore = try Data(contentsOf: masterURL)
        let mtimeBefore = try XCTUnwrap(FileManager.default
            .attributesOfItem(atPath: masterURL.path)[.modificationDate] as? Date)

        Thread.sleep(forTimeInterval: 0.05)   // any rewrite would move the mtime
        XCTAssertThrowsError(try pipeline.end(), "a second end() must throw") {
            XCTAssertEqual($0 as? SessionError, .notRunning)
        }

        let bytesAfter = try Data(contentsOf: masterURL)
        let mtimeAfter = try XCTUnwrap(FileManager.default
            .attributesOfItem(atPath: masterURL.path)[.modificationDate] as? Date)
        XCTAssertEqual(bytesAfter, bytesBefore, "master.fit bytes must be untouched")
        XCTAssertEqual(mtimeAfter, mtimeBefore,
                       "master.fit must not be rewritten by a second end() (mtime moved)")
    }

    func testManualReseedWritesMasterFromOnlyNewCurrentStackButKeepsSessionTotals() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        let source = ControlledLiveSource()
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: profile("Manual Reseed", subExposureSeconds: 30),
                                       rootDirectory: sessions)
        let oldUpdates = expectation(description: "old-stack accepted frames")
        oldUpdates.expectedFulfillmentCount = 2
        let newUpdates = expectation(description: "new-stack accepted frames")
        newUpdates.expectedFulfillmentCount = 2
        let updateLock = NSLock()
        var accepted = 0
        pipeline.onUpdate = { _, _ in
            updateLock.withLock {
                accepted += 1
                if accepted <= 2 {
                    oldUpdates.fulfill()
                } else {
                    newUpdates.fulfill()
                }
            }
        }

        try pipeline.start()
        source.send(FaultMatrixLifecycleTests.starField(name: "old_000.fit", dx: 0, dy: 0))
        source.send(FaultMatrixLifecycleTests.starField(name: "old_001.fit", dx: 1.1, dy: -0.9))
        wait(for: oldUpdates)
        XCTAssertEqual(pipeline.reseed(), .reseeded)
        source.send(FaultMatrixLifecycleTests.starField(name: "new_000.fit", dx: 0, dy: 0))
        source.send(FaultMatrixLifecycleTests.starField(name: "new_001.fit", dx: -1.2, dy: 0.8))
        wait(for: newUpdates)

        let replayURL = try pipeline.end()
        let dir = replayURL.deletingLastPathComponent()
        let manifest = try readManifest(dir)
        let header = try readMasterHeader(dir)

        XCTAssertEqual(Int(header.keywords["STACKCNT"] ?? ""), 2)
        XCTAssertEqual(Double(header.keywords["TOTALEXP"] ?? ""), 60)
        XCTAssertEqual(manifest.masterOutcome, .written)
        XCTAssertEqual(manifest.stackFrameCount, 2)
        XCTAssertEqual(manifest.sessionAcceptedCount, 4)
        XCTAssertEqual(manifest.sessionRejectedCount, 0)
    }

    func testManualReseedWithoutNewSeedEndsAwaitingSeedWithoutMaster() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        let source = ControlledLiveSource()
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: profile("Awaiting Manual Seed"),
                                       rootDirectory: sessions)
        let update = expectation(description: "initial accepted frame")
        var logs: [String] = []
        let logLock = NSLock()
        pipeline.onUpdate = { _, _ in update.fulfill() }
        pipeline.onLog = { msg in logLock.withLock { logs.append(msg) } }

        try pipeline.start()
        source.send(FaultMatrixLifecycleTests.starField(name: "old_000.fit", dx: 0, dy: 0))
        wait(for: update)
        XCTAssertEqual(pipeline.reseed(), .reseeded)

        let replayURL = try pipeline.end()
        let dir = replayURL.deletingLastPathComponent()
        let manifest = try readManifest(dir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("master.fit").path))
        XCTAssertEqual(manifest.masterOutcome, .awaitingSeed)
        XCTAssertEqual(manifest.stackFrameCount, 0)
        XCTAssertEqual(manifest.sessionAcceptedCount, 1)
        XCTAssertEqual(manifest.sessionRejectedCount, 0)
        XCTAssertTrue(logLock.withLock { logs }.contains {
            $0.contains("reference cleared by reseed (manual or automatic) and never re-seeded")
        })
    }

    func testZeroFramesEndsNoFramesWithoutMaster() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        let source = ControlledLiveSource()
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: profile("No Frames"), rootDirectory: sessions)
        var logs: [String] = []
        let logLock = NSLock()
        pipeline.onLog = { msg in logLock.withLock { logs.append(msg) } }

        try pipeline.start()
        let replayURL = try pipeline.end()
        let dir = replayURL.deletingLastPathComponent()
        let manifest = try readManifest(dir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("master.fit").path))
        XCTAssertEqual(manifest.masterOutcome, .noFrames)
        XCTAssertEqual(manifest.stackFrameCount, 0)
        XCTAssertEqual(manifest.sessionAcceptedCount, 0)
        XCTAssertEqual(manifest.sessionRejectedCount, 0)
        XCTAssertEqual(logLock.withLock { logs }.filter { $0 == "no frames accepted — no master written" }.count, 1)
    }

    func testFinalizationInvariantBreachThrowsAndLeavesManifestRunning() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        let source = ControlledLiveSource()
        let engine = StackEngine()
        let pipeline = SessionPipeline(nativeSource: source, engine: engine,
                                       profile: profile("Invariant Breach"), rootDirectory: sessions)
        let update = expectation(description: "initial accepted frame")
        pipeline.onUpdate = { _, _ in update.fulfill() }

        try pipeline.start()
        source.send(FaultMatrixLifecycleTests.starField(name: "seed.fit", dx: 0, dy: 0))
        wait(for: update)
        engine.forceAccumulatorLossForTesting()

        XCTAssertThrowsError(try pipeline.end()) { error in
            XCTAssertEqual(error as? StackEngine.FinalizationError, .invariantBreach)
        }
        let dir = try XCTUnwrap(pipeline.session.sessionDirectory)
        let manifest = try readManifest(dir)
        XCTAssertNil(manifest.endTime)
    }

    func testAutoReseedThenEndBeforeNewSeedEndsAwaitingSeedWithoutOperatorOnlyLog() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        let source = ControlledLiveSource()
        let pipeline = SessionPipeline(nativeSource: source,
                                       engine: StackEngine(autoReseedThreshold: 1),
                                       profile: profile("Awaiting Auto Seed"),
                                       rootDirectory: sessions)
        let update = expectation(description: "seed accepted")
        let rejected = expectation(description: "mismatched frame rejected")
        var logs: [String] = []
        let logLock = NSLock()
        pipeline.onUpdate = { _, _ in update.fulfill() }
        pipeline.onRejected = { _, _ in rejected.fulfill() }
        pipeline.onLog = { msg in logLock.withLock { logs.append(msg) } }

        try pipeline.start()
        source.send(FaultMatrixLifecycleTests.starField(name: "seed.fit", dx: 0, dy: 0))
        wait(for: update)
        source.send(Self.unmatchedField(name: "wrong-target.fit"))
        wait(for: rejected)

        let replayURL = try pipeline.end()
        let dir = replayURL.deletingLastPathComponent()
        let manifest = try readManifest(dir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("master.fit").path))
        XCTAssertEqual(manifest.masterOutcome, .awaitingSeed)
        XCTAssertEqual(manifest.stackFrameCount, 0)
        XCTAssertEqual(manifest.sessionAcceptedCount, 1)
        XCTAssertEqual(manifest.sessionRejectedCount, 1)
        let captured = logLock.withLock { logs }
        XCTAssertTrue(captured.contains {
            $0.contains("reference cleared by reseed (manual or automatic) and never re-seeded")
        }, "awaiting-seed log must cover automatic reseed as well as manual reseed: \(captured)")
    }
}
