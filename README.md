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

## OBS automation

LiveAstro can drive OBS over the obs-websocket 5.x protocol so you never have to
touch OBS during a session — **Go Live** launches OBS, connects, and starts the
stream, and scene automation switches scenes based on whether stacking is making
progress. Broadcasting is deliberate: starting a session never starts a stream.

**One-time OBS setup**

1. In OBS, open **Tools → WebSocket Server Settings**.
2. Check **Enable WebSocket server** (default port **4455**).
3. Either turn off **Enable Authentication**, or set a password and copy it into
   the Control window's OBS **Password** field.

**Control window — OBS section**

- **Status line** — a colored dot + text (`disconnected` / `connecting…` /
  `connected` / `streaming`), plus a red **REC** indicator while OBS is recording.
- **Connect / Disconnect** — connect manually with the current host/port/password.
- **Host / Port / Password** — connection settings; locked while connected.
- **Auto-launch OBS on Go Live** — when on (default), clicking Go Live with OBS
  unreachable launches OBS (in the background, without stealing focus) and
  retries the connection for up to 20 s. The manual Connect button never
  launches OBS.
- **Scene picker + ↻** — pick the live program scene; ↻ refreshes the scene list
  from OBS.
- **Record while streaming** — also start OBS recording when the stream comes up.
- **Scene automation (scope on stall)** with **Stack scene** / **Scope scene**
  pickers — see below.

**What happens on Go Live / Start / End Session**

- **Start Session** starts stacking and scene automation only — it never starts
  a stream. Broadcasting begins when you click **Go Live** (footer): it connects
  to OBS (auto-launching if needed), switches to the Stack scene, starts the
  stream, optionally starts recording, and confirms via status polls; **End
  Broadcast** stops it without ending the session. Every OBS step is
  best-effort: if any of it fails, the failure is logged and the astronomy
  session continues regardless — **OBS never blocks the session.**
- **Scene automation:** while a session runs with automation on, a stall detector
  (seeded from your sub-exposure length) watches for stacking to stall. On a stall
  it switches OBS to the **Scope scene** once; when frames resume it switches back
  to the **Stack scene** once. If you change the program scene by hand, automation
  detects the override and pauses until the next stall/resume boundary.
- **End Session** runs the replay generation first, then — and only then — stops
  the OBS stream and recording. This is the **only** place the stream is stopped:
  quitting or force-quitting the app deliberately leaves the OBS stream alive so a
  crash or accidental quit never kills your broadcast.

**Manual validation checklist**

Run through these against a live OBS before relying on the automation:

- [ ] **Auth** — with a WebSocket password set, Connect succeeds; with a wrong
      password it fails and logs an auth error (session still starts).
- [ ] **Cold auto-launch** — with OBS quit and Auto-launch on, Go Live
      launches OBS (in the background) and connects within ~20 s.
- [ ] **Stream toggle** — Go Live turns OBS's stream indicator on; End
      Session (or End Broadcast) turns it off.
- [ ] **Scene automation via stall** — with automation on and Stack/Scope scenes
      chosen, stop feeding frames (or pause `fakesiril`); after the stall threshold
      OBS switches to the Scope scene, and resuming frames switches back to Stack.
- [ ] **Accidental quit leaves stream alive** — while streaming, force-quit
      LiveAstro; OBS keeps streaming (only End Session stops it).

**Real-connection smoke test**

`Scripts/obs_smoke.swift` is a headless program that connects to a live OBS on
`localhost:4455`, prints the state, scene list, and OBS version, then starts and
stops the stream. It is run **manually** (it connects to real OBS and starts a
real stream, so never run it during a live broadcast). The password is passed as
the first argument; the build+run command is documented in a comment at the top
of the script.

## Native stacking

LiveAstro v2 can stack raw sub-exposures itself — no external live-stacker required.
There are two entry points:

**Import Subs… (batch import from acquired files)**

1. In the Control window, set the source mode to **Raw subs folder (native stacking)**.
2. Fill in the session profile (target and exposure are auto-detected from the
   newest sub's FITS header), then click **Import Subs…** and choose the folder
   containing your `.fit` files. The import starts immediately — no Start
   Session needed (and it refuses to start while a live session is running).
   The engine imports each file in chronological order: calibration (if
   configured) → RCD debayer → star registration → gradient leveling →
   σ-clip → quality-weighted stack. A progress bar shows N / total with
   accepted/rejected counts and a Cancel button; a cancelled import finalizes
   the frames stacked so far.
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
- v1: `docs/history/specs/2026-07-05-liveastro-studio-v1-design.md`
- v2 native stacking: `docs/history/specs/2026-07-07-liveastro-v2-native-stacking-design.md`

Validation comparison script: `Scripts/compare_to_master.py`
