# Mac App Store Edition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a separately packaged, sandbox-safe Mac App Store edition while preserving the full direct-download edition.

**Architecture:** Reuse the existing Store Preview sandbox boundary, but replace the informal preview-only bundle identity with an explicit distribution kind that recognizes the App Store target. Add a dedicated App Store packaging/upload path with App Sandbox, security-scoped bookmarks, network-client access, and App Store signing; keep GraXpert and public-stream automation available only to the direct edition.

**Tech Stack:** Swift Package Manager, Swift/AppKit/SwiftUI, macOS App Sandbox, security-scoped bookmarks, `codesign`, `productbuild`, Transporter or Xcode Organizer, XCTest, App Store Connect.

**Spec:** `docs/superpowers/specs/2026-10-03-mac-app-store-edition-design.md`

## Global Constraints

- The App Store edition uses native stacking, camera-share relay, display/broadcast windows, OBS status, and OBS local recording.
- The App Store edition does not expose GraXpert, one-click public streaming, or scene automation.
- Direct GitHub distribution retains its existing full feature set and bundle identifier.
- App Store file access comes only from user-selected URLs and app-scoped security bookmarks.
- App Store entitlements are limited to App Sandbox, user-selected read/write, app-scoped bookmarks, and network client.
- The App Store target requires macOS 14 or later and a separately registered bundle identifier.
- No App Store upload occurs before a local sandbox build and TestFlight/internal validation pass.

## Review Focus

- A mounted SMB share is visible but not authorized: camera discovery must not enumerate or read it until the user selects it; test in `StoreCameraShareTests`.
- A bookmark is stale after restart or the selected folder moves: restoration must report/recover access instead of silently using the old path; test in `StorePreviewAccessTests`.
- A user selects an output folder but not a source folder: the App Store build must block the session with a specific access error, not fall back to the home directory; test in `PermissionPreparationTests`.
- OBS is reachable but already streaming or recording: App Store controls must remain read-only or local-recording-safe and never issue public-stream commands; test in `OBSConnectionCheckTests` and `OBSLocalRecordingTests`.
- The App Store bundle is signed with an extra entitlement or wrong identifier: packaging must fail before upload; test in `Scripts/tests/test_store_preview.py` and the new packaging smoke test.

---

### Task 1: Make distribution kind explicit

**Files:**
- Modify: `Sources/LiveAstroStudio/StorePreviewConfiguration.swift`
- Modify: `Sources/LiveAstroStudio/AppModel+FileAccess.swift`
- Modify: `Sources/LiveAstroStudio/AppSurface.swift`
- Modify: `Sources/LiveAstroStudio/LiveSourceController.swift`
- Test: `Tests/LiveAstroStudioTests/StoreDistributionConfigurationTests.swift`

**Interfaces:**
- Produce `enum DistributionKind: String, Sendable { case direct, storePreview, appStore }`.
- Produce `StorePreviewConfiguration.distribution: DistributionKind` and computed `isSandboxedDistribution`.
- Preserve `isStorePreview` as a compatibility computed property for existing tests, returning true only for `.storePreview`.
- Treat `.appStore` and `.storePreview` identically for file-access leases, container roots, camera authorization, and restricted capabilities.

- [ ] **Step 1: Write failing configuration tests.** Assert bundle IDs `com.pauldavis.liveastrostudio`, `com.pauldavis.liveastrostudio.store-preview`, and `com.pauldavis.liveastrostudio.appstore` map to the expected kinds; assert app-store and preview configurations are sandboxed while direct is not.
- [ ] **Step 2: Run the focused tests.** Run `swift test --filter StoreDistributionConfigurationTests`; expected failure because the enum and mapping do not exist.
- [ ] **Step 3: Implement the distribution enum and mapping.** Update `StorePreviewConfiguration.init(bundleIdentifier:containerRoot:)`, add `isSandboxedDistribution`, and replace file-access checks that currently use `isStorePreview` with the sandboxed predicate without changing direct behavior.
- [ ] **Step 4: Add source-controller capability checks.** Ensure `.appStore` follows the existing authorized-camera-share path and cannot use direct-volume discovery before authorization.
- [ ] **Step 5: Run focused and adjacent tests.** Run `swift test --filter 'StoreDistributionConfigurationTests|StorePreviewAccessTests|StoreCameraShareTests'`; expected PASS.
- [ ] **Step 6: Commit.** `git add Sources Tests && git commit -m "feat: model App Store distribution explicitly"`.

### Task 2: Lock down App Store capabilities in the UI and runtime

**Files:**
- Modify: `Sources/LiveAstroStudio/CaptureSettingsView.swift`
- Modify: `Sources/LiveAstroStudio/ControlView.swift`
- Modify: `Sources/LiveAstroStudio/BroadcastSettingsView.swift`
- Modify: `Sources/LiveAstroStudio/AppModel.swift`
- Modify: `Sources/LiveAstroStudio/ImportController.swift`
- Modify: `Sources/LiveAstroStudio/Resources/Help.md`
- Test: `Tests/LiveAstroStudioTests/StoreDistributionCapabilityTests.swift`

**Interfaces:**
- Consume `AppModel.distribution.distribution` and `isSandboxedDistribution` from Task 1.
- Produce one capability predicate for public-stream/scene automation and one for external processors; both return false for `.appStore` and `.storePreview`, true for `.direct`.

- [ ] **Step 1: Write failing capability tests.** Assert App Store hides or disables GraXpert, Go Live, End Broadcast, and scene automation while retaining OBS status/local recording; assert direct mode retains all controls.
- [ ] **Step 2: Run the focused tests.** Run `swift test --filter StoreDistributionCapabilityTests`; expected failure on the new predicates and UI-facing state.
- [ ] **Step 3: Implement capability predicates.** Keep restrictions centralized in distribution configuration, not scattered bundle-ID comparisons.
- [ ] **Step 4: Apply predicates to UI and runtime commands.** Hide/disable prohibited controls, reject prohibited command calls defensively in `AppModel`/broadcast code, and leave direct behavior unchanged.
- [ ] **Step 5: Update Help text.** Add a clear App Store note: detach the broadcast window and operate public streaming in OBS; direct edition includes additional controls and GraXpert.
- [ ] **Step 6: Run focused tests.** Run `swift test --filter 'StoreDistributionCapabilityTests|OBSConnectionCheckTests|OBSLocalRecordingTests|StoreProcessorSettingsTests'`; expected PASS.
- [ ] **Step 7: Commit.** `git add Sources Tests && git commit -m "feat: enforce App Store capability boundary"`.

### Task 3: Add the App Store entitlement and packaging pipeline

**Files:**
- Create: `Scripts/AppStore.entitlements`
- Create: `Scripts/package_app_store.sh`
- Modify: `Scripts/tests/test_store_preview.py`
- Create: `Scripts/tests/test_app_store_package.py`
- Modify: `README.md`

**Interfaces:**
- `Scripts/package_app_store.sh --version VERSION --identity IDENTITY --installer-identity IDENTITY [--output PATH]` produces a signed App Store upload package without modifying `dist/`.
- The script validates the app bundle identifier `com.pauldavis.liveastrostudio.appstore`, display name, exact entitlements, resource-bundle layout, arm64/x86_64 build presence, and installer signature.

- [ ] **Step 1: Write packaging contract tests.** Stub the build/signing commands and assert the script selects the App Store bundle ID, uses `AppStore.entitlements`, rejects missing identities, rejects extra entitlements, and does not write under `/Applications`.
- [ ] **Step 2: Run packaging contract tests.** Run `python3 -m unittest Scripts/tests/test_app_store_package.py`; expected failure because the script and entitlement file do not exist.
- [ ] **Step 3: Create minimal App Store entitlements.** Include only `com.apple.security.app-sandbox`, `com.apple.security.files.user-selected.read-write`, `com.apple.security.files.bookmarks.app-scope`, and `com.apple.security.network.client`.
- [ ] **Step 4: Implement isolated packaging.** Build universal release output into a fresh scratch path, assemble the App Store bundle, set `CFBundleIdentifier` to `com.pauldavis.liveastrostudio.appstore`, set the App Store distribution configuration at runtime, sign nested resources and the app, then create an installer package with `productbuild` using the App Store installer identity.
- [ ] **Step 5: Implement fail-closed verification.** Parse signed entitlements and bundle metadata; fail on missing/extra entitlement, wrong bundle ID, unsigned nested resource, or wrong installer authority.
- [ ] **Step 6: Run packaging tests and a real dry-run.** Run `python3 -m unittest Scripts/tests/test_app_store_package.py Scripts/tests/test_store_preview.py`; then run the script with real identities into a temporary output path and inspect `codesign --display --entitlements :-` and `pkgutil --check-signature`.
- [ ] **Step 7: Document the command.** Add the exact local build command, required Apple certificates, and the no-upload boundary to README.
- [ ] **Step 8: Commit.** `git add Scripts README.md && git commit -m "build: add Mac App Store packaging"`.

### Task 4: Validate sandbox behavior end to end

**Files:**
- Modify: `Tests/LiveAstroStudioTests/PermissionPreparationTests.swift`
- Modify: `Tests/LiveAstroStudioTests/StorePreviewAccessTests.swift`
- Modify: `Tests/LiveAstroStudioTests/StoreCameraShareTests.swift`
- Modify: `Tests/LiveAstroStudioTests/OBSConnectionCheckTests.swift`
- Create: `Tests/LiveAstroStudioTests/AppStoreSandboxSmokeTests.swift`

**Interfaces:**
- Consume the explicit `.appStore` distribution configuration from Task 1 and the capability predicates from Task 2.
- Produce a repeatable smoke-test checklist for the packaged App Store bundle before TestFlight upload.

- [ ] **Step 1: Add failing edge-case tests.** Cover stale bookmarks, denied source/output access, camera-search cancellation, a mounted-but-unselected SMB path, OBS already streaming, and direct-vs-App-Store capability differences.
- [ ] **Step 2: Run focused tests to establish failures.** Run the five affected test filters; expected failures identify missing App Store mapping or permission handling.
- [ ] **Step 3: Implement only the smallest fixes required.** Keep all access changes behind sandboxed distribution predicates and preserve direct-mode paths.
- [ ] **Step 4: Run the focused suite.** Run `swift test --filter 'PermissionPreparationTests|StorePreviewAccessTests|StoreCameraShareTests|OBSConnectionCheckTests|AppStoreSandboxSmokeTests'`; expected PASS with no skips introduced by the new code.
- [ ] **Step 5: Build and launch the signed App Store bundle locally.** Select a temporary source/output folder through the UI, restart, restore bookmarks, run a small native stack, detach the broadcast window, and confirm prohibited controls are absent.
- [ ] **Step 6: Commit.** `git add Tests Sources && git commit -m "test: cover App Store sandbox workflows"`.

### Task 5: App Store Connect and TestFlight readiness

**Files:**
- Modify: `README.md`
- Create: `docs/app-store/mac-app-store-submission.md`

**Interfaces:**
- Produce a submission checklist tied to bundle ID `com.pauldavis.liveastrostudio.appstore`, the package output from Task 3, and the smoke tests from Task 4.

- [ ] **Step 1: Document App Store Connect setup.** Record app-record creation, bundle-ID registration, SKU, macOS platform, pricing, availability, privacy answers, screenshots, and review notes.
- [ ] **Step 2: Document TestFlight acceptance checks.** Include clean install, bookmark restoration, Seestar/ASIAIR authorization, native stacking, detached OBS capture, local recording, and restricted-feature messaging.
- [ ] **Step 3: Run the release gate.** Run `Scripts/preflight.sh` on the complete branch; expected zero build warnings, zero failures, and the recorded environment-gated skip list.
- [ ] **Step 4: Upload only after the gate and smoke test pass.** Use Transporter or Xcode Organizer; do not submit for review from an unverified local package.
- [ ] **Step 5: Commit.** `git add README.md docs/app-store/mac-app-store-submission.md && git commit -m "docs: add Mac App Store submission checklist"`.

## Self-review

- **Spec coverage:** Distribution kind and separate target are covered by Tasks 1 and 3; file access and camera authorization by Tasks 1 and 4; processing and OBS boundaries by Task 2; signing/upload flow by Tasks 3 and 5; TestFlight and review readiness by Tasks 4 and 5.
- **Placeholder scan:** No TBD/TODO steps or unspecified validation commands remain. The final bundle identifier is the concrete proposed value `com.pauldavis.liveastrostudio.appstore`; Apple registration remains an external prerequisite, not an implementation placeholder.
- **Type consistency:** `DistributionKind`, `StorePreviewConfiguration.distribution`, and `isSandboxedDistribution` are introduced in Task 1 and consumed consistently by later tasks. Packaging uses the same App Store bundle ID.
- **Review focus coverage:** Each five-item review-focus risk has a named test location and an owning task.
- **Scope check:** The work is one distribution project with separate configuration, packaging, runtime capability, and validation slices; each task produces an independently testable deliverable.
