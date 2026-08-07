import Foundation

/// Classic, deterministic two-stage noise reduction (native-noise-reduction spec §2.1).
///
/// One pure engine, two consumers: `SessionPipeline.displayCGImage` (post-stretch
/// display domain) and `NativeDenoiseProcessor` (linear master domain). The domain
/// is carried by `AstroImage.sourceIsLinear` (plan finding F3), keeping the spec's
/// single `apply(_:strength:)` signature.
///
/// Stage 1 — chroma mottle suppression (3-channel only): opponent transform
/// (Y, C1, C2), chroma downsampled 4x, box^3 blur at coarse scale, correction
/// blended under a luma-edge guard at BOTH scales so colour never bleeds across
/// star edges or filament boundaries, bilinear upsample, recombine.
/// Stage 2 — edge-preserving luma smoothing: residual-thresholded blur blend with
/// a 32x32 tile median/MAD-sigma grid (statistically flat sky smoothed harder,
/// structured tiles backed off) and a sigma-relative gradient-protection term
/// (threshold k · tile sigma).
///
/// Contracts (spec §2.1): `strength == 0` returns the input byte-identical;
/// images below 64x64 pass through; mono runs stage 2 only; non-finite input
/// pixels pass through untouched at their positions (math runs on a sanitized
/// copy — the engine never traps and never spreads NaN into neighbours).
/// Unsupported channel counts (not 1 or 3) pass through.
///
/// Deterministic: fixed constants, integer tile grid, `Parallel.rows` bands write
/// disjoint rows with per-element expressions identical to a serial loop.
public enum Denoiser {

    /// T1-validated constants (BINDING): mirrored VERBATIM from the gate-passed
    /// table in docs/superpowers/reviews/2026-08-02-denoise-prototype-results.md
    /// (spec §3 — additive-BN / DBE prototype-first discipline). Do not tune here.
    enum K {
        static let minDim = 64
        static let tilesPerAxis = 32
        static let maxTileSamples = 1024
        static let backgroundPercentile: Double = 20
        // ROUNDING CONVENTION (binding): half-up (floor(x+0.5) ≡ Swift .rounded()
        // for positive x) — the Python mirror uses int(math.floor(x + 0.5)), NOT
        // round(), which is banker's and diverges at .5 (e.g. lumaRadius at s=0.5).
        // Stage 1 — chroma
        static let chromaDown = 4
        static let chromaPasses = 3
        static func chromaRadius(_ s: Float) -> Int { max(1, Int((2.0 + 6.0 * s).rounded())) }
        static let chromaEdgeGradDisplay: Float = 0.25
        static let chromaEdgeGradLinear: Float = 0.025
        static let chromaBlendGain: Float = 2.0    // blend amplitude: min(1, gain·s)
        // Stage 2 — luma
        static let lumaPasses = 2
        static func lumaRadius(_ s: Float) -> Int { max(1, Int((1.0 + 3.0 * s).rounded())) }
        static let lumaResidualK: Float = 1.5
        static let lumaBlendGain: Float = 2.0      // blend amplitude: min(1, gain·s)
        static let lumaSigmaProtectK: Float = 6.0  // gradient-protect threshold = k · tile sigma
        static let structureK: Float = 4.0
        static let structuredTileFloor: Float = 0.15
    }

    public static func apply(_ image: AstroImage, strength: Float) -> AstroImage {
        guard strength > 0 else { return image }                       // off is free & byte-identical
        guard image.width >= K.minDim, image.height >= K.minDim else { return image }
        guard image.channels == 1 || image.channels == 3 else { return image }
        let s = min(strength, 1)
        let w = image.width, h = image.height, plane = w * h
        let src = image.pixels
        let sane = src.map { $0.isFinite ? $0 : Float(0) }             // DBE ingest-sanitize precedent

        var outPixels: [Float]
        if image.channels == 3 {
            // Opponent transform: Y=(R+2G+B)/4, C1=R-G, C2=B-G (exact integer-weight inverse).
            var y = [Float](repeating: 0, count: plane)
            var c1 = [Float](repeating: 0, count: plane)
            var c2 = [Float](repeating: 0, count: plane)
            y.withUnsafeMutableBufferPointer { yb in
                c1.withUnsafeMutableBufferPointer { c1b in
                    c2.withUnsafeMutableBufferPointer { c2b in
                        Parallel.rows(h) { rows in
                            for row in rows { for x in 0..<w {
                                let i = row * w + x
                                let r = sane[i], g = sane[plane + i], b = sane[2 * plane + i]
                                yb[i] = (r + 2 * g + b) * 0.25
                                c1b[i] = r - g
                                c2b[i] = b - g
                            } }
                        }
                    }
                }
            }
            stage1Chroma(y: y, c1: &c1, c2: &c2, width: w, height: h,
                         strength: s, linearDomain: image.sourceIsLinear)
            let y2 = stage2Luma(y, width: w, height: h,
                                strength: s, linearDomain: image.sourceIsLinear)
            var recombined = [Float](repeating: 0, count: plane * 3)
            recombined.withUnsafeMutableBufferPointer { ob in
                Parallel.rows(h) { rows in
                    for row in rows { for x in 0..<w {
                        let i = row * w + x
                        let g = y2[i] - (c1[i] + c2[i]) * 0.25
                        ob[i] = c1[i] + g
                        ob[plane + i] = g
                        ob[2 * plane + i] = c2[i] + g
                    } }
                }
            }
            outPixels = recombined
        } else {
            outPixels = stage2Luma(sane, width: w, height: h,
                                   strength: s, linearDomain: image.sourceIsLinear)
        }
        // Non-finite input pixels pass through untouched at their positions (spec §2.1).
        for i in 0..<src.count where !src[i].isFinite { outPixels[i] = src[i] }
        return AstroImage(width: w, height: h, channels: image.channels,
                          pixels: outPixels, sourceIsLinear: image.sourceIsLinear)
    }

    // MARK: - Stage 1 (chroma)

    /// Chroma mottle suppression at 1/16 pixel count (spec §2.1 stage 1).
    static func stage1Chroma(y: [Float], c1: inout [Float], c2: inout [Float],
                             width w: Int, height h: Int,
                             strength s: Float, linearDomain: Bool) {
        let edge = linearDomain ? K.chromaEdgeGradLinear : K.chromaEdgeGradDisplay
        let d = K.chromaDown
        let (yd, sw, sh) = blockDown(y, width: w, height: h, factor: d)
        let gd = gradientMagnitude(yd, width: sw, height: sh)
        let gFull = gradientMagnitude(y, width: w, height: h)
        let r = K.chromaRadius(s)
        // Coarse edge guard, computed once (channel-independent).
        var wdRaw = [Float](repeating: 0, count: sw * sh)
        for i in 0..<wdRaw.count { wdRaw[i] = max(0, 1 - gd[i] / edge) }
        // ONE-CELL GUARD DILATION (T1-BINDING structure): take the min of wd with
        // its 4-neighbour shifts (edge-clamped, no wrap-around — mirrors the
        // Python's np.pad(mode="edge")) so any coarse cell adjacent to a strong
        // luma edge is also guarded — without this, bilinear upsample leaks the
        // unguarded neighbour's blur delta ~4-6 columns past the edge (probe:
        // |Δc1| up to ~0.07). Mirrored EXACTLY from the prototype's stage1_chroma;
        // the T2 bleed-band test enforces it.
        var wd = wdRaw
        for j in 0..<sh { for i in 0..<sw {
            let up = wdRaw[max(0, j - 1) * sw + i]
            let dn = wdRaw[min(sh - 1, j + 1) * sw + i]
            let lf = wdRaw[j * sw + max(0, i - 1)]
            let rt = wdRaw[j * sw + min(sw - 1, i + 1)]
            wd[j * sw + i] = min(wd[j * sw + i], min(min(up, dn), min(lf, rt)))
        } }
        // Blend amplitude min(1, gain·s) (T1-BINDING chromaBlendGain): a bare s caps
        // the mix at s, structurally unable to reach the 50% chroma gate at s=0.5.
        let wf = min(1, K.chromaBlendGain * s)

        func smoothed(_ c: [Float]) -> [Float] {
            let (cd, _, _) = blockDown(c, width: w, height: h, factor: d)
            var cb = cd
            for _ in 0..<K.chromaPasses { cb = boxBlurParallel(cb, sw, sh, radius: r) }
            // Coarse edge-attenuated correction (no blend term here — the blend
            // weight wf is applied once, at full resolution, or the effective mix
            // would be wf^2).
            var delta = [Float](repeating: 0, count: sw * sh)
            for i in 0..<delta.count {
                delta[i] = wd[i] * (cb[i] - cd[i])
            }
            let deltaUp = upsampleBilinear(delta, smallW: sw, smallH: sh,
                                           width: w, height: h, factor: d)
            var out = c
            out.withUnsafeMutableBufferPointer { ob in
                Parallel.rows(h) { rows in
                    for row in rows { for x in 0..<w {
                        let i = row * w + x
                        ob[i] += wf * max(0, 1 - gFull[i] / edge) * deltaUp[i]
                    } }
                }
            }
            return out
        }
        c1 = smoothed(c1)
        c2 = smoothed(c2)
    }

    // MARK: - Stage 2 (luma)

    /// Edge-preserving, tile-adaptive luma smoothing (spec §2.1 stage 2).
    static func stage2Luma(_ y: [Float], width w: Int, height h: Int,
                           strength s: Float, linearDomain: Bool) -> [Float] {
        // `linearDomain` kept for signature symmetry with the Python mirror:
        // stage-2 thresholds are sigma-relative (residual k·σ, gradient k·σ),
        // hence domain-free.
        let tiles = K.tilesPerAxis
        let grid = tileGrid(y, width: w, height: h, tiles: tiles)
        let globalBg = percentile(grid.medians, K.backgroundPercentile)
        let globalSigma = max(median(grid.sigmas), 1e-6)
        // Per-tile strength: full on statistically flat sky, floor where the tile
        // median rises above background by more than structureK sigmas.
        var tileWeight = [Float](repeating: 0, count: tiles * tiles)
        for i in 0..<tileWeight.count {
            tileWeight[i] = (grid.medians[i] - globalBg < K.structureK * globalSigma)
                ? 1.0 : K.structuredTileFloor
        }
        var blur = y
        let r = K.lumaRadius(s)
        for _ in 0..<K.lumaPasses { blur = boxBlurParallel(blur, w, h, radius: r) }
        let grad = gradientMagnitude(y, width: w, height: h)
        // Blend amplitude min(1, gain·s) (T1-BINDING lumaBlendGain): a bare s caps
        // the mix at s, structurally unable to reach the 40% luma gate at s=0.5.
        let wGain = min(1, K.lumaBlendGain * s)
        var out = y
        out.withUnsafeMutableBufferPointer { ob in
            Parallel.rows(h) { rows in
                for row in rows {
                    let ty = grid.rowTile[row]
                    for x in 0..<w {
                        let i = row * w + x
                        let t = ty * tiles + grid.colTile[x]
                        let sigma = max(grid.sigmas[t], 1e-6)
                        let resid = y[i] - blur[i]
                        if abs(resid) > K.lumaResidualK * sigma { continue }   // protected detail ("keep")
                        // Sigma-relative gradient protection (T1-BINDING lumaSigmaProtectK):
                        // with a fixed threshold, background noise gradients
                        // (E[|gx|+|gy|] ≈ 1.13σ) eat the protection budget and the noise
                        // protects itself; relative to k·σ_tile, noise falls inside the
                        // threshold while stars/filaments (|grad| ≫ k·σ) stay protected.
                        let protect = max(0, 1 - grad[i] / (K.lumaSigmaProtectK * sigma))
                        ob[i] = y[i] + wGain * tileWeight[t] * protect * (blur[i] - y[i])
                    }
                }
            }
        }
        return out
    }

    // MARK: - Primitives (mirrored 1:1 by Scripts/prototypes/denoise_prototype.py)

    /// Clamped-edge separable box blur, window 2r+1, H then V. Identical per-element
    /// semantics to BackgroundExtraction.boxBlur (BackgroundExtraction.swift:314-334)
    /// but parallel over rows: stage 2 runs it at full 26MP resolution where the
    /// serial DBE version (built for 1/16-scale buffers) would dominate the §4 budget.
    static func boxBlurParallel(_ a: [Float], _ w: Int, _ h: Int, radius r: Int) -> [Float] {
        if r < 1 { return a }
        let inv = 1.0 / Float(2 * r + 1)
        var tmp = [Float](repeating: 0, count: w * h)
        tmp.withUnsafeMutableBufferPointer { tb in
            Parallel.rows(h) { rows in
                for y in rows { for x in 0..<w {
                    var s: Float = 0
                    for dx in -r...r { s += a[y * w + min(w - 1, max(0, x + dx))] }
                    tb[y * w + x] = s * inv
                } }
            }
        }
        var outb = [Float](repeating: 0, count: w * h)
        outb.withUnsafeMutableBufferPointer { ob in
            Parallel.rows(h) { rows in
                for y in rows { for x in 0..<w {
                    var s: Float = 0
                    for dy in -r...r { s += tmp[min(h - 1, max(0, y + dy)) * w + x] }
                    ob[y * w + x] = s * inv
                } }
            }
        }
        return outb
    }

    /// L1 central-difference gradient magnitude; each axis contributes 0 at its borders.
    static func gradientMagnitude(_ a: [Float], width w: Int, height h: Int) -> [Float] {
        var g = [Float](repeating: 0, count: w * h)
        g.withUnsafeMutableBufferPointer { gb in
            Parallel.rows(h) { rows in
                for y in rows { for x in 0..<w {
                    let i = y * w + x
                    var gx: Float = 0, gy: Float = 0
                    if x > 0 && x < w - 1 { gx = (a[i + 1] - a[i - 1]) * 0.5 }
                    if y > 0 && y < h - 1 { gy = (a[i + w] - a[i - w]) * 0.5 }
                    gb[i] = abs(gx) + abs(gy)
                } }
            }
        }
        return g
    }

    /// Block-average downsample; small dims max(2, dim/d) — flattenMultiscale geometry
    /// (BackgroundExtraction.swift:260-268).
    static func blockDown(_ a: [Float], width w: Int, height h: Int, factor d: Int)
        -> (small: [Float], sw: Int, sh: Int) {
        let sw = max(2, w / d), sh = max(2, h / d)
        var small = [Float](repeating: 0, count: sw * sh)
        small.withUnsafeMutableBufferPointer { sb in
            Parallel.rows(sh) { rows in
                for j in rows { for i in 0..<sw {
                    var sum: Float = 0; var n: Float = 0
                    for dy in 0..<d { for dx in 0..<d {
                        let yy = j * d + dy, xx = i * d + dx
                        if yy < h && xx < w { sum += a[yy * w + xx]; n += 1 }
                    } }
                    sb[j * sw + i] = n > 0 ? sum / n : 0
                } }
            }
        }
        return (small, sw, sh)
    }

    /// Bilinear upsample of a factor-d downsampled plane back to w x h
    /// (sample centers at (i+0.5)*d in full-res coords).
    static func upsampleBilinear(_ small: [Float], smallW sw: Int, smallH sh: Int,
                                 width w: Int, height h: Int, factor d: Int) -> [Float] {
        var out = [Float](repeating: 0, count: w * h)
        out.withUnsafeMutableBufferPointer { ob in
            Parallel.rows(h) { rows in
                for yPix in rows {
                    let fy = (Float(yPix) + 0.5) / Float(d) - 0.5
                    let y0 = min(sh - 1, max(0, Int(fy.rounded(.down))))
                    let y1 = min(sh - 1, y0 + 1)
                    let wy = min(max(fy - Float(y0), 0), 1)
                    for xPix in 0..<w {
                        let fx = (Float(xPix) + 0.5) / Float(d) - 0.5
                        let x0 = min(sw - 1, max(0, Int(fx.rounded(.down))))
                        let x1 = min(sw - 1, x0 + 1)
                        let wx = min(max(fx - Float(x0), 0), 1)
                        let top = small[y0 * sw + x0] * (1 - wx) + small[y0 * sw + x1] * wx
                        let bot = small[y1 * sw + x0] * (1 - wx) + small[y1 * sw + x1] * wx
                        ob[yPix * w + xPix] = top * (1 - wy) + bot * wy
                    }
                }
            }
        }
        return out
    }

    // MARK: - Tile grid (plan finding F2: same integer edge grid as
    // BackgroundExtraction.tileSamples, y0 = ty*h/tiles ..., but with MAD sigma,
    // which tileSamples does not provide)

    struct TileGrid {
        let medians: [Float]      // tiles x tiles, row-major
        let sigmas: [Float]       // 1.4826 * MAD per tile
        let rowTile: [Int]        // pixel row -> tile row
        let colTile: [Int]        // pixel col -> tile col
    }

    static func tileGrid(_ a: [Float], width w: Int, height h: Int, tiles: Int) -> TileGrid {
        var medians = [Float](repeating: 0, count: tiles * tiles)
        var sigmas = [Float](repeating: 0, count: tiles * tiles)
        var rowTile = [Int](repeating: 0, count: h)
        var colTile = [Int](repeating: 0, count: w)
        for ty in 0..<tiles {
            for yy in (ty * h / tiles)..<((ty + 1) * h / tiles) { rowTile[yy] = ty }
        }
        for tx in 0..<tiles {
            for xx in (tx * w / tiles)..<((tx + 1) * w / tiles) { colTile[xx] = tx }
        }
        for ty in 0..<tiles { for tx in 0..<tiles {
            let y0 = ty * h / tiles, y1 = (ty + 1) * h / tiles
            let x0 = tx * w / tiles, x1 = (tx + 1) * w / tiles
            if y1 <= y0 || x1 <= x0 { continue }
            // Deterministic stride cap (AstroImage.sampleStride precedent): a full
            // sort of every pixel in 1024 tiles of a 26MP frame would blow the §4 budget.
            let count = (y1 - y0) * (x1 - x0)
            let strideStep = max(1, count / K.maxTileSamples)
            var vals: [Float] = []
            vals.reserveCapacity(count / strideStep + 1)
            var k = 0
            for yy in y0..<y1 { for xx in x0..<x1 {
                if k % strideStep == 0 { vals.append(a[yy * w + xx]) }
                k += 1
            } }
            vals.sort()
            let med = vals[vals.count / 2]
            var dev = vals.map { abs($0 - med) }
            dev.sort()
            medians[ty * tiles + tx] = med
            sigmas[ty * tiles + tx] = 1.4826 * dev[dev.count / 2]
        } }
        return TileGrid(medians: medians, sigmas: sigmas, rowTile: rowTile, colTile: colTile)
    }

    /// Upper median (sorted()[count/2]) — matches the codebase's median convention.
    static func median(_ a: [Float]) -> Float {
        var v = a; v.sort(); return v[v.count / 2]
    }

    /// Nearest-rank percentile (mirrors AutoStretch.neutralizeBackgroundAdditive's index).
    static func percentile(_ a: [Float], _ p: Double) -> Float {
        var v = a; v.sort()
        let idx = min(v.count - 1, max(0, Int((p / 100 * Double(v.count - 1)).rounded())))
        return v[idx]
    }
}
