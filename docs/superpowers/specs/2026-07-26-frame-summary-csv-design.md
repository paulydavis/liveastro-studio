# Frame summary CSV design

## Goal

Finished sessions should expose the per-snapshot facts already stored in `manifest.json` in a spreadsheet-friendly form.

This supports later previous-shoot review and "sub quality / exposure per sub" work without building a new UI first.

## Output

Write `frame-summary.csv` beside `manifest.json` and `session-summary.md` at session finalization.

Rows come from `SessionManifest.snapshots`. Columns:

- `index`
- `timestamp`
- `source_file`
- `snapshot_file`
- `estimated_integration_seconds`
- `sub_exposure_seconds`
- `width`
- `height`
- `mean`
- `median`
- `stddev`

## Semantics

- The CSV is an auxiliary artifact, like `session-summary.md`.
- Manifest/master finalization remains authoritative.
- A CSV write failure must not roll back or poison a successfully ended session.
- Empty sessions still write a header-only CSV, which is useful evidence that no snapshots were recorded.

## Tests

- Red-first integration test: ending a session with a snapshot writes a CSV containing the expected header and row.
- Empty-session test: ending with no snapshots writes a header-only CSV.
- Re-run `SessionManagerTests`, in-app help markdown tests if output docs change, `swift build`, and `git diff --check`.
