import XCTest
@testable import LiveAstroCore

final class SessionPipelineShutdownTests: XCTestCase {
    /// A live (isFinite == false) source that yields exactly one seed frame and then never
    /// finishes. Combined with a consumer callback that blocks forever (below), the consume
    /// task is wedged INSIDE synchronous frame handling — unresponsive even to cancellation,
    /// exactly the drain-timeout condition P1-3 must handle without finalizing a racing stack.
    final class WedgingLiveSource: FrameSource {
        let frames: AsyncStream<RawFrame>
        var isFinite: Bool { false }
        var totalCount: Int? { nil }
        init(seed: RawFrame) {
            frames = AsyncStream { cont in
                cont.yield(seed)
                // Never finish: the stream stays open so the consumer stays live.
            }
        }
        func start() throws {}
        func stop() {}
    }

    /// A ≥15-star seed frame so the engine accepts it and fires onUpdate (our block point).
    private func seedFrame() -> RawFrame {
        let w = 256, h = 256
        var px = [Float](repeating: 0.05, count: w * h)
        var pts: [(Int, Int)] = []
        for i in 0..<20 { pts.append(((i * 47) % 240 + 8, (i * 83) % 240 + 8)) }
        for (sx, sy) in pts {
            for y in max(0, sy - 6)...min(h - 1, sy + 6) {
                for x in max(0, sx - 6)...min(w - 1, sx + 6) {
                    let dx = Double(x - sx), dy = Double(y - sy)
                    px[y * w + x] += 0.8 * Float(exp(-(dx * dx + dy * dy) / (2 * 2.0 * 2.0)))
                }
            }
        }
        let img = AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true)
        return RawFrame(image: img, bayerPattern: nil, bottomUp: false,
                        timestamp: Date(timeIntervalSince1970: 0), sourceName: "seed.fit")
    }

    func testEndThrowsShutdownTimeoutWhenConsumerWedged() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let profile = SessionProfile(targetName: "Hang Field", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let pipeline = SessionPipeline(nativeSource: WedgingLiveSource(seed: seedFrame()),
                                       engine: StackEngine(), profile: profile, rootDirectory: sessions)
        // Wedge the consumer inside synchronous frame handling: onUpdate blocks forever, so the
        // consume task cannot return even after cancellation → drain must give up and throw.
        let wedged = DispatchSemaphore(value: 0)
        pipeline.onUpdate = { _, _ in wedged.wait() }   // never signalled
        // Shrink the drain deadlines so the test runs fast.
        pipeline.drainPrimaryTimeout = .milliseconds(200)
        pipeline.drainGraceTimeout = .milliseconds(200)
        try pipeline.start()
        // Give the consumer a moment to enter the wedged callback before ending.
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertThrowsError(try pipeline.end()) { error in
            XCTAssertEqual(error as? SessionPipelineError, .shutdownTimeout,
                           "end() must throw shutdownTimeout rather than finalizing a racing stack")
        }
        wedged.signal()   // release the wedged task so the process can exit cleanly
    }

    /// A source that throws on start(), and can be flipped to succeed on a retry.
    final class FlakyStartSource: FrameSource {
        let frames: AsyncStream<RawFrame>
        var isFinite: Bool { false }
        var totalCount: Int? { nil }
        var shouldThrow = true
        init() { frames = AsyncStream { $0.finish() } }
        func start() throws {
            if shouldThrow { throw NSError(domain: "test", code: 1) }
        }
        func stop() {}
    }

    func testStartRollsBackOnSourceStartFailure() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let profile = SessionProfile(targetName: "Flaky", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let source = FlakyStartSource()
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: profile, rootDirectory: sessions)

        // First start(): the source throws → start() must roll back the just-created session.
        XCTAssertThrowsError(try pipeline.start())
        XCTAssertNotEqual(pipeline.session.state, .running,
                          "a failed start must not leave the session marked running")

        // Retry must NOT hit alreadyRunning.
        source.shouldThrow = false
        XCTAssertNoThrow(try pipeline.start(),
                         "after a rolled-back start, a retry must succeed (not alreadyRunning)")
    }
}
