# Changelog

## Unreleased

- One-button Go Live: pre-flight status panel, OBS WebSocket auto-discovery (no password paste), automatic capture-source provisioning/repair (additive only), stream-key presence check.

## 3.0.4 — 2026-07-26

Current recommended tester build.

- Fixed the packaged app layout so SwiftPM resources live under `Contents/Resources`, matching `Bundle.module` lookup. This prevents a packaged-app crash when bundled resources such as Help are opened.
- Added release-script guards so future packages fail if the resource bundle is missing or placed under `Contents/MacOS`.
- Published `LiveAstroStudio-3.0.4.dmg` as a Developer ID signed, notarized, stapled, Gatekeeper-accepted prerelease.

## 3.0.3 — 2026-07-26

Superseded by `3.0.4`.

- Fixed a watcher ordering edge where the same numeric stack revision with different zero padding, such as `_7` and `_007`, could reset the blocker write-off clock.
- Kept `3.0.2`'s completed-session report artifacts and output shortcuts.
- Published `LiveAstroStudio-3.0.3.dmg` as a Developer ID signed, notarized, stapled, Gatekeeper-accepted prerelease.

## 3.0.2 — 2026-07-26

Superseded by `3.0.3`.

- Added `session-summary.md` to completed session folders.
- Added `frame-summary.csv` with per-snapshot source, exposure, and image statistics.
- Added **Open Summary** and **Open Frame CSV** buttons in Session Outputs.
- Added the new artifact paths to **Copy Summary** and **Copy Support Bundle**.
- Fixed the release packaging script to submit the DMG carrier to Apple notarization.

## 3.0.1 — 2026-07-26

Superseded by `3.0.2`.

- Added public user guide, beta quickstart, beta checklist, distribution guide, and roadmap notes.
- Added repeatable Developer ID / notarization packaging.
- Clarified live-folder workflow wording for Seestar, ASIAIR, NINA/generic folder, Siril/external stacker, and previous-shoot stacking.
- Clarified calibration guidance, including darks, flats, bias frames, and dark-flats.

## 3.0.0 — 2026-07-17

Core stabilization release.

- Completed the stabilization arc that made unattended-session failures lose at most frames, not the whole session.
- Added Siril parity benchmark support gated on a local, non-redistributed corpus.
- Preserved the macOS-native app position while strengthening live watching, replay, OBS lifecycle, and session finalization behavior.
