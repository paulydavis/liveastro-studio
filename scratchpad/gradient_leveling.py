# scratchpad/gradient_leveling.py
import numpy as np
rng = np.random.default_rng(7)
H = W = 120; C = 3; N = 24

stars = np.zeros((H, W, C))
for _ in range(40):
    y, x = rng.integers(6, H-6), rng.integers(6, W-6); a = rng.uniform(.3, .9)
    yy, xx = np.mgrid[y-4:y+5, x-4:x+5]
    stars[y-4:y+5, x-4:x+5, :] += a * np.exp(-((yy-y)**2 + (xx-x)**2)/4)[..., None]

# normalized coords [-1,1]
ny, nx = np.mgrid[0:H, 0:W]
nx = nx / (W-1) * 2 - 1; ny = ny / (H-1) * 2 - 1

def make(i):
    # a linear sky gradient whose direction+slope DRIFT across the session (moonrise sweep),
    # plus a per-channel base pedestal + noise.
    ang = 2 * np.pi * i / N
    slope = 0.05 * (i / N)
    grad = slope * (np.cos(ang) * nx + np.sin(ang) * ny)   # H,W
    ped = np.array([.05, .04, .03])
    return np.clip(stars + grad[..., None] + ped[None, None, :] + rng.normal(0, .01, (H, W, C)), 0, 1)

subs = [make(i) for i in range(N)]

def basis(px, py, deg):
    return [np.ones_like(px), px, py] if deg == 1 else [np.ones_like(px), px, py, px*px, px*py, py*py]

def fit_coeffs(sub_c, deg, tiles=16):
    # tile medians → sigma-clip bright → least squares (mirrors BackgroundExtraction.flatten)
    txs, tys, tvs = [], [], []
    for ty in range(tiles):
        y0, y1 = ty*H//tiles, (ty+1)*H//tiles
        for tx in range(tiles):
            x0, x1 = tx*W//tiles, (tx+1)*W//tiles
            if y1 <= y0 or x1 <= x0: continue
            tvs.append(np.median(sub_c[y0:y1, x0:x1]))
            txs.append(((x0+x1)/2)/W*2 - 1); tys.append(((y0+y1)/2)/H*2 - 1)
    txs, tys, tvs = map(np.array, (txs, tys, tvs))
    keep = np.ones(len(tvs), bool)
    for _ in range(3):
        v = tvs[keep]
        if v.size <= 6: break
        med = np.median(v); madn = 1.4826*np.median(np.abs(v-med))
        if madn <= 1e-12: break
        keep &= tvs <= med + 2.0*madn
    B = np.stack(basis(txs[keep], tys[keep], deg), 1)
    coeff, *_ = np.linalg.lstsq(B, tvs[keep], rcond=None)
    return coeff

def surface(coeff, deg):
    B = np.stack([b.ravel() for b in basis(nx, ny, deg)], 1)
    return (B @ coeff).reshape(H, W)

def combine(subs, level, deg):
    ref = [fit_coeffs(subs[0][..., c], deg) for c in range(C)] if level else None
    acc = np.zeros((H, W, C))
    for s in subs:
        f = s.copy()
        if level:
            for c in range(C):
                diff = fit_coeffs(s[..., c], deg) - ref[c]
                f[..., c] = np.clip(s[..., c] - surface(diff, deg), 0, 1)
        acc += f
    return acc / len(subs)

def corner_delta(m):
    tl = m[:H//3, :W//3].reshape(-1, C).mean(0); br = m[2*H//3:, 2*W//3:].reshape(-1, C).mean(0)
    return float(np.mean(np.abs(br - tl)))
def row_grad_rms(m):
    rows = m.reshape(H, -1).mean(1); return float(np.sqrt(np.mean(np.diff(rows)**2)))

off = combine(subs, False, 1)
for deg in (1, 2):
    on = combine(subs, True, deg)
    print(f"[deg {deg}] corner_delta off={corner_delta(off):.5f} on={corner_delta(on):.5f} "
          f"({100*(corner_delta(on)-corner_delta(off))/corner_delta(off):+.1f}%)  "
          f"row_grad_rms off={row_grad_rms(off):.5f} on={row_grad_rms(on):.5f} "
          f"({100*(row_grad_rms(on)-row_grad_rms(off))/row_grad_rms(off):+.1f}%)")
