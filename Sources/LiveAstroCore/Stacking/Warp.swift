import Foundation

/// Inverse-mapped bilinear warp with a binary source-in-bounds mask (spec §4.2).
/// mask[i] is 1 where every bilinear tap lands inside the source, 0 otherwise;
/// the ~1 px partially-covered rim is deliberately dropped rather than given
/// fractional weight — conservative edges beat partially-sampled ones. The mask
/// lets the accumulator skip uncovered pixels instead of averaging in zeros.
public enum Warp {
    public static func apply(_ image: AstroImage,
                             transform: SimilarityTransform) -> (image: AstroImage, mask: [Float]) {
        let w = image.width, h = image.height, plane = w * h
        let inv = transform.inverse()
        var out = [Float](repeating: 0, count: image.pixels.count)
        var mask = [Float](repeating: 0, count: plane)
        image.pixels.withUnsafeBufferPointer { src in
            for y in 0..<h {
                for x in 0..<w {
                    let p = inv.apply(x: Double(x), y: Double(y))
                    let x0 = Int(floor(p.x)), y0 = Int(floor(p.y))
                    guard x0 >= 0, y0 >= 0, x0 < w - 1 || (x0 == w - 1 && p.x == Double(w - 1)),
                          y0 < h - 1 || (y0 == h - 1 && p.y == Double(h - 1)) else { continue }
                    let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
                    let tx = Float(p.x - Double(x0)), ty = Float(p.y - Double(y0))
                    let w00 = (1 - tx) * (1 - ty), w01 = tx * (1 - ty)
                    let w10 = (1 - tx) * ty, w11 = tx * ty
                    for c in 0..<image.channels {
                        let base = c * plane
                        out[base + y * w + x] =
                            w00 * src[base + y0 * w + x0] + w01 * src[base + y0 * w + x1] +
                            w10 * src[base + y1 * w + x0] + w11 * src[base + y1 * w + x1]
                    }
                    mask[y * w + x] = 1
                }
            }
        }
        let img = AstroImage(width: w, height: h, channels: image.channels,
                             pixels: out, sourceIsLinear: image.sourceIsLinear)
        return (img, mask)
    }
}
