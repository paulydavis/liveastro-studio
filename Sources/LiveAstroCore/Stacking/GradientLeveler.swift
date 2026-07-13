// Sources/LiveAstroCore/Stacking/GradientLeveler.swift

/// Reference-matched per-sub background leveling (spec: gradient leveling).
/// For each channel where BOTH the sub and reference models have coefficients,
/// evaluates each model's surface with its OWN degree then subtracts the
/// difference surface (surfSub − surfRef) per pixel, clamped to [0,1].
/// A channel with either coeff missing is passthrough. Identical models return
/// the frame byte-identical. Deterministic; parallel over row bands.
public enum GradientLeveler {
    public static func apply(_ image: AstroImage,
                             subModel: BackgroundExtraction.BackgroundModel,
                             refModel: BackgroundExtraction.BackgroundModel,
                             minRows: Int = 64) -> AstroImage {
        let w = image.width, h = image.height, chans = image.channels, plane = w * h
        var out = image.pixels
        out.withUnsafeMutableBufferPointer { buf in
            for c in 0..<chans {
                guard c < subModel.coeffPerChannel.count, c < refModel.coeffPerChannel.count,
                      let cs = subModel.coeffPerChannel[c], let cr = refModel.coeffPerChannel[c] else { continue }

                // Byte-identical fast path: same degree AND same coefficients.
                if subModel.degree == refModel.degree && cs == cr { continue }

                // Evaluate each model's surface with its OWN degree (fixes degree-mismatch
                // crash and zip-truncation silent corruption).
                let sSub = BackgroundExtraction.BackgroundModel.evaluate(
                    coeff: cs, degree: subModel.degree, width: w, height: h)
                let sRef = BackgroundExtraction.BackgroundModel.evaluate(
                    coeff: cr, degree: refModel.degree, width: w, height: h)

                let base = c * plane
                Parallel.rows(h, minRows: minRows) { rows in
                    for y in rows {
                        for x in 0..<w {
                            let j = y * w + x
                            let i = base + j
                            let correction = sSub[j] - sRef[j]
                            let result = buf[i] - correction
                            // NaN hardening: if surface values or result are non-finite,
                            // passthrough original pixel. Swift's min/max do NOT sanitize NaN.
                            if correction.isFinite && result.isFinite {
                                buf[i] = min(max(result, 0), 1)
                            }
                            // else: leave buf[i] at its original value (passthrough)
                        }
                    }
                }
            }
        }
        return AstroImage(width: w, height: h, channels: chans, pixels: out, sourceIsLinear: image.sourceIsLinear)
    }
}
