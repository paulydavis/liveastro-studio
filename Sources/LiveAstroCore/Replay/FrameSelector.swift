import Foundation

/// Keyframe selection for the stack-evolution replay (spec §5.8).
/// Improvement is dramatic early and slow late, so sampling is logarithmic over index.
public enum FrameSelector {

    public static func logSpacedIndices(count: Int, maxKeyframes: Int) -> [Int] {
        guard count > 0 else { return [] }
        guard count > maxKeyframes else { return Array(0..<count) }
        var out: Set<Int> = [0, count - 1]
        for j in 0..<maxKeyframes {
            let f = Double(j) / Double(maxKeyframes - 1)
            let idx = Int((pow(Double(count), f) - 1).rounded())
            out.insert(min(max(idx, 0), count - 1))
        }
        return out.sorted()
    }

    /// Log spacing + near-duplicate removal. `difference(i, j)` returns 0 for identical frames.
    public static func select(count: Int, maxKeyframes: Int,
                              difference: (Int, Int) -> Double,
                              differenceThreshold: Double = 0.01) -> [Int] {
        let candidates = logSpacedIndices(count: count, maxKeyframes: maxKeyframes)
        guard candidates.count > 2 else { return candidates }
        var kept: [Int] = [candidates[0]]
        for idx in candidates.dropFirst() {
            let isLast = idx == candidates.last
            if isLast || difference(kept.last!, idx) >= differenceThreshold {
                kept.append(idx)
            }
        }
        return kept
    }

    /// Mean absolute difference of 64×64 block-averaged grayscale thumbnails.
    public static func thumbnailDifference(_ a: AstroImage, _ b: AstroImage) -> Double {
        let ta = grayThumbnail(a), tb = grayThumbnail(b)
        var sum = 0.0
        for i in 0..<ta.count { sum += abs(Double(ta[i]) - Double(tb[i])) }
        return sum / Double(ta.count)
    }

    /// Pipeline convenience: load snapshot PNGs, memoize thumbnails, select.
    public static func selectSnapshots(urls: [URL], maxKeyframes: Int = 45) throws -> [Int] {
        var thumbs: [Int: [Float]] = [:]
        func thumb(_ i: Int) throws -> [Float] {
            if let t = thumbs[i] { return t }
            let t = grayThumbnail(try ImageLoader.load(url: urls[i]))
            thumbs[i] = t
            return t
        }
        return select(count: urls.count, maxKeyframes: maxKeyframes) { i, j in
            guard let a = try? thumb(i), let b = try? thumb(j) else { return 1.0 }
            var sum = 0.0
            for k in 0..<a.count { sum += abs(Double(a[k]) - Double(b[k])) }
            return sum / Double(a.count)
        }
    }

    static func grayThumbnail(_ img: AstroImage, size: Int = 64) -> [Float] {
        let plane = img.width * img.height
        var out = [Float](repeating: 0, count: size * size)
        for ty in 0..<size {
            for tx in 0..<size {
                let x0 = tx * img.width / size, x1 = max(x0 + 1, (tx + 1) * img.width / size)
                let y0 = ty * img.height / size, y1 = max(y0 + 1, (ty + 1) * img.height / size)
                var acc: Float = 0; var n = 0
                for y in y0..<min(y1, img.height) {
                    for x in x0..<min(x1, img.width) {
                        var v: Float = 0
                        for c in 0..<img.channels { v += img.pixels[c * plane + y * img.width + x] }
                        acc += v / Float(img.channels); n += 1
                    }
                }
                out[ty * size + tx] = n > 0 ? acc / Float(n) : 0
            }
        }
        return out
    }
}
