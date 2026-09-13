import Foundation

/// Shared "raw → calibrated-domain display RGB" step (spec §4.2): debayer in STORED order
/// (never flip the CFA), then flip rows to top-down display if the source was bottom-up.
/// Extracted from `StackEngine`'s private `displayRGB` so BOTH the online engine and the
/// live-rejection `GlobalRefiner`'s production `FrameLoader` produce byte-identical pixels —
/// one implementation, no drift between the two domains a warped/leveled sub is compared in.
/// RawFrame contract: `bayerPattern != nil` implies `channels == 1` (a violated contract
/// traps in `Debayer.bilinear`/`Debayer.malvar` rather than silently mis-rendering).
public enum DisplayRGB {
    public static func make(_ frame: RawFrame, demosaic: DemosaicMethod, minRows: Int = 64) -> AstroImage {
        var rgb: AstroImage
        if let pattern = frame.bayerPattern, frame.image.channels == 1 {
            switch demosaic {
            case .bilinear:
                rgb = Debayer.bilinear(cfa: frame.image, pattern: pattern, minRows: minRows)
            case .malvar:
                rgb = Debayer.malvar(cfa: frame.image, pattern: pattern, minRows: minRows)
            }
        } else {
            rgb = frame.image
        }
        guard frame.bottomUp else { return rgb }
        let w = rgb.width, h = rgb.height, plane = w * h
        var flipped = [Float](repeating: 0, count: rgb.pixels.count)
        for c in 0..<rgb.channels {
            for y in 0..<h {
                let src = c * plane + (h - 1 - y) * w
                let dst = c * plane + y * w
                flipped.replaceSubrange(dst..<(dst + w), with: rgb.pixels[src..<(src + w)])
            }
        }
        return AstroImage(width: w, height: h, channels: rgb.channels,
                          pixels: flipped, sourceIsLinear: rgb.sourceIsLinear)
    }
}
