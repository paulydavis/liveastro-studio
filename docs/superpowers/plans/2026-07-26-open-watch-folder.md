# Open Watch Folder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `Open Watch Folder` button to the Session Health header.

**Architecture:** Keep the change local to `ControlView`. Add one helper that opens `model.watchFolder` through `NSWorkspace`, then render one disabled-when-empty button beside `Copy Health`.

**Tech Stack:** Swift 6, SwiftUI, AppKit `NSWorkspace`, existing `AppModel`.

## Global Constraints

- Modify production behavior only in `Sources/LiveAstroStudio/ControlView.swift`.
- Add no new persisted state.
- Add no new model, controller, persistence, core, importer, watcher, OBS, or pipeline type.
- Button label must be `Open Watch Folder`.
- Button must be disabled when `model.watchFolder == nil`.
- Helper must append `Opened watch folder` only after a folder URL exists and is opened.
- Full `swift test` is not required because this is a SwiftUI action/display slice.

---

## File Structure

- Modify `Sources/LiveAstroStudio/ControlView.swift`.
  - Add `openWatchFolder()`.
  - Add the `Open Watch Folder` button in the Session Health title row.
- No new production files.
- No new test files.

---

### Task 1: Add Open Watch Folder Action

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift`

**Interfaces:**
- Consumes: `model.watchFolder: URL?`, `NSWorkspace.shared.open(_:)`, `model.log`.
- Produces: `private func openWatchFolder()`.

- [ ] **Step 1: Add the button beside `Copy Health`**

In the Session Health `HStack`, after the `Copy Health` button, add:

```swift
Button("Open Watch Folder") { openWatchFolder() }
    .font(.caption)
    .disabled(model.watchFolder == nil)
    .help("Open the folder LiveAstro is currently watching for FITS files.")
```

- [ ] **Step 2: Add `openWatchFolder()`**

Near `openSessionFolder()`, add:

```swift
private func openWatchFolder() {
    guard let url = model.watchFolder else { return }
    NSWorkspace.shared.open(url)
    model.log.append("Opened watch folder")
}
```

- [ ] **Step 3: Run compile check**

Run:

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

Run:

```bash
git add Sources/LiveAstroStudio/ControlView.swift
git commit -m "feat: open watched folder from health panel"
```

---

### Task 2: Final Verification and Push Readiness

**Files:**
- No code changes expected.

**Interfaces:**
- Consumes committed Task 1.
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
git show --stat --oneline HEAD
git diff HEAD~1..HEAD -- Sources/LiveAstroStudio/ControlView.swift
```

Expected:

- The only production file changed is `Sources/LiveAstroStudio/ControlView.swift`.
- The diff adds only the button and `openWatchFolder()`.

- [ ] **Step 3: Report**

Report commit hash, verification output, and whether GUI smoke was performed.
