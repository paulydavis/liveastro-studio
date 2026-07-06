import XCTest
import AVFoundation
@testable import LiveAstroCore

final class EndToEndTests: XCTestCase {
    var watchDir: URL!
    var rootDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-\(UUID().uuidString)", isDirectory: true)
        watchDir = base.appendingPathComponent("watch")
        rootDir = base.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: watchDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: watchDir.deletingLastPathComponent())
    }

    /// Fake Siril: rewrites live_stack.fit N times (partial write, pause, complete),
    /// waiting for the pipeline to accept each update before the next rewrite.
    func testFullSession() throws {
        let profile = SessionProfile(targetName: "Test Nebula", telescope: "Test APO",
                                     camera: "TestCam", subExposureSeconds: 20)
        var replay = ReplaySettings()
        replay.duration = 2; replay.fps = 10; replay.width = 320; replay.height = 180

        let pipeline = SessionPipeline(watchFolder: watchDir, profile: profile,
                                       rootDirectory: rootDir, replaySettings: replay,
                                       maxKeyframes: 10)
        let updateCount = NSLock() // simple counter guard
        var accepted = 0
        pipeline.onUpdate = { _, _ in updateCount.lock(); accepted += 1; updateCount.unlock() }
        try pipeline.start()

        let stackURL = watchDir.appendingPathComponent("live_stack.fit")
        let frames = 4
        for k in 1...frames {
            // Different content each rewrite: brightness grows with k.
            let px = (0..<(32 * 32)).map { i in
                Float(k) * 0.1 + Float(i % 32) / 320.0
            }
            let data = FITSWriter.float32(width: 32, height: 32, channels: 1, pixels: px)
            try data.prefix(data.count / 2).write(to: stackURL)   // partial
            Thread.sleep(forTimeInterval: 0.1)
            try data.write(to: stackURL)                          // complete
            // Wait until the pipeline accepts this update before writing the next.
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                updateCount.lock(); let n = accepted; updateCount.unlock()
                if n >= k { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            updateCount.lock(); let n = accepted; updateCount.unlock()
            XCTAssertGreaterThanOrEqual(n, k, "update \(k) never accepted")
        }

        let replayURL = try pipeline.end()

        // Manifest
        let manifest = try ManifestCoding.decoder().decode(
            SessionManifest.self,
            from: Data(contentsOf: pipeline.session.sessionDirectory!
                .appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.snapshots.count, frames)
        XCTAssertNotNil(manifest.endTime)
        XCTAssertEqual(manifest.snapshots.last!.estimatedIntegrationSeconds,
                       Double(frames) * 20, accuracy: 0.1)

        // Snapshots on disk
        for rec in manifest.snapshots {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: pipeline.session.sessionDirectory!.appendingPathComponent(rec.snapshotFile).path))
        }

        // Replay is a real video
        XCTAssertTrue(FileManager.default.fileExists(atPath: replayURL.path))
        let exp = expectation(description: "asset")
        Task {
            let d = try await AVURLAsset(url: replayURL).load(.duration)
            XCTAssertEqual(CMTimeGetSeconds(d), 2.0, accuracy: 0.3)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
    }
}
