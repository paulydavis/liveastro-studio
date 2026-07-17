# Post-tag Tiny Cleanups — Design

## Goal

Address two non-blocking post-`v3.0.0` review findings without changing the release contract or reopening large subsystems.

## Scope

1. Make reseed refusal after a failed `end()` honest during the retry window.
2. Make derived integration captions internally consistent after rounding.

## Design

`SessionPipeline` keeps the existing sticky finalization barrier after a running `end()` attempt claims it. A failed finalization still leaves the session running and `end()` retryable, but reseed remains refused. Instead of reporting the generic `.finalizationInProgress`, `reseed()` returns a distinct `.finalizationRetryPending` once an `end()` attempt has failed after claiming finalization. AppModel logs a retry-specific message.

`IntegrationFormat.caption(seconds:subSeconds:)` derives the rounded frame count first, then displays integration time as `roundedFrames × subSeconds`. This keeps the badge coherent: a 90-second estimate at 60-second subs becomes `2m · 2 × 60s`, not `1m 30s · 2 × 60s`. The explicit `caption(seconds:frames:subSeconds:)` overload remains unchanged; callers passing both values own their consistency.

## Tests

- A failed `end()` after claiming finalization returns `.finalizationRetryPending` from `reseed()`.
- Finite import finalization failure also returns `.finalizationRetryPending`, outranking `.unavailableDuringImport`.
- Derived integration captions use rounded frame count for both displayed time and frame count.
