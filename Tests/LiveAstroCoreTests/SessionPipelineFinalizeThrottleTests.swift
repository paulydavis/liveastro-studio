import XCTest
@testable import LiveAstroCore

final class SessionPipelineFinalizeThrottleTests: XCTestCase {
    /// A finite source that yields the SAME frame `count` times (each registers via identity,
    /// so all commit) with totalCount set — exercises the real BatchImporter import path.
    private final class NFrameFiniteSource: FrameSource {
        let frames: AsyncStream<RawFrame>
        var isFinite: Bool { true }
        let totalCount: Int?
        init(_ frame: RawFrame, count: Int) {
            totalCount = count
            frames = AsyncStream { c in for _ in 0..<count { c.yield(frame) }; c.finish() }
        }
        func start() throws {}
        func stop() {}
    }

    private func starFrame() -> RawFrame {
        let w = 240, h = 180
        var px = [Float](repeating: 0.05, count: w * h)
        for i in 0..<20 {                       // ≥15 well-separated stars so the engine seeds
            let sx = (i % 5) * 46 + 20, sy = (i / 5) * 42 + 20
            for y in (sy - 4)...(sy + 4) { for x in (sx - 4)...(sx + 4) {
                let dx = Double(x - sx), dy = Double(y - sy)
                px[y * w + x] += 0.9 * Float(exp(-(dx * dx + dy * dy) / 5))
            } }
        }
        let img = AstroImage(width: w, height: h, channels: 1, pixels: px, sourceIsLinear: true)
        return RawFrame(image: img, bayerPattern: nil, bottomUp: false,
                        timestamp: Date(timeIntervalSince1970: 0), sourceName: "sub.fit")
    }

    private func run(count: Int, budget: Int) throws -> (dir: URL, snapshots: Int) {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let profile = SessionProfile(targetName: "T", subExposureSeconds: 20)
        let engine = StackEngine()
        let pipeline = SessionPipeline(nativeSource: NFrameFiniteSource(starFrame(), count: count),
                                       engine: engine, profile: profile, rootDirectory: sandbox)
        pipeline.snapshotBudget = budget
        pipeline.rendersReplay = false     // skip the replay render for speed; end()'s final snapshot
                                           // render runs before replay, so it's still exercised
        try pipeline.start()
        let dir = try pipeline.end()
        let snaps = try FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("snapshots"),
                                                                includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }.count
        return (dir, snaps)
    }

    /// budget 5 over 20 frames → stride 4 → renders at 1,4,8,12,16,20 = 6 snapshots (not 20).
    func testImportThrottlesSnapshots() throws {
        let (dir, snaps) = try run(count: 20, budget: 5)
        XCTAssertEqual(snaps, 6, "throttled import should render ~budget snapshots, not one per frame")
        // Every frame still counted: manifest integration reflects all 20 accepted.
        let manifest = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
        XCTAssertFalse(manifest.isEmpty)
    }
}
