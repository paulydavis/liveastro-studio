# Output Footprint Guardrail Design

## Purpose

Give users a simple, visible storage guardrail without adding automatic cleanup. LiveAstro writes sessions, snapshots, replays, masters, and now `latest.png`; beta users should be able to see roughly how much space the output area is using.

## Scope

Add a user-triggered **Refresh Sizes** action in Session Outputs.

Behavior:

- Display `Output footprint: not checked` by default.
- Button label: **Refresh Sizes**.
- When clicked, compute:
  - `LiveAstro root: <size>` for `model.liveAstroRoot`
  - `last session: <size>` when `model.lastSessionDirectory` exists
- Display one compact line:
  - `Output footprint: root 1.2 GB · last session 240 MB`
  - or `Output footprint: root 1.2 GB`
- Include the same footprint string in **Copy Support Bundle**.
- If size calculation fails, display:
  - `Output footprint: unavailable`
  - and append an honest log line beginning `Could not calculate output footprint: `

## Architecture

Add a small Foundation-only core utility:

```swift
public enum DirectoryFootprint {
    public static func byteCount(at root: URL, fileManager: FileManager = .default) throws -> Int64
}
```

`DirectoryFootprint` recursively enumerates regular files under a directory and sums their file sizes.

In `ControlView`:

- Add `@State private var outputFootprintText = "not checked"`.
- Add `refreshOutputFootprint()` that calls `DirectoryFootprint.byteCount(...)` only when the user clicks the button.
- Add the display line and button to Session Outputs.
- Add `Output footprint: \(outputFootprintText)` to the support bundle.

## Non-goals

- No automatic background scanning.
- No cleanup/delete controls.
- No disk-free-space monitoring.
- No warning thresholds yet.
- No changes to session/replay/snapshot generation.
- No engine, watcher, importer, OBS, or persistence behavior changes.

## Tests

Add `DirectoryFootprintTests`:

- sums nested regular files;
- returns zero for an empty directory;
- throws when the root does not exist.

## Verification

- `swift test --filter DirectoryFootprintTests`
- `swift build`
- `git diff --check`

Full `swift test` is not required unless targeted tests uncover broader regressions.
