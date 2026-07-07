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
                               shadowsClipping: Double = -2.8) -> AstroImage {
        let plane = image.width * image.height
        // Combined luminance sample (mean across channels), stride-sampled.
        let stride = max(1, plane / 262_144)
        var sample: [Float] = []
        sample.reserveCapacity(plane / stride + 1)
        var i = 0
        while i < plane {
            var s: Float = 0
            for c in 0..<image.channels { s += image.pixels[c * plane + i] }
            sample.append(s / Float(image.channels))
            i += stride
        }
        sample.sort()
        let median = Double(sample[sample.count / 2])
        var deviations = sample.map { abs(Double($0) - median) }
        deviations.sort()
        let madn_raw = 1.4826 * deviations[deviations.count / 2]
        // When all samples are nearly identical (madn ≈ 0), use median as fallback to preserve channel ratios
        let madn = madn_raw > 1e-10 ? madn_raw : max(median, 1e-10)

        let shadow = min(max(median + shadowsClipping * madn, 0), 1)
        let denom = max(1 - shadow, 1e-9)
        let r = min(max((median - shadow) / denom, 1e-9), 1)
        let midtone = mtf(r, targetBackground)

        var out = [Float](repeating: 0, count: image.pixels.count)
        for idx in 0..<image.pixels.count {
            let x = (Double(image.pixels[idx]) - shadow) / denom
            out[idx] = Float(mtf(min(max(x, 0), 1), midtone))
        }
        return AstroImage(width: image.width, height: image.height, channels: image.channels,
                          pixels: out, sourceIsLinear: false)
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

    /// Pack planar float image into an 8-bit CGImage (gray or RGBX).
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
