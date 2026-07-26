# Start Workflow Chooser Design

## Goal

Make the app's first action obvious to a public/beta user who does not already
know LiveAstro's internal terms. The current Setup tab exposes the correct
controls, but it leads with implementation language: watch folder, source mode,
prefix, and import subs. The new surface should answer the user's real question:
"What kind of session am I starting?"

This is a product-language and navigation slice. It does not change the stacking
core, OBS behavior, session persistence, or release packaging.

## Approach

Add a `Start Workflow` section near the top of `ControlView`, before the
existing `Watch Folder` section. The existing advanced controls remain below it.
This keeps the app familiar and low-risk while giving new users a clear entry
point.

The chooser presents plain-language actions:

- `Live from Seestar`
- `Live from ASIAIR`
- `Live from Folder / NINA`
- `Watch Siril / External Stacker`
- `Stack Previous Shoot`
- `Try Demo` as a visible future affordance, disabled and clearly marked
  "coming soon".

Each action includes one short explanatory sentence. The copy should name what
the app expects from the user: a mounted Seestar, an ASIAIR Autorun/Light folder,
a folder where NINA or another capture app writes FITS files, Siril's live stack
output folder, or a folder of existing FITS light frames.

## Behavior

The chooser uses existing app paths:

- `Live from Seestar` calls `model.liveSource.startSeestarLive()`.
- `Live from ASIAIR` calls `model.liveSource.startASIAIRLive()`.
- `Live from Folder / NINA` opens the existing live watch-folder picker and
  chooses native-stacking defaults.
- `Watch Siril / External Stacker` opens the existing live watch-folder picker
  and chooses stacker-output defaults.
- `Stack Previous Shoot` opens the existing import picker.
- `Try Demo` does not start work in this slice. It is disabled with copy that
  says it is planned.

Existing footer actions remain for now, but their labels should align with the
new public wording:

- `Choose Folder…` becomes `Live from Folder / NINA…`.
- `Import Subs…` becomes `Stack Previous Shoot…`.

## Component Shape

Keep the first pass small and local:

- Add a private `WorkflowActionRow` or equivalent helper view inside
  `ControlView`.
- Add small helper methods in `ControlView` if needed to configure source mode
  before invoking the existing folder picker.
- Avoid introducing a new controller or persisted workflow enum in this slice.

The intent is discoverability, not architecture expansion.

## State and Disabled Rules

The chooser should obey the same safety rules as the existing footer buttons:

- Disable live-start actions while a session is running, an import is running,
  or auto-detection is already in progress.
- Disable offline stack while a session is running or an import is running.
- Disable source-mode-changing actions while a session/import is active.

If an action only opens a picker, it should still be disabled when choosing a new
source would be unsafe.

## Error Handling

No new error model is needed. Actions use the existing controller paths, which
already log and present errors for failed detection, missing folders, or import
failures.

The only new copy requirement is clarity:

- NINA is not a special integration; it is the folder-watching path.
- Siril/external stackers are stacker-output watching, not native sub stacking.
- Previous-shoot stacking is offline; it does not need a live camera or OBS.

## Testing and Verification

Because this slice is primarily SwiftUI composition and label routing, the main
gate is compilation plus targeted checks:

1. Run `swift build`.
2. Run focused tests that cover settings/source-mode behavior if implementation
   touches model defaults.
3. Run `git diff --check`.

A full `swift test` is not required for this UI-only slice unless implementation
touches controller, pipeline, watcher, importer, OBS, or persistence behavior.

Manual smoke after build:

- The Setup tab shows the new `Start Workflow` section above `Watch Folder`.
- The row labels use public wording.
- Existing advanced controls remain available below.
- Footer labels match the chooser wording.

## Out of Scope

- A multi-step wizard.
- A new onboarding window.
- A real demo-data playback mode.
- New acquisition integrations.
- NINA-specific API support.
- Changes to stacking, calibration, watcher, OBS, or replay behavior.
