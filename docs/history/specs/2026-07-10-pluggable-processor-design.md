# LiveAstro Studio — "Pluggable Processor" Design

**Date:** 2026-07-10 · **Status:** approved for planning ·
**Origin:** the GraXpert post-processing workflow proven by hand this session
(LiveAstro master → GraXpert bg/denoise/deconv → dramatically better NGC 6960),
now baked into the app as a pluggable backend — the same pattern as the shipped
`RejectionMethod`.

## 1. Goal

Add **post-stack image processing** (background extraction + denoising) to the
exported master as an **explicit, non-destructive, offline, pluggable** step.
Ship the **GraXpert** backend (free, already installed, CLI-verified) so any user
with GraXpert installed can one-click a processed master, without touching the
raw one.

## 2. Core principles (settled 2026-07-10 with Paul)

- **Pluggable backend**, like `RejectionMethod` — a `Processor` protocol; users
  pick their backend, no lock-in.
- **Explicit, not automatic** — a "Process master" action on a finished session
  (mirrors the existing `regenerateReplay` post-session action), never on the
  session-end critical path. A multi-minute CPU op must not block anything.
- **Non-destructive** — writes `master_processed.fit`; the raw `master.fit` is
  never modified (Paul takes the raw master into PixInsight himself).
- **Conservative defaults** — denoise strength `0.5` (experimentally validated:
  `0.9` over-smoothed the Veil; the eye preferred `0.5`–`0.6`). No blind
  auto-tuning; no sliders this build.
- **Graceful absence** — GraXpert can't be bundled (licensing); we call the
  user's own install and degrade cleanly when it's missing.

## 3. Decisions

| Decision | Choice |
|---|---|
| Trigger | **Explicit "Process master" action** on a finished session (like Regenerate replay) |
| Output | **`master_processed.fit`** alongside `master.fit`; raw master untouched |
| Op chain (GraXpert) | **background-extraction → denoising (`-strength 0.5`)**; deconvolution deferred |
| Backend selection | `SessionSettings.processorBackend` = `.none` (default) or `.graxpert`; picker in Setup |
| External-process seam | `GraXpertProcessor` calls an injectable `ProcessRunner` (real = Foundation `Process`; fake in tests) |
| GraXpert location | auto-detect `/Applications/GraXpert.app/Contents/MacOS/GraXpert` |
| GPU flag | always `-gpu false` (no GPU accel on macOS; avoids errors) |

## 4. Architecture

```
LiveAstroCore/
  Processing/
    Processor.swift          (NEW: Processor protocol + ProcessorBackend enum)
    ProcessRunner.swift      (NEW: ProcessRunner protocol + FoundationProcessRunner)
    GraXpertProcessor.swift  (NEW: GraXpert CLI backend + path detection)
  Settings/
    SessionSettings.swift    (+ processorBackend field, backward-compat decode)
LiveAstroStudio/
    AppModel.swift           (+ processMaster(sessionDirectory:), isProcessing, lastSessionDirectory)
    ControlView.swift        (+ Post-process picker + "Process master" button)
```

### 4.1 `Processor` protocol (LiveAstroCore)

```swift
public protocol Processor {
    var name: String { get }
    var isAvailable: Bool { get }
    /// Read `masterURL`, write the processed result to `outputURL`.
    /// Throws on failure (tool missing, non-zero exit, missing output).
    func process(masterURL: URL, outputURL: URL, log: ((String) -> Void)?) throws
}

public enum ProcessorBackend: String, CaseIterable, Codable {
    case none, graxpert
}
```
`ProcessorBackend.none` means "no processing" (the button is disabled) — there is
no `NoProcessor` type; the app simply doesn't run a processor for `.none`.

### 4.2 `ProcessRunner` seam (LiveAstroCore)

```swift
public protocol ProcessRunner {
    /// Run `executable` with `arguments`, streaming any output to `log`.
    /// Returns the process exit code.
    func run(executable: URL, arguments: [String], log: ((String) -> Void)?) throws -> Int32
}
public struct FoundationProcessRunner: ProcessRunner { /* Foundation Process */ }
```
This is the testability seam: `GraXpertProcessor` takes a `ProcessRunner`; tests
inject a fake that records the commands and simulates the output file, so the
backend is fully unit-testable without the real GraXpert binary.

### 4.3 `GraXpertProcessor` (LiveAstroCore)

```swift
public struct GraXpertProcessor: Processor {
    public init(executable: URL, runner: ProcessRunner = FoundationProcessRunner(),
                denoiseStrength: Double = 0.5)
    /// Auto-detected default install location, or nil if absent.
    public static func defaultExecutable(fileManager: FileManager = .default) -> URL?
}
```
- `name` = `"GraXpert"`.
- `isAvailable` = the executable exists and is a file (via the injected
  `FileManager`/runner — checked with `FileManager.isExecutableFile` or existence).
- `process(masterURL:outputURL:log:)`:
  1. Make a temp file `bgTmp` in the session dir (or `FileManager.temporaryDirectory`).
  2. `runner.run(executable, ["-cli","-cmd","background-extraction","-gpu","false","-output", bgTmp.path, masterURL.path], log)` → require exit 0.
  3. `runner.run(executable, ["-cli","-cmd","denoising","-strength","0.5","-gpu","false","-output", outputURL.path, bgTmp.path], log)` → require exit 0.
  4. Verify `outputURL` exists; else throw `ProcessorError.noOutput`.
  5. Remove `bgTmp` (best-effort).
- Errors: `ProcessorError.notAvailable`, `.stepFailed(cmd:code:)`, `.noOutput`.

> GraXpert writes `<output>.fits` — confirm the exact output extension/naming the
> CLI produces (it appended `.fits` in this session's runs); the implementer
> pins `outputURL` to whatever GraXpert actually writes so the sibling file is
> named predictably (`master_processed.fits` is acceptable if that's what the
> CLI emits).

### 4.4 App wiring (`AppModel`)

Mirror `regenerateReplay(sessionDirectory:)`:
```swift
@Published var isProcessing = false
private(set) var lastSessionDirectory: URL?   // set from end()/import completion

func processMaster(sessionDirectory: URL) {
    guard !isProcessing, !isImporting else { return }
    guard let proc = makeProcessor(), proc.isAvailable else {
        errorMessage = "GraXpert not found — install it from graxpert.com"; return
    }
    isProcessing = true
    Task.detached { [weak self] in
        do {
            let master = sessionDirectory.appendingPathComponent("master.fit")
            let out = sessionDirectory.appendingPathComponent("master_processed.fit")
            try proc.process(masterURL: master, outputURL: out) { m in
                Task { @MainActor in self?.log.append(m) }
            }
            await MainActor.run { self?.isProcessing = false; self?.log.append("Processed → \(out.lastPathComponent)") }
        } catch {
            await MainActor.run { self?.isProcessing = false; self?.errorMessage = "Processing failed: \(error)" }
        }
    }
}
```
`makeProcessor()` returns a `GraXpertProcessor` when `settings.processorBackend
== .graxpert` and the default executable exists, else nil.

### 4.5 UI (`ControlView`)

- A **Post-process picker** near the other stacking options: segmented
  `None | GraXpert`, bound to `appModel.processorBackend`; the GraXpert case is
  disabled with a helper tooltip when `GraXpertProcessor.defaultExecutable() ==
  nil` ("GraXpert not found — install from graxpert.com").
- A **"Process master"** button (in the footer or session controls), enabled when
  `lastSessionDirectory != nil && processorBackend == .graxpert && available &&
  !isProcessing`, calling `processMaster(sessionDirectory: lastSessionDirectory!)`.
  Disabled with a spinner/label while `isProcessing`.

## 5. Data flow

```
[finished session dir with master.fit]
  user taps "Process master"
    AppModel.processMaster(dir) → Task.detached
      GraXpertProcessor.process(master.fit → master_processed.fit)
        run: GraXpert -cli -cmd background-extraction -gpu false -output tmp master.fit
        run: GraXpert -cli -cmd denoising -strength 0.5 -gpu false -output master_processed.fit tmp
        verify output; cleanup tmp
      → log "Processed → master_processed.fit"  (raw master.fit untouched)
```

## 6. Error handling

| Situation | Behavior |
|---|---|
| GraXpert not installed | picker's GraXpert case disabled + hint; `processMaster` sets a helpful `errorMessage`, no crash |
| `master.fit` missing in the session dir | throw / `errorMessage`; no output written |
| A GraXpert step exits non-zero | throw `ProcessorError.stepFailed`; surface in log; no partial `master_processed.fit` left claimed as good |
| Output file not produced | throw `ProcessorError.noOutput` |
| Backend `.none` | Process button disabled; nothing runs |

## 7. Testing

`swift test --filter LiveAstroCoreTests`

- **`GraXpertProcessor` with a fake `ProcessRunner`:**
  - issues exactly two `run` calls, in order: background-extraction then
    denoising, with the expected argument arrays (incl. `-gpu false`,
    `-strength 0.5`, the temp handoff, correct input/output paths);
  - simulated exit 0 + fake writing the output → `process` succeeds, temp cleaned;
  - a non-zero exit on step 1 → throws `stepFailed`, step 2 never runs;
  - output file not created by the fake → throws `noOutput`.
- **`isAvailable` / `defaultExecutable`** — with an injected `FileManager`/path:
  present path → available; absent → nil / not available.
- **`SessionSettings.processorBackend`** — Codable round-trip; an old blob
  lacking the key decodes to `.none` (backward-compatible, matching the
  clean-export/rejection decode pattern).
- **No real-GraXpert test in CI** — documented; the real end-to-end run is manual
  validation (this session already proved the actual chain on NGC 6960).
- **App wiring (`processMaster`, UI)** — manual validation; SwiftUI/window
  lifecycle isn't unit-tested in scope.

## 8. Non-goals (future builds)

Live-view processing (background-extraction on the live stack — a later pillar);
a native ONNX→Core ML denoise backend (removes the external dependency);
the RC-Astro backend (only if their tools ship a standalone/CLI); deconvolution
(`deconv-obj`/`deconv-stellar`) in the chain; per-op toggles and strength
sliders; auto-parameter tuning.

## 9. Risks

| Risk | Mitigation |
|---|---|
| GraXpert CLI output naming/extension differs from expected | implementer pins `outputURL` to what GraXpert actually writes (verified `.fits` this session); a test asserts the produced sibling path |
| Foundation `Process` used off the main thread / env issues | mirror the existing `Process` use in `AppModel`; run on `Task.detached`; `-gpu false` avoids GPU-init failures on Mac |
| A partial/failed run leaves a bogus `master_processed.fit` | verify output + exit codes; on failure, don't claim success (leave only via a clear error); optionally write to a temp then move on success |
| External-process invocation in a Foundation-only core | `Process` is Foundation; the seam is the `ProcessRunner` protocol so Core stays testable and the real runner is a thin wrapper |
| RC-Astro "coming soon" over-promise | not in scope; picker shows only None/GraXpert this build |
