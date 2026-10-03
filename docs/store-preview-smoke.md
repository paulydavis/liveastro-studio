# LiveAstro Store Preview smoke check

This checklist is for the separate local proof build named **LiveAstro Store Preview**
(`com.pauldavis.liveastrostudio.store-preview`). It is not an App Store archive,
is not notarized, and must not replace or modify `/Applications/LiveAstroStudio.app`.
A valid signature and parsed entitlements establish packaging configuration only;
they do not establish that macOS folder grants persist at runtime.

## Build and static verification

Use an existing Developer ID Application identity. The script refuses an existing
output app, creates and removes only its own `mktemp` build scratch, and leaves
`dist/` and the direct-release scratch untouched.

```bash
security find-identity -v -p codesigning

Scripts/package_store_preview.sh \
  --identity 48A67337B61BCAF1F4970C1389A4EC36D0096E26 \
  --output-app "$PWD/.build/store-preview-task3/LiveAstro Store Preview.app"

preview_app="$PWD/.build/store-preview-task3/LiveAstro Store Preview.app"
codesign --verify --deep --strict "$preview_app"
codesign -dv --verbose=4 "$preview_app" 2>&1
codesign -d --entitlements - --xml "$preview_app" > /tmp/liveastro-store-preview-entitlements.plist
plutil -p /tmp/liveastro-store-preview-entitlements.plist
plutil -p "$preview_app/Contents/Info.plist"
```

Before launch, confirm the signature reports a Developer ID Application authority,
the identifier is `com.pauldavis.liveastrostudio.store-preview`, and the display
name is `LiveAstro Store Preview`. The parsed signed entitlements must enable only
the intended capabilities:

- `com.apple.security.app-sandbox`
- `com.apple.security.files.user-selected.read-write`
- `com.apple.security.files.bookmarks.app-scope`
- `com.apple.security.network.client`

Do not interpret a Developer ID signature as notarization or App Store approval.

## Preconditions for the operator checkpoint

Do not launch until the whole-branch review and full serial preflight are complete.
Prepare a new scratch input folder containing copies of six real Seestar light subs,
a separate scratch output folder, and copied-only calibration input if used. Record
SHA-256 checksums for every original and copy before starting. Never move, relabel,
or process the original FITS files in place.

## Manual acceptance — pending until observed

All items below require the signed app running as its own process and remain pending
until the operator performs them through the real macOS folder-selection panels.

- [ ] Launch the development copy, confirm its visible name, and choose the copied
  input folder, scratch session-output folder, and copied calibration folder.
- [ ] Start native processing and confirm the six copied subs are read, calibrated
  when selected, stacked, and written only beneath the chosen scratch output.
- [ ] Select **End** and observe ordinary finalization. Record FITS counts/exposure,
  output paths, completion state, and any sandbox denial messages.
- [ ] Quit the process completely, relaunch the same signed app, and confirm the
  remembered input/output/calibration grants resolve without selecting raw paths
  as if they were authorization.
- [ ] Add a newly copied sub to the authorized input folder and confirm the
  relaunched process observes and processes it.
- [ ] Make only the copied input or calibration location unavailable, relaunch,
  confirm the choice remains visible but requires reauthorization, then reselect
  the copied location and retry. A denial must not look like an empty folder.
- [ ] Confirm the original Seestar files retain their pre-test checksums and that
  no preview data appeared in the direct edition's preferences or output paths.
- [ ] If ordinary **End** reaches a fully complete clean stack, separately exercise
  the clearly labelled deterministic development fixture for incomplete completion.
  Its harness-only zero final-refine budget is evidence for the completion UI, not
  a production preview option and not sandbox proof by itself.

Keep the manual result labelled **pending** unless every relevant behavior was
observed in the signed sandboxed process. Fake bookmark tests, the standalone
completion harness, screenshots, and static codesign inspection cannot substitute
for this checkpoint.

## Authorized camera shares — separate runtime checkpoint

The Store preview's **Live from Seestar** and **Live from ASIAIR** actions ask for
the camera's mounted share on first use. Mount it in Finder first and select the
top-level folder containing `MyWorks` (Seestar) or `Autorun/Light` (ASIAIR).
Discovery searches only inside that saved share; it does not scan `/Volumes`.
Use **Choose Seestar share…** or **Choose ASIAIR share…** to replace a selection.
Cancelling replacement keeps the previous permission. These changes do not alter
the direct GitHub edition's discovery behavior.

The existing relay still copies only newly arriving subs. Its start baseline is
not changed by authorization; pre-existing subs on the camera are not suddenly
imported. Session-start confirmation still applies to matching files already in
the local relay destination.

- [ ] In the signed preview, select one real mounted camera share and start its
  workflow. Verify the chosen target and a newly arriving file actually relays
  and is processed, then End and check counts/exposure/output.
- [ ] Quit completely, reopen, and repeat without selecting the share again.
- [ ] Disconnect the share, retry, and confirm an actionable access error rather
  than empty-folder waiting or selection of another mounted camera/copy.
- [ ] Reconnect; retry using the saved permission. If macOS cannot restore it,
  choose the share again and verify a new frame is processed.
- [ ] Repeat for the other camera before claiming both real-share paths tested.

Automated fixtures with fake bookmark services do not establish real SMB or
macOS sandbox behavior. These items remain pending until observed.

## Permission preparation repair — runtime checks still pending

While Store camera/folder detection is pending, **Cancel source search** is in
the fixed Setup footer, including when another Setup sub-tab is selected. Cancel
must immediately restore the controls and prevent any late result from starting
a session or replacing a newer search. It does not stop an active session/relay.
Camera errors identify permission acquisition, share search, or session-folder
preparation; underlying macOS details are retained in Diagnostics.

- [ ] With a saved share unavailable, begin access and verify the app remains
  responsive during permission preparation. Cancel, then reconnect or choose a
  different folder; a late completion must not restore the old selection or start
  the cancelled operation. Repeat for import and camera discovery.
- [ ] Use the same selected raw folder for a calibration-library source and
  session dark-flats. Move it in Finder. Start a session, then rebuild the master;
  repeat in reverse order with another move. Both consumers must follow the moved
  folder, including after quitting and reopening the signed preview.
- [ ] While calibration permission preparation is stalled, clear or reselect its
  folder. Busy preparation must retire immediately; the late result must not
  build from the old source or overwrite the new selection.
- [ ] Finish a session under a symlinked output folder, then select a different
  output. The old session's replay/processing must still work, without granting
  access to its sibling sessions. Session-output buttons may populate after the
  background availability check; a disconnected share must not freeze Setup.

Cancellation releases the UI's request ownership; it cannot forcibly interrupt
a filesystem call already blocked inside macOS. Its worker keeps any acquired
security scope until that call returns. Automated blocked-call and moved-folder
tests cover these contracts, not the behavior of a particular SMB server.

## Whole-display night tint — integrated runtime checks

The standalone sandbox API probe succeeded on the operator's built-in display on
2026-09-28. That is feasibility evidence, not a test of the integrated app or App
Store approval. The controls now use the same whole-display API in both editions.

- [ ] Launch the signed integrated preview with tint off. Use its moon button and
  verify OTHER apps, the menu bar and every connected display turn red. Screenshots
  do not prove physical display output.
- [ ] Change brightness under **Display → Night vision**, then toggle off and
  confirm normal colours return. Saved FITS/PNG/replay files must remain unchanged;
  check captured checksums and view the broadcast output on an untinted display
  where available rather than inferring its pixels from the tinted screen.
- [ ] With tint on, quit the preview completely. Verify normal colours return and
  relaunch starts with tint off.
- [ ] With tint on, let the displays sleep, wake them and confirm tint returns.
  Record any normal-colour interval. Repeat system sleep/reconnect where practical;
  do not claim lock/login screens or untested external/HDR displays are protected.

Automated injected-display tests cover API errors and late lifecycle events without
altering test-runner hardware. They do not replace these physical observations.
The app attempts reapplication; it cannot promise zero white flashes during macOS
transitions. A physical filter is needed where that guarantee is essential.

## OBS read-only check — integrated runtime checkpoint

The later local-recording controls are a separate capability; the connection-check
button itself remains read-only. See the local-recording checklist below.

The separate signed sandbox probe connected and read status on the operator's Mac.
That does not prove this integrated UI works or that the Store edition can control OBS.

- [ ] Open OBS manually; enable its WebSocket server with authentication. In the
  signed Store preview's Broadcast tab, enter the connection details. Verify the
  check reports streaming/recording status and disconnects. No Go Live,
  scene selection or auto-launch controls should appear. The separate recording
  section must not start anything when a connection check succeeds.
- [ ] Repeat with a wrong password, then the correct one. Failure must not claim
  outputs are inactive. Passwords must not appear in logs or persisted settings.
- [ ] Cancel or leave the Broadcast tab during a pending check; the check must
  retire without a late result replacing the cancelled/newer state.
- [ ] Quit/relaunch: connection status starts unverified and the password is empty.
  Direct-edition OBS controls remain unchanged.

Do not start a public stream just to exercise this check. Automated tests cover
active-output responses, cancellation, malformed responses and wire-level rejection
of modifying requests; live stream/record/control testing is outside this milestone.

## OBS local recording — integrated runtime checkpoint

The separate signed sandbox recording probe passed start/stop and the operator
verified playback. That is feasibility evidence only, not an integrated-app pass.

- [ ] In the signed Store preview, check OBS's current picture/audio and save
  folder. Start local recording explicitly and confirm the prompt. The app must
  wait for actual active status, not just the StartRecord acknowledgment.
- [ ] Change tabs and return; recording continues and Stop remains available.
- [ ] Stop recording. Wait for actual inactive status and the reported output path.
  Open the saved clip and check picture/audio. No public stream was started.
- [ ] Start a recording directly in OBS, then try Start in LiveAstro. It refuses
  without taking over. Stop that recording in OBS yourself.
- [ ] During an app-started recording, try End Session and normal Quit. Cancel
  leaves the operation alone; proceeding warns that OBS continues. Stop in OBS
  after quitting. Force quit/crash cannot provide that warning.
- [ ] During an app-started recording, disconnect/stop OBS's WebSocket server.
  LiveAstro must show uncertainty rather than stopped. Stop recording in OBS;
  restore the server and use the read-only recovery check. It must not send Stop
  or take over an existing recording. Re-enter password if required.
- [ ] After relaunch, no previous recording is adopted and no password is saved.

Keep other OBS recording controllers idle. OBS has no per-recording ownership
token: status reads/events narrow external stop/restart races but cannot eliminate
them. Public streaming, scene setup, auto-launch and OBS file access are excluded.
