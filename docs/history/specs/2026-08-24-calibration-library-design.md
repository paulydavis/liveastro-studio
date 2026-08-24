# Calibration Library — Design

**Status:** approved (design), 2026-08-24
**Supersedes/extends:** `2026-07-08-calibration-design.md` (single-file dark/flat/bias picker)

## Goal

Turn calibration from "pick a master file each session" into a **managed library** of reusable master **darks and bias**, keyed by camera + capture settings, auto-matched to each session, rebuildable on demand — with **flats built fresh each session** and **optional dark-flats**.

## Motivation

Master darks and bias are stable per camera at a given gain/exposure/temperature — you shoot them once and reuse them for months. Flats are optical-train-specific and change every session (dust, rotation, focus), so they're shot fresh, ideally before the lights. Today the app makes you hand-pick a master file every time; there is no library and no auto-matching. This closes that gap.

## What already exists (reuse, do not rebuild)

- `MasterBuilder.combine(fitsURLs:kind:bias:)` — mean-combines raw FITS into a master dark/flat/bias; for flats it subtracts a bias/dark-flat per frame and normalizes to median 1. **Master creation is done.**
- `Calibrator(dark:flat:)` — per-frame dark-subtract + flat-divide, size-mismatch-safe, orientation-aware. **Application is done.**
- `SourceMetadata(fitsKeywords:)` — already parses `instrument` (INSTRUME), `exposureSeconds` (EXPTIME), `gain` (GAIN), `ccdTempC` (CCD-TEMP). Add `binning` (XBINNING) and `setTempC` (SET-TEMP).
- `CatalogInstaller` — the Application-Support-with-test-seam storage pattern to mirror for the library.

The new work is the **library store**, the **matcher/scaler**, header-field additions, and the **UI**. The matcher produces a final master dark (possibly scaled) + master flat and hands them to the existing `Calibrator` unchanged.

## Decisions (approved)

1. **Matching = hybrid.** Auto-match a library master to the session from the lights' headers; if nothing matches, prompt the user to pick one or skip (run uncalibrated) with a clear warning.
2. **Exposure = exact-preferred, scale-as-fallback.** Prefer an exact-exposure dark; if none, scale the nearest dark to the light's exposure using bias: `scaled = bias + (dark − bias) × (expLight / expDark)`. This is why bias is stored alongside darks. A "Scale darks across exposures" toggle (default on) can disable scaling.
3. **Temp tolerance = ±2 °C** on set-point (SET-TEMP, fallback CCD-TEMP). Frames with no temperature (uncooled) match ignoring temperature, with a warning.
4. **Bias scope.** Bias is stored for **flat-building** and **dark-scaling** only; it is *not* separately subtracted from lights (a matched or scaled dark already contains the bias).
5. **Flats are per-session**, never stored in the library. Optional **dark-flats** per session occupy the flat's offset role (already supported by `MasterBuilder`).

## Data model

`MasterFrame` (library entry, `Codable`):
- `id: UUID`
- `kind: MasterKind` (`dark` | `bias`; dark-flats are session-scoped, not library entries)
- `camera: String` (INSTRUME, or user label)
- `gain: Double?`
- `exposureSeconds: Double?` (nil for bias)
- `setTempC: Double?` (SET-TEMP → CCD-TEMP; nil if uncooled)
- `binning: Int?` (XBINNING)
- `width, height, channels: Int` (size-match guard)
- `frameCount: Int`
- `sourceFolderBookmark: Data?` (security-scoped bookmark for Rebuild)
- `createdAt: Date`
- `fileName: String` (`master-<id>.fit` in the library dir)

**Store:** `~/Library/Application Support/LiveAstroStudio/CalibrationLibrary/` with `index.json` (array of `MasterFrame`) + one `master-<id>.fit` per entry. Test seam: an overridable base directory (mirror `CatalogInstaller`).

## Components (new)

### `CalibrationLibrary.swift` (LiveAstroCore/Calibration)
On-disk store + CRUD. `all()`, `add(kind:camera:gain:exposure:setTemp:binning:from:onProgress:) throws -> MasterFrame` (reads headers of the first raw, `MasterBuilder.combine`, writes the `.fit`, appends index), `rebuild(id:) throws`, `remove(id:)`, `master(for: MasterFrame) -> AstroImage?` (loads the `.fit`). Atomic index writes.

### `CalibrationMatcher.swift` (LiveAstroCore/Calibration) — PURE, unit-tested
Input: light `SourceMetadata` + `[MasterFrame]` + options (scaleEnabled, tempTolerance). Output:
```
struct CalibrationMatch {
  var dark: MatchResult?   // .exact(MasterFrame) | .scaled(base: MasterFrame, bias: MasterFrame, factor: Double) | .none(reason)
  var bias: MasterFrame?
  var warnings: [String]
}
```
Pure selection + scaling-factor math; no I/O. The caller loads the chosen masters, applies scaling via `DarkScaler`, and constructs the `Calibrator`.

### `DarkScaler.swift` (LiveAstroCore/Calibration) — PURE, unit-tested
`scale(dark: AstroImage, bias: AstroImage, factor: Double) -> AstroImage` implementing `bias + (dark − bias) × factor`, clamped ≥ 0.

### `SourceMetadata` extension
Add `binning` (XBINNING, Int) and `setTempC` (SET-TEMP, Double). Backward-compatible (optional).

### `CalibrationSection.swift` (app) — extended UI
- **Darks / Bias library**: list rows (`camera · gain · exp · temp · ×N`), Add-dark / Add-bias (folder picker → progress), Rebuild, Delete.
- **Auto-match status** line: `180 s dark @ −10 °C, gain 100 ✓` or `No matching dark — [Pick…] [Skip]` (scaled shows `scaled 120 s→180 s ✓`).
- **Flats (this session)**: choose raw-flats folder → builds master flat now; optional **Dark-flats** folder. Status: `24 flats → master ✓`.
- Toggle: **Scale darks across exposures**.

### Wiring (`AppModel`)
At session start: read the first light's metadata (already available via `sourceMetadata`), run `CalibrationMatcher`, load + scale the chosen dark, build the session flat (if provided) with the matched bias/dark-flat, construct the `Calibrator`, and surface the match status + warnings in the log and the Calibration section.

## Persistence / migration

`CalibrationSelection` evolves to reference library entry `id`s for dark/bias plus a session flat path. Old `darkPath`/`flatPath`/`biasPath` values migrate to ad-hoc (non-library) masters so existing setups keep working.

## Testing

- `CalibrationLibrary`: index round-trip; add reads headers + writes master + indexes; rebuild replaces; remove deletes file + entry (use the dir test seam + synthetic FITS fixtures).
- `CalibrationMatcher`: exact match; temp within/outside tolerance; missing-temp (uncooled) path; no-match reason; scale-fallback selection; scaleEnabled=false disables scaling.
- `DarkScaler`: scaling math on synthetic frames (byte/precision), factor 1.0 == identity, clamp ≥ 0.
- `SourceMetadata`: XBINNING / SET-TEMP parsing.
- `MasterBuilder`/`Calibrator`: already covered.
- UI + AppModel wiring: not CI-testable (documented), covered by manual verification.

## Non-goals

- Capturing calibration frames (the app doesn't drive the camera — it builds masters from raw files the user provides).
- Bad-pixel maps / cosmetic correction, defect maps, or per-amp calibration.
- Cloud sync of the library.

## Rollout

Feature branch `feature/calibration-library`; spec → implementation plan (writing-plans) → subagent/inline task execution with tests green at each step; released in a subsequent version.
