import XCTest
@testable import LiveAstroCore

/// End-to-end tests for Task 4: SessionPipeline.end() crops master.fit to the
/// covered region (before additive balance) when subs drift; leaves full frame
/// when subs are identical (uniform coverage → safety/no-op path).
final class CropToOverlapPipelineTests: XCTestCase {

    // Sub dimensions used across helpers
    private let SUB_W = 256
    private let SUB_H = 256

    // MARK: - Tests

    func testMasterIsCroppedToCoveredRegion() throws {
        let (subsDir, sessionRoot) = try makeDriftingSession()
        defer {
            try? FileManager.default.removeItem(at: subsDir.deletingLastPathComponent())
        }
        let masterURL = try findMaster(in: sessionRoot)
        let hdr = try FITSReader.readHeader(Data(contentsOf: masterURL))
        let w = Int(hdr.keywords["NAXIS1"]!.trimmingCharacters(in: .whitespaces))!
        let h = Int(hdr.keywords["NAXIS2"]!.trimmingCharacters(in: .whitespaces))!
        // Drifting subs => covered core is strictly smaller than a single sub
        XCTAssertLessThan(w, SUB_W, "Master width should be cropped (got \(w), sub width \(SUB_W))")
        XCTAssertLessThan(h, SUB_H, "Master height should be cropped (got \(h), sub height \(SUB_H))")
        // Safety guard must keep a majority of the frame
        XCTAssertGreaterThan(w, SUB_W / 2, "Safety guard: cropped width must exceed half sub width")
        XCTAssertGreaterThan(h, SUB_H / 2, "Safety guard: cropped height must exceed half sub height")
    }

    func testFullFrameWhenNoDrift() throws {
        let (subsDir, sessionRoot) = try makeNoDriftSession()
        defer {
            try? FileManager.default.removeItem(at: subsDir.deletingLastPathComponent())
        }
        let masterURL = try findMaster(in: sessionRoot)
        let hdr = try FITSReader.readHeader(Data(contentsOf: masterURL))
        let w = Int(hdr.keywords["NAXIS1"]!.trimmingCharacters(in: .whitespaces))!
        let h = Int(hdr.keywords["NAXIS2"]!.trimmingCharacters(in: .whitespaces))!
        // Identical subs => uniform coverage => no crop
        XCTAssertEqual(w, SUB_W, "No-drift: master width should equal sub width")
        XCTAssertEqual(h, SUB_H, "No-drift: master height should equal sub height")
    }

    // MARK: - Session Helpers

    /// Builds a native session over CFA subs that each have their star pattern
    /// shifted by a per-frame translation. The shift is large enough (~20 px each
    /// frame over 4 frames = 60 px total drift) so the covered intersection is
    /// well under the full frame, but small enough that registration still matches.
    private func makeDriftingSession() throws -> (URL, URL) {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let subsDir = sandbox.appendingPathComponent("subs")
        let sessionsRoot = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: subsDir, withIntermediateDirectories: true)

        // 20 bright stars in the centre of the frame — positions ensure they stay
        // inside the sub bounds even after the maximum drift offset.
        var field: [(Double, Double)] = []
        for i in 0..<20 {
            // Cluster stars in the centre 100×100 region (rows 78–178, cols 78–178)
            // so they remain visible after a drift of up to ±60 px.
            field.append((Double((i * 47) % 100 + 78), Double((i * 83) % 100 + 78)))
        }

        let profile = SessionProfile(
            targetName: "Drift Test", telescope: "Test", camera: "Test",
            mount: "Test", filter: "L", locationLabel: "Lab", bortle: 5,
            subExposureSeconds: 60, notes: ""
        )

        // 5 subs: reference at centre, then 4 drifted subs each shifted +8 px
        // right and +8 px down relative to the previous frame. Total drift: 32×32 px.
        // After stacking + Warp masking, uncovered border strips have weight==0 and
        // the well-covered core is (256-32)×(256-32) = 224×224 (~77% of full frame,
        // above the 60% safety-guard threshold) — so CoverageCrop crops to it.
        let drifts: [(Double, Double)] = [
            (0, 0), (8, 8), (16, 16), (24, 24), (32, 32)
        ]
        for (idx, drift) in drifts.enumerated() {
            let shifted = field.map { ($0.0 + drift.0, $0.1 + drift.1) }
            let name = String(format: "Light_%03d.fit", idx + 1)
            try writeCFASub(subsDir, name: name, stars: shifted, W: SUB_W, H: SUB_H, metadata: idx == 0 ? basicMetadata() : nil)
        }

        let source = FolderFrameSource(folder: subsDir, mode: .importOnce, fileNamePrefix: "Light_")
        let pipeline = SessionPipeline(
            nativeSource: source, engine: StackEngine(),
            profile: profile, rootDirectory: sessionsRoot,
            neutralizeBackground: false
        )
        try pipeline.start()
        _ = try pipeline.end()

        return (subsDir, sessionsRoot)
    }

    /// Builds a native session over identical (non-drifting) CFA subs.
    /// Coverage is uniform → CoverageCrop returns full-frame rect or nil → no crop.
    private func makeNoDriftSession() throws -> (URL, URL) {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let subsDir = sandbox.appendingPathComponent("subs")
        let sessionsRoot = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: subsDir, withIntermediateDirectories: true)

        var field: [(Double, Double)] = []
        for i in 0..<20 {
            field.append((Double((i * 47) % 240 + 8), Double((i * 83) % 240 + 8)))
        }

        let profile = SessionProfile(
            targetName: "NoDrift Test", telescope: "Test", camera: "Test",
            mount: "Test", filter: "L", locationLabel: "Lab", bortle: 5,
            subExposureSeconds: 60, notes: ""
        )

        // 4 identical subs (no offset) — coverage is uniform across the whole frame.
        for idx in 0..<4 {
            let name = String(format: "Light_%03d.fit", idx + 1)
            try writeCFASub(subsDir, name: name, stars: field, W: SUB_W, H: SUB_H, metadata: idx == 0 ? basicMetadata() : nil)
        }

        let source = FolderFrameSource(folder: subsDir, mode: .importOnce, fileNamePrefix: "Light_")
        let pipeline = SessionPipeline(
            nativeSource: source, engine: StackEngine(),
            profile: profile, rootDirectory: sessionsRoot,
            neutralizeBackground: false
        )
        try pipeline.start()
        _ = try pipeline.end()

        return (subsDir, sessionsRoot)
    }

    // MARK: - Sub / FITS Helpers

    private func basicMetadata() -> SourceMetadata {
        var m = SourceMetadata()
        m.object = "Test Object"
        return m
    }

    /// Writes a W×H RGGB CFA FITS sub with stars at `stars` positions.
    /// Mirrors CleanExportPipelineTests.writeGreenCFASub but uses a neutral
    /// background (no green pedestal) so balance assertions aren't needed here.
    private func writeCFASub(_ dir: URL, name: String,
                              stars: [(Double, Double)],
                              W: Int, H: Int,
                              metadata: SourceMetadata?) throws {
        var px = [Float](repeating: 0.05, count: W * H)
        // Inject bright Gaussian stars at all Bayer sites
        for s in stars {
            let sx = Int(s.0), sy = Int(s.1)
            for y in max(0, sy - 6)...min(H - 1, sy + 6) {
                for x in max(0, sx - 6)...min(W - 1, sx + 6) {
                    let dx = Double(x) - s.0, dy = Double(y) - s.1
                    px[y * W + x] += 0.9 * Float(exp(-(dx * dx + dy * dy) / (2 * 2.0 * 2.0)))
                }
            }
        }
        let data = makeCFAFITS(width: W, height: H, pixels: px,
                                metadata: metadata, bayerPattern: "RGGB")
        try data.write(to: dir.appendingPathComponent(name))
    }

    /// Minimal FITS writer with BAYERPAT keyword.
    /// Mirrors CleanExportPipelineTests.writeCFAFITS exactly.
    private func makeCFAFITS(width: Int, height: Int, pixels: [Float],
                              metadata: SourceMetadata?, bayerPattern: String) -> Data {
        func card(_ key: String, _ value: String) -> String {
            let k = key.padding(toLength: 8, withPad: " ", startingAt: 0)
            let valField = String(repeating: " ", count: max(0, 20 - value.count)) + value
            return "\(k)= \(valField)".padding(toLength: 80, withPad: " ", startingAt: 0)
        }
        func cardStr(_ key: String, _ value: String) -> String {
            let k = key.padding(toLength: 8, withPad: " ", startingAt: 0)
            let inner = value.count < 8
                ? value.padding(toLength: 8, withPad: " ", startingAt: 0)
                : String(value.prefix(68))
            return "\(k)= '\(inner)'".padding(toLength: 80, withPad: " ", startingAt: 0)
        }
        func trimDouble(_ d: Double) -> String {
            if d == d.rounded() && abs(d) < 1e15 { return String(Int(d)) }
            return String(d)
        }

        var cards = [
            card("SIMPLE", "T"),
            card("BITPIX", "-32"),
            card("NAXIS", "2"),
            card("NAXIS1", "\(width)"),
            card("NAXIS2", "\(height)"),
            cardStr("ROWORDER", "TOP-DOWN"),
            cardStr("BAYERPAT", bayerPattern)
        ]
        if let m = metadata {
            if let v = m.object      { cards.append(cardStr("OBJECT",   v)) }
            if let v = m.ra          { cards.append(card("RA",          trimDouble(v))) }
            if let v = m.dec         { cards.append(card("DEC",         trimDouble(v))) }
            if let v = m.instrument  { cards.append(cardStr("INSTRUME", v)) }
            if let v = m.telescope   { cards.append(cardStr("TELESCOP", v)) }
            if let v = m.filter      { cards.append(cardStr("FILTER",   v)) }
            if let v = m.exposureSeconds { cards.append(card("EXPTIME", trimDouble(v))) }
            if let v = m.dateObs     { cards.append(cardStr("DATE-OBS", v)) }
        }
        cards.append("END".padding(toLength: 80, withPad: " ", startingAt: 0))

        var s = cards.joined()
        let pad = (2880 - s.count % 2880) % 2880
        s += String(repeating: " ", count: pad)
        var data = s.data(using: .ascii)!

        let plane = width * height
        for i in 0..<plane {
            var be = pixels[i].bitPattern.bigEndian
            withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        }
        let dataPad = (2880 - data.count % 2880) % 2880
        data.append(Data(repeating: 0, count: dataPad))
        return data
    }

    /// Finds master.fit in the session directory tree under `sessionsRoot`.
    private func findMaster(in sessionsRoot: URL) throws -> URL {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: sessionsRoot,
                                              includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw NSError(domain: "CropToOverlapPipelineTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot enumerate \(sessionsRoot.path)"])
        }
        for case let url as URL in enumerator {
            if url.lastPathComponent == "master.fit" { return url }
        }
        throw NSError(domain: "CropToOverlapPipelineTests", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "master.fit not found under \(sessionsRoot.path)"])
    }
}
