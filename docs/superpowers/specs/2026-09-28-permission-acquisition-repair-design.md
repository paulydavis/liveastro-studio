# Responsive permission acquisition and shared moved-folder recovery

## Purpose and scope

Repair the two whole-branch review findings on draft PR #40 at `ebbb581`:
permission acquisition can block the main actor before the existing background
availability checks, and renewal of a moved grant can strand references held by
another consumer. The user approved moving permission work off the UI thread,
rejecting obsolete results, updating both consumer families, and regression
tests for both defects.

Work stays in the existing `feature/store-camera-shares` worktree. No merge,
push, release, installation, or App Store submission is part of this repair.
Keep the unrelated untracked watcher evidence untouched. Retain macOS 14 and
Swift tools 5.10 compatibility and add no dependencies.

## Chosen approach

Split acquisition into a main-actor snapshot, off-main resolution, and a guarded
main-actor application of the result. Preserve the existing permission rules and
operation-owned leases. Centralize moved-reference reconciliation in AppModel
instead of having session acquisition and library rebuilding maintain separate
lists of consumers.

A lexical containment shortcut alone is insufficient: bookmark resolution and
creation can also block. Merely moving the current mutable AuthorizedLocations
object into detached tasks would introduce races. A permanent old-path alias
table is also unnecessary; retaining the old bookmark until dependent references
are saved provides a recoverable ordering without a second path database.

## 1. Scheduling and ownership

AuthorizedLocations retains main-actor ownership of its saved records. It creates
immutable, Sendable requests containing the policy, container roots, relevant
record snapshot, and backend. A worker performs canonical containment checks,
bookmark creation/resolution, scope acquisition, and renewal preparation. No
filesystem metadata lookup, symlink resolution, or bookmark backend call runs on
the main actor. The worker returns leases and proposed record changes; it does
not write the captured envelope back to UserDefaults.

Applying a proposed record change checks that the current record still equals
the record from which it was derived. Merge changes per key, never replace a
newer envelope with an old snapshot. Explicit selection replacement uses its own
request generation so an older picker result cannot replace a newer choice.

Start, restoration, import, camera discovery, calibration build/rebuild, output
operations, and finished-session access must await this boundary. AppSurface
permission closures become asynchronous. Folder pickers and UI mutation remain
on the main actor. Existing downstream file reading remains off-main. Audit
SessionDirectoryAccess construction as well: retaining a finished directory
must not introduce another on-main symlink lookup.

Set busy/preparing ownership before the first suspension. On resumption, check
cancellation and operation generation before starting a pipeline, changing a
selection, saving a renewal, or showing an error. Changing a relevant selection
invalidates preparation that captured it. An obsolete result is dropped, not
reported as a current failure.

Cancellation does not promise to interrupt an OS filesystem call. The UI can
cancel immediately, but the worker retains any acquired security scope until its
actual work returns. Late results release their leases without publishing state.
Do not replace this with a main-thread wait or hold a state lock across I/O.

## 2. Shared moved-folder reconciliation

Every acquisition entry point uses the same reconciliation path. Its captured
reference inventory includes capture/output selections, legacy dark/flat/bias
paths, session flats/dark-flats folders, and calibration-library source
directories identified by entry UUID. Successful resolution returns the grant's
old root, resolved root, and the original record identity.

Apply relocation to every still-matching reference covered by that grant, using
path components and preserving the child suffix. Prefer the most specific
successful covering grant when grants overlap. Never rewrite an unrelated path,
a newly selected value, or a removed/replaced library entry. References added
while acquisition is suspended are not silently guessed into the old inventory;
if they still depend on the old grant, retain that grant for a subsequent batch.

Both session acquisition and library rebuild invoke this reconciliation. A
library-only failure must not block an unrelated session on grounds of access to
that library folder: only resolve permissions the requested operation needs.
Relocation information from those successful resolutions updates all dependent
references without reading their image contents.

### Persistence and partial failure

Persist dependent path changes before publishing a renewed bookmark whose
display root no longer matches the old references. If dependent persistence
fails, keep the old bookmark record and report the failure; never publish a new
root that strands a remaining old path. Already saved dependent paths may remain
updated: the old bookmark resolves to the new root, and acquisition already
supports matching requests against that resolved root. This ordering also keeps
the next launch recoverable after interruption between writes.

The same rule applies if bookmark renewal itself fails: keep valid current
access and the old saved grant, as today. Do not claim a multi-file atomic
transaction. Tests must demonstrate recoverability from partial persistence and
must verify both consumer families after relaunch.

## 3. Failure behavior and compatibility

Keep fail-closed canonical containment, including symlink escapes and missing
children; never substitute lexical containment to avoid I/O. Corrupt or unknown
bookmark storage is not overwritten. Broader-grant fallback and output-first
operation error precedence remain intact. Successful leases live with workers,
relays, pipelines, and finished-session readers for their existing lifetimes.

The direct distribution retains its current permission policy and processing
behavior. Async preparation must not introduce duplicate starts, orphan completion
callbacks, or an uncancellable busy state in either distribution. Tests use
isolated UserDefaults suites, never the real preferences domain.

## 4. Regression evidence

Add deterministic tests before the fixes, using blocking probes and explicit
release barriers rather than sleeps as synchronization:

1. Block containment or bookmark resolution before availability checking; prove
   it executes off-main and the main actor can process cancellation/reselection.
   Release the worker and prove no stale state, error, pipeline start, or renewed
   record is published. Always release probes during teardown.
2. Block bookmark creation/renewal and cover the same ownership boundary. Verify
   every successful scope acquisition is eventually balanced, including errors.
3. Share one folder between a library source and session dark-flats; move it.
   Acquire session access first, then rebuild; repeat in reverse order. Assert
   both persisted references resolve and a fresh AppModel remains usable.
4. Exercise a moved parent with child references, overlapping grants, unrelated
   failed grants, selection replacement, and a removed library entry.
5. Inject dependent persistence failure and renewal failure. A second operation
   and relaunch must recover without requiring the user to reselect the folder.
6. Keep existing containment, malformed-storage, restoration, cancellation,
   camera share, calibration, import, and finished-session lifetime tests green.

The initial tests must fail against the relevant broken behavior, not merely a
changed API. If a regression cannot be demonstrated safely in-process (for
example an intentionally blocked main actor), use a bounded subprocess or assert
the worker execution boundary directly; do not hang the test runner.

Run focused suites first with Swift compiler warnings enforced, then one full
preflight on a frozen final tree. Run no concurrent build/test jobs. Attribute
results to the exact tested revision plus diff; report skips separately. A green
test run establishes these exercised contracts, not that every stalled network
filesystem call can be interrupted.

## Review checkpoint

This document specifies the repair, not its completion. After the user's review,
write the implementation plan with exact API changes and test steps. Product
implementation and its verification follow that plan; PR #40 stays draft.
