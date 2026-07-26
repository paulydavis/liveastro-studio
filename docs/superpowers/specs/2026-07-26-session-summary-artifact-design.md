# Session summary artifact design

## Goal

Every completed session folder should contain a small human-readable summary file that tells a user what happened without opening `manifest.json` or digging through logs.

This is the first slice toward a richer previous-shoot quality workflow. It deliberately avoids a new UI table or per-sub quality report for now.

## Output

Write `session-summary.md` beside `manifest.json` at session finalization.

The summary should include:

- session id and target
- start/end time
- profile metadata: telescope, camera, mount, filter, location, Bortle, sub exposure
- snapshot count
- finalization facts when present: master outcome, current-stack frame count, session accepted/rejected counts
- derived current-stack integration when `stack_frame_count` exists
- output filenames users should expect to inspect: `manifest.json`, `session-summary.md`, `master.fit`, `replay.mp4`, `latest.png`

## Reliability rule

The summary is auxiliary. Manifest/master correctness must remain the authority.

`endSession()` may write `session-summary.md` after the ended manifest is durably persisted and in-memory state is updated. If the summary write fails, it must not roll back or poison the finalization path.

## Formatting

Use plain Markdown, stable labels, and no machine-only jargon. Dates can use ISO-like display through Foundation; exact localization is not part of the contract.

## Tests

- Unit-test the markdown renderer directly for stable user-facing labels.
- Integration-test that a normally ended `SessionManager` writes `session-summary.md`.
- Keep write-then-commit tests unchanged: failed manifest persistence must still leave the manager running/idle exactly as before.
