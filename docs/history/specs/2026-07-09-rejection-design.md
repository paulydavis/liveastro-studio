# LiveAstro Studio — Native-Stacker Rejection Pillar Design

**Date:** 2026-07-09 · **Status:** approved for planning ·
**Origin:** roadmap pillar after the M8 shakedown; community input on rejection algorithms

## 1. Goal

Remove satellite / plane / cosmic-ray outliers during native stacking, **live and
import, at any frame count**, as a **pluggable strategy** — shipping online
winsorized κ-σ first. This turns the Seestar's dilution-only behavior (a trail
fades to Δ/N but never vanishes) into true per-pixel rejection, and it's the axis
where a transparent tool beats the Seestar's whole-frame toss.

## 2. Decisions (made 2026-07-09 with Paul)

| Decision | Choice |
|---|---|
| Strategy | **Online winsorized κ-σ** — incremental, O(1) in frame count, works identically live + import, any N (the 1,483-sub M8 night fits). Chosen over full-stack-in-RAM (caps ~480 frames @8MP / ~80 @8GB) and 2-pass-from-disk (import-only, 2× warp) because storing all frames doesn't fit: 1,483 × ~100 MB (8 MP RGB) ≈ 148 GB > 48 GB RAM |
| Pluggability | A `RejectionMethod` protocol; ship `NoRejection` + `WinsorizedSigmaClip` now; linear-fit / GESD / RCR are protocol-ready future adds |
| Winsorize vs reject | **Winsorize** (clamp to ±kσ, keep the sample) — the Python-validated form; no noise penalty |
| UX | **On by default**, single "Reject outliers (σ-clip)" toggle, plus a **Strength** picker (Low/Med/High → k = 3.5 / 3 / 2.5, default **Med** = validated k=3) shown when enabled |
| Warm-up | Per-pixel: accept raw until that pixel's in-bounds count ≥ **W = 8**, then clip. Guards against over-clipping real faint signal on early/sparse frames |

## 3. Architecture

```
Sources/LiveAstroCore/Stacking/
  RejectionMethod.swift      (protocol + NoRejection + strength→k mapping)
  WinsorizedSigmaClip.swift  (online Welford per-pixel winsorizing)
  StackEngine.swift          (holds a RejectionMethod; applies it before accumulate)
  StackAccumulator.swift     (UNCHANGED — stays a dumb weighted mean)

Sources/LiveAstroStudio/
  AppModel.swift             (rejection on/off + strength; passes to StackEngine)
  ControlView.swift          (toggle + strength picker + tooltips)
  Settings/SessionSettings   (persist rejection settings)
```

### 3.1 RejectionMethod protocol

```swift
/// Transforms an incoming warped RGB frame before it is accumulated, updating
/// its own per-pixel running state. Reference types (hold mutable state).
public protocol RejectionMethod: AnyObject {
    /// Returns the frame to accumulate (winsorized/cleaned). Only pixels where
    /// `mask[i] > 0` are considered in-bounds; the method updates state and
    /// clamps only those. Out-of-bounds pixels are returned unchanged (they are
    /// not accumulated anyway).
    func apply(_ frame: AstroImage, mask: [Float]) -> AstroImage

    /// Discard all accumulated per-pixel state (called from StackEngine.reseed()).
    func reset()
}

/// Pass-through — preserves today's behavior exactly.
public final class NoRejection: RejectionMethod {
    public init() {}
    public func apply(_ frame: AstroImage, mask: [Float]) -> AstroImage { frame }
    public func reset() {}
}

/// Strength → κ mapping for the UI.
public enum RejectionStrength: String, CaseIterable, Codable {
    case low, medium, high
    public var kappa: Float { switch self { case .low: return 3.5; case .medium: return 3.0; case .high: return 2.5 } }
}
```

### 3.2 WinsorizedSigmaClip (online, O(1) in frame count)

Per-pixel-per-channel running **Welford** state: `count`, `mean`, `M2` (three
`[Float]` arrays sized `width·height·channels`). Memory is O(image), O(1) in
frame count: ≈300 MB @8 MP RGB, ≈940 MB @26 MP RGB — acceptable and independent
of how many subs stack.

```swift
public final class WinsorizedSigmaClip: RejectionMethod {
    public init(kappa: Float = 3.0, warmUp: Int = 8)
    public func apply(_ frame: AstroImage, mask: [Float]) -> AstroImage
}
```

For each in-bounds pixel (mask > 0), per channel:
1. If `count < warmUp`: keep `x` as-is (σ meaningless with few samples), then update running stats with `x`.
2. Else: `σ = sqrt(M2 / count)`; `x' = clamp(x, mean − κσ, mean + κσ)`; output `x'`; update running stats with **`x'`** (the clamped value — so a persistent bright trail cannot keep inflating σ).

Output pixel = the (possibly clamped) value; out-of-bounds pixels are copied
through unchanged. No sample is dropped → no per-pixel weight loss → no noise
penalty (the validated property). Welford update: `count += 1; d = v − mean;
mean += d/count; M2 += d·(v − mean)`.

### 3.3 StackEngine integration (surgical)

`StackEngine` gains an injected `rejection: RejectionMethod` (default
`NoRejection()` so existing callers/tests are unchanged). In `processLocked`,
**both** accumulate sites route through it:
- Reference seed (frame 1): `let seed = rejection.apply(rgb, mask: ones); accumulator.add(seed, mask: ones)` — frame 1 is within warm-up, so it passes through, but this keeps the running stats seeded from frame 1.
- Stacked frames: after the warp, `let cleaned = rejection.apply(warped, mask: mask); accumulator.add(cleaned, mask: mask)`.

`reseed()` must also reset the rejection state (new reference → discard running
stats). `StackAccumulator` is untouched. Live and import use the identical path.

### 3.4 UI + persistence

`ControlView` Setup: a **"Reject outliers (σ-clip)"** toggle (default ON); when
on, a **Strength** segmented picker (Low / Med / High, default Med). `SessionSettings`
gains `rejectionEnabled: Bool` (default true) and `rejectionStrength:
RejectionStrength` (default `.medium`), persisted + restored like the rest.
`AppModel` builds `StackEngine(rejection: rejectionEnabled ?
WinsorizedSigmaClip(kappa: strength.kappa) : NoRejection())` at session start.
Hover tips: toggle — "Drop satellite/plane/cosmic-ray streaks by clamping pixels
that deviate from the per-pixel stack statistics."; strength — "Higher = safer
(rejects less); lower = more aggressive."

## 4. Data flow

```
warp → RejectionMethod.apply(frame, mask)     # winsorize in-bounds pixels vs running per-pixel μ,σ
     → StackAccumulator.add(cleaned, mask)     # unchanged weighted mean
running Welford stats persist across frames; reset on reseed()
```

## 5. Error handling / edge cases

| Situation | Behavior |
|---|---|
| First W frames (per pixel) | passed raw; stats build; no clipping |
| Rejection off | `NoRejection` — byte-identical to today |
| Dimension change / reseed | rejection state reset with the accumulator |
| σ = 0 (identical values early) | clamp bounds collapse to mean; a genuinely different pixel is clamped to mean (safe — only after warm-up, where σ=0 means truly flat history) |
| Non-finite pixel | already clamped to [0,1]/finite upstream (FITSReader + Calibrator); Welford stays finite |

## 6. Testing

`WinsorizedSigmaClip`: (a) a bright synthetic outlier in one frame of an otherwise-flat stack → after warm-up its accumulated residual is near μ, not the raw outlier; (b) **no-noise-penalty** — a clean Gaussian stack's output background σ ≈ the un-rejected mean's σ (no inflation from dropped samples); (c) warm-up — the first W frames pass through unclamped; (d) update-with-clamped keeps σ from exploding under a persistent outlier. `NoRejection`: identity. `RejectionStrength.kappa` mapping. **StackEngine**: with rejection on, an injected satellite streak across one sub of a synthetic multi-frame stack is gone from `currentStack()`, and the same stack with `NoRejection` still shows it — the A/B proof. Reseed resets rejection state.

## 7. Non-goals (their own future builds)

Linear-fit / GESD / RCR (protocol-ready, not implemented); a 2-pass or
out-of-core "deep clean" import mode for exact full-stack stats; DBE / gradient
extraction; noise reduction; multithreading (separate perf build — rejection adds
one linear pass per frame, parallelizable later).

## 8. Risks

| Risk | Mitigation |
|---|---|
| Over-clipping real faint signal early | per-pixel warm-up (W=8) before clipping; default Med (k=3) not aggressive; on-by-default but user can lower strength or disable |
| Online baseline weaker than true multi-pass | accepted tradeoff for universality/scale; the pluggable protocol leaves room for a future 2-pass import mode |
| Per-pixel stats memory at 26 MP (~940 MB) | O(1) in frame count; acceptable on target hardware; documented |
| A moving satellite leaves a tiny winsorized residual (clamped, not dropped) | ~Δ/N·(clamped) ≈ near-zero at large N, far better than dilution; validated to erase trails on IC 443 |
