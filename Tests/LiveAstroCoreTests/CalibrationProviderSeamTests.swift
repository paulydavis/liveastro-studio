import XCTest
@testable import LiveAstroCore

/// Covers the empty-folder seam in SessionPipeline.handleNative: the calibratorProvider
/// must be called exactly once, on the FIRST frame carrying metadata, and its returned
/// Calibrator must be applied to that same frame.
final class CalibrationProviderSeamTests: XCTestCase {

    private final class ControlledLiveSource: FrameSource {
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

    /// A 512×512 CFA starfield RawFrame with the given metadata. Returns the frame and
    /// its raw image (so a caller can build a "dark" equal to the frame that blanks it).
    private func makeFrame(name: String, seed: Int, meta: SourceMetadata) -> (RawFrame, AstroImage) {
        let w = 512, h = 512
        var px = [Float](repeating: 0.05, count: w * h)
        for i in 0..<24 {
            let cx = Double((i * 47 + seed * 13) % 480 + 16)
            let cy = Double((i * 83 + seed * 29) % 480 + 16)
            for y in max(0, Int(cy) - 8)...min(h - 1, Int(cy) + 8) {
                for x in max(0, Int(cx) - 8)...min(w - 1, Int(cx) + 8) {
                    let ex = Double(x) - cx, ey = Double(y) - cy
                    px[y * w + x] += 0.8 * Float(exp(-(ex * ex + ey * ey) / (2 * 3.0 * 3.0)))
                }
            }
        }
        let img = AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true)
        let frame = RawFrame(image: img, bayerPattern: .grbg, bottomUp: false,
                             timestamp: Date(timeIntervalSince1970: 0), sourceName: name, metadata: meta)
        return (frame, img)
    }

    private func meta(exp: Double) -> SourceMetadata {
        var m = SourceMetadata(); m.instrument = "ASI2600"; m.gain = 100; m.exposureSeconds = exp; m.setTempC = -10
        return m
    }

    func testProviderResolvesOnceOnFirstFrameAndIsApplied() throws {
        let sessions = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sessions) }

        let m1 = meta(exp: 180), m2 = meta(exp: 60)
        let (frame1, img1) = makeFrame(name: "Light_001.fit", seed: 1, meta: m1)
        let (frame2, _)    = makeFrame(name: "Light_002.fit", seed: 7, meta: m2)

        // Provider: record calls, and return a Calibrator whose dark == frame1's image,
        // so applying it to frame1 blanks the frame (frame1 − dark ≈ 0) → rejected,
        // proving the calibrator was applied to that frame.
        let calls = Locked([SourceMetadata]())
        let provider: (SourceMetadata) -> Calibrator? = { m in
            calls.mutate { $0.append(m) }
            return Calibrator(dark: img1, flat: nil)
        }

        let source = ControlledLiveSource()
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: SessionProfile(targetName: "Seam", telescope: "T", camera: "C",
                                            mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                            subExposureSeconds: 180, notes: ""),
                                       rootDirectory: sessions, calibratorProvider: provider)

        let rejected = Locked([String]())
        let frame1Rejected = expectation(description: "frame1 rejected after calibration blanks it")
        let frame2Handled = expectation(description: "frame2 processed")
        pipeline.onRejected = { _, name in
            rejected.mutate { $0.append(name) }
            if name == "Light_001.fit" { frame1Rejected.fulfill() }
            if name == "Light_002.fit" { frame2Handled.fulfill() }
        }
        pipeline.onUpdate = { _, rec in if rec.index >= 0 { frame2Handled.fulfill() } }  // accepted frame2 also counts

        try pipeline.start()
        source.send(frame1)
        source.send(frame2)
        wait(for: [frame1Rejected, frame2Handled], timeout: 8)
        source.stop()

        // Exactly one resolution, on the FIRST frame's metadata.
        XCTAssertEqual(calls.value.count, 1, "provider must resolve exactly once")
        XCTAssertEqual(calls.value.first, m1, "provider must see the first frame's metadata")
        // Applied: frame1 blanked by its own dark → rejected like a starless sub.
        XCTAssertTrue(rejected.value.contains("Light_001.fit"), "the provider's calibrator must be applied to frame1")
    }

    /// Minimal thread-safe box (onRejected/onUpdate fire on the pipeline callback thread).
    private final class Locked<T>: @unchecked Sendable {
        private let lock = NSLock(); private var v: T
        init(_ initial: T) { v = initial }
        var value: T { lock.lock(); defer { lock.unlock() }; return v }
        func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
    }
}
