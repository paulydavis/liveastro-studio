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
2. Fill in the session profile (target, scope, camera, sub length…).
3. Open the Broadcast Window; in OBS add a **Window Capture** for "LiveAstro Broadcast".
4. Start Session. Stream from OBS as usual.
5. End Session → `~/Documents/LiveAstro/<session>/replay.mp4`.

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
