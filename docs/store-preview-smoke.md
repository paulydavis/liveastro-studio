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
