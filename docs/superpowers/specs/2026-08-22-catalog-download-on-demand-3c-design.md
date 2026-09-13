# Catalog Download-on-Demand (sub-project 3c) — Design

**Date:** 2026-08-22 · **Status:** draft, pending user review
**Parent pillar:** native plate-solve / north-up. catalog ✓ · solver ✓ · 3a wiring ✓ · 3b north-up ✓ →
**3c catalog download-on-demand** (the last piece — turns "plate-solve works in tests" into "north-up
works in the shipped app").

**Goal:** The shipped app fetches the real Gaia bright-star catalog (~32 MB) on the user's explicit
request, caches it locally, and the plate-solver loads it from there — so north-up works end-to-end
without bundling CC BY-NC data into the MIT app.

## Decisions (settled)

- **Download-on-demand, not bundled** — keeps the MIT app free of the CC BY-NC 3.0 IGO Gaia data.
- **Hosting: GitHub Releases** on `paulydavis/liveastro-studio`. The pre-built `.bin` is a release
  asset (a Gaia-derived data file, not code — lives on the Release, never committed). Free CDN,
  versioned, no infra.
- **First-run UX: an explicit contextual affordance** next to the North-up toggle — "Download star
  catalog (~32 MB) to enable North up" with progress. No silent background downloads. Rationale: the
  toggle is disabled until a solve exists, and there is no solve without the catalog, so the download
  must be a self-explaining opt-in right where the feature it unlocks lives.
- **Cache: Application Support** (`~/Library/Application Support/LiveAstroStudio/catalog/brightstars.bin`).
- **Remove the bundled placeholder** (`Sources/LiveAstroCore/Resources/brightstars.bin` +
  `.copy("Resources")` in Package.swift). It's the only thing in that resource bundle, and once the
  catalog loads from the cache it's dead weight — removing it **eliminates the release-script
  bundle-copy landmine** (the scripts copy `LiveAstroStudio_LiveAstroStudio.bundle`, never the
  LiveAstroCore one, so a bundled core resource would be nil in the shipped app anyway).

## Components

### 1. `CatalogInstaller` (`Sources/LiveAstroCore/PlateSolve/CatalogInstaller.swift`)
Owns the cache location, the remote source, integrity, and the download.
```swift
public enum CatalogInstaller {
    /// GitHub Release asset URL for the pre-built G<=11 catalog + its SHA-256 (filled in after Paul
    /// uploads the asset). Overridable for tests.
    public static var remoteURL: URL
    public static var expectedSHA256: String
    /// ~/Library/Application Support/LiveAstroStudio/catalog/brightstars.bin
    public static func cacheURL() -> URL
    /// True iff a valid catalog file already exists in the cache.
    public static func isInstalled() -> Bool
    /// Download → verify SHA-256 + StarCatalog parse (magic/version/count) → atomically move into the
    /// cache. Reports fractional progress. Throws on network / checksum / parse failure (cache
    /// untouched on failure — never leaves a partial file where isInstalled() would accept it).
    public static func download(session: URLSession = .shared,
                                progress: @escaping (Double) -> Void) async throws
}
```

### 2. `StarCatalog` — load from the cache (replaces `bundled()`)
- Add `public static func load(from url: URL) -> StarCatalog?` (parse + `count > 0`, same fail-closed
  contract as today's `bundled()`).
- Add `public static func installed() -> StarCatalog?` = `load(from: CatalogInstaller.cacheURL())` when
  `isInstalled()`, else nil.
- Remove `bundled()` and the `Resources` bundle. Update the three test files that used `bundled()`
  (`PlateSolverTests`, `StarCatalogTests`, `SessionPipelineNorthUpTests`) to stage a catalog into the
  cache path (or a temp path) and load via `load(from:)`.

### 3. Pipeline wiring
`SessionPipeline.plateSolveCatalog = StarCatalog.installed()` (was `.bundled()`). Everything downstream
already treats a nil catalog as "plate-solve disabled" — so with no catalog installed, the pipeline is
an unchanged no-op and the North-up toggle stays disabled, exactly as today.

### 4. App UI + state (`AppModel`, `ControlView`)
- `AppModel.catalogState: CatalogState` = `.notInstalled | .downloading(Double) | .installed | .failed(String)`,
  initialized from `CatalogInstaller.isInstalled()`.
- `AppModel.downloadCatalog()` → runs `CatalogInstaller.download`, streams progress into `catalogState`,
  and on success re-points the live pipeline's `plateSolveCatalog = StarCatalog.installed()` so a solve
  can run without an app restart (and refreshes `solveAvailable`).
- `ControlView`, in the Display Adjustments section by the North-up toggle:
  - `.notInstalled` → a "Download star catalog (~32 MB) — enables North up" button.
  - `.downloading(p)` → a progress bar.
  - `.installed` → the normal North-up toggle (already gated on `solveAvailable`).
  - `.failed` → an error line + Retry.

### 5. Config + the ops step (Paul, out of code scope)
`CatalogInstaller.remoteURL`/`expectedSHA256` are constants Paul fills in after: (a) generating the
whole-sky **G≤11** catalog via `Scripts/download_gaia_catalog.py` on his own network (ESA is
unreachable from the dev sandbox; VizieR per-band works), and (b) attaching the `.bin` to a GitHub
Release + recording its SHA-256. Until then the code is complete and testable against a local/injected
URL; the app simply shows the download button and (with a placeholder URL) a clear failure on click.

## Testing
- **CatalogInstaller (the core):** download from a `file://` URL pointing at a small fixture catalog →
  `isInstalled()` true, cached bytes match; **SHA-256 mismatch → throws, cache untouched**; corrupt/
  truncated payload → parse rejects, cache untouched; atomic move (no partial file accepted); idempotent
  re-download.
- **StarCatalog.load(from:) / installed():** loads a staged cache file; nil when absent/empty/corrupt.
- **Pipeline:** unchanged from 3a's tests — inject `plateSolveCatalog` (the seam already exists); with
  no installed catalog, `currentWCS` stays nil and import is unaffected.
- **AppModel state machine:** `notInstalled → downloading → installed` on success (with a mock installer /
  `file://` URL); `→ failed` on checksum/network error; on success `solveAvailable`/plate-solve pick up
  the catalog live.
- **Gated real-frame tests:** stage the real catalog into the cache path and load via `installed()`
  (replacing the old `bundled()` staging).

## Non-goals (3c)
- Generating or hosting the actual catalog (Paul's op step — code is parameterized on URL + hash).
- The plate-solver, the pipeline solve-wiring, or north-up rendering (done in solver/3a/3b).
- Auto-updating the catalog / multiple catalog depths (single pinned asset for now).
- Bundling any Gaia data (explicitly avoided for licensing).

## Open decisions (flag for review)
- Cache location: Application Support (chosen) vs Caches (the OS can purge Caches — bad for a 32 MB
  asset you don't want silently evicted, hence Application Support).
- Should a `NOTICE`/attribution for Gaia DR3 (ESA/DPAC) ship in-app near the download button? (Low cost,
  good provenance — recommend yes.)
