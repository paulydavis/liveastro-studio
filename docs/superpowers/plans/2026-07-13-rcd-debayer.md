# RCD Debayer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add RCD demosaicing (sharp, fringe-free star cores) as the app's default, keeping the existing bilinear byte-identical behind a "Demosaic" picker.

**Architecture:** A Task-1 Python prototype implements RCD faithfully from the published reference (librtprocess `rcd.cc`), gates it against bilinear on star metrics + a real Seestar sub, and exports golden test vectors. Task 2 ports it to `Debayer.rcd` (row-parallel, borders via existing bilinear), pinned to the golden vectors. Task 3 adds `DemosaicMethod` selection end to end (engine default `.bilinear` = byte-identical; app default `.rcd`).

**Tech Stack:** Swift 5.10 SPM (LiveAstroCore: Foundation/CoreGraphics/Accelerate only), SwiftUI app, Python 3 + numpy for the prototype.

## Global Constraints

- Swift 5.10, macOS 14+. LiveAstroCore imports Foundation / CoreGraphics / Accelerate only; zero external deps; demosaic in plain Swift + `Parallel.rows`.
- Engine default `.bilinear` = **byte-identical** to today (the entire existing suite is the guard). App default `.rcd`.
- All 4 Bayer patterns (GRBG/RGGB/BGGR/GBRG). Borders (outer 4 px) via the existing bilinear result; frames with width or height < 8 fall back to bilinear entirely; mono passthrough unchanged.
- The T1 prototype + its golden vectors are the **normative reference** for the Swift port — where prose and vectors disagree, vectors win.
- Output finite and clamped [0,1] from finite input. Parallel == serial byte-identical.
- Core logic TDD'd; prototype is a validation artifact; app/UI build-verified; adversarial pass before merge (Bayer-phase correctness, saturation, edges).
- Branch: `feature/rcd-debayer` off `main` @ 0cceed2. Spec: `docs/superpowers/specs/2026-07-13-rcd-debayer-design.md`.

---

## Task 1: Python prototype — gate + golden vectors (research task; capable model)

**Files:**
- Create: `scratchpad/rcd_debayer.py` (NOT shipped; scratchpad is git-ignored but commit this artifact like prior prototype gates)

**This is a research/algorithm task, not transcription.** Implement RCD faithfully from the published reference: fetch and read `https://raw.githubusercontent.com/CarVac/librtprocess/master/src/demosaic/rcd.cc` (Luis Sanz Rodríguez's RCD; Siril/RawTherapee lineage). Port its steps to numpy: (1) CFA low-pass estimate, (2) vertical/horizontal directional discrimination from local gradient statistics, (3) ratio/LPF-corrected green interpolation at R/B sites, (4) R/B reconstruction at the remaining sites via color-difference in the RCD manner, (5) simple border handling (the Swift port will use our bilinear for the outer 4 px — in the prototype, exclude a 4-px border from all metrics and golden vectors' expected-value comparisons, or fill it with the bilinear result).

- [ ] **Step 1: Scaffolding (write verbatim, then add the RCD core per the reference)**

```python
# scratchpad/rcd_debayer.py
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

def rcd(cfa, pattern):
    """FAITHFUL port of librtprocess rcd.cc — implement per the fetched reference.
    Return HxWx3 in [0,1]. Border (outer 4px): fill with bilinear(cfa,pattern) values."""
    raise NotImplementedError  # <- replace with the real implementation

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

if __name__ == "__main__":
    truth, stars = ground_truth()
    for pat in PATTERNS:
        cfa = mosaic(truth, pat)
        bi = bilinear(cfa, pat)
        rc = rcd(cfa, pat)
        print(f"[{pat}] starPSNR bi={star_core_psnr(bi, truth, stars):.2f} rcd={star_core_psnr(rc, truth, stars):.2f}  "
              f"fringe bi={fringe_energy(bi, truth, stars):.2e} rcd={fringe_energy(rc, truth, stars):.2e}  "
              f"skyPSNR bi={sky_psnr(bi, truth):.2f} rcd={sky_psnr(rc, truth):.2f}")
```

- [ ] **Step 2: Implement the RCD core** from the fetched `rcd.cc`, replacing the `NotImplementedError`. Stay faithful; document any simplification in comments.

- [ ] **Step 3: Run the gate**

Run: `python3 scratchpad/rcd_debayer.py`
GATE (all 4 patterns): RCD starPSNR **clearly higher** than bilinear AND fringe **clearly lower**, with skyPSNR not meaningfully worse (within ~0.5 dB). If the gate fails, investigate your port against the reference before concluding; if it genuinely fails, report BLOCKED with the numbers.

- [ ] **Step 4: Real-sub sanity check**

Load one real Seestar sub (`~/Documents/lights/Light_NGC 6888_*.fit`, GRBG; read with a tiny FITS reader inline — 2880-byte header blocks, BITPIX 16 with BZERO 32768, dims from NAXIS1/2, normalize to [0,1]). Demosaic a 512×512 crop with both; save PNG crops (`scratchpad/rcd_real_{bilinear,rcd}.png`, any writer available — matplotlib if present, else raw PPM) and report per-channel star-profile consistency (no channel swap: the brightest star's per-channel centroid must coincide within 0.5 px — this is the Bayer-phase check).

- [ ] **Step 5: Emit golden vectors**

For each pattern: a fixed deterministic 16×16 CFA (`rng seed 3`, values from a tiny star field via `ground_truth`-like generation at 16×16, mosaicked), run YOUR `rcd`, and print BOTH arrays as Swift literals (`let cfa_GRBG: [Float] = [...]`, `let expected_GRBG: [Float] = [...]` — expected covers the FULL 16×16×3 planar output including the bilinear-filled border). Put them in the report file verbatim (they will be pasted into the Swift tests).

- [ ] **Step 6: Commit**

```bash
git add scratchpad/rcd_debayer.py
git commit -m "prototype: RCD demosaic gate + golden vectors (vs bilinear)"
```

**Deliverables for T2:** the validated prototype (normative), the golden vectors ×4 patterns in the report, and any noted deviations from rcd.cc.

---

## Task 2: `Debayer.rcd` (TDD, pinned to golden vectors)

**Files:**
- Modify: `Sources/LiveAstroCore/Stacking/Debayer.swift`
- Test: `Tests/LiveAstroCoreTests/DebayerRCDTests.swift`

**Interfaces:**
- Consumes: T1's golden vectors (pasted from the T1 report — the controller injects them into the dispatch); existing `BayerPattern.channel(row:col:)`, `Debayer.bilinear(cfa:pattern:minRows:)`, `Parallel.rows`.
- Produces: `public static func rcd(cfa: AstroImage, pattern: BayerPattern, minRows: Int = 64) -> AstroImage` — 1-channel CFA in, 3-channel planar RGB out, clamped [0,1].

Contract (the golden vectors are normative; this prose summarizes):
- Interior (≥4 px from every edge): the T1 RCD algorithm, ported faithfully from the prototype (the implementer receives the prototype source `scratchpad/rcd_debayer.py` as the reference — port ITS arithmetic, not rcd.cc prose).
- Border (outer 4 px): copy the corresponding pixels from `Debayer.bilinear(cfa:pattern:minRows:)`'s output.
- `cfa.width < 8 || cfa.height < 8` ⇒ return `bilinear(...)` outright.
- Row-parallel via `Parallel.rows` with disjoint writes; `minRows: .max` (serial) must equal `minRows: 1` (parallel) byte-identically.
- Finite, clamped [0,1] output.

- [ ] **Step 1: Write the failing tests** — `DebayerRCDTests` with: `testGoldenVectorGRBG/RGGB/BGGR/GBRG` (paste the four cfa/expected literals; build a 16×16 1-channel `AstroImage` from cfa; assert `rcd(...)` pixels equal expected within `1e-4` elementwise); `testFlatFieldExactEverywhere` (constant 0.37 CFA, 32×32, all patterns → every output pixel 0.37 within 1e-6); `testParallelEqualsSerial` (128×128 random CFA, `minRows: .max` vs `1`, byte-equal); `testTinyFrameFallsBackToBilinear` (6×6 → byte-equal to `bilinear`); `testOutputFiniteAndClamped` (random CFA incl. 0s and 1s → all pixels finite, in [0,1]); `testStarSharperThanBilinear` (synthesize a 64×64 truth with one Gaussian star on flat sky in Swift, mosaic per GRBG using `BayerPattern.channel`, demosaic both ways, assert RCD's summed squared error to truth over the star's 5×5 core is LOWER than bilinear's).
- [ ] **Step 2: Run to verify they fail** — `swift test --filter DebayerRCDTests` → `cannot find 'rcd'`.
- [ ] **Step 3: Implement `Debayer.rcd`** per the contract, porting the prototype's arithmetic.
- [ ] **Step 4: Run to verify they pass** — plus the neighbors: `swift test --filter 'Debayer'` (existing bilinear tests must stay green and unmodified).
- [ ] **Step 5: Commit** — `git add Sources/LiveAstroCore/Stacking/Debayer.swift Tests/LiveAstroCoreTests/DebayerRCDTests.swift && git commit -m "feat: Debayer.rcd — RCD demosaic pinned to prototype golden vectors (TDD)"`

---

## Task 3: `DemosaicMethod` selection end to end

**Files:**
- Modify: `Sources/LiveAstroCore/Stacking/Debayer.swift` (add the enum next to `BayerPattern`)
- Modify: `Sources/LiveAstroCore/Settings/SessionSettings.swift`
- Modify: `Sources/LiveAstroCore/Stacking/StackEngine.swift`
- Modify: `Sources/LiveAstroStudio/AppModel.swift`, `Sources/LiveAstroStudio/ControlView.swift`
- Test: `Tests/LiveAstroCoreTests/SessionSettingsTests.swift`, `Tests/LiveAstroCoreTests/PerformanceTests.swift`

**Interfaces:**
- Consumes: `Debayer.rcd` (T2); the `frameWeightingEnabled`/`relayRetentionDays` settings pattern; `helpToggle`/`InfoButton`/segmented-picker UI patterns.
- Produces: `public enum DemosaicMethod: String, Codable, CaseIterable { case bilinear, rcd }`; `SessionSettings.demosaic: DemosaicMethod` (default `.rcd`, decode `?? .rcd`); `StackEngine.init(..., demosaic: DemosaicMethod = .bilinear)`; `AppModel.demosaic`; "Demosaic" picker.

- [ ] **Step 1: Failing settings tests** — add to `SessionSettingsTests`: `testDemosaicDefaultsRCDAndRoundTrips` (default `.rcd`; set `.bilinear`; encode/decode round-trips) and `testDemosaicBackwardCompatDefaultsRCD` (reuse the existing backward-compat JSON literal; assert `.rcd`).
- [ ] **Step 2: Verify fail** — `swift test --filter SessionSettingsTests`.
- [ ] **Step 3: Implement** — `DemosaicMethod` enum in Debayer.swift; `SessionSettings.demosaic` at all 5 touch points + `.defaults` (`demosaic: .rcd`); `StackEngine`: store `private let demosaic: DemosaicMethod`, init param `demosaic: DemosaicMethod = .bilinear`, and in `displayRGB` switch: `.bilinear → Debayer.bilinear(...)`, `.rcd → Debayer.rcd(...)`; `AppModel`: `var demosaic: DemosaicMethod = .rcd`, persist in `currentSettings()`/`loadSettings()`, pass `demosaic: demosaic` in `makeStackEngine()`; `ControlView`: after the "Keep relay sessions" row, a row `Text("Demosaic") + InfoButton(text: "RCD keeps star cores sharp and fringe-free (recommended). Bilinear is the legacy demosaic.") + Spacer() + Picker` with `Text("Bilinear").tag(DemosaicMethod.bilinear); Text("RCD").tag(DemosaicMethod.rcd)`, segmented, labelsHidden, `maxWidth: 220`, disabled while running/importing.
- [ ] **Step 4: Verify settings pass** — `swift test --filter SessionSettingsTests`.
- [ ] **Step 5: Perf pin** — in `PerformanceTests` (follow its existing release-only skip pattern): build a 3840×2160 random CFA `AstroImage`; measure wall time of `Debayer.bilinear` and `Debayer.rcd` once each; assert `rcd <= 5 * bilinear` elapsed. Run `swift test -c release --filter PerformanceTests` and confirm.
- [ ] **Step 6: Build + full suite** — `swift build`, `swift build -c release` (clean; pre-existing `#SendableClosureCaptures` warning unrelated), `swift test` (0 failures — engine default `.bilinear` keeps every existing test byte-identical).
- [ ] **Step 7: Commit** — `git add -A Sources Tests && git commit -m "feat: Demosaic picker (RCD default in app; engine default bilinear = byte-identical)"`

---

## After all tasks

Whole-branch review (opus) + adversarial pass (numerical: Bayer-phase/pattern correctness, saturation, star fidelity; degenerate: tiny frames, edges, hostile CFA) — the phase check matters: a Bayer-phase color bug shipped once before in this project. Then finish: merge to main + push + repackage dist (standard recipe). Post-merge manual: re-import a few NGC 6888 subs, eyeball star tightness vs the previous master.
