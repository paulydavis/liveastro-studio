import XCTest
import CoreGraphics
@testable import LiveAstroCore

final class SessionPipelineDisplayAdjTests: XCTestCase {
    private func writeSub(_ dir: URL, _ name: String, stars: [(Double, Double)]) throws {
        var px = [Float](repeating: 0.05, count: 256 * 256)
        for s in stars {
            for y in max(0, Int(s.1)-6)...min(255, Int(s.1)+6) {
                for x in max(0, Int(s.0)-6)...min(255, Int(s.0)+6) {
                    let dx = Double(x)-s.0, dy = Double(y)-s.1
                    px[y*256+x] += 0.8 * Float(exp(-(dx*dx+dy*dy)/(2*2.0*2.0)))
                }
            }
        }
        try FITSWriter.float32(width: 256, height: 256, channels: 1, pixels: px)
            .write(to: dir.appendingPathComponent(name))
    }
    /// Writes a 3-channel (RGB) sub whose background carries a horizontal ramp
    /// (light-pollution gradient) plus the same Gaussian star field. DBE operates
    /// only on 3-channel images, so this is required for the differential gate.
    private func writeGradientSubRGB(_ dir: URL, _ name: String, stars: [(Double, Double)]) throws {
        let w = 256, h = 256, plane = w * h
        var px = [Float](repeating: 0, count: plane * 3)
        for c in 0..<3 {
            let base = c * plane
            for y in 0..<h {
                for x in 0..<w {
                    px[base + y*w + x] = 0.05 + 0.4 * Float(x) / Float(w - 1)   // horizontal LP ramp
                }
            }
        }
        for s in stars {
            for y in max(0, Int(s.1)-6)...min(h-1, Int(s.1)+6) {
                for x in max(0, Int(s.0)-6)...min(w-1, Int(s.0)+6) {
                    let dx = Double(x)-s.0, dy = Double(y)-s.1
                    let g = 0.8 * Float(exp(-(dx*dx+dy*dy)/(2*2.0*2.0)))
                    for c in 0..<3 { px[c*plane + y*w + x] = min(px[c*plane + y*w + x] + g, 1) }
                }
            }
        }
        try FITSWriter.float32(width: w, height: h, channels: 3, pixels: px)
            .write(to: dir.appendingPathComponent(name))
    }
    private func makePipeline(_ sandbox: URL, _ subsDir: URL) -> SessionPipeline {
        let profile = SessionProfile(targetName: "T", telescope: "T", camera: "C", mount: "M",
                                     filter: "F", locationLabel: "L", bortle: 5, subExposureSeconds: 20, notes: "")
        let source = FolderFrameSource(folder: subsDir, mode: .importOnce, fileNamePrefix: "Light_")
        return SessionPipeline(nativeSource: source, engine: StackEngine(),
                               profile: profile, rootDirectory: sandbox.appendingPathComponent("sessions"))
    }
    func testRenderCurrentDisplayNilWithoutStack() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let subsDir = sandbox.appendingPathComponent("subs")
        try FileManager.default.createDirectory(at: subsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let pipeline = makePipeline(sandbox, subsDir)
        XCTAssertNil(pipeline.renderCurrentDisplay(adjustments: .neutral))   // no frames → no stack
    }
    func testRenderCurrentDisplayNonNilAfterFrames() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let subsDir = sandbox.appendingPathComponent("subs")
        try FileManager.default.createDirectory(at: subsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        var field: [(Double, Double)] = []
        for i in 0..<20 { field.append((Double((i*47)%240+8), Double((i*83)%240+8))) }
        try writeSub(subsDir, "Light_001.fit", stars: field)
        try writeSub(subsDir, "Light_002.fit", stars: field.map { ($0.0+2.4, $0.1-1.1) })
        let pipeline = makePipeline(sandbox, subsDir)
        try pipeline.start()
        _ = try pipeline.end()
        XCTAssertNotNil(pipeline.renderCurrentDisplay(adjustments: DisplayAdjustments(saturation: 1.5)))
        XCTAssertEqual(pipeline.displayAdjustments.saturation, 1.5)
    }
    /// Differential gate: on a stack whose background carries a spatial gradient,
    /// rendering with DBE ON must produce DIFFERENT pixels than DBE OFF. Proves the
    /// DBE call is actually wired into the display transform (not a no-op) — this
    /// test FAILS if the BackgroundExtraction.flatten call is removed.
    func testRenderWithDBEChangesGradientImage() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let subsDir = sandbox.appendingPathComponent("subs")
        try FileManager.default.createDirectory(at: subsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        var field: [(Double, Double)] = []
        for i in 0..<20 { field.append((Double((i*47)%240+8), Double((i*83)%240+8))) }
        try writeGradientSubRGB(subsDir, "Light_001.fit", stars: field)
        try writeGradientSubRGB(subsDir, "Light_002.fit", stars: field.map { ($0.0+2.4, $0.1-1.1) })
        let pipeline = makePipeline(sandbox, subsDir)
        try pipeline.start()
        _ = try pipeline.end()

        let off = pipeline.renderCurrentDisplay(adjustments: DisplayAdjustments(backgroundExtraction: false))
        let on  = pipeline.renderCurrentDisplay(adjustments: DisplayAdjustments(backgroundExtraction: true, backgroundDegree: 2))
        XCTAssertNotNil(off)
        XCTAssertNotNil(on)
        XCTAssertTrue(pipeline.displayAdjustments.backgroundExtraction)

        func pixelData(_ cg: CGImage) -> Data { (cg.dataProvider?.data as Data?) ?? Data() }
        // DBE actually flattened the ramp → output bytes must differ.
        XCTAssertNotEqual(pixelData(off!), pixelData(on!))
    }
}
