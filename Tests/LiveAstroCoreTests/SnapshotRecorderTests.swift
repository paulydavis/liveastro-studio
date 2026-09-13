import XCTest
import CoreGraphics
@testable import LiveAstroCore

final class SnapshotRecorderTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("snapshots"),
                                                withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func makeImage(width: Int, height: Int, value: Float) -> (AstroImage, CGImage) {
        let img = AstroImage(width: width, height: height, channels: 1,
                             pixels: [Float](repeating: value, count: width * height),
                             sourceIsLinear: true)
        let cg = AutoStretch.makeCGImage(AutoStretch.stretch(img))!
        return (img, cg)
    }

    func testSaveWritesPNGAndReturnsRecord() throws {
        let img = AstroImage(width: 8, height: 6, channels: 1,
                             pixels: [Float](repeating: 0.1, count: 48), sourceIsLinear: true)
        let cg = AutoStretch.makeCGImage(AutoStretch.stretch(img))!
        let rec = try SnapshotRecorder(sessionDirectory: tmp).save(
            cgImage: cg, linear: img, sourceFile: "live_stack.fit",
            index: 3, timestamp: Date(), estimatedIntegrationSeconds: 360)
        XCTAssertEqual(rec.snapshotFile, "snapshots/0003.png")
        XCTAssertEqual(rec.width, 8); XCTAssertEqual(rec.height, 6)
        XCTAssertEqual(rec.mean, 0.1, accuracy: 1e-4)
        let path = tmp.appendingPathComponent(rec.snapshotFile).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertNotNil(try? ImageLoader.load(url: tmp.appendingPathComponent(rec.snapshotFile)))
    }

    func testSaveWritesLatestPNG() throws {
        let (img, cg) = makeImage(width: 8, height: 6, value: 0.1)

        _ = try SnapshotRecorder(sessionDirectory: tmp).save(
            cgImage: cg, linear: img, sourceFile: "live_stack.fit",
            index: 1, timestamp: Date(), estimatedIntegrationSeconds: 60)

        let latest = tmp.appendingPathComponent("latest.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: latest.path))
        let decoded = try ImageLoader.load(url: latest)
        XCTAssertEqual(decoded.width, 8)
        XCTAssertEqual(decoded.height, 6)
    }

    func testLatestPNGTracksMostRecentSnapshot() throws {
        let recorder = SnapshotRecorder(sessionDirectory: tmp)
        let (first, firstCG) = makeImage(width: 8, height: 6, value: 0.1)
        let (second, secondCG) = makeImage(width: 4, height: 3, value: 0.5)

        let rec1 = try recorder.save(cgImage: firstCG, linear: first,
                                     sourceFile: "first.fit", index: 1,
                                     timestamp: Date(), estimatedIntegrationSeconds: 60)
        _ = try recorder.save(cgImage: secondCG, linear: second,
                              sourceFile: "second.fit", index: 2,
                              timestamp: Date(), estimatedIntegrationSeconds: 120)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent(rec1.snapshotFile).path))
        let latest = try ImageLoader.load(url: tmp.appendingPathComponent("latest.png"))
        XCTAssertEqual(latest.width, 4)
        XCTAssertEqual(latest.height, 3)
    }

    private func filledCGImage(w: Int, h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    func testLargeSnapshotDownscaledButRecordKeepsFullDims() throws {
        // 26MP display image → snapshot PNG capped at 2560px long edge (2.5K preview),
        // but the manifest record still reports the true stacked size from `linear`.
        let big = filledCGImage(w: 6248, h: 4176)
        let linear = AstroImage(width: 120, height: 80, channels: 1,
                                pixels: [Float](repeating: 0.1, count: 120 * 80), sourceIsLinear: true)
        let rec = try SnapshotRecorder(sessionDirectory: tmp).save(
            cgImage: big, linear: linear, sourceFile: "big.fit",
            index: 5, timestamp: Date(), estimatedIntegrationSeconds: 100)
        let decoded = try ImageLoader.load(url: tmp.appendingPathComponent(rec.snapshotFile))
        XCTAssertEqual(decoded.width, 2560, "snapshot long edge capped at 2560")
        XCTAssertTrue((1709...1713).contains(decoded.height), "aspect preserved, got \(decoded.height)")
        XCTAssertEqual(rec.width, 120); XCTAssertEqual(rec.height, 80)   // record from linear, not the preview
        let latest = try ImageLoader.load(url: tmp.appendingPathComponent("latest.png"))
        XCTAssertEqual(latest.width, 2560, "latest.png is the same downscaled preview")
    }

    func testSnapshotAtOrBelowCapNotResized() throws {
        let small = filledCGImage(w: 1920, h: 1280)   // <= 2560 → passthrough, exact dims
        let linear = AstroImage(width: 1920, height: 1280, channels: 1,
                                pixels: [Float](repeating: 0.1, count: 1920 * 1280), sourceIsLinear: true)
        let rec = try SnapshotRecorder(sessionDirectory: tmp).save(
            cgImage: small, linear: linear, sourceFile: "s.fit",
            index: 1, timestamp: Date(), estimatedIntegrationSeconds: 20)
        let decoded = try ImageLoader.load(url: tmp.appendingPathComponent(rec.snapshotFile))
        XCTAssertEqual(decoded.width, 1920); XCTAssertEqual(decoded.height, 1280)
    }

    func testSaveThrowsWhenSnapshotsSubdirectoryMissing() throws {
        let bare = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-bare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bare) }
        let img = AstroImage(width: 8, height: 6, channels: 1,
                             pixels: [Float](repeating: 0.1, count: 48), sourceIsLinear: true)
        let cg = AutoStretch.makeCGImage(AutoStretch.stretch(img))!
        XCTAssertThrowsError(try SnapshotRecorder(sessionDirectory: bare).save(
            cgImage: cg, linear: img, sourceFile: "live_stack.fit",
            index: 1, timestamp: Date(), estimatedIntegrationSeconds: 60))
    }
}
