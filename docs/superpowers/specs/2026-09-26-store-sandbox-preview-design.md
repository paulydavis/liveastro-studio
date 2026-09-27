# Store sandbox preview: persistent folder access

Status: approved by the operator on 26 September 2026. Implementation of this preview is authorized; public submission, merge and installation over the direct edition are not.

## Goal and boundary

Prove that LiveAstro's native capture workflow works in a genuinely sandboxed Mac app: choose input, calibration and output locations; stack copied subs; End; finish an incomplete clean stack; quit and reopen with permissions preserved. Keep the shipped GitHub edition and its processing algorithms unchanged.

The operator approved choosing an output folder once and remembering it. The proof build is visibly named **LiveAstro Store Preview**, uses a separate bundle identifier (`com.pauldavis.liveastrostudio.store-preview`), preferences and container, and is installed only in a development location. It must not read the direct edition's settings or migrate/delete its data implicitly. The preview identifier is provisional, not the final App Store identity.

Base: main `1c7a657` / v3.6.11. Separate unmerged calibration work is excluded. The existing isolated worktree is reused on `feature/store-sandbox-preview`; other worktrees remain untouched.

## Chosen approach

Use one shared processing implementation with separate distribution configuration and a narrow app-side file-access service. A packaging-only sandbox switch is insufficient because settings store paths without permission. Converting the direct edition in place would expose a working capture setup to migration risk. Neither alternative is chosen.

The store-preview launch configuration selects sandbox-aware storage and access policy. Production Developer ID packaging remains unchanged. A build claiming to be the preview must be verified to carry the sandbox entitlement; a label or Info.plist flag alone is not proof.

## Components

### 1. Distribution configuration and storage locations

An immutable configuration supplies variant identity and app-owned directories. The direct variant retains current defaults. Preview relay, catalog, calibration library and settings live in its container. Session output is the user-selected folder, not a silent fallback inside the container.

The Capture panel shows the selected output location and a Choose/Change action. First Start or Import requires output authorization; cancelling leaves the app idle and existing choices unchanged. A changed output choice applies only to a future operation; active and post-session work keep their captured destination.

### 2. Persistent authorized locations

An app-side store records bookmark data plus a display path, purpose and schema version, separately from the existing path-only settings. Purposes cover capture input, output, calibration selections and library rebuild sources. Paths are for display/compatibility, never proof of permission. Bookmarks are local app data and must not be copied into session manifests or logs.

Resolve bookmarks without an unsolicited picker at launch. Refresh a stale bookmark when resolution and renewed serialization succeed. If access cannot be restored, mark that location as requiring selection; do not erase the record or reinterpret denial as an empty folder. Resolve the returned URL rather than continuing to use the old saved string.

Access is obtained through an injectable platform adapter (create/resolve/start/stop) so lifecycle tests can count calls and force failures. Direct-distribution access is a pass-through policy, not an attempt to impose sandbox semantics on existing users.

### 3. Explicit access lifetime

Acquiring a location returns an owned access token. The token balances every successful security-scope start with a stop after its last owner releases it. Known container-owned files do not require an external security scope; do not confuse a false start result with universal denial without considering that distinction and actual I/O.

Acquire before the first baseline listing or metadata read, not merely before the stacker starts. Retain access across asynchronous preparation, dialogs, worker queues and finalization. Cancellation or failure releases it only after outstanding work has relinquished its ownership. Replacing a UI selection must not revoke another operation's live token.

After End, retain the required source/output authorization with the app's post-session context while ordinary restack or Finish clean stack remains available. Keep it through completion/backup/rollback and release when the context is retired. This does not make Finish clean stack restart-persistent; that feature's same-instance restriction remains.

Calibration master creation/rebuild owns source access until its worker completes; app-owned generated masters remain in the container. Native input and output access must not depend on whether calibration was selected.

### 4. Boundary integration

Route manual folder selection, native Start preparation, Import, calibration selection/build/rebuild and output selection through the service. Keep permission logic out of pixel mathematics, registration and rejection algorithms. Extend existing app/controller dependency seams where needed; do not create duplicate session-start logic for the preview.

Do not silently run auto-detection over unrestricted `/Volumes` in the preview. Until authorized-root detection is implemented in the next milestone, its auto-detect entry points must explain that manual folder selection is required. Similarly, preview controls for unresolved external integrations must be clearly marked unavailable in this proof build, not left to fail mysteriously. This is temporary proof-build scoping, not an approved removal from the final store edition or direct build.

### 5. Failure behavior

- Cancelled picker: no start, no changed saved grant, completion callback resolved exactly once.
- Denied or revoked input: actionable permission message, not “waiting for files.”
- Disconnected share: preserve the choice and report unavailable; reconnect requires successful resolution/access before retry, not broad automatic scanning.
- Output unwritable: refuse to start or report an output failure at the existing boundary; never redirect files silently.
- Calibration access failure: explicit failure requiring user action rather than silently claiming calibrated output.
- Permission loss during processing: preserve existing files and use existing error/finalization reporting. Reauthorization must not imply a dropped frame was processed.

## Packaging proof

Add a separate reproducible preview packaging path using its own build scratch directory, bundle ID/name and entitlements. Initial entitlements: sandbox, user-selected read/write files, app-scoped bookmarks, outgoing network access where used. Confirm the exact set during implementation and signing; no broad temporary exceptions, root helper or Full Disk Access workaround.

Use an Apple-issued development/distribution identity appropriate to local testing, without registering a store listing or changing account settings without approval. Do not call notarization or a Developer ID signature App Store approval. Store archives/TestFlight are later milestones.

## Verification and acceptance

Red-first automated tests must prove:

1. Saved grants restore after creating a fresh access service; stale bookmarks renew and moved URLs replace display paths.
2. Denied resolution does not return a raw path as authorized or clear a valid prior choice.
3. Shared token ownership stays live across asynchronous work and releases exactly once after its final owner; picker cancellation and superseded starts do not leak access or callbacks.
4. Output cancellation prevents Start and Import; changing future output cannot redirect active or completion writes.
5. Calibration and post-End completion retain their required access until terminal work/retirement.
6. The direct-distribution policy preserves existing path/default behavior and preferences.

Fake adapter tests alone are insufficient. A signed sandboxed app must pass a manual separate-process test: select copied real Seestar data and scratch output, process and End, quit, relaunch, reuse the selection, and observe a newly arriving sub. Exercise a denied/unavailable location and reauthorization. Verify FITS counts/exposure and untouched originals. Run full preflight once the implementation is stable; also inspect signed entitlements and sandbox logs.

Finish-clean permission lifetime needs a deterministic incomplete-session fixture in addition to the normal flow. Any test-only timeout override stays out of release behavior and is labelled in evidence. No performance or network-share compatibility claim follows from a local-folder test.

## Not in this milestone

App Store submission, pricing, payment code, final store branding/icon, preference/library migration from the GitHub edition, external GraXpert redesign, full OBS adaptation, whole-screen tint compatibility, and automatic camera-share discovery. Do not merge the uncommitted calibration feature incidentally. No public release or replacement of the installed app.

## Next checkpoint

Approve this design, then write an implementation plan with small test-first tasks. After implementation, stop at the signed preview's manual folder-selection/restart check so the operator can grant access through the actual macOS dialogs.
