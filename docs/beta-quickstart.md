# Beta Quickstart: Try LiveAstro Without a Telescope

This quickstart lets a new tester see what LiveAstro Studio does without clear skies, a mounted camera, or a live rig.

The easiest demo is the built-in **Try Demo** workflow. It writes a changing sample stack into a local folder, starts LiveAstro watching it, updates the display, records snapshots, and creates a replay when the session ends.

## What You Need

- macOS 14 or later
- LiveAstro Studio from source or the current tester DMG: [LiveAstro Studio 3.0.3](https://github.com/paulydavis/liveastro-studio/releases/tag/v3.0.3)
- OBS Studio, optional but recommended for the broadcast-window check

## 1. Start the Demo

In LiveAstro, click **Try Demo** in the Start Workflow section.

If you are running from source and want to drive the demo from Terminal instead:

```bash
mkdir -p /tmp/liveastro-demo-stack
swift run demo-stack /tmp/liveastro-demo-stack --interval 3 --count 30
```

Leave that Terminal window running. It writes a new stack update every few seconds.

## 2. Open LiveAstro

If you installed from the DMG, open **LiveAstro Studio** from Applications.

To run from source:

```bash
swift run LiveAstroStudio
```

## 3. Choose the Demo Folder

In LiveAstro:

1. If you clicked **Try Demo**, LiveAstro already chose the demo folder and started the session.
2. If you are using the Terminal fallback, choose **Stacker output folder**.
3. Choose `/tmp/liveastro-demo-stack`.
4. Leave **File name starts with** set to `live_stack` if the generated files use that prefix.
5. Fill in a simple profile:
   - Target: `Demo Nebula`
   - Telescope: `Demo`
   - Camera: `Demo`
   - Sub-exposure: `30s`
6. Start the session.

The live view should update as new demo stack files arrive.

## 4. Open the Broadcast Window

Click **Detach** to open the broadcast window. This is the window OBS should capture during a real stream.

If using OBS:

1. Open OBS.
2. Add a **Window Capture** source.
3. Select the LiveAstro broadcast window.
4. Confirm the broadcast view fills the OBS scene cleanly.

You do not need to actually stream for this check.

## 5. End the Session

Click **End Session** in LiveAstro.

LiveAstro should:

- stop watching for demo updates
- write the session record under `~/Documents/LiveAstro/`
- create `replay.mp4`
- keep a snapshot history

External-stacker demo sessions do not promise a native `master.fit`; the watched stacker owns the stack.

## 6. Check the Output

Open the newest session folder under:

```text
~/Documents/LiveAstro/
```

Look for:

- `replay.mp4`
- snapshots
- manifest metadata

Open `replay.mp4`. It should show the stack evolving over the demo session.

## What This Demo Proves

This no-sky path checks:

- app launch
- folder watching
- display update
- detached broadcast window
- OBS capture setup
- session finalization
- replay generation
- session output discoverability

It does not prove:

- camera acquisition
- real FITS calibration quality
- real star registration on your optics
- live network-share behavior
- YouTube stream health

Those still need real rig and field validation.
