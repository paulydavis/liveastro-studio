# Catalog Download-on-Demand (3c) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** The shipped app downloads the Gaia bright-star catalog (~32 MB) on explicit user request, caches it, and the plate-solver loads it from there — so north-up works end-to-end without bundling CC BY-NC data.

**Architecture:** A `CatalogInstaller` (cache path + remote URL/SHA-256 + verified, atomic download); `StarCatalog.installed()` loads from the cache (replacing `bundled()`); the pipeline points at it; the app shows a contextual download affordance + progress next to the North-up toggle; the LiveAstroCore `Resources` bundle is removed (kills the release-script landmine).

**Tech Stack:** Swift 5.10, SPM, macOS 14+, SwiftUI, URLSession, CryptoKit (SHA-256), XCTest.

## Global Constraints

- Branch `feature/catalog-download-3c` (created). NEVER commit to `main`.
- Commit trailer `Claude-Session: https://claude.ai/code/session_01DskXfU4g9ZkcDGHexnYB8j`; no `Co-Authored-By`.
- One `swift test`/`build` at a time; build to `--scratch-path /private/tmp/claude-501/-Users-pauldavis/2349d1c1-e213-4a31-a397-bea11f9674d7/scratchpad/las-build`.
- Download-on-demand ONLY — never bundle Gaia data. No catalog installed → plate-solve is an unchanged no-op (toggle disabled), exactly as today.
- The real catalog URL + SHA-256 are supplied by Paul after he generates + uploads the asset; code is built + tested against a `file://` fixture and stays correct with a placeholder URL (download just fails cleanly).
- Download must be **atomic + verified**: never leave a partial/wrong file where `isInstalled()` would accept it.

---

### Task 1: `CatalogInstaller` — cache path, verified atomic download

**Files:** Create `Sources/LiveAstroCore/PlateSolve/CatalogInstaller.swift`; Test `Tests/LiveAstroCoreTests/CatalogInstallerTests.swift`.

**Interfaces / Produces:**
```swift
public enum CatalogInstaller {
    public static var remoteURL: URL          // GitHub Release asset (placeholder until Paul uploads)
    public static var expectedSHA256: String  // lowercase hex; "" disables the check (dev)
    public static func cacheURL() -> URL       // App Support/LiveAstroStudio/catalog/brightstars.bin
    public static func isInstalled() -> Bool   // a parseable, non-empty catalog exists at cacheURL()
    public static func download(from url: URL? = nil, session: URLSession = .shared,
                                progress: @escaping (Double) -> Void) async throws
    public enum InstallError: Error, Equatable { case checksumMismatch, invalidCatalog, http(Int) }
}
```

- [ ] **Step 1: Failing tests.**
  - `testDownloadsFromFileURLAndInstalls`: point `download(from:)` at a `file://` URL of a small valid fixture catalog (build with `StarCatalog.encode`), with `expectedSHA256` set to the fixture's real hash → after await, `isInstalled()` true and `cacheURL()` bytes == fixture bytes.
  - `testChecksumMismatchThrowsAndLeavesCacheClean`: wrong `expectedSHA256` → throws `.checksumMismatch`, `isInstalled()` false, no file at `cacheURL()`.
  - `testCorruptPayloadRejected`: fixture that isn't a valid LASC (or truncated) → throws `.invalidCatalog`, cache clean.
  - Use a per-test cache dir override (see Step 3) so tests don't touch the real Application Support path.
- [ ] **Step 2: Run, verify fail.** `swift test --scratch-path <scratch> --filter CatalogInstallerTests`
- [ ] **Step 3: Implement.**
  - `cacheURL()`: `FileManager.default.url(for: .applicationSupportDirectory, ...)` + `LiveAstroStudio/catalog/brightstars.bin`; create intermediate dirs. Add an internal `cacheDirectoryOverride: URL?` (settable in tests) so tests use a temp dir.
  - `download`: `URLSession.download` (or `data`) from `url ?? remoteURL`; on non-2xx throw `.http(code)`; compute SHA-256 with `CryptoKit.SHA256`; if `expectedSHA256` non-empty and mismatched → `.checksumMismatch`; parse via `StarCatalog(data:)` and require `count > 0` else `.invalidCatalog`; write to a temp file then `FileManager.replaceItemAt`/atomic move into `cacheURL()`. Report progress (0…1) via the callback (URLSession delegate or incremental read).
  - `isInstalled()`: `StarCatalog.load(from: cacheURL()) != nil` (Task 2).
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** `feat(catalog): CatalogInstaller — verified atomic download-to-cache`.

---

### Task 2: `StarCatalog.installed()` / `load(from:)`; remove `bundled()` + the Resources bundle

**Files:** Modify `Sources/LiveAstroCore/PlateSolve/StarCatalog.swift`; `Package.swift`; delete `Sources/LiveAstroCore/Resources/`; update `Tests/.../StarCatalogTests.swift`, `PlateSolverTests.swift`, `SessionPipelineNorthUpTests.swift` (the three `bundled()` users).

**Interfaces:** Produces `StarCatalog.load(from: URL) -> StarCatalog?`, `StarCatalog.installed() -> StarCatalog?`. Removes `StarCatalog.bundled()`.

- [ ] **Step 1: Failing test** (`StarCatalogTests`): `load(from:)` returns a catalog for a staged valid file, nil for missing/empty/corrupt; `installed()` reflects a catalog staged at `CatalogInstaller.cacheURL()` (via the test cache override).
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement.** Add `load(from:)` (same parse + `count > 0` fail-closed contract as the old `bundled()`); `installed()` = `CatalogInstaller.isInstalled() ? load(from: CatalogInstaller.cacheURL()) : nil`. Delete `bundled()`. Remove `Sources/LiveAstroCore/Resources/` and the `.copy("Resources")` from `Package.swift`'s LiveAstroCore target.
- [ ] **Step 4: Update the gated real-frame tests** (`PlateSolverTests.testSolvesRealM63Frame`, `SessionPipelineNorthUpTests.testRealM63NorthEndsUp`) + `StarCatalogTests` bundled-contract tests to stage a catalog into the cache path and load via `installed()`/`load(from:)` instead of `bundled()`.
- [ ] **Step 5: Run all three affected test files + confirm the package still builds without the Resources bundle.** **Commit** `refactor(catalog): load from cache (installed()), drop bundled() + Resources bundle`.

---

### Task 3: Pipeline wiring

**Files:** Modify `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` (line ~90).

- [ ] **Step 1:** Change `var plateSolveCatalog: StarCatalog? = StarCatalog.bundled()` → `= StarCatalog.installed()`.
- [ ] **Step 2:** Add `public func reloadCatalog()` that sets `plateSolveCatalog = StarCatalog.installed()` and clears `solveAttempted`/`solvedWCS` (via `invalidatePlateSolve()`) so a fresh download takes effect on the live pipeline without a restart. (Thread-safe: same pattern as reseed.)
- [ ] **Step 3: Test** (`SessionPipelinePlateSolveTests` or NorthUp): with a catalog staged into the cache after start, `reloadCatalog()` makes a subsequent seed solve (was nil before). **Commit** `feat(catalog): pipeline loads installed catalog + reloadCatalog() after download`.

---

### Task 4: App UI + download state

**Files:** Modify `Sources/LiveAstroStudio/AppModel.swift` (`catalogState`, `downloadCatalog()`); `Sources/LiveAstroStudio/ControlView.swift` (affordance near North-up).

- [ ] **Step 1:** `AppModel`: `enum CatalogState { case notInstalled, downloading(Double), installed, failed(String) }`; `var catalogState` initialized from `CatalogInstaller.isInstalled()`; `func downloadCatalog()` runs `CatalogInstaller.download(progress:)` (on a background Task), streams progress into `catalogState` on MainActor, on success sets `.installed` + calls `pipeline?.reloadCatalog()` + refreshes `solveAvailable`, on error `.failed(msg)`.
- [ ] **Step 2:** `ControlView`, in Display Adjustments by the North-up toggle:
  - `.notInstalled` → Button "Download star catalog (~32 MB) — enables North up" → `model.downloadCatalog()`.
  - `.downloading(p)` → `ProgressView(value: p)`.
  - `.installed` → the existing North-up toggle (gated on `solveAvailable`).
  - `.failed(m)` → red text + "Retry".
  - A small "Gaia DR3 (ESA/DPAC)" attribution caption under it.
- [ ] **Step 3:** Build the app target; add an `AppModel` unit test where feasible (state transitions with a `file://` URL injected into `CatalogInstaller`). **Commit** `feat(catalog): North-up download affordance + progress in ControlView`.

---

### Task 5: Config + docs for the ops step

**Files:** `CatalogInstaller.swift` (real URL/hash placeholders + doc), a short `docs/CATALOG.md`.

- [ ] **Step 1:** Leave `remoteURL`/`expectedSHA256` as clearly-marked placeholders with a comment pointing at `docs/CATALOG.md`.
- [ ] **Step 2:** Write `docs/CATALOG.md`: how to (a) generate the G≤11 catalog (`Scripts/download_gaia_catalog.py`, note the dense-band caveat), (b) create the GitHub Release + upload the asset (`gh release create`), (c) get the URL + `shasum -a 256`, (d) drop both into `CatalogInstaller`. **Commit** `docs(catalog): CATALOG.md — generate/host/wire the release asset`.

---

## Post-plan verification
- [ ] Full `swift test` green (build to scratch path); package builds with no Resources bundle.
- [ ] With no catalog installed: app shows the download button, plate-solve is a no-op, North-up disabled — no regression vs pre-3c.
- [ ] Adversarial review of `CatalogInstaller` (atomicity, partial-download/checksum edge cases, path handling) before merge.
