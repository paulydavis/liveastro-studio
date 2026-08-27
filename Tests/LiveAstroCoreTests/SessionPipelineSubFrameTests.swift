import XCTest
@testable import LiveAstroCore

/// Covers Task 6: `SessionPipeline.onSubFrame` fires once per processed native sub with
/// outcome mapped from `ProcessResult` (Task 5). Reuses the native live-source harness
/// (ControlledLiveSource + FaultMatrixLifecycleTests.starField/blankField) already used
/// by NativePipelineTests, since there's no shared `NativePipelineHarness` type.
final class SessionPipelineSubFrameTests: XCTestCase {
    private func profile(_ target: String = "SubFrame Test") -> SessionProfile {
        SessionProfile(targetName: target, telescope: "T", camera: "C",
                       mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                       subExposureSeconds: 20, notes: "")
    }

    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testOnSubFrameFiresForEachNativeSub() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        let source = NativePipelineTests.ControlledLiveSource()
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: profile(), rootDirectory: sessions)

        let captureLock = NSLock()
        var captured: [SubFrameRecord] = []
        let subFrameCount = expectation(description: "onSubFrame fired 3 times")
        subFrameCount.expectedFulfillmentCount = 3
        pipeline.onSubFrame = { record in
            captureLock.withLock { captured.append(record) }
            subFrameCount.fulfill()
        }

        try pipeline.start()
        // seed
        source.send(FaultMatrixLifecycleTests.starField(name: "seed.fit", dx: 0, dy: 0))
        // registers against the seed -> stacked
        source.send(FaultMatrixLifecycleTests.starField(name: "good.fit", dx: 1.1, dy: -0.9))
        // star-less frame -> rejected (insufficient stars)
        source.send(FaultMatrixLifecycleTests.blankField(name: "too_few_stars.fit"))
        wait(for: [subFrameCount], timeout: 5)

        _ = try pipeline.end()

        let records = captureLock.withLock { captured }
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[0].outcome, .reference)
        XCTAssertEqual(records[0].sourceFile, "seed.fit")
        XCTAssertEqual(records[1].outcome, .stacked)
        XCTAssertEqual(records[1].sourceFile, "good.fit")
        XCTAssertEqual(records[2].outcome, .rejected)
        XCTAssertEqual(records[2].sourceFile, "too_few_stars.fit")
        XCTAssertNotNil(records[2].rejectionReason)
        // Accepted subs' indices must match the snapshot index (engine.acceptedCount).
        XCTAssertEqual(records[0].index, 1)
        XCTAssertEqual(records[1].index, 2)
    }

    /// Task 8a: the pipeline persists every emitted sub (accepted AND rejected) into
    /// `session.subFrames` on the same callback-delivery thread as the emit — completing
    /// Task 6's emit-only hook into the data-plane write.
    func testPipelinePersistsEverySubToSessionManifest() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        let source = NativePipelineTests.ControlledLiveSource()
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: profile(), rootDirectory: sessions)

        let captureLock = NSLock()
        var captured: [SubFrameRecord] = []
        let subFrameCount = expectation(description: "onSubFrame fired 3 times")
        subFrameCount.expectedFulfillmentCount = 3
        pipeline.onSubFrame = { record in
            captureLock.withLock { captured.append(record) }
            subFrameCount.fulfill()
        }

        try pipeline.start()
        source.send(FaultMatrixLifecycleTests.starField(name: "seed.fit", dx: 0, dy: 0))
        source.send(FaultMatrixLifecycleTests.starField(name: "good.fit", dx: 1.1, dy: -0.9))
        source.send(FaultMatrixLifecycleTests.blankField(name: "too_few_stars.fit"))
        wait(for: [subFrameCount], timeout: 5)

        _ = try pipeline.end()

        let records = captureLock.withLock { captured }
        let persisted = pipeline.session.subFrames
        XCTAssertEqual(persisted.count, 3)
        XCTAssertEqual(persisted.map(\.sourceFile), records.map(\.sourceFile))
        XCTAssertEqual(persisted.map(\.outcome), records.map(\.outcome))
        XCTAssertEqual(persisted.map(\.index), records.map(\.index))
        // Persisted set must include both accepted and rejected subs.
        XCTAssertEqual(persisted.filter { $0.outcome == .rejected }.count, 1)
        XCTAssertEqual(persisted.filter { $0.outcome != .rejected }.count, 2)
    }

    /// Fix A regression: a rejection that lands BEFORE a later accept must not collide
    /// indices. Before the fix, `index` was `processedCount` for rejected subs but
    /// `engine.acceptedCount` for accepted subs — two counters that overlap
    /// (acceptedCount <= processedCount), so a reject-then-accept sequence could produce
    /// duplicate indices (the seed's acceptedCount, then the reject's processedCount, then
    /// the next accept's acceptedCount collide once processedCount outruns acceptedCount).
    /// This broke StatsView's `ForEach(id: \.index)` and `toggleReject`'s
    /// `firstIndex(by index)` lookup. Sequence: seed (accept/reference) -> blank
    /// (reject) -> good (accept/stacked) — the reject is NOT last, reproducing the
    /// collision (seed.index == acceptedCount 1; blank.index == processedCount 2;
    /// good.index == acceptedCount 2 — collides with blank pre-fix).
    func testSubFrameIndicesAreDistinctWhenRejectionPrecedesAccepts() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        let source = NativePipelineTests.ControlledLiveSource()
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: profile(), rootDirectory: sessions)

        let subFrameCount = expectation(description: "onSubFrame fired 3 times")
        subFrameCount.expectedFulfillmentCount = 3
        pipeline.onSubFrame = { _ in subFrameCount.fulfill() }

        try pipeline.start()
        // seed -> becomes reference (accepted)
        source.send(FaultMatrixLifecycleTests.starField(name: "seed.fit", dx: 0, dy: 0))
        // star-less frame -> rejected, BEFORE the next accept
        source.send(FaultMatrixLifecycleTests.blankField(name: "too_few_stars.fit"))
        // registers against the seed -> stacked (accepted)
        source.send(FaultMatrixLifecycleTests.starField(name: "good.fit", dx: 1.1, dy: -0.9))
        wait(for: [subFrameCount], timeout: 5)

        _ = try pipeline.end()

        let indices = pipeline.session.subFrames.map(\.index)
        XCTAssertEqual(indices.count, 3)
        XCTAssertEqual(Set(indices).count, indices.count, "sub-frame indices must all be distinct, got \(indices)")
    }
}
