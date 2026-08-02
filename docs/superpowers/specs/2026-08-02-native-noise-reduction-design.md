# Native Noise Reduction — Design

**Goal:** close the live-view noise gap identified in the M8 head-to-head (background grain + green/magenta chroma mottle vs the Seestar's AI-polished output) with a **native, classic, deterministic** denoiser — no AI, no external tools, zero new dependencies — applied non-destructively in the display path, and offered as a backend on the existing master post-process picker.

**Decisions already made (owner):** live view first; classic-only (the "honest processing" identity stands); the same engine is also offered on the master path.

**Non-goals:** no Core ML / AI backend (the seam allows one later); no changes to GraXpert; `master.fit` is never mutated; no watcher or stacking-engine changes; no new UI surface beyond one slider and one picker entry.

---

## 1. The problem, precisely

At low-to-moderate integration (tens of frames), the stretched live stack shows two distinct artifacts:

1. **Chroma mottle** — low-frequency green/magenta splotches across the sky background. This is coarse-scale *color* noise; it survives stacking because OSC chroma converges slower than luma.
2. **Luma grain** — fine background noise, most visible after the aggressive stretch that makes faint nebulosity pop.

They are different noise types and get different treatment. The guardrail, from the Veil night, is Paul's own words: *"keep this kind of nebulosity"* — faint filaments must not be eaten.

## 2. Architecture

One pure engine, two consumers:

```
Sources/LiveAstroCore/Imaging/Denoiser.swift        (new — the engine)
Sources/LiveAstroCore/Processing/NativeDenoiseProcessor.swift  (new — master-path wrapper)
DisplayAdjustments.denoiseStrength                  (new field — display-path control)
SessionPipeline.displayCGImage                      (one new stage in the existing chain)
ControlView                                          (Denoise slider + picker entry)
```

### 2.1 The engine (`Denoiser`)

`Denoiser.apply(_ image: AstroImage, strength: Float) -> AstroImage` — pure, deterministic, Foundation + the existing `Parallel.rows` only. Two stages:

**Stage 1 — chroma mottle suppression (3-channel only; mono passes through).**
Convert RGB to an opponent luma/chroma representation (Y, C1, C2). Downsample chroma 4×. Smooth chroma at coarse scale with a luma-edge-guided filter: large separable blur passes whose per-pixel blend is attenuated where the *luma* gradient is strong, so color never bleeds across star edges or filament boundaries. Upsample, recombine with the untouched luma. This stage kills the green/magenta mottle and is cheap (chroma work happens at 1/16 the pixel count).

**Stage 2 — edge-preserving luma smoothing.**
Guided/bilateral-family filter on Y with two adaptivity inputs: (a) a per-tile background-sigma grid (same tile pattern as `BackgroundExtraction` — smooth harder where the tile is statistically flat sky, back off where signal rises above background), and (b) a gradient-protection threshold that exempts strong edges (star cores, filament rims). Strength maps the user slider to filter radius/range sigma per the prototype's validated curve.

Contracts: `strength == 0` returns the input byte-identical (off costs nothing); NaN/Inf pass through untouched (upstream sanitizes; the engine must not trap); mono images run stage 2 only; images below 64×64 pass through.

### 2.2 Display-path consumer

`DisplayAdjustments` gains `denoiseStrength: Float` (0…1, default **0 / off** for the first release — same conservative precedent as the neutralize toggle; revisit the default after a real-sky A/B). Applied in `SessionPipeline.displayCGImage` **after** stretch and DBE, before CGImage packing — the noise being targeted is the post-stretch appearance, and this placement makes broadcast, snapshots, `latest.png`, and replay all inherit it automatically while `master.fit` stays raw. Codable backward-compatible like every prior adjustment field. The slider follows the DBE pattern including the drag-end `{ editing in if !editing { applyDisplayAdjustments() } }` gotcha.

### 2.3 Master-path consumer

`ProcessorBackend` gains `.nativeDenoise`; `NativeDenoiseProcessor` conforms to the existing `Processor` protocol (master in → processed file out, real produced URL returned). It reads the linear master via `readLinear`, estimates noise sigma from the data (same tile machinery), runs the same two stages in linear domain with the prototype's linear-domain strength mapping, and writes `master_processed.fit` through the existing writer. `isAvailable` is always true — this gives users without GraXpert a denoise option. Picker becomes **None | GraXpert | Native NR**.

## 3. Prototype-first gate (binding, per repo discipline)

Task 1 of the implementation plan is a Python prototype on the real M8 (`~/Documents/LiveAstro/2026-07-08-m8lagoon-3`) and Veil masters, A/B'd with metrics before any Swift is written:

- background luma sigma reduction ≥ 40% at Medium strength (slider 0.5);
- chroma mottle (coarse-scale sigma of the opponent chroma channels) reduction ≥ 50%;
- star FWHM change ≤ 2%;
- filament contrast (line profile across the Veil arc) preserved ≥ 95%;
- A/B PNGs produced for owner eyeballing.

The validated kernel sizes, thresholds, and strength curve become the Swift constants, verbatim — the same pipeline that validated additive-BN, DBE, and RCD. If the guided-filter approach cannot hit these numbers in prototyping, the fallback is à-trous wavelet thresholding (approach B), decided at the gate, not improvised mid-port.

## 4. Performance

Budget: ≤ 1.0 s per application at 26MP in release (the live cadence is one stack update per sub, ≥ 10 s apart; DBE + stretch already run in this window). Pinned by a release-mode performance test like the RCD pin. Chroma stage at 1/16 pixel count + separable passes keeps this comfortable on the CPU ladder; Accelerate/vImage remains the sanctioned escalation if the pin fails, Metal is out of scope.

## 5. Error handling

- Engine never throws; degenerate inputs pass through (0 strength, mono for stage 1, tiny images, non-finite pixels).
- Display path: denoise failure is impossible by construction (pure function); a strength change mid-session follows the existing adjustments push/throttle semantics.
- Master path: standard `Processor` error surface (`noOutput` if the write fails); no partial files (existing temp+rename pattern from the GraXpert fix).

## 6. Testing

- **Unit:** strength-0 byte-identity; determinism (same input → same output); mono/NaN/tiny passthrough; synthetic fixtures — a star field on noisy background asserting background sigma drops while star FWHM and a synthetic filament's contrast hold (the prototype metrics, in miniature).
- **Golden:** one small real-data crop (checked-in, license-clean because it's Paul's own data) with prototype-generated expected output, tolerance-compared — pins the Swift port to the validated prototype.
- **Integration:** snapshot/`latest.png` inherit denoise when enabled; replay frames match; settings round-trip (Codable back-compat test).
- **Processor:** `NativeDenoiseProcessor` round-trip on a synthetic master; picker persistence.
- **Perf:** 26MP release-mode pin ≤ 1.0 s.
- Post-merge: standard adversarial + quality review per repo practice.

## 7. Future seams (explicitly not built now)

- `Denoiser` is the type a Core ML backend would shadow if the classic-only stance ever changes.
- Approach C (stack-aware variance-guided strength maps from the accumulator) can feed stage 2's adaptivity later without changing the engine's interface.
