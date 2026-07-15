import Foundation

/// Multiplicative transparency normalization (spec: scale normalization).
/// Scales a frame's SIGNAL about the per-channel reference background:
/// out = clamp(bg[c] + (x − bg[c])·scale, 0, 1). scale == 1 returns the frame
/// byte-identical. Deterministic; parallel over row bands.
public enum SignalScaler {
    public static func apply(_ image: AstroImage, scale: Float, background: [Float],
                             minRows: Int = 64) -> AstroImage {
        precondition(background.count == image.channels, "background must have one value per channel")
        if scale == 1.0 { return image }
        let w = image.width, h = image.height, chans = image.channels, plane = w * h
        var out = image.pixels
        out.withUnsafeMutableBufferPointer { buf in
            for c in 0..<chans {
                let bg = background[c], base = c * plane
                Parallel.rows(h, minRows: minRows) { rows in
                    for y in rows {
                        for x in 0..<w {
                            let i = base + y * w + x
                            buf[i] = min(max(bg + (buf[i] - bg) * scale, 0), 1)
                        }
                    }
                }
            }
        }
        return AstroImage(width: w, height: h, channels: chans, pixels: out, sourceIsLinear: image.sourceIsLinear)
    }
}
