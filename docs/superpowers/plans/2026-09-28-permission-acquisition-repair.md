# Permission Acquisition Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task in the existing session. A fresh whole-branch review follows implementation.

**Goal:** Keep permission preparation responsive and preserve every saved consumer of a moved folder.

**Architecture:** Snapshot records on MainActor, resolve immutable requests off-main, then reconcile references and conditionally publish renewals on MainActor. Controllers own cancellation and request generations before they suspend. Filesystem workers own security-scope leases until they actually finish.

**Tech Stack:** Swift tools 5.10, macOS 14, Foundation/AppKit/SwiftUI, XCTest, existing SwiftPM preflight.

**Spec:** `docs/superpowers/specs/2026-09-28-permission-acquisition-repair-design.md` (approved by the user).

## Global Constraints

- Work stays in the existing `feature/store-camera-shares` worktree.
- No merge, push, release, installation, or App Store submission is part of this repair.
- Keep the unrelated untracked watcher evidence untouched.
- Retain macOS 14 and Swift tools 5.10 compatibility and add no dependencies.
- Tests use isolated UserDefaults suites, never the real preferences domain.
- Run no concurrent build/test jobs; freeze product/test files during full preflight.
- Keep fail-closed canonical containment and operation-owned lease lifetimes.
- Do not promise that cancellation interrupts an OS filesystem call.
- Local commits are explicit, scoped checkpoints; never stage the whole worktree.

## Review Focus

1. A disconnected share blocks before availability checking: main-actor cancellation must still execute (Tasks 1 and 3).
2. A second selection arrives before an older permission request completes: no stale record or UI result may win (Tasks 1 and 3).
3. A moved parent is shared by session calibration and library rebuilding: both operation orders and relaunch must work (Task 2).
4. A consumer write fails after another succeeds: keep the old grant and prove retry recovery (Task 2).
5. A permission request is cancelled after scope acquisition: eventual cleanup must balance exactly, without ending a running worker's access (Tasks 1 and 3).

---

## Task 1: Separate record ownership from blocking resolution

**Files:**
- Modify `Sources/LiveAstroStudio/AuthorizedLocations.swift`.
- Create `Sources/LiveAstroStudio/AuthorizedLocationResolver.swift`.
- Modify `Tests/LiveAstroStudioTests/AuthorizedLocationsTests.swift`.
- Create `Tests/LiveAstroStudioTests/PermissionPreparationTests.swift`.

**Interfaces:** Introduce these nested types in AuthorizedLocations; Record becomes internal, Codable, Equatable, Sendable. Keep storage version 1 and the existing encoded record fields.

```swift
enum Request: Sendable { case key(String), url(URL) }
struct ResolutionInput: Sendable {
    let requests: [Request]
    let records: [String: Record]
    let policy: FileAccessPolicy
    let containerRoots: [URL]
    let backend: any BookmarkAccessing
}
struct GrantChange: Sendable {
    let key: String
    let original: Record?
    let replacement: Record
}
struct Relocation: Sendable {
    let key: String
    let original: Record
    let oldRoot: URL
    let newRoot: URL
}
struct PreparedAccess: Sendable {
    let results: [Result<FileAccessLease, Error>]
    let relocations: [Relocation]
    let changes: [GrantChange]
}
```

Main-actor API: `snapshot(_ requests: [Request]) throws -> ResolutionInput`,
`prepare(_ requests: [Request]) async throws -> PreparedAccess`,
`prepareSelection(_ url: URL, key: String) async throws -> PreparedAccess`,
`commit(_ changes: [GrantChange]) throws`. Selection preparation captures the
original record and a per-key request generation. Resolver has synchronous
`resolve(_ input: AuthorizedLocations.ResolutionInput) -> AuthorizedLocations.PreparedAccess`
called only by the detached boundary, plus a selection counterpart receiving URL,
key and captured input. Neither resolver receives UserDefaults or AppModel.

- [ ] **1. Add safe red tests on today's API.** Extend FakeBookmarkBackend's existing lock-protected event records to capture `Thread.isMainThread` for create, resolve, start and stop. Select/acquire on MainActor and assert create/resolve/start observations are all false. The current implementation should fail these assertions without blocking the runner. Preserve existing start/stop balance assertions.

```swift
XCTAssertFalse(backend.events.isEmpty)
XCTAssertFalse(backend.threadObservations.contains(true),
               "permission preparation must not perform bookmark I/O on main")
```

- [ ] **2. Run and record red.** From this worktree:

```bash
swift test -Xswiftc -warnings-as-errors --filter AuthorizedLocationsTests
```

Expected new thread-boundary assertion failures; distinguish these from compiler errors. Keep the log before migrating APIs.

- [ ] **3. Extract the resolver.** Move canonical containment, most-specific candidate search, broader-grant fallback, backend calls, suffix mapping and scope creation into AuthorizedLocationResolver. Use the captured original roots for all requests in one batch. Build proposed renewals instead of persisting them. Record relocation even when renewed bookmark creation fails; current access remains usable.

```swift
let input = try snapshot(requests)
let worker = Task.detached(priority: .userInitiated) {
    AuthorizedLocationResolver.resolve(input)
}
let prepared = await withTaskCancellationHandler {
    await worker.value
} onCancel: {
    worker.cancel()
}
try Task.checkCancellation()
return prepared
```

Check cancellation between blocking stages; release all locally owned successful scopes on thrown paths. Do not use a semaphore to await this task on main. A cancelled caller may wait internally for OS return, but its owning controller must relinquish UI ownership immediately.

- [ ] **4. Implement per-record publication.** Load the current envelope at commit time and apply only changes whose original still matches. Never persist a captured whole envelope. Selection requests additionally require their captured per-key generation to remain current.

```swift
for change in changes where envelope.records[change.key] == change.original {
    envelope.records[change.key] = change.replacement
}
try persist(envelope)
```

Keep malformed/unsupported storage failure behavior. Path-only direct/container fallback must still work when saved storage cannot be decoded; represent the storage failure in preparation rather than throwing before permitted path-only requests are considered.

- [ ] **5. Add blocking boundary tests.** Add a lock-protected fake canonicalizer seam alongside the bookmark backend. It records executor/thread, signals entry, and blocks only on a background thread. If accidentally invoked on main, record a failure and return immediately. Use XCTest async fulfillment for entry/release/completion, with a semaphore only inside the background fake and teardown always releasing it. Cover containment, initial bookmark creation, resolution and renewal independently. While each is parked, run a MainActor sentinel, cancel/reselect, then release. Assert the original bytes remain unchanged and every successful scope is eventually stopped once.

- [ ] **6. Verify existing semantics.** Migrate AuthorizedLocationsTests to the prepare/commit split. Keep original malformed storage, container symlink escape, missing-child containment, sibling-prefix exclusion, broader grant fallback, group failure and cross-executor lifetime assertions. Add overlapping old/new preparations: committing the older result after a new selection must preserve the new record. Run the two suites with warnings enforced. Do not retain synchronous production acquisition wrappers as a convenience.

Task 1 and Task 3's caller migration may need to stay in one compiling checkpoint; do not create a broken intermediate commit just to satisfy task numbering.

## Task 2: One reconciliation path for every moved-folder consumer

**Files:**
- Create `Sources/LiveAstroStudio/AppModel+LocationReconciliation.swift`.
- Modify `Sources/LiveAstroStudio/AppModel+FileAccess.swift`.
- Modify `Sources/LiveAstroStudio/AppModel.swift` (library rebuild).
- Modify `Sources/LiveAstroCore/Calibration/CalibrationLibrary.swift` only for conditional source-path updates if required.
- Modify `Tests/LiveAstroStudioTests/StorePreviewAccessTests.swift`.
- Modify `Tests/LiveAstroCoreTests/CalibrationLibraryTests.swift` if adding the conditional library API.

**Interfaces:** Define `LocationReferenceSnapshot` in the new extension file: optional capture/output URLs, a CalibrationSelection, optional flats/dark-flats URLs, and library sources `[UUID: String]`. Add `captureLocationReferences() -> LocationReferenceSnapshot` and `reconcileLocationReferences(_:prepared:) throws -> [AuthorizedLocations.GrantChange]` on AppModel. The returned changes are only those safe to commit; callers then call `authorizedLocations.commit` without another suspension. Reconciliation consumes Task 1's relocation facts and does not resolve unrelated grants.

- [ ] **1. Add cross-consumer red tests before replacing the old batches.** Extend the existing `fixture()`, `directory`, and real `writeFITS` helpers. Build a `.bias` library entry from one synthetic FITS source, set the same source as session dark-flats, authorize input/output, physically move the source, and set `backend.moves[old.path] = moved`. In one test acquire session access then rebuild; in the other rebuild then acquire. Wait for actual calibration completion with a watchdog that fails, not skips. Assert:

```swift
XCTAssertEqual(model.sessionDarkFlatsFolder?.path, moved.path)
XCTAssertEqual(model.libraryEntries.first?.sourcePath, moved.path)
XCTAssertEqual(defaults.string(forKey: "StorePreview.darkFlatsPath"), moved.path)
XCTAssertNil(model.errorMessage)
```

Create a fresh AppModel using the same isolated defaults, configuration and library directory, await restoration, repeat the operation, and assert moved paths again. Record the current branch's wrong-path or authorization failures before the fix; do not accept missing fixtures as the red result.

- [ ] **2. Implement a pure relocation helper.** Given a URL and successful relocations, sort old roots by descending component count, choose the first component-wise containment match, append the suffix to newRoot, and return the result. Reject cross-host/non-file mappings. Use it only when the current consumer value equals its captured value. Library entries require matching UUID and original source path; never recreate a removed entry.

```swift
if currentPath == capturedPath {
    proposedPath = relocatedURL.path
}
```

Add a conditional library update API if the existing UUID-only setter cannot enforce the old-path check at write time. It must preserve all other entry metadata and skip missing or changed entries.

- [ ] **3. Persist consumers before renewal.** Compute the complete reconciliation first. Persist conditional library changes, then calibration/session preference changes, then return eligible record changes. If a dependent write throws, do not commit its renewal; propagate a folder-access failure while retaining the old bookmark. If a new old-root reference appeared after the snapshot, withhold that grant's renewal until another batch can reconcile it. Check current record identities before touching any dependent reference.

- [ ] **4. Add recovery and race tests.** Cover moved parent/children; overlapping parent/specific grants; a denied unrelated library grant; a removed or changed library entry; a newly added old-root reference; and a reselected dark-flats folder. Inject a throwing persistence closure at the reconciliation boundary (defaulting to the real library update) and independently fail bookmark renewal. After removing the injected failure, repeat acquisition and recreate AppModel; assert no re-selection is needed. Prove the old bookmark bytes were retained when required.

These tests establish ordering/retry recovery. UserDefaults does not provide a cross-file durable transaction; do not claim arbitrary power-loss atomicity from call ordering or from a same-process fresh AppModel.

- [ ] **5. Harden the existing fake before parallel reads.** Move PreviewBookmarkBackend's `denied`, `moved`, and `moves` properties behind its existing NSLock, not just its counters. Copy configured values under lock and release the lock before any blocking test seam. Run AuthorizedLocationsTests, PermissionPreparationTests, StorePreviewAccessTests and affected CalibrationLibraryTests sequentially with warnings enforced.

## Task 3: Wire asynchronous access through operation ownership

**Files:**
- Modify `Sources/LiveAstroStudio/AppModel+FileAccess.swift`, `AppModel.swift`, `AppSurface.swift`.
- Modify `Sources/LiveAstroStudio/CameraShareAuthorization.swift`, `LiveSourceController.swift`, `ImportController.swift`.
- Modify `Sources/LiveAstroStudio/ControlView.swift`, `CaptureSettingsView.swift`, `CalibrationSection.swift`.
- Modify affected app tests, including `StorePreviewAccessTests.swift`, `StoreCameraShareTests.swift`, and AppSurface controller test fixtures.

**Interfaces:** Convert the existing acquisition methods and three AppSurface closures to async throws, preserving their result types:

```swift
var acquireOperationAccess: (@MainActor (URL) async throws -> OperationFileAccess)?
var acquireCameraShare: (@MainActor (CameraShareKind, Bool) async throws -> FileAccessLease?)?
var acquireLocationAccess: (@MainActor (URL) async throws -> SessionDirectoryAccess)?
```

AppModel `selectLocation`, `selectSourceFolder`, `setCalibrationFolder` await selection preparation. `acquireReadableLocation`, `acquireOutputLocation`, `acquireOperationAccess` and finished-session acquisition await the shared snapshot/resolve/reconcile/commit path. CameraShareAuthorization keeps the picker on main but makes `acquire(_:replacing:)` async throws. UI action wrappers own tasks rather than blocking. Do not hide permission errors with `try?`.

- [ ] **1. Put ownership before suspension.** In startSession establish inputPreparationID, pendingStartCompletion, preparing status and a task before acquisition. ImportController sets importPrepareGeneration/in-flight state before access. LiveSourceController increments detectionGeneration and sets isDetecting before access or picker entry. Restoration sets accessRestorationID before any worker starts. Calibration and output actions need equivalent task identity/busy ownership.

```swift
let id = UUID()
inputPreparationID = id
pendingStartCompletion = completion
inputPreparationTask = Task { [weak self] in
    guard let self else { return }
    do {
        let access = try await self.acquireOperationAccess(input: folder)
        try Task.checkCancellation()
        guard self.inputPreparationID == id else { return }
        self.pendingFileAccess = access
        // Continue through the existing off-main baseline/availability worker.
    } catch {
        guard self.inputPreparationID == id else { return }
        self.cancelSessionInputPreparation()
        if !(error is CancellationError) { self.reportFileAccess(error) }
    }
}
```

Preserve completion-exactly-once behavior; reuse the existing cancellation owner rather than invoking the captured completion a second time. Revalidate folder/filter/mode and operation ownership at each handoff. Reconciliation must itself check captured selection generation before publishing, not rely solely on the caller checking after await.

- [ ] **2. Keep blocking follow-on work off-main.** Move ControlView output footprint traversal and output-directory creation into workers retaining the acquired lease. NSWorkspace opening stays on main. SessionDirectoryAccess must retain an already-canonicalized URL or canonicalize in its access worker; remove synchronous resolvingSymlinksInPath from publishFinishedSession and finished-session matching. Do not widen retained-session authorization to sibling directories.

- [ ] **3. Add caller-level cancellation regressions.** For start, restoration, import, camera preparation and calibration rebuild, park bookmark resolution before availability. Cancel or change the relevant selection, allow the main-actor sentinel to run, release the fake, and assert no session/import/relay starts, no newer error is overwritten, and busy state clears for the owning request only. Check one completion on cancelled Start, zero duplicate Starts, and preservation of a newer request. For selected-folder actions park bookmark creation and make a second choice; assert the second wins. Cover the direct policy as well as sandboxed policy.

- [ ] **4. Run focused tests and audit all call sites.** Use:

```bash
rg -n 'authorizedLocations\.|acquireOperationAccess|acquireReadableLocation|acquireOutputLocation|acquireCameraShare|resolvingSymlinksInPath' Sources/LiveAstroStudio
swift test -Xswiftc -warnings-as-errors --filter 'AuthorizedLocationsTests|PermissionPreparationTests|StorePreviewAccessTests|StoreCameraShareTests|ImportControllerTests|LiveSourceControllerTests'
```

Check discovered test class names against the actual test inventory before trusting the filtered count. Update adjacent source-text regression checks only when their contract genuinely changed; replace timing assumptions with async completion assertions. No bare AppModel construction against real defaults.

- [ ] **5. Commit the compiling, focused-green repair.** Inspect `git diff --check`, file inventory and diff first. Stage only files from Tasks 1–3. Commit message records the two defects, observed red results, focused totals, and that full preflight remains pending. Leave all unrelated evidence untracked.

## Task 4: Falsification, independent review, and frozen full gate

**Files:** the repair's test files and existing `docs/store-preview-smoke.md`; evidence belongs in the existing ignored sandbox-preview progress directory, not shipped product sources.

- [ ] **1. Falsify the specific new protections.** With byte-for-byte backups of every temporarily modified file, independently bypass cross-consumer reconciliation, bypass generation rejection, and move the resolver onto main. Each must fail its corresponding regression. The on-main mutation must use the nonblocking thread probe rather than the semaphore gate. Restore and compare bytes after each experiment; do not overwrite unrelated work.
- [ ] **2. Request a fresh whole-branch correctness review.** Review the final diff from main, focusing on ownership at await boundaries and reference persistence. No build/test runs in parallel with the reviewer; read-only review is fine. Fix any substantiated findings with tests before freezing.
- [ ] **3. Update smoke instructions.** Document cancellation of stalled permission preparation, shared moved calibration folder recovery, and the cancellation limitation: UI cancellation does not forcibly interrupt kernel I/O. Do not claim hardware execution on newly built bytes.
- [ ] **4. Freeze and run one full gate.** Record HEAD, complete tracked/untracked file inventory, and hashes of all scoped product/test files. Confirm no existing SwiftPM/xctest job, then run:

```bash
bash Scripts/preflight.sh
```

Keep the complete log and actual exit status. No edits or competing builds during the run. Recheck all hashes afterwards. Report duration, counts, named failures/skips, debug counted warnings, and release/test compiler-enforced Swift warning results. This is new evidence; the earlier 1547-test gate belongs to ebbb581 only.
- [ ] **5. Handoff.** Report fix/review/falsification/gate results separately, list remaining manual checks if any, and keep draft PR #40 unmerged. No push or public action is implied by a green run.

## Execution choice

Recommended: native implementation in this session. These tasks share permission
interfaces and operation ownership, so parallel implementation would cause
overlapping edits. Use one independent whole-branch reviewer after the repair,
then the frozen gate. Await the user's plan approval before product edits.
