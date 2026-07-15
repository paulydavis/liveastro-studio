# scratchpad/scale_normalization.py
import numpy as np
rng = np.random.default_rng(5)
H = W = 200; N = 24
NOISE = 0.008

yy, xx = np.mgrid[0:H, 0:W]

def make_field():
    stars = []
    for _ in range(30):
        y, x = rng.uniform(10, H-10), rng.uniform(10, W-10)
        amp = rng.uniform(0.15, 0.8); sig = rng.uniform(1.0, 1.8)
        stars.append((y, x, amp, sig))
    return stars

STARS = make_field()
BG = 0.05

def render(transparency):
    img = np.full((H, W), BG)
    for (y, x, amp, sig) in STARS:
        img += transparency * amp * np.exp(-(((xx-x)**2 + (yy-y)**2) / (2*sig*sig)))
    return np.clip(img + rng.normal(0, NOISE, (H, W)), 0, 1)

# per-sub true transparency drifting 1.0 -> 0.6 across the session
t_true = np.linspace(1.0, 0.6, N)
subs = [render(t) for t in t_true]
ref = subs[0]

def measure_fluxes(img):
    """Aperture flux (bg-subtracted 5x5 sum) at the KNOWN star positions —
    stands in for StarDetector flux; registration gives us matched pairs."""
    out = []
    for (y, x, amp, sig) in STARS:
        yi, xi = int(round(y)), int(round(x))
        ap = img[yi-2:yi+3, xi-2:xi+3]
        out.append(max(ap.sum() - 25 * BG, 1e-6))
    return np.array(out)

F_ref = measure_fluxes(ref)

def estimate_scale(img, corrupt_pairs=0):
    f = measure_fluxes(img)
    ratios = F_ref / f
    if corrupt_pairs:                        # simulate RANSAC mismatches surviving
        idx = rng.choice(len(ratios), corrupt_pairs, replace=False)
        ratios[idx] *= rng.uniform(0.2, 5.0, corrupt_pairs)
    return float(np.clip(np.median(ratios), 0.5, 2.0))

# ---- Part A: estimator accuracy ----
print("=== A: estimator accuracy (s_hat vs 1/t_true) ===")
errs, errs_corrupt = [], []
for i, s in enumerate(subs):
    target = np.clip(1.0 / t_true[i], 0.5, 2.0)
    errs.append(abs(estimate_scale(s) - target))
    errs_corrupt.append(abs(estimate_scale(s, corrupt_pairs=4) - target))
print(f"clean pairs : max|err|={max(errs):.4f}  mean={np.mean(errs):.4f}")
print(f"4 bad pairs : max|err|={max(errs_corrupt):.4f}  mean={np.mean(errs_corrupt):.4f}")

# ---- Part B: does scale-then-weight beat weight-alone on the master? ----
def combine(subs, use_scale):
    acc = np.zeros((H, W)); wsum = 0.0
    for i, s in enumerate(subs):
        k = estimate_scale(s) if use_scale else 1.0
        frame = np.clip(BG + (s - BG) * k, 0, 1)
        sigma = NOISE * k                                  # post-scale noise
        w = 1.0 / (sigma * sigma)                          # inverse-variance
        acc += w * frame; wsum += w
    return acc / wsum

truth = np.full((H, W), BG)
for (y, x, amp, sig) in STARS:
    truth += amp * np.exp(-(((xx-x)**2 + (yy-y)**2) / (2*sig*sig)))   # transparency 1.0 signal

def star_amp_err(master):
    """Mean |master peak - truth peak| over stars (amplitude fidelity)."""
    e = []
    for (y, x, amp, sig) in STARS:
        yi, xi = int(round(y)), int(round(x))
        e.append(abs(master[yi, xi] - truth[yi, xi]))
    return float(np.mean(e))

m_off = combine(subs, False)
m_on  = combine(subs, True)
print("=== B: master star-amplitude error vs ground truth ===")
print(f"weight-alone     : {star_amp_err(m_off):.5f}")
print(f"scale-then-weight: {star_amp_err(m_on):.5f}   "
      f"({100*(star_amp_err(m_on)-star_amp_err(m_off))/star_amp_err(m_off):+.1f}%)")

# ---- Part C: sigma-clip efficacy with drifting transparency ----
def clip_combine(subs, use_scale, kappa=3.0):
    frames = []
    for s in subs:
        k = estimate_scale(s) if use_scale else 1.0
        frames.append(np.clip(BG + (s - BG) * k, 0, 1))
    a = np.stack(frames)
    mean = a.mean(0); std = a.std(0) + 1e-9
    clipped = np.clip(a, mean - kappa*std, mean + kappa*std)
    return clipped.mean(0)

streaky = [s.copy() for s in subs]
streaky[10][100:102, :] = 0.9                            # satellite streak on one sub
c_off = clip_combine(streaky, False); c_on = clip_combine(streaky, True)
res_off = c_off[100:102, :].mean() - truth[100:102, :].mean()
res_on  = c_on[100:102, :].mean() - truth[100:102, :].mean()
print("=== C: streak residual after sigma-clip (lower = better rejection) ===")
print(f"weight-alone     : {res_off:.5f}")
print(f"scale-then-weight: {res_on:.5f}")
