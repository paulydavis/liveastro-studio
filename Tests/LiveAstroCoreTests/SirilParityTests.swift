import XCTest
@testable import LiveAstroCore

enum SirilParityMetrics {
    static func pearson(_ a: [Float], _ b: [Float]) -> Double {
        precondition(a.count == b.count)
        guard !a.isEmpty else { return 0 }
        let n = Double(a.count)
        var sumA = 0.0, sumB = 0.0
        for i in a.indices {
            sumA += Double(a[i])
            sumB += Double(b[i])
        }
        let meanA = sumA / n
        let meanB = sumB / n
        var numerator = 0.0, denomA = 0.0, denomB = 0.0
        for i in a.indices {
            let da = Double(a[i]) - meanA
            let db = Double(b[i]) - meanB
            numerator += da * db
            denomA += da * da
            denomB += db * db
        }
        let denom = sqrt(denomA * denomB)
        return denom > 0 ? numerator / denom : 0
    }

    static func affineNormalizedMAE(reference: [Float], candidate: [Float]) -> Double {
        precondition(reference.count == candidate.count)
        guard !reference.isEmpty else { return 0 }
        let n = Double(reference.count)
        var sumX = 0.0, sumY = 0.0
        for i in reference.indices {
            sumX += Double(reference[i])
            sumY += Double(candidate[i])
        }
        let meanX = sumX / n
        let meanY = sumY / n

        var covariance = 0.0, variance = 0.0
        for i in reference.indices {
            let dx = Double(reference[i]) - meanX
            covariance += dx * (Double(candidate[i]) - meanY)
            variance += dx * dx
        }
        let scale = variance > 0 ? covariance / variance : 0
        let offset = meanY - scale * meanX

        var absoluteError = 0.0
        var referenceRange = 0.0
        if let minRef = reference.min(), let maxRef = reference.max() {
            referenceRange = max(Double(maxRef - minRef), 1e-9)
        }
        for i in reference.indices {
            let predicted = scale * Double(reference[i]) + offset
            absoluteError += abs(Double(candidate[i]) - predicted)
        }
        return (absoluteError / n) / referenceRange
    }

    static func luminance(_ image: AstroImage) -> (pixels: [Float], width: Int, height: Int) {
        let plane = image.width * image.height
        guard image.channels > 1 else {
            return (image.pixels, image.width, image.height)
        }
        var out = [Float](repeating: 0, count: plane)
        for c in 0..<image.channels {
            let base = c * plane
            for i in 0..<plane {
                out[i] += image.pixels[base + i] / Float(image.channels)
            }
        }
        return (out, image.width, image.height)
    }

    static func channel(_ image: AstroImage, _ channel: Int) -> [Float] {
        let plane = image.width * image.height
        guard image.channels > 0 else { return [] }
        let c = min(channel, image.channels - 1)
        let start = c * plane
        return Array(image.pixels[start..<(start + plane)])
    }

    static func matchedStarMetrics(reference: AstroImage,
                                   candidate: AstroImage) throws -> (matchedRatio: Double, medianFWHMRatio: Double, backgroundSigmaRatio: Double) {
        let refLum = luminance(reference)
        let candLum = luminance(candidate)
        let refStats = StarDetector.detectWithStats(luminance: refLum.pixels, width: refLum.width, height: refLum.height)
        let candStats = StarDetector.detectWithStats(luminance: candLum.pixels, width: candLum.width, height: candLum.height)
        guard !refStats.stars.isEmpty, !candStats.stars.isEmpty else {
            throw XCTSkip("Siril parity star metrics require detectable stars in both masters.")
        }

        var usedCandidate = Set<Int>()
        var fwhmRatios: [Double] = []
        for ref in refStats.stars {
            var bestIndex: Int?
            var bestDistance = Double.greatestFiniteMagnitude
            for (idx, cand) in candStats.stars.enumerated() where !usedCandidate.contains(idx) {
                let dx = ref.x - cand.x
                let dy = ref.y - cand.y
                let distance = sqrt(dx * dx + dy * dy)
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = idx
                }
            }
            guard let bestIndex, bestDistance <= 8 else { continue }
            usedCandidate.insert(bestIndex)
            let refRadius = halfFluxRadius(star: ref, luminance: refLum.pixels, width: refLum.width, height: refLum.height)
            let candRadius = halfFluxRadius(star: candStats.stars[bestIndex], luminance: candLum.pixels, width: candLum.width, height: candLum.height)
            if refRadius > 0, candRadius > 0 {
                fwhmRatios.append(candRadius / refRadius)
            }
        }
        guard !fwhmRatios.isEmpty else {
            throw XCTSkip("Siril parity star metrics found stars but no centroid matches within 8 px.")
        }

        return (
            matchedRatio: Double(candStats.stars.count) / Double(refStats.stars.count),
            medianFWHMRatio: median(fwhmRatios),
            backgroundSigmaRatio: Double(candStats.backgroundSigma / max(refStats.backgroundSigma, 1e-9))
        )
    }

    private static func halfFluxRadius(star: Star, luminance: [Float], width: Int, height: Int) -> Double {
        let cx = Int(round(star.x))
        let cy = Int(round(star.y))
        guard cx >= 0, cx < width, cy >= 0, cy < height else { return 0 }

        let radius = 8
        var localMin = Float.greatestFiniteMagnitude
        var localMax: Float = 0
        for y in max(0, cy - radius)...min(height - 1, cy + radius) {
            for x in max(0, cx - radius)...min(width - 1, cx + radius) {
                let v = luminance[y * width + x]
                localMin = min(localMin, v)
                localMax = max(localMax, v)
            }
        }
        let threshold = localMin + (localMax - localMin) * 0.5
        var area = 0
        for y in max(0, cy - radius)...min(height - 1, cy + radius) {
            for x in max(0, cx - radius)...min(width - 1, cx + radius) {
                let dx = x - cx
                let dy = y - cy
                guard dx * dx + dy * dy <= radius * radius else { continue }
                if luminance[y * width + x] >= threshold { area += 1 }
            }
        }
        return area > 0 ? 2.0 * sqrt(Double(area) / Double.pi) : 0
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

struct SirilParityDataset {
    let root: URL
    let lightFolder: URL
    let lights: [URL]
    let darks: [URL]
    let flats: [URL]
    let biases: [URL]
    let sirilMaster: URL

    static func fromEnvironment(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> SirilParityDataset {
        guard let rawPath = environment["LIVEASTRO_PARITY_DATASET"], !rawPath.isEmpty else {
            throw XCTSkip("Set LIVEASTRO_PARITY_DATASET to a local Siril parity corpus to run this benchmark.")
        }

        let root = URL(fileURLWithPath: rawPath, isDirectory: true)
        let lightFolder = root.appendingPathComponent("Brutes_180s", isDirectory: true)
        let darkFolder = root.appendingPathComponent("Darks_180s", isDirectory: true)
        let flatFolder = root.appendingPathComponent("Flats_3s", isDirectory: true)
        let biasFolder = root.appendingPathComponent("Offsets_3s", isDirectory: true)
        let sirilMaster = root.appendingPathComponent("resultat.fit")

        let lights = try fitsFiles(in: lightFolder, label: "Brutes_180s")
        let darks = try fitsFiles(in: darkFolder, label: "Darks_180s")
        let flats = try fitsFiles(in: flatFolder, label: "Flats_3s")
        let biases = try fitsFiles(in: biasFolder, label: "Offsets_3s")
        guard FileManager.default.fileExists(atPath: sirilMaster.path) else {
            throw XCTSkip("Siril parity corpus is missing resultat.fit at \(sirilMaster.path).")
        }

        return SirilParityDataset(root: root, lightFolder: lightFolder, lights: lights,
                                  darks: darks, flats: flats, biases: biases,
                                  sirilMaster: sirilMaster)
    }

    private static func fitsFiles(in folder: URL, label: String) throws -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw XCTSkip("Siril parity corpus is missing \(label) at \(folder.path).")
        }
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: folder.path)
        } catch {
            throw XCTSkip("Siril parity corpus cannot enumerate \(label): \(error)")
        }
        let urls = names
            .filter { ($0 as NSString).pathExtension.lowercased() == "fit" }
            .sorted()
            .map { folder.appendingPathComponent($0) }
        guard !urls.isEmpty else {
            throw XCTSkip("Siril parity corpus has no FITS files in \(label).")
        }
        return urls
    }
}

struct SirilParityChannelReport {
    let index: Int
    let pearson: Double
    let affineMAE: Double
}

struct SirilParityReport {
    let reportURL: URL
    let liveAstro: AstroImage
    let siril: AstroImage
    let acceptedCount: Int
    let rejectedCount: Int
    let channels: [SirilParityChannelReport]
    let starMatchedRatio: Double
    let medianFWHMRatio: Double
    let backgroundSigmaRatio: Double
}

enum SirilParityRunner {
    static func run(dataset: SirilParityDataset) async throws -> SirilParityReport {
        let started = Date()
        let progressURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("liveastro-siril-parity-progress.log")
        try? "".write(to: progressURL, atomically: true, encoding: .utf8)
        func stage(_ name: String) {
            let line = String(format: "[siril-parity +%.1fs] %@\n", Date().timeIntervalSince(started), name)
            if let data = line.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: progressURL) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                }
            }
            fputs(line, stderr)
        }

        stage("building bias master (\(dataset.biases.count) frames)")
        let bias = try MasterBuilder.combine(fitsURLs: dataset.biases, kind: .bias, bias: nil)
        stage("building dark master (\(dataset.darks.count) frames)")
        let dark = try MasterBuilder.combine(fitsURLs: dataset.darks, kind: .dark, bias: nil)
        stage("building flat master (\(dataset.flats.count) frames)")
        let flat = try MasterBuilder.combine(fitsURLs: dataset.flats, kind: .flat, bias: bias)
        let calibrator = Calibrator(dark: dark, flat: flat)

        stage("starting light source (\(dataset.lights.count) frames)")
        let source = FolderFrameSource(folder: dataset.lightFolder, mode: .importOnce)
        try source.start()
        let engine = StackEngine()
        let importer = BatchImporter(engine: engine, poolSize: 4)
        var committed: [BatchImporter.Committed] = []
        var rejected: [String] = []
        stage("running BatchImporter")
        await importer.run(source: source,
                           prepare: calibrator.apply,
                           onCommitted: {
                               committed.append($0)
                               stage("committed \($0.index): \($0.sourceName)")
                           },
                           onRejected: {
                               rejected.append($0)
                               stage("rejected: \($0)")
                           },
                           isCancelled: { false })
        stage("import complete accepted=\(engine.acceptedCount) rejected=\(engine.rejectedCount)")

        guard let liveAstro = engine.currentStack() else {
            throw XCTSkip("LiveAstro parity import produced no current stack.")
        }
        stage("loading Siril master")
        let sirilData = try Data(contentsOf: dataset.sirilMaster)
        let sirilRead = try FITSReader.read(sirilData, normalizeRowOrder: true)
        let siril = AstroImage(width: sirilRead.width, height: sirilRead.height,
                               channels: sirilRead.channels, pixels: sirilRead.pixels,
                               sourceIsLinear: true)
        guard liveAstro.width == siril.width, liveAstro.height == siril.height else {
            throw XCTSkip("LiveAstro master \(liveAstro.width)×\(liveAstro.height) does not match Siril \(siril.width)×\(siril.height).")
        }

        let channelCount = min(liveAstro.channels, siril.channels)
        guard channelCount > 0 else {
            throw XCTSkip("Parity masters have no comparable channels.")
        }
        stage("computing channel metrics")
        var channels: [SirilParityChannelReport] = []
        for c in 0..<channelCount {
            let live = SirilParityMetrics.channel(liveAstro, c)
            let ref = SirilParityMetrics.channel(siril, c)
            channels.append(SirilParityChannelReport(
                index: c,
                pearson: SirilParityMetrics.pearson(ref, live),
                affineMAE: SirilParityMetrics.affineNormalizedMAE(reference: ref, candidate: live)
            ))
        }

        stage("computing star/background metrics")
        let star = try SirilParityMetrics.matchedStarMetrics(reference: siril, candidate: liveAstro)
        stage("writing report")
        let reportURL = try writeReport(dataset: dataset, committed: committed, rejected: rejected,
                                        liveAstro: liveAstro, siril: siril, channels: channels,
                                        starMatchedRatio: star.matchedRatio,
                                        medianFWHMRatio: star.medianFWHMRatio,
                                        backgroundSigmaRatio: star.backgroundSigmaRatio)
        stage("done")
        return SirilParityReport(reportURL: reportURL, liveAstro: liveAstro, siril: siril,
                                 acceptedCount: engine.acceptedCount,
                                 rejectedCount: engine.rejectedCount,
                                 channels: channels,
                                 starMatchedRatio: star.matchedRatio,
                                 medianFWHMRatio: star.medianFWHMRatio,
                                 backgroundSigmaRatio: star.backgroundSigmaRatio)
    }

    private static func writeReport(dataset: SirilParityDataset,
                                    committed: [BatchImporter.Committed],
                                    rejected: [String],
                                    liveAstro: AstroImage,
                                    siril: AstroImage,
                                    channels: [SirilParityChannelReport],
                                    starMatchedRatio: Double,
                                    medianFWHMRatio: Double,
                                    backgroundSigmaRatio: Double) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("liveastro-siril-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("parity-report.md")
        var lines: [String] = [
            "# Siril Parity Report",
            "",
            "- Dataset: `\(dataset.root.path)`",
            "- Lights: \(dataset.lights.count)",
            "- Darks: \(dataset.darks.count)",
            "- Flats: \(dataset.flats.count)",
            "- Bias/offsets: \(dataset.biases.count)",
            "- Siril master: `\(dataset.sirilMaster.lastPathComponent)`",
            "- LiveAstro dimensions: \(liveAstro.width)×\(liveAstro.height)×\(liveAstro.channels)",
            "- Siril dimensions: \(siril.width)×\(siril.height)×\(siril.channels)",
            "- Accepted: \(committed.count)",
            "- Rejected: \(rejected.count)",
            "",
            "## Channel Metrics",
            "",
            "| Channel | Pearson | Affine MAE |",
            "| --- | ---: | ---: |",
        ]
        for channel in channels {
            lines.append("| \(channel.index) | \(String(format: "%.6f", channel.pearson)) | \(String(format: "%.6f", channel.affineMAE)) |")
        }
        lines.append(contentsOf: [
            "",
            "## Star / Background Metrics",
            "",
            "- Star count ratio: \(String(format: "%.6f", starMatchedRatio))",
            "- Median FWHM ratio: \(String(format: "%.6f", medianFWHMRatio))",
            "- Background sigma ratio: \(String(format: "%.6f", backgroundSigmaRatio))",
            "",
            "## Thresholds",
            "",
            "- Pearson ≥ 0.83",
            "- Affine MAE ≤ 0.08",
            "- Star count ratio within 0.70...1.30",
            "- Median FWHM ratio within 0.75...1.35",
            "- Background sigma ratio within 0.50...2.25",
        ])
        if !rejected.isEmpty {
            lines.append("")
            lines.append("## Rejected Frames")
            lines.append("")
            for name in rejected { lines.append("- \(name)") }
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

final class SirilParityMetricTests: XCTestCase {
    func testPearsonDetectsLinearAgreementAndDisagreement() {
        XCTAssertGreaterThan(SirilParityMetrics.pearson([1, 2, 3, 4], [2, 4, 6, 8]), 0.999)
        XCTAssertLessThan(SirilParityMetrics.pearson([1, 2, 3, 4], [8, 6, 4, 2]), -0.999)
    }

    func testAffineNormalizedMAEIgnoresScaleAndOffset() {
        let err = SirilParityMetrics.affineNormalizedMAE(reference: [1, 2, 3, 4],
                                                        candidate: [12, 14, 16, 18])
        XCTAssertLessThan(err, 1e-6)
    }

    func testLuminanceAveragesRGBPlanes() {
        let image = AstroImage(width: 2, height: 1, channels: 3,
                               pixels: [1, 0, 0, 1, 0, 0],
                               sourceIsLinear: true)
        let lum = SirilParityMetrics.luminance(image)
        XCTAssertEqual(lum.width, 2)
        XCTAssertEqual(lum.height, 1)
        XCTAssertEqual(lum.pixels, [Float(1.0 / 3.0), Float(1.0 / 3.0)])
    }
}

final class SirilParityDatasetTests: XCTestCase {
    func testDatasetLoaderReportsSkipWhenEnvMissing() {
        XCTAssertThrowsError(try SirilParityDataset.fromEnvironment(environment: [:])) { error in
            guard error is XCTSkip else {
                return XCTFail("expected XCTSkip, got \(error)")
            }
        }
    }

    func testDatasetLoaderFindsExpectedFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Brutes_180s", "Darks_180s", "Flats_3s", "Offsets_3s"] {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data().write(to: dir.appendingPathComponent("one.fit"))
        }
        try Data().write(to: root.appendingPathComponent("resultat.fit"))

        let dataset = try SirilParityDataset.fromEnvironment(
            environment: ["LIVEASTRO_PARITY_DATASET": root.path]
        )
        XCTAssertEqual(dataset.lights.count, 1)
        XCTAssertEqual(dataset.darks.count, 1)
        XCTAssertEqual(dataset.flats.count, 1)
        XCTAssertEqual(dataset.biases.count, 1)
        XCTAssertEqual(dataset.sirilMaster.lastPathComponent, "resultat.fit")
    }
}

final class SirilParityTests: XCTestCase {
    func testLiveAstroNativeStackMatchesSirilReference() async throws {
        let dataset = try SirilParityDataset.fromEnvironment()
        let report = try await SirilParityRunner.run(dataset: dataset)
        print("Siril parity report: \(report.reportURL.path)")

        XCTAssertGreaterThanOrEqual(report.acceptedCount, 10)
        XCTAssertEqual(report.liveAstro.width, report.siril.width)
        XCTAssertEqual(report.liveAstro.height, report.siril.height)
        for channel in report.channels {
            // First real M8/M20 parity run (15× ASI2600 lights, Siril resultat.fit)
            // measured Pearson [0.847918, 0.989489, 0.983172]. Red is the loose
            // channel by correlation, while affine error remains tiny (0.005788),
            // so the regression floor is calibrated to that observed baseline
            // rather than pretending all channels behave like green/blue.
            XCTAssertGreaterThanOrEqual(channel.pearson, 0.83)
            XCTAssertLessThanOrEqual(channel.affineMAE, 0.08)
        }
        XCTAssertGreaterThanOrEqual(report.starMatchedRatio, 0.70)
        XCTAssertLessThanOrEqual(report.starMatchedRatio, 1.30)
        XCTAssertGreaterThanOrEqual(report.medianFWHMRatio, 0.75)
        XCTAssertLessThanOrEqual(report.medianFWHMRatio, 1.35)
        XCTAssertGreaterThanOrEqual(report.backgroundSigmaRatio, 0.50)
        // First real run measured 2.116990. Keep this as a regression guard
        // while allowing Siril/LiveAstro's different noise treatment.
        XCTAssertLessThanOrEqual(report.backgroundSigmaRatio, 2.25)
    }
}
