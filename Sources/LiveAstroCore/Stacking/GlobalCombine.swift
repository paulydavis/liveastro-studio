import Foundation

/// Pure full-set robust combine used by the live GlobalRefiner (and, later, the import surface).
/// No I/O, no knowledge of live/import/relay. Two composable pieces: a robust median/MAD CENTER
/// estimated over a RAM sample, and a weighted clipped MEAN accumulated over all survivors.
public enum GlobalCombine {
    /// Per-pixel·channel median + MAD over `sample` (masked). `scale = 1.4826·MAD` (robust σ).
    /// `mask` length == width*height (shared across channels; >0 == in-bounds). Center/scale
    /// length == width*height*channels. `sampleCovered` length == width*height (one PLANE entry,
    /// shared across channels like `mask`): true iff at least one sample frame's mask covers that
    /// plane pixel — lets `clippedWeightedMean` distinguish "no robust center exists here" (must
    /// not clip) from "a robust center exists but every full-set frame was clipped" (center
    /// fallback is legitimate). nil if sample empty or a frame's dims disagree.
    public static func robustCenter(sample: [(image: AstroImage, mask: [Float])])
        -> (center: AstroImage, scale: [Float], sampleCovered: [Bool])? {
        guard let first = sample.first else { return nil }
        let w = first.image.width, h = first.image.height, c = first.image.channels
        let plane = w * h, n = plane * c
        for s in sample where s.image.width != w || s.image.height != h
            || s.image.channels != c || s.mask.count != plane || s.image.pixels.count != n {
            return nil
        }
        var center = [Float](repeating: 0, count: n)
        var scale = [Float](repeating: 0, count: n)
        var sampleCovered = [Bool](repeating: false, count: plane)
        for p in 0..<plane {
            sampleCovered[p] = sample.contains { $0.mask[p] > 0 }
        }
        var vbuf = [Float](); vbuf.reserveCapacity(sample.count)
        var dbuf = [Float](); dbuf.reserveCapacity(sample.count)
        for idx in 0..<n {
            let p = idx % plane
            vbuf.removeAll(keepingCapacity: true)
            for s in sample where s.mask[p] > 0 { vbuf.append(s.image.pixels[idx]) }
            if vbuf.isEmpty { continue }               // no coverage → center/scale stay 0
            let med = median(&vbuf)
            center[idx] = med
            dbuf.removeAll(keepingCapacity: true)
            for v in vbuf { dbuf.append(abs(v - med)) }
            scale[idx] = madToSigma * median(&dbuf)
        }
        return (AstroImage(width: w, height: h, channels: c, pixels: center, sourceIsLinear: true),
                scale, sampleCovered)
    }

    /// In-place median (sorts the buffer). Even count → mean of the two middle elements.
    static func median(_ a: inout [Float]) -> Float {
        a.sort()
        let m = a.count / 2
        return a.count % 2 == 1 ? a[m] : (a[m - 1] + a[m]) / 2
    }
}

extension GlobalCombine {
    /// Floor for the robust σ used as the clip denominator: `sigma = max(scale, scaleFloor)`.
    /// Ensures a zero-MAD core ([1,1,1,1,9]) still rejects the gross outlier, and guards
    /// divide-by-tiny. Rationale: `AstroImage` pixels are linear floats normalized ~0..1, so the
    /// 16-bit quantization step is ~1/65535 ≈ 1.5e-5 — `1e-7` sits ~two decades BELOW the smallest
    /// real intensity step, so it never over-rejects legitimate frame-to-frame noise (which is ≥
    /// quantization); it bites only a truly-degenerate exactly-equal core. Pinned by a test that a
    /// near-flat set with sub-floor spread is fully KEPT.
    static let scaleFloor: Float = 1e-7

    /// MAD→σ normal-consistency constant, 1/Φ⁻¹(0.75).
    static let madToSigma: Float = 1.4826

    public static func clippedWeightedMean(
        frames: () -> AnyIterator<(image: AstroImage, mask: [Float], weight: Float)>,
        center: AstroImage, scale: [Float], sampleCovered: [Bool], kappa: Float
    ) -> (image: AstroImage, coverage: [Float])? {
        let w = center.width, h = center.height, c = center.channels
        let plane = w * h, n = plane * c
        guard scale.count == n, sampleCovered.count == plane else { return nil }
        var sumW = [Float](repeating: 0, count: n)
        var sumWV = [Float](repeating: 0, count: n)
        var coverage = [Float](repeating: 0, count: plane)   // per-pixel FRAME DEPTH (not binary)
        var any = false
        var it = frames()
        while let f = it.next() {
            guard f.image.width == w, f.image.height == h, f.image.channels == c,
                  f.mask.count == plane, f.image.pixels.count == n else { return nil }
            any = true
            for p in 0..<plane where f.mask[p] > 0 { coverage[p] += 1 }   // spatial depth per pixel
            for idx in 0..<n where f.mask[idx % plane] > 0 {
                let v = f.image.pixels[idx]
                // Sample-UNCOVERED pixel: no robust center/scale exists here (robustCenter left
                // center=0/scale=0 for it) — clipping against that phantom center would reject
                // every real value and fall back to black. Take the true weighted mean instead.
                if !sampleCovered[idx % plane] {
                    sumW[idx]  += f.weight
                    sumWV[idx] += f.weight * v
                    continue
                }
                // REAL floor as the clip denominator: a zero-MAD core (e.g. [1,1,1,1,9]) must still
                // reject the 9. `if scale>floor` (the earlier form) wrongly ACCEPTED everything at MAD=0.
                let sigma = max(scale[idx], scaleFloor)
                if abs(v - center.pixels[idx]) > kappa * sigma { continue }   // reject outlier
                sumW[idx]  += f.weight
                sumWV[idx] += f.weight * v
            }
        }
        guard any else { return nil }
        var out = [Float](repeating: 0, count: n)
        for idx in 0..<n {
            if sumW[idx] > 0 { out[idx] = sumWV[idx] / sumW[idx] }
            // Sample-covered but every full-set frame was clipped → the robust center is real and
            // meaningful for this pixel; fall back to it (no black speckle). A sample-UNCOVERED
            // pixel never reaches this branch with sumW==0 unless it truly had zero coverage
            // (`any` frame at all) — its real values are always accumulated above, never clipped.
            else if coverage[idx % plane] > 0 { out[idx] = center.pixels[idx] }
        }
        return (AstroImage(width: w, height: h, channels: c, pixels: out, sourceIsLinear: center.sourceIsLinear), coverage)
    }
}
