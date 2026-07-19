# Release Packaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a repeatable LiveAstro Studio packaging lane for ad-hoc, Developer ID, and notarized direct distribution builds.

**Architecture:** Implement one shell script with explicit modes and a dry-run validation surface. Verify behavior through script dry-runs plus an ad-hoc package build; do not require Apple credentials in automated checks.

**Tech Stack:** Bash, SwiftPM, macOS `codesign`, `hdiutil`, optional `xcrun notarytool`, optional `xcrun stapler`, Markdown documentation.

## Global Constraints

- Do not change app runtime behavior.
- Do not move or recreate `v3.0.0`.
- Do not require Apple credentials for default verification.
- Do not silently fall back to ad-hoc signing when Developer ID signing is requested.
- Do not contact Apple during tests unless `--notarize` is explicitly passed by the operator.

---

### Task 1: Script Dry-Run Contract

**Files:**
- Create: `Scripts/package_release.sh`

**Interfaces:**
- Produces: `Scripts/package_release.sh --dry-run --version <version> --sign <mode> [--identity <identity>] [--notary-profile <profile>]`

- [ ] **Step 1: Create a minimal script with help and argument validation**

The script should support `--help`, `--dry-run`, `--version`, `--sign`, `--identity`, `--notary-profile`, and `--notarize`.

- [ ] **Step 2: Verify dry-run behavior**

Run:

```bash
Scripts/package_release.sh --dry-run --version 3.0.1 --sign ad-hoc
Scripts/package_release.sh --dry-run --version 3.0.1 --sign developer-id --identity "Developer ID Application: Example (TEAMID)"
Scripts/package_release.sh --dry-run --version 3.0.1 --sign developer-id --identity "Developer ID Application: Example (TEAMID)" --notarize --notary-profile liveastro-notary
```

Expected: all print the selected plan and exit 0.

- [ ] **Step 3: Verify invalid combinations fail**

Run:

```bash
Scripts/package_release.sh --dry-run --version 3.0.1 --sign ad-hoc --notarize
Scripts/package_release.sh --dry-run --version 3.0.1 --sign developer-id
Scripts/package_release.sh --dry-run --version 3.0.1 --sign developer-id --identity "Developer ID Application: Example (TEAMID)" --notarize
```

Expected: all exit nonzero with a clear error.

### Task 2: Packaging Implementation

**Files:**
- Modify: `Scripts/package_release.sh`

**Interfaces:**
- Consumes: SwiftPM release products.
- Produces: `dist/LiveAstroStudio.app` and `dist/LiveAstroStudio-<version>.dmg`.

- [ ] **Step 1: Implement build, bundle assembly, signing, DMG creation, and verification**

Use the existing `Scripts/package_signed.sh` behavior as the source of truth for bundle layout, resource-bundle Info.plist injection, entitlements, inside-out signing, and DMG creation.

- [ ] **Step 2: Run an ad-hoc package**

Run:

```bash
Scripts/package_release.sh --version 3.0.1 --sign ad-hoc
```

Expected: release build succeeds, app signs ad-hoc, DMG is written.

### Task 3: Distribution Documentation

**Files:**
- Create: `docs/distribution.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: `Scripts/package_release.sh`.
- Produces: user/developer documentation for direct distribution.

- [ ] **Step 1: Document ad-hoc and Developer ID release commands**

Include setup, identity check, notary profile setup, commands, expected outputs, and troubleshooting.

- [ ] **Step 2: Link distribution docs from README**

Add a short development/distribution pointer.

### Task 4: Final Verification

**Files:**
- All modified files.

**Interfaces:**
- Consumes: Tasks 1-3.
- Produces: committed release tooling change.

- [ ] **Step 1: Run dry-run checks**

Run the valid and invalid dry-run commands from Task 1.

- [ ] **Step 2: Run build/package check**

Run `Scripts/package_release.sh --version 3.0.1 --sign ad-hoc`.

- [ ] **Step 3: Run docs/hygiene checks**

Run `swift build -c release`, `git diff --check`, and `git status --short --branch`.

- [ ] **Step 4: Commit**

Commit with `build: add release packaging workflow`.

