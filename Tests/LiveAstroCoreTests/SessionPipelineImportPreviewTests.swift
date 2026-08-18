import XCTest
@testable import LiveAstroCore

/// Pins the finalizeCommitted (import) call-site: the on-disk snapshot is rendered from the
/// downsampled preview, not the full-res stack. Reverting the downsample wiring in
/// SessionPipeline would make the snapshot the full stack width again (2026-08-17 P3 review).
/// Uses a shrunk `importPreviewLongEdge` so a small frame exercises the same wiring fast.
final class SessionPipelineImportPreviewTests: XCTestCase {
    private final class OneFrameFiniteSource: FrameSource {
        let frames: AsyncStream<RawFrame>
        var isFinite: Bool { true }
        var totalCount: Int? { 1 }
        init(_ frame: RawFrame) { frames = AsyncStream { c in c.yield(frame); c.finish() } }
        func start() throws {}
        func stop() {}
    }

    func testImportSnapshotRenderedFromDownscaledPreview() throws {
        let w = 400, h = 260   // long edge 400 > the shrunk cap (200) → downsample must engage
        var px = [Float](repeating: 0.05, count: w * h)
        for i in 0..<20 {      // ≥15 well-separated stars so the engine seeds
            let sx = (i % 5) * 76 + 20, sy = (i / 5) * 60 + 20
            for y in (sy - 5)...(sy + 5) { for x in (sx - 5)...(sx + 5) {
                let dx = Double(x - sx), dy = Double(y - sy)
                px[y * w + x] += 0.9 * Float(exp(-(dx * dx + dy * dy) / 6))
            } }
        }
        let img = AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true)
        let frame = RawFrame(image: img, bayerPattern: nil, bottomUp: false,
                             timestamp: Date(timeIntervalSince1970: 0), sourceName: "big.fit")

        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let profile = SessionProfile(targetName: "Big", telescope: "T", camera: "C", mount: "M",
                                     filter: "F", locationLabel: "L", bortle: 5, subExposureSeconds: 20, notes: "")
        let engine = StackEngine()
        let pipeline = SessionPipeline(nativeSource: OneFrameFiniteSource(frame), engine: engine,
                                       profile: profile, rootDirectory: sandbox, neutralizeBackground: false)
        pipeline.rendersReplay = false        // end() returns the session dir, skips the replay render
        pipeline.importPreviewLongEdge = 200  // shrink the cap so a 400px frame exercises the wiring fast

        try pipeline.start()
        let sessionDir = try pipeline.end()
        let snap = try ImageLoader.load(url: sessionDir.appendingPathComponent("snapshots/0001.png"))
        XCTAssertEqual(max(snap.width, snap.height), 200,
                       "import snapshot must be rendered from the downsampled preview, not the full 400px stack")
    }
}
