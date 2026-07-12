import Foundation

public enum BayerPattern: String {
    case grbg = "GRBG"
    case rggb = "RGGB"
    case bggr = "BGGR"
    case gbrg = "GBRG"

    public init?(headerValue: String?) {
        guard let v = headerValue?.trimmingCharacters(in: .whitespaces).uppercased(),
              let p = BayerPattern(rawValue: v) else { return nil }
        self = p
    }

    /// Channel at CFA site (row % 2, col % 2): 0 = R, 1 = G, 2 = B.
    func channel(row: Int, col: Int) -> Int {
        switch self {
        case .grbg: return (row % 2 == 0) ? (col % 2 == 0 ? 1 : 0) : (col % 2 == 0 ? 2 : 1)
        case .rggb: return (row % 2 == 0) ? (col % 2 == 0 ? 0 : 1) : (col % 2 == 0 ? 1 : 2)
        case .bggr: return (row % 2 == 0) ? (col % 2 == 0 ? 2 : 1) : (col % 2 == 0 ? 1 : 0)
        case .gbrg: return (row % 2 == 0) ? (col % 2 == 0 ? 1 : 2) : (col % 2 == 0 ? 0 : 1)
        }
    }
}

/// Full-resolution bilinear demosaic (spec §3): mask-normalized 3×3 convolution,
/// exact at image edges because the kernel weight renormalizes with the mask.
public enum Debayer {
    public static func bilinear(cfa: AstroImage, pattern: BayerPattern,
                                minRows: Int = 64) -> AstroImage {
        precondition(cfa.channels == 1, "CFA input must be single-channel")
        let w = cfa.width, h = cfa.height, plane = w * h
        // K weights by (dy+1, dx+1); G kernel is the cross, R/B the full 3×3.
        let kG: [Float] = [0, 1, 0, 1, 4, 1, 0, 1, 0]
        let kRB: [Float] = [1, 2, 1, 2, 4, 2, 1, 2, 1]
        var out = [Float](repeating: 0, count: plane * 3)
        cfa.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { outBuf in
                Parallel.rows(h, minRows: minRows) { rows in
                    for y in rows {
                        for x in 0..<w {
                            for c in 0..<3 {
                                let k = c == 1 ? kG : kRB
                                var num: Float = 0, den: Float = 0
                                for dy in -1...1 {
                                    let yy = y + dy
                                    guard yy >= 0, yy < h else { continue }
                                    for dx in -1...1 {
                                        let xx = x + dx
                                        guard xx >= 0, xx < w else { continue }
                                        guard pattern.channel(row: yy, col: xx) == c else { continue }
                                        let kw = k[(dy + 1) * 3 + (dx + 1)]
                                        num += kw * src[yy * w + xx]
                                        den += kw
                                    }
                                }
                                outBuf[c * plane + y * w + x] = den > 0 ? num / den : 0
                            }
                        }
                    }
                }
            }
        }
        return AstroImage(width: w, height: h, channels: 3, pixels: out,
                          sourceIsLinear: cfa.sourceIsLinear)
    }
}
