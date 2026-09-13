import XCTest
@testable import LiveAstroStudio
@testable import LiveAstroCore

/// PREREQUISITES for the Apply-visibility experiment. Both must pass before that experiment's
/// results mean anything — the first attempt produced "no deliveries, no frame renders" and could
/// not distinguish a product mechanism from a broken harness.
///
/// Bounded expectations with explicit failures, and the test AWAITS asynchronously: the earlier
/// harness was @MainActor and waited with `usleep`, so `AppModel`'s delivery handler — which hops
/// to the main actor via `Task` — could never run. It instrumented a handoff and then prevented it.
final class ApplyVisibilityPrerequisiteTests: XCTestCase {

    private struct Harness {
        let pipeline: SessionPipeline
        let sandbox: URL
        let watch: URL
        let write: (Int) throws -> Void
    }

    @MainActor private func makeHarness() throws -> Harness {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let watch = sandbox.appendingPathComponent("watch", isDirectory: true)
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        let w = 1200, h = 900
        func data(_ seed: Int) -> Data {
            var px = [Float](repeating: 0, count: w * h)
            var s = UInt64(0xBEEF &+ UInt64(seed &* 7919))
            for i in 0..<(w * h) {
                s = s &* 6364136223846793005 &+ 1442695040888963407
                px[i] = 0.0104 + (Float(s >> 40) / Float(1 << 24) - 0.5) * 0.006
            }
            // 18 stars, fractional positions. Five was not enough to SEED a reference in native
            // mode, so nothing registered, nothing stacked, and no render ever happened — the
            // prerequisites failed for want of a fixture, not for a product reason.
            for (fx, fy, amp) in [(0.216, 0.239, Float(0.8)), (0.583, 0.611, 0.5),
                                  (0.792, 0.333, 0.65), (0.292, 0.500, 0.6), (0.417, 0.167, 0.55),
                                  (0.542, 0.833, 0.65), (0.667, 0.222, 0.5), (0.875, 0.556, 0.7),
                                  (0.188, 0.722, 0.55), (0.479, 0.389, 0.6), (0.771, 0.722, 0.5),
                                  (0.250, 0.889, 0.65), (0.833, 0.139, 0.55), (0.375, 0.611, 0.6),
                                  (0.708, 0.500, 0.5), (0.917, 0.833, 0.6), (0.208, 0.389, 0.55),
                                  (0.604, 0.917, 0.6)] {
                let sx = Int(fx * Double(w)), sy = Int(fy * Double(h))
                for dy in -8...8 { for dx in -8...8 {
                    let x = sx + dx, y = sy + dy
                    guard x >= 0, x < w, y >= 0, y < h else { continue }
                    px[y * w + x] += amp * exp(-Float(dx * dx + dy * dy) / 12.0)
                } }
            }
            return FITSWriter.float32(width: w, height: h, channels: 1, pixels: px)
        }
        // NATIVE "Raw subs" mode with prefix Light_ — the mode the live session actually ran in.
        // The first harness used WATCHER mode, whose frames go through `handle(_:)` and never
        // touch `renderSnapshot`, so it exercised a different code path than the one under
        // investigation AND produced no "frame"-origin renders at all.
        let source = FolderFrameSource(folder: watch, mode: .live, fileNamePrefix: "Light_")
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
            profile: SessionProfile(targetName: "ApplyVisPrereq", subExposureSeconds: 20),
            rootDirectory: sandbox.appendingPathComponent("sessions"))
        return Harness(pipeline: pipeline, sandbox: sandbox, watch: watch,
                       write: { seed in
                           // atomic temp+rename, so the watcher never sees a partial file
                           let tmp = watch.appendingPathComponent(".t\(seed)")
                           try data(seed).write(to: tmp)
                           try FileManager.default.moveItem(
                               at: tmp,
                               to: watch.appendingPathComponent(String(format: "Light_%04d.fit", seed)))
                       })
    }

    /// PREREQUISITE 1: a matching file is ingested and produces a FRAME-ORIGIN render.
    @MainActor func testPrerequisiteMatchingFileProducesAFrameOriginRender() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.sandbox) }

        let frameRender = expectation(description: "a render with origin 'frame'")
        frameRender.assertForOverFulfill = false
        h.pipeline.displayRenderSettingsProbeForTest = { (_: UInt64, _: DisplayAdjustments, origin: String) in
            if origin == "frame" { frameRender.fulfill() }
        }
        try h.pipeline.start()
        defer { _ = try? h.pipeline.end() }
        for i in 0..<3 { try h.write(i) }

        await fulfillment(of: [frameRender], timeout: 90)
    }

    /// PREREQUISITE 2: that delivery is ACCEPTED by the real AppModel handler, with the test
    /// awaiting asynchronously so the main actor is free to service the handoff.
    @MainActor func testPrerequisiteDeliveryIsAcceptedByTheRealAppModelHandler() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.sandbox) }

        // ISOLATED PREFERENCES. The long experiment calls Apply, which PERSISTS settings — with
        // the default init that writes the real com.pauldavis.liveastrostudio domain. A per-test
        // suite keeps a measurement run from mutating the operator's actual configuration.
        let suiteName = "liveastro.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removeSuite(named: suiteName) }
        let model = AppModel(userDefaults: defaults)
        let accepted = expectation(description: "a delivery accepted by AppModel")
        accepted.assertForOverFulfill = false
        let outcomes = OutcomeLog()
        model.displayDeliveryOutcomeForTest = { rev, outcome in
            outcomes.add(rev, outcome)
            if outcome == "accepted" { accepted.fulfill() }
        }
        model.wireCallbacks(to: h.pipeline)
        model.attach(pipeline: h.pipeline)
        try h.pipeline.start()
        defer { _ = try? h.pipeline.end() }
        for i in 0..<3 { try h.write(i) }

        await fulfillment(of: [accepted], timeout: 90)
        XCTAssertNotNil(model.broadcastImage,
                        "an accepted delivery must have put an image on the model")
        print("PREREQ  outcomes: \(outcomes.summary)")
    }

    private final class OutcomeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(UInt64, String)] = []
        func add(_ r: UInt64, _ o: String) { lock.lock(); items.append((r, o)); lock.unlock() }
        var summary: String {
            lock.lock(); defer { lock.unlock() }
            return items.map { "rev \($0.0):\($0.1)" }.joined(separator: ", ")
        }
    }
}
