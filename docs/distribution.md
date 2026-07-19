# Distribution

LiveAstro Studio is distributed as a direct-download Mac app, not as a Mac App Store app.

The direct distribution path keeps the app outside the App Sandbox so it can watch mounted network shares, talk to local OBS, and run external helper processes when configured. Public releases should be signed with a Developer ID Application certificate, notarized by Apple, and shipped as a DMG.

## Current Certificate Check

Check whether this Mac has a valid code-signing identity:

```bash
security find-identity -v -p codesigning
```

For public releases, look for a line like:

```text
Developer ID Application: Your Name (TEAMID)
```

If the command reports `0 valid identities found`, the Apple Developer account may be active but the Developer ID Application certificate is not installed in this login keychain yet.

## One-Time Developer ID Setup

1. Open Xcode.
2. Go to **Xcode → Settings → Accounts**.
3. Add the Apple ID tied to the paid Apple Developer Program.
4. Select the team and open **Manage Certificates…**.
5. Create or download a **Developer ID Application** certificate.
6. Re-run:

```bash
security find-identity -v -p codesigning
```

Copy the exact `Developer ID Application: ...` identity string.

If `security find-identity` shows multiple Developer ID Application identities with the same display name, use the SHA-1 hash at the start of the line instead of the name. For example:

```bash
Scripts/package_release.sh \
  --version 3.0.1 \
  --sign developer-id \
  --identity 48A67337B61BCAF1F4970C1389A4EC36D0096E26
```

Using the hash avoids `codesign` failing with an ambiguous identity error.

## One-Time Notary Profile Setup

Apple notarization uses `notarytool`. Store credentials in the keychain once:

```bash
xcrun notarytool store-credentials liveastro-notary \
  --apple-id you@example.com \
  --team-id TEAMID \
  --password APP_SPECIFIC_PASSWORD
```

Use an app-specific password from Apple ID account management. Do not commit Apple IDs, team IDs, or passwords into the repository.

## Local Ad-Hoc Package

Use this for local testing before Developer ID is installed:

```bash
Scripts/package_release.sh --version 3.0.1 --sign ad-hoc
```

Expected output:

- `dist/LiveAstroStudio.app`
- `dist/LiveAstroStudio-3.0.1.dmg`

This build is signed for local packaging sanity only. It is not notarized and is not suitable for public distribution.

## Developer ID Signed Package

After the Developer ID identity appears in the keychain:

```bash
Scripts/package_release.sh \
  --version 3.0.1 \
  --sign developer-id \
  --identity "Developer ID Application: Your Name (TEAMID)"
```

This signs with hardened runtime and creates a DMG, but does not contact Apple.

## Notarized Public Package

After the notary profile is stored:

```bash
Scripts/package_release.sh \
  --version 3.0.1 \
  --sign developer-id \
  --identity "Developer ID Application: Your Name (TEAMID)" \
  --notarize \
  --notary-profile liveastro-notary
```

The script submits the DMG with `xcrun notarytool submit --wait`, staples the notarization ticket to the app, rebuilds the DMG with the stapled app, staples the DMG, and runs a final Gatekeeper assessment.

## Dry Runs

Dry runs validate command choices without building, signing, or contacting Apple:

```bash
Scripts/package_release.sh --dry-run --version 3.0.1 --sign ad-hoc
Scripts/package_release.sh --dry-run --version 3.0.1 --sign developer-id --identity "Developer ID Application: Example (TEAMID)"
Scripts/package_release.sh --dry-run --version 3.0.1 --sign developer-id --identity "Developer ID Application: Example (TEAMID)" --notarize --notary-profile liveastro-notary
```

Invalid combinations fail deliberately:

- `--sign ad-hoc --notarize`
- `--sign developer-id` without an identity
- `--notarize` without a notary profile

## Verification Commands

After packaging:

```bash
codesign --verify --strict --verbose=2 dist/LiveAstroStudio.app
spctl -a -vv --type execute dist/LiveAstroStudio.app
xcrun stapler validate dist/LiveAstroStudio-3.0.1.dmg
```

Ad-hoc builds are expected to fail Gatekeeper assessment. Developer ID notarized builds should pass.

## Notes

- The entitlements file is intentionally empty. Hardened runtime is enabled by `codesign --options runtime`.
- Do not enable App Sandbox for direct distribution unless the app is redesigned around sandbox file access and external process limitations.
- `v3.0.0` remains the existing release tag. Release-tooling commits do not move that tag.
