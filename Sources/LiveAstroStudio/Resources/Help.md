# LiveAstro Studio Help

## Quick Start (Seestar Live)

1. Mount the Seestar's SMB share in Finder (connect to server using the IP shown in the Seestar app).
2. Tap **Seestar Live** — the app auto-detects the share, starts relaying 10-second subs to a local relay folder, and begins native stacking in one step.
3. Switch to the **Live** tab to see the stacked result updating in real time.
4. Optionally tap **Detach** to pop the display into its own window for OBS capture.

---

## Source Modes

| Mode | What it does |
|------|-------------|
| **Seestar Live** | Watches Siril's `live_stack.fit` output and displays that image directly. |
| **Raw subs** | Stacks individual sub-exposures natively using LiveAstro's built-in stacker. |

Switch between modes in the **Watch Folder** section before starting a session. The mode cannot be changed while a session is running.

---

## Calibration

Calibration applies only in **Raw subs** mode.

- **Dark** — subtracts thermal noise matching your sub-exposure length and camera temperature.
- **Flat** — corrects vignetting and dust motes. Flats are bias-corrected before use.
- **Bias** — used internally to clean flats; it is *not* applied to light frames directly.

For each frame type you can either:
- **Use file…** — point to a pre-built master FITS file.
- **Build…** — select a folder of raw calibration frames; the app combines them into a master and saves it to `~/Library/Application Support/LiveAstroStudio/masters/`.

Leave a row empty to skip that calibration type.

---

## OBS Setup

1. In OBS: **Tools → WebSocket Server Settings** → enable the WebSocket server (default port 4455).
2. Copy the password from **Show Connect Info**.
3. Paste the host, port, and password into the **OBS** section in LiveAstro Studio, then click **Connect**.

> **Important:** The OBS WebSocket password regenerates every time OBS is restarted with "Generate Password" enabled. If the connection suddenly fails, open **Tools → WebSocket Server Settings → Show Connect Info** in OBS and paste the new password here.

For broadcast, add an **Image Source** (or **Window Capture**) in OBS pointed at the detached LiveAstro window. Use the **Stack scene** / **Scope scene** pickers to enable automatic scene switching when the stack stalls.

---

## Troubleshooting

**"No share found" when tapping Seestar Live**
The Seestar SMB share is not mounted. In Finder: **Go → Connect to Server** (`⌘K`), enter `smb://<seestar-ip>`, and mount the share. Then try Seestar Live again.

**Stack not updating**
Check that the relay folder (`~/Library/Application Support/LiveAstroStudio/relay/`) is receiving new files. If it is empty, the relay watcher may have lost the watch-folder path — end the session, re-select the folder, and start again.

**OBS scene not switching automatically**
Ensure you have selected both a **Stack scene** and a **Scope scene** in the OBS section and that **Scene automation** is toggled on.

**Import Subs progress bar stuck**
A large folder with many FITS files can take time. The **Cancel** button is always available; cancelling mid-import preserves all frames processed so far and leaves a valid partial master.
