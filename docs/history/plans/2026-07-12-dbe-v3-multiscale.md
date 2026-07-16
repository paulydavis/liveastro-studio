# DBE v3 — Multiscale Background Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a multiscale, structure-protected background model as the primary DBE (with the existing polynomial as auto-fallback), removing the local/corner gradients the polynomial cannot, controlled by two sliders (Scale, Smoothest).

**Architecture:** Prototype the recipe in Python first (Task 1) to validate it beats the polynomial and to fix the default constants; then port to a deterministic Foundation/Accelerate-free Swift `flattenMultiscale` (Task 2), wire it into the display path + settings (Task 3), and expose Scale/Smoothest sliders (Task 4). Display-path only; the linear master is never touched.

**Tech Stack:** Python (numpy/scipy) for the prototype; Swift 5.10 / SwiftUI / SwiftPM / XCTest for the port. Zero new Swift dependencies.

## Global Constraints

- Swift 5.10, macOS 14+. `LiveAstroCore` imports Foundation / CoreGraphics / Accelerate only. Zero external Swift dependencies.
- Display-path only; the linear master is never modified.
- Deterministic; sanitize non-finite inputs to 0 (ingest pattern, as `flatten` does).
- Multiscale is primary; the existing polynomial `flatten` is retained as the auto fallback (not deleted).
- Core logic TDD'd (`swift test --filter LiveAstroCoreTests`); the Python prototype is a validation artifact (scratchpad, not shipped); app/UI is build/manual-verified.
- **Prototype-first:** Tasks 2–4 consume the default constants VALIDATED in Task 1's report. The concrete constants written in this plan are the prototype's *starting* values; Task 1's report supersedes any it tunes, and the SDD controller injects the final values into the Task 2 dispatch.
- Co-Authored-By Claude trailer allowed in this repo.

**Scratchpad dir (this session):** `/private/tmp/claude-501/-Users-pauldavis/2349d1c1-e213-4a31-a397-bea11f9674d7/scratchpad` — referred to below as `$SCRATCH`. IC443 calibrated data lives under `$SCRATCH/import_ic443_cal`.

---

### Task 1: Python prototype + validation (produces the validated recipe & constants)

**Files:**
- Create: `$SCRATCH/dbe_multiscale.py` (not shipped; validation artifact)

**Interfaces:**
- Consumes: nothing (leaf research).
- Produces (in the task report): the validated default constants — `scaleDefaultPct`, `smoothestDefault`, `k` (sigma for structure rejection), `growRadius`, `downsample D`, `maxIters`, `fallbackFraction` — plus a metrics table (multiscale vs polynomial) and before/after PNG paths. These constants feed Task 2.

- [ ] **Step 1: Write the prototype**

Create `$SCRATCH/dbe_multiscale.py`:

```python
import numpy as np
from scipy.ndimage import gaussian_filter, binary_dilation
import os, glob

SCRATCH = os.path.dirname(os.path.abspath(__file__))

# ---- inputs -------------------------------------------------------------
def load_ic443():
    """Load the IC443 calibrated master as a float [0,1] HxWx3 array, if present."""
    # Try a stacked master PNG/npy the prior additive-BN work produced; else None.
    for pat in ["ic443*master*.npy", "import_ic443_cal/*master*.npy", "D_swift_additive*.npy"]:
        hits = glob.glob(os.path.join(SCRATCH, pat))
        if hits:
            a = np.load(hits[0]).astype(np.float32)
            if a.ndim == 2: a = np.stack([a]*3, -1)
            return a / max(1e-6, a.max())
    return None

def synthetic_hard_gradient(h=800, w=1200):
    """Flat sky + a strong LOCAL corner gradient + stars + a nebula blob.
    The corner gradient is what a low-order polynomial cannot remove."""
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    base = 0.06
    # broad tilt (poly CAN handle this)
    broad = 0.04 * (xx / w) + 0.03 * (yy / h)
    # local corner glow (poly CANNOT handle this): a 2D logistic bump in one corner
    r = np.hypot(xx - w, yy - h) / (0.5 * np.hypot(w, h))
    corner = 0.12 / (1 + np.exp(6 * (r - 0.5)))
    sky = base + broad + corner
    img = np.stack([sky, sky, sky], -1).astype(np.float32)
    rng = np.random.default_rng(42)
    # stars
    for _ in range(300):
        cy, cx = rng.integers(0, h), rng.integers(0, w)
        img[max(0,cy-3):cy+3, max(0,cx-3):cx+3] += 0.5
    # a nebula blob (extended structure — must be protected)
    ny, nx = h*0.4, w*0.45
    blob = 0.25*np.exp(-(((xx-nx)**2)/(2*60**2) + ((yy-ny)**2)/(2*45**2)))
    img += blob[..., None]
    return np.clip(img, 0, 1)

# ---- models -------------------------------------------------------------
def multiscale_background(img, scale_pct, smoothest, k=3.0, grow=2, D=4, max_iters=5):
    """Per-channel spatially-varying background via iterative smooth/reject/inpaint."""
    h, w, c = img.shape
    out = img.copy()
    for ch in range(c):
        small = img[::D, ::D, ch].astype(np.float32)
        sh, sw = small.shape
        sigma = max(1.0, scale_pct/100.0 * max(sh, sw))
        work = small.copy()
        for _ in range(max_iters):
            bg = gaussian_filter(work, sigma)
            resid = work - bg
            s = 1.4826 * np.median(np.abs(resid - np.median(resid))) + 1e-6
            mask = resid > k * s
            if grow > 0:
                mask = binary_dilation(mask, iterations=grow)
            work = np.where(mask, bg, work)   # inpaint structure with the smooth bg
        bg = gaussian_filter(work, sigma)
        if smoothest > 0:
            bg = gaussian_filter(bg, sigma * 0.5 * smoothest)
        # upsample bg back to full res (nearest-block is fine — it's smooth)
        up = np.repeat(np.repeat(bg, D, 0), D, 1)[:h, :w]
        ped = float(up.min())
        out[..., ch] = np.clip(img[..., ch] - up + ped, 0, 1)
    return out

def poly_background(img, degree=2):
    """Degree-2 per-channel tile-median polynomial (matches Swift `flatten`)."""
    h, w, c = img.shape; out = img.copy(); T = 32
    for ch in range(c):
        xs, ys, vs = [], [], []
        for ty in range(T):
            for tx in range(T):
                y0,y1 = ty*h//T,(ty+1)*h//T; x0,x1 = tx*w//T,(tx+1)*w//T
                if y1<=y0 or x1<=x0: continue
                vs.append(np.median(img[y0:y1,x0:x1,ch]))
                ys.append(((y0+y1)/2)/h*2-1); xs.append(((x0+x1)/2)/w*2-1)
        xs,ys,vs = map(np.array,(xs,ys,vs))
        med = np.median(vs); madn = 1.4826*np.median(np.abs(vs-med))+1e-9
        keep = vs <= med + 2.0*madn
        A = np.stack([np.ones_like(xs),xs,ys,xs*xs,xs*ys,ys*ys],1)[keep]
        coef,*_ = np.linalg.lstsq(A, vs[keep], rcond=None)
        gy,gx = np.mgrid[0:h,0:w]; nx = gx/w*2-1; ny = gy/h*2-1
        surf = (coef[0]+coef[1]*nx+coef[2]*ny+coef[3]*nx*nx+coef[4]*nx*ny+coef[5]*ny*ny)
        ped = float(surf.min())
        out[...,ch] = np.clip(img[...,ch]-surf+ped,0,1)
    return out

# ---- metric -------------------------------------------------------------
def flatness(img):
    """Lower is flatter. Background spread over central-sky + corner-vs-center delta."""
    h,w,_ = img.shape; g = img.mean(2)
    # sky sample: 5th percentile per 32x32 tile (background), over a central region
    tiles = []
    for ty in range(4, 28):
        for tx in range(4, 28):
            y0,y1=ty*h//32,(ty+1)*h//32; x0,x1=tx*w//32,(tx+1)*w//32
            tiles.append(np.percentile(g[y0:y1,x0:x1], 5))
    tiles = np.array(tiles)
    corner = np.percentile(g[int(h*0.85):, int(w*0.85):], 5)
    center = np.percentile(g[int(h*0.45):int(h*0.55), int(w*0.45):int(w*0.55)], 5)
    return float(tiles.std()), float(abs(corner - center))

# ---- run ----------------------------------------------------------------
def save_png(a, path):
    from PIL import Image
    lo,hi = np.percentile(a, 1), np.percentile(a, 99)
    b = np.clip((a-lo)/max(1e-6,hi-lo),0,1)
    Image.fromarray((b*255).astype(np.uint8)).save(path)

if __name__ == "__main__":
    cases = {"synthetic": synthetic_hard_gradient()}
    ic = load_ic443()
    if ic is not None: cases["ic443"] = ic
    else: print("NOTE: IC443 master not found in scratchpad; synthetic case only.")

    SCALE, SMOOTHEST = 3.0, 0.5   # starting knobs; tune here until the corner gradient is gone
    print(f"{'case':10} {'model':10} {'skyStd':>10} {'cornerDelta':>12}")
    for name, img in cases.items():
        for label, fn in [("original", lambda x: x),
                          ("poly", poly_background),
                          ("multiscale", lambda x: multiscale_background(x, SCALE, SMOOTHEST))]:
            res = fn(img)
            std, dl = flatness(res)
            print(f"{name:10} {label:10} {std:10.5f} {dl:12.5f}")
            save_png(res, os.path.join(SCRATCH, f"dbe_{name}_{label}.png"))
    print(f"\nCHOSEN DEFAULTS: scale={SCALE}%, smoothest={SMOOTHEST}, k=3.0, grow=2, D=4, maxIters=5, fallbackFraction=0.5")
```

- [ ] **Step 2: Run the prototype**

Run: `python3 "$SCRATCH/dbe_multiscale.py"` (install deps if missing: `pip install numpy scipy pillow`)
Expected: a metrics table printing `skyStd` + `cornerDelta` for original / poly / multiscale on the synthetic (and IC443 if present), and `dbe_*.png` images written.

- [ ] **Step 3: Validate + tune (the gate)**

Confirm on the metrics table that **multiscale's `cornerDelta` is materially lower than poly's** on the synthetic hard gradient (and IC443 if present) — i.e. the multiscale model removes the local corner gradient the polynomial leaves. If not, tune `SCALE` down (follow more local variation) and `SMOOTHEST` toward 0, re-run, until it does. Visually confirm `dbe_synthetic_multiscale.png` is flat AND the nebula blob is intact (structure not eaten). Record the final `(scale, smoothest, k, grow, D, maxIters, fallbackFraction)` in the report.

- [ ] **Step 4: Commit the artifact + write the report**

```bash
cd ~/Desktop/liveastro-studio
git add -f "$SCRATCH/dbe_multiscale.py" 2>/dev/null || true   # if scratch is gitignored, skip; the report captures it
git commit -m "chore: DBE v3 multiscale Python prototype (validation artifact)" || echo "scratch not tracked — recipe captured in report"
```

Report the metrics table, the chosen defaults, and the PNG paths in the task report. (If `$SCRATCH` is git-ignored, the commit is a no-op; the report + the validated constants are the real deliverable.)

---

### Task 2: Swift `flattenMultiscale` (TDD)

**Files:**
- Modify: `Sources/LiveAstroCore/Imaging/BackgroundExtraction.swift` (add `flattenMultiscale` + private blur/downsample helpers)
- Test: `Tests/LiveAstroCoreTests/BackgroundExtractionMultiscaleTests.swift`

**Interfaces:**
- Consumes: existing `BackgroundExtraction.flatten(_:degree:tilesPerAxis:rejectionSigma:)` (for the fallback); the validated constants from **Task 1's report** (the values below are the prototype starting points — replace with Task 1's final values if they differ).
- Produces: `public static func flattenMultiscale(_ image: AstroImage, scale: Double, smoothest: Double) -> AstroImage`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LiveAstroCoreTests/BackgroundExtractionMultiscaleTests.swift`:

```swift
import XCTest
@testable import LiveAstroCore

final class BackgroundExtractionMultiscaleTests: XCTestCase {
    // 3-channel image: flat base + a LOCAL corner glow (a low-order polynomial cannot remove this).
    func cornerGradientImage(w: Int, h: Int) -> AstroImage {
        var px = [Float](repeating: 0, count: w*h*3)
        for c in 0..<3 { for y in 0..<h { for x in 0..<w {
            let r = hypot(Double(x - w), Double(y - h)) / (0.5 * hypot(Double(w), Double(h)))
            let glow = 0.12 / (1 + exp(6*(r - 0.5)))
            px[c*w*h + y*w + x] = Float(0.06 + glow)
        } } }
        return AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
    }
    // background spread over a central sky region.
    func skySpread(_ img: AstroImage) -> Float {
        let w = img.width, h = img.height
        var lo: Float = .greatestFiniteMagnitude, hi: Float = -.greatestFiniteMagnitude
        for y in (h/4)..<(3*h/4) { for x in (w/4)..<(3*w/4) {
            let v = img.pixels[y*w + x]; lo = min(lo, v); hi = max(hi, v)
        } }
        return hi - lo
    }

    func testLocalCornerGradientRemoved() {
        let img = cornerGradientImage(w: 256, h: 192)
        let before = skySpread(img)
        let out = BackgroundExtraction.flattenMultiscale(img, scale: 3.0, smoothest: 0.5)
        let after = skySpread(out)
        XCTAssertGreaterThan(before, 0.02)          // the corner glow really varies the sky
        XCTAssertLessThan(after, before * 0.3)      // multiscale flattens the LOCAL gradient
        XCTAssertEqual(out.width, 256); XCTAssertEqual(out.channels, 3)
    }

    func testFlatImageUnchangedWithinTolerance() {
        let w = 128, h = 128
        let img = AstroImage(width: w, height: h, channels: 3,
                             pixels: [Float](repeating: 0.2, count: w*h*3), sourceIsLinear: true)
        let out = BackgroundExtraction.flattenMultiscale(img, scale: 3.0, smoothest: 0.5)
        for v in out.pixels { XCTAssertEqual(v, 0.2, accuracy: 5e-3) }
    }

    func testBrightBlobPreserved() {
        let w = 256, h = 192
        var px = cornerGradientImage(w: w, h: h).pixels
        let plane = w*h
        for c in 0..<3 { for y in 0..<h { for x in 0..<w {
            let dx = Double(x-128), dy = Double(y-96)
            px[c*plane + y*w + x] += Float(0.5*exp(-(dx*dx+dy*dy)/(2*10.0*10.0)))
        } } }
        let img = AstroImage(width: w, height: h, channels: 3, pixels: px, sourceIsLinear: true)
        let out = BackgroundExtraction.flattenMultiscale(img, scale: 3.0, smoothest: 0.5)
        let peak = out.pixels[96*w + 128], localSky = out.pixels[20*w + 20]
        XCTAssertGreaterThan(peak - localSky, 0.3)   // blob not eaten by the background model
    }

    func testMonoPassthrough() {
        let img = AstroImage(width: 8, height: 8, channels: 1,
                             pixels: [Float](repeating: 0.3, count: 64), sourceIsLinear: true)
        XCTAssertEqual(BackgroundExtraction.flattenMultiscale(img, scale: 3, smoothest: 0.5).pixels, img.pixels)
    }

    func testNaNInputProducesFiniteOutput() {
        var px = cornerGradientImage(w: 64, h: 64).pixels
        px[100] = .nan; px[64*64 + 7] = .infinity
        let img = AstroImage(width: 64, height: 64, channels: 3, pixels: px, sourceIsLinear: true)
        let out = BackgroundExtraction.flattenMultiscale(img, scale: 3, smoothest: 0.5)
        XCTAssertTrue(out.pixels.allSatisfy { $0.isFinite })
    }

    func testDeterministic() {
        let img = cornerGradientImage(w: 128, h: 96)
        let a = BackgroundExtraction.flattenMultiscale(img, scale: 3, smoothest: 0.5)
        let b = BackgroundExtraction.flattenMultiscale(img, scale: 3, smoothest: 0.5)
        XCTAssertEqual(a.pixels, b.pixels)
    }

    func testStructureFillsFrameFallsBackToPolynomial() {
        // A frame that is almost entirely bright structure → too little sky → poly fallback.
        let w = 96, h = 96
        let img = AstroImage(width: w, height: h, channels: 3,
                             pixels: [Float](repeating: 0.8, count: w*h*3), sourceIsLinear: true)
        let ms = BackgroundExtraction.flattenMultiscale(img, scale: 3, smoothest: 0.5)
        let poly = BackgroundExtraction.flatten(img, degree: 2)
        XCTAssertEqual(ms.pixels, poly.pixels)   // fell back to the polynomial
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BackgroundExtractionMultiscaleTests`
Expected: FAIL — `type 'BackgroundExtraction' has no member 'flattenMultiscale'`.

- [ ] **Step 3: Implement `flattenMultiscale` + helpers**

Add to `Sources/LiveAstroCore/Imaging/BackgroundExtraction.swift` (inside the enum). Constants are Task 1's starting values — replace with Task 1's validated values if they differ:

```swift
    /// Spatially-varying, structure-protected background model (DBE v3 primary).
    /// Iteratively smooths at the `scale` radius, rejects+inpaints structure, then
    /// subtracts the model. Follows LOCAL/corner gradients a low-order polynomial
    /// cannot. Falls back to `flatten(_,degree:2)` when structure fills the frame.
    /// Display-path only; deterministic. `scale` is % of image size; `smoothest`
    /// is the final blur strength.
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
        let fallbackFraction: Float = 0.5

        let sw = max(2, w / D), sh = max(2, h / D)
        let scaleRadius = max(1, Int((scale / 100.0) * Double(max(sw, sh))))

        var out = src
        var totalStructureFrac: Float = 0
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
            var lastMask = [Bool](repeating: false, count: sw*sh)
            for _ in 0..<maxIters {
                let bg = boxBlur(work, sw, sh, radius: scaleRadius)
                var resid = [Float](repeating: 0, count: sw*sh)
                for idx in 0..<resid.count { resid[idx] = work[idx] - bg[idx] }
                let s = madSigma(resid)
                var mask = [Bool](repeating: false, count: sw*sh)
                for idx in 0..<mask.count where resid[idx] > k * s { mask[idx] = true }
                mask = dilate(mask, sw, sh, iterations: grow)
                for idx in 0..<work.count where mask[idx] { work[idx] = bg[idx] }
                lastMask = mask
            }
            var bg = boxBlur(work, sw, sh, radius: scaleRadius)
            if smoothest > 0 {
                bg = boxBlur(bg, sw, sh, radius: max(1, Int(Double(scaleRadius) * 0.5 * smoothest)))
            }
            totalStructureFrac += Float(lastMask.lazy.filter { $0 }.count) / Float(sw*sh) / 3
            // 3. upsample (block replicate) to full res
            var up = [Float](repeating: 0, count: plane)
            for y in 0..<h { for x in 0..<w {
                up[y*w + x] = bg[min(sh-1, y/D)*sw + min(sw-1, x/D)]
            } }
            perChannelModelUp[c] = up
        }

        // 4. structure fills frame → too little sky → polynomial fallback
        if totalStructureFrac > fallbackFraction { return flatten(image, degree: 2) }

        // 5. subtract with clamp-safe pedestal re-add
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BackgroundExtractionMultiscaleTests`
Expected: PASS — all 7 tests green. (If `testLocalCornerGradientRemoved` is marginal, that indicates the constants need Task-1's tuned values — apply them.)
Run: `swift test --filter BackgroundExtractionTests`
Expected: PASS (existing polynomial tests unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Imaging/BackgroundExtraction.swift Tests/LiveAstroCoreTests/BackgroundExtractionMultiscaleTests.swift
git commit -m "feat: multiscale background extraction (DBE v3 primary) with poly fallback (TDD)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `DisplayAdjustments` fields + `SessionPipeline` wiring (TDD + build)

**Files:**
- Modify: `Sources/LiveAstroCore/Imaging/DisplayAdjustments.swift` (add `bgScale`, `bgSmoothest`)
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` (route DBE through `flattenMultiscale`)
- Test: `Tests/LiveAstroCoreTests/DisplayAdjustmentsTests.swift` (extend, or the existing settings test file)

**Interfaces:**
- Consumes: `flattenMultiscale(_:scale:smoothest:)` (Task 2); Task 1's validated defaults for the neutral field values.
- Produces: `DisplayAdjustments.bgScale: Double`, `DisplayAdjustments.bgSmoothest: Double`.

- [ ] **Step 1: Write the failing test (backward-compat decode + defaults)**

Add to the DisplayAdjustments test file (create `Tests/LiveAstroCoreTests/DisplayAdjustmentsTests.swift` if none exists):

```swift
import XCTest
@testable import LiveAstroCore

final class DisplayAdjustmentsDBEv3Tests: XCTestCase {
    func testNewFieldsHaveDefaultsAndRoundTrip() throws {
        var a = DisplayAdjustments.neutral
        XCTAssertEqual(a.bgScale, 3.0, accuracy: 1e-9)      // Task-1 validated default
        XCTAssertEqual(a.bgSmoothest, 0.5, accuracy: 1e-9)
        a.bgScale = 2.0; a.bgSmoothest = 0.2
        let data = try JSONEncoder().encode(a)
        let back = try JSONDecoder().decode(DisplayAdjustments.self, from: data)
        XCTAssertEqual(back.bgScale, 2.0, accuracy: 1e-9)
        XCTAssertEqual(back.bgSmoothest, 0.2, accuracy: 1e-9)
    }

    func testDecodesOldSettingsWithoutBgFields() throws {
        // An old settings blob (no bgScale/bgSmoothest) must decode to defaults.
        let old = #"{"blackPoint":0,"midtoneStrength":0,"saturation":1,"backgroundExtraction":true,"backgroundDegree":2}"#
        let a = try JSONDecoder().decode(DisplayAdjustments.self, from: Data(old.utf8))
        XCTAssertEqual(a.bgScale, 3.0, accuracy: 1e-9)
        XCTAssertEqual(a.bgSmoothest, 0.5, accuracy: 1e-9)
        XCTAssertTrue(a.backgroundExtraction)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter DisplayAdjustmentsDBEv3Tests`
Expected: FAIL — `value of type 'DisplayAdjustments' has no member 'bgScale'`.

- [ ] **Step 3: Add the fields (mirror the existing codable pattern)**

In `Sources/LiveAstroCore/Imaging/DisplayAdjustments.swift`: add stored props `public var bgScale: Double` and `public var bgSmoothest: Double`; add them to the memberwise `init` with defaults `bgScale: Double = 3.0, bgSmoothest: Double = 0.5` (Task-1 values); add to `CodingKeys`; in `init(from:)` `bgScale = try c.decodeIfPresent(Double.self, forKey: .bgScale) ?? 3.0` and `bgSmoothest = … ?? 0.5`; ensure `.neutral` uses the defaults; keep `backgroundExtraction` and keep decoding `backgroundDegree` (unused by UI now) for old-blob compatibility. Follow the exact pattern already used for `backgroundExtraction`/`backgroundDegree` in that file.

- [ ] **Step 4: Route the DBE call through multiscale**

In `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` `displayCGImage`, replace:
```swift
        let flattened = adj.backgroundExtraction
            ? BackgroundExtraction.flatten(linear, degree: adj.backgroundDegree)
            : linear
```
with:
```swift
        let flattened = adj.backgroundExtraction
            ? BackgroundExtraction.flattenMultiscale(linear, scale: adj.bgScale, smoothest: adj.bgSmoothest)
            : linear
```

- [ ] **Step 5: Run tests + build**

Run: `swift test --filter DisplayAdjustmentsDBEv3Tests` → PASS.
Run: `swift test --filter LiveAstroCoreTests` → all pass.
Run: `swift build` → Build complete.

- [ ] **Step 6: Commit**

```bash
git add Sources/LiveAstroCore/Imaging/DisplayAdjustments.swift Sources/LiveAstroCore/Pipeline/SessionPipeline.swift Tests/LiveAstroCoreTests/DisplayAdjustmentsTests.swift
git commit -m "feat: DisplayAdjustments bgScale/bgSmoothest; route DBE through multiscale (TDD)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: ControlView Scale/Smoothest sliders (build/manual-verified)

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift` (the Background Extraction section)

**Interfaces:**
- Consumes: `DisplayAdjustments.bgScale`/`bgSmoothest` (Task 3), bound via `$model.displayAdjustments`.
- Produces: nothing (leaf view).

- [ ] **Step 1: Replace the degree control with two sliders**

In `Sources/LiveAstroStudio/ControlView.swift`, find the Background Extraction section (the `backgroundExtraction` toggle + `backgroundDegree` control). Keep the toggle; replace the degree control with two sliders, matching the existing display-adjustment slider idiom (Slider + label + `.help`, disabled/enabled with the toggle):

```swift
                if model.displayAdjustments.backgroundExtraction {
                    HStack {
                        Text("Scale").frame(width: 90, alignment: .leading)
                        Slider(value: $model.displayAdjustments.bgScale, in: 1...15)
                        Text(String(format: "%.1f%%", model.displayAdjustments.bgScale))
                            .frame(width: 48, alignment: .trailing).monospacedDigit()
                    }
                    .help("Smoothing scale as % of image size — lower follows local/corner gradients, higher removes only broad gradients.")
                    HStack {
                        Text("Smoothest").frame(width: 90, alignment: .leading)
                        Slider(value: $model.displayAdjustments.bgSmoothest, in: 0...3)
                        Text(String(format: "%.1f", model.displayAdjustments.bgSmoothest))
                            .frame(width: 48, alignment: .trailing).monospacedDigit()
                    }
                    .help("Extra blur on the background model — raise to remove residual blotchiness, lower to track non-smooth gradients.")
                }
```
Remove the old `backgroundDegree` UI control (Picker/Stepper) entirely. If the Reset button resets display adjustments, ensure it restores `bgScale`/`bgSmoothest` to the neutral defaults (it will, if it assigns `.neutral`).

- [ ] **Step 2: Build (debug)**

Run: `swift build`
Expected: `Build complete!` no errors. (Confirm no remaining references to `backgroundDegree` in ControlView.)

- [ ] **Step 3: Core suite green + release build**

Run: `swift test --filter LiveAstroCoreTests` → all pass.
Run: `swift build -c release` → succeeds.

- [ ] **Step 4: Manual check (RELEASE)**

Launch; open a stacked frame with a light-pollution/corner gradient; toggle **Background Extraction** on; drag **Scale** down and **Smoothest** toward 0 and confirm the corner gradient flattens live (throttled re-render) without eating nebula/galaxy signal; confirm the settings persist across relaunch.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroStudio/ControlView.swift
git commit -m "feat: DBE Scale/Smoothest sliders (replace polynomial-degree control)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage:**
- Multiscale algorithm (downsample → iterate smooth/reject/inpaint → Smoothest → subtract + pedestal) → Task 2 `flattenMultiscale`. ✅
- Prototype-first validation on IC443 + synthetic hard gradient, produces defaults → Task 1. ✅
- Auto poly-fallback when structure fills frame → Task 2 (`fallbackFraction`) + `testStructureFillsFrameFallsBackToPolynomial`. ✅
- Display-path only; master untouched → Task 3 wires `displayCGImage` only (the master-write path is not touched). ✅
- Two knobs Scale/Smoothest, codable backward-compat → Task 3 fields + Task 4 sliders. ✅
- Deterministic, mono passthrough, NaN-sanitized → Task 2 tests. ✅
- Structure (blob) preserved → Task 2 `testBrightBlobPreserved`. ✅

**2. Placeholder scan:** No lazy TBDs. The one legitimate cross-task dependency (Task 2/3 constants come from Task 1's validation) is explicitly modeled: concrete starting values are written throughout (3.0 / 0.5 / k=3 / grow=2 / D=4 / maxIters=5 / fallback=0.5), and the plan states Task 1's report supersedes any it tunes. Every code step contains complete code.

**3. Type consistency:** `flattenMultiscale(_:scale:smoothest:)` signature identical across Task 2 (def), Task 3 (call), and the tests. `bgScale`/`bgSmoothest` names identical across Task 3 (def) and Task 4 (binding). Fallback calls `flatten(_,degree:2)` — matches the existing signature. Blur/dilate/madSigma helpers are defined in Task 2 and used only there.
