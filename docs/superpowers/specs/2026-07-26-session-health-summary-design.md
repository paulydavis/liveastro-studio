# Session Health Summary Design

## Goal

Show a compact, always-visible health summary that answers: "What is LiveAstro
doing right now, and is the session healthy?" This closes the middle of the
workflow after the new start chooser and before the finished-session output
shortcuts.

This is a UI/discoverability slice. It does not change stacking, watching,
importing, OBS control, session persistence, or output generation.

## Current Ground Truth

`AppModel` and its controllers already expose enough state for a useful first
version:

- `isRunning`
- `importer.isImporting`
- `importer.isGeneratingReplay`
- `liveSource.isDetecting`
- `sourceMode`
- `watchFolder`
- `latestRecord`
- `integrationCaption`
- `acceptedCount`
- `rejectedCount`
- `log`
- `broadcast.broadcastState`
- `broadcast.streamHealth`
- `lastSessionDirectory`
- `replayURL`

The first version should derive display text from these facts. It should not
add new persisted state or ask the engine for deeper telemetry.

## Approach

Add a `Session Health` block in the fixed footer/control area, above the live
broadcast controls and output shortcuts. Keep it compact and scannable.

It should show:

- `State`: one of Detecting source, Importing, Rendering replay, Running, or
  Idle.
- `Source`: current source mode in public language.
- `Folder`: current watch folder, or `(none)`.
- `Last update`: latest snapshot index/file when present, otherwise the current
  integration caption such as `waiting for first stack…`.
- `Frames`: accepted/rejected counts.
- `Last rejection`: latest log line beginning with `✗ rejected`, or `(none)`.
- `OBS`: broadcast state, plus duration/dropped/congestion when live health is
  available.
- `Outputs`: replay/session-folder availability.

This is summary text only. Existing action buttons remain where they are.

## Component Shape

Keep the implementation local to `ControlView`:

- Add computed text helpers:
  - `sessionStateText`
  - `sourceSummaryText`
  - `watchFolderSummaryText`
  - `lastUpdateSummaryText`
  - `lastRejectionSummaryText`
  - `obsSummaryText`
  - `outputsSummaryText`
- Add a small nested `HealthItem` view for label/value pairs.
- Add `Session Health` footer block before the existing broadcast row.

No new model, controller, persistence, or core type is needed.

## Copy and Semantics

Use public wording:

- `.nativeStack` → `Native stacking`
- `.stackerOutput` → `Siril / external stacker`
- Missing folder → `(none selected)`
- Missing rejection → `(none)`
- Missing outputs → `no finished session yet`
- Replay present → `replay ready`
- Session folder present but replay absent → `session folder ready`

The summary must not pretend that watcher/staker-output mode has native accepted
counts. It may show `accepted 0 · rejected N` because that is existing app
state, but the text should not call it "native accepted frames" in the summary.

## State Priority

When multiple state flags are true, display the highest-priority state:

1. `liveSource.isDetecting` → `Detecting source`
2. `importer.isImporting` → `Importing`
3. `importer.isGeneratingReplay` → `Rendering replay`
4. `isRunning` → `Running`
5. otherwise → `Idle`

This mirrors user perception: a detector/import/replay operation is the thing
currently occupying the UI.

## Error Handling

No new errors are introduced. Missing values render as plain text placeholders
instead of alerts.

If `log` contains a rejection line, show the most recent one stripped of the
leading `✗ rejected ` prefix when possible. If stripping fails, show the whole
line.

## Testing and Verification

This is SwiftUI composition and pure display text. The gate is:

1. `swift build`
2. `git diff --check`
3. Manual visual smoke if the app can be opened:
   - idle app shows `Session Health`;
   - source/folder reflect current setup;
   - import/replay/detecting states win over idle/running;
   - latest update/rejection/output text changes with existing state.

A full `swift test` is not required unless implementation touches model,
controller, pipeline, watcher, importer, OBS, or persistence behavior.

## Out of Scope

- Per-sub quality/exposure reports.
- New telemetry recording.
- Health warnings or notifications.
- Disk-space checks.
- Persisted session health history.
- New session manifest fields.
- Changes to existing broadcast/output actions.
