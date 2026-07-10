import Foundation

/// Inclusive pixel bounds of a rectangular crop region.
public struct CropRect: Equatable {
    public let x0: Int, y0: Int, x1: Int, y1: Int
    public init(x0: Int, y0: Int, x1: Int, y1: Int) {
        self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1
    }
    public var width: Int { x1 - x0 + 1 }
    public var height: Int { y1 - y0 + 1 }
}

/// Computes the inscribed rectangle of the well-covered region of a coverage
/// (per-pixel frame-count) map. Robust to translation and field rotation:
/// trims whole rows/columns whose well-covered fraction is too low.
public enum CoverageCrop {
    public static func rect(coverage: [Float], width: Int, height: Int,
                            wellCoveredFraction: Float = 0.9,
                            edgeFloor: Float = 0.5) -> CropRect? {
        guard width > 0, height > 0, coverage.count == width * height else { return nil }
        var peak: Float = 0
        for v in coverage where v > peak { peak = v }
        guard peak > 0 else { return nil }
        let thresh = wellCoveredFraction * peak

        // per-row and per-column count of well-covered pixels
        var rowCount = [Int](repeating: 0, count: height)
        var colCount = [Int](repeating: 0, count: width)
        for y in 0..<height {
            let base = y * width
            for x in 0..<width where coverage[base + x] >= thresh {
                rowCount[y] += 1; colCount[x] += 1
            }
        }
        func trim(_ counts: [Int], _ span: Int) -> (Int, Int)? {
            var lo = 0, hi = counts.count - 1
            while lo <= hi && Float(counts[lo]) < edgeFloor * Float(span) { lo += 1 }
            while hi >= lo && Float(counts[hi]) < edgeFloor * Float(span) { hi -= 1 }
            return lo <= hi ? (lo, hi) : nil
        }
        // a row's "span" is width (max well-covered pixels it could have); col's is height
        guard let (y0, y1) = trim(rowCount, width),
              let (x0, x1) = trim(colCount, height) else { return nil }
        return CropRect(x0: x0, y0: y0, x1: x1, y1: y1)
    }
}
