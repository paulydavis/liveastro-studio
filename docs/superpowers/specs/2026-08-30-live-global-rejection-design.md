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
    ALSO capture SubRegistration{ subIndex, contentDigest, relayURL, stackGeneration, referenceIdentity,
                                  transform(half-res), effectiveScale, weight, leveling(sub,ref) }
    notify refiner "new sub"

GlobalRefiner (own serial background queue, self-throttled):
  when idle AND the survivor set changed since the last pass:
    survivors := accepted, non-user-rejected subs OF THE CURRENT stackGeneration
                 (same selection as RestackPlanning.survivorSubs, filtered by generation)
    per sub → loadRegisteredInput(relayURL, expectedContentDigest) → calibrate → debayer/displayRGB
              → warp(cached transform)
              → warped-domain leveling(cached (sub,ref), effectiveScale)  # scale is FUSED into
                 -- or the warped frame UNSCALED when the leveling pair is nil (matches engine)
              # exact online per-sub order: warp FIRST, then leveling
    center pass: per-pixel median + MAD over a RAM-held SAMPLE of survivors
                 (all survivors when they fit the RAM budget; a representative subset when deep)
                 → robust center + scale = 1.4826·MAD
    output pass: weighted clipped mean over ALL survivors (reuse the RAM sample when
                 shallow; stream from disk when deep), keeping v where |v-center| ≤ κ·max(scale, scaleFloor)
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
  — accept `|v-center| ≤ kappa·max(scale, scaleFloor)`; accumulate `Σ w·v` / `Σ w` over survivors
  (a covered pixel with all survivors clipped → `center`).
- `frames` is a **factory** (fresh iterator per call) so the refiner can stream the
  output pass from disk for deep stacks; `sample` is materialized in RAM.
- `CombineMethod { case clippedMean /* future: case median (output) */ }` param on the
  refiner call so median-output slots in for the in-RAM variant with no core rewrite.
- Zero-count / all-masked pixels → coverage 0. The clip denominator is `sigma = max(MAD-scale,
  scaleFloor)`, so a **zero-MAD core still rejects a gross outlier** (e.g. [1,1,1,1,9] rejects the 9);
  a covered pixel whose survivors are all clipped falls back to `center` (no black speckle). `coverage`
  is per-pixel frame-count depth (not binary).
- **Tests (always in CI, synthetic):** planted trail in 1 of N (N=5,11,30) → trail removed,
  survivor mean == clean-frame mean within ε, *including the shallow N=5 case that mean/σ
  fails*; MAD center unmoved by the outlier; weights honored (a down-weighted sub contributes
  less); zero-MAD / single-frame / all-masked edges; golden byte test; κ monotonicity.

### 2. `SubRegistration` cache — captured in the online pass
- `struct SubRegistration { let subIndex: Int; let contentDigest: String?; let relayURL: URL; let stackGeneration: Int;
   let referenceIdentity: FileIdentity?; let transform: SimilarityTransform; let effectiveScale: Float;
   let weight: Float; let leveling: (sub: BackgroundExtraction.BackgroundModel, ref: BackgroundExtraction.BackgroundModel)? }`
  — **`subIndex`** is the per-sub monotonic capture ID (= `processedCount`, the same value as `SubFrameRecord.index`) and is the UNIQUE identifier used for cache keying, the user-reject set, and the freshness list; **`contentDigest`** (from `RawFrame.identity`, digest with stat fields zeroed) is kept ONLY for byte re-verification on re-read. Content identity is NOT used as a key — two byte-identical subs are distinct subs (`FileIdentity`-keying would collapse/cross-reject them).
  — matches the engine exactly (`StackEngine.swift:366-373`): leveling is the `(sub, ref)` pair
  from `levelingModels(...)`, `effectiveScale` is the *applied* scale (1.0 when the pair is nil or
  `scalingApplies` fails), and `weight` is the `appliedWeight` (`frameWeight(sigma·effectiveScale)`).
  The refiner re-applies leveling identically: `GradientLeveler.apply(warped, subModel: leveling.sub,
  refModel: leveling.ref, scale: effectiveScale)` when the pair exists, else the warped frame unscaled.
- **The reference frame is a survivor** (it seeds the online mean): its record is `transform = identity`,
  `effectiveScale = 1.0`, `weight = 1.0`, `leveling = nil`, `referenceIdentity = its own identity`, and it
  is the **generation seed** — every sub of a generation shares that reference's identity.
- `relayURL` (not just `sourceName`) because `RawFrame` exposes only name + identity; the
  trigger captures the relay destination path so the refiner can re-read.
- `stackGeneration`/`referenceIdentity`: the engine increments a generation on every reseed
  (manual or auto). Transforms from generation G reference generation-G's frame and **cannot**
  be combined with generation-G+1 subs. The refiner filters to the current generation only.
- **Seam (chosen):** `StackEngine.processDetailed` currently discards the internal
  `RegisteredFrame.transform`/`scale` and the applied `weight`/leveling model. Surface them for
  accepted subs by extending `ProcessResult` with an optional `registration: RegistrationPayload?`
  (additive, `nil` default — existing call sites compile unchanged), plus a public locked
  `currentStackGeneration` accessor. (Plan Task 4.)
- `SessionPipeline` keeps an **ordered `[SubRegistration]`** (capture order; `subIndex` is the key),
  populated in `handleNative` alongside the existing `onSubFrame` record, session-scoped. The user-reject
  set is `Set<Int>` of `subIndex`es. **`relayURL` must survive calibration:** `handleNative` calibrates the
  frame before recording, and `Calibrator.apply` rebuilds `RawFrame` — it (and any `RawFrame`-copying path)
  MUST preserve `sourceURL`, or every calibrated live frame is silently skipped (nil URL).

### 3. `GlobalRefiner` — `Sources/LiveAstroCore/Pipeline/GlobalRefiner.swift`
- Owns a serial background queue; the loader wraps the concurrent reader path
  (`FolderFrameSource.loadRawFrame(url:expectedDigest:)`, from the watcher-async-reads fix) with
  **content-digest-only verification** (`expectedContentDigest: String?` — stat fields zeroed).
  One pass in flight at a time.
- Selects survivors = accepted, non-user-rejected subs **of the current stackGeneration**,
  ordered; resolves each to `(relayURL, SubRegistration)`.
- **Sample policy (pinned).** The center/MAD is estimated from a RAM-held sample:
  - **Under budget** (`sample bytes ≤ maxSampleBytes`, default ~6 GB) → sample = **all**
    survivors; the output pass reuses them (no disk re-read).
  - **Capped** → sample = a **deterministic, evenly-strided** subset of exactly `maxSampleFrames`
    (reduced to an **odd count** so each pixel's median has a true middle element), across the
    *ordered* survivor list, **no RNG** (a given survivor set always yields the same sample). RAM is
    the **hard bound** — the sample **never exceeds `maxSampleFrames`**; there is no floor that
    overrides it. `maxSampleFrames = maxSampleBytes / sampleFrameBytes`, where `sampleFrameBytes =
    image.pixels.count·4 + mask.count·4` (warped RGB pixels + the per-pixel mask — at 26 MP RGB
    that's ~312 MB + ~104 MB ≈ 416 MB/frame; the mask is NOT negligible). `maxSampleFrames` MUST be
    ≥ 11 — **checked hard on the first refine** (frame dims are known only then; a `< 11` result
    returns nil = live rejection stays off, online master kept) and **advisory-logged at session
    start**. The output pass **streams all survivors from disk**. Logged, not silent.
  - **Honesty:** the capped case is a **sample-derived robust center + full-survivor clipped
    weighted mean** — NOT a full-set median. The center is an estimate from the sample; only the
    *output* (the clipped weighted mean) is over every survivor. Status/logs say so.
- Per sub: load (digest-verified) → calibrate → debayer/displayRGB → warp(cached transform)
  → warped-domain leveling(cached model) → scale → `(image, mask, weight)`.
- Per-sub load/digest failure → skip + count, never abort the pass; if a quorum is lost,
  abandon the refresh and keep the last published master.
- **Cancellable** for `end()`, reusing the bounded-drain discipline.

### 4. Published-master swap + freshness — `SessionPipeline`
- `publishedMaster: (image, coverage, survivorCount, freshnessKey)?` under a lock.
- **`freshnessKey` is a real composite**, not "recent": `{ stackGeneration, sorted array of survivor
  `subIndex`es (the per-sub monotonic capture IDs — unique even for byte-identical subs, unlike a
  content-digest set which would collapse duplicates), userRejectGeneration, kappa/rejectionStrength }`.
  The broadcast/
  outputs and `end()` use the published master **only when `liveRejectionActive` is true AND its key
  equals the current one** (`FreshnessKey` does not encode `enabled`, so the separate
  `liveRejectionActive` gate — lock-guarded, cleared on toggle-off — preserves feature-off parity).
  So rejecting a sub, a reseed, a κ change, or **turning the feature off** immediately stops serving
  a stale clean master; `end()` on the off/fallback path writes the online master with
  `finalizationState()` metadata (byte-identical to today).
- Broadcast/`latest.png`/`master.fit` prefer the published master when the key matches; else
  the online `currentStackAndCoverage()` (floor). The operator **preview always uses online**.
  Same crop + display pipeline for both.

### 5. Trigger — `SessionPipeline`
- After each accepted sub (in `handleNative`, after the online commit), `refiner.noteChanged()`.
  Also on a user reject/unreject, on reseed, and on a **config change** (`configureLiveRejection` —
  κ/budget/enabled, including enable-ON mid-session). The refiner coalesces: idle → start; running →
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
  master which keeps it) and SNR **does not regress**, measured **ROI-based** (a flat background ROI
  away from the trail + galaxy): `globalSNR ≥ 0.9 · onlineSNR` (tolerance for the survivor-count
  difference — not a strict global ≥).
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
