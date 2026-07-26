# Beta Tester Checklist

Use this checklist for pre-field beta validation. It is intentionally split into checks that do not need clear skies and checks that require real observing.

## No-Sky Checks

### Install and Launch

- [ ] Open the packaged `LiveAstroStudio.app`.
- [ ] Confirm macOS does not show an unidentified-developer warning for notarized builds.
- [ ] Confirm the app opens to the main control surface.
- [ ] Open Help and confirm the in-app help renders.

### Demo Source

- [ ] Run the sample stack generator:

  ```bash
  mkdir -p /tmp/liveastro-demo-stack
  swift run demo-stack /tmp/liveastro-demo-stack --interval 3 --count 30
  ```

- [ ] Choose **Stacker output folder** in LiveAstro.
- [ ] Select `/tmp/liveastro-demo-stack`.
- [ ] Start the session.
- [ ] Confirm the display updates as new demo frames arrive.
- [ ] Click **Detach** and confirm the broadcast window opens.
- [ ] End the session.
- [ ] Confirm a new session folder appears under `~/Documents/LiveAstro/`.
- [ ] Confirm `replay.mp4` exists and plays.

### OBS Local Check

- [ ] Open OBS.
- [ ] Enable OBS WebSocket server.
- [ ] Connect LiveAstro to OBS.
- [ ] Add a Window Capture source for the LiveAstro broadcast window.
- [ ] Confirm **Go Live** starts OBS streaming or test streaming as configured.
- [ ] Confirm **End Broadcast** stops OBS streaming.
- [ ] Confirm scene automation switches between Stack and Scope scenes when frames stall/resume.
- [ ] Confirm LiveAstro reports an honest degraded state if OBS cannot confirm stop status.

### Stack Previous Shoot

- [ ] Choose **Stack Previous Shoot…**.
- [ ] Select a folder of existing FITS light frames.
- [ ] Confirm import progress advances.
- [ ] Confirm Cancel preserves a valid partial result.
- [ ] Confirm completed imports write `replay.mp4`.
- [ ] Confirm native-stack imports write `master.fit` when a current stack exists.

### Distribution Package

- [ ] Run an ad-hoc local package:

  ```bash
  Scripts/package_release.sh --version 3.0.1 --sign ad-hoc
  ```

- [ ] Run a Developer ID signed package:

  ```bash
  Scripts/package_release.sh \
    --version 3.0.1 \
    --sign developer-id \
    --identity 48A67337B61BCAF1F4970C1389A4EC36D0096E26
  ```

- [ ] Run a notarized package:

  ```bash
  Scripts/package_release.sh \
    --version 3.0.1 \
    --sign developer-id \
    --identity 48A67337B61BCAF1F4970C1389A4EC36D0096E26 \
    --notarize \
    --notary-profile liveastro-notary
  ```

- [ ] Confirm `codesign --verify --strict --verbose=2 dist/LiveAstroStudio.app` passes.
- [ ] Confirm notarized builds pass `spctl -a -vv --type execute dist/LiveAstroStudio.app`.
- [ ] Confirm `xcrun stapler validate dist/LiveAstroStudio-3.0.1.dmg` passes for notarized DMGs.

## Field Checks

These require a real rig, real sky, or both.

- [ ] Seestar share detection and live raw FITS writing.
- [ ] ASIAIR share detection and active light-frame folder selection.
- [ ] Generic folder live stacking from a capture app such as NINA.
- [ ] Siril live-stack folder behavior on a real target.
- [ ] Reseed after meridian flip or large framing change.
- [ ] Cloud/fog interruption recovery.
- [ ] Long unattended session survival.
- [ ] OBS stream health during a real YouTube broadcast.
- [ ] Siril parity benchmark against a known legal local corpus.

## Feedback to Record

For every beta run, record:

- app version
- macOS version
- source mode
- camera/capture system
- whether OBS was used
- session duration
- number of accepted/rejected frames when visible
- whether `replay.mp4` was produced
- whether `master.fit` was expected and produced
- anything confusing in the UI
- any crash, hang, or misleading log line
