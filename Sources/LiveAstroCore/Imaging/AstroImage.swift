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

    /// Stats over a stride-sampled subset (≤ 262144 samples) — full sort of a 24MP plane is wasteful.
    static func computeStats(_ slice: ArraySlice<Float>) -> ChannelStats {
        let n = slice.count
        let stride = max(1, n / 262_144)
        var samples: [Float] = []
        samples.reserveCapacity(n / stride + 1)
        var i = slice.startIndex
        while i < slice.endIndex { samples.append(slice[i]); i += stride }
        let count = Double(samples.count)
        let mean = samples.reduce(0.0) { $0 + Double($1) } / count
        let variance = samples.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / count
        samples.sort()
        let median = Double(samples[samples.count / 2])
        return ChannelStats(mean: mean, median: median, stddev: variance.squareRoot())
    }
}
