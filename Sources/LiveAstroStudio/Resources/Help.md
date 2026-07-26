# LiveAstro Studio Help

LiveAstro Studio watches incoming astrophotography files, builds or displays a live stack, shows an OBS-friendly broadcast window, and writes a replay when the session ends.

It does not control your camera or mount. Use Seestar, ASIAIR, NINA, Siril, or another acquisition tool to get images off the camera. LiveAstro begins when those files appear in a folder it can read.

---

## Quick Start

1. Start your capture or live-stacking workflow.
2. Choose a source in LiveAstro:
   - **Start Seestar** for a mounted Seestar share
   - **Start ASIAIR** for a mounted ASIAIR share
   - **Choose Folder…** for NINA or any incoming raw-sub folder
   - **Stacker output folder** for Siril or another external stacker
   - **Stack Previous Shoot…** for an existing folder of captured subs
3. Fill in the session profile fields you want saved with the session.
4. Start the session.
5. Click **Detach** to open the broadcast window for OBS.
6. End the session when finished. LiveAstro writes the replay and session record under `~/Documents/LiveAstro/`.

---

## Source Modes

| Mode | Use it when |
|------|-------------|
| **Start Seestar** | A Seestar SMB share is mounted and writing raw FITS subs. |
| **Start ASIAIR** | An ASIAIR network share is mounted and writing light frames. |
| **Choose Folder…** | NINA or another capture app writes incoming raw subs to a folder you choose. |
| **Stacker output folder** | Siril or another stacker writes `live_stack.fit` or image revisions. |
| **Stack Previous Shoot…** | You already have a folder of subs and want a stack/replay afterward. |

Live sessions are session-scoped. Files already sitting in a folder before the source is armed are not replayed as new live frames.

---

## Try Without a Telescope

Click **Try Demo** in the Start Workflow section. LiveAstro creates a local demo input folder, starts a sample stack stream, and watches it like an external stacker output.

If you are running from the repository and want the Terminal fallback:

```bash
mkdir -p /tmp/liveastro-demo-stack
swift run demo-stack /tmp/liveastro-demo-stack --interval 3 --count 30
```

Then choose **Stacker output folder** in LiveAstro and select `/tmp/liveastro-demo-stack`.

This checks folder watching, display updates, the broadcast window, snapshots, and replay generation. It does not test camera acquisition, real calibration quality, real star registration from your optics, or network-share behavior.

---

## OBS and Go Live

LiveAstro broadcasts through OBS Studio.

1. In OBS, enable **Tools → WebSocket Server Settings**.
2. In LiveAstro, enter the OBS host, port, and password.
3. Click **Connect** to test the connection.
4. Click **Go Live** when you are ready to start streaming.

Broadcasting is deliberate:

- **Start Session** never starts the stream by itself.
- **Go Live** starts OBS streaming.
- **End Broadcast** stops OBS streaming without ending the astronomy session.
- **End Session** finishes the session and replay first, then stops OBS if LiveAstro started the broadcast.
- Quitting LiveAstro does not intentionally stop OBS; this avoids killing a stream because of an app crash or accidental quit.

If LiveAstro says **OBS may still be live**, check OBS directly. The app could not confirm that streaming or recording stopped.

---

## Scene Automation

With OBS connected, choose a **Stack scene** and a **Scope scene** to let LiveAstro switch scenes when stacking stalls.

- When frames stop arriving, LiveAstro can switch to the scope scene.
- When frames resume, it switches back to the stack scene.
- Manual scene changes in OBS are treated as operator overrides.

---

## Display Adjustments

Display controls are non-destructive. They change the live view and broadcast window, not the saved linear master.

- **Black point** darkens the background.
- **Stretch strength** brightens faint detail.
- **Saturation** changes color intensity.
- **Neutralize background** removes broad color casts.
- **Background extraction** reduces smooth gradients from light pollution or moonlight.

If your target fills most of the frame, use background extraction gently so it does not over-flatten the display.

---

## Calibration

Calibration applies to native raw-sub stacking and import workflows.

- **Dark** subtracts thermal signal.
- **Flat** corrects dust and vignetting.
- **Bias / dark-flat** removes camera readout offset, mainly so flats can be applied cleanly.

You can use existing master calibration files or build masters from folders of calibration frames. Leave a calibration row empty to skip it.

Darks are helpful for many cameras and conditions, but they are not required for every stack. For modern cooled cameras with dithered subs and Winsorized sigma clipping, compare your own data with and without darks if the result looks cleaner one way. LiveAstro does not perform dithering; Seestar, ASIAIR, NINA/PHD2, or another capture tool must do that upstream.

Bias or dark-flat frames mostly matter when you use flats. With many CMOS astro cameras, matched dark-flats are often preferred over very short bias frames. If you are stacking lights only and skipping flats, bias/dark-flat usually does little by itself.

---

## Reseed Reference

Use **Reseed Reference** when the current alignment reference is no longer a good match for new frames.

Common reasons:

- meridian flip
- long gap
- fog or clouds clearing
- major framing change
- repeated registration failures

Reseed keeps the session history and snapshots, but resets the current stack. The next accepted frame becomes the new reference.

---

## Session Outputs

Sessions are written under `~/Documents/LiveAstro/`. This folder contains LiveAstro's own session record, generated images, replay, and native master when available. It does not replace your original capture folder; Seestar, ASIAIR, NINA, Siril, or your capture app still owns the source files.

Common outputs:

- `replay.mp4` — stack-evolution video
- `master.fit` — native-stacking master, when LiveAstro owns the stack and a current stack exists
- `latest.png` — stable monitor image for the newest saved snapshot
- `session-summary.md` — readable target, timing, frame-count, and output summary
- `frame-summary.csv` — per-snapshot source, exposure, and image-stat table for spreadsheets
- snapshots — frames captured throughout the session
- manifest metadata — profile, timing, and output facts

External-stacker sessions may not write `master.fit`; the external stacker owns that file.

Useful buttons:

- **Open Sessions Folder** opens the output root in Finder.
- **Open Latest Image** opens `latest.png` for the latest session.
- **Reveal latest.png** selects the monitor image in Finder.
- **Refresh Sizes** checks how much disk space the output root and latest session currently use.
- **Copy Support Bundle** copies app version, session health, output paths, output footprint, and recent log lines.
- **Copy Log Tail** copies only the recent log.

`latest.png` is for quick viewing, OBS/web overlays, and support checks. Use `master.fit` for serious post-processing when a native master is available.

---

## Troubleshooting

**No Seestar or ASIAIR share found**
Mount the device's SMB share in Finder first, then try again.

**Folder selected, but nothing stacks**
Confirm new `.fit` or `.fits` files are appearing after the session starts.

**Refresh Sizes shows a large output footprint**
That number is informational. LiveAstro will not delete anything when you click **Refresh Sizes**.

**Seestar stacks do not start**
Confirm the Seestar is writing raw FITS subs, not JPEG-only live-view images.

**Siril files are rejected**
In Siril's command line, run `cd /path/to/watch/folder` before starting livestacking.

**OBS will not connect**
Check that OBS is running, WebSocket Server is enabled, the port matches, and the password is current.

**Replay skips cloudy frames**
The replay generator can drop frames whose background brightness is far outside the recent baseline, while still keeping the first and last frames.
