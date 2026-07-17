# LiveAstro Studio

LiveAstro Studio turns an astrophotography session into a polished live broadcast and an automatic replay.

It watches the files your capture or live-stacking software creates, stacks or displays them live, shows a clean OBS-friendly broadcast window, records session snapshots, and renders a stack-evolution replay when the session ends.

LiveAstro is not camera-control software. Seestar, ASIAIR, NINA, Siril, or another acquisition tool still gets images off the camera. LiveAstro starts at the folder boundary: when new FITS files or stack images appear on disk, it turns them into a live stack, broadcast view, session record, and replay.

## Requirements

- macOS 14 or later
- A source folder that receives incoming `.fit` / `.fits` files, or an external stacker output folder
- [OBS Studio](https://obsproject.com) for streaming
- Optional: [Siril](https://siril.org), if you want Siril to do the live stacking and LiveAstro to watch Siril's output

## Supported Workflows

- **Seestar live** — mount the Seestar SMB share, click **Start Seestar**, and LiveAstro stacks new raw subs as they arrive.
- **ASIAIR live** — mount the ASIAIR network share, click **Start ASIAIR**, and LiveAstro watches the active light-frame folder.
- **Generic folder live** — choose any folder where a capture app writes incoming raw subs.
- **Siril / external stacker output** — watch `live_stack.fit` or numbered stack revisions from Siril or another stacker.
- **Import existing subs** — stack a folder of already-captured raw subs and produce a replay plus native master.

See the full [User Guide](docs/user-guide.md) for setup, OBS streaming, session outputs, reseeding, and troubleshooting.

## Open LiveAstro

If you have a packaged build, open `LiveAstroStudio.app`.

To run from source:

```bash
swift run LiveAstroStudio
```

## Quick Start

1. Start or prepare your capture system.
   - Seestar, ASIAIR, NINA, Siril, or another tool should be writing files into a folder LiveAstro can read.
2. In LiveAstro, choose a source:
   - **Start Seestar**
   - **Start ASIAIR**
   - **Choose Folder…**
   - **Stacker output folder**
   - **Import Subs…**
3. Fill in the session profile fields you care about: target, telescope, camera, filter, location, and sub-exposure length.
4. Click **Start Session** for live workflows, or choose a folder for **Import Subs…**.
5. Click **Detach** to open the broadcast window.
6. In OBS, add a Window Capture for the LiveAstro broadcast window.
7. Click **Go Live** if OBS automation is configured, or start streaming manually in OBS.
8. Click **End Session** when finished. LiveAstro writes the session folder under `~/Documents/LiveAstro/`.

## OBS Automation

LiveAstro can control OBS through the OBS WebSocket server.

One-time setup:

1. In OBS, open **Tools → WebSocket Server Settings**.
2. Enable the WebSocket server.
3. Use the default port `4455`, or enter your chosen port in LiveAstro.
4. If authentication is enabled, copy the OBS WebSocket password into LiveAstro.

LiveAstro treats broadcasting as deliberate:

- **Start Session** starts the astronomy session, not the stream.
- **Go Live** starts the OBS stream.
- **End Broadcast** stops OBS without ending the astronomy session.
- **End Session** finishes the astronomy session, renders the replay, then stops OBS if LiveAstro owns the broadcast.
- Quitting the app does not intentionally stop an active OBS stream.

## Session Outputs

Session folders are written under `~/Documents/LiveAstro/`.

Depending on the workflow, a session may contain:

- `replay.mp4` — automatic stack-evolution video
- `master.fit` — linear 32-bit FITS master for native stacking sessions
- snapshots — still frames captured throughout the session
- manifest metadata — profile, timing, and output facts

External-stacker sessions do not promise a native `master.fit`; the external stacker owns that artifact.

## Demo Without a Telescope

You can simulate an updating stack folder:

```bash
mkdir -p /tmp/fakestack
swift run fakesiril /tmp/fakestack --interval 3 --count 20
```

Then point LiveAstro's stacker-output workflow at `/tmp/fakestack`.

## Development

```bash
swift test
swift build -c release
swift test -c release --filter PerformanceTests
```

Siril parity testing is optional and requires a local dataset:

```bash
LIVEASTRO_PARITY_DATASET=~/LiveAstroCorpus/siril-m8-asi2600 swift test --filter SirilParityTests
```

Design and history documents live under `docs/`.
