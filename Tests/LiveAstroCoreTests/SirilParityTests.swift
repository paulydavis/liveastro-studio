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
