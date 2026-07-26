# Open Sessions Folder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `Open Sessions Folder` action that opens the LiveAstro session-output root.

**Architecture:** Keep the change local to `ControlView`. Add one helper that creates/opens `model.liveAstroRoot`, then render one button in the Session Outputs header.

**Tech Stack:** Swift 6, SwiftUI, AppKit `NSWorkspace`, Foundation `FileManager`, existing `AppModel`.

## Global Constraints

- Modify production behavior only in `Sources/LiveAstroStudio/ControlView.swift`.
- Add no new persisted state.
- Add no new model, controller, persistence, core, importer, watcher, OBS, or pipeline type.
- Button label must be `Open Sessions Folder`.
- Success log line must be `Opened sessions folder`.
- Error message must begin `Could not open sessions folder: `.
- Full `swift test` is not required because this is a SwiftUI action/display slice.

---

## File Structure

- Modify `Sources/LiveAstroStudio/ControlView.swift`.
  - Add `openSessionsRoot()`.
  - Add an `Open Sessions Folder` button beside `Regenerate Replay…`.
- No new production files.
- No new test files.

---

### Task 1: Add Open Sessions Folder Action

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift`

**Interfaces:**
- Consumes: `model.liveAstroRoot`, `FileManager.default.createDirectory(at:withIntermediateDirectories:)`, `NSWorkspace.shared.open(_:)`, `model.log`, `model.errorMessage`.
- Produces: `private func openSessionsRoot()`.

- [ ] **Step 1: Add the Session Outputs header button**

In the `Session Outputs` header `HStack`, before `Button("Regenerate Replay…")`, add:

```swift
Button("Open Sessions Folder") { openSessionsRoot() }
    .help("Open the root folder where LiveAstro writes session outputs.")
```

- [ ] **Step 2: Add `openSessionsRoot()`**

Near `openSessionFolder()`, add:

```swift
private func openSessionsRoot() {
    let url = model.liveAstroRoot
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
        model.log.append("Opened sessions folder")
    } catch {
        model.errorMessage = "Could not open sessions folder: \(error.localizedDescription)"
    }
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
git commit -m "feat: open sessions folder from outputs"
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
- The diff adds only `openSessionsRoot()` and the `Open Sessions Folder` button.

- [ ] **Step 3: Report**

Report commit hash, verification output, and whether GUI smoke was performed.
