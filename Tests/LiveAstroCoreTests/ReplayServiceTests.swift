import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LiveAstroCore

final class ReplayServiceTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("replay-svc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Helpers

    private func writePNG(to url: URL, gray: Double, width: Int, height: Int) throws {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                           bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }

    /// Builds a self-contained session directory with 3 gradient PNGs and a matching manifest.json.
    private func buildSessionDir(snapshots count: Int = 3) throws -> URL {
        let dir = tmp.appendingPathComponent("session", isDirectory: true)
        let snapshotsDir = dir.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)

        var records: [SnapshotRecord] = []
        for i in 1...max(1, count) {
            let filename = "snapshots/\(String(format: "%04d", i)).png"
            let pngURL = dir.appendingPathComponent(filename)
            if i <= count {
                try writePNG(to: pngURL, gray: Double(i) * 0.25, width: 160, height: 90)
                records.append(SnapshotRecord(
                    index: i,
                    timestamp: Date(),
                    sourceFile: "frame_\(i).fits",
                    snapshotFile: filename,
                    estimatedIntegrationSeconds: Double(i) * 20,
                    width: 160, height: 90,
                    mean: 0.5, median: 0.5, stddev: 0.1))
            }
        }

        let manifest = SessionManifest(
            sessionId: "2026-07-05-test",
            targetName: "Test",
            startTime: Date(),
            endTime: nil,
            subExposureSeconds: 20,
            bortle: nil,
            locationLabel: "",
            telescope: "",
            camera: "",
            mount: "",
            filter: "",
            notes: "",
            snapshots: records)

        let data = try ManifestCoding.encoder().encode(manifest)
        try data.write(to: dir.appendingPathComponent("manifest.json"))
        return dir
    }

    // MARK: - Tests

    func testRegenerateProducesValidMP4() throws {
        let dir = try buildSessionDir(snapshots: 3)
        var settings = ReplaySettings()
        settings.duration = 1; settings.fps = 10
        settings.width = 160; settings.height = 90; settings.crossfade = 0.2

        let outputURL = try ReplayService.regenerate(sessionDirectory: dir,
                                                     replaySettings: settings,
                                                     maxKeyframes: 45)

        XCTAssertEqual(outputURL.lastPathComponent, "replay.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path),
                      "replay.mp4 should exist after regenerate")

        let asset = AVURLAsset(url: outputURL)
        let exp = expectation(description: "asset load")
        Task {
            let duration = try await asset.load(.duration)
            XCTAssertEqual(CMTimeGetSeconds(duration), 1.0, accuracy: 0.25,
                           "Replay duration should be approximately 1 second")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
    }

    func testEmptySnapshotsReturnsURLWithoutCreatingFile() throws {
        let dir = try buildSessionDir(snapshots: 0)
        // buildSessionDir with 0 writes records for max(1,0)=1, so we need a clean empty manifest
        let emptyManifest = SessionManifest(
            sessionId: "2026-07-05-empty",
            targetName: "Empty",
            startTime: Date(),
            endTime: nil,
            subExposureSeconds: 20,
            bortle: nil,
            locationLabel: "",
            telescope: "",
            camera: "",
            mount: "",
            filter: "",
            notes: "",
            snapshots: [])

        let emptyDir = tmp.appendingPathComponent("empty-session", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        let data = try ManifestCoding.encoder().encode(emptyManifest)
        try data.write(to: emptyDir.appendingPathComponent("manifest.json"))

        let outputURL = try ReplayService.regenerate(sessionDirectory: emptyDir)

        XCTAssertEqual(outputURL, emptyDir.appendingPathComponent("replay.mp4"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path),
                       "replay.mp4 should NOT be created for an empty session")
    }

    func testMissingManifestThrows() {
        let dir = tmp.appendingPathComponent("no-manifest", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        XCTAssertThrowsError(try ReplayService.regenerate(sessionDirectory: dir),
                             "regenerate should throw when manifest.json is absent")
    }
}
