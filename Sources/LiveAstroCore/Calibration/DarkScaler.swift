import Foundation

/// Scales a master dark to a different exposure using a bias reference so one
/// dark set (plus bias) can calibrate lights shot at other exposures.
///
/// A dark frame is `bias + thermal×time`. The bias offset is exposure-independent;
/// only the thermal component scales with exposure. So to retarget a dark from its
/// own exposure to the light's:
///
///     scaled = bias + (dark − bias) × factor,   factor = expLight / expDark
///
/// Result is clamped ≥ 0. Returns nil if the dark and bias dimensions differ (the
/// matcher guarantees a size match before calling; nil is the defensive path).
public enum DarkScaler {
    public static func scale(dark: AstroImage, bias: AstroImage, factor: Double) -> AstroImage? {
        guard dark.width == bias.width, dark.height == bias.height,
              dark.channels == bias.channels else { return nil }
        // A corrupt exposure (e.g. EXPTIME=1e100) yields a non-finite factor; Float(1e100) is +Inf.
        // Refuse rather than emit a non-finite dark that would black out every calibrated frame.
        guard factor.isFinite, factor > 0 else { return nil }
        let f = Float(factor)
        guard f.isFinite else { return nil }
        let n = dark.pixels.count
        var out = [Float](repeating: 0, count: n)
        dark.pixels.withUnsafeBufferPointer { D in
            bias.pixels.withUnsafeBufferPointer { B in
                for i in 0..<n {
                    let v = B[i] + (D[i] - B[i]) * f
                    out[i] = (v.isFinite && v > 0) ? v : 0   // clamp non-finite (overflow) AND negative to 0
                }
            }
        }
        return AstroImage(width: dark.width, height: dark.height, channels: dark.channels,
                          pixels: out, sourceIsLinear: true)
    }
}
