# Footer Actions Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reorder and group existing footer actions so open/reveal actions and copy/share actions are visually separate.

**Architecture:** Keep the change local to `ControlView`. Move existing SwiftUI buttons without changing their actions, disabled rules, or help text.

**Tech Stack:** Swift 6, SwiftUI, existing `ControlView`.

## Global Constraints

- Modify production behavior only in `Sources/LiveAstroStudio/ControlView.swift`.
- Add no new persisted state.
- Add no new model, controller, persistence, core, importer, watcher, OBS, or pipeline type.
- Add no new actions.
- Remove no existing actions.
- Keep existing button actions, disabled rules, and help text byte-identical unless the plan explicitly moves the button.
- Full `swift test` is not required because this is a SwiftUI layout-only slice.

---

## File Structure

- Modify `Sources/LiveAstroStudio/ControlView.swift`.
  - Reorder Session Health header actions.
  - Split Session Outputs finished-session actions into open/reveal and copy/share rows.
- No new production files.
- No new test files.

---

### Task 1: Reorder Session Health Actions

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift`

**Interfaces:**
- Consumes existing `openWatchFolder()` and `copyHealthSnapshot()`.
- Produces no new functions.

- [ ] **Step 1: Reorder buttons**

In the `Session Health` header `HStack`, replace:

```swift
Button("Copy Health") { copyHealthSnapshot() }
    .font(.caption)
    .help("Copy the current session health snapshot for sharing or debugging.")
Button("Open Watch Folder") { openWatchFolder() }
    .font(.caption)
    .disabled(model.watchFolder == nil)
    .help("Open the folder LiveAstro is currently watching for FITS files.")
```

with:

```swift
Button("Open Watch Folder") { openWatchFolder() }
    .font(.caption)
    .disabled(model.watchFolder == nil)
    .help("Open the folder LiveAstro is currently watching for FITS files.")
Button("Copy Health") { copyHealthSnapshot() }
    .font(.caption)
    .help("Copy the current session health snapshot for sharing or debugging.")
```

- [ ] **Step 2: Run compile check**

Run:

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

Run:

```bash
git add Sources/LiveAstroStudio/ControlView.swift
git commit -m "chore: order health actions by intent"
```

---

### Task 2: Split Session Output Actions

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift`

**Interfaces:**
- Consumes existing output actions:
  - `openReplay()`
  - `revealReplay()`
  - `openSessionFolder()`
  - `revealMaster()`
  - `copySupportBundle()`
  - `copySessionSummary()`

- [ ] **Step 1: Replace the finished-session action row**

Inside `if hasSessionOutputs`, replace the single `HStack(spacing: 8) { ... }` action row with:

```swift
VStack(alignment: .leading, spacing: 6) {
    HStack(spacing: 8) {
        Button("Open Replay") { openReplay() }
            .disabled(model.replayURL == nil)
            .help("Open the latest replay video with the default macOS app.")

        Button("Reveal Replay") { revealReplay() }
            .disabled(model.replayURL == nil)
            .help("Show the latest replay video in Finder.")

        Button("Open Session Folder") { openSessionFolder() }
            .disabled(model.lastSessionDirectory == nil)
            .help("Open the folder containing this session's manifest, snapshots, replay, and native master when present.")

        if latestMasterURL != nil {
            Button("Reveal master.fit") { revealMaster() }
                .help("Show the native stacking master in Finder.")
        } else if model.lastSessionDirectory != nil {
            Button("No master.fit") {}
                .disabled(true)
                .help("Native sessions write master.fit when a current stack exists. Siril/external stacker sessions may not create one.")
        }

        Spacer()
    }

    HStack(spacing: 8) {
        Spacer()

        Button("Copy Support Bundle") { copySupportBundle() }
            .help("Copy health, output paths, and recent log lines for sharing or debugging.")

        Button("Copy Summary") { copySessionSummary() }
            .help("Copy target, output paths, and accepted/rejected frame counts.")
    }
}
.font(.caption)
```

- [ ] **Step 2: Run compile check**

Run:

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

Run:

```bash
git add Sources/LiveAstroStudio/ControlView.swift
git commit -m "chore: group session output actions"
```

---

### Task 3: Final Verification and Push Readiness

**Files:**
- No code changes expected.

**Interfaces:**
- Consumes committed Tasks 1-2.
- Produces verified work ready for merge/push.

- [ ] **Step 1: Run final gates**

Run:

```bash
swift build
git diff --check
git status --short --branch
```

Expected:

- `swift build` succeeds.
- `git diff --check` prints nothing.
- `git status --short --branch` shows a clean feature branch.

- [ ] **Step 2: Inspect final diff**

Run:

```bash
git show --stat --oneline HEAD~2..HEAD
git diff HEAD~2..HEAD -- Sources/LiveAstroStudio/ControlView.swift
```

Expected:

- The only production file changed is `Sources/LiveAstroStudio/ControlView.swift`.
- The diff reorders existing Session Health buttons and splits existing Session Outputs buttons into two rows.
- No helper function bodies change.

- [ ] **Step 3: Report**

Report commit range, verification output, and whether GUI smoke was performed.
