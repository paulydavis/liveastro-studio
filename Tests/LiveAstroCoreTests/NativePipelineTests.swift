import XCTest
@testable import LiveAstroCore

final class NativePipelineTests: XCTestCase {
    /// Mono starfield FITS subs (no BAYERPAT — engine's mono path), one starless.
    func writeSub(_ dir: URL, name: String, stars: [(Double, Double)]) throws {
        var px = [Float](repeating: 0.05, count: 256 * 256)
        for s in stars {
            for y in max(0, Int(s.1) - 6)...min(255, Int(s.1) + 6) {
                for x in max(0, Int(s.0) - 6)...min(255, Int(s.0) + 6) {
                    let dx = Double(x) - s.0, dy = Double(y) - s.1
                    px[y * 256 + x] += 0.8 * Float(exp(-(dx * dx + dy * dy) / (2 * 2.0 * 2.0)))
                }
            }
        }
        try FITSWriter.float32(width: 256, height: 256, channels: 1, pixels: px)
            .write(to: dir.appendingPathComponent(name))
    }

    func testImportEndToEnd() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let subsDir = sandbox.appendingPathComponent("subs")
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: subsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        var field: [(Double, Double)] = []
        for i in 0..<20 {
            field.append((Double((i * 47) % 240 + 8), Double((i * 83) % 240 + 8)))
        }
        try writeSub(subsDir, name: "Light_001.fit", stars: field)
        try writeSub(subsDir, name: "Light_002.fit", stars: field.map { ($0.0 + 2.4, $0.1 - 1.1) })
        try writeSub(subsDir, name: "Light_003.fit", stars: [])          // rejected
        try writeSub(subsDir, name: "Light_004.fit", stars: field.map { ($0.0 - 1.2, $0.1 + 0.8) })

        let profile = SessionProfile(targetName: "Test Field", telescope: "T", camera: "C",
                                     mount: "M", filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let source = FolderFrameSource(folder: subsDir, mode: .importOnce, fileNamePrefix: "Light_")
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: profile, rootDirectory: sessions)
        var rejected: [String] = []
        pipeline.onRejected = { _, name in rejected.append(name) }
        try pipeline.start()
        let replayURL = try pipeline.end()   // end() drains the finite import stream first

        XCTAssertEqual(rejected, ["Light_003.fit"])
        let sessionDir = replayURL.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: replayURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("master.fit").path))
        let manifest = try ManifestCoding.decoder().decode(SessionManifest.self,
            from: Data(contentsOf: sessionDir.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.snapshots.count, 3)
        XCTAssertEqual(manifest.snapshots.last?.estimatedIntegrationSeconds, 60)   // 3 accepted × 20 s
        // master.fit round-trips through our own reader
        let master = try FITSReader.read(Data(contentsOf: sessionDir.appendingPathComponent("master.fit")))
        XCTAssertEqual(master.width, 256)
    }
}
