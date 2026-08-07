# Changelog

## Unreleased

- Relicensed under the **MIT License**. Replaced the demosaic path with a
  clean-room implementation of Malvar–He–Cutler (ICASSP 2004), removing the
  previous GPL-derived RCD code so the project carries no copyleft dependency.
  The high-quality demosaic is now "Malvar"; saved settings that named "rcd"
  load unchanged.


## 3.1.0 — 2026-08-06

Three pillars since 3.0.4, validated on a real-sky Seestar S30 session (IC 1396,
339 subs, 0 rejected) that streamed live to YouTube.

**One-button Go Live (OBS broadcast pre-flight).** A single Go Live now launches
OBS if needed, reads its WebSocket credentials from OBS's own config (no password
paste), verifies and repairs the broadcast-window capture source in your chosen
scene (additive only — your camera/scope/other sources are never touched), checks
the stream service, and starts the stream. A five-link status panel shows each step
going green, with a reason and fix for any that fail. Recognizes OAuth
account-linked YouTube/Twitch/Restream as well as pasted stream keys. Help gains
broadcast-setup recipes (camera PiP, AirPlay phone mirror, NINA, multi-scene).

**Native noise reduction.** A classic, deterministic two-stage denoiser (chroma
mottle suppression + edge-preserving luma smoothing) in the live-view display path,
plus a **Native NR** option on the master post-process picker. One Denoise slider;
default off; `master.fit` is never mutated.

**Watcher segment clock model.** The stack-file watcher's blocker write-off now
uses per-owner accrual segments, resolving the starvation/attribution family that
nine review rounds could not close with single-scalar guards.

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
