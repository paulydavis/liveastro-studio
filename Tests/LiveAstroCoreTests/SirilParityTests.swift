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
