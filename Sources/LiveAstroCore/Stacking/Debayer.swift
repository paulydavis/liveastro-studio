import Foundation

/// Demosaic algorithm selection.
public enum DemosaicMethod: String, Codable, CaseIterable {
    /// Classic bilinear interpolation — fast, byte-identical to the engine's legacy
    /// behaviour. Default for `StackEngine` so all existing tests remain unaffected.
    case bilinear
    /// RCD (Ratio Corrected Demosaicing) — sharper star cores, less colour fringe.
    /// Default in the app via `AppModel`.
    case rcd
}

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

        // Wrap entire algorithm body in withUnsafeBufferPointer so that all
        // concurrent closures see an UnsafeBufferPointer<Float> (a value type)
        // rather than the Swift Array itself. Swift's exclusivity runtime can
        // serialise concurrent reads through a [Float] subscript; UBP has no
        // such restriction and allows true data-race-free parallel reads.
        var rgbR: [Float] = []
        var rgbG: [Float] = []
        var rgbB: [Float] = []
        var out:  [Float] = []
        var vhpf  = [Float](repeating: 0, count: plane)
        var hhpf  = [Float](repeating: 0, count: plane)
        var phvpf = [Float](repeating: 0, count: plane)   // P-diagonal (NW-SE)
        var qhvpf = [Float](repeating: 0, count: plane)   // Q-diagonal (NE-SW)
        var lpf   = [Float](repeating: 0, count: plane)
        var VH_Dir = [Float](repeating: 0, count: plane)
        var PQ_Dir = [Float](repeating: 0, count: plane)

        cfa.pixels.withUnsafeBufferPointer { srcBuf in

        // srcBuf: UnsafeBufferPointer<Float> — value type, safe to copy into parallel
        // closures for concurrent read-only access. Each Parallel.rows body defines
        // its own local gAt so the compiler can inline it directly at each call site.

        @inline(__always) func sq(_ v: Float) -> Float { v * v }
        @inline(__always) func intp(_ p: Float, _ q: Float, _ r: Float) -> Float {
            p * q + (1.0 - p) * r
        }

        // ── Pre-compute whole-image scratch arrays (parallel) ───────────────────
        // vhpf / hhpf / phvpf / qhvpf: HPF² terms for the directional stats.
        // lpf: low-pass filter at every site.
        // Each element reads only from `srcBuf` (UBP, immutable), so rows are
        // independent and the band decomposition is byte-identical to a serial loop.
        // gAt is defined INSIDE each Parallel body so @inline(__always) applies
        // at the actual call site rather than through a captured closure reference.
        vhpf.withUnsafeMutableBufferPointer { vhpfBuf in
        hhpf.withUnsafeMutableBufferPointer { hhpfBuf in
        phvpf.withUnsafeMutableBufferPointer { phvpfBuf in
        qhvpf.withUnsafeMutableBufferPointer { qhvpfBuf in
        lpf.withUnsafeMutableBufferPointer { lpfBuf in
            Parallel.rows(h, minRows: minRows) { rows in
                // gAt defined locally so it can be inlined at each call site.
                @inline(__always)
                func gAt(_ y: Int, _ x: Int) -> Float {
                    guard y >= 0, y < h, x >= 0, x < w else { return 0 }
                    return srcBuf[y &* w &+ x]
                }
                for y in rows { for x in 0..<w {
                    let v = gAt(y, x)
                    let i = y * w + x
                    vhpfBuf[i]  = sq((gAt(y-3,x)-gAt(y-1,x)-gAt(y+1,x)+gAt(y+3,x))
                                      - 3.0*(gAt(y-2,x)+gAt(y+2,x)) + 6.0*v)
                    hhpfBuf[i]  = sq((gAt(y,x-3)-gAt(y,x-1)-gAt(y,x+1)+gAt(y,x+3))
                                      - 3.0*(gAt(y,x-2)+gAt(y,x+2)) + 6.0*v)
                    phvpfBuf[i] = sq((gAt(y-3,x-3)-gAt(y-1,x-1)-gAt(y+1,x+1)+gAt(y+3,x+3))
                                      - 3.0*(gAt(y-2,x-2)+gAt(y+2,x+2)) + 6.0*v)
                    qhvpfBuf[i] = sq((gAt(y-3,x+3)-gAt(y-1,x+1)-gAt(y+1,x-1)+gAt(y+3,x-3))
                                      - 3.0*(gAt(y-2,x+2)+gAt(y+2,x-2)) + 6.0*v)
                    lpfBuf[i]   = v
                                 + 0.5*(gAt(y-1,x)+gAt(y+1,x)+gAt(y,x-1)+gAt(y,x+1))
                                 + 0.25*(gAt(y-1,x-1)+gAt(y-1,x+1)+gAt(y+1,x-1)+gAt(y+1,x+1))
                }}
            }
        }}}}}

        // VH_Dir and PQ_Dir for the full image (only interior values are read in
        // the hot path, but neighbours of interior pixels are also needed).
        // Each element reads only from the already-complete vhpf/hhpf/phvpf/qhvpf
        // arrays — rows are independent and the result is byte-identical to serial.
        vhpf.withUnsafeBufferPointer { vhpfBuf in
        hhpf.withUnsafeBufferPointer { hhpfBuf in
        phvpf.withUnsafeBufferPointer { phvpfBuf in
        qhvpf.withUnsafeBufferPointer { qhvpfBuf in
        VH_Dir.withUnsafeMutableBufferPointer { vhDirBuf in
        PQ_Dir.withUnsafeMutableBufferPointer { pqDirBuf in
            Parallel.rows(h - 2, minRows: minRows) { rows in
                for y in rows.lowerBound + 1 ..< rows.upperBound + 1 {
                    for x in 1..<w-1 {
                        let i  = y * w + x
                        let vs = max(EPSSQ, vhpfBuf[(y-1)*w+x] + vhpfBuf[i] + vhpfBuf[(y+1)*w+x])
                        let hs = max(EPSSQ, hhpfBuf[y*w+(x-1)] + hhpfBuf[i] + hhpfBuf[y*w+(x+1)])
                        vhDirBuf[i] = vs / (vs + hs)
                        let ps = max(EPSSQ, phvpfBuf[(y-1)*w+(x-1)] + phvpfBuf[i] + phvpfBuf[(y+1)*w+(x+1)])
                        let qs = max(EPSSQ, qhvpfBuf[(y-1)*w+(x+1)] + qhvpfBuf[i] + qhvpfBuf[(y+1)*w+(x-1)])
                        pqDirBuf[i] = ps / (ps + qs)
                    }
                }
            }
        }}}}}}

        // ── Seed: rgbR = rgbG = rgbB = CFA (matches prototype's array seed) ─────
        rgbR = cfa.pixels
        rgbG = cfa.pixels
        rgbB = cfa.pixels

        // ── Step 3: Green at R/B sites — whole image (parallel) ──────────────────
        // Reads only from srcBuf (UBP, immutable), lpf, and VH_Dir — all immutable
        // at this point. Writes to rgbG at disjoint non-green sites, one per iter.
        // Row bands are byte-identical to the sequential loop.
        rgbG.withUnsafeMutableBufferPointer { rgbGBuf in
            lpf.withUnsafeBufferPointer { lpfBuf in
                VH_Dir.withUnsafeBufferPointer { vhDirBuf in
                    Parallel.rows(h, minRows: minRows) { rows in
                        // gAt defined locally so @inline(__always) fires at each call site.
                        @inline(__always)
                        func gAt(_ y: Int, _ x: Int) -> Float {
                            guard y >= 0, y < h, x >= 0, x < w else { return 0 }
                            return srcBuf[y &* w &+ x]
                        }
                        for y in rows { for x in 0..<w {
                            let ch = pattern.channel(row: y, col: x)
                            guard ch != 1 else { continue }
                            let i    = y * w + x
                            let cfai = srcBuf[i]
                            let lpfi = lpfBuf[i]

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

                            let lpfNi = y > 0 ? lpfBuf[(y-1)*w+x] : lpfi
                            let lpfSi = y < h-1 ? lpfBuf[(y+1)*w+x] : lpfi
                            let lpfWi = x > 0 ? lpfBuf[y*w+(x-1)] : lpfi
                            let lpfEi = x < w-1 ? lpfBuf[y*w+(x+1)] : lpfi

                            let N_Est = gAt(y-1,x) * (lpfi + lpfi) / (EPS + lpfi + lpfNi)
                            let S_Est = gAt(y+1,x) * (lpfi + lpfi) / (EPS + lpfi + lpfSi)
                            let W_Est = gAt(y,x-1) * (lpfi + lpfi) / (EPS + lpfi + lpfWi)
                            let E_Est = gAt(y,x+1) * (lpfi + lpfi) / (EPS + lpfi + lpfEi)

                            let V_Est = (S_Grad * N_Est + N_Grad * S_Est) / (N_Grad + S_Grad)
                            let H_Est = (W_Grad * E_Est + E_Grad * W_Est) / (E_Grad + W_Grad)

                            let VH_C = vhDirBuf[i]
                            let VH_N = 0.25 * (
                                vhDirBuf[max(0,y-1)*w + max(0,x-1)]
                              + vhDirBuf[max(0,y-1)*w + min(w-1,x+1)]
                              + vhDirBuf[min(h-1,y+1)*w + max(0,x-1)]
                              + vhDirBuf[min(h-1,y+1)*w + min(w-1,x+1)])
                            let VH_D = abs(0.5 - VH_C) < abs(0.5 - VH_N) ? VH_N : VH_C
                            rgbGBuf[i] = intp(VH_D, H_Est, V_Est)
                        }}
                    }
                }
            }
        }

        // ── Step 4.2: R@B and B@R — whole image (parallel) ───────────────────────
        // Compute blue_at_r and red_at_b using the seeded rgbB/rgbR (= CFA).
        // Parallelization is safe: R sites write rgbB[R pos] and B sites write
        // rgbR[B pos].  The reads — rgbB at B positions (R sites) and rgbR at R
        // positions (B sites) — are never written in this step, so no race exists.
        // Step 4.2 parallelization safety:
        //   R sites write rgbB[R pos]; reads go to rgbB at B/G positions (never written).
        //   B sites write rgbR[B pos]; reads go to rgbR at R/G positions (never written).
        //   → pass the mutable buffer as an immutable view; reads/writes don't alias.
        //   rgbG is read-only here; use withUnsafeBufferPointer (no copy).
        rgbR.withUnsafeMutableBufferPointer { rgbRBuf in
        rgbB.withUnsafeMutableBufferPointer { rgbBBuf in
        PQ_Dir.withUnsafeBufferPointer { pqDirBuf in
        rgbG.withUnsafeBufferPointer { GBuf in
            // Immutable views of the SAME storage (no copy):
            // reads target positions that are never concurrently written.
            let rgbBRO = UnsafeBufferPointer(rgbBBuf)
            let rgbRRO = UnsafeBufferPointer(rgbRBuf)
            Parallel.rows(h, minRows: minRows) { rows in
                for y in rows { for x in 0..<w {
                    let ch = pattern.channel(row: y, col: x)
                    guard ch != 1 else { continue }
                    let i    = y * w + x

                    let PQ_C = pqDirBuf[i]
                    let PQ_N = 0.25 * (
                        pqDirBuf[max(0,y-1)*w + max(0,x-1)]
                      + pqDirBuf[max(0,y-1)*w + min(w-1,x+1)]
                      + pqDirBuf[min(h-1,y+1)*w + max(0,x-1)]
                      + pqDirBuf[min(h-1,y+1)*w + min(w-1,x+1)])
                    let PQ_D = abs(0.5 - PQ_C) < abs(0.5 - PQ_N) ? PQ_N : PQ_C

                    func rbAtRBBuf(_ rgbc: UnsafeBufferPointer<Float>) -> Float {
                        let NW  = y>0 && x>0    ? rgbc[(y-1)*w+(x-1)] : 0
                        let SE  = y<h-1 && x<w-1 ? rgbc[(y+1)*w+(x+1)] : 0
                        let NE  = y>0 && x<w-1   ? rgbc[(y-1)*w+(x+1)] : 0
                        let SW  = y<h-1 && x>0   ? rgbc[(y+1)*w+(x-1)] : 0
                        let NWG = y>0 && x>0    ? GBuf[(y-1)*w+(x-1)] : 0
                        let SEG = y<h-1 && x<w-1 ? GBuf[(y+1)*w+(x+1)] : 0
                        let NEG = y>0 && x<w-1   ? GBuf[(y-1)*w+(x+1)] : 0
                        let SWG = y<h-1 && x>0   ? GBuf[(y+1)*w+(x-1)] : 0
                        let gi  = GBuf[i]
                        let nw3 = y>=3 && x>=3   ? rgbc[(y-3)*w+(x-3)] : 0
                        let ne3 = y>=3 && x<w-3  ? rgbc[(y-3)*w+(x+3)] : 0
                        let sw3 = y<h-3 && x>=3  ? rgbc[(y+3)*w+(x-3)] : 0
                        let se3 = y<h-3 && x<w-3 ? rgbc[(y+3)*w+(x+3)] : 0
                        let g_nw2 = y>=2 && x>=2   ? GBuf[(y-2)*w+(x-2)] : 0
                        let g_ne2 = y>=2 && x<w-2  ? GBuf[(y-2)*w+(x+2)] : 0
                        let g_sw2 = y<h-2 && x>=2  ? GBuf[(y+2)*w+(x-2)] : 0
                        let g_se2 = y<h-2 && x<w-2 ? GBuf[(y+2)*w+(x+2)] : 0
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
                        rgbBBuf[i] = rbAtRBBuf(rgbBRO)
                    } else {
                        rgbRBuf[i] = rbAtRBBuf(rgbRRO)
                    }
                }}
            }
        }}}}

        // ── Step 4.3: R@G and B@G — whole image (parallel) ───────────────────────
        // G sites write rgbR[G pos] and rgbB[G pos]; reads are from R/B positions
        // (written by step 4.2). G positions are never read in step 4.3, so
        // concurrent writes to G positions don't race with their own reads.
        // rgbG is read-only here; use withUnsafeBufferPointer (no copy).
        rgbR.withUnsafeMutableBufferPointer { rgbRBuf in
        rgbB.withUnsafeMutableBufferPointer { rgbBBuf in
        rgbG.withUnsafeBufferPointer { G2Buf in
        VH_Dir.withUnsafeBufferPointer { vhDirBuf in
            // Immutable views — G positions are never read by cAtG.
            let rgbRRO = UnsafeBufferPointer(rgbRBuf)
            let rgbBRO = UnsafeBufferPointer(rgbBBuf)
            Parallel.rows(h, minRows: minRows) { rows in
                for y in rows { for x in 0..<w {
                    let ch = pattern.channel(row: y, col: x)
                    guard ch == 1 else { continue }
                    let i = y * w + x

                    let VH_C = vhDirBuf[i]
                    let VH_N = 0.25 * (
                        vhDirBuf[max(0,y-1)*w + max(0,x-1)]
                      + vhDirBuf[max(0,y-1)*w + min(w-1,x+1)]
                      + vhDirBuf[min(h-1,y+1)*w + max(0,x-1)]
                      + vhDirBuf[min(h-1,y+1)*w + min(w-1,x+1)])
                    let VH_D = abs(0.5 - VH_C) < abs(0.5 - VH_N) ? VH_N : VH_C

                    let rgb1 = G2Buf[i]
                    let N1   = EPS + abs(rgb1 - (y>=2 ? G2Buf[(y-2)*w+x] : rgb1))
                    let S1   = EPS + abs(rgb1 - (y<h-2 ? G2Buf[(y+2)*w+x] : rgb1))
                    let W1   = EPS + abs(rgb1 - (x>=2 ? G2Buf[y*w+(x-2)] : rgb1))
                    let E1   = EPS + abs(rgb1 - (x<w-2 ? G2Buf[y*w+(x+2)] : rgb1))
                    let rgb1mw1 = y>0   ? G2Buf[(y-1)*w+x] : rgb1
                    let rgb1pw1 = y<h-1 ? G2Buf[(y+1)*w+x] : rgb1
                    let rgb1m1  = x>0   ? G2Buf[y*w+(x-1)] : rgb1
                    let rgb1p1  = x<w-1 ? G2Buf[y*w+(x+1)] : rgb1

                    func cAtGBuf(_ rgbc: UnsafeBufferPointer<Float>) -> Float {
                        let rN  = y>0   ? rgbc[(y-1)*w+x] : 0
                        let rS  = y<h-1 ? rgbc[(y+1)*w+x] : 0
                        let rW  = x>0   ? rgbc[y*w+(x-1)] : 0
                        let rE  = x<w-1 ? rgbc[y*w+(x+1)] : 0
                        let rN3 = y>=3  ? rgbc[(y-3)*w+x] : 0
                        let rS3 = y<h-3 ? rgbc[(y+3)*w+x] : 0
                        let rW3 = x>=3  ? rgbc[y*w+(x-3)] : 0
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
                    rgbRBuf[i] = cAtGBuf(rgbRRO)
                    rgbBBuf[i] = cAtGBuf(rgbBRO)
                }}
            }
        }}}}

        // ── Build output: bilinear border + parallel RCD interior ────────────────
        // Start from bilinear (covers the border); overwrite interior with RCD.
        out = bilinear(cfa: cfa, pattern: pattern, minRows: minRows).pixels
        rgbR.withUnsafeBufferPointer { rgbRBuf2 in
        rgbG.withUnsafeBufferPointer { rgbGBuf2 in
        rgbB.withUnsafeBufferPointer { rgbBBuf2 in
        out.withUnsafeMutableBufferPointer { outBuf in
            Parallel.rows(h, minRows: minRows) { rows in
                for y in rows {
                    guard y >= 4 && y < h - 4 else { continue }
                    for x in 4..<w-4 {
                        let i = y * w + x
                        outBuf[          i] = max(0.0, min(1.0, rgbRBuf2[i]))
                        outBuf[plane   + i] = max(0.0, min(1.0, rgbGBuf2[i]))
                        outBuf[2*plane + i] = max(0.0, min(1.0, rgbBBuf2[i]))
                    }
                }
            }
        }}}}

        } // end cfa.pixels.withUnsafeBufferPointer

        return AstroImage(width: w, height: h, channels: 3, pixels: out,
                          sourceIsLinear: cfa.sourceIsLinear)
    }
}
