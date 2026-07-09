# Performance & Plate-Solving Trajectory

**Date:** 2026-07-08 · **Status:** forward-looking design note (not yet scheduled) ·
**Origin:** discussion during the M8 Seestar live shakedown

This note records the agreed engineering direction for two related concerns that
will surface as LiveAstro matures toward a competitive native stacker: adding
plate-solving (for north-up orientation and astrometric alignment) without
losing real-time cadence, and the performance ladder (multithreading →
Accelerate → GPU) that the heavier image-quality pillars will require.

## 0. Target hardware — Apple M4 Max, 48 GB unified memory

The primary dev/runtime machine is an **Apple M4 Max with 48 GB unified
memory** (~16-core CPU: 12 performance + 4 efficiency; ~32–40-core GPU;
~400+ GB/s memory bandwidth). This materially reshapes the trajectory below —
it is not a modest laptop:

- **Huge CPU headroom.** Step 1 (multithreading) alone yields ~12× across the
  performance cores; combined with Accelerate/AMX SIMD, the CPU ladder likely
  carries κ-σ + NR on 26 MP frames at real-time cadence *before* GPU is even
  needed.
- **Unified memory = zero-copy GPU.** On Apple Silicon the CPU and GPU share
  the same physical memory, so Metal does **not** pay the CPU↔GPU copy tax that
  makes discrete-GPU stacking painful. That removes the biggest Metal downside
  and makes the GPU step more attractive (and less risky) than the "endgame"
  framing below would suggest on a PC.
- **48 GB working set changes the κ-σ design.** The hard part of proper
  winsorized/2-pass rejection is memory (you need all frames, or careful
  running statistics). A 26 MP OSC frame is ~312 MB in float RGB (~104 MB as
  single-channel CFA); 48 GB comfortably holds a large in-memory working set —
  enough to do **full multi-pass rejection in RAM** instead of settling for an
  online/Welford single-pass approximation. Design κ-σ to exploit this rather
  than assume it must be O(1) memory.

**But design for a hardware *range*, not just the beast.** LiveAstro ships to
friends now and toward a real product later (tier 2 → 3), so the dev machine's
headroom is a luxury, not a floor. Target Macs with far less — base-M
MacBook Airs, older Intel Macs, 8–16 GB memory. The implications:
  - **Scale to available resources at runtime** — thread count to
    `ProcessInfo.activeProcessorCount`, and gate the memory-hungry κ-σ path on
    available RAM (fall back to the O(1) online/Welford accumulator when a full
    in-memory multi-pass working set won't fit). Two rejection backends, chosen
    by budget.
  - **Degrade gracefully, never stall.** On weak hardware, prefer honest
    slow-down or optional quality reductions (skip NR, half-res registration
    already exists, cap in-flight frames) over blowing cadence or OOM. Tonight's
    debug-build crawl is the cautionary tale: on a *modest* machine even the
    release build could feel like that if the per-frame cost isn't managed.
  - **This is exactly why the CPU ladder (Steps 1–2) matters most.**
    Multithreading + Accelerate are what make LiveAstro viable on modest Macs;
    Metal/GPU is a *bonus* on capable ones (M-series, discrete GPUs), never a
    requirement. Keep the CPU path first-class and complete on its own.

## 1. Plate-solving while keeping real-time

**Key idea: solve the *reference frame* once, not every frame.** The native
stacker already registers every sub to the first sub of the session
(`StackEngine.referenceStars`). If we know the reference frame's orientation
(its WCS: center RA/Dec, rotation, scale), the entire stack inherits it for
free. That is **one solve per session** (or per Reseed), amortized to ~zero
per-frame — so it does not threaten cadence. The solve can also run **off the
hot path** (a background task) and simply rotate the display once it lands.

**We already have most of the machinery.** Plate-solving is star-pattern
matching against a *catalog* instead of against the previous frame. We already
have `StarDetector` (grid-background MADN detection, sub-pixel centroids) and
`TriangleMatcher` (triangle-invariant correspondence). A plate-solver reuses
both: detect stars → match their triangle invariants against a catalog's
triangles for the plausible sky region.

**Known-scale "near-solve" is the fast path.** A blind solve (unknown scale +
position) is the slow, index-file-heavy case. But the Seestar (and any fixed
optical train) has a **known pixel scale / FOV**. Fixing scale collapses the
search to center + rotation only — dramatically faster and needing a far
smaller catalog. Practically every deployment we care about has a known scale.

**Catalog / dependency options** (our zero-external-dependency rule is the real
constraint, not the algorithm):
- **Preferred:** bundle a **bright-star catalog subset** (e.g. Tycho-2 or Gaia
  down to ~mag 9 for the working FOV — a few MB) and match with our own
  matcher. Keeps zero-dep, self-contained.
- **Optional escape hatch:** if zero-dep is ever relaxed for an *optional*
  feature, shelling out to a local **ASTAP** solve (~0.5–1 s, small star
  database) is trivial and robust.
- Full **astrometry.net** index files (hundreds of MB–GB) are the heavyweight
  fallback and probably never necessary given known scale.

**Orientation vs. our current display.** Today LiveAstro shows the raw sensor
orientation of the reference sub (top-down-normalized), because it does not
know which way is north. Plate-solving the reference yields the rotation to
north-up, applied once. Until then, a cheap interim is a **manual rotate
control** in the broadcast window (a fixed display rotation the user picks).

**Bottom line:** north-up via plate-solving is *not hard* and does *not* cost
cadence, because it is a one-time, off-hot-path operation. The work is
packaging a compact catalog + a known-scale matcher on top of machinery we
already have.

## 2. Performance ladder: multithread → Accelerate → GPU

The per-frame budget is generous *today* (release build ≈ 1.2 s per 8 MP
Seestar sub; Seestar cadence ≈ 24 s), so nothing is urgent yet. Pressure
arrives with **heavier per-pixel work** (κ-σ rejection touching every pixel,
possibly 2-pass; gradient extraction/DBE; noise reduction; drizzle) and
**bigger sensors** (26 MP ASI2600) and shorter cadence. There is a pragmatic
ladder before Metal:

### Step 1 — Multithread the hot loops (cheap, do first)
Tonight's `sample` of the stuck debug run showed **100% of time in
`Warp.apply` on a single core**. Warp, debayer, star-detect, and accumulate are
per-pixel / per-tile and embarrassingly parallel. `DispatchQueue.concurrentPerform`
over row ranges gives ~5–8× on Apple-silicon (8–10 cores) with modest effort.

Note the concurrency boundary: `StackEngine`'s `NSLock` serializes *frames*
(one `process()` at a time); parallelism lives **inside** a frame's hot loops,
not across frames. (Cross-frame pipelining is possible later but the shared
accumulator needs care.)

### Step 2 — Accelerate / vImage / vDSP (already an allowed dependency)
Accelerate is a system framework already inside our zero-dep allowance
(same standing as CryptoKit). SIMD-optimized building blocks map directly onto
our hot paths: `vImageAffineWarp_*` for Warp, vImage for debayer/convolution,
vDSP for stats/accumulation. Another few× on top of threading, no GPU
complexity. This is the highest value-per-effort step after threading.

### Step 3 — Metal (GPU) is the endgame
For 26 MP+, drizzle, real-time NR, and per-pixel rejection, Metal compute
shaders are the ceiling (10–100× on resampling). It is still an investment
(compute pipelines, buffer management), but on the M4 Max's **unified memory
the CPU↔GPU copy tax is gone** (§0) — the usual "keep data resident on-GPU
across stages" caveat largely dissolves, since CPU and GPU address the same
buffers. That makes Metal lower-risk here than on a discrete-GPU PC. Still,
reach for it only when Steps 1–2 are genuinely exhausted — on this hardware
that may be a long way off.

### Architectural prep to do *now* (so GPU is painless later)
Keep every pipeline stage a **discrete kernel over a flat `[Float]` pixel
buffer** — which the code largely already is (planar `AstroImage.pixels`,
`Warp`/`Debayer`/`StackAccumulator` are self-contained transforms). Then each
stage can be swapped CPU→Accelerate→Metal without restructuring the pipeline.

## 3. Sequencing against the product roadmap

Performance work is not a standalone pillar — it rides alongside the
image-quality pillars that create the demand for it:

```
seamless "Seestar Live" preset      (Paul's UX mandate)
  → winsorized κ-σ rejection  + multithread the hot loops alongside it
  → noise reduction
  → plate-solve / north-up  (+ interim manual rotate control)
  → Metal/GPU  (when CPU headroom runs out: big sensors, drizzle, real-time NR)
```

The trigger to prioritize Step 1/2 is the moment κ-σ + NR land on 26 MP frames:
single-threaded Warp will blow the cadence budget there, where it has ample
headroom on 8 MP Seestar subs today.

## References
- `Sources/LiveAstroCore/Stacking/Warp.swift` — the current single-threaded
  resampler; first target for multithreading + `vImageAffineWarp`.
- `Sources/LiveAstroCore/Stacking/StarDetector.swift`,
  `TriangleMatcher.swift` — the detection + pattern-matching machinery a
  plate-solver would reuse.
- `Sources/LiveAstroCore/Stacking/StackEngine.swift` — the `NSLock` frame
  serialization boundary; parallelism goes inside `processLocked`, not across it.
