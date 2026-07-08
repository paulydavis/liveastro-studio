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

    public func add(_ image: AstroImage, mask: [Float]) {
        precondition(image.width == width && image.height == height && image.channels == channels)
        let plane = width * height
        for i in 0..<plane {
            let m = mask[i]
            guard m > 0 else { continue }
            weight[i] += m
            for c in 0..<channels { sum[c * plane + i] += m * image.pixels[c * plane + i] }
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
}
