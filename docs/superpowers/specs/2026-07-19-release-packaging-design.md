# Release Packaging Design

## Goal

Prepare LiveAstro Studio for direct Mac distribution using one repeatable packaging lane that works today with ad-hoc signing and later with Developer ID signing plus notarization.

## Scope

This is release tooling only. It does not change app behavior, move the `v3.0.0` tag, or require Apple credentials during normal tests.

## Packaging Script

Add `Scripts/package_release.sh` as the canonical packaging command. It builds a release app bundle, signs nested bundle/executable/app inside-out, creates a DMG, and verifies the result.

Supported modes:

- `--sign ad-hoc`: uses `codesign --sign -` with hardened runtime options where supported; creates a local-test DMG that is not notarized.
- `--sign developer-id`: requires `DEVID` or `--identity`, uses `Developer ID Application: ...`, signs with secure timestamp and hardened runtime, and produces a DMG suitable for notarization.
- `--notarize`: requires Developer ID signing and `NOTARY_PROFILE`; submits the DMG with `xcrun notarytool submit --wait`, staples the app and final DMG, then verifies with Gatekeeper.
- `--dry-run`: prints the selected plan and validates mode/credential requirements without building, signing, or contacting Apple.

The script must fail fast when asked to notarize without Developer ID signing or without a notary profile. It must not silently fall back to ad-hoc when the user requested Developer ID signing.

## Documentation

Add `docs/distribution.md` with:

- current status check: `security find-identity -v -p codesigning`
- Developer ID certificate requirement
- `xcrun notarytool store-credentials liveastro-notary`
- ad-hoc packaging command for local testing
- Developer ID signing command
- notarized release command
- expected outputs and verification commands

## Compatibility

Keep existing `Scripts/package_signed.sh` and `Scripts/make_dmg.sh` for now, but make the new script the documented path. A later cleanup can remove or redirect legacy scripts after the new path has been used successfully.

