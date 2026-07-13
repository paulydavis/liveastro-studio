import Foundation

public enum BayerPattern: String {
    case grbg = "GRBG"
    case rggb = "RGGB"
    case bggr = "BGGR"
    case gbrg = "GBRG"

    public init?(headerValue: String?) {
        guard let v = headerValue?.trimmingCharacters(in: .whitespaces).uppercased(),
              let p = BayerPattern(rawValue: v) else { return nil }
        self = p
    }

    /// Channel at CFA site (row % 2, col % 2): 0 = R, 1 = G, 2 = B.
    func channel(row: Int, col: Int) -> Int {
        switch self {
        case .grbg: return (row % 2 == 0) ? (col % 2 == 0 ? 1 : 0) : (col % 2 == 0 ? 2 : 1)
        case .rggb: return (row % 2 == 0) ? (col % 2 == 0 ? 0 : 1) : (col % 2 == 0 ? 1 : 2)
        case .bggr: return (row % 2 == 0) ? (col % 2 == 0 ? 2 : 1) : (col % 2 == 0 ? 1 : 0)
        case .gbrg: return (row % 2 == 0) ? (col % 2 == 0 ? 1 : 2) : (col % 2 == 0 ? 0 : 1)
        }
    }
}

/// Full-resolution bilinear demosaic (spec §3): mask-normalized 3×3 convolution,
/// exact at image edges because the kernel weight renormalizes with the mask.
public enum Debayer {
    public static func bilinear(cfa: AstroImage, pattern: BayerPattern,
                                minRows: Int = 64) -> AstroImage {
        precondition(cfa.channels == 1, "CFA input must be single-channel")
        let w = cfa.width, h = cfa.height, plane = w * h
        // K weights by (dy+1, dx+1); G kernel is the cross, R/B the full 3×3.
        let kG: [Float] = [0, 1, 0, 1, 4, 1, 0, 1, 0]
        let kRB: [Float] = [1, 2, 1, 2, 4, 2, 1, 2, 1]
        var out = [Float](repeating: 0, count: plane * 3)
        cfa.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { outBuf in
                Parallel.rows(h, minRows: minRows) { rows in
                    for y in rows {
                        for x in 0..<w {
                            for c in 0..<3 {
                                let k = c == 1 ? kG : kRB
                                var num: Float = 0, den: Float = 0
                                for dy in -1...1 {
                                    let yy = y + dy
                                    guard yy >= 0, yy < h else { continue }
                                    for dx in -1...1 {
                                        let xx = x + dx
                                        guard xx >= 0, xx < w else { continue }
                                        guard pattern.channel(row: yy, col: xx) == c else { continue }
                                        let kw = k[(dy + 1) * 3 + (dx + 1)]
                                        num += kw * src[yy * w + xx]
                                        den += kw
                                    }
                                }
                                outBuf[c * plane + y * w + x] = den > 0 ? num / den : 0
                            }
                        }
                    }
                }
            }
        }
        return AstroImage(width: w, height: h, channels: 3, pixels: out,
                          sourceIsLinear: cfa.sourceIsLinear)
    }

    // MARK: - RCD (Ratio Corrected Demosaicing)
    //
    // Faithful Swift port of Luis Sanz Rodríguez's RCD 2.3 from
    // librtprocess src/demosaic/rcd.cc, via the validated Python prototype
    // scratchpad/rcd_debayer.py.  Arithmetic is per-pixel translation of that
    // prototype; see its file header for documented deviations from rcd.cc.
    //
    // Interior = pixels with y ∈ [4, h-4) and x ∈ [4, w-4).
    // Outer 4-px border = copied from Debayer.bilinear.
    // Width < 8 or height < 8 → delegates to bilinear outright.
    public static func rcd(cfa: AstroImage, pattern: BayerPattern,
                            minRows: Int = 64) -> AstroImage {
        precondition(cfa.channels == 1, "CFA input must be single-channel")
        let w = cfa.width, h = cfa.height
        // Tiny frame: delegate to bilinear
        if w < 8 || h < 8 { return bilinear(cfa: cfa, pattern: pattern, minRows: minRows) }

        let plane = w * h
        let EPS: Float    = 1e-5
        let EPSSQ: Float  = 1e-10

        let src = cfa.pixels   // [Float] row-major, read-only

        // OOB-safe CFA read (zero-fill) used in pre-computation passes.
        // Interior pixels (y∈4..<h-4, x∈4..<w-4) can always index ±4 in-bounds,
        // so the hot path uses direct subscripting without this guard.
        @inline(__always)
        func gAt(_ y: Int, _ x: Int) -> Float {
            guard y >= 0, y < h, x >= 0, x < w else { return 0 }
            return src[y &* w &+ x]
        }
        @inline(__always) func sq(_ v: Float) -> Float { v * v }
        @inline(__always) func intp(_ p: Float, _ q: Float, _ r: Float) -> Float {
            p * q + (1.0 - p) * r
        }

        // ── Pre-compute whole-image scratch arrays (serial) ─────────────────────
        // vhpf / hhpf / phvpf / qhvpf: HPF² terms for the directional stats.
        // lpf: low-pass filter at every site.
        var vhpf  = [Float](repeating: 0, count: plane)
        var hhpf  = [Float](repeating: 0, count: plane)
        var phvpf = [Float](repeating: 0, count: plane)   // P-diagonal (NW-SE)
        var qhvpf = [Float](repeating: 0, count: plane)   // Q-diagonal (NE-SW)
        var lpf   = [Float](repeating: 0, count: plane)

        for y in 0..<h { for x in 0..<w {
            let v = gAt(y, x)
            let i = y * w + x
            vhpf[i]  = sq((gAt(y-3,x)-gAt(y-1,x)-gAt(y+1,x)+gAt(y+3,x))
                          - 3.0*(gAt(y-2,x)+gAt(y+2,x)) + 6.0*v)
            hhpf[i]  = sq((gAt(y,x-3)-gAt(y,x-1)-gAt(y,x+1)+gAt(y,x+3))
                          - 3.0*(gAt(y,x-2)+gAt(y,x+2)) + 6.0*v)
            phvpf[i] = sq((gAt(y-3,x-3)-gAt(y-1,x-1)-gAt(y+1,x+1)+gAt(y+3,x+3))
                          - 3.0*(gAt(y-2,x-2)+gAt(y+2,x+2)) + 6.0*v)
            qhvpf[i] = sq((gAt(y-3,x+3)-gAt(y-1,x+1)-gAt(y+1,x-1)+gAt(y+3,x-3))
                          - 3.0*(gAt(y-2,x+2)+gAt(y+2,x-2)) + 6.0*v)
            lpf[i]   = v
                     + 0.5*(gAt(y-1,x)+gAt(y+1,x)+gAt(y,x-1)+gAt(y,x+1))
                     + 0.25*(gAt(y-1,x-1)+gAt(y-1,x+1)+gAt(y+1,x-1)+gAt(y+1,x+1))
        }}

        // VH_Dir and PQ_Dir for the full image (only interior values are read in
        // the hot path, but neighbours of interior pixels are also needed).
        var VH_Dir = [Float](repeating: 0, count: plane)
        var PQ_Dir = [Float](repeating: 0, count: plane)
        for y in 1..<h-1 { for x in 1..<w-1 {
            let i  = y * w + x
            let vs = max(EPSSQ, vhpf[(y-1)*w+x] + vhpf[i] + vhpf[(y+1)*w+x])
            let hs = max(EPSSQ, hhpf[y*w+(x-1)] + hhpf[i] + hhpf[y*w+(x+1)])
            VH_Dir[i] = vs / (vs + hs)
            let ps = max(EPSSQ, phvpf[(y-1)*w+(x-1)] + phvpf[i] + phvpf[(y+1)*w+(x+1)])
            let qs = max(EPSSQ, qhvpf[(y-1)*w+(x+1)] + qhvpf[i] + qhvpf[(y+1)*w+(x-1)])
            PQ_Dir[i] = ps / (ps + qs)
        }}

        // ── Seed: rgbR = rgbG = rgbB = CFA (matches prototype's array seed) ─────
        var rgbR = src
        var rgbG = src
        var rgbB = src

        // ── Step 3: Green at R/B sites — whole image ─────────────────────────────
        // The Python prototype runs this on the full array so that G is populated
        // everywhere (including y/x < 4 and >= h-4).  Steps 4.2 and 4.3 read G
        // at ±2 offsets from the boundary of the interior, so we must fill the
        // full image here too.  Use gAt for stencil reads outside [4, h-4) / [4, w-4).
        for y in 0..<h { for x in 0..<w {
            let ch = pattern.channel(row: y, col: x)
            guard ch != 1 else { continue }          // skip green sites
            let i    = y * w + x
            let cfai = src[i]
            let lpfi = lpf[i]

            let N_Grad = EPS
                + abs(gAt(y-1,x) - gAt(y+1,x)) + abs(cfai - gAt(y-2,x))
                + abs(gAt(y-1,x) - gAt(y-3,x)) + abs(gAt(y-2,x) - gAt(y-4,x))
            let S_Grad = EPS
                + abs(gAt(y-1,x) - gAt(y+1,x)) + abs(cfai - gAt(y+2,x))
                + abs(gAt(y+1,x) - gAt(y+3,x)) + abs(gAt(y+2,x) - gAt(y+4,x))
            let W_Grad = EPS
                + abs(gAt(y,x-1) - gAt(y,x+1)) + abs(cfai - gAt(y,x-2))
                + abs(gAt(y,x-1) - gAt(y,x-3)) + abs(gAt(y,x-2) - gAt(y,x-4))
            let E_Grad = EPS
                + abs(gAt(y,x-1) - gAt(y,x+1)) + abs(cfai - gAt(y,x+2))
                + abs(gAt(y,x+1) - gAt(y,x+3)) + abs(gAt(y,x+2) - gAt(y,x+4))

            let lpfNi = y > 0 ? lpf[(y-1)*w+x] : lpfi
            let lpfSi = y < h-1 ? lpf[(y+1)*w+x] : lpfi
            let lpfWi = x > 0 ? lpf[y*w+(x-1)] : lpfi
            let lpfEi = x < w-1 ? lpf[y*w+(x+1)] : lpfi

            let N_Est = gAt(y-1,x) * (lpfi + lpfi) / (EPS + lpfi + lpfNi)
            let S_Est = gAt(y+1,x) * (lpfi + lpfi) / (EPS + lpfi + lpfSi)
            let W_Est = gAt(y,x-1) * (lpfi + lpfi) / (EPS + lpfi + lpfWi)
            let E_Est = gAt(y,x+1) * (lpfi + lpfi) / (EPS + lpfi + lpfEi)

            let V_Est = (S_Grad * N_Est + N_Grad * S_Est) / (N_Grad + S_Grad)
            let H_Est = (W_Grad * E_Est + E_Grad * W_Est) / (E_Grad + W_Grad)

            let VH_C = VH_Dir[i]
            let VH_N = 0.25 * (
                VH_Dir[max(0,y-1)*w + max(0,x-1)]
              + VH_Dir[max(0,y-1)*w + min(w-1,x+1)]
              + VH_Dir[min(h-1,y+1)*w + max(0,x-1)]
              + VH_Dir[min(h-1,y+1)*w + min(w-1,x+1)])
            let VH_D = abs(0.5 - VH_C) < abs(0.5 - VH_N) ? VH_N : VH_C
            rgbG[i] = intp(VH_D, H_Est, V_Est)
        }}

        // ── Step 4.2: R@B and B@R — whole image ──────────────────────────────────
        // Compute blue_at_r and red_at_b using the seeded rgbB/rgbR (= CFA).
        // The diagonal ±1 and ±3 neighbours of an R site are B or G sites (not
        // other R sites), and vice versa — so sequential order = vectorised order.
        // We must cover the full image so step 4.3's cardinal reads from the
        // interior boundary see the properly-updated R/B values.
        let G = rgbG   // snapshot: green now valid everywhere (including border)
        for y in 0..<h { for x in 0..<w {
            let ch = pattern.channel(row: y, col: x)
            guard ch != 1 else { continue }
            let i    = y * w + x

            let PQ_C = PQ_Dir[i]
            let PQ_N = 0.25 * (
                PQ_Dir[max(0,y-1)*w + max(0,x-1)]
              + PQ_Dir[max(0,y-1)*w + min(w-1,x+1)]
              + PQ_Dir[min(h-1,y+1)*w + max(0,x-1)]
              + PQ_Dir[min(h-1,y+1)*w + min(w-1,x+1)])
            let PQ_D = abs(0.5 - PQ_C) < abs(0.5 - PQ_N) ? PQ_N : PQ_C

            // _rb_at_rb(rgbc): diagonal color-difference estimates.
            func rbAtRB(_ rgbc: [Float]) -> Float {
                let NW = y>0 && x>0   ? rgbc[(y-1)*w+(x-1)] : 0
                let SE = y<h-1 && x<w-1 ? rgbc[(y+1)*w+(x+1)] : 0
                let NE = y>0 && x<w-1 ? rgbc[(y-1)*w+(x+1)] : 0
                let SW = y<h-1 && x>0 ? rgbc[(y+1)*w+(x-1)] : 0
                let NWG = y>0 && x>0   ? G[(y-1)*w+(x-1)] : 0
                let SEG = y<h-1 && x<w-1 ? G[(y+1)*w+(x+1)] : 0
                let NEG = y>0 && x<w-1 ? G[(y-1)*w+(x+1)] : 0
                let SWG = y<h-1 && x>0 ? G[(y+1)*w+(x-1)] : 0
                let gi  = G[i]
                let nw3 = y>=3 && x>=3 ? rgbc[(y-3)*w+(x-3)] : 0
                let ne3 = y>=3 && x<w-3 ? rgbc[(y-3)*w+(x+3)] : 0
                let sw3 = y<h-3 && x>=3 ? rgbc[(y+3)*w+(x-3)] : 0
                let se3 = y<h-3 && x<w-3 ? rgbc[(y+3)*w+(x+3)] : 0
                let g_nw2 = y>=2 && x>=2 ? G[(y-2)*w+(x-2)] : 0
                let g_ne2 = y>=2 && x<w-2 ? G[(y-2)*w+(x+2)] : 0
                let g_sw2 = y<h-2 && x>=2 ? G[(y+2)*w+(x-2)] : 0
                let g_se2 = y<h-2 && x<w-2 ? G[(y+2)*w+(x+2)] : 0
                let NW_Grad = EPS + abs(NW-SE) + abs(NW-nw3) + abs(gi-g_nw2)
                let NE_Grad = EPS + abs(NE-SW) + abs(NE-ne3) + abs(gi-g_ne2)
                let SW_Grad = EPS + abs(NE-SW) + abs(SW-sw3) + abs(gi-g_sw2)
                let SE_Grad = EPS + abs(NW-SE) + abs(SE-se3) + abs(gi-g_se2)
                let NW_Est = NW - NWG
                let NE_Est = NE - NEG
                let SW_Est = SW - SWG
                let SE_Est = SE - SEG
                let P_Est = (NW_Grad * SE_Est + SE_Grad * NW_Est) / (NW_Grad + SE_Grad)
                let Q_Est = (NE_Grad * SW_Est + SW_Grad * NE_Est) / (NE_Grad + SW_Grad)
                return gi + intp(PQ_D, Q_Est, P_Est)
            }
            if ch == 0 {
                rgbB[i] = rbAtRB(rgbB)
            } else {
                rgbR[i] = rbAtRB(rgbR)
            }
        }}

        // ── Step 4.3: R@G and B@G — whole image ──────────────────────────────────
        let G2 = rgbG  // green unchanged since step 3
        for y in 0..<h { for x in 0..<w {
            let ch = pattern.channel(row: y, col: x)
            guard ch == 1 else { continue }
            let i = y * w + x

            let VH_C = VH_Dir[i]
            let VH_N = 0.25 * (
                VH_Dir[max(0,y-1)*w + max(0,x-1)]
              + VH_Dir[max(0,y-1)*w + min(w-1,x+1)]
              + VH_Dir[min(h-1,y+1)*w + max(0,x-1)]
              + VH_Dir[min(h-1,y+1)*w + min(w-1,x+1)])
            let VH_D = abs(0.5 - VH_C) < abs(0.5 - VH_N) ? VH_N : VH_C

            let rgb1 = G2[i]
            let N1   = EPS + abs(rgb1 - (y>=2 ? G2[(y-2)*w+x] : rgb1))
            let S1   = EPS + abs(rgb1 - (y<h-2 ? G2[(y+2)*w+x] : rgb1))
            let W1   = EPS + abs(rgb1 - (x>=2 ? G2[y*w+(x-2)] : rgb1))
            let E1   = EPS + abs(rgb1 - (x<w-2 ? G2[y*w+(x+2)] : rgb1))
            let rgb1mw1 = y>0   ? G2[(y-1)*w+x] : rgb1
            let rgb1pw1 = y<h-1 ? G2[(y+1)*w+x] : rgb1
            let rgb1m1  = x>0   ? G2[y*w+(x-1)] : rgb1
            let rgb1p1  = x<w-1 ? G2[y*w+(x+1)] : rgb1

            func cAtG(_ rgbc: [Float]) -> Float {
                let rN = y>0 ? rgbc[(y-1)*w+x] : 0
                let rS = y<h-1 ? rgbc[(y+1)*w+x] : 0
                let rW = x>0 ? rgbc[y*w+(x-1)] : 0
                let rE = x<w-1 ? rgbc[y*w+(x+1)] : 0
                let rN3 = y>=3 ? rgbc[(y-3)*w+x] : 0
                let rS3 = y<h-3 ? rgbc[(y+3)*w+x] : 0
                let rW3 = x>=3 ? rgbc[y*w+(x-3)] : 0
                let rE3 = x<w-3 ? rgbc[y*w+(x+3)] : 0
                let SNabs = abs(rN - rS)
                let EWabs = abs(rW - rE)
                let N_Grad = N1 + SNabs + abs(rN - rN3)
                let S_Grad = S1 + SNabs + abs(rS - rS3)
                let W_Grad = W1 + EWabs + abs(rW - rW3)
                let E_Grad = E1 + EWabs + abs(rE - rE3)
                let N_Est = rN - rgb1mw1
                let S_Est = rS - rgb1pw1
                let W_Est = rW - rgb1m1
                let E_Est = rE - rgb1p1
                let V_Est = (N_Grad * S_Est + S_Grad * N_Est) / (N_Grad + S_Grad)
                let H_Est = (E_Grad * W_Est + W_Grad * E_Est) / (E_Grad + W_Grad)
                return rgb1 + intp(VH_D, H_Est, V_Est)
            }
            rgbR[i] = cAtG(rgbR)
            rgbB[i] = cAtG(rgbB)
        }}

        // ── Build output: bilinear border + parallel RCD interior ────────────────
        // Start from bilinear (covers the border); overwrite interior with RCD.
        var out = bilinear(cfa: cfa, pattern: pattern, minRows: minRows).pixels
        out.withUnsafeMutableBufferPointer { outBuf in
            Parallel.rows(h, minRows: minRows) { rows in
                for y in rows {
                    guard y >= 4 && y < h - 4 else { continue }
                    for x in 4..<w-4 {
                        let i = y * w + x
                        outBuf[          i] = max(0.0, min(1.0, rgbR[i]))
                        outBuf[plane   + i] = max(0.0, min(1.0, rgbG[i]))
                        outBuf[2*plane + i] = max(0.0, min(1.0, rgbB[i]))
                    }
                }
            }
        }
        return AstroImage(width: w, height: h, channels: 3, pixels: out,
                          sourceIsLinear: cfa.sourceIsLinear)
    }
}
