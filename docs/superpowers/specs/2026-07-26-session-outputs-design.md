# Session Outputs Design

## Goal

Make finished session artifacts discoverable inside the app. After a live
session ends or a previous-shoot import completes, a user should not have to
dig through Finder to answer: "Where is my replay, session folder, and master?"

This is a UI/discoverability slice. It does not change the stacking core,
session manifest schema, replay generation, import pipeline, watcher, OBS, or
release packaging.

## Current Ground Truth

`AppModel` already tracks the two facts this slice needs:

- `replayURL`: set after live-session `end()` succeeds, import `end()`
  succeeds, or replay regeneration succeeds.
- `lastSessionDirectory`: set from the replay URL's parent directory after live
  session end/import completion, and set directly by replay regeneration.

External-stacker sessions and failed/empty native sessions may not have
`master.fit`. That is expected and must not be presented as an error.

## Approach

Add a `Session Outputs` section in the fixed footer area when the app is not
running and there is either a `replayURL` or a `lastSessionDirectory`.

Keep the existing `Regenerate Replay…` action, but move it near the output
actions so the footer reads as one finished-session toolbox.

Actions:

- `Open Replay` — opens `model.replayURL` with the system default app.
- `Reveal Replay` — reveals `model.replayURL` in Finder.
- `Open Session Folder` — opens `model.lastSessionDirectory` in Finder.
- `Reveal master.fit` — reveals `master.fit` when it exists in the last session
  directory.
- `No master.fit` — disabled explanatory label/button when the last session
  directory exists but `master.fit` does not.
- `Copy Summary` — copies a plain-text summary to the pasteboard.

## Summary Text

`Copy Summary` writes deterministic, plain text with only facts already present
in app state or the filesystem:

```text
LiveAstro Session
Target: <target or "(untitled)">
Session folder: <path or "(none)">
Replay: <path or "(none)">
Master: <path or "(none)">
Accepted frames: <acceptedCount>
Rejected frames: <rejectedCount>
```

If `master.fit` is absent, the master line is `(none)`. Do not infer why it is
absent; the help text can explain that external-stacker/Siril sessions may not
produce a native master.

## Component Shape

Keep the first pass local to `ControlView`:

- Add computed helpers:
  - `hasSessionOutputs`
  - `latestMasterURL`
- Add button helper methods:
  - `openReplay()`
  - `revealReplay()`
  - `openSessionFolder()`
  - `revealMaster()`
  - `copySessionSummary()`
- Add a small `Session Outputs` footer block.

No new controller, model state, or persistence type is needed.

## State and Disabled Rules

- Only show the section when `!model.isRunning` and either `model.replayURL` or
  `model.lastSessionDirectory` exists.
- Disable `Open Replay` and `Reveal Replay` when `replayURL` is nil.
- Disable `Open Session Folder` when `lastSessionDirectory` is nil.
- Enable `Reveal master.fit` only when `lastSessionDirectory/master.fit` exists.
- Keep `Regenerate Replay…` disabled while `model.importer.isGeneratingReplay`.
- Keep `Process master` behavior unchanged.

## Error Handling

Opening/revealing uses AppKit/Finder best-effort behavior. If an output URL is
nil, the corresponding action is disabled rather than presenting an error.

If `master.fit` is absent, show disabled `No master.fit` text with help:

> Native sessions write `master.fit` when a current stack exists. Siril/external
> stacker sessions may not create one.

## Testing and Verification

This is SwiftUI composition plus AppKit utility calls. The gate is:

1. `swift build`
2. `git diff --check`
3. Manual visual smoke if the app can be opened:
   - finish/import/regenerate state shows `Session Outputs`;
   - `Open Replay`, `Reveal Replay`, `Open Session Folder`, `Reveal master.fit`
     are visible with correct enablement;
   - `No master.fit` appears disabled when the master is absent;
   - existing `Regenerate Replay…` and `Process master` affordances remain.

A full `swift test` is not required unless implementation touches model,
controller, pipeline, watcher, importer, OBS, or persistence behavior.

## Out of Scope

- New output files.
- Session manifest changes.
- Rich report generation.
- Persistent output history.
- Explaining every artifact in the session directory.
- Changing replay generation or master-writing behavior.
