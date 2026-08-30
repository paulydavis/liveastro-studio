# Live Global Rejection (Real-Time Trail-Free Stacking) — Design

**Status:** Design (brainstormed 2026-08-30). Roadmap origin: §7a.

**Goal (one sentence):** While live-stacking, remove satellite trails and other
single-frame outliers from the broadcast master in near-real-time by periodically
recomputing a full-set κ-σ-clipped-mean master from the recorded subs — something
the online engine structurally cannot do — with zero change to per-sub ingest
latency, the online preview, or the shutdown behavior.

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
trail. A *global* (full-set) combine has neither limitation — it sees every sub's
value at each pixel at once, so an outlier in 1 of N is rejected outright, at any
depth, with no warm-up.

## Scope for v1

**In:** live, native `FolderFrameSource(.live)` sources whose subs are on local
disk (via the relay); κ-σ clipped-mean combine only; ASI2600-class (large-sensor)
disk two-pass; the final `master.fit` becomes the clean global result.

**Out (documented follow-ups):** median combine (belongs to the in-RAM
small-sensor variant, where it is cheap — §7a); the in-RAM Seestar variant;
wiring the same core into the import/"Stack Previous Shoot"/re-stack surface;
network/SMB live (stays online-only).

**Global constraints (bind every task):**
- The online path (`StackEngine.processDetailed`, `handleNative`, the accumulator)
  is **not modified in behavior**. Feature OFF ⇒ byte-identical to today.
- The refiner runs entirely off the online consumer — it never blocks per-sub
  ingest, the display, or the broadcast, and never holds more than O(one image).
- All output goes through the existing crop-to-coverage + additive-neutralize +
  FITS-metadata path (`RestackPlanning.encodeMaster`) — no new file format.
- Registration is **reused, never recomputed** in the refiner.
- Bounded shutdown: a global pass triggered by `end()` obeys the same
  progress-aware/timeout discipline as the live drain (2026-08-28 fix); on any
  failure it falls back to the online master (never worse than today).

---

## Architecture & data flow

```
per accepted sub (ONLINE, unchanged behavior):
    register → warp → online mean → preview
    ALSO: cache SubRegistration{ identity, transform(half-res), scale, levelingModel }
          keyed by content-digest identity; notify refiner "new sub"

GlobalRefiner (own serial background queue, self-throttled):
    when idle AND a new sub arrived since the last pass:
      subs := accepted, non-user-rejected recorded subs (identity → relay URL + cached SubRegistration)
      pass 1: for each sub → loadRawFrame(url, expectedDigest) → calibrate → level → warp(cached xform, scale)
              → GlobalCombine accumulate (per-pixel sum, sumsq, count) over masked pixels
      pass 2: same reads/warps → clip each pixel to mean ± κσ, accumulate survivors → clipped mean + coverage
      publish: atomically install the result as the "published master"

display/broadcast/snapshot:
    prefer the published master when present & fresh; else the online mean (always the floor)

end():  cancel in-flight refiner (bounded) → if fresh published master & no new subs, use it;
        else run ONE bounded final global pass → write master.fit from the global result;
        on failure fall back to the online accumulator's master.
```

The refiner reproduces the online per-sub pipeline **minus registration**: read
raw → debayer → calibrate → gradient-level → warp. Registration (the expensive
star-match) is taken from the cached `SubRegistration`, so a refresh is
read + warp + reduce, not a re-solve.

## Components (each a small, testable unit)

### 1. `GlobalCombine` (pure core) — `Sources/LiveAstroCore/Stacking/GlobalCombine.swift`
- `static func clippedMean(frames: () -> AnyIterator<(image: AstroImage, mask: [Float])>, kappa: Float, iterations: Int, method: CombineMethod = .clippedMean) -> (image: AstroImage, coverage: [Float])?`
- `CombineMethod { case clippedMean /* future: case median */ }` — the parameter
  exists now so median slots in with no caller changes when the in-RAM variant lands.
- Two-pass, O(one image): pass 1 → per-pixel `sum`, `sumsq`, `count` over pixels
  where `mask>0`; derive `mean`, `sigma`. pass 2 → per-pixel accept `|v-mean| ≤ kappa*sigma`,
  accumulate survivor sum + count → survivor mean. `iterations>1` re-derives mean/σ
  from survivors between passes (v1 default: 1 clip pass).
- `frames` is a **factory** returning a fresh iterator per pass (the refiner re-reads
  from disk each pass; the core stays agnostic to the source).
- Pure, no I/O, no knowledge of live/import/relay. Zero-count pixels → coverage 0.
- **Tests:** synthetic frames with a planted trail in 1 of N → trail removed, survivor
  mean == mean of clean frames within ε; single-frame / all-identical / zero-σ edge
  cases; golden byte test; κ monotonicity (higher κ rejects less).

### 2. `SubRegistration` cache — captured in the online pass
- `struct SubRegistration { let identity: FileIdentity; let transform: SimilarityTransform; let scale: Float; let leveling: BackgroundExtraction.BackgroundModel? }` (the per-sub `subModel` `GradientLeveler.apply` consumes; refiner re-levels against the same reference model)
- **Seam:** `StackEngine.processDetailed` currently discards the internal
  `RegisteredFrame.transform`/`scale`. Add a way to surface them for accepted subs —
  either extend `ProcessResult` with an optional `registration` payload, or a
  dedicated `onRegistered` callback. Chosen in the plan; must not change existing
  `ProcessResult` equality semantics for current callers (add optional field).
- `SessionPipeline` keeps `[FileIdentity: SubRegistration]` in memory, populated in
  `handleNative` alongside the existing `onSubFrame` record. Session-scoped; a
  mid-session app restart loses it (acceptable for a live feature — refiner simply
  can't run until subs re-accumulate).

### 3. `GlobalRefiner` — `Sources/LiveAstroCore/Pipeline/GlobalRefiner.swift`
- Owns a serial background `DispatchQueue`; reads subs via the existing concurrent
  reader path (`FolderFrameSource.loadRawFrame(url:expectedDigest:)`, from the
  watcher-async-reads fix). One pass in flight at a time.
- Input per refresh: ordered `[(url, SubRegistration)]` for accepted, non-user-rejected
  subs (same survivor set as `RestackPlanning.survivorSubs`).
- Per sub: load raw (digest-verified) → calibrate (session calibrator) → gradient-level
  (cached model) → `Warp.apply(rgb, transform.liftedToFullResolution(), scale)` → yields
  `(image, mask)` to `GlobalCombine`.
- On success: hands the `(image, coverage)` to the publish step. On any per-sub load
  failure: skip that sub + count it (never abort the whole pass); if too few remain,
  abandon the refresh and keep the last published master.
- **Cancellable** (for `end()`), progress-aware bound reused from the drain discipline.

### 4. Published-master swap + display integration — `SessionPipeline`
- A new atomic `publishedMaster: (image, coverage, subCount, generation)?` guarded by
  a lock; the refiner installs it, the display path reads it.
- `renderSnapshot`/broadcast/`latest.png` prefer `publishedMaster` when present; else
  fall back to the online `currentStackAndCoverage()` (unchanged floor). Same crop +
  display pipeline (`cropToCoverage` → `displayCGImage`) for both.
- `end()`: see shutdown flow above. `master.fit` written via `RestackPlanning.encodeMaster`
  from the global result (parity: crop, neutralize, STACKCNT/TOTALEXP/pointing metadata).

### 5. Trigger — `SessionPipeline`
- After each accepted sub (in `handleNative`, after the online commit), call
  `refiner.noteNewSub()`. The refiner coalesces: if idle, start a pass; if running,
  set a "dirty" flag so exactly one more pass runs after the current finishes.
  Self-throttling — shallow stacks refresh ~every sub; deep stacks space out as the
  pass duration grows. No wall-clock timer.

### 6. UI + gating — `AppModel` + `CaptureSettingsView`
- `AppModel.liveTrailRejection: Bool` (default **true**), `rejectionStrength` reused
  for κ. Toggle + a status line ("clean master: N subs, refreshed Ns ago") in
  Setup → Capture.
- **Gate:** engage only for a native `FolderFrameSource(.live)` with a local relay.
  Network/watcher/import ⇒ silently online-only regardless of the toggle.

## Error handling
- Per-sub read failure in a pass → skip + count, continue; refresh still publishes if
  a quorum remains, else keep the last good master.
- Refiner never throws into the online path; all failures are logged via `onLog` and
  leave the online master as the floor.
- `end()` final-pass failure → fall back to the online accumulator master (today's
  behavior); the session still finalizes.
- Digest mismatch on re-read (a sub changed on disk) → skip that sub (same policy as
  re-stack), never stack unverified bytes.

## Testing & success criteria
- **Unit:** `GlobalCombine` (see §1). `SubRegistration` capture seam. Refiner survivor
  selection + skip-counting. Published-master preference in the display path.
- **Integration (the acceptance bar):** drip the real M 51 set **including the trail
  sub** through the live pipeline with the feature ON; assert the trail is **absent**
  from the resulting `master.fit` (pixel statistics along the trail's path match
  background, vs the online master which retains it), and SNR ≥ the online mean.
- **Regression:** feature OFF ⇒ byte-identical master to today (pinned). Online path +
  shutdown-drain tests unchanged and green. The `end()` final-global-pass honors the
  bounded-drain timeout (no hang, no lost master).
- **Success =** on the M 51 trail sub the live master shows no trail where the online
  one does; `end()` writes the clean version; zero regression to ingest latency or
  shutdown; feature-off parity holds.

## Non-goals
- Do not make the online accumulator itself do global rejection — it stays online/O(1)
  for timely, network-tolerant broadcast. The global combine is always a distinct
  full-set pass.
- No median, no in-RAM small-sensor variant, no import surface, no network-live in v1
  (all §7a follow-ups).
