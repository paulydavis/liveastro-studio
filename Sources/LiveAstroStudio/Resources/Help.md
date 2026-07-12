# LiveAstro Studio Help

LiveAstro Studio watches your incoming sub-exposures, stacks them live, and shows the result in an OBS-friendly window you can broadcast. It works with any FITS source — a Seestar, an ASIAIR/ASI2600 rig, or NINA — plus a native stacker for finished imaging.

---

## Quick Start

There are three one-tap live paths. Each relays only the subs that arrive **after** you tap (session-scoped), then stacks them natively.

1. **Start Seestar** — mount the Seestar's SMB share in Finder, then tap **Start Seestar**. The app auto-detects the share, relays 10-second subs to a local folder, and begins stacking.
2. **Start ASIAIR** — mount the ASIAIR's SMB share (ASIAIR app: Settings → Network Share → Enable), then tap **Start ASIAIR**. The app auto-detects the ASIAIR's `Autorun/Light` target folder and stacks its subs live.
3. **Choose Folder…** — tap **Choose Folder…** and pick the folder your rig writes subs to (a NINA output folder, or any incoming-subs folder). The app relays new subs from that folder and stacks them.

Switch to the **Live** tab to watch the stack build in real time. Tap **Detach** to pop the display into its own window for OBS capture.

---

## Source Modes

| Mode | What it does |
|------|-------------|
| **Start Seestar** | Auto-detects the Seestar SMB share and stacks its 10s subs live. |
| **Start ASIAIR** | Auto-detects the ASIAIR's Autorun/Light folder and stacks its subs live. |
| **Choose Folder…** | Relays new subs from a folder you pick (any rig) and stacks them live. |
| **Raw subs** | Imports and stacks a folder of existing sub-exposures with the native stacker. |

The source mode is locked while a session is running. End the session to change it.

---

## Display Adjustments

These sliders are **non-destructive** — they change only what you see, never the linear master on disk.

- **Black point** — lifts the shadow clip to darken the background.
- **Stretch strength** — how aggressively midtones are brightened.
- **Saturation** — color intensity of the display image.

Press **Reset** to return to neutral (the default, byte-identical to the unadjusted view). Two background tools help with light pollution:

- **Neutralize background** — removes an overall color cast (e.g. the green tint on one-shot-color sky).
- **Background extraction (DBE)** — fits and subtracts a smooth gradient across the frame. For a nebula that fills the whole frame, raise Scale or leave it off — the model can over-flatten a frame-filling nebula in the display (the master is never affected).

---

## Zoom & Pan

Scroll over the live view to zoom in and out. Drag to pan when zoomed in. The view re-centers to fit when you zoom back out.

---

## Calibration

Calibration applies only in **Raw subs** mode.

- **Dark** — subtracts thermal noise matching your sub-exposure length and camera temperature.
- **Flat** — corrects vignetting and dust motes. Flats are bias-corrected before use.
- **Bias** — used internally to clean flats; it is *not* applied to light frames directly.

For each frame type you can either:

- **Use file…** — point to a pre-built master FITS file.
- **Build…** — select a folder of raw calibration frames; the app combines them into a master and saves it to `~/LiveAstro/masters/`.

Leave a row empty to skip that calibration type.

---

## Go Live (YouTube via OBS)

LiveAstro Studio broadcasts through OBS Studio.

1. Connect LiveAstro to OBS in the **OBS** section (see OBS Setup below).
2. In OBS, add a source pointed at the detached LiveAstro window.
3. Click **Go Live** to start the stream. The status line shows elapsed time and, if the network is congested, dropped-frame and congestion readouts.
4. Click **End Broadcast** to stop.

Use the **Stack scene** / **Scope scene** pickers with **Scene automation** on to switch scenes automatically when the stack stalls.

---

## OBS Setup

1. In OBS: **Tools → WebSocket Server Settings** → enable the WebSocket server (default port 4455).
2. Copy the password from **Show Connect Info**.
3. Paste the host, port, and password into the **OBS** section in LiveAstro Studio, then click **Connect**.

> **Important:** The OBS WebSocket password regenerates every time OBS is restarted with "Generate Password" enabled. If the connection suddenly fails, open **Tools → WebSocket Server Settings → Show Connect Info** in OBS and paste the new password here.

---

## Troubleshooting

**"No share found" when tapping Start Seestar**
The Seestar SMB share is not mounted. In Finder: **Go → Connect to Server** (`⌘K`), enter `smb://<seestar-ip>`, and mount the share. Then try Start Seestar again.

**Start Seestar finds the share but never stacks**
Check the Seestar's live-view format. In the Seestar app (v3.3.0+), the live-view format toggle must be set to **RAW**, not JPEG — in JPEG mode the Seestar does not write the raw `.fit` subs that LiveAstro relays, so the stack never builds.

**Choose Folder… isn't stacking**
Confirm the folder you picked is the one your rig actively writes subs to, and that new `.fit`/`.fits` files are appearing there. Only subs that arrive after you tap are relayed; a folder that is already full but idle will not produce new frames.

**Stack not updating**
Check that the relay folder (`~/LiveAstro/relay/`) is receiving new files. If it is empty, end the session, re-select the source, and start again.

**OBS scene not switching automatically**
Ensure you have selected both a **Stack scene** and a **Scope scene** in the OBS section and that **Scene automation** is toggled on.

**Import Subs progress bar stuck**
A large folder with many FITS files can take time. The **Cancel** button is always available; cancelling mid-import preserves all frames processed so far and leaves a valid partial master.
