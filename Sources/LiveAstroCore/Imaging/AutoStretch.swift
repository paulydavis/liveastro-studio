import Foundation
import CoreGraphics

/// Midtone-transfer-function autostretch (PixInsight STF / Siril autostretch family).
/// Linear FITS displayed raw is a black rectangle; this makes it look like Siril's preview.
public enum AutoStretch {

    /// MTF(x, m) — midtones transfer function with midtones balance m.
    public static func mtf(_ x: Double, _ m: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        return ((m - 1) * x) / (((2 * m - 1) * x) - m)
    }

    /// Linked autostretch: statistics from the mean-of-channels sample, one transform for all channels.
    public static func stretch(_ image: AstroImage,
                               targetBackground: Double = 0.25,
                               shadowsClipping: Double = -2.8,
                               blackPoint: Double = 0,
                               midtoneStrength: Double = 0) -> AstroImage {
        // Black-point: gentle shadow clip on the LINEAR data. bp==0 → identity.
        let bp = min(max(blackPoint, 0), 0.2)
        let work: [Float]
        if bp > 0 {
            let inv = 1.0 - bp
            work = image.pixels.map { Float(max(0, (Double($0) - bp) / inv)) }
        } else {
            work = image.pixels
        }

        let plane = image.width * image.height
        // A zero-pixel image has no samples: median indexing below would trap. Nothing
        // to stretch — return it unchanged (mirrors the AstroImage.computeStats guard).
        guard plane > 0 else { return image }
        // Combined luminance sample (mean across channels), stride-sampled.
        let stride = AstroImage.sampleStride(count: plane)
        var sample: [Float] = []
        sample.reserveCapacity(plane / stride + 1)
        var i = 0
        while i < plane {
            var s: Float = 0
            for c in 0..<image.channels { s += work[c * plane + i] }
            sample.append(s / Float(image.channels))
            i += stride
        }
        sample.sort()
        let median = Double(sample[sample.count / 2])
        var deviations = sample.map { abs(Double($0) - median) }
        deviations.sort()
        // 1.4826 = 1 / Φ⁻¹(0.75): MAD→σ consistency factor for Gaussian data
        let madn_raw = 1.4826 * deviations[deviations.count / 2]
        // When all samples are nearly identical (madn ≈ 0), use median as fallback to preserve channel ratios
        let madn = madn_raw > 1e-10 ? madn_raw : max(median, 1e-10)

        let shadow = min(max(median + shadowsClipping * madn, 0), 1)
        let denom = max(1 - shadow, 1e-9)
        let r = min(max((median - shadow) / denom, 1e-9), 1)
        let strengthFactor = pow(2.0, -min(max(midtoneStrength, -1), 1))
        let baseMidtone = mtf(r, targetBackground)
        // strengthFactor==1 (neutral) must reproduce today's UNclamped midtone exactly,
        // preserving byte-identity for all inputs. Clamp only when strength is engaged
        // (protects mtf from a degenerate midtone near 0/1 on the strength≠0 path).
        let midtone = strengthFactor == 1.0
            ? baseMidtone
            : min(max(baseMidtone * strengthFactor, 1e-4), 1 - 1e-4)

        var out = [Float](repeating: 0, count: image.pixels.count)
        for idx in 0..<image.pixels.count {
            let x = (Double(work[idx]) - shadow) / denom
            out[idx] = Float(mtf(min(max(x, 0), 1), midtone))
        }
        return AstroImage(width: image.width, height: image.height, channels: image.channels,
                          pixels: out, sourceIsLinear: false)
    }

    /// Luminance-preserving saturation on stretched, display-space [0,1] RGB.
    /// factor 1 → identity, 0 → greyscale (each channel = luminance), 2 → doubled
    /// chroma around luminance. Mono (channels != 3) is returned unchanged.
    public static func applySaturation(_ image: AstroImage, _ factor: Double) -> AstroImage {
        guard image.channels == 3 else { return image }
        let f = min(max(factor, 0), 2)
        if f == 1 { return image }
        let plane = image.width * image.height
        var out = image.pixels
        for i in 0..<plane {
            let r = Double(image.pixels[i])
            let g = Double(image.pixels[plane + i])
            let b = Double(image.pixels[2 * plane + i])
            let L = 0.2126 * r + 0.7152 * g + 0.0722 * b
            out[i]             = Float(min(max(L + f * (r - L), 0), 1))
            out[plane + i]     = Float(min(max(L + f * (g - L), 0), 1))
            out[2 * plane + i] = Float(min(max(L + f * (b - L), 0), 1))
        }
        return AstroImage(width: image.width, height: image.height, channels: image.channels,
                          pixels: out, sourceIsLinear: image.sourceIsLinear)
    }

    /// Multiplicative background neutralization for OSC stacks (spec §8.5 v1.1).
    /// Scales each non-green channel so its median matches the green channel's median.
    /// Raw OSC sensors are green-dominant; this is the white-balance step Siril applies
    /// during processing. Channel 1 is treated as the reference (G in RGB).
    public static func neutralizeBackground(_ image: AstroImage) -> AstroImage {
        guard image.channels == 3 else { return image }
        let plane = image.width * image.height
        func channelMedian(_ c: Int) -> Double {
            var s = Array(image.pixels[c * plane..<(c + 1) * plane])
            s.sort()
            let mid = s.count / 2
            return s.count % 2 == 0 ? Double(s[mid - 1] + s[mid]) / 2 : Double(s[mid])
        }
        let refMedian = channelMedian(1)
        var out = image.pixels
        for c in [0, 2] {
            let med = channelMedian(c)
            guard med > 1e-9 else { continue }
            let scale = Float(refMedian / med)
            for i in (c * plane)..<((c + 1) * plane) {
                out[i] = min(max(out[i] * scale, 0), 1)
            }
        }
        return AstroImage(width: image.width, height: image.height, channels: image.channels,
                          pixels: out, sourceIsLinear: image.sourceIsLinear)
    }

    /// Additive background neutralization for OSC color casts.
    /// Multiplicative BN corrects channel gain but leaves the additive skyglow
    /// pedestal, so a green cast survives. This estimates each channel's sky
    /// background from a tile grid and subtracts each channel down to the darkest
    /// channel's level, removing the cast (validated on ASI2600 data).
    ///
    /// Robustness: the channel background is the LOW percentile of tile medians.
    /// The darkest tiles are true sky, so bright nebula/stars can't skew the
    /// estimate the way a whole-frame median would.
    public static func neutralizeBackgroundAdditive(_ image: AstroImage,
                                                    tilesPerAxis: Int = 48,
                                                    backgroundPercentile: Double = 20) -> AstroImage {
        guard image.channels == 3 else { return image }
        let w = image.width, h = image.height, plane = w * h
        let tiles = max(1, tilesPerAxis)

        // Median of an arbitrary set of values (even-count → mean of the two middle).
        func median(_ values: inout [Float]) -> Double {
            values.sort()
            let mid = values.count / 2
            return values.count % 2 == 0 ? Double(values[mid - 1] + values[mid]) / 2
                                         : Double(values[mid])
        }

        // Background estimate for one channel: low percentile of per-tile medians.
        func channelBackground(_ c: Int) -> Double {
            let base = c * plane
            var tileMedians: [Double] = []
            tileMedians.reserveCapacity(tiles * tiles)
            for ty in 0..<tiles {
                let y0 = ty * h / tiles
                let y1 = (ty + 1) * h / tiles
                for tx in 0..<tiles {
                    let x0 = tx * w / tiles
                    let x1 = (tx + 1) * w / tiles
                    if y1 <= y0 || x1 <= x0 { continue }
                    var vals: [Float] = []
                    vals.reserveCapacity((y1 - y0) * (x1 - x0))
                    for y in y0..<y1 {
                        let row = base + y * w
                        for x in x0..<x1 { vals.append(image.pixels[row + x]) }
                    }
                    tileMedians.append(median(&vals))
                }
            }
            // Reachable only for a degenerate 0-area frame (every tile collapses
            // to zero extent and is skipped above). Return a 0 background offset
            // so such an image passes through unchanged rather than crashing on
            // the empty-array percentile index below.
            guard !tileMedians.isEmpty else { return 0 }
            tileMedians.sort()
            let p = min(max(backgroundPercentile, 0), 100) / 100
            // Nearest-rank index into the sorted tile medians.
            let idx = min(tileMedians.count - 1,
                          max(0, Int((p * Double(tileMedians.count - 1)).rounded())))
            return tileMedians[idx]
        }

        let bg = (0..<3).map { channelBackground($0) }
        let floor = min(bg[0], min(bg[1], bg[2]))

        var out = image.pixels
        for c in 0..<3 {
            let offset = Float(bg[c] - floor)
            if offset <= 0 { continue }
            for i in (c * plane)..<((c + 1) * plane) {
                out[i] = min(max(out[i] - offset, 0), 1)
            }
        }
        return AstroImage(width: w, height: h, channels: image.channels,
                          pixels: out, sourceIsLinear: image.sourceIsLinear)
    }

    /// Pack planar float image into an 8-bit CGImage (gray or RGBX).
    /// CGContext creation / makeImage() only fail under memory pressure;
    /// the nil propagates to the caller rather than trapping.
    public static func makeCGImage(_ image: AstroImage) -> CGImage? {
        let w = image.width, h = image.height, plane = w * h
        if image.channels == 1 {
            var buf = [UInt8](repeating: 0, count: plane)
            for p in 0..<plane { buf[p] = UInt8(min(max(image.pixels[p], 0), 1) * 255) }
            return buf.withUnsafeMutableBytes { ptr in
                CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                          bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                          bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
            }
        }
        var buf = [UInt8](repeating: 255, count: plane * 4)
        for p in 0..<plane {
            buf[p * 4]     = UInt8(min(max(image.pixels[p], 0), 1) * 255)
            buf[p * 4 + 1] = UInt8(min(max(image.pixels[plane + p], 0), 1) * 255)
            buf[p * 4 + 2] = UInt8(min(max(image.pixels[2 * plane + p], 0), 1) * 255)
        }
        return buf.withUnsafeMutableBytes { ptr in
            CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
    }
}
