# Mac App Store submission checklist

This checklist is for the sandboxed Mac App Store edition. The direct GitHub
edition remains the full-featured distribution. The proposed App Store bundle
identifier is `com.pauldavis.liveastrostudio.appstore`.

## App Store Connect setup

- Create the macOS app record and register the bundle ID exactly as
  `com.pauldavis.liveastrostudio.appstore`.
- Choose a stable SKU and set macOS as the platform. Confirm pricing,
  availability, tax, and any regional restrictions before the first upload.
- Complete the privacy questionnaire. Describe local FITS/session files,
  selected camera shares, OBS connection status, and local recording; do not
  claim camera control or public-stream automation.
- Prepare screenshots showing: Start Workflow, native stack/live view,
  detached broadcast window, OBS status/local recording, and the restricted
  controls/help text.
- In review notes, explain that Seestar/ASIAIR shares are user-selected
  locations, native stacking is local, OBS status is read-only, and local
  recording is separate from public streaming. Include a short reviewer path
  using the built-in demo input if hardware is unavailable.

## Build and package

1. Start from a clean checkout and run `Scripts/preflight.sh`.
2. Build the package with the App Store identity and installer identity:

   ```bash
   Scripts/package_app_store.sh \
     --version 3.6.12 \
     --identity "3rd Party Mac Developer Application: NAME (TEAMID)" \
     --installer-identity "3rd Party Mac Developer Installer: NAME (TEAMID)"
   ```

3. Confirm the script reports the expected bundle ID and exact sandbox
   entitlements, then retain the `.pkg` checksum with the release artifacts.
4. Upload with Transporter or Xcode Organizer only after the gate and smoke
   checks below pass. Do not submit a package that has only been locally
   assembled or signed.

## TestFlight acceptance

- Install cleanly on a test Mac and launch without a pre-existing direct-edition
  settings domain.
- Select temporary source and output folders; quit and relaunch; confirm
  security-scoped bookmarks restore the selected locations.
- Select a Seestar or ASIAIR mounted share and confirm the camera authorization
  flow, relay creation, cancellation, and retry behavior.
- Run a small native stack from FITS files and confirm the session summary,
  master, snapshots, and replay are created in the selected output location.
- Open the detached broadcast window and add it to OBS as a window capture.
  Confirm an already-streaming OBS instance is reported without being taken
  over by the app.
- Start and stop local OBS recording through the sandboxed controls.
- Confirm the App Store build does not show GraXpert, one-click public stream,
  or scene-automation controls; the help text should explain the boundary.
- Test a denied folder, stale bookmark, cancelled camera search, and a mounted
  but unselected SMB share. Each must fail visibly without falling back to an
  unrelated path.

## Submission record

Record the uploaded build number, package checksum, TestFlight build number,
test date, macOS version, and the reviewer notes used. Keep the preflight log
and focused sandbox-test log with the release artifacts. If a later build
changes entitlements, bundle identity, or capability predicates, repeat the
full checklist rather than relying on the previous TestFlight result.
