import Foundation

/// Demosaic algorithm selection.
public enum DemosaicMethod: String, Codable, CaseIterable {
    /// Classic bilinear interpolation — fast, byte-identical to the engine's legacy
    /// behaviour. Default for `StackEngine` so all existing tests remain unaffected.
    case bilinear
    /// Malvar–He–Cutler gradient-corrected linear interpolation (ICASSP 2004) — high
    /// quality, a large step above bilinear. Default in the app via `AppModel`.
    case malvar

    /// Back-compat decode: settings persisted before the clean-room migration stored
    /// the old `"rcd"` raw value. Map it to `.malvar` (the replacement high-quality
    /// method) rather than throwing, so upgrading never wipes a saved config.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "rcd":
            self = .malvar
        default:
            guard let v = DemosaicMethod(rawValue: raw) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown DemosaicMethod raw value \"\(raw)\""))
            }
            self = v
        }
    }
}

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

    // MARK: - Malvar–He–Cutler (gradient-corrected linear interpolation)

    /// High-quality demosaic (Malvar, He & Cutler, ICASSP 2004): bilinear interpolation
    /// of each missing channel plus a gradient correction from the Laplacian of a known
    /// channel, realised as one 5×5 convolution of the raw CFA with the appropriate
    /// published mask. Five masks cover every missing-value case; all four Bayer patterns
    /// share the same site-parity scheme as `bilinear`. A 2-pixel border (where the 5×5
    /// window leaves the image), and any image with fewer than `minRows` rows, delegate to
    /// `bilinear`. Output is clamped to [0, 1] and sanitised so non-finite values never
    /// propagate. Deterministic: each output row is written by exactly one worker band.
    public static func malvar(cfa: AstroImage, pattern: BayerPattern,
                              minRows: Int = 64) -> AstroImage {
        precondition(cfa.channels == 1, "CFA input must be single-channel")
        let w = cfa.width, h = cfa.height, plane = w * h
        // Base result also fills the 2px border and is the small-image passthrough.
        let base = bilinear(cfa: cfa, pattern: pattern, minRows: minRows)
        guard h >= minRows else { return base }

        // Published 5×5 masks (row-major), each summing to its divisor (unity gain).
        // Green at a red or blue site (÷8).
        let mG: [Float] = [
             0,  0, -1,  0,  0,
             0,  0,  2,  0,  0,
            -1,  2,  4,  2, -1,
             0,  0,  2,  0,  0,
             0,  0, -1,  0,  0]
        // Missing colour whose like-coloured neighbours lie along the ROW (÷16).
        let mRow: [Float] = [
             0,  0,  1,  0,  0,
             0, -2,  0, -2,  0,
            -2,  8, 10,  8, -2,
             0, -2,  0, -2,  0,
             0,  0,  1,  0,  0]
        // Missing colour whose like-coloured neighbours lie along the COLUMN — the
        // transpose of mRow (÷16).
        let mCol: [Float] = [
             0,  0, -2,  0,  0,
             0, -2,  8, -2,  0,
             1,  0, 10,  0,  1,
             0, -2,  8, -2,  0,
             0,  0, -2,  0,  0]
        // Red at a blue site, and symmetrically blue at a red site (÷16).
        let mDiag: [Float] = [
             0,  0, -3,  0,  0,
             0,  4,  0,  4,  0,
            -3,  0, 12,  0, -3,
             0,  4,  0,  4,  0,
             0,  0, -3,  0,  0]

        var out = base.pixels
        cfa.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { o in
                // One 5×5 convolution of the raw CFA at (y, x), divided by `div`.
                // Caller guarantees 2 ≤ x < w-2 and 2 ≤ y < h-2, so the window is in bounds.
                func conv(_ y: Int, _ x: Int, _ m: [Float], _ div: Float) -> Float {
                    var s: Float = 0
                    var i = 0
                    for dy in -2...2 {
                        let row = (y + dy) * w + x
                        for dx in -2...2 {
                            s += m[i] * src[row + dx]
                            i += 1
                        }
                    }
                    return s / div
                }
                Parallel.rows(h, minRows: minRows) { rows in
                    for y in rows {
                        guard y >= 2, y < h - 2 else { continue }  // 2px border → bilinear
                        for x in 2..<(w - 2) {
                            let c0 = pattern.channel(row: y, col: x)  // 0=R 1=G 2=B
                            let known = src[y * w + x]
                            let r: Float, g: Float, b: Float
                            switch c0 {
                            case 1:  // Green site: one neighbour colour along the row, the other along the column.
                                let colH = pattern.channel(row: y, col: x + 1)  // 0=R or 2=B
                                g = known
                                let estRow = conv(y, x, mRow, 16)   // colour along the row
                                let estCol = conv(y, x, mCol, 16)   // colour along the column
                                if colH == 0 { r = estRow; b = estCol } else { r = estCol; b = estRow }
                            case 0:  // Red site.
                                r = known
                                g = conv(y, x, mG, 8)
                                b = conv(y, x, mDiag, 16)
                            default: // Blue site (c0 == 2).
                                b = known
                                g = conv(y, x, mG, 8)
                                r = conv(y, x, mDiag, 16)
                            }
                            o[0 * plane + y * w + x] = r
                            o[1 * plane + y * w + x] = g
                            o[2 * plane + y * w + x] = b
                        }
                    }
                }
                // Sanitise every element: clamp to [0, 1], non-finite → 0. Covers the
                // bilinear border too, so NaN/Inf inputs never leak into the output.
                for k in 0..<o.count {
                    let v = o[k]
                    o[k] = v.isFinite ? min(max(v, 0), 1) : 0
                }
            }
        }
        return AstroImage(width: w, height: h, channels: 3, pixels: out,
                          sourceIsLinear: cfa.sourceIsLinear)
    }
}
