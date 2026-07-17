# Public User Guide Design

## Goal

Give a future public user one clear place to learn what LiveAstro Studio does, how to run a normal session, how OBS fits in, what files are produced, and where the product boundary sits.

## Audience

The guide assumes the reader knows basic astrophotography terms such as sub-exposure, FITS, mount, camera, and live stacking, but has not used LiveAstro Studio before.

## Documentation Shape

- `README.md` is the front door: concise pitch, supported workflows, quick start, requirements, and a link to the full guide.
- `docs/user-guide.md` is the full public guide: product model, workflows, normal-night steps, OBS setup, outputs, reseed, troubleshooting, and boundaries.
- `Sources/LiveAstroStudio/Resources/Help.md` is the in-app field reference: shorter, task-oriented, and aligned with the same public story.

## Product Story

LiveAstro Studio is not camera-control software. Seestar, ASIAIR, NINA, Siril, or another capture/live-stacking tool still gets images off the camera. LiveAstro watches the files those tools produce, stacks or displays them, shows an OBS-friendly broadcast window, records session snapshots, and renders a replay when the session ends.

## Tone

Public, practical, and confidence-building. Avoid internal review language, implementation-history references, and private rig assumptions.

