import Foundation

/// Flattens a smooth background gradient (light-pollution ramp) by fitting a
/// per-channel low-order 2D polynomial to sky-tile samples and subtracting it.
/// Display-path only — never applied to the linear master. Conservative: a
/// degree-1/2 polynomial can only model a smooth ramp/bowl, so it cannot
/// subtract a non-smooth nebula. Returns the image UNCHANGED on any condition
/// that makes a fit unsafe (see guards).
public enum BackgroundExtraction {
    public static func flatten(_ image: AstroImage, degree: Int,
                               tilesPerAxis: Int = 32,
                               rejectionSigma: Double = 2.0) -> AstroImage {
        guard image.channels == 3 else { return image }        // mono display path unchanged
        let deg = min(max(degree, 1), 2)
        let nCoeff = deg == 1 ? 3 : 6
        let w = image.width, h = image.height, plane = w * h
        let tiles = max(1, tilesPerAxis)

        // Polynomial basis at normalized coords x,y ∈ [-1,1].
        func basis(_ x: Double, _ y: Double) -> [Double] {
            deg == 1 ? [1, x, y] : [1, x, y, x*x, x*y, y*y]
        }

        // Sanitize non-finite inputs up front (matches ingest: FITSReader/Calibrator).
        // A NaN/Inf pixel otherwise poisons tile medians (Swift sort of NaN is
        // undefined-order) and the output (min/max don't clamp NaN). Passthrough
        // channels then also carry clean data.
        let src = image.pixels.map { $0.isFinite ? $0 : Float(0) }
        var out = src
        for c in 0..<3 {
            let base = c * plane
            // 1. tile samples: (nx, ny, median)
            var sx: [Double] = [], sy: [Double] = [], sv: [Double] = []
            sx.reserveCapacity(tiles*tiles); sy.reserveCapacity(tiles*tiles); sv.reserveCapacity(tiles*tiles)
            for ty in 0..<tiles {
                let y0 = ty * h / tiles, y1 = (ty + 1) * h / tiles
                if y1 <= y0 { continue }
                for tx in 0..<tiles {
                    let x0 = tx * w / tiles, x1 = (tx + 1) * w / tiles
                    if x1 <= x0 { continue }
                    var vals: [Float] = []; vals.reserveCapacity((y1-y0)*(x1-x0))
                    for yy in y0..<y1 { for xx in x0..<x1 { vals.append(src[base + yy*w + xx]) } }
                    vals.sort()
                    let med = Double(vals[vals.count/2])
                    let cx = (Double(x0 + x1) / 2) / Double(w) * 2 - 1   // → [-1,1]
                    let cy = (Double(y0 + y1) / 2) / Double(h) * 2 - 1
                    sx.append(cx); sy.append(cy); sv.append(med)
                }
            }
            // 2. sigma-clip bright tiles (nebula/stars) out of the sky set.
            var keep = [Bool](repeating: true, count: sv.count)
            for _ in 0..<3 {
                let kept = sv.enumerated().filter { keep[$0.offset] }.map { $0.element }
                if kept.count <= nCoeff { break }
                let sorted = kept.sorted()
                let med = sorted[sorted.count/2]
                var dev = sorted.map { abs($0 - med) }; dev.sort()
                let madn = 1.4826 * dev[dev.count/2]
                if madn <= 1e-12 { break }
                let hiCut = med + rejectionSigma * madn
                var changed = false
                for i in 0..<sv.count where keep[i] && sv[i] > hiCut { keep[i] = false; changed = true }
                if !changed { break }
            }
            let idx = (0..<sv.count).filter { keep[$0] }
            guard idx.count >= nCoeff else { continue }        // too few sky tiles → passthrough this channel

            // 3. least-squares normal equations AᵀA c = Aᵀb over kept tiles.
            var ata = [[Double]](repeating: [Double](repeating: 0, count: nCoeff), count: nCoeff)
            var atb = [Double](repeating: 0, count: nCoeff)
            for i in idx {
                let b = basis(sx[i], sy[i]); let v = sv[i]
                for r in 0..<nCoeff { atb[r] += b[r] * v; for col in 0..<nCoeff { ata[r][col] += b[r] * b[col] } }
            }
            guard let coeff = solveSymmetric(&ata, atb) else { continue }  // singular → passthrough channel
            // Defense-in-depth: a non-finite fit (e.g. a NaN slipping past ingest
            // sanitization) must not poison the surface — passthrough this channel.
            guard coeff.allSatisfy({ $0.isFinite }) else { continue }

            // 4. evaluate surface, find pedestal (min), subtract + re-add pedestal.
            var surface = [Float](repeating: 0, count: plane)
            var minS = Double.greatestFiniteMagnitude
            for yy in 0..<h {
                let ny = Double(yy) / Double(h) * 2 - 1
                for xx in 0..<w {
                    let nx = Double(xx) / Double(w) * 2 - 1
                    let bb = basis(nx, ny)
                    var s = 0.0; for r in 0..<nCoeff { s += coeff[r] * bb[r] }
                    surface[yy*w + xx] = Float(s); if s < minS { minS = s }
                }
            }
            let ped = Float(minS)
            for i in 0..<plane {
                out[base + i] = min(max(src[base + i] - surface[i] + ped, 0), 1)
            }
        }
        return AstroImage(width: w, height: h, channels: image.channels, pixels: out,
                          sourceIsLinear: image.sourceIsLinear)
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
