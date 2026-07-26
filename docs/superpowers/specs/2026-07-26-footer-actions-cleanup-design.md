# Footer Actions Cleanup Design

## Purpose

The footer gained useful beta/support actions quickly. This pass keeps the functionality but makes the layout calmer and more predictable, so it reads as “tools grouped by job” instead of a long horizontal button pile.

## Scope

Clean up footer action ordering and grouping in `ControlView`.

Changes:

- In `Session Health`, order actions as:
  - `Open Watch Folder`
  - `Copy Health`
- In `Session Outputs`, split finished-session actions into two rows:
  - an open/reveal row: `Open Replay`, `Reveal Replay`, `Open Session Folder`, `Reveal master.fit` or disabled `No master.fit`
  - a copy/share row: `Copy Support Bundle`, `Copy Summary`
- Keep `Open Sessions Folder` and `Regenerate Replay…` in the `Session Outputs` header.

## Architecture

Keep the slice local to `Sources/LiveAstroStudio/ControlView.swift`.

No helper extraction is required. This is a SwiftUI layout pass: move existing buttons and keep their existing actions, disabled rules, and help text.

## Design Notes

The layout rule is “things that open Finder or files first, things that copy text last.” That matches what users are trying to do and makes the support actions feel intentional rather than bolted on.

## Non-goals

- No new actions.
- No removed actions.
- No copy text changes.
- No engine, watcher, importer, OBS, persistence, or pipeline behavior changes.
- No visual redesign of the full app.

## Verification

- `swift build`
- `git diff --check`
- final diff inspection confirming production behavior changes only in `ControlView.swift`

Full `swift test` is not required because this is a SwiftUI layout-only slice.
