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

        // A window with a start and an end, so the test can PROVE the three operations overlapped
        // instead of assuming that dispatching them together was enough. A peak-RSS-under-overlap
        // measurement taken while the operations actually ran one after another measures nothing.
        final class Span: @unchecked Sendable {
            private let lock = NSLock()
            private var began: Date?
            private var ended: Date?
            let name: String
            init(_ name: String) { self.name = name }
            func open() { lock.lock(); if began == nil { began = Date() }; lock.unlock() }
            // First completion wins. Later deliveries for the same operation would otherwise
            // stretch the window and overstate the overlap.
            func close() { lock.lock(); if ended == nil { ended = Date() }; lock.unlock() }
            var window: (start: Date, end: Date)? {
                lock.lock(); defer { lock.unlock() }
                guard let began, let ended else { return nil }
                return (began, ended)
            }
        }
        let frameSpan = Span("frame"), draftSpan = Span("draft"), applySpan = Span("apply")

        let frame2 = expectation(description: "frame 2 processed")
        pipeline.onUpdate = { _, _ in
            print("PIPELOG \(Date()): frame2 onUpdate fired")
            frameSpan.close(); frame2.fulfill()
        }

        let draftDone = expectation(description: "draft render finished")
        let applyRevisionDelivered = expectation(description: "Apply's revision delivered")
        applyRevisionDelivered.assertForOverFulfill = false

        // DELIVERY, not scheduling. `refreshDisplay()` bumps `displayRevision` BEFORE it dispatches
        // the render, so observing the revision only proves the work was REQUESTED. `onDisplayUpdate`
        // fires from `deliverDisplay`, past the `isCurrentDisplay` guard, so it is the real
        // completion signal. The comparison is `>=`, never `==`: revisions are monotonic and a
        // newer one supersedes the render in flight, so an exact-equality wait can miss its target
        // and spin until the enclosing timeout — reporting a timeout for work that did complete.
        let applyLock = NSLock()
        var applyRevision: UInt64?
        var lastDelivered: UInt64 = 0
        pipeline.onDisplayUpdate = { update in
            applyLock.lock()
            lastDelivered = max(lastDelivered, update.revision)
            let reached = applyRevision.map { update.revision >= $0 } ?? false
            applyLock.unlock()
            if reached {
                print("PIPELOG \(Date()): delivered revision \(update.revision) >= Apply's")
                applySpan.close(); applyRevisionDelivered.fulfill()
            }
        }

        print("PIPELOG \(Date()): === overlap window opens ===")
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
            applySpan.open()
            print("PIPELOG \(Date()): apply setter call starting")
            var adjustments = DisplayAdjustments.neutral
            adjustments.midtoneStrength = 0.15
            pipeline.displayAdjustments = adjustments   // "Apply" — schedules refreshDisplay() async
            // The setter has returned, so refreshDisplay() has already claimed its revision. Read it
            // HERE, after the mutation, so the wait cannot be satisfied by a delivery that predates
            // the Apply (frame 2 also bumps the revision, concurrently).
            let claimed = self.currentDisplayRevision(pipeline) ?? 0
            applyLock.lock()
            applyRevision = claimed
            let alreadyDelivered = lastDelivered >= claimed
            applyLock.unlock()
            print("PIPELOG \(Date()): apply setter returned; its revision is \(claimed)")
            // Delivery can beat this assignment; without the re-check the signal would be missed.
            if alreadyDelivered { applySpan.close(); applyRevisionDelivered.fulfill() }
        }
        DispatchQueue.global().async {
            releaseAll.wait()
            frameSpan.open()
            print("PIPELOG \(Date()): frame 2 write starting (pre-built Data, fast)")
            try? frame2Data.write(to: liveStackURL)   // frame delivery begins
            print("PIPELOG \(Date()): frame 2 write returned — watcher can now detect it")
        }
        releaseAll.signal(); releaseAll.signal(); releaseAll.signal()

        wait(for: [frame2, draftDone, applyRevisionDelivered], timeout: 90)
        print("PIPELOG \(Date()): === all three operations confirmed resolved ===")

        // The measurement below is only meaningful if the windows genuinely intersected. Report it
        // rather than asserting: this is a measurement test, and a machine that serialises the work
        // should say so plainly instead of failing as though the pipeline regressed.
        let spans = [frameSpan, draftSpan, applySpan].compactMap { s -> (String, Date, Date)? in
            s.window.map { (s.name, $0.start, $0.end) }
        }
        if spans.count == 3 {
            let latestStart = spans.map(\.1).max()!
            let earliestEnd = spans.map(\.2).min()!
            let overlap = earliestEnd.timeIntervalSince(latestStart)
            for (name, a, b) in spans {
                print(String(format: "PIPELOG span %@: %.3f s", name, b.timeIntervalSince(a)))
            }
            print(String(format: "PIPELOG three-way overlap: %.3f s", overlap))
            if overlap <= 0 {
                print("PIPELOG WARNING: the operations did NOT all overlap — the peak below is "
                      + "not a concurrency measurement on this run.")
            }
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
        // The regression this test actually guards: raw RSS here runs far above one frame's
        // byte count because macOS/libmalloc keeps large freed allocations resident (arena
        // growth) rather than decommitting them — NOT because copies pile up per frame. A real
        // per-frame leak (e.g. lastPreviewLinear/displayOnline diverging into two independently-
        // retained full-res buffers instead of sharing one via COW) would cost roughly one more
        // `frameMB` of RSS on EVERY additional frame; allocator-retention plateaus instead.
        XCTAssertLessThan(settledAfterFrame3MB - settledAfterFrame2MB, frameMB,
                          "one further full-resolution frame cycle must not cost another whole " +
                          "frame's worth of RSS — that pattern would indicate lastPreviewLinear " +
                          "and displayOnline had stopped sharing one COW buffer")
    }
}
