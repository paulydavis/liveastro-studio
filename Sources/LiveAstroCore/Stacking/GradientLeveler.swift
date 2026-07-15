// Sources/LiveAstroCore/Stacking/GradientLeveler.swift

/// Reference-matched per-sub background leveling WITH fused multiplicative scaling
/// (spec: gradient leveling + scale normalization).
/// For each channel where BOTH the sub and reference models have coefficients,
/// evaluates each model's surface with its OWN degree, then applies the fused form
///   out = clamp( surfRef + (x − surfSub) · scale, 0, 1 )
/// per pixel. This levels the sub's background onto the reference surface AND scales
/// the leveled signal about that per-pixel reference-background pivot — the correct
/// pivot for both a scalar-background sub (regime 1) and a gradient sky (regime 2).
/// When `scale == 1` this matches plain leveling to within 1 ULP (FP reassociation);
/// byte-identical fast path only when the models are identical. A channel with either
/// coeff missing is passthrough (no leveling AND no scaling — consistent). Identical
/// models return the frame byte-identical ONLY when `scale == 1`; when models match
/// but `scale != 1` the fused form still applies (out = surfRef + (x − surfRef)·scale).
/// Scaling is all-or-nothing across channels: if ANY channel is missing a sub or ref
/// coeff pair and scale != 1, the effective scale is forced to 1.0 for the WHOLE frame.
/// This prevents a silent per-sub color shift when one channel's polynomial fit fails
/// (a per-channel scaling failure would leave that channel unscaled while others are
/// scaled, shifting the color balance). The frame weight may then be slightly
/// conservative (σ·s computed at registration) — acceptable, mirrors the leveling-nil
/// case. Deterministic; parallel over row bands.
public enum GradientLeveler {
    public static func apply(_ image: AstroImage,
                             subModel: BackgroundExtraction.BackgroundModel,
                             refModel: BackgroundExtraction.BackgroundModel,
                             scale: Float = 1.0,
                             minRows: Int = 64) -> AstroImage {
        let w = image.width, h = image.height, chans = image.channels, plane = w * h

        // All-or-nothing scaling guard: if ANY channel has a mismatched coeff pair (one
        // side nil, the other non-nil) and scale != 1, suppress scaling for the entire
        // frame to prevent per-sub color shifts. A channel where BOTH sub AND ref are nil
        // is passthrough regardless and does not create a mismatch. A channel where BOTH
        // are non-nil participates fully. Only when one side is nil and the other is not
        // does scaling become asymmetric — that channel passes through unscaled while
        // other channels are scaled, producing a color shift.
        let effectiveScale: Float
        if scale != 1.0 {
            let hasAsymmetricChannel = (0..<chans).contains { c in
                let hasSub = c < subModel.coeffPerChannel.count && subModel.coeffPerChannel[c] != nil
                let hasRef = c < refModel.coeffPerChannel.count && refModel.coeffPerChannel[c] != nil
                return hasSub != hasRef   // XOR: exactly one side present → mismatch
            }
            effectiveScale = hasAsymmetricChannel ? 1.0 : scale
        } else {
            effectiveScale = 1.0
        }

        var out = image.pixels
        out.withUnsafeMutableBufferPointer { buf in
            for c in 0..<chans {
                guard c < subModel.coeffPerChannel.count, c < refModel.coeffPerChannel.count,
                      let cs = subModel.coeffPerChannel[c], let cr = refModel.coeffPerChannel[c] else { continue }

                // Byte-identical fast path: same degree AND same coefficients — but ONLY
                // when effectiveScale == 1 (out = x − surfSub + surfRef = x). When
                // effectiveScale != 1 the fused form still transforms the pixel
                // (out = surfRef + (x − surfRef)·s), so do NOT skip.
                if effectiveScale == 1.0 && subModel.degree == refModel.degree && cs == cr { continue }

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
                            // pivot: out = surfRef + (x − surfSub)·effectiveScale.
                            // effectiveScale == 1 → x − surfSub + surfRef.
                            let result = sRef[j] + (buf[i] - sSub[j]) * effectiveScale
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
