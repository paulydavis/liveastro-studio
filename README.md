# LiveAstro Studio

Turn a live astrophotography session into a polished livestream and an automatic
recap video — without manual video editing.

LiveAstro Studio watches your live-stacker's output (Siril `live_stack.fit`,
or PNG/JPG/TIFF), shows the latest stack in a clean 1920×1080 broadcast window
for OBS, records a snapshot on every stack update, and renders a 45-second
"stack evolution" MP4 when you end the session.

## Requirements

- macOS 14+
- [Siril](https://siril.org) (or any tool that periodically writes a stack image to a folder)
- [OBS](https://obsproject.com) for streaming

## Run

```bash
swift run LiveAstroStudio
```

1. Choose the folder Siril's livestack writes into.
2. Fill in the session profile (target, scope, camera, sub length…). For OSC cameras, enable **Neutralize background (OSC white balance)** to scale R and B channel medians to G before stretching — useful when your live-stack output looks green-dominant. The toggle is off by default and locks once a session starts.
3. The **File name starts with** field defaults to `live_stack` — this matches both
   Siril's classic in-place `live_stack.fit` and the numbered `live_stack_00001.fit`
   revisions Siril 1.4+ writes, while ignoring raw sub-exposures and `r_live_stack_*`
   registered frames that land in the same folder.
   Clear the field (or leave it blank) when pointing at a folder of arbitrary display-ready images.

> **Siril tip:** after launching Siril, run `cd /path/to/your/watch/folder` in its
> command line before starting livestacking. A freshly launched Siril otherwise
> rejects every file with "File not supported for live stacking" (stat against the
> wrong process CWD — see `docs/upstream/siril-livestack-cwd-bug.md`).
4. Open the Broadcast Window; in OBS add a **Window Capture** for "LiveAstro Broadcast".
5. Start Session. Stream from OBS as usual.
6. End Session → `~/Documents/LiveAstro/<session>/replay.mp4`. The replay cloud gate automatically drops frames whose background brightness deviates more than 50% from the recent accepted-frame baseline before keyframe selection — first and last frames are always kept, so passing clouds do not corrupt the evolution video.

## Demo without a telescope

```bash
mkdir -p /tmp/fakestack
swift run fakesiril /tmp/fakestack --interval 3 --count 20
```

Point the watch folder at `/tmp/fakestack`.

## Development

```bash
swift test   # full suite, no hardware needed
```

Design spec: `docs/superpowers/specs/2026-07-05-liveastro-studio-v1-design.md`
