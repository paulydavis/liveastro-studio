import Foundation

/// Weighted incremental mean stack (spec §3): per-pixel Float32 sum + weight.
public final class StackAccumulator {
    private var sum: [Float]
    private var weight: [Float]
    private let width: Int, height: Int, channels: Int
    public private(set) var frameCount = 0

    public init(width: Int, height: Int, channels: Int) {
        self.width = width; self.height = height; self.channels = channels
        sum = [Float](repeating: 0, count: width * height * channels)
        weight = [Float](repeating: 0, count: width * height)
    }

    public func add(_ image: AstroImage, mask: [Float], minRows: Int = 64) {
        precondition(image.width == width && image.height == height && image.channels == channels)
        let plane = width * height
        let w = width, chans = channels
        image.pixels.withUnsafeBufferPointer { src in
            mask.withUnsafeBufferPointer { m in
                sum.withUnsafeMutableBufferPointer { sumBuf in
                    weight.withUnsafeMutableBufferPointer { wBuf in
                        Parallel.rows(height, minRows: minRows) { rows in
                            for y in rows {
                                for x in 0..<w {
                                    let i = y * w + x
                                    let mv = m[i]
                                    guard mv > 0 else { continue }
                                    wBuf[i] += mv
                                    for c in 0..<chans { sumBuf[c * plane + i] += mv * src[c * plane + i] }
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

    /// Read-only per-pixel coverage (sum of applied mask values). With binary
    /// Warp masks this is the number of frames covering each pixel. Returns a
    /// copy; callers cannot mutate accumulator state.
    public func coverage() -> [Float] { weight }
}
