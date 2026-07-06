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
}
