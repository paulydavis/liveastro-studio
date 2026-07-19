# LiveAstro Studio User Guide

LiveAstro Studio turns an astrophotography session into a clean live broadcast and an automatic replay.

It watches the image files your capture or live-stacking software creates, stacks or displays them live, shows an OBS-friendly broadcast window, records the session as snapshots, and renders a replay when you end the session.

LiveAstro is not camera-control software. Your camera, mount, autofocus, plate solving, and capture plan still come from tools such as Seestar, ASIAIR, NINA, Siril, or another acquisition system. LiveAstro starts at the folder boundary: once new FITS files or stack images appear on disk, it turns them into a live stack, broadcast view, and session record.

## Requirements

- macOS 14 or later
- A folder that receives incoming `.fit` / `.fits` files, or a folder that receives external stack images
- OBS Studio for streaming
- Optional: Siril, if you want Siril to do the live stacking and LiveAstro to watch Siril's output

## Open LiveAstro

If you have a packaged build, open `LiveAstroStudio.app`.

To run from source:

```bash
swift run LiveAstroStudio
```

If you want to try the app without a telescope or clear skies, use the [Beta Quickstart](beta-quickstart.md). For structured tester notes, use the [Beta Tester Checklist](beta-checklist.md).

## The Big Picture

A normal session has four moving parts:

1. Your capture system gets images off the camera.
2. LiveAstro watches the folder where those images or stack outputs appear.
3. LiveAstro shows the current result in its main view and in a detached broadcast window.
4. OBS captures the broadcast window and streams it.

When the session ends, LiveAstro writes a session folder with snapshots, metadata, a replay video, and, for native stacking sessions, a linear `master.fit`.

## Choose a Workflow

### Seestar live

Use this when a Seestar is writing raw subs to its network share.

1. In Finder, mount the Seestar SMB share.
2. In LiveAstro, click **Start Seestar**.
3. LiveAstro finds the share, relays only new session frames, and begins native stacking.

If the stack never starts, check the Seestar app's live-view format. It must write raw FITS subs; JPEG-only live view does not provide the data LiveAstro needs to stack.

### ASIAIR live

Use this when an ASIAIR is writing autorun light frames to its network share.

1. In the ASIAIR app, enable the network share.
2. Mount the ASIAIR share in Finder.
3. In LiveAstro, click **Start ASIAIR**.
4. LiveAstro finds the ASIAIR light-frame folder and stacks new subs as they arrive.

### Generic folder live

Use this for NINA, local capture software, a mounted network share, or any folder that receives incoming raw subs. There is no separate NINA button because NINA already writes FITS files to a normal folder; in LiveAstro, NINA uses **Choose Folder…**.

1. Click **Choose Folder…**.
2. Select the folder where new light frames will appear, such as NINA's image output folder.
3. Start the session.

Only frames that arrive after the live source is armed are treated as live session frames. If you point LiveAstro at a folder full of old files that is no longer changing, nothing new will stack.

### Siril or external stacker output

Use this when another program is already producing a live stack image, such as Siril's `live_stack.fit`.

1. Set the source mode to **Stacker output folder**.
2. Choose the folder where the external stacker writes its stack output.
3. Leave **File name starts with** set to `live_stack` for Siril-style outputs, or clear it for arbitrary display-ready image folders.
4. Start the session.

In this mode, LiveAstro does not create a native `master.fit`; the external stacker owns the master stack. LiveAstro records snapshots and replay output from the stack images it observes.

### Import existing subs

Use this after a night of imaging when you already have a folder of subs and want LiveAstro to build a stack and replay.

1. Set the source mode to **Raw subs folder**.
2. Click **Import Subs…**.
3. Select the folder containing existing light frames.
4. LiveAstro imports them in chronological order and writes a session folder when finished.

Calibration files can be configured before import. If you cancel an import, frames already processed are preserved and the partial result is finalized honestly.

## A Normal Live Night

1. Prepare your capture system.
   - Start your Seestar, ASIAIR, NINA sequence, Siril livestack, or other acquisition workflow.
   - Confirm new files are appearing in the expected folder.

2. Choose the source in LiveAstro.
   - Use **Start Seestar**, **Start ASIAIR**, **Choose Folder…**, or **Stacker output folder**.
   - Fill in target, telescope, camera, filter, location, and sub-exposure length when available.

3. Start the session.
   - LiveAstro begins watching for new frames.
   - The main view updates as the stack develops.
   - The session record begins accumulating snapshots.

4. Open the broadcast view.
   - Click **Detach** to open the dedicated broadcast window.
   - In OBS, capture that window.

5. Go live when ready.
   - Use LiveAstro's **Go Live** controls if OBS WebSocket automation is configured.
   - Or start streaming manually in OBS.

6. Let the session run.
   - Display adjustments are non-destructive and affect only the view.
   - Native stacking sessions can use **Reseed Reference** if alignment needs a fresh reference frame.

7. End the session.
   - LiveAstro drains in-flight frames, writes final artifacts, renders the replay, then stops OBS if LiveAstro started the broadcast.
   - If OBS cannot confirm that streaming stopped, LiveAstro reports that OBS may still be live instead of pretending everything is idle.

## OBS Setup

LiveAstro streams through OBS Studio. OBS captures the LiveAstro broadcast window and sends it to YouTube or another streaming service.

### One-time OBS setup

1. In OBS, open **Tools → WebSocket Server Settings**.
2. Enable the WebSocket server.
3. Use the default port, `4455`, unless you have a reason to change it.
4. If authentication is enabled, copy the password from OBS and paste it into LiveAstro's OBS settings.

### In LiveAstro

- **Connect** connects to OBS without starting a stream.
- **Go Live** connects to OBS if needed, switches to the selected stack scene, starts streaming, and optionally starts recording.
- **End Broadcast** stops the OBS stream without ending the astronomy session.
- **End Session** finishes the astronomy session first, renders the replay, then stops the broadcast.

LiveAstro treats broadcasting as deliberate. Starting a session never starts a stream by itself. Quitting the app does not intentionally stop an active OBS stream; this avoids killing a broadcast because of an app crash or accidental quit.

### Scene automation

If you choose both a **Stack scene** and a **Scope scene**, LiveAstro can switch OBS scenes when stacking stalls.

- When frames stop arriving long enough to look stalled, LiveAstro switches to the scope scene.
- When frames resume, LiveAstro switches back to the stack scene.
- If you change scenes manually in OBS, LiveAstro treats that as an operator override and waits for the next stall or resume boundary before switching again.

## Display Adjustments

Display controls are non-destructive. They change the live view and broadcast image, not the saved linear master.

- **Black point** darkens the background.
- **Stretch strength** brightens faint detail.
- **Saturation** changes color intensity.
- **Neutralize background** removes broad color casts.
- **Background extraction** reduces smooth gradients from light pollution or moonlight.

If a nebula fills most of the frame, use background extraction gently. Any automatic gradient tool can over-flatten a frame-filling object if pushed too hard.

## Calibration

Calibration applies to native raw-sub stacking and import workflows.

- **Dark** frames subtract thermal signal.
- **Flat** frames correct dust and vignetting.
- **Bias / dark-flat** frames remove the camera readout offset, mainly so flats can be applied cleanly.

You can point LiveAstro at existing master calibration files or build masters from folders of raw calibration frames. Calibration is optional; leave a row empty to skip that type.

Darks are useful for many rigs, especially uncooled cameras, long exposures,
amp glow, warm sensors, or data that was not dithered. They are not mandatory
for every modern cooled-camera workflow. If your capture software dithers
between subs and LiveAstro's Winsorized sigma clipping is enabled, test your
own data both with and without darks before assuming one answer is always
better. LiveAstro records what calibration was used, but dithering is controlled
by the upstream capture system, not by LiveAstro.

Bias or dark-flat frames are mostly a companion to flats. If you are using
flats, provide whichever master your calibration workflow calls for; with many
CMOS astro cameras, matched dark-flats are often preferred over very short bias
frames. If you are stacking lights only and skipping flats, bias/dark-flat
frames usually do little by themselves.

## Reseed Reference

Native stacking aligns new frames against a reference. **Reseed Reference** clears the current reference and uses the next accepted frame as the new one.

Use reseed when the field has changed enough that the old reference is no longer useful:

- a meridian flip
- a long gap
- fog or clouds clearing
- a major framing change
- repeated registration failures

Reseed does not erase the session history or snapshots already recorded. It does reset the current stack. If you reseed near the end of a session and no later frame becomes the new seed, LiveAstro may end honestly without a native master because there is no current stack to write.

## Session Outputs

Sessions are written under `~/Documents/LiveAstro/`.

A session folder may contain:

- `replay.mp4` — the automatic stack-evolution video
- `master.fit` — the final native-stack master, when LiveAstro performed native stacking and a current stack exists
- snapshots — still frames captured throughout the session
- a manifest — session metadata, profile fields, timing, and output facts

For external-stacker sessions, the external program owns the stack master. LiveAstro records what it observed and produces the replay from those observations.

## Troubleshooting

### The app does not see my Seestar or ASIAIR

Mount the device's SMB share in Finder first. LiveAstro detects mounted shares; it does not mount every possible network device by itself.

### The folder is selected, but nothing stacks

Confirm new `.fit` or `.fits` files are appearing after the session starts. Live sessions are session-scoped, so old files already sitting in the folder are not automatically replayed as new frames.

### Siril says files are unsupported

If using Siril livestacking, make sure Siril's working directory is the folder where live stacking is running. In Siril's command line, run `cd /path/to/watch/folder` before starting livestacking.

### OBS will not connect

Check that OBS is running, WebSocket Server is enabled, the port matches, and the password in LiveAstro matches OBS. If OBS regenerates its WebSocket password, paste the new password into LiveAstro.

### OBS may still be live

LiveAstro could not confirm that OBS stopped streaming or recording. Check OBS directly. If needed, stop the stream in OBS or use LiveAstro's retry control.

### The replay skips cloudy frames

The replay generator avoids letting passing clouds dominate the evolution video. It keeps the first and last frames and can drop frames whose background brightness is far outside the recent accepted-frame baseline.

### The image looks too dark or too flat

Adjust stretch, black point, saturation, and background tools. These are display-only controls. The saved native `master.fit` remains linear for later processing.

## What LiveAstro Does Not Do

LiveAstro does not replace your acquisition ecosystem.

It does not:

- polar align your mount
- slew or plate-solve your target
- focus your telescope
- control camera gain, cooling, or exposure plans
- replace OBS as the streaming encoder

It does:

- watch incoming files
- stack raw FITS subs natively
- watch external stack outputs
- show a clean broadcast window
- automate OBS when configured
- save snapshots and replays
- write a native linear master when LiveAstro owns the stack
