// Sources/LiveAstroCore/Stacking/GradientLeveler.swift

/// Reference-matched per-sub background leveling WITH fused multiplicative scaling
/// (spec: gradient leveling + scale normalization).
/// For each channel where BOTH the sub and reference models have coefficients,
/// evaluates each model's surface with its OWN degree, then applies the fused form
///   out = clamp( surfRef + (x − surfSub) · scale, 0, 1 )
/// per pixel. This levels the sub's background onto the reference surface AND scales
/// the leveled signal about that per-pixel reference-background pivot — the correct
/// pivot for both a scalar-background sub (regime 1) and a gradient sky (regime 2).
/// When `scale == 1` this reduces to `x − surfSub + surfRef` (byte-identical to the
/// pure leveling subtract). A channel with either coeff missing is passthrough (no
/// leveling AND no scaling — consistent). Identical models return the frame
/// byte-identical ONLY when `scale == 1`; when models match but `scale != 1` the
/// fused form still applies (out = surfRef + (x − surfRef)·scale). Deterministic;
/// parallel over row bands.
public enum GradientLeveler {
    public static func apply(_ image: AstroImage,
                             subModel: BackgroundExtraction.BackgroundModel,
                             refModel: BackgroundExtraction.BackgroundModel,
                             scale: Float = 1.0,
                             minRows: Int = 64) -> AstroImage {
        let w = image.width, h = image.height, chans = image.channels, plane = w * h
        var out = image.pixels
        out.withUnsafeMutableBufferPointer { buf in
            for c in 0..<chans {
                guard c < subModel.coeffPerChannel.count, c < refModel.coeffPerChannel.count,
                      let cs = subModel.coeffPerChannel[c], let cr = refModel.coeffPerChannel[c] else { continue }

                // Byte-identical fast path: same degree AND same coefficients — but ONLY
                // when scale == 1 (out = x − surfSub + surfRef = x). When scale != 1 the
                // fused form still transforms the pixel (out = surfRef + (x − surfRef)·s),
                // so do NOT skip.
                if scale == 1.0 && subModel.degree == refModel.degree && cs == cr { continue }

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
                            // Fused leveling + scaling about the per-pixel reference-background
                            // pivot: out = surfRef + (x − surfSub)·scale. scale == 1 → x − surfSub + surfRef.
                            let result = sRef[j] + (buf[i] - sSub[j]) * scale
                            // NaN hardening: if surface values or result are non-finite,
                            // passthrough original pixel. Swift's min/max do NOT sanitize NaN.
                            if result.isFinite {
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
