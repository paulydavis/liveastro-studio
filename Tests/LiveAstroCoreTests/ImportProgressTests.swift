import XCTest
@testable import LiveAstroCore

final class ImportProgressTests: XCTestCase {
    func writeSub(_ dir: URL, _ name: String, stars: [(Double, Double)]) throws {
        var px = [Float](repeating: 0.05, count: 128 * 128)
        for s in stars {
            for y in max(0, Int(s.1)-4)...min(127, Int(s.1)+4) {
                for x in max(0, Int(s.0)-4)...min(127, Int(s.0)+4) {
                    let dx = Double(x)-s.0, dy = Double(y)-s.1
                    px[y*128+x] += 0.8 * Float(exp(-(dx*dx+dy*dy)/6))
                }
            }
        }
        try FITSWriter.float32(width: 128, height: 128, channels: 1, pixels: px)
            .write(to: dir.appendingPathComponent(name))
    }

    func testImportReportsProgress() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let subs = sandbox.appendingPathComponent("subs"), sessions = sandbox.appendingPathComponent("s")
        try FileManager.default.createDirectory(at: subs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        var field: [(Double, Double)] = []
        for i in 0..<18 { field.append((Double((i*37)%116+6), Double((i*53)%116+6))) }
        for i in 1...4 { try writeSub(subs, "Light_00\(i).fit", stars: field.map { ($0.0 + Double(i)*0.5, $0.1) }) }

        let profile = SessionProfile(targetName: "T", telescope: "", camera: "", mount: "",
                                     filter: "", locationLabel: "", bortle: 5, subExposureSeconds: 10, notes: "")
        let source = FolderFrameSource(folder: subs, mode: .importOnce, fileNamePrefix: "Light_")
        XCTAssertEqual(source.totalCount, 4)
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: profile, rootDirectory: sessions)
        var lastTotal = 0, lastProcessed = 0
        pipeline.onImportProgress = { processed, total, _, _ in lastProcessed = processed; lastTotal = total }
        try pipeline.start()
        _ = try pipeline.end()
        XCTAssertEqual(lastTotal, 4)
        XCTAssertEqual(lastProcessed, 4)
    }
}
