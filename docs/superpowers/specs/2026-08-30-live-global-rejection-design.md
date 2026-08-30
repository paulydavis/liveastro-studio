# Live Global Rejection (Real-Time Trail-Free Stacking) — Design

**Status:** Design (brainstormed 2026-08-30; revised after review round 1). Roadmap origin: §7a.

**Goal (one sentence):** While live-stacking, remove satellite trails and other
single-frame outliers from the **broadcast outputs** in near-real-time by
periodically recomputing a full-set, robustly-clipped master from the recorded
subs — something the online engine structurally cannot do — while the operator's
per-sub live *preview* and per-sub ingest latency stay exactly as they are today.

**Why this is the standout, not import-only:** offline global rejection (Siril,
DSS, PixInsight) is table stakes. *Live* stacking that kills a Starlink train as
it crosses — while broadcasting — is unique to a live-broadcast app and is the
demo that sells LiveAstro. Import/re-stack gets the same core later for free.

---

## Background — why the online engine can't do this

Live and import share one `WinsorizedSigmaClip` (`StackEngine.rejection`). It is an
*online* κ-σ estimator: O(1) memory in frame count, an 8-frame per-pixel warm-up
before it clips anything, and it *clamps* outliers to ±κσ rather than dropping
them and cannot un-add a warm-up contribution. Correct for bounded-memory 26 MP
broadcast, but structurally weak at removing a single-frame outlier in a shallow
stack. Confirmed 2026-08-29: an 11-sub real M 51 stack kept a visible satellite
trail. A *global* combine that sees every survivor's value at each pixel — with a
**robust (median/MAD) center**, not mean/σ — rejects an outlier in 1 of N outright
at any depth, including the 5–11 frame case where mean/σ would let a bright trail
inflate σ and survive.

## Scope for v1

**In:** live, native `FolderFrameSource(.live)` sources whose subs are on local
disk (via the relay); a **robust clipped-mean** combine (median/MAD center →
weighted clipped mean); ASI2600-class large sensors; the broadcast outputs and
final `master.fit` become the clean global result.

**Out (documented follow-ups):** median-*output* combine and the pure in-RAM
Seestar variant (§7a); the import/"Stack Previous Shoot"/re-stack surface;
network/SMB live (stays online-only).

**Global constraints (bind every task):**
- The online path (`StackEngine.processDetailed`, `handleNative`, the accumulator)
  and the **operator's per-sub live preview** are not modified in behavior.
  Feature OFF ⇒ byte-identical outputs to today.
- The refiner runs entirely off the online consumer — it never blocks per-sub
  ingest or the preview.
- **Generation-scoped:** transforms are only valid against the reference that was
  live when they were solved. The refiner combines only subs of the *current*
  stack generation (see reseed handling).
- **Weight parity:** frame weighting is on by default; the global combine is a
  *weighted* clipped mean using the same per-sub weight the online engine used, so
  feature-on changes trail rejection and nothing else about frame contribution.
- All output goes through the existing crop-to-coverage + additive-neutralize +
  FITS-metadata path (`RestackPlanning.encodeMaster`), with **STACKCNT/TOTALEXP
  reflecting the global survivor count**, not the online engine's stack count.
- Registration is **reused, never recomputed** in the refiner.
- Bounded shutdown: a global pass triggered by `end()` obeys the same
  progress-aware/timeout discipline as the live drain (2026-08-28 fix); on any
  failure it falls back to the online master (never worse than today).

---

## Architecture & data flow

```
per accepted sub (ONLINE, unchanged behavior + preview):
    register → warp → warped-domain leveling → online mean → PREVIEW (stays online)
    ALSO capture SubRegistration{ identity, relayURL, stackGeneration, referenceIdentity,
                                  transform(half-res), scale, weight, levelingModel }
    notify refiner "new sub"

GlobalRefiner (own serial background queue, self-throttled):
  when idle AND the survivor set changed since the last pass:
    survivors := accepted, non-user-rejected subs OF THE CURRENT stackGeneration
                 (same selection as RestackPlanning.survivorSubs, filtered by generation)
    per sub → loadRawFrame(relayURL, expectedDigest) → calibrate → debayer/displayRGB
              → warp(cached transform) → warped-domain leveling(cached model)
              → scale                                      # exact online per-sub order (warp FIRST)
    center pass: per-pixel median + MAD over a RAM-held SAMPLE of survivors
                 (all survivors when they fit the RAM budget; a representative subset when deep)
                 → robust center + scale = 1.4826·MAD
    output pass: weighted clipped mean over ALL survivors (reuse the RAM sample when
                 shallow; stream from disk when deep), keeping v where |v-center| ≤ κ·scale
    publish: install {image, coverage, survivorCount, freshnessKey} as the published master

outputs:
    live PREVIEW (operator)         → ALWAYS the online mean (instant per-sub feedback)
    broadcast / latest.png / master → the published master when its freshnessKey is current,
                                       else the online mean (always the floor)

end():  cancel in-flight refiner (bounded) → if a published master with a CURRENT freshnessKey
        exists, use it; else run ONE bounded final global pass; write master.fit from the global
        result via RestackPlanning.encodeMaster; on any failure fall back to the online master.
```

The refiner reproduces the online per-sub pipeline **minus registration**, in the
engine's real order — **warp first, then warped-domain leveling** (pre-warp
leveling was proven to inject errors; cf. `StackEngine.swift:355`). Registration
(the expensive star-match) comes from the cached `SubRegistration`.

## Components (each a small, testable unit)

### 1. `GlobalCombine` (pure core) — `Sources/LiveAstroCore/Stacking/GlobalCombine.swift`
Two composable, pure functions (no I/O, no live/import knowledge):
- `robustCenter(sample: [(image: AstroImage, mask: [Float])]) -> (center: AstroImage, scale: [Float])?`
  — per-pixel **median** and **MAD** (`scale = 1.4826·MAD`) over the masked values.
- `clippedWeightedMean(frames: () -> AnyIterator<(image: AstroImage, mask: [Float], weight: Float)>,
   center: AstroImage, scale: [Float], kappa: Float) -> (image: AstroImage, coverage: [Float])?`
  — accept `|v-center| ≤ kappa·scale`; accumulate `Σ w·v` / `Σ w` over survivors.
- `frames` is a **factory** (fresh iterator per call) so the refiner can stream the
  output pass from disk for deep stacks; `sample` is materialized in RAM.
- `CombineMethod { case clippedMean /* future: case median (output) */ }` param on the
  refiner call so median-output slots in for the in-RAM variant with no core rewrite.
- Zero-count / all-masked pixels → coverage 0. Zero-MAD pixel (all equal) → scale floor,
  no clipping.
- **Tests (always in CI, synthetic):** planted trail in 1 of N (N=5,11,30) → trail removed,
  survivor mean == clean-frame mean within ε, *including the shallow N=5 case that mean/σ
  fails*; MAD center unmoved by the outlier; weights honored (a down-weighted sub contributes
  less); zero-MAD / single-frame / all-masked edges; golden byte test; κ monotonicity.

### 2. `SubRegistration` cache — captured in the online pass
- `struct SubRegistration { let identity: FileIdentity; let relayURL: URL; let stackGeneration: Int;
   let referenceIdentity: FileIdentity; let transform: SimilarityTransform; let scale: Float;
   let weight: Float; let leveling: BackgroundExtraction.BackgroundModel? }`
- `relayURL` (not just `sourceName`) because `RawFrame` exposes only name + identity; the
  trigger captures the relay destination path so the refiner can re-read.
- `stackGeneration`/`referenceIdentity`: the engine increments a generation on every reseed
  (manual or auto). Transforms from generation G reference generation-G's frame and **cannot**
  be combined with generation-G+1 subs. The refiner filters to the current generation only.
- **Seam:** `StackEngine.processDetailed` currently discards the internal
  `RegisteredFrame.transform`/`scale` and the applied `weight`/leveling model. Surface them
  for accepted subs — extend `ProcessResult` with an optional `registration` payload (additive,
  preserving existing equality for current callers) or a dedicated `onRegistered` callback.
  Also expose the current `stackGeneration` + reference identity. Chosen in the plan.
- `SessionPipeline` keeps `[FileIdentity: SubRegistration]` in memory, populated in
  `handleNative` alongside the existing `onSubFrame` record. Session-scoped.

### 3. `GlobalRefiner` — `Sources/LiveAstroCore/Pipeline/GlobalRefiner.swift`
- Owns a serial background queue; reads via the concurrent reader path
  (`FolderFrameSource.loadRawFrame(url:expectedDigest:)`, from the watcher-async-reads fix).
  One pass in flight at a time.
- Selects survivors = accepted, non-user-rejected subs **of the current stackGeneration**,
  ordered; resolves each to `(relayURL, SubRegistration)`.
- RAM budget (`maxSampleBytes`, default ~6 GB): if the survivor set fits, the sample = all
  survivors and the output reuses them; if it exceeds the budget, the sample = a
  most-recent/representative subset for the center, and the output **streams all survivors
  from disk** (documented cap behavior; logged, not silent).
- Per sub: load (digest-verified) → calibrate → debayer/displayRGB → warp(cached transform)
  → warped-domain leveling(cached model) → scale → `(image, mask, weight)`.
- Per-sub load/digest failure → skip + count, never abort the pass; if a quorum is lost,
  abandon the refresh and keep the last published master.
- **Cancellable** for `end()`, reusing the bounded-drain discipline.

### 4. Published-master swap + freshness — `SessionPipeline`
- `publishedMaster: (image, coverage, survivorCount, freshnessKey)?` under a lock.
- **`freshnessKey` is a real composite**, not "recent": `{ stackGeneration, sorted set of
  survivor content-digests, userRejectGeneration, kappa/rejectionStrength }`. The broadcast/
  outputs and `end()` use the published master **only when its key equals the current one**,
  recomputed cheaply on read. So rejecting a sub, a reseed, or a κ change immediately
  invalidates a stale clean master containing the removed/altered sub.
- Broadcast/`latest.png`/`master.fit` prefer the published master when the key matches; else
  the online `currentStackAndCoverage()` (floor). The operator **preview always uses online**.
  Same crop + display pipeline for both.

### 5. Trigger — `SessionPipeline`
- After each accepted sub (in `handleNative`, after the online commit), `refiner.noteChanged()`.
  Also on a user reject/unreject and on reseed. The refiner coalesces: idle → start; running →
  set a dirty flag so exactly one more pass runs after the current. Self-throttling; no timer.

### 6. UI + gating — `AppModel` + `CaptureSettingsView`
- `AppModel.liveTrailRejection: Bool` (default **true**); `rejectionStrength` reused for κ.
- Toggle + a status line that **states why it is or isn't active** —
  e.g. "Clean master: 24 subs, refreshed 8s ago" / "Clean master off — network source" /
  "off — need ≥ N subs" / "off — reseeding". Never silently inactive.
- **Gate:** engage only for a native `FolderFrameSource(.live)` with a local relay and
  ≥ a minimum survivor count. Network/watcher/import ⇒ online-only, with the reason shown.

## Error handling
- Per-sub read/digest failure → skip + count, continue; publish if a quorum remains, else keep
  last good master. Never stack unverified bytes.
- Refiner never throws into the online path; failures logged via `onLog`; online master is the floor.
- `end()` final-pass failure → fall back to the online accumulator master (today's behavior).
- Reseed mid-pass → the running pass's generation no longer matches; discard its result, the
  next pass runs on the new generation.

## Testing & success criteria
- **Unit (always CI, synthetic):** `GlobalCombine` per §1 (esp. the shallow N=5 trail case and
  weight honoring); `SubRegistration` capture + generation stamping; refiner generation filter +
  skip-count + RAM-cap fallback; `freshnessKey` invalidation on reject/reseed/κ-change; published-
  master preference (preview stays online, broadcast switches).
- **Integration (acceptance bar, env-gated/skippable like `testSolvesRealM63Frame`):** drip the
  real M 51 set **including the trail sub** through the live pipeline, feature ON; assert the trail
  is **absent** from `master.fit` (pixel stats along the trail path == background, vs the online
  master which keeps it) and SNR ≥ the online weighted mean.
- **Regression:** feature OFF ⇒ byte-identical master to today (pinned). Online path + shutdown-
  drain tests unchanged and green. `end()` final-pass honors the bounded-drain timeout.
- **Success =** shallow real stack shows no trail where online does; reject-a-sub immediately
  invalidates the clean master; `end()` writes the clean, correctly-counted version; zero
  regression to ingest latency, preview, or shutdown; feature-off parity holds.

## Non-goals
- The online accumulator itself never does global rejection — it stays online/O(1) for timely,
  network-tolerant broadcast and the instant preview. The global combine is always a distinct
  full-set pass.
- No median-*output* combine, no pure in-RAM Seestar variant, no import surface, no network-live
  in v1 (all §7a follow-ups).
