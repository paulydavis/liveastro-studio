# Copy Health Snapshot Design

## Purpose

Make the new Session Health panel shareable. A beta user or operator should be able to click one small button and paste the current app state into a message without taking screenshots or digging through logs.

## Scope

Add a **Copy Health** action beside the `Session Health` title in `ControlView`.

The copied text is plain text:

```text
LiveAstro Session Health
State: Running
Source: Native stacking
Folder: /path/to/watch/folder
Last update: #12 · snapshot_0012.fit
Frames: accepted 12 · rejected 1
Last rejection: frame_0013.fit — no stars detected
OBS: live · 00:14:20 · 0 dropped · 3% congestion
Outputs: no finished session yet
```

The button appends one app log line: `Copied session health`.

## Architecture

Keep this UI-only and local to `Sources/LiveAstroStudio/ControlView.swift`.

The snapshot text must reuse the existing Session Health helper properties:

- `sessionStateText`
- `sourceSummaryText`
- `watchFolderSummaryText`
- `lastUpdateSummaryText`
- `framesSummaryText`
- `lastRejectionSummaryText`
- `obsSummaryText`
- `outputsSummaryText`

This keeps the copy action and on-screen panel aligned.

## Non-goals

- No new session manifest fields.
- No new engine, watcher, importer, OBS, persistence, or telemetry behavior.
- No per-sub quality report.
- No CSV export.
- No public sharing service integration.

## Verification

Because this is a SwiftUI display/action slice, the required gate is:

- `swift build`
- `git diff --check`
- final diff inspection confirming only `ControlView.swift` changes for production behavior

Full `swift test` is not required unless the implementation touches model, controller, pipeline, watcher, importer, OBS, or persistence behavior.
