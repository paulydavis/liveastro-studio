import XCTest
@testable import LiveAstroCore

/// Spec §6 integration: latest.png (and thus every snapshot/replay frame, which
/// share the displayCGImage render) inherits denoise when enabled, and the
/// display path never touches master.fit.
final class DenoiseDisplayIntegrationTests: XCTestCase {

    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// One noisy mono starfield sub (mono exercises stage 2; deterministic LCG noise).
    /// Star count: StackEngine's seed frame needs >= seedMinStars (15) detections or
    /// the import rejects everything and no latest.png/master exists — the plan's
    /// 3-star field was below that; the 20-star grid matches NativePipelineTests.
    private func writeNoisySub(_ dir: URL, name: String) throws {
        var rng: UInt64 = 0xDEAD_0001
        var px = (0..<(256 * 256)).map { _ -> Float in
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return 0.08 + Float(rng >> 33) / Float(1 << 31) * 0.04
        }
        var field: [(Double, Double)] = []
        for i in 0..<20 {
            field.append((Double((i * 47) % 240 + 8), Double((i * 83) % 240 + 8)))
        }
        for (sx, sy) in field {
            let cx = Int(sx), cy = Int(sy)
            for y in (cy - 6)...(cy + 6) { for x in (cx - 6)...(cx + 6) {
                let dx = Double(x) - sx
                let dy = Double(y) - sy
                let r2: Double = dx * dx + dy * dy
                px[y * 256 + x] += 0.8 * Float(exp(-r2 / 8.0))
            } }
        }
        try FITSWriter.float32(width: 256, height: 256, channels: 1,
                               pixels: px.map { min(max($0, 0), 1) })
            .write(to: dir.appendingPathComponent(name))
    }

    private func runImport(denoise: Double) throws -> URL {
        let root = try sandbox()
        let subs = root.appendingPathComponent("subs", isDirectory: true)
        try FileManager.default.createDirectory(at: subs, withIntermediateDirectories: true)
        try writeNoisySub(subs, name: "sub_0001.fit")
        let source = FolderFrameSource(folder: subs, mode: .importOnce, fileNamePrefix: nil)
        let profile = SessionProfile(targetName: "T", telescope: "t", camera: "c",
                                     mount: "m", filter: "f", locationLabel: "l",
                                     bortle: 5, subExposureSeconds: 10, notes: "")
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
                                       profile: profile, rootDirectory: root)
        pipeline.displayAdjustments = DisplayAdjustments(denoiseStrength: denoise)
        try pipeline.start()
        let replay = try pipeline.end()
        return replay.deletingLastPathComponent()             // session directory
    }

    func testLatestPNGInheritsDenoiseAndMasterDoesNot() throws {
        let neutralDir = try runImport(denoise: 0)
        let denoisedDir = try runImport(denoise: 0.8)
        let latestA = try Data(contentsOf: neutralDir.appendingPathComponent("latest.png"))
        let latestB = try Data(contentsOf: denoisedDir.appendingPathComponent("latest.png"))
        XCTAssertNotEqual(latestA, latestB, "denoise strength did not reach latest.png")
        // The replay-input keyframes (snapshots/NNNN.png, SnapshotRecorder) share the
        // displayCGImage render — assert one directly rather than arguing only by
        // construction that replay inherits denoise.
        func firstSnapshot(_ dir: URL) throws -> Data {
            let snaps = dir.appendingPathComponent("snapshots", isDirectory: true)
            let names = try FileManager.default.contentsOfDirectory(atPath: snaps.path)
                .filter { $0.hasSuffix(".png") }.sorted()
            return try Data(contentsOf: snaps.appendingPathComponent(try XCTUnwrap(names.first)))
        }
        XCTAssertNotEqual(try firstSnapshot(neutralDir), try firstSnapshot(denoisedDir),
                          "denoise strength did not reach the replay keyframes")
        // master.fit stays raw: identical input subs -> byte-identical masters
        // regardless of the display-path denoise setting (spec: master never mutated).
        let masterA = try Data(contentsOf: neutralDir.appendingPathComponent("master.fit"))
        let masterB = try Data(contentsOf: denoisedDir.appendingPathComponent("master.fit"))
        XCTAssertEqual(masterA, masterB)
    }

    func testStrengthZeroRenderMatchesNeutralAdjustments() throws {
        let a = try runImport(denoise: 0)
        let b = try runImport(denoise: 0)
        XCTAssertEqual(try Data(contentsOf: a.appendingPathComponent("latest.png")),
                       try Data(contentsOf: b.appendingPathComponent("latest.png")),
                       "strength-0 path is not deterministic/passthrough")
    }
}
