# LiveAstro Studio — "Live-Session Accuracy" Design

**Date:** 2026-07-11 · **Status:** approved for planning ·
**Origin:** two related bugs from the Veil nights, both about the
accepted-vs-seen gap: (1) after a reseed the integration badge overstated depth
(showed session-total accepted frames while the time reflected only the current
stack — "34 × 30s" when 27 were in the stack); (2) the ROOT CAUSE of the
registration gaps — the reference seeded on a *wrong-target* slew frame (which
still had ≥15 stars), so every real-target frame failed the transform and was
rejected. This pillar fixes the root cause (auto-reseed) and makes the badge
honest.

## 1. Goal

The live stack **self-heals from a bad reference seed** (auto-reseed on
systematic registration failure), and the integration **badge reflects the
current stack** consistently (frame count and time always agree).

## 2. Core principles

- **Self-heal, don't just report.** The real problem is frames being wrongly
  rejected because the reference is a different field; the engine should detect
  that and reseed, recovering the session — not merely display the loss.
- **Conservative trigger.** Only a *systematic* transform failure (many
  consecutive `noTransform` with no successful stack between) reseeds. A good
  reference essentially never produces that (bad frames give `insufficientStars`,
  not `noTransform`), so no false reseeds.
- **Honest, consistent badge.** The "N × exp" badge shows the *current stack's*
  depth; count and time are derived from the same quantity so they cannot
  disagree.
- **Complement the manual Reseed.** The existing manual Reseed button is
  unchanged; auto-reseed is an automatic safety net.

## 3. Decisions

| Decision | Choice |
|---|---|
| Trigger signal | Consecutive `StackOutcome.rejected(.noTransform)` since the reference seeded, with no `.stacked` in between |
| Threshold | **`autoReseedThreshold: Int = 6`** consecutive noTransform (0 = disabled); injectable |
| Reseed action | Clear the reference (`referenceSize/referenceStars/accumulator = nil`); the **next** ≥`seedMinStars` frame reseeds via the existing seed path |
| Counter reset | `.stacked` and `becameReference` reset `consecutiveNoTransform` to 0; `insufficientStars`/`dimensionMismatch` neither count nor reset |
| Observability | Public read-only `autoReseedCount`; the pipeline logs a line when it increments |
| Badge fix | `integrationCaption` derives the frame count from `estimatedIntegrationSeconds / subExposureSeconds` (current-stack), not from `rec.index` |
| Manual Reseed | Unchanged; `autoReseedCount` is session-total, not reset by `reseed()` |

## 4. Architecture

```
LiveAstroCore/
  Stacking/
    StackEngine.swift        (+ autoReseedThreshold param, consecutiveNoTransform,
                              autoReseedCount; auto-reseed logic in processLocked)
  Pipeline/
    SessionPipeline.swift     (log when engine.autoReseedCount increments)
LiveAstroStudio/
    AppModel.swift            (integrationCaption: frames from integration seconds;
                              pass autoReseedThreshold when constructing the engine — default)
```

### 4.1 `StackEngine` auto-reseed

```swift
public init(seedMinStars: Int = 15, minMatches: Int = 8, inlierTolerance: Double = 2.0,
            rejection: RejectionMethod = NoRejection(),
            autoReseedThreshold: Int = 6)          // NEW: 0 disables

public private(set) var autoReseedCount = 0        // NEW: session-total auto-reseeds
private var consecutiveNoTransform = 0             // NEW
```

In `processLocked`, at the existing `.noTransform` rejection (transform solve
returns nil):
```swift
rejectedCount += 1
consecutiveNoTransform += 1
if autoReseedThreshold > 0 && consecutiveNoTransform >= autoReseedThreshold {
    // The reference is probably a wrong-target frame — clear it so the next
    // qualifying frame re-seeds; the current frame stays rejected.
    referenceStars = []
    referenceSize = nil
    referenceChannels = nil
    accumulator = nil
    consecutiveNoTransform = 0
    autoReseedCount += 1
}
return .rejected(.noTransform)
```
On the successful accumulate path (`.stacked`) and on `.becameReference`, set
`consecutiveNoTransform = 0`. The seeding path (`referenceSize == nil`) is
otherwise unchanged, so after a clear the next ≥`seedMinStars` frame seeds
exactly as at session start.

**Concurrency:** all of this runs inside the existing `lock.withLock` in
`process()`; `autoReseedCount`/`consecutiveNoTransform` are only touched under
that lock (same as `acceptedCount`/`rejectedCount`). `reseed()` (manual) already
clears the reference under the lock and is unaffected; it does **not** reset
`autoReseedCount` (session-total, matching `acceptedCount`).

### 4.2 Pipeline logging

The consume loop already calls `engine.process(frame)` per frame and reacts to
the outcome. Add: after `process`, if `engine.autoReseedCount` increased since
the last frame, emit a log line via the existing log/`onRejected`-style channel:
`"Auto-reseeded — reference didn't match \(threshold) subs; re-seeding on the next good frame."`
(The exact seam — track the last-seen `autoReseedCount` in the consume loop, or
add a `StackOutcome.autoReseeded` case — is settled in the plan by reading the
pipeline's outcome switch; the engine behavior is identical either way. Prefer
the counter-diff approach if it avoids rippling a new case through every
`StackOutcome` consumer.)

### 4.3 Badge honesty (`AppModel.integrationCaption`)

Today:
```swift
IntegrationFormat.caption(seconds: rec.estimatedIntegrationSeconds,
                          frames: rec.index,                       // ← session-total accepted
                          subSeconds: profile.subExposureSeconds)
```
`rec.estimatedIntegrationSeconds` is `stackFrameCount × subExposure` (current
stack — correct). `rec.index` is `acceptedCount` (session-total — survives
reseed → overstates). Fix: derive the frame count from the (already-correct)
integration seconds so count and time cannot disagree:
```swift
let sub = profile.subExposureSeconds
let framesInStack = sub > 0 ? Int((rec.estimatedIntegrationSeconds / sub).rounded()) : rec.index
IntegrationFormat.caption(seconds: rec.estimatedIntegrationSeconds,
                          frames: framesInStack,
                          subSeconds: sub)
```
Absent a reseed this equals today's value (`acceptedCount == stackFrameCount`);
after an (auto- or manual) reseed it shows the honest current-stack depth. No
`SnapshotRecord`/`IntegrationFormat` signature change; `rec.index` stays the
monotonic snapshot identity used for filenames/replay.

## 5. Data flow

```
frame → engine.process (under lock):
  reference seeded?
    no  → ≥seedMinStars ? seed (becameReference, resets consec) : reject(insufficientStars)
    yes → match+solve:
            fail  → reject(noTransform); consec++;
                    consec ≥ threshold ? clear reference + autoReseedCount++ + consec=0
            ok    → warp+accumulate → stacked; consec=0
pipeline: autoReseedCount bumped since last frame ? log "Auto-reseeded…"
badge: frames = round(estimatedIntegrationSeconds / subExposure)  → current-stack depth
```

## 6. Error handling / edge cases

| Situation | Behavior |
|---|---|
| Long slew (many wrong-target subs) | reseeds every `threshold` garbage subs; harmless (all garbage); locks the instant a real-target frame seeds and frames stack (consec resets) |
| Good reference + one satellite/mismatch frame | single `noTransform` never reaches the threshold; counter resets on the next `.stacked` |
| Cloud/blank frames mid-run | `insufficientStars` — neither counts toward nor resets the reseed counter (reference validity unchanged) |
| `threshold = 0` | auto-reseed disabled entirely |
| Manual Reseed pressed | clears reference as today; `autoReseedCount` unchanged (session-total) |
| `subExposure = 0` (guard) | badge falls back to `rec.index` (no divide-by-zero) |

## 7. Testing

`swift test --filter LiveAstroCoreTests`

- **Auto-reseed fires on a wrong seed (TDD):** seed the engine on star-field A,
  then feed `threshold` frames of a disjoint star-field B (all `.noTransform`).
  Assert: the `threshold`-th returns `.rejected(.noTransform)`, `autoReseedCount
  == 1`, and the reference is cleared (a subsequent B frame returns
  `.becameReference`); then another B frame `.stacked`. Net: the engine recovers
  onto field B.
- **No false reseed on a good reference:** seed on A, feed A frames with an
  occasional single non-matching frame interleaved (never `threshold` in a row);
  assert `autoReseedCount == 0` throughout (the counter resets on each `.stacked`).
- **Threshold 0 disables:** with `autoReseedThreshold: 0`, feed many
  `.noTransform` frames → `autoReseedCount == 0`, reference never auto-cleared.
- **Counter semantics (pin the exact rule):** the counter increments **only** on
  `.noTransform` and resets **only** on `.stacked`/`.becameReference`. Test that a
  noTransform run with a single `insufficientStars` (cloud) frame interleaved —
  e.g. noTransform ×3, insufficientStars ×1, noTransform ×3 — **still trips**
  (6 total noTransform; the cloud frame neither incremented nor reset the count),
  proving the wrong-seed evidence survives a transient cloud.
- **Badge (TDD):** `AppModel`-independent check on the caption math — a record
  with `estimatedIntegrationSeconds = 27 × 30`, `index = 34`, `subExposure = 30`
  → caption frames == 27 (from seconds), not 34.
- **Manual/build-verified:** the pipeline log line and the SwiftUI badge wiring
  (out of unit-test scope, per prior pillars). RELEASE build must succeed;
  existing StackEngine/pipeline tests stay green (default threshold changes no
  behavior until 6 consecutive noTransform occur — assert an existing e2e still
  passes).

## 8. Non-goals (future builds)

Reseed onto the *best-so-far* frame (buffering candidate references / picking the
highest-star-count frame) rather than the next qualifying frame; a user setting
for the threshold (measured default only this build); reseed heuristics based on
sky-quality/FWHM; recovering the frames rejected *before* the auto-reseed fired
(they stay rejected — the point is to stop the bleeding, not replay); changing
the manual Reseed button.

## 9. Risks

| Risk | Mitigation |
|---|---|
| False reseed drops a good reference | trigger is `threshold` *consecutive* `noTransform` (not sporadic); `.stacked` resets the counter; a good reference doesn't produce systematic transform failures; threshold 6 is conservative and configurable |
| Reseed thrash during a long slew | bounded to one reseed per `threshold` frames; converges the moment a real-target frame seeds; the discarded stack held only garbage |
| Badge change alters a correct display | absent a reseed the derived count equals `acceptedCount` (== `stackFrameCount`), byte-identical to today; a test pins the reseed case |
| New `StackOutcome` case ripples through consumers | prefer the `autoReseedCount` counter-diff logging seam (no new case); decided in the plan after reading the outcome switch |
| Concurrency on the new counters | mutated only inside the existing `process()`/`reseed()` lock, exactly like `acceptedCount`/`rejectedCount` |
