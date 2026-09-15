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

## Capture settings

Click the ⓘ beside a setting for its explanation. **Read more in Help** opens the manual in the same popover; **Back to setting** returns to the topic. **Done** or Escape closes it without changing any setting.

### Neutralize background (OSC white balance)

Balances the red, green and blue background levels after stacking to reduce a broad color cast in the displayed image. OSC means a one-shot-color camera. This is not flat calibration and does not remove dust shadows. Choose it before starting; compare the color balance on your own data.

### Reject outliers (σ-clip)

Limits unusually different pixel values as subs are combined, reducing the influence of satellite trails, aircraft trails and isolated bright pixels. It is on by default. It does not guarantee that every trail disappears, particularly with few subs.

**Strength** controls the tolerance: Low is more aggressive; High tolerates more variation and rejects less. Medium is the default. This online rejection is separate from the background clean-master pass described under **Live trail rejection**.

### Weight frames by quality

Gives sharper, lower-noise subs more influence using star-count and background-noise measurements. Turn it off for equal weighting. Weighting changes the contribution of a frame; it is not the same as rejecting the frame entirely.

### Match sky background

Matches each sub's broad background to the reference before stacking. This helps when sky brightness or its gradient changes during a session. It affects the stack, unlike display-only background extraction. Turn it off when you want to combine frames without this background adjustment.

### Match transparency

Uses matched stars to scale each sub's brightness toward the reference, compensating for changes such as thin haze. Requires **Match sky background**, because the scaling is applied about that matched background. It cannot recover detail obscured by cloud; turn it off for unscaled contributions.

### Keep relay sessions

Live relay sessions stage copies of incoming subs under `~/LiveAstro/relay`. When a new relay session starts, old relay sessions beyond the selected age are eligible for deletion. These are local copies, not the originals on the rig. **Off** disables this pruning; keep an eye on disk space if you retain everything.

### Debayer

Converts a color camera's raw mosaic into a color image. **Malvar (high quality)** is the recommended method; **Bilinear** is the older, simpler option. Choose this before stacking. It is not a saturation control or a substitute for correct camera mosaic information.

### Live trail rejection (broadcast master)

Runs a background whole-frame outlier pass to produce a cleaner broadcast master and final `master.fit`. It is separate from online per-pixel σ-clipping. It requires an eligible local native live source and enough subs; the status beneath the switch tells you whether a clean master is available.

You can toggle it during a session. Do not assume the switch being on means a clean master has already been published—check the status.

### Idle safeguard — save master if capture stalls

For native stacking, writes a master snapshot after the selected period without incoming capture progress. It keeps the session running, so capture can resume after a cloud gap. This is a save safeguard, not End Session. External stackers manage their own masters.

### Auto-stop at a set time

Schedules a full End Session: finalizes the master and replay and ends a broadcast owned by LiveAstro. It does not quit the app. Check the displayed stop time before leaving the rig unattended; this is different from the idle safeguard, which keeps stacking.

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

## Broadcast setups

LiveAstro guarantees only its own "LiveAstro Stack" source; everything else in your scenes is yours.

**Camera picture-in-picture**
1. Add your camera as a **Video Capture Device** source in the same scene as **LiveAstro Stack**.
2. Drag and resize it into a corner over the stack.
3. Reorder sources so the camera sits above **LiveAstro Stack** in the list.

**Seestar / ASIAIR phone app**
1. AirPlay-mirror the phone to the Mac (Control Center → Screen Mirroring).
2. In OBS, add a **Window Capture** source targeting the mirrored display/window.
3. Position it alongside or over **LiveAstro Stack**.

**NINA**
1. Add a **Window Capture** (or **Display Capture**) source pointed at the NINA window.
2. Arrange it in the scene next to **LiveAstro Stack**.

**Multi-scene combos + stall auto-switch**
1. Build separate scenes (e.g. wide shot, scope cam, stack-only) that each include **LiveAstro Stack** or your other sources as desired.
2. Set **Stack scene** and **Scope scene** under Scene Automation so LiveAstro switches between them automatically on a stall/resume.
3. Switch scenes manually in OBS any time — LiveAstro treats that as an operator override until the next stall/resume boundary.

**YouTube: stream key vs account link**
- **Stream key** (OBS → Settings → Stream, pasted from YouTube Studio → Go Live): one-button automation — Go Live works every time with no extra steps in OBS.
- **Account link** (OBS's YouTube dock, signed in via OAuth): gives you the live chat dock and a fresh broadcast per session, but you must create the broadcast in OBS's YouTube dock *before* clicking Go Live each session — otherwise streaming fails to start.
- If Go Live fails with an account-linked service, check the YouTube dock for an existing broadcast first; pasting a permanent stream key avoids the per-session step entirely.

---

## Display Adjustments

Display controls are non-destructive. They change the live view and broadcast window, not the saved linear master.

- **Black point** darkens the background.
- **Stretch strength** brightens faint detail.
- **Saturation** changes color intensity.
- **Neutralize background** removes broad color casts.
- **Background extraction** reduces smooth gradients from light pollution or moonlight.

If your target fills most of the frame, use background extraction gently so it does not over-flatten the display.

The lower **Your edit** pane previews pending changes. Click **Apply** to commit them or **Revert** to return to the committed settings. Proxy previews are approximate: the delivered broadcast can look different. **Currently live** shows the delivered broadcast; **Updating…** means a committed change has not reached that pane yet.

### Black point

Darkens the sky background. **0** leaves the automatic stretch's shadow cut unchanged. Higher values cut more shadow detail; much of the useful range is below **0.4**. Increase gently—an attractive black sky can also hide faint nebulosity. Click the slider and use arrow keys for fine steps, then Apply.

### Stretch strength

Adjusts how strongly faint detail is brought into view; **0** uses the automatic setting. Judge it alongside black point rather than trying to fix both with one slider. This changes the displayed image, not the linear `master.fit`. Preview the result, then Apply.

### Saturation

Controls color intensity. **1** leaves saturation unchanged; **0** removes color, and values above **1** strengthen it. Strong saturation can exaggerate color noise. This is a display adjustment—preview it, then Apply.

### Flatten background (DBE)

Reduces broad gradients such as light pollution or moonlight in the displayed image. The recommended live preset enables it; your saved settings may differ. It does not replace flats or repair dust calibration.

- **Scale** is the smoothing scale as a percentage of image size. Lower values follow more local gradients; higher values target broader gradients.
- **Smoothest** adds blur to the background model. Increase it to soften blotchiness, or reduce it to follow less-smooth gradients.

Use gently when nebulosity fills the frame: real extended signal can be mistaken for background. Preview, then Apply. Processing can take time, and the proxy preview is not an exact broadcast match.

### Denoise

Smooths background grain and color mottle in the displayed stack. **0** is off. Increase cautiously because smoothing can also soften fine detail. Preview, then Apply; the linear `master.fit` is unchanged. This is separate from optional end-of-stack post-processing.

### North up

Rotates the display so celestial north is up. It requires a star catalog and a successful plate solve; the control is unavailable until a solve is available. The rotated display is cropped to valid image coverage, so its framing can change. The saved linear master stays in its native orientation. Preview, then Apply.

### Red screen

Tints the whole Mac display red to help preserve dark adaptation—not just the LiveAstro window. It takes effect immediately, without Apply, and clears when you quit. Lower brightness means a dimmer, deeper red. Screenshots remain normal because macOS captures them before the display tint.

---

## Calibration

Calibration applies to native raw-sub stacking and import workflows.

- **Dark** subtracts thermal signal.
- **Flat** corrects dust and vignetting.
- **Bias / dark-flat** removes camera readout offset, mainly so flats can be applied cleanly.

You can use existing master calibration files or build masters from folders of calibration frames. Leave a calibration row empty to skip it.

Darks are helpful for many cameras and conditions, but they are not required for every stack. For modern cooled cameras with dithered subs and Winsorized sigma clipping, compare your own data with and without darks if the result looks cleaner one way. LiveAstro does not perform dithering; Seestar, ASIAIR, NINA/PHD2, or another capture tool must do that upstream.

Bias or dark-flat frames mostly matter when you use flats. With many CMOS astro cameras, matched dark-flats are often preferred over very short bias frames. If you are stacking lights only and skipping flats, bias/dark-flat usually does little by itself.

### Using dark-flats as a light offset

**Short answer:** leave **Also use dark-flat as the light offset** off unless you deliberately want this calibration workflow. It is an optional approximation, not a general dust-removal switch.

**What are the different frames?**

- **Lights** are your pictures of the sky.
- **Flats** measure dust shadows and uneven illumination, so the app can correct those patterns in your lights.
- **Dark-flats** are covered exposures taken with the same exposure and camera settings as the flats. Normally, LiveAstro subtracts them from the flats only.
- **Light darks** are covered exposures matched to the lights. They account for the camera's offset and dark signal during those longer exposures.

**What does the checkbox change?**

The camera adds a background level, called an **offset**, even with no light entering it. If that level remains in the lights when the flat is applied, the correction can turn dark dust shadows into bright patches.

With this option enabled, LiveAstro also subtracts the selected dark-flat master from the lights, **before** applying the flat. This treats the dark-flat as an approximation of the lights' offset. It does not make a short dark-flat equivalent to a longer light dark.

**Example:** you have 300-second lights, 15-second flats and 15-second dark-flats. The dark-flats match your flats, not your 300-second lights. This option reuses them for light-offset subtraction only if you choose to do so. It may reduce bright overcorrection, but cannot promise complete dust removal or correction of all dark signal.

**Which settings should I use?**

1. Choose your session flats and dark-flats folders under **Setup → Capture → Calibration**.
2. Leave the checkbox off to use dark-flats only on the flats—the existing behavior.
3. Turn it on only when you intend to reuse the dark-flat for the lights too. Compare the result on copies of your data; bright circles alone do not prove this is the right correction.
4. Check the calibration status and log after Start. They say whether the light offset was actually applied or why it was not.

**Safeguards and limits**

- A usable light dark always wins. LiveAstro does **not** subtract both the light dark and the extra dark-flat offset.
- Usable session flats and dark-flats are required. A missing, unreadable or incompatible selection is reported rather than silently replaced by another offset.
- This setting applies at **live Start**, including when the folder is initially empty. It cannot change calibration in an active session.
- It resets to **off when you quit and reopen the app**.
- It does **not** apply to **Stack Previous Shoot / offline Import**, which uses a separate calibration path.

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
- **Open Summary** opens `session-summary.md` for the latest session.
- **Open Frame CSV** opens `frame-summary.csv` for spreadsheet review.
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
