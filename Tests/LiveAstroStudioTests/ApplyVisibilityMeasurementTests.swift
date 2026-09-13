import XCTest
@testable import LiveAstroStudio
@testable import LiveAstroCore

/// ONLINE-FALLBACK CASE ONLY. Two frames never reach the clean-master quorum, so the broadcast
/// resolves to `onlinePreviewCG` — one render per frame. This says nothing about clean-master
/// behaviour, where a second full-resolution render appears.
///
/// Measures the latency regime under investigation, at REAL dimensions and settings: an Apply
/// issued while a frame is actively rendering. Records queue delay, lock wait and hold, render and
/// disk-write intervals, supersession, and the time until an AppModel-ACCEPTED image carries the
/// edit — the only event that means the operator saw it.
///
///   LAS_RUN_APPLY_VISIBILITY=1 swift test -c release --filter ApplyVisibilityMeasurementTests
final class ApplyVisibilityMeasurementTests: XCTestCase {

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var marks: [(rev: UInt64, what: String, at: Date)] = []
        func mark(_ r: UInt64, _ w: String) { lock.lock(); marks.append((r, w, Date())); lock.unlock() }
        var all: [(rev: UInt64, what: String, at: Date)] {
            lock.lock(); defer { lock.unlock() }; return marks
        }
    }

    @MainActor func testApplyVisibilityUnderNativeLiveRendering() async throws {
        guard ProcessInfo.processInfo.environment["LAS_RUN_APPLY_VISIBILITY"] != nil else {
            throw XCTSkip("set LAS_RUN_APPLY_VISIBILITY=1 (run -c release; ~26 MP frames)")
        }
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let watch = sandbox.appendingPathComponent("watch", isDirectory: true)
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        // REAL dimensions — the live path renders the cropped mean at full resolution, measured at
        // 19.6 s per render on a 6236x4159 master. A small frame would measure ordering only.
        // THREE CHANNELS. `BackgroundExtraction.flattenMultiscale` has an explicit
        // `guard image.channels == 3 else { return image }` mono passthrough, so a 1-channel
        // fixture skipped DBE entirely — 0.0 ms against 14.4 s — and the earlier 0.6 s result
        // measured a render with its dominant stage absent. The camera is a colour OSC, so subs
        // debayer to 3 channels and DBE really runs.
        let w = 6236, h = 4159, channels = 3
        func frameData(_ seed: Int) -> Data {
            var px = [Float](repeating: 0, count: w * h * channels)
            var s = UInt64(0xC0FFEE &+ UInt64(seed &* 7919))
            for c in 0..<channels {
                for i in 0..<(w * h) {
                    s = s &* 6364136223846793005 &+ 1442695040888963407
                    // planar: c * plane + i, with a per-channel offset so the channels differ
                    px[c * w * h + i] = 0.0104 + Float(c) * 0.0008
                        + (Float(s >> 40) / Float(1 << 24) - 0.5) * 0.006
                }
            }
            for (fx, fy, amp) in [(0.216, 0.239, Float(0.8)), (0.583, 0.611, 0.5),
                                  (0.792, 0.333, 0.65), (0.292, 0.500, 0.6), (0.417, 0.167, 0.55),
                                  (0.542, 0.833, 0.65), (0.667, 0.222, 0.5), (0.875, 0.556, 0.7),
                                  (0.188, 0.722, 0.55), (0.479, 0.389, 0.6), (0.771, 0.722, 0.5),
                                  (0.250, 0.889, 0.65), (0.833, 0.139, 0.55), (0.375, 0.611, 0.6),
                                  (0.708, 0.500, 0.5), (0.917, 0.833, 0.6), (0.208, 0.389, 0.55),
                                  (0.604, 0.917, 0.6)] {
                let sx = Int(fx * Double(w)), sy = Int(fy * Double(h))
                for c in 0..<channels {
                    for dy in -10...10 { for dx in -10...10 {
                        let x = sx + dx, y = sy + dy
                        guard x >= 0, x < w, y >= 0, y < h else { continue }
                        px[c * w * h + y * w + x] += amp * exp(-Float(dx * dx + dy * dy) / 16.0)
                    } }
                }
            }
            return FITSWriter.float32(width: w, height: h, channels: channels, pixels: px)
        }
        func write(_ seed: Int) throws {
            let tmp = watch.appendingPathComponent(".t\(seed)")
            try frameData(seed).write(to: tmp)
            try FileManager.default.moveItem(
                at: tmp, to: watch.appendingPathComponent(String(format: "Light_%04d.fit", seed)))
        }

        let source = FolderFrameSource(folder: watch, mode: .live, fileNamePrefix: "Light_")
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
            profile: SessionProfile(targetName: "ApplyVis", subExposureSeconds: 20),
            rootDirectory: sandbox.appendingPathComponent("sessions"))

        // The operator's actual settings — DBE dominates a full-resolution render at 71.5%.
        var live = DisplayAdjustments.neutral
        live.backgroundExtraction = true
        live.bgScale = 2.9611440772720226
        live.bgSmoothest = 0.5
        live.denoiseStrength = 0.7257130587748345
        pipeline.displayAdjustments = live

        let suiteName = "liveastro.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removeSuite(named: suiteName) }
        let model = AppModel(userDefaults: defaults)
        model.staged.pending = live
        model.applyAdjustments()          // commit the baseline settings before measuring

        let log = Log()
        let ingested = expectation(description: "frame 1 ingested (frame-origin render)")
        ingested.assertForOverFulfill = false
        let secondRendering = expectation(description: "frame 2 is actively RENDERING")
        secondRendering.assertForOverFulfill = false
        let frameRenders = AtomicCounter()

        pipeline.displayRenderSettingsProbeForTest = { (rev: UInt64, adj: DisplayAdjustments, origin: String) in
            log.mark(rev, "render[\(origin)] bp=\(String(format: "%.3f", adj.blackPoint))")
            if origin == "frame" {
                frameRenders.increment()
                if frameRenders.value == 1 { ingested.fulfill() }
                if frameRenders.value == 2 { secondRendering.fulfill() }
            }
        }
        pipeline.displayRenderPhaseProbeForTest = { rev, phase in log.mark(rev, "\(phase)") }
        let inputs = InputFactsLog()
        pipeline.displayRenderInputProbeForTest = { facts in
            inputs.add(facts)
            log.mark(facts.revision, String(format: "input[%@] %dx%dx%d linear=%@ DBE=%@ scale=%.3f smooth=%.2f",
                                            facts.origin, facts.width, facts.height, facts.channels,
                                            facts.sourceIsLinear ? "yes" : "no",
                                            facts.backgroundExtraction ? "ON" : "OFF",
                                            facts.bgScale, facts.bgSmoothest))
        }
        pipeline.displayRenderProbeForTest = { rev, event in
            if event == .superseded { log.mark(rev, "SUPERSEDED") }
        }
        model.displayDeliveryOutcomeForTest = { rev, outcome in log.mark(rev, "delivery:\(outcome)") }
        model.wireCallbacks(to: pipeline)
        model.attach(pipeline: pipeline)

        try pipeline.start()
        defer { _ = try? pipeline.end() }

        try write(0)
        await fulfillment(of: [ingested], timeout: 240)   // fails loudly if ingestion never happens
        try write(1)
        await fulfillment(of: [secondRendering], timeout: 300)   // overlap prerequisite

        // Apply ONLY now — while frame 2 is rendering. No guessed sleep.
        let appliedBlackPoint = 0.25
        var edit = live
        edit.blackPoint = appliedBlackPoint
        model.staged.pending = edit
        let applyAt = Date()
        log.mark(0, "APPLY issued")
        model.applyAdjustments()

        let carrying = expectation(description: "an ACCEPTED image carrying the edit")
        carrying.assertForOverFulfill = false
        let carryingRevs = RevisionSet()
        pipeline.displayRenderSettingsProbeForTest = { (rev: UInt64, adj: DisplayAdjustments, origin: String) in
            log.mark(rev, "render[\(origin)] bp=\(String(format: "%.3f", adj.blackPoint))")
            if abs(adj.blackPoint - appliedBlackPoint) < 1e-9 { carryingRevs.insert(rev) }
        }
        model.displayDeliveryOutcomeForTest = { rev, outcome in
            log.mark(rev, "delivery:\(outcome)")
            if outcome == "accepted" && carryingRevs.contains(rev) { carrying.fulfill() }
        }
        await fulfillment(of: [carrying], timeout: 600)
        let visibleAfter = Date().timeIntervalSince(applyAt)

        print("APPLY-VIS  ===== ONLINE-FALLBACK CASE (2 frames, no clean master) =====")
        print(String(format: "APPLY-VIS  frame size %dx%d, DBE on (scale %.3f)", w, h, live.bgScale))
        for m in log.all {
            print(String(format: "APPLY-VIS  %+8.0fms  rev %2llu  %@",
                         m.at.timeIntervalSince(applyAt) * 1000, m.rev, m.what))
        }
        print(String(format: "APPLY-VIS  TIME TO ACCEPTED IMAGE CARRYING THE EDIT: %.1f s", visibleAfter))
        print("APPLY-VIS  DBE cache — hits \(pipeline.committedFlattenHitsForTest), "
              + "misses \(pipeline.committedFlattenMissesForTest), retained "
              + String(format: "%.0f MB", Double(pipeline.committedFlattenRetainedBytesForTest) / 1_048_576))

        // REPRESENTATIVENESS ASSERTIONS. A run whose inputs differ from the live regime must FAIL,
        // not print a number that looks like an answer: the previous run reported 214 ms against a
        // 19.6 s full-resolution measurement, and printing settings alone could not explain it.
        let observed = inputs.all
        XCTAssertFalse(observed.isEmpty, "no render inputs were observed at all")
        for f in observed {
            // cropToCoverage trims a few pixels, so compare SIZE not exact equality — an earlier
            // strict check failed on a 2-pixel crop and flagged a representative run as invalid.
            XCTAssertEqual(Double(f.width * f.height), Double(w * h), accuracy: Double(w * h) * 0.02,
                           "render input is not full size (\(f.width)x\(f.height))")
            XCTAssertEqual(f.channels, channels,
                           "DBE has a mono passthrough — a 1-channel fixture skips it entirely")
            XCTAssertTrue(f.backgroundExtraction,
                          "DBE must be ON for this to describe the live regime; it is 71.5% of a "
                          + "full-resolution render")
            XCTAssertEqual(f.bgScale, live.bgScale, accuracy: 1e-9, "captured bgScale")
            XCTAssertEqual(f.bgSmoothest, live.bgSmoothest, accuracy: 1e-9, "captured bgSmoothest")
            XCTAssertTrue(f.sourceIsLinear,
                          "a non-linear source SKIPS the stretch entirely and would not be the "
                          + "regime under investigation")
        }
    }

    private final class InputFactsLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [SessionPipeline.RenderInputFacts] = []
        func add(_ f: SessionPipeline.RenderInputFacts) { lock.lock(); items.append(f); lock.unlock() }
        var all: [SessionPipeline.RenderInputFacts] {
            lock.lock(); defer { lock.unlock() }; return items
        }
    }

    private final class RevisionSet: @unchecked Sendable {
        private let lock = NSLock()
        private var set = Set<UInt64>()
        func insert(_ r: UInt64) { lock.lock(); set.insert(r); lock.unlock() }
        func contains(_ r: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return set.contains(r) }
    }
}
