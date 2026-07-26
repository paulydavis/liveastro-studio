# Demo Stack Command Design

## Goal

Make the no-sky demo path feel public-friendly by adding a `demo-stack` command while preserving the existing `fakesiril` development command.

## Scope

- Add a new SwiftPM executable target named `demo-stack`.
- Keep `fakesiril` working for historical/dev scripts.
- Move the shared implementation into `LiveAstroCore` so both executables use the same code path.
- Update public-facing docs to use `swift run demo-stack ...`.
- Leave history docs and old validation logs alone.

## User-facing behavior

Both commands accept:

```bash
swift run demo-stack <folder> [--interval seconds] [--count n]
swift run fakesiril <folder> [--interval seconds] [--count n]
```

`demo-stack` prints `demo-stack: stack update ...` and writes `live_stack.fit` updates into the chosen folder. It remains a Siril-style external stacker simulator internally, but public docs call it the "demo stack generator."

## Non-goals

- No in-app Try Demo implementation.
- No change to generated FITS content.
- No change to watcher, stacking, replay, or session behavior.

## Verification

- Red: `swift run demo-stack` fails before the target exists.
- Green: `swift run demo-stack /tmp/liveastro-demo-stack-smoke --interval 0 --count 1` writes `/tmp/liveastro-demo-stack-smoke/live_stack.fit`.
- Regression: `swift run fakesiril /tmp/liveastro-fakesiril-smoke --interval 0 --count 1` still writes `/tmp/liveastro-fakesiril-smoke/live_stack.fit`.
- `swift build`
- `git diff --check`

