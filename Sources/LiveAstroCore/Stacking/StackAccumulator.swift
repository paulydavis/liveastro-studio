import Foundation

/// Weighted incremental mean stack (spec §3): per-pixel Float32 sum + weight.
public final class StackAccumulator {
    private var sum: [Float]
    private var weight: [Float]        // Σ (frameWeight·mask) — denominator of the weighted mean
    private var coverageSum: [Float]   // Σ mask — geometric frame count, independent of weighting
    private let width: Int, height: Int, channels: Int
    public private(set) var frameCount = 0

    public init(width: Int, height: Int, channels: Int) {
        self.width = width; self.height = height; self.channels = channels
        sum = [Float](repeating: 0, count: width * height * channels)
        weight = [Float](repeating: 0, count: width * height)
        coverageSum = [Float](repeating: 0, count: width * height)
    }

    public func add(_ image: AstroImage, mask: [Float], frameWeight: Float = 1.0, minRows: Int = 64) {
        precondition(image.width == width && image.height == height && image.channels == channels)
        let plane = width * height
        let w = width, chans = channels
        image.pixels.withUnsafeBufferPointer { src in
            mask.withUnsafeBufferPointer { m in
                sum.withUnsafeMutableBufferPointer { sumBuf in
                    weight.withUnsafeMutableBufferPointer { wBuf in
                        coverageSum.withUnsafeMutableBufferPointer { covBuf in
                            Parallel.rows(height, minRows: minRows) { rows in
                                for y in rows {
                                    for x in 0..<w {
                                        let i = y * w + x
                                        let m0 = m[i]
                                        let mv = frameWeight * m0
                                        guard mv > 0 else { continue }
                                        wBuf[i] += mv
                                        covBuf[i] += m0   // geometric coverage: weight-independent
                                        for c in 0..<chans { sumBuf[c * plane + i] += mv * src[c * plane + i] }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        frameCount += 1
    }

    public func mean() -> AstroImage {
        let plane = width * height
        var out = [Float](repeating: 0, count: sum.count)
        for i in 0..<plane where weight[i] > 0 {
            for c in 0..<channels { out[c * plane + i] = sum[c * plane + i] / weight[i] }
        }
        return AstroImage(width: width, height: height, channels: channels,
                          pixels: out, sourceIsLinear: true)
    }

    /// Read-only per-pixel geometric coverage: the sum of raw mask values,
    /// independent of quality weighting. With binary Warp masks this is the
    /// number of frames covering each pixel — the value CoverageCrop needs so a
    /// low-weight-but-fully-covered region is not trimmed. Returns a copy;
    /// callers cannot mutate accumulator state.
    public func coverage() -> [Float] { coverageSum }
}
