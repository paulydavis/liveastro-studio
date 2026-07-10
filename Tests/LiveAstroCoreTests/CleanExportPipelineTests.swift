import XCTest
@testable import LiveAstroCore

/// End-to-end tests for Task 5: SessionPipeline captures first-frame SourceMetadata
/// and applies additive-only background neutralization to master.fit.
final class CleanExportPipelineTests: XCTestCase {

    // MARK: - Tests

    func testMasterHasMetadataAndIsBalancedWhenNeutralizeOn() throws {
        let (subsDir, sessionRoot) = try makeGreenSession(neutralize: true)
        defer {
            try? FileManager.default.removeItem(at: subsDir.deletingLastPathComponent())
        }
        let masterURL = try findMaster(in: sessionRoot)
        let masterData = try Data(contentsOf: masterURL)
        let hdr = try FITSReader.readHeader(masterData)
        // Metadata propagated from first sub
        XCTAssertEqual(
            hdr.keywords["OBJECT"]?.trimmingCharacters(in: .whitespaces),
            "NGC 6960",
            "OBJECT keyword should be propagated from first sub's metadata"
        )
        XCTAssertNotNil(hdr.keywords["RA"], "RA keyword should be propagated")
        XCTAssertNotNil(hdr.keywords["STACKCNT"], "STACKCNT keyword should be written")
        // Green pedestal removed: per-channel background medians within tolerance
        let img = try FITSReader.read(masterData)
        let bg = channelBackgroundMedians(img)
        XCTAssertLessThan(abs(bg[1] - bg[0]), 0.01,
            "After additive BN, G≈R (got G=\(bg[1]), R=\(bg[0]))")
        XCTAssertLessThan(abs(bg[1] - bg[2]), 0.01,
            "After additive BN, G≈B (got G=\(bg[1]), B=\(bg[2]))")
    }

    func testMasterRawWhenNeutralizeOff() throws {
        let (subsDir, sessionRoot) = try makeGreenSession(neutralize: false)
        defer {
            try? FileManager.default.removeItem(at: subsDir.deletingLastPathComponent())
        }
        let masterURL = try findMaster(in: sessionRoot)
        let img = try FITSReader.read(Data(contentsOf: masterURL))
        let bg = channelBackgroundMedians(img)
        XCTAssertGreaterThan(bg[1] - bg[0], 0.02,
            "Without BN, green pedestal should still be present (got G=\(bg[1]), R=\(bg[0]))")
    }

    // MARK: - Helpers

    /// Builds ≥3 synthetic CFA subs with a green background pedestal + shared stars,
    /// with NGC 6960 metadata embedded in the FITS header, then runs a native pipeline
    /// session to completion. Returns (subsDir, sessionRoot).
    ///
    /// The subs use BAYERPAT=RGGB so the StackEngine debayers them. The green Bayer
    /// sites have a higher background (0.15) than R and B sites (0.05), creating a
    /// green pedestal in the debayered master.
    private func makeGreenSession(neutralize: Bool) throws -> (URL, URL) {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let subsDir = sandbox.appendingPathComponent("subs")
        let sessionsRoot = sandbox.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: subsDir, withIntermediateDirectories: true)

        // 20 stars at reproducible positions (same pattern as NativePipelineTests)
        var field: [(Double, Double)] = []
        for i in 0..<20 {
            field.append((Double((i * 47) % 240 + 8), Double((i * 83) % 240 + 8)))
        }

        // NGC 6960 metadata to be embedded in the subs
        var meta = SourceMetadata()
        meta.object = "NGC 6960"
        meta.ra = 312.75
        meta.dec = 30.72
        meta.instrument = "ZWO ASI2600MC"
        meta.telescope = "Askar 120"
        meta.filter = "L"
        meta.exposureSeconds = 300.0
        meta.dateObs = "2024-08-15T21:00:00"

        // Write 3 subs: first at nominal position, others with small offsets
        let offsets: [(Double, Double)] = [(0, 0), (2.4, -1.1), (-1.2, 0.8)]
        for (idx, offset) in offsets.enumerated() {
            let shifted = field.map { ($0.0 + offset.0, $0.1 + offset.1) }
            let name = "Light_00\(idx + 1).fit"
            // Only embed metadata in first sub; others get none (tests first-frame capture)
            let subMeta = idx == 0 ? meta : nil
            try writeGreenCFASub(subsDir, name: name, stars: shifted, metadata: subMeta)
        }

        let profile = SessionProfile(
            targetName: "NGC 6960", telescope: "Askar 120", camera: "ZWO ASI2600MC",
            mount: "ZWO AM5N", filter: "L", locationLabel: "Backyard", bortle: 5,
            subExposureSeconds: 300, notes: ""
        )
        let source = FolderFrameSource(folder: subsDir, mode: .importOnce, fileNamePrefix: "Light_")
        let pipeline = SessionPipeline(
            nativeSource: source, engine: StackEngine(),
            profile: profile, rootDirectory: sessionsRoot,
            neutralizeBackground: neutralize
        )
        try pipeline.start()
        _ = try pipeline.end()

        return (subsDir, sessionsRoot)
    }

    /// Writes a 256×256 RGGB CFA FITS sub where green Bayer sites have a background
    /// of 0.15 (vs. 0.05 for R and B), creating a detectable green pedestal after debayer.
    /// Stars are injected as bright point sources at all Bayer sites.
    private func writeGreenCFASub(_ dir: URL, name: String,
                                   stars: [(Double, Double)],
                                   metadata: SourceMetadata?) throws {
        let W = 256, H = 256
        // Per-Bayer-site background: RGGB pattern
        //   row%2==0, col%2==0 → R → 0.05
        //   row%2==0, col%2==1 → G → 0.15
        //   row%2==1, col%2==0 → G → 0.15
        //   row%2==1, col%2==1 → B → 0.05
        var px = [Float](repeating: 0, count: W * H)
        for y in 0..<H {
            for x in 0..<W {
                let isGreen = (y % 2 == 0 && x % 2 == 1) || (y % 2 == 1 && x % 2 == 0)
                px[y * W + x] = isGreen ? 0.15 : 0.05
            }
        }
        // Inject stars: bright Gaussian at all Bayer sites
        for s in stars {
            for y in max(0, Int(s.1) - 6)...min(H - 1, Int(s.1) + 6) {
                for x in max(0, Int(s.0) - 6)...min(W - 1, Int(s.0) + 6) {
                    let dx = Double(x) - s.0, dy = Double(y) - s.1
                    px[y * W + x] += 0.8 * Float(exp(-(dx * dx + dy * dy) / (2 * 2.0 * 2.0)))
                }
            }
        }
        // Write with BAYERPAT=RGGB so FolderFrameSource decodes a bayerPattern
        // and StackEngine debayers it into RGB channels.
        var data = FITSWriter.float32(
            width: W, height: H, channels: 1, pixels: px,
            metadata: metadata
        )
        // Insert BAYERPAT card into header: FITSWriter doesn't expose bayerPattern,
        // so we append it by prepending to the first block before END.
        // Instead, write via the helper that includes bayerPattern.
        _ = data  // suppress warning; overwrite below
        data = writeCFAFITS(width: W, height: H, pixels: px, metadata: metadata,
                            bayerPattern: "RGGB")
        try data.write(to: dir.appendingPathComponent(name))
    }

    /// Minimal FITS writer that includes a BAYERPAT keyword in the header.
    private func writeCFAFITS(width: Int, height: Int, pixels: [Float],
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
            if let v = m.focalLengthMM { cards.append(card("FOCALLEN", trimDouble(v))) }
            if let v = m.pixelSizeUM { cards.append(card("XPIXSZ",     trimDouble(v))) }
            if let v = m.instrument  { cards.append(cardStr("INSTRUME", v)) }
            if let v = m.telescope   { cards.append(cardStr("TELESCOP", v)) }
            if let v = m.filter      { cards.append(cardStr("FILTER",   v)) }
            if let v = m.exposureSeconds { cards.append(card("EXPTIME", trimDouble(v))) }
            if let v = m.dateObs     { cards.append(cardStr("DATE-OBS", v)) }
            if let v = m.gain        { cards.append(card("GAIN",        trimDouble(v))) }
            if let v = m.ccdTempC   { cards.append(card("CCD-TEMP",    trimDouble(v))) }
            if let v = m.siteLat    { cards.append(card("SITELAT",     trimDouble(v))) }
            if let v = m.siteLon    { cards.append(card("SITELONG",    trimDouble(v))) }
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
            throw NSError(domain: "CleanExportPipelineTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot enumerate \(sessionsRoot.path)"])
        }
        for case let url as URL in enumerator {
            if url.lastPathComponent == "master.fit" { return url }
        }
        throw NSError(domain: "CleanExportPipelineTests", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "master.fit not found under \(sessionsRoot.path)"])
    }

    /// Returns the background (20th-percentile) per-channel median for the image.
    /// Uses a simple sort + index approach on each channel plane.
    private func channelBackgroundMedians(_ image: FITSImage) -> [Double] {
        let plane = image.width * image.height
        return (0..<image.channels).map { c in
            var vals = Array(image.pixels[(c * plane)..<((c + 1) * plane)])
            vals.sort()
            // 20th-percentile approximates sky background (bright stars/nebula won't skew it).
            let idx = max(0, Int(Double(vals.count - 1) * 0.20))
            return Double(vals[idx])
        }
    }
}
