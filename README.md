# LiveAstro Studio

LiveAstro Studio turns an astrophotography session into a polished live broadcast and an automatic replay.

It watches the files your capture or live-stacking software creates, stacks or displays them live, shows a clean OBS-friendly broadcast window, records session snapshots, and renders a stack-evolution replay when the session ends.

LiveAstro is not camera-control software. Seestar, ASIAIR, NINA, Siril, or another acquisition tool still gets images off the camera and writes files to disk. LiveAstro starts at that folder boundary: it watches a folder that another program or device is already writing into, then turns those files into a live stack, broadcast view, session record, and replay.

## Requirements

- macOS 14 or later
- A folder that is already receiving files from your capture system, or a folder of existing files from a previous shoot
  - raw `.fit` / `.fits` light frames for native stacking
  - external stack images such as Siril's `live_stack.fit` for stacker-output mode
- [OBS Studio](https://obsproject.com) for streaming
- Optional: [Siril](https://siril.org), if you want Siril to do the live stacking and LiveAstro to watch Siril's output

## Supported Workflows

- **Seestar live** — mount the Seestar SMB share, click **Start Seestar**, and LiveAstro stacks new raw subs as they arrive.
- **ASIAIR live** — mount the ASIAIR network share, click **Start ASIAIR**, and LiveAstro watches the active light-frame folder.
- **Generic folder live** — choose a folder where another capture app is actively writing new raw subs. This is the NINA path: point **Choose Folder…** at NINA's image output folder.
- **Siril / external stacker output** — choose the folder where Siril or another stacker writes `live_stack.fit` or numbered stack revisions.
- **Stack previous shoot** — choose a folder of already-captured raw subs from a previous shoot, then stack them offline and produce a replay plus native master.

See the full [User Guide](docs/user-guide.md) for setup, OBS streaming, session outputs, reseeding, and troubleshooting.

Trying LiveAstro before you have clear skies? Start with the [Beta Quickstart](docs/beta-quickstart.md), then use the [Beta Tester Checklist](docs/beta-checklist.md) to record what worked.

## Open LiveAstro

For the current tester build, download `LiveAstroStudio-3.0.4.dmg` from the [LiveAstro Studio 3.0.4 release](https://github.com/paulydavis/liveastro-studio/releases/tag/v3.0.4), open the DMG, drag LiveAstro Studio to Applications, then launch it.

To run from source:

```bash
swift run LiveAstroStudio
```

## Quick Start

1. Start or prepare your capture system.
   - For live use, Seestar, ASIAIR, NINA, Siril, or another tool should be writing new files into a folder LiveAstro can read.
   - For offline use, choose a folder of existing FITS light frames from a previous shoot.
2. In LiveAstro, choose a source:
   - **Start Seestar**
   - **Start ASIAIR**
   - **Choose Folder…** for NINA or any other capture app that writes FITS subs to a folder
   - **Stacker output folder**
   - **Stack Previous Shoot…**
3. Fill in the session profile fields you care about: target, telescope, camera, filter, location, and sub-exposure length.
4. Click **Start Session** for live workflows, or use **Stack Previous Shoot…** to stack an existing folder.
5. Click **Detach** to open the broadcast window.
6. In OBS, add a Window Capture for the LiveAstro broadcast window.
7. Click **Go Live** if OBS automation is configured, or start streaming manually in OBS.
8. Click **End Session** when finished. LiveAstro writes the session folder under `~/Documents/LiveAstro/`.

With live trail rejection enabled, the detached broadcast window shows the current clean
master when one is available. The embedded operator pane shows the online stack so you can
inspect incoming data. Each view's integration caption reflects its own image depth.
The broadcast window refreshes when a clean master publishes or becomes invalid, even
between subs. `latest.png` updates when a snapshot is saved; it is not the source of the
Window Capture workflow above.

Committed display images are processed at a maximum long edge of 2560 pixels in native
live, offline import, and external-stacker modes, including Apply and final display
refreshes. This reduces display-render cost but can change fine texture compared with
processing at full resolution: DBE, stretch statistics, and denoise operate on the reduced
image. Snapshots, `latest.png`, and replay inherit that appearance. The native accumulator,
archival `master.fit`, and linear statistics retain their full-resolution data; clean-master
selection is unchanged. Images smaller than the cap are not enlarged.

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

Session folders are written under `~/Documents/LiveAstro/`. These are LiveAstro's own output copies and generated files; your original capture files stay where Seestar, ASIAIR, NINA, Siril, or your other upstream tool wrote them.

Depending on the workflow, a session may contain:

- `replay.mp4` — automatic stack-evolution video
- `master.fit` — linear 32-bit FITS master for native stacking sessions
- `latest.png` — a stable monitor image that always points at the newest saved snapshot
- `session-summary.md` — human-readable target, timing, frame-count, and output summary
- `frame-summary.csv` — spreadsheet-friendly per-snapshot source, exposure, and image-stat table
- snapshots — still frames captured throughout the session
- manifest metadata — profile, timing, and output facts

External-stacker sessions do not promise a native `master.fit`; the external stacker owns that artifact.

The app's **Session Outputs** area provides quick actions for the files you are most likely to need:

- **Open Sessions Folder** opens the output root.
- **Open Summary** opens `session-summary.md` for the latest session.
- **Open Frame CSV** opens `frame-summary.csv` for spreadsheet review.
- **Open Latest Image** opens `latest.png` for the most recent session.
- **Reveal latest.png** shows that monitor image in Finder.
- **Refresh Sizes** calculates the current output footprint for the root folder and latest session. It is informational only; it does not delete, prune, or move files.
- **Copy Support Bundle** copies a compact text report with app version, session health, output paths, output footprint, and recent log lines.
- **Copy Log Tail** copies only the visible recent log lines.

## Calibration Philosophy

Calibration frames are optional. LiveAstro can use dark, flat, and
bias/dark-flat masters when you provide them, but missing calibration frames
are not an error.

Darks are often helpful, especially with uncooled cameras, long exposures, amp
glow, warm sensors, or non-dithered data. With a modern cooled camera, dithered
subs, and Winsorized sigma clipping, darks may be less important; try both on
your own data if you are unsure. LiveAstro does not control dithering itself —
that happens in Seestar, ASIAIR, NINA/PHD2, or your capture software.

Bias or dark-flat frames are mainly useful when you are using flats: they remove
the camera readout offset from the flat before the flat is applied. With many
CMOS astro cameras, matched dark-flats are often preferred over very short bias
frames. If you are stacking lights only and skipping flats, bias/dark-flat
frames usually do little on their own.

## Try It Without a Telescope

Click **Try Demo** in the Start Workflow section. LiveAstro creates a local demo input folder, writes a changing sample stack, starts watching it, and lets you test the live view, broadcast window, snapshots, and replay without clear skies.

If you are running from source and want the Terminal-driven fallback, the demo stack generator is still available:

```bash
mkdir -p /tmp/liveastro-demo-stack
swift run demo-stack /tmp/liveastro-demo-stack --interval 3 --count 20
```

Then point LiveAstro's stacker-output workflow at `/tmp/liveastro-demo-stack`.

For the fuller no-sky walkthrough, see [docs/beta-quickstart.md](docs/beta-quickstart.md).

## Development

Before merging, run the whole gate as one command:

```bash
Scripts/preflight.sh          # debug build + RELEASE build + full test suite
```

The release build matters and is easy to skip: `swift test` and `swift build` are both DEBUG, and
`-c release` is otherwise compiled only inside the packaging scripts. A release-configuration
warning shipped in v3.6.2 for exactly that reason — nothing in the development loop ever compiled
that configuration, so a release-only error would have surfaced at packaging time rather than at
review.

The release step compiles into a throwaway scratch directory (so it cannot report "clean" by
reusing existing output) and builds with `-Xswiftc -warnings-as-errors`. **A new Swift compiler
warning in the release build fails the gate.** The test step also uses
`swift test -Xswiftc -warnings-as-errors`, so Swift compiler warnings in test targets
and their dependencies fail the gate before tests run. The standalone debug build
still counts warnings rather than enforcing them. Enforcement is by the compiler rather than by matching the build log,
which would depend on message formatting and could not tell a real warning from the word "warning"
in a path. Warnings from SwiftPM, the linker or other tools are outside that flag's reach; the gate
reports those from both the release and test logs without failing. The test step
prints its detailed log path, including when compilation fails. If a
warning is genuinely acceptable, fix it or silence it deliberately at the source — do not weaken
the gate.

The small gate-contract tests exercise real Swift compilation and test execution
without running the app suite: `python3 Scripts/tests/test_preflight.py`.

The individual steps, if you want them separately:

```bash
swift test
swift build -c release
swift test -c release --filter PerformanceTests
```

Siril parity testing is optional and requires a local dataset:

```bash
LIVEASTRO_PARITY_DATASET=~/LiveAstroCorpus/siril-m8-asi2600 swift test --filter SirilParityTests
```

Design, history, and roadmap documents live under `docs/`.

Release history is summarized in [CHANGELOG.md](CHANGELOG.md).

Release packaging and notarization notes live in [docs/distribution.md](docs/distribution.md).

Near-term product direction is tracked in [docs/roadmap.md](docs/roadmap.md).

## License

LiveAstro Studio is released under the [MIT License](LICENSE). It vendors no
third-party source and has no runtime dependencies beyond Apple's SDKs;
algorithms implemented from published literature are credited in [NOTICE.md](NOTICE.md).
