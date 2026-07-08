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

## Native stacking

LiveAstro v2 can stack raw sub-exposures itself — no external live-stacker required.
There are two entry points:

**Import Subs… (batch import from acquired files)**

1. In the Control window, set the source mode to **Raw subs folder (native stacking)**.
2. Click **Import Subs…** and choose the folder containing your `.fit` files
   (the folder that your capture software writes to, e.g. `~/Documents/lights/`).
3. Fill in the session profile and click **Start Session**.
   The engine imports each file in chronological order: bilinear debayer → star
   registration → incremental mean stack.  An indeterminate spinner is shown while
   the import runs; accepted and rejected frames are listed in the session log.
   The session lands in `~/Documents/LiveAstro/<date-target>/` like any
   other session — including `replay.mp4` and `master.fit`.

**Live raw-subs (watch folder as subs arrive)**

1. Set source mode to **Raw subs folder (native stacking)**.
2. Point the watch folder at the folder your capture software writes subs into
   (Seestar SMB share, ASIAIR, or a local capture path).
3. Start Session — each new sub is stacked as it arrives.
4. Use **Reseed Reference** to discard the current reference frame and restart
   alignment from the next accepted sub (useful after a long gap, fog clearing,
   or a meridian flip that changes field rotation significantly).

**Stacker output folder (Siril / external stacker)**

This is the original v1 mode.  Set source mode to **Stacker output folder (Siril)**
and point at the folder Siril writes its `live_stack.fit` into.  All v1 behavior
is unchanged.

**master.fit output**

At the end of every native-stack session, `master.fit` is written into the session
directory alongside `replay.mp4`.  It is a 32-bit float RGB FITS file in TOP-DOWN
row order, suitable for further processing in PixInsight or Siril.

**Validation results (NGC 6888, 2026-07-07)**

120 × 20 s subs (40 min) imported headless against Paul's Siril 1000-sub master:

| Channel | LiveAstro r | Siril master baseline (16-sub prototype) | Delta |
|---------|-------------|------------------------------------------|-------|
| R       | **0.9490**  | 0.87                                     | +0.079 |
| G       | **0.9522**  | 0.94                                     | +0.012 |
| B       | **0.9466**  | 0.83                                     | +0.117 |

All 120 subs accepted, 0 rejected.  Import time: ~350 s on Apple Silicon (M-class).
Correlation measured by `Scripts/compare_to_master.py` (astroalign luminance
registration, full registered frame Pearson r).

## Demo without a telescope

```bash
mkdir -p /tmp/fakestack
swift run fakesiril /tmp/fakestack --interval 3 --count 20
```

Point the watch folder at `/tmp/fakestack`.

## Development

```bash
swift test                                          # full suite, no hardware needed
swift test -c release --filter PerformanceTests     # 26 MP perf gate (< 10 s per frame)
```

Design specs:
- v1: `docs/superpowers/specs/2026-07-05-liveastro-studio-v1-design.md`
- v2 native stacking: `docs/superpowers/specs/2026-07-07-liveastro-v2-native-stacking-design.md`

Validation comparison script: `Scripts/compare_to_master.py`
