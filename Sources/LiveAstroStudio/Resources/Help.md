# LiveAstro Studio Help

LiveAstro Studio watches incoming astrophotography files, builds or displays a live stack, shows an OBS-friendly broadcast window, and writes a replay when the session ends.

It does not control your camera or mount. Use Seestar, ASIAIR, NINA, Siril, or another acquisition tool to get images off the camera. LiveAstro begins when those files appear in a folder it can read.

---

## Quick Start

1. Start your capture or live-stacking workflow.
2. Choose a source in LiveAstro:
   - **Start Seestar** for a mounted Seestar share
   - **Start ASIAIR** for a mounted ASIAIR share
   - **Choose Folder…** for any incoming raw-sub folder
   - **Stacker output folder** for Siril or another external stacker
   - **Import Subs…** for an existing folder of captured subs
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
| **Choose Folder…** | A capture app writes incoming raw subs to a folder you choose. |
| **Stacker output folder** | Siril or another stacker writes `live_stack.fit` or image revisions. |
| **Import Subs…** | You already have a folder of subs and want a stack/replay afterward. |

Live sessions are session-scoped. Files already sitting in a folder before the source is armed are not replayed as new live frames.

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
- **Bias** cleans flats before they are applied.

You can use existing master calibration files or build masters from folders of calibration frames. Leave a calibration row empty to skip it.

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

Sessions are written under `~/Documents/LiveAstro/`.

Common outputs:

- `replay.mp4` — stack-evolution video
- `master.fit` — native-stacking master, when LiveAstro owns the stack and a current stack exists
- snapshots — frames captured throughout the session
- manifest metadata — profile, timing, and output facts

External-stacker sessions may not write `master.fit`; the external stacker owns that file.

---

## Troubleshooting

**No Seestar or ASIAIR share found**
Mount the device's SMB share in Finder first, then try again.

**Folder selected, but nothing stacks**
Confirm new `.fit` or `.fits` files are appearing after the session starts.

**Seestar stacks do not start**
Confirm the Seestar is writing raw FITS subs, not JPEG-only live-view images.

**Siril files are rejected**
In Siril's command line, run `cd /path/to/watch/folder` before starting livestacking.

**OBS will not connect**
Check that OBS is running, WebSocket Server is enabled, the port matches, and the password is current.

**Replay skips cloudy frames**
The replay generator can drop frames whose background brightness is far outside the recent baseline, while still keeping the first and last frames.
