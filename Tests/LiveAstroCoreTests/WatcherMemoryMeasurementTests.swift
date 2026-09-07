import XCTest
import Darwin
@testable import LiveAstroCore

/// Task B (staged-display-adjustments plan, 2026-09-03): measures ACTUAL resident memory a
/// watcher/external-stacker session holds for full-resolution linear data, at rest and at peak,
/// on a realistic ASI2600MC-Air (OSC) frame shape. Not run as part of the routine suite filter —
/// it drives the REAL disk-watching path (writes real ~300 MB FITS files, waits for the real
/// `StackFileWatcher` poll/quiet-period to detect them) so the numbers are measured, not guessed.
/// Gated behind `LAS_RUN_MEMORY_TEST=1` so an unfiltered `swift test` run never pays its minutes
/// and hundreds of MB by accident.
///
/// Why this can't be settled by reading the source alone: `AstroImage` is a value struct whose
/// `pixels` is a Swift `Array` (copy-on-write). `SessionPipeline.handle(_:)` assigns the SAME
/// `linear` local to BOTH `lastPreviewLinear` (via `noteWatcherFrame`) and `displayOnline` —
/// two stored properties, but because neither is ever mutated after that assignment, COW means
/// they may share ONE underlying buffer, not two. Only a real RSS measurement can confirm that,
/// which is the point of this file.
///
/// Sampling discipline: both ~300 MB fixture blobs (frame1Data/frame2Data) are built BEFORE the
/// baseline sample is taken, so building them never lands inside a sampled delta — only the fast
/// `.write(to:)` of an already-built `Data` happens inside a timed window. The peak window is
/// bounded by explicit, independently-verified start/finish signals for each of the three
/// overlapping operations (see the PIPELOG timestamps this test prints), not by a guessed sleep.
final class WatcherMemoryMeasurementTests: XCTestCase {

    // Realistic full-resolution debayered (RGB) frame shape (matches the ASI2600MC-Air imager
    // named in CLAUDE.md / astro_alert context, cropped-to-sensor-ish dimensions given in the brief).
    private let width = 6248
    private let height = 4176
    private let channels = 3
    private var frameBytes: Int { width * height * channels * MemoryLayout<Float>.size }
    private var frameMB: Double { Double(frameBytes) / (1024 * 1024) }

    /// The measurement above is only as good as its instruments, and a silent probe is
    /// indistinguishable from work that genuinely did not overlap: the first instrumented run
    /// reported "only 2 of 3 windows observed" because the frame probe never fired. Fast, ungated,
    /// and tiny (128x128) so it runs in the normal suite and keeps the seam honest.
    func testWorkProbesFireForWatcherFrames() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let watch = sandbox.appendingPathComponent("watch", isDirectory: true)
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let pipeline = SessionPipeline(watchFolder: watch,
            profile: SessionProfile(targetName: "ProbeTest", subExposureSeconds: 20),
            rootDirectory: sandbox.appendingPathComponent("sessions"))

        final class Events: @unchecked Sendable {
            private let lock = NSLock()
            private var frame: [String] = []
            private var display: [String] = []
            func addFrame(_ e: String) { lock.lock(); frame.append(e); lock.unlock() }
            func addDisplay(_ e: String) { lock.lock(); display.append(e); lock.unlock() }
            var frames: [String] { lock.lock(); defer { lock.unlock() }; return frame }
            var displays: [String] { lock.lock(); defer { lock.unlock() }; return display }
        }
        let events = Events()
        pipeline.displayRenderProbeForTest = { _, event in events.addDisplay("\(event)") }

        // Await the PROBE's completion event, not `onUpdate`. The `.finished` probe runs in a
        // `defer`, i.e. AFTER onUpdate has already fired, so asserting on the recorded events
        // straight after an onUpdate wait is a race the test would lose intermittently.
        let firstFrameFinished = expectation(description: "the first frame finished processing")
        firstFrameFinished.assertForOverFulfill = false
        let secondFrameFinished = expectation(description: "the rewritten frame finished processing")
        secondFrameFinished.assertForOverFulfill = false
        // Atomic increment-and-read: `AtomicCounter.increment()` returns Void, and reading it
        // separately would race the second frame against the first.
        final class Ticks: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        }
        let finishedCount = Ticks()
        pipeline.frameProcessingProbeForTest = { _, event in
            events.addFrame("\(event)")
            guard event == .finished else { return }
            if finishedCount.next() == 1 { firstFrameFinished.fulfill() } else { secondFrameFinished.fulfill() }
        }
        try pipeline.start()
        defer { _ = try? pipeline.end() }

        let w = 128, h = 128
        var px = [Float](repeating: 0.1, count: w * h)
        for i in stride(from: 0, to: w * h, by: 11) { px[i] += Float(i % 97) / 5000 }
        try FITSWriter.float32(width: w, height: h, channels: 1, pixels: px)
            .write(to: watch.appendingPathComponent("live_stack.fit"))
        wait(for: [firstFrameFinished], timeout: 30)

        XCTAssertTrue(events.frames.contains("began"),
                      "the frame-processing probe never fired; the overlap measurement would "
                      + "silently report a missing window instead of a real absence of overlap")
        XCTAssertTrue(events.frames.contains("finished"),
                      "the frame-processing probe reported a start with no completion")

        // SECOND write, rewriting the same file in place — the exact shape the measurement uses
        // for frame 2, and the case where the instrument was silent. A probe that fires only for
        // the first frame is worse than no probe: the measurement reports a missing window and
        // reads as "the work did not overlap".
        let framesAfterFirst = events.frames.count
        for i in stride(from: 1, to: w * h, by: 13) { px[i] += Float(i % 89) / 4000 }
        try FITSWriter.float32(width: w, height: h, channels: 1, pixels: px)
            .write(to: watch.appendingPathComponent("live_stack.fit"))
        wait(for: [secondFrameFinished], timeout: 30)
        XCTAssertGreaterThan(events.frames.count, framesAfterFirst,
                             "the frame probe fired for the first frame but not for a rewrite of "
                             + "the same file, which is what the measurement actually measures")

        // The display probe backs the Apply window; exercise it through an adjustment change and
        // wait for COMPLETION, not merely for the start.
        var adjustments = DisplayAdjustments.neutral
        adjustments.midtoneStrength = 0.15
        pipeline.displayAdjustments = adjustments
        let displayFinished = expectation(description: "a display render ran to completion")
        displayFinished.assertForOverFulfill = false
        DispatchQueue.global().async {
            while !events.displays.contains("finished") { usleep(5_000) }
            displayFinished.fulfill()
        }
        wait(for: [displayFinished], timeout: 30)
        XCTAssertTrue(events.displays.contains("began"),
                      "the display probe reported a completion with no start")
    }

    /// `mach_task_basic_info.resident_size`, in MB, for THIS process — as directed by the task
    /// brief. (Known to be a slightly coarser signal than `TASK_VM_INFO`'s `phys_footprint` on
    /// some macOS versions, but it's what was asked for, and the deltas below are what matters,
    /// not the absolute baseline.)
    private func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Double(info.resident_size) / (1024 * 1024)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    /// Builds a real FITS `Data` blob (~`frameMB` MB) OUTSIDE any sampled window. The pixel
    /// array is released as soon as this returns (only the encoded `Data` survives), so building
    /// N fixtures ahead of time costs at most ~1 fixture's worth of transient overhead, not N.
    private func buildFrameData(_ value: Float) -> Data {
        var px = [Float](repeating: value, count: width * height * channels)
        // Non-degenerate content (matches PreviewTestSupport's rationale) without paying for a
        // full per-pixel fill — touch a sparse subset so this isn't a single-value constant buffer.
        for x in stride(from: 0, to: min(width, 4000), by: 7) { px[x] += Float(x) / Float(width) * 0.01 }
        return FITSWriter.float32(width: width, height: height, channels: channels, pixels: px)
    }

    /// Probes the pipeline's current display revision via `isCurrentDisplay` (its only exposed
    /// introspection), by testing small revision numbers in order.
    private func currentDisplayRevision(_ pipeline: SessionPipeline, upperBound: UInt64 = 20) -> UInt64? {
        for revision in 0...upperBound {
            let probe = DisplayDelivery(revision: revision, previewImage: nil, broadcastImage: nil,
                cleanMasterSubCount: nil, integrationSeconds: 0, previewIntegrationSeconds: 0,
                subExposureSeconds: 1, record: nil)
            if pipeline.isCurrentDisplay(probe) { return revision }
        }
        return nil
    }

    /// Steady-state retention at rest, and peak retention while a frame delivery, a draft
    /// render, and an Apply all overlap.
    func testWatcherSteadyStateAndPeakOverlapResidentMemory() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LAS_RUN_MEMORY_TEST"] == "1",
            "gated: set LAS_RUN_MEMORY_TEST=1 to run — real ~300 MB FITS I/O, ~2-3 minutes")

        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("watcher-mem-\(UUID().uuidString)", isDirectory: true)
        let watch = sandbox.appendingPathComponent("watch", isDirectory: true)
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        // Fixtures built and fully released of their pixel-array scratch BEFORE anything is
        // sampled — see the file-level doc comment. Only `frame1Data`/`frame2Data` (the final
        // encoded Data, unavoidably ~frameMB each since that IS what gets written/read) survive.
        print("PIPELOG \(Date()): building fixtures (excluded from all sampled windows)")
        let frame1Data = buildFrameData(0.3)
        let frame2Data = buildFrameData(0.4)
        let frame3Data = buildFrameData(0.5)
        print("PIPELOG \(Date()): fixtures built")

        let pipeline = SessionPipeline(watchFolder: watch,
            profile: SessionProfile(targetName: "MemTest", subExposureSeconds: 20),
            rootDirectory: sandbox.appendingPathComponent("sessions"))

        pipeline.onLog = { print("PIPELOG \(Date()): \($0)") }
        let frame1 = expectation(description: "frame 1 processed")
        pipeline.onUpdate = { _, _ in print("PIPELOG \(Date()): frame1 onUpdate fired"); frame1.fulfill() }
        try pipeline.start()

        Thread.sleep(forTimeInterval: 0.2)
        let baselineMB = residentMB()
        print("PIPELOG \(Date()): baseline sampled = \(String(format: "%.1f", baselineMB)) MB")

        let liveStackURL = watch.appendingPathComponent("live_stack.fit")
        try frame1Data.write(to: liveStackURL)
        wait(for: [frame1], timeout: 30)
        // Let delivery-path transients (DBE/neutralize/stretch intermediates inside
        // displayCGImage) drain before sampling steady state.
        Thread.sleep(forTimeInterval: 0.5)

        let steadyMB = residentMB()
        let steadyDeltaMB = steadyMB - baselineMB
        print("PIPELOG \(Date()): steady-state sampled = \(String(format: "%.1f", steadyMB)) MB " +
              "(delta \(String(format: "%.1f", steadyDeltaMB)) MB)")

        // --- Peak during OVERLAP: frame delivery + a draft render + an Apply, concurrently. ---
        // Each operation's start/finish is independently signalled (never a fixed sleep), and the
        // RSS poller runs for the full union of all three windows, confirmed below.
        let peakLock = NSLock()
        var peakMB = steadyMB
        func noteMax(_ v: Double) { peakLock.lock(); peakMB = max(peakMB, v); peakLock.unlock() }

        let stopPolling = Flag()
        let pollingDone = expectation(description: "RSS polling stopped")
        DispatchQueue.global().async {
            while !stopPolling.isSet {
                noteMax(self.residentMB())
                usleep(2_000)
            }
            pollingDone.fulfill()
        }

        // Windows measured from ACTUAL execution, not from dispatch. The earlier version opened the
        // frame window before the file write, so it covered the write and the watcher's detection
        // latency as well as processing — a draft and an Apply that both finished before the frame
        // was even picked up still produced "overlapping" intervals. These come from probes inside
        // the pipeline, at the entry and exit of the real work.
        final class Span: @unchecked Sendable {
            private let lock = NSLock()
            private var began: Date?
            private var ended: Date?
            let name: String
            init(_ name: String) { self.name = name }
            func open(at date: Date = Date()) { lock.lock(); if began == nil { began = date }; lock.unlock() }
            // First completion wins. Later deliveries for the same operation would otherwise
            // stretch the window and overstate the overlap.
            func close(at date: Date = Date()) { lock.lock(); if ended == nil { ended = date }; lock.unlock() }
            var window: (start: Date, end: Date)? {
                lock.lock(); defer { lock.unlock() }
                guard let began, let ended else { return nil }
                return (began, ended)
            }
        }
        let frameSpan = Span("frame processing"), draftSpan = Span("draft render")
        let displaySpan = Span("post-Apply display render")

        let frame2 = expectation(description: "frame 2 processed")
        pipeline.onUpdate = { _, _ in print("PIPELOG \(Date()): frame2 onUpdate fired"); frame2.fulfill() }

        let draftDone = expectation(description: "draft render finished")
        let applyRenderDone = expectation(description: "the display render carrying Apply finished")
        applyRenderDone.assertForOverFulfill = false

        // Frame 1 used this same file name, so events must be attributed to the right frame. That
        // is done by TIMESTAMP against `windowOpenedAt` below, not by a boolean gate: a gate that
        // is somehow closed makes the probe silent, and a silent probe is indistinguishable in the
        // report from work that genuinely did not overlap. Recording everything and filtering
        // afterwards cannot fail that way — and the raw log shows what was seen either way.
        let eventLock = NSLock()
        var frameEvents: [(Date, String, SessionPipeline.WorkProbeEvent)] = []
        let frameProcessingFinished = expectation(description: "frame processing finished in window")
        frameProcessingFinished.assertForOverFulfill = false
        pipeline.frameProcessingProbeForTest = { name, event in
            let at = Date()
            eventLock.lock(); frameEvents.append((at, name, event)); eventLock.unlock()
            print("PIPELOG \(at): frame processing \(event) (\(name))")
            // `.finished` runs in a defer, AFTER onUpdate. Snapshotting the events on the onUpdate
            // signal alone can therefore miss the completion and report a missing window.
            if event == .finished { frameProcessingFinished.fulfill() }
        }

        // Any display render whose revision is past the pre-Apply value, once the window is open,
        // necessarily reads the adjustments Apply had already assigned — the pipeline resolves the
        // newest committed settings at render time. Revision NUMBERS cannot separate Apply's render
        // from frame 2's, because the pipeline coalesces them by design; `supersededRevisions`
        // records when that happened so the report can say so instead of implying three distinct
        // concurrent renders.
        let revisionBeforeApply = currentDisplayRevision(pipeline) ?? 0
        let renderLock = NSLock()
        var supersededRevisions: [UInt64] = []
        pipeline.displayRenderProbeForTest = { revision, event in
            guard revision > revisionBeforeApply else { return }
            switch event {
            case .began:
                displaySpan.open()
            case .finished:
                displaySpan.close(); applyRenderDone.fulfill()
            case .superseded:
                // TERMINAL, not merely recorded. The frame path renders through
                // `renderDisplayTransition` directly rather than through `refreshDisplay`, so when
                // frame processing supersedes Apply's queued refresh NO transition render finishes
                // under this probe — waiting only on `.finished` then burns the full 90 s timeout
                // and reports a failure for a pipeline that behaved exactly as designed.
                renderLock.lock(); supersededRevisions.append(revision); renderLock.unlock()
                applyRenderDone.fulfill()
            }
            print("PIPELOG \(Date()): display render \(event) revision \(revision)")
        }

        print("PIPELOG \(Date()): === overlap window opens ===")
        let windowOpenedAt = Date()
        // Start barrier: every operation blocks here, so they begin within microseconds of each
        // other rather than in dispatch order.
        let releaseAll = DispatchSemaphore(value: 0)

        print("PIPELOG \(Date()): draft render dispatching")
        DispatchQueue.global().async {
            releaseAll.wait()
            draftSpan.open()
            print("PIPELOG \(Date()): draft render EXECUTING (synchronous call starts)")
            _ = pipeline.renderPreview(source: .online, adjustments: DisplayAdjustments(blackPoint: 0.02))
            print("PIPELOG \(Date()): draft render EXECUTING finished (synchronous call returns)")
            draftSpan.close(); draftDone.fulfill()
        }
        print("PIPELOG \(Date()): apply dispatching")
        DispatchQueue.global().async {
            releaseAll.wait()
            print("PIPELOG \(Date()): apply setter call starting")
            var adjustments = DisplayAdjustments.neutral
            adjustments.midtoneStrength = 0.15
            pipeline.displayAdjustments = adjustments   // "Apply" — schedules refreshDisplay() async
            print("PIPELOG \(Date()): apply setter call returned (async transition now in flight)")
        }
        DispatchQueue.global().async {
            releaseAll.wait()
            print("PIPELOG \(Date()): frame 2 write starting (pre-built Data, fast)")
            try? frame2Data.write(to: liveStackURL)   // frame delivery begins
            print("PIPELOG \(Date()): frame 2 write returned — watcher can now detect it")
        }
        releaseAll.signal(); releaseAll.signal(); releaseAll.signal()

        wait(for: [frame2, draftDone, applyRenderDone, frameProcessingFinished], timeout: 90)
        print("PIPELOG \(Date()): === all three operations confirmed resolved ===")

        // Attribute frame events to the overlap window by time, then build its span.
        eventLock.lock()
        let recordedFrameEvents = frameEvents
        eventLock.unlock()
        let inWindow = recordedFrameEvents.filter { $0.0 >= windowOpenedAt }
        if let began = inWindow.first(where: { $0.2 == .began }) {
            // Stamped with the RECORDED event times, not the time this reconstruction runs.
            frameSpan.open(at: began.0)
            if let finished = inWindow.first(where: { $0.2 == .finished && $0.0 >= began.0 }) {
                frameSpan.close(at: finished.0)
            }
        }
        print("PIPELOG frame-processing events in window: \(inWindow.count) "
              + "(total observed: \(recordedFrameEvents.count))")

        // Report what actually overlapped; do not claim more. This is a measurement, so a machine
        // that serialised the work should say so plainly rather than fail as though the pipeline
        // regressed — but the peak below is only a CONCURRENCY figure if the windows intersected.
        let spans = [frameSpan, draftSpan, displaySpan].compactMap { s -> (String, Date, Date)? in
            s.window.map { (s.name, $0.start, $0.end) }
        }
        renderLock.lock()
        let superseded = supersededRevisions
        renderLock.unlock()
        if !superseded.isEmpty {
            print("PIPELOG WARNING: the intended three-way measurement was NOT obtained on this run.")
            print("PIPELOG note: display revisions \(superseded) were superseded before rendering. "
                  + "The pipeline coalesces pending display work, so Apply's own queued render did "
                  + "not run separately — its settings were rendered by the surviving revision. "
                  + "That is one render, not two: the figures below describe frame processing, the "
                  + "draft render, and that single display render.")
        }
        for (name, a, b) in spans {
            print(String(format: "PIPELOG span %@: %.3f s", name, b.timeIntervalSince(a)))
        }
        if spans.count == 3 {
            let latestStart = spans.map(\.1).max()!
            let earliestEnd = spans.map(\.2).min()!
            let overlap = earliestEnd.timeIntervalSince(latestStart)
            print(String(format: "PIPELOG three-way overlap: %.3f s", overlap))
            if overlap <= 0 {
                print("PIPELOG WARNING: the three windows did NOT all intersect — the peak below is "
                      + "not a three-way concurrency measurement on this run.")
            }
        } else {
            print("PIPELOG WARNING: only \(spans.count) of 3 windows were observed; the peak below "
                  + "is not a three-way concurrency measurement on this run.")
        }
        Thread.sleep(forTimeInterval: 0.3)   // let any just-finished renders' transient buffers drain
        stopPolling.set()
        wait(for: [pollingDone], timeout: 5)

        let peakDeltaMB = peakMB - baselineMB
        let settledAfterFrame2MB = residentMB()

        // Disambiguate "a genuine per-frame leak" from "libmalloc/allocator retaining freed large
        // blocks resident for reuse" (a known RSS-measurement confound): one MORE frame, with NO
        // concurrent render/apply this time. If RSS keeps climbing by another ~1 frame's worth,
        // that points to a leak; if it plateaus near the post-frame-2 level, the earlier jump was
        // allocator high-water-mark churn, not additional LIVE full-resolution retention.
        let frame3 = expectation(description: "frame 3 processed")
        pipeline.onUpdate = { _, _ in print("PIPELOG \(Date()): frame3 onUpdate fired"); frame3.fulfill() }
        try frame3Data.write(to: liveStackURL)
        wait(for: [frame3], timeout: 90)
        Thread.sleep(forTimeInterval: 0.5)
        let settledAfterFrame3MB = residentMB()

        // This test's PURPOSE is these numbers — printed (not just asserted) so they land in the
        // `swift test` log and can be transcribed into the report verbatim.
        print("""
        WATCHER-MEMORY-REPORT frame=\(width)x\(height)x\(channels)f32 oneFrameMB=\(String(format: "%.1f", frameMB)) \
        baselineMB=\(String(format: "%.1f", baselineMB)) steadyMB=\(String(format: "%.1f", steadyMB)) \
        steadyDeltaMB=\(String(format: "%.1f", steadyDeltaMB)) peakMB=\(String(format: "%.1f", peakMB)) \
        peakDeltaMB=\(String(format: "%.1f", peakDeltaMB)) settledAfterFrame2MB=\(String(format: "%.1f", settledAfterFrame2MB)) \
        settledAfterFrame3MB=\(String(format: "%.1f", settledAfterFrame3MB))
        """)

        XCTAssertGreaterThan(steadyDeltaMB, 0,
                             "at least one full-resolution linear copy must be retained at rest " +
                             "in watcher mode (lastPreviewLinear / displayOnline)")
        XCTAssertGreaterThanOrEqual(peakDeltaMB, steadyDeltaMB - 5,
                                    "peak-during-overlap must be at least the steady-state retention")
        // The regression this test guards: raw RSS here runs far above one frame's byte count
        // because macOS/libmalloc keeps large freed allocations resident (arena growth) rather
        // than decommitting them — NOT because copies pile up per frame. Retention that GROWS by
        // about `frameMB` on every additional frame is the shape of an unbounded per-frame leak;
        // allocator retention plateaus instead.
        //
        // SCOPE, stated precisely because the previous wording overclaimed: this measures
        // incremental resident growth per frame cycle. It CANNOT prove that lastPreviewLinear and
        // displayOnline share one buffer — two independent buffers that are both REPLACED each
        // frame plateau exactly the same way. Distinguishing shared ownership from
        // replaced-in-place would need allocation-level evidence (a heap tool, or an identity
        // check on the underlying storage), which this does not attempt.
        XCTAssertLessThan(settledAfterFrame3MB - settledAfterFrame2MB, frameMB,
                          "one further full-resolution frame cycle must not cost another whole " +
                          "frame's worth of RSS — that pattern is unbounded per-frame retention")
    }
}
