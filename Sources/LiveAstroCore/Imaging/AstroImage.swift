import Foundation

public struct ChannelStats: Codable, Equatable {
    public let mean: Double
    public let median: Double
    public let stddev: Double
    public init(mean: Double, median: Double, stddev: Double) {
        self.mean = mean; self.median = median; self.stddev = stddev
    }
}

public struct AstroImage {
    public let width: Int
    public let height: Int
    public let channels: Int
    /// Planar (channel-major), row-major top-down, 0…1.
    public let pixels: [Float]
    /// True for FITS (linear data needing autostretch); false for PNG/JPG/TIFF.
    public let sourceIsLinear: Bool
    public let stats: [ChannelStats]

    public init(width: Int, height: Int, channels: Int, pixels: [Float], sourceIsLinear: Bool) {
        precondition(pixels.count == width * height * channels)
        self.width = width; self.height = height; self.channels = channels
        self.pixels = pixels; self.sourceIsLinear = sourceIsLinear
        let plane = width * height
        self.stats = (0..<channels).map { c in
            Self.computeStats(pixels[(c * plane)..<((c + 1) * plane)])
        }
    }

    /// Stride that caps statistical samples at `maxSamples` (256K default) so stats
    /// stay O(1) on huge frames. Ceiling division: any count above the cap gets
    /// stride ≥ 2, keeping the sample count at or below the cap.
    static func sampleStride(count: Int, maxSamples: Int = 262_144) -> Int {
        max(1, (count + maxSamples - 1) / maxSamples)
    }

    /// Stats over a stride-sampled subset (≤ 262144 samples) — full sort of a 24MP plane is wasteful.
    static func computeStats(_ slice: ArraySlice<Float>) -> ChannelStats {
        let n = slice.count
        let stride = Self.sampleStride(count: n)
        var samples: [Float] = []
        samples.reserveCapacity(n / stride + 1)
        var i = slice.startIndex
        while i < slice.endIndex { samples.append(slice[i]); i += stride }
        let count = Double(samples.count)
        let mean = samples.reduce(0.0) { $0 + Double($1) } / count
        let variance = samples.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / count
        samples.sort()
        let mid = samples.count / 2
        let median = samples.count % 2 == 0
            ? (Double(samples[mid - 1]) + Double(samples[mid])) / 2
            : Double(samples[mid])
        return ChannelStats(mean: mean, median: median, stddev: variance.squareRoot())
    }
}
