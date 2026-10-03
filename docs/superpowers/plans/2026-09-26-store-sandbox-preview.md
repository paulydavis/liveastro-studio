# Store Sandbox Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Produce a separate sandboxed native-capture preview that remembers authorized input/calibration/output locations across launches.

**Architecture:** App-side authorized-location storage wraps macOS security-scoped bookmarks in reference-owned leases. App/controller boundaries retain leases for asynchronous work and post-session completion; core pixel processing is unchanged. A separate packaging script produces a labelled sandboxed preview with isolated identity/storage.

**Tech Stack:** Swift 5.10 package, macOS 14+, SwiftUI/AppKit, Foundation bookmarks, XCTest, codesign.

**Spec:** `docs/superpowers/specs/2026-09-26-store-sandbox-preview-design.md`

## Global Constraints

- Work only in the current isolated worktree on `feature/store-sandbox-preview`, base `1c7a657`.
- No modifications to the installed app, real preferences, original FITS files or other worktrees.
- No changes to stacking, registration, calibration arithmetic or rejection math.
- Preview bundle identifier: `com.pauldavis.liveastrostudio.store-preview`; name: `LiveAstro Store Preview`.
- Direct distribution retains existing paths and behavior; no implicit migration.
- Folder permission failure is not empty-folder success. No broad exceptions or Full Disk Access workaround.
- No concurrent builds/tests. Use isolated UserDefaults suites and temporary fixture paths in tests.
- Local implementation commits are permitted for review checkpoints; no push, merge, release or account changes.

## Task 1: Authorized-location storage and owned leases

**Files:** Create `Sources/LiveAstroStudio/AuthorizedLocations.swift` and `Tests/LiveAstroStudioTests/AuthorizedLocationsTests.swift`.

**Interfaces:** Define `FileAccessLease` (immutable resolved `url: URL`, reference-owned cleanup), `BookmarkAccessing` (create/resolve/start/stop OS boundary), and `AuthorizedLocations` initialized with `UserDefaults`, sandbox policy, container roots and injectable backend. Main-actor store methods: `select(_ url: URL, key: String) throws -> FileAccessLease`, `acquire(key: String) throws -> FileAccessLease`, `acquire(url: URL) throws -> FileAccessLease`, and `displayURL(key: String) -> URL?`. Key strings used downstream: `capture`, `output`, and `source:<standardized URL absoluteString>` for calibration/rebuild sources. Persist bookmark records, not live leases. Direct mode URL acquisition passes through; sandbox mode never treats a bare external path as authorization.

- [ ] Write tests using a fake OS bookmark backend only; keep real store/persistence/lease behavior. Assert fresh-store restore, stale renewal/moved URL, denied resolve preserving record, failed select preserving old grant, independent leases outliving selection changes, balanced successful starts/stops, known container access, external bare-path refusal, and parent grants covering later child files but not sibling-prefix paths.

```swift
let held = try store.select(input, key: "capture")
let reopened = AuthorizedLocations(/* same isolated defaults and backend */)
let restored = try reopened.acquire(key: "capture")
XCTAssertEqual(restored.url, input)
// Replacing a persisted selection must not stop held access.
withExtendedLifetime(held) { XCTAssertEqual(backend.stopCount, 0) }
```

- [ ] Run `swift test -c release -Xswiftc -warnings-as-errors --filter AuthorizedLocationsTests`; establish red behavior against minimal compiling stubs, then implement and rerun.
- [ ] Use macOS `.withSecurityScope` bookmarks, `.withoutUI` resolution, stale renewal after access succeeds; stop only for a successful start. Known app-container roots bypass external bookmarks. Preserve old records on any failed replacement. Reject malformed/version-unknown storage without writing over it.
- [ ] Self-review, record exact red/green evidence, commit only this task's files. Coordinator obtains task review before consumers depend on it.

## Task 2: Distribution and operation lifetime integration

**Files:** Create `Sources/LiveAstroStudio/StorePreviewConfiguration.swift`, `Sources/LiveAstroStudio/AppModel+FileAccess.swift`, `Tests/LiveAstroStudioTests/StorePreviewAccessTests.swift`. Modify `AppModel.swift`, `AppSurface.swift`, `ImportController.swift`, `LiveSourceController.swift`, `CaptureSettingsView.swift`, `CalibrationSection.swift`, `MainView.swift` and preview-gated controls as required.

**Consumes:** Task 1 store/leases. **Produces:** `AppModel.isStorePreview`, selected output display, `chooseSessionOutputFolder()`, centralized selected-location registration and explicit operation-owned leases. Configuration selects preview only for its bundle ID (injectable in tests); defaults to direct otherwise.

- [ ] Write red app tests: preview Start/Import without output authorization stays idle; direct defaults unchanged; denied capture fails before baseline; changing output cannot redirect running/post-session work; calibration workers and completion retain leases; restored selection uses resolved URL; unavailable selection remains visible.

```swift
model.startSession { started = $0 }
XCTAssertEqual(started, false)
XCTAssertFalse(model.isRunning)
XCTAssertFalse(model.isPreparingSessionInput)
XCTAssertNotNil(model.errorMessage)
```

- [ ] Add config with injectable container roots; production preview uses its own container for relay/library/catalog and a required remembered output selection. Never instantiate the direct user's calibration library before choosing the preview configuration.
- [ ] Route picker results to store selection before metadata enumeration. Restore bookmarked capture/calibration paths during load; report reauthorization instead of raw-path fallback. Keep existing SessionSettings schema compatible.
- [ ] Capture lease groups before native baseline/metadata or import enumeration. Workers capture the group, so cancellation cannot revoke it while work is still running. Capture destination URL once per operation. Retain post-session source/output group until post-session work is retired; completion/restack tasks capture it independently.
- [ ] Calibration folder selection/build/rebuild obtains the correct grant before listing; generated masters stay private. Permission errors abort explicitly rather than silently producing uncalibrated output.
- [ ] Add output picker/card visible only in preview. Disable or explain auto-volume discovery, external processor/OBS/night-tint controls not yet proven in preview. Also guard underlying entry methods, not UI alone. Direct mode remains unchanged.
- [ ] Run targeted app/store/input/import/calibration/completion tests with release warnings-as-errors, review, then commit the task files.

## Task 3: Signed preview packaging and verification

**Files:** Create `Scripts/package_store_preview.sh`, `Scripts/StorePreview.entitlements`, `docs/store-preview-smoke.md`; update Help only if necessary for preview-specific permission messages.

**Consumes:** Task 2 bundle-selected configuration. **Produces:** local standalone `.app` outside `/Applications`, not a store upload or public release.

- [ ] Script behavior test: bad arguments fail before building; supplied temporary build/output paths are used; no shared release scratch deletion. Test the actual invocation through a stub toolchain if needed, then run real build/sign verification.

```bash
codesign --verify --deep --strict "$preview_app"
codesign -d --entitlements :- "$preview_app"
# Assert sandbox, user-selected read/write and bookmark entitlements in parsed plist.
```

- [ ] Package with its own mktemp scratch, resources and separate identity; use an existing appropriate signing identity only. No account/provisioning changes without approval. Confirm signed bundle ID/name and sandbox entitlement before launch.
- [ ] Run the full preflight serially on a frozen file manifest. Obtain whole-branch review; fix blocking findings with regression coverage.
- [ ] Prepare copies of six real Seestar subs and scratch output; checksum originals/copies. Launch preview only after gate/review; stop for the operator to select folders through macOS dialogs.
- [ ] Manual acceptance instructions: authorize input/output/calibration, process/End, quit/relaunch and reuse access, add a new copied sub, exercise missing-location/reselection, and check post-End completion via clearly labelled deterministic fixture if normal End completes fully. Record manual steps as pending until actually observed.

## Plan self-review

Task 1 owns bookmark semantics; Task 2 alone owns app/controller state and lifetime. Task 3 consumes a fixed bundle identity and never changes production processing. All tasks use the same direct-vs-preview rule and macOS floor. UI screenshots or fake bookmark tests cannot establish OS permission persistence; the signed separate-process manual check remains a required boundary. No public distribution action is included.
