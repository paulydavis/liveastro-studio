# Copy Support Bundle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `Copy Support Bundle` action that copies health, output paths, and recent log lines in one plain-text payload.

**Architecture:** Keep the change local to `ControlView`. Add one pasteboard helper that reuses the existing Session Health helper properties and current output-path helpers, then render one button in the existing Session Outputs action row.

**Tech Stack:** Swift 6, SwiftUI, AppKit `NSPasteboard`, existing `AppModel`.

## Global Constraints

- Modify production behavior only in `Sources/LiveAstroStudio/ControlView.swift`.
- Add no new persisted state.
- Add no new model, controller, persistence, core, importer, watcher, OBS, or pipeline type.
- Button label must be `Copy Support Bundle`.
- Button is shown only inside the existing `if hasSessionOutputs` action row.
- Copied payload must include sections named `Session Health`, `Session Outputs`, and `Recent Log`.
- Copied log tail must be captured before appending `Copied support bundle`.
- Full `swift test` is not required because this is a SwiftUI action/display slice.

---

## File Structure

- Modify `Sources/LiveAstroStudio/ControlView.swift`.
  - Add `copySupportBundle()`.
  - Add a `Copy Support Bundle` button in the Session Outputs action row.
- No new production files.
- No new test files.

---

### Task 1: Add Copy Support Bundle Action

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift`

**Interfaces:**
- Consumes:
  - `model.targetName`
  - `model.lastSessionDirectory`
  - `model.replayURL`
  - `latestMasterURL`
  - `model.log`
  - `logDisplayCap`
  - `sessionStateText`
  - `sourceSummaryText`
  - `watchFolderSummaryText`
  - `lastUpdateSummaryText`
  - `framesSummaryText`
  - `lastRejectionSummaryText`
  - `obsSummaryText`
  - `outputsSummaryText`
  - `NSPasteboard.general`
- Produces: `private func copySupportBundle()`.

- [ ] **Step 1: Add the Session Outputs button**

In the `Session Outputs` action row, directly before `Button("Copy Summary")`, add:

```swift
Button("Copy Support Bundle") { copySupportBundle() }
    .help("Copy health, output paths, and recent log lines for sharing or debugging.")
```

- [ ] **Step 2: Add `copySupportBundle()`**

Near `copySessionSummary()`, add:

```swift
private func copySupportBundle() {
    let target = model.targetName.trimmingCharacters(in: .whitespacesAndNewlines)
    let sessionPath = model.lastSessionDirectory?.path ?? "(none)"
    let replayPath = model.replayURL?.path ?? "(none)"
    let masterPath = latestMasterURL?.path ?? "(none)"
    let logTail = model.log.suffix(logDisplayCap).joined(separator: "\n")
    let summary = """
    LiveAstro Support Bundle

    Session Health
    State: \(sessionStateText)
    Source: \(sourceSummaryText)
    Folder: \(watchFolderSummaryText)
    Last update: \(lastUpdateSummaryText)
    Frames: \(framesSummaryText)
    Last rejection: \(lastRejectionSummaryText)
    OBS: \(obsSummaryText)
    Outputs: \(outputsSummaryText)

    Session Outputs
    Target: \(target.isEmpty ? "(untitled)" : target)
    Session folder: \(sessionPath)
    Replay: \(replayPath)
    Master: \(masterPath)

    Recent Log
    \(logTail.isEmpty ? "(empty)" : logTail)
    """
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(summary, forType: .string)
    model.log.append("Copied support bundle")
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
git commit -m "feat: copy support bundle"
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
- The diff adds only `copySupportBundle()` and the `Copy Support Bundle` button.

- [ ] **Step 3: Report**

Report commit hash, verification output, and whether GUI smoke was performed.
