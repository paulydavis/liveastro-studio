import Foundation

/// Online winsorized κ-σ rejection. Per pixel·channel it keeps running Welford
/// stats (count, mean, M2) and, after a per-pixel warm-up, clamps each incoming
/// value to ±kσ of the running mean. Memory is O(image), O(1) in frame count.
public final class WinsorizedSigmaClip: RejectionMethod {
    private let kappa: Float
    private let warmUp: Float
    private var count: [Float] = []
    private var mean: [Float] = []
    private var m2: [Float] = []

    public init(kappa: Float = 3.0, warmUp: Int = 8) {
        self.kappa = kappa
        self.warmUp = Float(warmUp)
    }

    public func reset() { count = []; mean = []; m2 = [] }

    public func apply(_ frame: AstroImage, mask: [Float]) -> AstroImage {
        let plane = frame.width * frame.height
        let n = frame.pixels.count
        if count.count != n {                 // lazy alloc / dimension change
            count = [Float](repeating: 0, count: n)
            mean  = [Float](repeating: 0, count: n)
            m2    = [Float](repeating: 0, count: n)
        }
        var out = frame.pixels
        for c in 0..<frame.channels {
            let base = c * plane
            for i in 0..<plane where mask[i] > 0 {
                let idx = base + i
                var v = frame.pixels[idx]
                if count[idx] >= warmUp {                         // clip only after warm-up
                    let sigma = (m2[idx] / count[idx]).squareRoot()
                    let lo = mean[idx] - kappa * sigma
                    let hi = mean[idx] + kappa * sigma
                    if v < lo { v = lo } else if v > hi { v = hi }
                    out[idx] = v
                }
                // Welford update with v (raw during warm-up, clamped after)
                count[idx] += 1
                let d = v - mean[idx]
                mean[idx] += d / count[idx]
                m2[idx] += d * (v - mean[idx])
            }
        }
        return AstroImage(width: frame.width, height: frame.height,
                          channels: frame.channels, pixels: out,
                          sourceIsLinear: frame.sourceIsLinear)
    }
}
