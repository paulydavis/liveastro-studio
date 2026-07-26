# User Guide Output Actions Design

## Goal

Bring the public user guide's **Session Outputs** section up to date with the app's current output actions.

## Scope

Update `docs/user-guide.md` only. The guide should explain:

- `~/Documents/LiveAstro/` contains LiveAstro-generated session outputs, not the upstream capture originals;
- `latest.png` is the stable newest-snapshot monitor image;
- `Open Replay`, `Reveal Replay`, `Open Session Folder`, `Reveal master.fit`, `Open Latest Image`, `Reveal latest.png`, `Refresh Sizes`, `Copy Summary`, `Copy Support Bundle`, and `Copy Log Tail`;
- `Refresh Sizes` is informational and does not delete files.

## Non-goals

- No Swift source changes.
- No bundled Help changes in this slice.
- No cleanup/delete workflow.
- No screenshots or GIFs.

## Verification

- `swift build`
- `git diff --check`

