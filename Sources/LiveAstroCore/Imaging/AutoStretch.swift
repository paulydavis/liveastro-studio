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

    /// How far, in MADN (robust sigma), a full-travel black point lifts the shadow cut above the
    /// auto-derived one. 8 puts the background well past crushed on real data, so the useful range
    /// sits comfortably inside the slider rather than in a sliver at one end.
    public static let blackPointMaxMADN = 8.0

    /// The linked statistics the autostretch derives its transform from: the median and MADN of
    /// the mean-of-channels sample. Exposed so a caller can compute them on the FULL-RESOLUTION
    /// image and hand them to a render of a downsampled proxy, which is what keeps the preview's
    /// curve identical to the broadcast's.
    public struct LinkedStatistics: Equatable, Sendable {
        public let median: Double
        public let madn: Double
        public init(median: Double, madn: Double) { self.median = median; self.madn = madn }
    }

    public static func linkedStatistics(_ image: AstroImage) -> LinkedStatistics {
        let plane = image.width * image.height
        guard plane > 0 else { return LinkedStatistics(median: 0, madn: 1e-10) }
        let work = image.pixels
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
        let madnRaw = 1.4826 * deviations[deviations.count / 2]
        // When all samples are nearly identical (madn ≈ 0), use median as fallback to preserve
        // channel ratios.
        return LinkedStatistics(median: median, madn: madnRaw > 1e-10 ? madnRaw : max(median, 1e-10))
    }

    /// Linked autostretch: statistics from the mean-of-channels sample, one transform for all channels.
    public static func stretch(_ image: AstroImage,
                               targetBackground: Double = 0.25,
                               shadowsClipping: Double = -2.8,
                               blackPoint: Double = 0,
                               midtoneStrength: Double = 0,
                               statistics: LinkedStatistics? = nil) -> AstroImage {
        // Black point is applied AFTER the auto-stretch statistics are derived, not before.
        //
        // It used to clip the LINEAR data first; the median and MADN were then measured on the
        // CLIPPED result and the background renormalised to `targetBackground`, which undid the
        // clip almost exactly. Measured on a real M51 master: moving the slider from 0 to 0.005
        // changed the rendered output by 0.00/255, and even the full old range only reached
        // 0.21/255 mean. The control did nothing, which is what it looked like in use.
        //
        // It now raises the SHADOW POINT while the midtone stays fixed at its auto-derived value.
        // The midtone was the real culprit: it is solved to place the background at
        // `targetBackground`, so ANY shadow movement was compensated away and the background
        // landed back in the same place. Deriving the midtone once, from the auto shadow, and then
        // moving only the cut makes the control bite: measured on a real master, +1 MADN shifts
        // the render by 18.6/255 and +3 MADN by 53.4/255, against 0.00/255 for the old behaviour.
        // 0 reproduces the auto-stretch exactly, so the neutral path stays byte-identical.
        let bp = min(max(blackPoint, 0), 1)
        let work = image.pixels

        let plane = image.width * image.height
        // A zero-pixel image has no samples: median indexing below would trap. Nothing
        // to stretch — return it unchanged (mirrors the AstroImage.computeStats guard).
        guard plane > 0 else { return image }
        // Statistics may be INJECTED. The preview renders a downsample, and deriving the
        // transform from the downsample's own statistics is not the same transform the
        // full-resolution broadcast derives: averaging halves MADN, which moves the shadow point,
        // and the midtone is solved from that — so the curve visibly diverges. Passing the
        // full-resolution statistics in makes the preview apply the BROADCAST's curve.
        let stats = statistics ?? linkedStatistics(image)
        let median = stats.median
        let madn = stats.madn

        let autoShadow = min(max(median + shadowsClipping * madn, 0), 1)
        // The slider spans 0...1; full travel lifts the cut by `blackPointMaxMADN` sigma above the
        // auto point, which is past the point where the background is fully crushed on real data.
        //
        // The cut is bounded by the headroom ABOVE the auto shadow, not by an absolute ceiling.
        // An absolute cap gets both edge cases wrong on a near-saturated frame, where the auto
        // shadow itself is already above the ceiling: a flat 0.99 pulls the cut BELOW the auto
        // point and changes the render at black point 0 (measured on [0.9989, 0.9990, 0.9991]:
        // rendered median 0.25 -> 0.878), while `max(autoShadow, 0.99)` lands exactly ON the auto
        // point and freezes the slider instead. Letting the offset consume at most 99% of the
        // distance from the auto shadow to 1 keeps `denom` strictly positive, leaves black point 0
        // byte-identical on every input, and keeps the control live on every input.
        let headroom = max(1 - autoShadow, 0)
        let shadow = autoShadow + min(max(bp, 0) * blackPointMaxMADN * madn, 0.99 * headroom)
        let denom = max(1 - shadow, 1e-9)
        // r — and therefore the midtone — comes from the AUTO shadow, never the user-shifted one.
        // Deriving it from `shadow` is what made black point self-cancelling.
        let autoDenom = max(1 - autoShadow, 1e-9)
        let r = min(max((median - autoShadow) / autoDenom, 1e-9), 1)
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
