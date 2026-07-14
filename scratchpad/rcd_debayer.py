# scratchpad/rcd_debayer.py
#
# RCD (Ratio Corrected Demosaicing) prototype for LiveAstro Studio.
#
# FAITHFUL numpy port of Luis Sanz Rodriguez's RCD, release 2.3, as implemented
# in librtprocess:
#   https://raw.githubusercontent.com/CarVac/librtprocess/master/src/demosaic/rcd.cc
#
# Port notes / deviations from rcd.cc (documented; none change the arithmetic on
# the interior pixels the metrics/golden vectors look at):
#
#   * rcd.cc works on tiles (194x194 with a 9px overlap) purely for cache/OpenMP
#     performance. We operate on the whole image at once; the arithmetic per
#     interior pixel is identical. Tiling is a performance detail, not part of the
#     algorithm.
#   * rcd.cc scales raw by 1/65536 into [0,1] (LIM01) and multiplies back by 65536
#     on output. Our CFA is already in [0,1], so scale == 1.0 (LIM01 == clip01).
#     This is a pure change of units and does not alter the result in [0,1].
#   * rcd.cc's `intp(a, b, c)` (rt_math.h) is a*b + (1-a)*c. Replicated exactly.
#   * rcd.cc's border (outer `rcdBorder = 9` px) is filled by a separate
#     bayerborder_demosaic (a bilinear-family fill). The brief specifies that the
#     Swift port uses OUR bilinear for the outer 4px, and that metrics/golden
#     vectors exclude/replace a 4px border. So here the RCD interior is computed
#     wherever the reference's index math is in-bounds, and the outer 4px ring is
#     overwritten with our bilinear() result. The 4px metric border keeps all
#     compared pixels inside the region where the full RCD stencil is valid
#     (the widest stencil reaches +/-4 rows/cols, i.e. w4).
#   * The `>= std::min(tileRows-3, 5)` clamp on bufferV in rcd.cc is a tiling
#     artifact (it only fills the first few rows of a rolling 3-row buffer); the
#     effective computation is V_Stat = sum of the vertical HPF^2 over 3 vertically
#     adjacent rows, which we compute directly and vectorized.
#
# Everything else (the HPF stencils, the eps/epssq constants, the ratio-corrected
# cardinal estimates, the VH/PQ directional discrimination and the neighbourhood
# refinement, the color-difference red/blue reconstruction) is a 1:1 port of the
# per-pixel formulas in rcd.cc.

import numpy as np
rng = np.random.default_rng(11)

PATTERNS = {  # channel index at (row%2, col%2): 0=R 1=G 2=B  (mirrors Swift BayerPattern.channel)
    "GRBG": {(0,0):1,(0,1):0,(1,0):2,(1,1):1},
    "RGGB": {(0,0):0,(0,1):1,(1,0):1,(1,1):2},
    "BGGR": {(0,0):2,(0,1):1,(1,0):1,(1,1):0},
    "GBRG": {(0,0):1,(0,1):2,(1,0):0,(1,1):1},
}

def mosaic(rgb, pattern):
    H, W, _ = rgb.shape
    cfa = np.zeros((H, W))
    for (r, c), ch in PATTERNS[pattern].items():
        cfa[r::2, c::2] = rgb[r::2, c::2, ch]
    return cfa

def ground_truth(H=256, W=256):
    """Star field: gradient sky + Gaussian stars (varied brightness incl. near-saturation) + noise."""
    yy, xx = np.mgrid[0:H, 0:W]
    sky = 0.05 + 0.02 * xx / W + 0.015 * yy / H
    rgb = np.stack([sky * 1.0, sky * 0.9, sky * 0.8], -1)
    stars = []
    for i in range(40):
        y, x = rng.uniform(12, H-12), rng.uniform(12, W-12)
        amp = rng.uniform(0.2, 0.95)
        sigma = rng.uniform(0.8, 1.6)               # undersampled-to-normal star widths
        col = np.array([1.0, rng.uniform(0.85, 1.0), rng.uniform(0.7, 1.0)])  # slightly colored stars
        g = amp * np.exp(-(((xx - x)**2 + (yy - y)**2) / (2 * sigma**2)))
        rgb += g[..., None] * col[None, None, :]
        stars.append((y, x))
    rgb = np.clip(rgb + rng.normal(0, 0.004, rgb.shape), 0, 1)
    return rgb, stars

def bilinear(cfa, pattern):
    """Port of the Swift mask-normalized 3x3 bilinear (Debayer.bilinear)."""
    H, W = cfa.shape
    out = np.zeros((H, W, 3))
    chan = np.zeros((H, W), int)
    for (r, c), ch in PATTERNS[pattern].items():
        chan[r::2, c::2] = ch
    for ch in range(3):
        m = (chan == ch).astype(float)
        v = cfa * m
        num = np.zeros((H, W)); den = np.zeros((H, W))
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                w = 1.0 if (dy, dx) == (0, 0) else (0.5 if dy == 0 or dx == 0 else 0.25)
                num += w * np.roll(np.roll(v, dy, 0), dx, 1) * valid_shift(H, W, dy, dx)
                den += w * np.roll(np.roll(m, dy, 0), dx, 1) * valid_shift(H, W, dy, dx)
        out[..., ch] = np.where(den > 0, num / np.maximum(den, 1e-12), 0)
    return np.clip(out, 0, 1)

def valid_shift(H, W, dy, dx):
    """Mask that zeroes wrapped-around rows/cols from np.roll (edge-exactness like the Swift kernel)."""
    m = np.ones((H, W))
    if dy == 1: m[0, :] = 0
    if dy == -1: m[-1, :] = 0
    if dx == 1: m[:, 0] = 0
    if dx == -1: m[:, -1] = 0
    return m

# ------------------------------------------------------------------------------
# RCD core
# ------------------------------------------------------------------------------
#
# Index / stencil dictionary (matches rcd.cc):
#   In rcd.cc indices are into a flat tile buffer with row stride w1 = tileSize.
#   Here we work on 2D arrays and use a shift helper. A flat offset of
#       a*w1 + b   (a = rows down, b = cols right)
#   corresponds to sampling the array at (row + a, col + b). We realise that by
#   shifting the array by (-a, -b): the value that ends up at (row,col) is the
#   value originally at (row+a, col+b). fabs -> np.abs, SQR -> square, max -> max,
#   intp(p,q,r) = p*q + (1-p)*r.

EPS = 1e-5
EPSSQ = 1e-10

def _sh(a, dr, dc):
    """Return array b such that b[r,c] = a[r+dr, c+dc] (zero-filled at the edges).

    This mirrors rcd.cc's `cfa[indx + dr*w1 + dc]`. Edges are zero-filled; every
    pixel that consumes a shifted sample lies in the RCD interior (>=4px from the
    border), and its 4-px-away neighbours are still in-bounds, so the zero fill is
    never read by a pixel that survives the 4px metric/golden border.
    """
    b = np.zeros_like(a)
    H, W = a.shape
    r0s, r0d = (dr, 0) if dr >= 0 else (0, -dr)
    c0s, c0d = (dc, 0) if dc >= 0 else (0, -dc)
    rh = H - abs(dr)
    cw = W - abs(dc)
    b[r0d:r0d+rh, c0d:c0d+cw] = a[r0s:r0s+rh, c0s:c0s+cw]
    return b

def _intp(p, q, r):
    return p * q + (1.0 - p) * r

def rcd(cfa, pattern):
    """FAITHFUL port of librtprocess rcd.cc. Returns HxWx3 in [0,1].
    Border (outer 4px) filled with bilinear(cfa, pattern) values."""
    H, W = cfa.shape
    cfa = np.clip(cfa.astype(np.float64), 0.0, 1.0)   # LIM01 with scale==1

    # site-channel map (0=R,1=G,2=B) and a parity map (0 => even col in fc terms)
    chan = np.zeros((H, W), int)
    for (r, c), ch in PATTERNS[pattern].items():
        chan[r::2, c::2] = ch

    # rgb[c] buffers. rcd.cc seeds rgb[c0]=rgb[c1]=cfa across the row, i.e. every
    # channel's buffer initially holds the raw CFA value at each site. Only the
    # green buffer's R/B sites and the R/B buffers get overwritten below; the
    # seed matters where an estimate reads an as-yet-unwritten neighbour (it never
    # does for interior pixels, but we replicate the seed to be exact).
    rgbG = cfa.copy()
    rgbR = cfa.copy()
    rgbB = cfa.copy()

    # --- Step 1.1/1.2: vertical & horizontal HPF^2 and VH_Dir ------------------
    # Vertical HPF at a pixel (rcd.cc bufferV):
    #   (cfa[-w3] - cfa[-w1] - cfa[+w1] + cfa[+w3]) - 3*(cfa[-w2]+cfa[+w2]) + 6*cfa
    vhpf = ((_sh(cfa,-3,0) - _sh(cfa,-1,0) - _sh(cfa,1,0) + _sh(cfa,3,0))
            - 3.0 * (_sh(cfa,-2,0) + _sh(cfa,2,0)) + 6.0 * cfa) ** 2
    hhpf = ((_sh(cfa,0,-3) - _sh(cfa,0,-1) - _sh(cfa,0,1) + _sh(cfa,0,3))
            - 3.0 * (_sh(cfa,0,-2) + _sh(cfa,0,2)) + 6.0 * cfa) ** 2

    # V_Stat = sum of vhpf over 3 vertically-adjacent rows {-1,0,+1} at this col.
    # H_Stat = sum of hhpf over 3 horizontally-adjacent cols {-1,0,+1} at this row.
    # (In rcd.cc V uses bufferV rows row-1,row,row+1; H uses bufferH cols col-2..col
    #  which after the col-4 vs col-3 index offset is the {-1,0,+1} neighbourhood.)
    V_Stat = np.maximum(EPSSQ, _sh(vhpf,-1,0) + vhpf + _sh(vhpf,1,0))
    H_Stat = np.maximum(EPSSQ, _sh(hhpf,0,-1) + hhpf + _sh(hhpf,0,1))
    VH_Dir = V_Stat / (V_Stat + H_Stat)

    # --- Step 2: low-pass filter (populated at every site) ---------------------
    lpf = (cfa
           + 0.5 * (_sh(cfa,-1,0) + _sh(cfa,1,0) + _sh(cfa,0,-1) + _sh(cfa,0,1))
           + 0.25 * (_sh(cfa,-1,-1) + _sh(cfa,-1,1) + _sh(cfa,1,-1) + _sh(cfa,1,1)))

    # --- Step 3: green at R/B sites -------------------------------------------
    cfai = cfa
    N_Grad = EPS + (np.abs(_sh(cfa,-1,0) - _sh(cfa,1,0)) + np.abs(cfai - _sh(cfa,-2,0))) \
                 + (np.abs(_sh(cfa,-1,0) - _sh(cfa,-3,0)) + np.abs(_sh(cfa,-2,0) - _sh(cfa,-4,0)))
    S_Grad = EPS + (np.abs(_sh(cfa,-1,0) - _sh(cfa,1,0)) + np.abs(cfai - _sh(cfa,2,0))) \
                 + (np.abs(_sh(cfa,1,0) - _sh(cfa,3,0)) + np.abs(_sh(cfa,2,0) - _sh(cfa,4,0)))
    W_Grad = EPS + (np.abs(_sh(cfa,0,-1) - _sh(cfa,0,1)) + np.abs(cfai - _sh(cfa,0,-2))) \
                 + (np.abs(_sh(cfa,0,-1) - _sh(cfa,0,-3)) + np.abs(_sh(cfa,0,-2) - _sh(cfa,0,-4)))
    E_Grad = EPS + (np.abs(_sh(cfa,0,-1) - _sh(cfa,0,1)) + np.abs(cfai - _sh(cfa,0,2))) \
                 + (np.abs(_sh(cfa,0,1) - _sh(cfa,0,3)) + np.abs(_sh(cfa,0,2) - _sh(cfa,0,4)))

    lpfi = lpf
    N_Est = _sh(cfa,-1,0) * (lpfi + lpfi) / (EPS + lpfi + _sh(lpf,-1,0))
    S_Est = _sh(cfa,1,0)  * (lpfi + lpfi) / (EPS + lpfi + _sh(lpf,1,0))
    W_Est = _sh(cfa,0,-1) * (lpfi + lpfi) / (EPS + lpfi + _sh(lpf,0,-1))
    E_Est = _sh(cfa,0,1)  * (lpfi + lpfi) / (EPS + lpfi + _sh(lpf,0,1))

    V_Est = (S_Grad * N_Est + N_Grad * S_Est) / (N_Grad + S_Grad)
    H_Est = (W_Grad * E_Est + E_Grad * W_Est) / (E_Grad + W_Grad)

    VH_Central = VH_Dir
    VH_Neigh = 0.25 * ((_sh(VH_Dir,-1,-1) + _sh(VH_Dir,-1,1)) + (_sh(VH_Dir,1,-1) + _sh(VH_Dir,1,1)))
    VH_Disc = np.where(np.abs(0.5 - VH_Central) < np.abs(0.5 - VH_Neigh), VH_Neigh, VH_Central)
    green_at_rb = _intp(VH_Disc, H_Est, V_Est)

    rb_site = (chan != 1)  # R or B site
    rgbG = np.where(rb_site, green_at_rb, rgbG)

    # --- Step 4.0/4.1: P/Q diagonal HPF^2 and PQ_Dir ---------------------------
    # P diagonal (NW-SE): stencil along (-w1-1) direction.
    p_hpf = ((_sh(cfa,-3,-3) - _sh(cfa,-1,-1) - _sh(cfa,1,1) + _sh(cfa,3,3))
             - 3.0 * (_sh(cfa,-2,-2) + _sh(cfa,2,2)) + 6.0 * cfa) ** 2
    # Q diagonal (NE-SW): stencil along (-w1+1) direction.
    q_hpf = ((_sh(cfa,-3,3) - _sh(cfa,-1,1) - _sh(cfa,1,-1) + _sh(cfa,3,-3))
             - 3.0 * (_sh(cfa,-2,2) + _sh(cfa,2,-2)) + 6.0 * cfa) ** 2

    # rcd.cc: P_Stat = P_hpf[indx3] + P_hpf[indx2] + P_hpf[indx4+1]
    #   indx2 = indx/2 (this pixel), indx3 = (indx-w1-1)/2 (NW), indx4+1 = (indx+w1+1)/2 (SE)
    # => P_Stat sums P_hpf at NW, center, SE (the NW-SE diagonal neighbours).
    P_Stat = np.maximum(EPSSQ, _sh(p_hpf,-1,-1) + p_hpf + _sh(p_hpf,1,1))
    # Q_Stat = Q_hpf[indx3+1] + Q_hpf[indx2] + Q_hpf[indx4]
    #   indx3+1 = (indx-w1+1)/2 (NE), indx4 = (indx+w1-1)/2 (SW)
    # => Q_Stat sums Q_hpf at NE, center, SW (the NE-SW diagonal neighbours).
    Q_Stat = np.maximum(EPSSQ, _sh(q_hpf,-1,1) + q_hpf + _sh(q_hpf,1,-1))
    PQ_Dir = P_Stat / (P_Stat + Q_Stat)

    # --- Step 4.2: R@B and B@R at R/B sites ------------------------------------
    # c = 2 - fc(site): at an R site (fc=0) c=2 (interpolate blue); at B site c=0.
    # We compute both an "R buffer" and "B buffer" update using the *opposite*
    # channel's known values. rgb[c] here is whichever channel is NOT present.
    PQ_Central = PQ_Dir
    PQ_Neigh = 0.25 * (_sh(PQ_Dir,-1,-1) + _sh(PQ_Dir,-1,1) + _sh(PQ_Dir,1,-1) + _sh(PQ_Dir,1,1))
    PQ_Disc = np.where(np.abs(0.5 - PQ_Central) < np.abs(0.5 - PQ_Neigh), PQ_Neigh, PQ_Central)

    G = rgbG  # green now valid everywhere (R/B sites filled; G sites are raw)

    def _rb_at_rb(rgbc):
        # Diagonal gradients on channel-c buffer + green.
        NW_Grad = EPS + np.abs(_sh(rgbc,-1,-1) - _sh(rgbc,1,1)) + np.abs(_sh(rgbc,-1,-1) - _sh(rgbc,-3,-3)) + np.abs(G - _sh(G,-2,-2))
        NE_Grad = EPS + np.abs(_sh(rgbc,-1,1) - _sh(rgbc,1,-1)) + np.abs(_sh(rgbc,-1,1) - _sh(rgbc,-3,3)) + np.abs(G - _sh(G,-2,2))
        SW_Grad = EPS + np.abs(_sh(rgbc,-1,1) - _sh(rgbc,1,-1)) + np.abs(_sh(rgbc,1,-1) - _sh(rgbc,3,-3)) + np.abs(G - _sh(G,2,-2))
        SE_Grad = EPS + np.abs(_sh(rgbc,-1,-1) - _sh(rgbc,1,1)) + np.abs(_sh(rgbc,1,1) - _sh(rgbc,3,3)) + np.abs(G - _sh(G,2,2))
        NW_Est = _sh(rgbc,-1,-1) - _sh(G,-1,-1)
        NE_Est = _sh(rgbc,-1,1)  - _sh(G,-1,1)
        SW_Est = _sh(rgbc,1,-1)  - _sh(G,1,-1)
        SE_Est = _sh(rgbc,1,1)   - _sh(G,1,1)
        P_Est = (NW_Grad * SE_Est + SE_Grad * NW_Est) / (NW_Grad + SE_Grad)
        Q_Est = (NE_Grad * SW_Est + SW_Grad * NE_Est) / (NE_Grad + SW_Grad)
        return G + _intp(PQ_Disc, Q_Est, P_Est)

    # At R sites, the missing R/B channel is Blue -> update rgbB using rgbB buffer
    # (which holds raw B at B sites via the seed). At B sites, update rgbR.
    r_site = (chan == 0)
    b_site = (chan == 2)
    blue_at_r = _rb_at_rb(rgbB)   # rgb[2] reconstruction at R sites
    red_at_b  = _rb_at_rb(rgbR)   # rgb[0] reconstruction at B sites
    rgbB = np.where(r_site, blue_at_r, rgbB)
    rgbR = np.where(b_site, red_at_b, rgbR)

    # --- Step 4.3: R@G and B@G at green sites ----------------------------------
    VH_Central = VH_Dir
    VH_Neigh = 0.25 * ((_sh(VH_Dir,-1,-1) + _sh(VH_Dir,-1,1)) + (_sh(VH_Dir,1,-1) + _sh(VH_Dir,1,1)))
    VH_Disc = np.where(np.abs(0.5 - VH_Central) < np.abs(0.5 - VH_Neigh), VH_Neigh, VH_Central)

    rgb1 = G
    N1 = EPS + np.abs(rgb1 - _sh(G,-2,0))
    S1 = EPS + np.abs(rgb1 - _sh(G,2,0))
    W1 = EPS + np.abs(rgb1 - _sh(G,0,-2))
    E1 = EPS + np.abs(rgb1 - _sh(G,0,2))
    rgb1mw1 = _sh(G,-1,0); rgb1pw1 = _sh(G,1,0)
    rgb1m1 = _sh(G,0,-1); rgb1p1 = _sh(G,0,1)

    def _c_at_g(rgbc):
        SNabs = np.abs(_sh(rgbc,-1,0) - _sh(rgbc,1,0))
        EWabs = np.abs(_sh(rgbc,0,-1) - _sh(rgbc,0,1))
        N_Grad = N1 + SNabs + np.abs(_sh(rgbc,-1,0) - _sh(rgbc,-3,0))
        S_Grad = S1 + SNabs + np.abs(_sh(rgbc,1,0) - _sh(rgbc,3,0))
        W_Grad = W1 + EWabs + np.abs(_sh(rgbc,0,-1) - _sh(rgbc,0,-3))
        E_Grad = E1 + EWabs + np.abs(_sh(rgbc,0,1) - _sh(rgbc,0,3))
        N_Est = _sh(rgbc,-1,0) - rgb1mw1
        S_Est = _sh(rgbc,1,0)  - rgb1pw1
        W_Est = _sh(rgbc,0,-1) - rgb1m1
        E_Est = _sh(rgbc,0,1)  - rgb1p1
        V_Est = (N_Grad * S_Est + S_Grad * N_Est) / (N_Grad + S_Grad)
        H_Est = (E_Grad * W_Est + W_Grad * E_Est) / (E_Grad + W_Grad)
        return rgb1 + _intp(VH_Disc, H_Est, V_Est)

    g_site = (chan == 1)
    red_at_g  = _c_at_g(rgbR)
    blue_at_g = _c_at_g(rgbB)
    rgbR = np.where(g_site, red_at_g, rgbR)
    rgbB = np.where(g_site, blue_at_g, rgbB)

    out = np.stack([rgbR, rgbG, rgbB], axis=-1)
    out = np.clip(out, 0.0, 1.0)   # std::max(0, ...) plus [0,1] domain

    # --- Border: fill outer 4px with our bilinear (per brief) ------------------
    bi = bilinear(cfa, pattern)
    mask = np.ones((H, W), bool)
    mask[4:-4, 4:-4] = False
    out[mask] = bi[mask]
    return np.clip(out, 0.0, 1.0)

# ---- metrics (exclude 4px border everywhere) ----
def interior(a): return a[4:-4, 4:-4]

def star_core_psnr(est, truth, stars):
    errs = []
    for (y, x) in stars:
        yi, xi = int(round(y)), int(round(x))
        if 6 <= yi < truth.shape[0]-6 and 6 <= xi < truth.shape[1]-6:
            e = est[yi-2:yi+3, xi-2:xi+3] - truth[yi-2:yi+3, xi-2:xi+3]
            errs.append(np.mean(e**2))
    mse = np.mean(errs)
    return 10 * np.log10(1.0 / mse) if mse > 0 else np.inf

def fringe_energy(est, truth, stars):
    """Chroma error in a 5..8px annulus around stars (color fringing)."""
    H, W, _ = truth.shape
    yy, xx = np.mgrid[0:H, 0:W]
    total = 0.0
    for (y, x) in stars:
        d = np.sqrt((yy - y)**2 + (xx - x)**2)
        ring = (d >= 5) & (d <= 8)
        chroma_est = est[..., 0][ring] - est[..., 2][ring]
        chroma_tru = truth[..., 0][ring] - truth[..., 2][ring]
        total += np.mean((chroma_est - chroma_tru)**2)
    return total / len(stars)

def sky_psnr(est, truth):
    mse = np.mean((interior(est) - interior(truth))**2)
    return 10 * np.log10(1.0 / mse)

# ------------------------------------------------------------------------------
# Real-sub FITS reader (tiny, inline) + golden-vector emitter
# ------------------------------------------------------------------------------
def read_fits(path):
    """Minimal FITS reader: 2880-byte header blocks, BITPIX 16 + BZERO 32768."""
    with open(path, 'rb') as f:
        data = f.read()
    # parse header (2880-byte blocks of 80-char cards) until END
    hdr = {}
    off = 0
    end = False
    while not end:
        block = data[off:off+2880]
        for i in range(0, 2880, 80):
            card = block[i:i+80].decode('ascii', 'replace')
            key = card[:8].strip()
            if key == 'END':
                end = True
                break
            if '=' in card:
                val = card[10:].split('/')[0].strip()
                hdr[key] = val
        off += 2880
    naxis1 = int(hdr['NAXIS1']); naxis2 = int(hdr['NAXIS2'])
    bitpix = int(hdr['BITPIX'])
    bzero = float(hdr.get('BZERO', '0'))
    bscale = float(hdr.get('BSCALE', '1'))
    assert bitpix == 16, f"expected BITPIX 16, got {bitpix}"
    arr = np.frombuffer(data[off:off + naxis1*naxis2*2], dtype='>i2').astype(np.float64)
    arr = arr[:naxis1*naxis2].reshape(naxis2, naxis1)
    arr = arr * bscale + bzero          # BZERO 32768 -> unsigned 0..65535
    return arr, hdr

def _swift_literal(name, arr):
    """arr is HxWx3 (planar order: emit R plane, G plane, B plane) or HxW."""
    flat = arr.astype(np.float32).ravel(order='C')
    vals = ", ".join(f"{v:.6f}" for v in flat)
    return f"let {name}: [Float] = [{vals}]"

def golden_vectors():
    """Deterministic 16x16 CFA + full 16x16x3 RCD output per pattern, as Swift literals."""
    grng = np.random.default_rng(3)
    H = W = 16
    yy, xx = np.mgrid[0:H, 0:W]
    sky = 0.05 + 0.02 * xx / W + 0.015 * yy / H
    rgb = np.stack([sky * 1.0, sky * 0.9, sky * 0.8], -1)
    for i in range(4):
        y, x = grng.uniform(4, H-4), grng.uniform(4, W-4)
        amp = grng.uniform(0.3, 0.9)
        sigma = grng.uniform(0.9, 1.5)
        col = np.array([1.0, grng.uniform(0.85, 1.0), grng.uniform(0.7, 1.0)])
        g = amp * np.exp(-(((xx - x)**2 + (yy - y)**2) / (2 * sigma**2)))
        rgb += g[..., None] * col[None, None, :]
    rgb = np.clip(rgb, 0, 1)  # no noise: deterministic golden vectors

    blocks = {}
    for pat in PATTERNS:
        cfa = mosaic(rgb, pat)
        out = rcd(cfa, pat)          # HxWx3, planar R,G,B on emit
        # planar output: R plane then G plane then B plane (matches Swift planar layout)
        planar = np.concatenate([out[..., 0].ravel(), out[..., 1].ravel(), out[..., 2].ravel()])
        blocks[pat] = (_swift_literal(f"cfa_{pat}", cfa),
                       _swift_literal(f"expected_{pat}", planar.reshape(3, H, W)))
    return blocks

if __name__ == "__main__":
    import sys
    truth, stars = ground_truth()
    for pat in PATTERNS:
        cfa = mosaic(truth, pat)
        bi = bilinear(cfa, pat)
        rc = rcd(cfa, pat)
        print(f"[{pat}] starPSNR bi={star_core_psnr(bi, truth, stars):.2f} rcd={star_core_psnr(rc, truth, stars):.2f}  "
              f"fringe bi={fringe_energy(bi, truth, stars):.2e} rcd={fringe_energy(rc, truth, stars):.2e}  "
              f"skyPSNR bi={sky_psnr(bi, truth):.2f} rcd={sky_psnr(rc, truth):.2f}")

    if "--golden" in sys.argv:
        # -----------------------------------------------------------------------
        # WARNING: This Python generator computes in float64 (numpy default) and
        # fills the outer 4-px border with Python's bilinear (which includes
        # diagonal taps weighted 0.25).  The committed Swift implementation uses
        # float32 sequential arithmetic and Swift's bilinear (cross-only, no
        # diagonals).  The two differ by up to ~4.3e-2 on border pixels and
        # ~1.2e-4 on interior pixels, so the output of "--golden" WILL NOT match
        # the committed expected_* arrays in DebayerRCDTests.swift and WILL fail
        # the 1e-4 tolerance tests.
        #
        # RECOMMENDED regeneration path (correct by construction):
        #   DUMP_GOLDENS=1 swift test --filter testDumpGoldenVectors
        # See Tests/LiveAstroCoreTests/DebayerRCDTests.swift  testDumpGoldenVectors
        # for instructions.  That test runs the actual Debayer.rcd implementation
        # on the committed CFA input literals and prints Swift-ready expected arrays.
        # -----------------------------------------------------------------------
        print("\n==== GOLDEN VECTORS (Python/float64 — see WARNING above) ====")
        for pat, (cfa_lit, exp_lit) in golden_vectors().items():
            print(f"\n// ---- {pat} ----")
            print(cfa_lit)
            print(exp_lit)
