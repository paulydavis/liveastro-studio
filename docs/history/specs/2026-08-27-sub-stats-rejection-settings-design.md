# Per-Sub Stats, User Rejection, and Settings De-Clutter — Design

**Date:** 2026-08-27
**Status:** Approved (design phase)
**Author:** Paul Davis (with Claude)

## Summary

Three coupled changes to LiveAstro Studio's live-stacking workflow:

- **A. Per-sub stats** — retain the per-frame quality signal the pipeline already
  computes (and currently discards) and surface it as a live table + session trend.
- **B. User rejection** — let the operator flag individual subs as bad, then rebuild
  the master without them via one deliberate re-stack.
- **C. Settings de-clutter** — split the single 1200-line Setup panel into an inner
  `TabView` so the new stats view has a home and the existing controls stop competing
  for one scroll.

These ship together because B needs A's data, and C is where A/B live in the UI.

## Motivation

Today the pipeline computes a star count and background σ per sub (`StarDetector`),
derives a frame weight (`StackEngine.frameWeight`), and an accept/reject outcome
(`StackOutcome`) — then **throws all of it away**, folding the frame into an
irreversible running sum (`StackAccumulator`). The operator can see aggregate
accepted/rejected counts but cannot see *why* a sub was weighted low, cannot spot a
cloud band or a satellite-trail sub, and has no way to remove a bad sub that already
made it into the master. This design retains that per-sub signal, shows it, and makes
it actionable.

## Confirmed decisions

1. **Reject model = flag now, re-stack on button.** Flagging never mutates the running
   stack; a deliberate "Re-stack without flagged" (and an optional prompt at session
   end) rebuilds the master cleanly. Chosen over immediate-re-stack (a recompute per
   click) and reject-going-forward (leaves the bad sub visibly in the master).
2. **Stats for v1 = the four free metrics only:** star count, background σ, frame
   weight, accept/reject outcome+reason. FWHM/HFR are explicitly **out of scope** —
   they require a new shape-fitting detector and are deferred (YAGNI).
3. **Settings = inner sub-tabs inside Setup** (not a different split).

## Architecture

### Re-stack engine — chosen approach

**Re-stack from raw subs on disk.** When the operator re-stacks, re-read the raw FITS
subs (already staged in the relay / watch folder), skip the user-flagged set, and run
the existing register→stack pipeline fresh — the same mechanics "Stack Previous Shoot"
(`ImportController`) already uses. This is accurate (winsorized σ-clip and quality
weighting recompute correctly from scratch), bounded in memory (one frame decoded at a
time), and reuses a proven offline path.

Rejected alternative: retaining warped per-frame buffers to subtract on reject —
infeasible on memory (26 MP × N subs × Float = multiple GB) and mathematically wrong
(non-linear winsorized rejection cannot be undone by subtracting one frame's contribution).

### Components

| Unit | Responsibility | Depends on |
|---|---|---|
| `SubFrameRecord` (Core/Session) | Immutable-ish per-sub quality record; Codable; `rejectedByUser` mutable | Foundation |
| `SessionManifest.subFrames` | Persist the per-sub records (optional field, backward-compatible) | `SubFrameRecord` |
| `SessionManager` append/flag API | Append a record; set/clear a user-reject flag by index | `SessionManifest` |
| `SubFrameCSV` | Serialize per-sub records to `sub-frames.csv` | `SubFrameRecord` |
| Pipeline capture hook | Emit a `SubFrameRecord` per sub from the `(stars, sigma, weight, outcome)` already in hand | `StackEngine`, `SessionPipeline` |
| `RestackCoordinator` | Re-stack from raw minus an excluded set; produce a new master + display | `StackEngine`, raw folder |
| `StatsSettingsView` + sub-tab views | Live table, session rollups, reject toggles, re-stack button | `AppModel` |
| Setup `TabView` split | Move each `Form` section group into its own view file | existing views |

## Data model

```swift
public enum SubFrameOutcome: String, Codable, Equatable {
    case reference   // became the stack reference (seed)
    case stacked     // accepted and accumulated
    case rejected    // rejected at intake (registration failure)
}

public struct SubFrameRecord: Codable, Equatable {
    public let index: Int              // monotonic sub index within the session
    public let timestamp: Date
    public let sourceFile: String      // basename of the raw sub
    public let starCount: Int
    public let backgroundSigma: Float
    public let weight: Float            // frame weight applied (1.0 for reference; 0 if not stacked)
    public let outcome: SubFrameOutcome
    public let rejectionReason: String? // set when outcome == .rejected (intake reason)
    public var rejectedByUser: Bool     // operator flag; drives re-stack exclusion
}
```

- **Backward compatibility:** `SessionManifest` gains `public internal(set) var subFrames: [SubFrameRecord]? = nil`,
  following the existing `masterOutcome`/`stackFrameCount` pattern (synthesized `Codable`
  decodes absent as nil; legacy manifests load unchanged).
- `weight` is stored as the value the stacker actually used; a sub rejected at intake
  carries `weight = 0` and `outcome = .rejected`.
- `rejectedByUser` is the only mutable field; flagging never rewrites the measured metrics.

## Data flow

**Live capture (native mode):**
1. `handleNative` registers a sub; `StackEngine` already yields `(stars, sigma, scale, weight, outcome)`.
2. A new pipeline hook builds a `SubFrameRecord` from those values and calls
   `onSubFrame?(record)` (delivered on the same context as `onSnapshot`/`onRejected`).
3. `AppModel` appends the record to `SessionManager` (→ manifest) and to an in-memory
   `@Published subFrames: [SubFrameRecord]` the Stats view observes.
4. The running stack is **unchanged** by any of this — pure observation.

**Flagging:**
1. Operator toggles Reject on a row → `AppModel` sets `rejectedByUser = true` on that
   index (idempotent; toggling off clears it).
2. The footer's "Re-stack without N flagged" enables when ≥1 flag exists.

**Re-stack:**
1. `RestackCoordinator.restack(excluding: Set<Int>)` gathers the raw sub URLs for all
   records whose index is **not** excluded, in original order.
2. It runs a fresh `StackEngine` pass over them (reusing the offline import mechanics),
   producing a new master image.
3. On success: replace `master.fit`, re-render the display/broadcast, update
   `stackFrameCount` and accepted/rejected counts, log the result.
4. Re-stack is also **offered at session end** if any flags exist (a confirm, not automatic),
   yielding one clean final integration.

## Error handling

- **Raw subs missing** (relay pruned, folder moved): `restack` collects the URLs it can
  resolve; if the resolvable count is 0 it aborts with a clear message ("raw subs no
  longer on disk — cannot re-stack") and leaves the existing master intact. If *some* are
  missing it reports how many were skipped and proceeds with the rest (never silently).
- **All subs flagged**: re-stack button disabled when the excluded set would leave < the
  stacker's seed minimum; a tooltip explains why.
- **Re-stack in flight**: the button and flag toggles are disabled until it completes;
  a second re-stack cannot be launched concurrently.
- **Re-stack failure** (no seed acquired from the surviving subs): abort, keep the old
  master, surface the reason; flags are preserved so the operator can adjust and retry.
- **Records with `outcome == .rejected`** are already excluded from the stack; flagging
  them is a no-op for re-stack (they were never contributing) and the UI reflects that.

## UI

### Setup → inner `TabView`

`ControlView` becomes a thin container: an inner `TabView` above the existing
always-visible action footer (Start/End, Go Live — unchanged, stays pinned). Sub-tabs:

- **Capture** — Start Workflow, Watch Folder, Calibration, Session Profile, Session end.
- **Display** — Night vision, Display Adjustments.
- **Stats** — the new view (below).
- **Broadcast** — OBS, Go Live config, Session Outputs.
- **Diagnostics** — Session Health grid, Log.

Each sub-tab's body moves to its own file (`CaptureSettingsView`, `DisplaySettingsView`,
`StatsView`, `BroadcastSettingsView`, `DiagnosticsView`), shrinking `ControlView` from a
god-view to a container. This is a **structural move** — control logic and bindings are
unchanged, only relocated.

### Stats view

- **Rollup header:** accepted · rejected · user-flagged counts; mean frame weight; a
  compact sparkline of star count (and/or σ) over the session index so a cloud band or
  focus drift reads at a glance.
- **Table** (newest on top), one row per sub: `# · stars · σ · weight · status`, with a
  per-row **Reject** toggle. User-flagged rows get a distinct style; intake-rejected rows
  are visually muted (already out of the stack). Virtualized/`LazyVStack` so a
  many-hundred-sub session scrolls smoothly.
- **Footer:** "N flagged — [Re-stack without flagged]" (disabled at 0 flags or while a
  re-stack runs).

## Persistence & outputs

- Manifest gains `subFrames`.
- New `sub-frames.csv` output (index, timestamp, source_file, star_count, background_sigma,
  weight, outcome, rejection_reason, rejected_by_user) alongside the existing
  `frame-summary.csv`. Added to the Session Outputs footer as a reveal/open target,
  matching the existing CSV affordance.

## Testing

Pure/core (no UI):

- `SubFrameRecord` + `SessionManifest.subFrames` JSON round-trip; a legacy manifest with
  the field absent decodes to `nil` (backward-compat pin).
- `SubFrameCSV` column order + escaping; empty-session yields header only.
- **Golden re-stack:** `RestackCoordinator.restack(excluding:)` over a fixed sub set
  produces a master **byte-identical** to a direct `StackEngine` stack of the same subs
  minus the excluded indices (proves re-stack == fresh stack; no path divergence).
- Flagging is idempotent (double-flag == single) and order-independent (flag A then B ==
  B then A → same excluded set).
- Error paths each get a test: excluded set leaves 0 resolvable raw subs → abort + master
  unchanged; some missing → proceeds with survivors + reports skipped; excluded set below
  seed minimum → abort with reason.

UI (structural):

- Setup sub-tab split is behavior-preserving: the full existing app test suite stays green,
  and a build passes. No new logic tests for the move itself.

## Out of scope (v1)

- FWHM / HFR / eccentricity per sub (new detector — deferred).
- Auto-rejection by metric threshold (this is manual flagging only; the existing intake
  registration rejection and per-pixel σ-clip are untouched).
- Editing/rejecting subs of a *past* session reopened from disk (live/just-finished
  session only for v1).

## File structure

- Create: `Sources/LiveAstroCore/Session/SubFrameRecord.swift`
- Create: `Sources/LiveAstroCore/Session/SubFrameCSV.swift`
- Create: `Sources/LiveAstroCore/Pipeline/RestackCoordinator.swift`
- Modify: `Sources/LiveAstroCore/Session/SessionModels.swift` (manifest field)
- Modify: `Sources/LiveAstroCore/Session/SessionManager.swift` (append/flag API)
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` (`onSubFrame` hook)
- Modify: `Sources/LiveAstroStudio/AppModel.swift` (published subFrames, flag, re-stack drive)
- Create: `Sources/LiveAstroStudio/StatsView.swift`
- Create: `Sources/LiveAstroStudio/CaptureSettingsView.swift`, `DisplaySettingsView.swift`,
  `BroadcastSettingsView.swift`, `DiagnosticsView.swift`
- Modify: `Sources/LiveAstroStudio/ControlView.swift` (reduce to `TabView` container + footer)
- Tests: `Tests/LiveAstroCoreTests/SubFrameRecordTests.swift`,
  `SubFrameCSVTests.swift`, `RestackCoordinatorTests.swift`
