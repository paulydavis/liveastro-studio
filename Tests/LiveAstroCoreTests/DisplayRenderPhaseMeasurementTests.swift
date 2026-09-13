import XCTest
@testable import LiveAstroCore

/// MEASUREMENT, not a gate. Separates WAITING from RENDERING from REPEATED INVALIDATION for a
/// display-render request, with and without a frame backlog.
///
/// Why: an Apply was invisible for minutes on a real session, but a committed render measures
/// ~2.3 s in release (DBE 1.25 s of it). So the latency is not render cost. The candidate
/// explanations are queue delay, `displayRenderLock` contention behind frame processing, repeated
/// supersession, or presentation-side rejection. This tells them apart with numbers.
///
///   LAS_RUN_RENDER_PHASES=1 swift test -c release --filter DisplayRenderPhaseMeasurementTests
final class DisplayRenderPhaseMeasurementTests: XCTestCase {

    private final class Phases: @unchecked Sendable {
        private let lock = NSLock()
        private var marks: [(rev: UInt64, phase: SessionPipeline.DisplayRenderPhase, at: Date)] = []
        func mark(_ r: UInt64, _ p: SessionPipeline.DisplayRenderPhase) {
            lock.lock(); marks.append((r, p, Date())); lock.unlock()
        }
        var all: [(rev: UInt64, phase: SessionPipeline.DisplayRenderPhase, at: Date)] {
            lock.lock(); defer { lock.unlock() }; return marks
        }
    }

    private func report(_ label: String, _ phases: Phases, focus: UInt64?) {
        let all = phases.all
        let superseded = all.filter { $0.phase == .superseded }
        print("PHASE  === \(label) ===")
        print("PHASE  superseded requests: \(superseded.count) (revisions \(superseded.map(\.rev)))")
        let revisions = focus.map { [$0] } ?? Array(Set(all.map(\.rev))).sorted()
        for rev in revisions {
            let m = all.filter { $0.rev == rev }
            func at(_ p: SessionPipeline.DisplayRenderPhase) -> Date? { m.first { $0.phase == p }?.at }
            func ms(_ a: Date?, _ b: Date?) -> String {
                guard let a, let b else { return "     —" }
                return String(format: "%6.0f", b.timeIntervalSince(a) * 1000)
            }
            let req = at(.requested), work = at(.workerStarted), lock = at(.lockAcquired)
            let began = at(.renderBegan), fin = at(.renderFinished), del = at(.deliveryEmitted)
            print("PHASE  rev \(rev):  queue \(ms(req, work))ms  lockWait \(ms(work, lock))ms  "
                  + "render \(ms(began, fin))ms  delivered \(ms(fin, del))ms  "
                  + "total \(ms(req, del ?? fin))ms")
        }
        // How long the FRAME path held the lock — what an Apply would be queued behind.
        let holds = all.filter { $0.phase == .frameLockAcquired }
        for h in holds {
            if let rel = all.first(where: { $0.phase == .frameLockReleased && $0.at > h.at }) {
                print(String(format: "PHASE  frame path held displayRenderLock %.0f ms",
                             rel.at.timeIntervalSince(h.at) * 1000))
            }
        }
        let waits = all.filter { $0.phase == .frameLockRequested }
        for w in waits {
            if let acq = all.first(where: { $0.phase == .frameLockAcquired && $0.at >= w.at }) {
                let ms = acq.at.timeIntervalSince(w.at) * 1000
                if ms > 1 { print(String(format: "PHASE  frame path WAITED %.0f ms for the lock", ms)) }
            }
        }
        let writes = all.filter { $0.phase == .diskWriteBegan }
        for w in writes {
            if let end = all.first(where: { $0.rev == w.rev && $0.phase == .diskWriteEnded }) {
                print(String(format: "PHASE  rev %llu: snapshot disk write %.0f ms",
                             w.rev, end.at.timeIntervalSince(w.at) * 1000))
            }
        }
    }

    func testDisplayRenderPhasesWithAndWithoutBacklog() throws {
        guard ProcessInfo.processInfo.environment["LAS_RUN_RENDER_PHASES"] != nil else {
            throw XCTSkip("set LAS_RUN_RENDER_PHASES=1 (run -c release)")
        }
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (pipeline, source) = try PreviewRenderTests.runningPipeline(sandbox: sandbox)
        defer { source.stop() }

        // Match the real session's settings: DBE ON is 54% of a committed render, and the
        // default neutral adjustments made the render 47ms instead of ~2.3s — measuring nothing.
        var live = DisplayAdjustments.neutral
        live.backgroundExtraction = true
        live.bgScale = 2.9611440772720226
        live.bgSmoothest = 0.5
        live.denoiseStrength = 0.7257130587748345
        live.blackPoint = 0.24986757297550768
        pipeline.displayAdjustments = live

        let phases = Phases()
        pipeline.displayRenderPhaseProbeForTest = { rev, phase in phases.mark(rev, phase) }

        // --- CASE A: no backlog ---
        let quietRev = pipeline.currentDisplayRevision + 1
        pipeline.refreshDisplay()
        var deadline = Date().addingTimeInterval(30)
        while !phases.all.contains(where: { $0.rev == quietRev && ($0.phase == .deliveryEmitted || $0.phase == .superseded) })
              && Date() < deadline { usleep(20_000) }
        report("A: no backlog", phases, focus: quietRev)

        // --- CASE B: controlled backlog, then an Apply-shaped refresh ---
        let backlogPhases = Phases()
        pipeline.displayRenderPhaseProbeForTest = { rev, phase in backlogPhases.mark(rev, phase) }
        for i in 0..<6 {
            source.send(RawFrame(image: PreviewRenderTests.richStarField(),
                                 bayerPattern: nil, bottomUp: false,
                                 timestamp: Date(timeIntervalSince1970: TimeInterval(100 + i)),
                                 sourceName: "bl\(i).fit",
                                 identity: FileIdentity(dev: 0, ino: 0, size: 0, mtimeSec: 0,
                                                        mtimeNsec: 0, digest: "bl\(i)"),
                                 sourceURL: URL(fileURLWithPath: "/tmp/bl\(i).fit")))
        }
        usleep(300_000)   // let the consume loop pick the backlog up
        let busyRev = pipeline.currentDisplayRevision + 1
        pipeline.refreshDisplay()
        deadline = Date().addingTimeInterval(180)
        while !backlogPhases.all.contains(where: { $0.rev == busyRev && ($0.phase == .deliveryEmitted || $0.phase == .superseded) })
              && Date() < deadline { usleep(20_000) }
        report("B: 6-frame backlog", backlogPhases, focus: busyRev)
        report("B: all revisions", backlogPhases, focus: nil)
        XCTAssertTrue(true, "measurement only")
    }
}
