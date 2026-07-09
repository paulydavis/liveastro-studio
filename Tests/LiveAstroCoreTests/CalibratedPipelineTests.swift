import XCTest
@testable import LiveAstroCore

final class CalibratedPipelineTests: XCTestCase {
    /// Top-down mono starfield + additive pedestal, written as FITS.
    func writeSub(_ dir: URL, _ name: String, pedestal: Float, stars: [(Double, Double)]) throws {
        var px = [Float](repeating: 0.02 + pedestal, count: 256 * 256)
        for s in stars {
            for y in max(0, Int(s.1) - 6)...min(255, Int(s.1) + 6) {
                for x in max(0, Int(s.0) - 6)...min(255, Int(s.0) + 6) {
                    let dx = Double(x) - s.0, dy = Double(y) - s.1
                    px[y * 256 + x] += 0.8 * Float(exp(-(dx * dx + dy * dy) / 8))
                }
            }
        }
        try FITSWriter.float32(width: 256, height: 256, channels: 1, pixels: px)
            .write(to: dir.appendingPathComponent(name))
    }

    func testCalibrationRemovesPedestalFromMaster() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let subs = sandbox.appendingPathComponent("subs")
        let sessions = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: subs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        var field: [(Double, Double)] = []
        for i in 0..<20 { field.append((Double((i * 47) % 240 + 8), Double((i * 83) % 240 + 8))) }
        let pedestal: Float = 0.1
        try writeSub(subs, "Light_001.fit", pedestal: pedestal, stars: field)
        try writeSub(subs, "Light_002.fit", pedestal: pedestal, stars: field.map { ($0.0 + 2.0, $0.1 - 1.0) })

        // Master dark = constant pedestal.
        let dark = AstroImage(width: 256, height: 256, channels: 1,
                              pixels: [Float](repeating: pedestal, count: 256 * 256), sourceIsLinear: true)

        let profile = SessionProfile(targetName: "Cal", telescope: "T", camera: "C", mount: "M",
                                     filter: "F", locationLabel: "L", bortle: 5,
                                     subExposureSeconds: 20, notes: "")
        let source = FolderFrameSource(folder: subs, mode: .importOnce, fileNamePrefix: "Light_")
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: profile, rootDirectory: sessions,
                                       calibrator: Calibrator(dark: dark, flat: nil))
        try pipeline.start()
        let replayURL = try pipeline.end()
        let masterURL = replayURL.deletingLastPathComponent().appendingPathComponent("master.fit")
        let master = try FITSReader.read(Data(contentsOf: masterURL))
        // Background (corner pixel, no star) should be ~0.02 (pedestal removed), not ~0.12.
        XCTAssertLessThan(master.pixels[0], 0.05)
    }
}
