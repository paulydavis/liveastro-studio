import Foundation

/// Flattens a smooth background gradient (light-pollution ramp) by fitting a
/// per-channel low-order 2D polynomial to sky-tile samples and subtracting it.
/// Display-path only — never applied to the linear master. Conservative: a
/// degree-1/2 polynomial can only model a smooth ramp/bowl, so it cannot
/// subtract a non-smooth nebula. Returns the image UNCHANGED on any condition
/// that makes a fit unsafe (see guards).
public enum BackgroundExtraction {

    /// A fitted per-channel low-order polynomial background (degree 1 or 2).
    /// `coeffPerChannel[c] == nil` means that channel could not be fit (too few
    /// sky tiles or singular) — callers treat it as passthrough.
    public struct BackgroundModel {
        public let degree: Int
        public let width: Int
        public let height: Int
        public let coeffPerChannel: [[Double]?]

        /// Raw polynomial surface for one channel (no pedestal), or nil if unfit.
        public func rawSurface(channel: Int) -> [Float]? {
            guard channel < coeffPerChannel.count, let c = coeffPerChannel[channel] else { return nil }
            return BackgroundModel.evaluate(coeff: c, degree: degree, width: width, height: height)
        }

        /// Evaluate a coefficient vector over a width×height grid at normalized
        /// coords x,y ∈ [-1,1] (SAME mapping as flatten: coord/dim*2 − 1).
        ///
        /// PRECONDITION: `coeff.count` must match the basis length for the clamped
        /// degree (3 for degree 1, 6 for degree 2). A mismatch (e.g. a 3-coeff vector
        /// evaluated at degree 2) would otherwise index `coeff[r]` out of bounds and
        /// trap raw (exit 133); the precondition turns that into a diagnosable
        /// contract failure at the public boundary (rawSurface / GradientLeveler).
        public static func evaluate(coeff: [Double], degree: Int, width w: Int, height h: Int) -> [Float] {
            let deg = min(max(degree, 1), 2)
            precondition(coeff.count == (deg == 1 ? 3 : 6), "coeff count must match degree basis")
            var surface = [Float](repeating: 0, count: w * h)
            for yy in 0..<h {
                let ny = Double(yy) / Double(h) * 2 - 1
                for xx in 0..<w {
                    let nx = Double(xx) / Double(w) * 2 - 1
                    let bb: [Double] = deg == 1 ? [1, nx, ny] : [1, nx, ny, nx*nx, nx*ny, ny*ny]
                    var s = 0.0; for r in 0..<bb.count { s += coeff[r] * bb[r] }
                    surface[yy*w + xx] = Float(s)
                }
            }
            return surface
        }
    }

    /// Minimum fraction of covered pixels a tile must have to be included when a
    /// mask is supplied. Partial border tiles at a looser gate bias the degree-2
    /// quadratic terms; 0.75 matches the R1 prototype threshold.
    static let minTileCoverage: Float = 0.75

    /// Per-channel tile median samples on the SHARED 32×tile grid (stage 1 of the fit,
    /// split out so two frames can be fit over the SAME masked tile subset — the R5
    /// domain-matched-fit fix). `x`/`y` are normalized tile centers (coord/dim*2 − 1),
    /// shared across channels and in a fixed order (the same `y1<=y0`/`x1<=x0` skips as
    /// the legacy path). `v[c]` is the per-channel tile median array, or `nil` for the
    /// non-3-channel case (mirrors the legacy channels==3 special case). The arrays are
    /// index-aligned: sample `i` has center `(x[i], y[i])` and channel-`c` value `v[c]![i]`.
    ///
    /// NaN/Inf are sanitized to 0 up front (same as the legacy path).
    public static func tileSamples(_ image: AstroImage,
                                   tilesPerAxis: Int = 32)
        -> (x: [Double], y: [Double], v: [[Double]?]) {
        let w = image.width, h = image.height, plane = w * h
        let tiles = max(1, tilesPerAxis)
        var sx: [Double] = [], sy: [Double] = []
        sx.reserveCapacity(tiles*tiles); sy.reserveCapacity(tiles*tiles)
        // First pass: build the shared tile grid (centers + pixel ranges), in legacy order.
        var ranges: [(x0: Int, x1: Int, y0: Int, y1: Int)] = []
        ranges.reserveCapacity(tiles*tiles)
        for ty in 0..<tiles {
            let y0 = ty * h / tiles, y1 = (ty + 1) * h / tiles
            if y1 <= y0 { continue }
            for tx in 0..<tiles {
                let x0 = tx * w / tiles, x1 = (tx + 1) * w / tiles
                if x1 <= x0 { continue }
                sx.append((Double(x0 + x1) / 2) / Double(w) * 2 - 1)
                sy.append((Double(y0 + y1) / 2) / Double(h) * 2 - 1)
                ranges.append((x0, x1, y0, y1))
            }
        }
        guard image.channels == 3 else {
            return (sx, sy, Array(repeating: nil, count: image.channels))
        }
        let src = image.pixels.map { $0.isFinite ? $0 : Float(0) }
        var v = [[Double]?](repeating: nil, count: 3)
        for c in 0..<3 {
            let base = c * plane
            var sv: [Double] = []; sv.reserveCapacity(ranges.count)
            for r in ranges {
                var vals: [Float] = []; vals.reserveCapacity((r.y1-r.y0)*(r.x1-r.x0))
                for yy in r.y0..<r.y1 { for xx in r.x0..<r.x1 { vals.append(src[base + yy*w + xx]) } }
                vals.sort()
                sv.append(Double(vals[vals.count/2]))
            }
            v[c] = sv
        }
        return (sx, sy, v)
    }

    /// Indices (into the `tileSamples` arrays) of tiles whose covered fraction over
    /// their pixel range is ≥ `minTileCoverage`. Rebuilds the SAME tile grid/order as
    /// `tileSamples`, so the returned indices select the same subset in both a sub's and
    /// the reference's sample arrays — the shared domain the R5 fix requires.
    ///
    /// PRECONDITION: `mask.count == width * height`. Mask values are expected binary
    /// (Warp-produced coverage: 1 = covered, 0 = outside); a value > 0 counts as covered.
    /// A NaN is not > 0, so it counts as UNCOVERED.
    public static func maskGatedTileIndices(width w: Int, height h: Int,
                                            tilesPerAxis: Int = 32,
                                            mask: [Float]) -> [Int] {
        precondition(mask.count == w * h, "mask must have one value per pixel")
        let tiles = max(1, tilesPerAxis)
        var included: [Int] = []
        var idx = 0
        for ty in 0..<tiles {
            let y0 = ty * h / tiles, y1 = (ty + 1) * h / tiles
            if y1 <= y0 { continue }
            for tx in 0..<tiles {
                let x0 = tx * w / tiles, x1 = (tx + 1) * w / tiles
                if x1 <= x0 { continue }
                var covered: Float = 0
                let tileCount = Float((y1 - y0) * (x1 - x0))
                for yy in y0..<y1 { for xx in x0..<x1 {
                    if mask[yy * w + xx] > 0 { covered += 1 }
                } }
                if tileCount != 0 && covered / tileCount >= minTileCoverage { included.append(idx) }
                idx += 1
            }
        }
        return included
    }

    /// Stage-2 solve: σ-clip bright tiles (high-side MAD, 3 iterations) then least-squares
    /// over the given samples. `x`/`y`/`v` must be index-aligned (a subset of `tileSamples`).
    /// Returns `nil` on failure (too few kept samples, singular system, or non-finite
    /// coeffs) — exactly the legacy passthrough behaviour.
    public static func solveModel(x: [Double], y: [Double], v: [Double],
                                  degree: Int, rejectionSigma: Double = 2.0) -> [Double]? {
        let deg = min(max(degree, 1), 2)
        let nCoeff = deg == 1 ? 3 : 6
        func basis(_ x: Double, _ y: Double) -> [Double] { deg == 1 ? [1, x, y] : [1, x, y, x*x, x*y, y*y] }
        let sv = v
        var keep = [Bool](repeating: true, count: sv.count)
        for _ in 0..<3 {
            let kept = sv.enumerated().filter { keep[$0.offset] }.map { $0.element }
            if kept.count <= nCoeff { break }
            let sorted = kept.sorted(); let med = sorted[sorted.count/2]
            var dev = sorted.map { abs($0 - med) }; dev.sort()
            let madn = 1.4826 * dev[dev.count/2]
            if madn <= 1e-12 { break }
            let hiCut = med + rejectionSigma * madn
            var changed = false
            for i in 0..<sv.count where keep[i] && sv[i] > hiCut { keep[i] = false; changed = true }
            if !changed { break }
        }
        let idx = (0..<sv.count).filter { keep[$0] }
        guard idx.count >= nCoeff else { return nil }
        var ata = [[Double]](repeating: [Double](repeating: 0, count: nCoeff), count: nCoeff)
        var atb = [Double](repeating: 0, count: nCoeff)
        for i in idx {
            let b = basis(x[i], y[i]); let vv = sv[i]
            for r in 0..<nCoeff { atb[r] += b[r] * vv; for col in 0..<nCoeff { ata[r][col] += b[r] * b[col] } }
        }
        guard let coeff = solveSymmetric(&ata, atb), coeff.allSatisfy({ $0.isFinite }) else { return nil }
        return coeff
    }

    /// Fit a per-channel low-order polynomial background (steps 1–3 of flatten):
    /// tile medians → σ-clip bright tiles → least-squares. 3-channel only (others
    /// get all-nil coeffs). Deterministic; NaN/Inf sanitized up front. Reimplemented
    /// on top of `tileSamples` / `maskGatedTileIndices` / `solveModel` (R5) — behaviour
    /// is UNCHANGED (byte-identical to the pre-R5 path, including the mask-nil case).
    ///
    /// - Parameter mask: optional coverage mask of length `w*h` (1 = covered, 0 = outside).
    ///   A tile is included only when its covered fraction ≥ `minTileCoverage`.
    ///   When `nil`, all tiles are included — behaviour is EXACTLY as before
    ///   (flatten's byte-identity depends on this).
    ///   PRECONDITION (non-nil mask): `mask.count == w*h`. Mask values are expected
    ///   binary (Warp-produced); a NaN counts as uncovered.
    public static func fitBackground(_ image: AstroImage, degree: Int,
                                     tilesPerAxis: Int = 32,
                                     rejectionSigma: Double = 2.0,
                                     mask: [Float]? = nil) -> BackgroundModel {
        let w = image.width, h = image.height
        let deg = min(max(degree, 1), 2)
        guard image.channels == 3 else {
            return BackgroundModel(degree: deg, width: w, height: h,
                                   coeffPerChannel: Array(repeating: nil, count: image.channels))
        }
        let samples = tileSamples(image, tilesPerAxis: tilesPerAxis)
        // Optional mask gate → selected tile indices. mask: nil → all tiles (legacy path).
        let selected: [Int]
        if let mask = mask {
            precondition(mask.count == w * h, "mask must have one value per pixel")
            selected = maskGatedTileIndices(width: w, height: h, tilesPerAxis: tilesPerAxis, mask: mask)
        } else {
            selected = Array(0..<samples.x.count)
        }
        let sx = selected.map { samples.x[$0] }
        let sy = selected.map { samples.y[$0] }
        var coeffs = [[Double]?](repeating: nil, count: 3)
        for c in 0..<3 {
            guard let chan = samples.v[c] else { continue }
            let sv = selected.map { chan[$0] }
            coeffs[c] = solveModel(x: sx, y: sy, v: sv, degree: deg, rejectionSigma: rejectionSigma)
        }
        return BackgroundModel(degree: deg, width: w, height: h, coeffPerChannel: coeffs)
    }

    public static func flatten(_ image: AstroImage, degree: Int,
                               tilesPerAxis: Int = 32,
                               rejectionSigma: Double = 2.0) -> AstroImage {
        guard image.channels == 3 else { return image }
        let w = image.width, h = image.height, plane = w * h
        let model = fitBackground(image, degree: degree, tilesPerAxis: tilesPerAxis, rejectionSigma: rejectionSigma)
        let src = image.pixels.map { $0.isFinite ? $0 : Float(0) }
        var out = src
        for c in 0..<3 {
            guard let surface = model.rawSurface(channel: c) else { continue }   // passthrough this channel
            let base = c * plane
            let ped = surface.min() ?? 0
            for i in 0..<plane { out[base + i] = min(max(src[base + i] - surface[i] + ped, 0), 1) }
        }
        return AstroImage(width: w, height: h, channels: image.channels, pixels: out, sourceIsLinear: image.sourceIsLinear)
    }

    /// Spatially-varying, structure-protected background model (DBE v3 primary).
    /// Iteratively smooths at the `scale` radius, rejects+inpaints structure, then
    /// subtracts the model. Follows LOCAL/corner gradients a low-order polynomial
    /// cannot. Multiscale is the sole model; polynomial `flatten` is retained for
    /// direct use. Display-path only; deterministic. `scale` is % of image size;
    /// `smoothest` is the final blur strength.
    public static func flattenMultiscale(_ image: AstroImage,
                                         scale: Double, smoothest: Double) -> AstroImage {
        guard image.channels == 3 else { return image }               // mono passthrough
        let w = image.width, h = image.height, plane = w * h
        guard w >= 8, h >= 8 else { return image }
        let src = image.pixels.map { $0.isFinite ? $0 : Float(0) }     // ingest sanitize

        // Task-1 validated constants (starting values):
        let D = 4                       // downsample factor
        let maxIters = 5
        let k: Float = 3.0              // structure rejection sigma
        let grow = 2                    // mask grow (downsampled px)

        let sw = max(2, w / D), sh = max(2, h / D)
        let scaleRadius = max(1, Int((scale / 100.0) * Double(max(sw, sh))))

        var out = src
        var perChannelModelUp = [[Float]](repeating: [], count: 3)

        for c in 0..<3 {
            let base = c * plane
            // 1. downsample (block-average) into a small buffer
            var small = [Float](repeating: 0, count: sw * sh)
            for j in 0..<sh { for i in 0..<sw {
                var s: Float = 0; var n: Float = 0
                for dy in 0..<D { for dx in 0..<D {
                    let yy = j*D + dy, xx = i*D + dx
                    if yy < h && xx < w { s += src[base + yy*w + xx]; n += 1 }
                } }
                small[j*sw + i] = n > 0 ? s / n : 0
            } }
            // 2. iterate smooth → reject → inpaint
            var work = small
            for _ in 0..<maxIters {
                // Triple box blur ≈ Gaussian (box³ → Gaussian by CLT) — approximates the prototype's scipy gaussian_filter without changing the validated constants.
                var bg = boxBlur(work, sw, sh, radius: scaleRadius)
                bg = boxBlur(bg, sw, sh, radius: scaleRadius)
                bg = boxBlur(bg, sw, sh, radius: scaleRadius)
                var resid = [Float](repeating: 0, count: sw*sh)
                for idx in 0..<resid.count { resid[idx] = work[idx] - bg[idx] }
                let s = madSigma(resid)
                var mask = [Bool](repeating: false, count: sw*sh)
                for idx in 0..<mask.count where resid[idx] > k * s { mask[idx] = true }
                mask = dilate(mask, sw, sh, iterations: grow)
                for idx in 0..<work.count where mask[idx] { work[idx] = bg[idx] }
            }
            var bg = boxBlur(work, sw, sh, radius: scaleRadius)
            bg = boxBlur(bg, sw, sh, radius: scaleRadius)
            bg = boxBlur(bg, sw, sh, radius: scaleRadius)
            if smoothest > 0 {
                let sr = max(1, Int(Double(scaleRadius) * 0.5 * smoothest))
                bg = boxBlur(bg, sw, sh, radius: sr)
                bg = boxBlur(bg, sw, sh, radius: sr)
                bg = boxBlur(bg, sw, sh, radius: sr)
            }
            // 3. upsample (block replicate) to full res
            var up = [Float](repeating: 0, count: plane)
            for y in 0..<h { for x in 0..<w {
                up[y*w + x] = bg[min(sh-1, y/D)*sw + min(sw-1, x/D)]
            } }
            perChannelModelUp[c] = up
        }

        // 4. subtract with clamp-safe pedestal re-add
        for c in 0..<3 {
            let base = c * plane
            let up = perChannelModelUp[c]
            var minM: Float = .greatestFiniteMagnitude
            for v in up where v < minM { minM = v }
            for i in 0..<plane { out[base + i] = min(max(src[base + i] - up[i] + minM, 0), 1) }
        }
        return AstroImage(width: w, height: h, channels: 3, pixels: out,
                          sourceIsLinear: image.sourceIsLinear)
    }

    /// Separable box blur (deterministic). radius r → (2r+1) window, clamped edges.
    static func boxBlur(_ a: [Float], _ w: Int, _ h: Int, radius r: Int) -> [Float] {
        if r < 1 { return a }
        var tmp = [Float](repeating: 0, count: w*h)
        let inv = 1.0 / Float(2*r + 1)
        for y in 0..<h {                                  // horizontal
            for x in 0..<w {
                var s: Float = 0
                for dx in -r...r { s += a[y*w + min(w-1, max(0, x+dx))] }
                tmp[y*w + x] = s * inv
            }
        }
        var outb = [Float](repeating: 0, count: w*h)
        for x in 0..<w {                                  // vertical
            for y in 0..<h {
                var s: Float = 0
                for dy in -r...r { s += tmp[min(h-1, max(0, y+dy))*w + x] }
                outb[y*w + x] = s * inv
            }
        }
        return outb
    }

    /// Normalized MAD sigma of a residual buffer.
    static func madSigma(_ a: [Float]) -> Float {
        var v = a; v.sort()
        let med = v[v.count/2]
        var dev = a.map { abs($0 - med) }; dev.sort()
        return 1.4826 * dev[dev.count/2] + 1e-6
    }

    /// Binary dilation by `iterations` (4-neighbour).
    static func dilate(_ m: [Bool], _ w: Int, _ h: Int, iterations: Int) -> [Bool] {
        if iterations < 1 { return m }
        var cur = m
        for _ in 0..<iterations {
            var next = cur
            for y in 0..<h { for x in 0..<w where !cur[y*w+x] {
                if (x>0 && cur[y*w+x-1]) || (x<w-1 && cur[y*w+x+1]) ||
                   (y>0 && cur[(y-1)*w+x]) || (y<h-1 && cur[(y+1)*w+x]) { next[y*w+x] = true }
            } }
            cur = next
        }
        return cur
    }

    /// Solve an n×n symmetric system in place via Gaussian elimination with
    /// partial pivoting. Returns nil if singular / ill-conditioned.
    static func solveSymmetric(_ a: inout [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        var m = a, y = b
        for col in 0..<n {
            var piv = col
            for r in (col+1)..<n where abs(m[r][col]) > abs(m[piv][col]) { piv = r }
            if abs(m[piv][col]) < 1e-12 { return nil }
            if piv != col { m.swapAt(piv, col); y.swapAt(piv, col) }
            for r in (col+1)..<n {
                let f = m[r][col] / m[col][col]
                if f == 0 { continue }
                for k in col..<n { m[r][k] -= f * m[col][k] }
                y[r] -= f * y[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n-1, through: 0, by: -1) {
            var s = y[r]; for k in (r+1)..<n { s -= m[r][k] * x[k] }
            x[r] = s / m[r][r]
        }
        return x
    }
}
