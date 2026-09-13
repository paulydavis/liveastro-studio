import XCTest
@testable import LiveAstroCore

/// Task 11: `sub-frames.csv` is written at session finalize (`SessionManager.endSession`,
/// called from `SessionPipeline.end()`), mirroring the existing `frame-summary.csv` write.
/// Reuses the same native-pipeline harness as `SessionPipelineSubFrameTests`
/// (ControlledLiveSource + FaultMatrixLifecycleTests star/blank field builders) — there is
/// no shared `NativePipelineHarness` type in this codebase.
final class SessionPipelineSubFrameCSVTests: XCTestCase {
    private func profile(_ target: String = "SubFrame CSV Test") -> SessionProfile {
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

    func testEndWritesSubFramesCSV() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        let source = NativePipelineTests.ControlledLiveSource()
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: profile(), rootDirectory: sessions)

        let subFrameCount = expectation(description: "onSubFrame fired 2 times")
        subFrameCount.expectedFulfillmentCount = 2
        pipeline.onSubFrame = { _ in subFrameCount.fulfill() }

        try pipeline.start()
        source.send(FaultMatrixLifecycleTests.starField(name: "seed.fit", dx: 0, dy: 0))
        source.send(FaultMatrixLifecycleTests.starField(name: "good.fit", dx: 1.1, dy: -0.9))
        wait(for: [subFrameCount], timeout: 5)

        let sessionDirectory = pipeline.session.sessionDirectory
        _ = try pipeline.end()

        let dir = try XCTUnwrap(sessionDirectory)
        let csv = dir.appendingPathComponent("sub-frames.csv")
        XCTAssertTrue(FileManager.default.fileExists(atPath: csv.path))
        let text = try String(contentsOf: csv, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("index,timestamp,source_file,star_count"))
        XCTAssertEqual(text.split(separator: "\n").count, 3)   // header + 2 subs
    }
}
