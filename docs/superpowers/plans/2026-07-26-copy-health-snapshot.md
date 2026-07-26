# Copy Health Snapshot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `Copy Health` action that copies the current Session Health panel values as plain text.

**Architecture:** Keep the implementation local to `ControlView`. Build the copied text from the same helper properties used by the visible Session Health grid, then copy it through `NSPasteboard` and append one log line.

**Tech Stack:** Swift 6, SwiftUI, AppKit `NSPasteboard`, existing `AppModel`.

## Global Constraints

- Modify production behavior only in `Sources/LiveAstroStudio/ControlView.swift`.
- Add no new persisted state.
- Add no new model, controller, persistence, core, importer, watcher, OBS, or pipeline type.
- The copied values must reuse the existing Session Health helper properties so copied text and visible text do not drift.
- The copied text header must be `LiveAstro Session Health`.
- The button label must be `Copy Health`.
- The button help text must explain that it copies the current health snapshot for sharing/debugging.
- A full `swift test` is not required unless implementation touches model, controller, pipeline, watcher, importer, OBS, or persistence behavior.

---

## File Structure

- Modify `Sources/LiveAstroStudio/ControlView.swift`.
  - Add `copyHealthSnapshot()`.
  - Add a `Copy Health` button beside the `Session Health` heading.
- No new production files.
- No new test files because this is a SwiftUI display/action slice.

---

### Task 1: Add the Copy Health Snapshot Action

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift`

**Interfaces:**
- Consumes:
  - `sessionStateText: String`
  - `sourceSummaryText: String`
  - `watchFolderSummaryText: String`
  - `lastUpdateSummaryText: String`
  - `framesSummaryText: String`
  - `lastRejectionSummaryText: String`
  - `obsSummaryText: String`
  - `outputsSummaryText: String`
  - `NSPasteboard.general`
  - `model.log`
- Produces:
  - `private func copyHealthSnapshot()`

- [ ] **Step 1: Add `copyHealthSnapshot()`**

In `Sources/LiveAstroStudio/ControlView.swift`, add this function near `copySessionSummary()`:

```swift
private func copyHealthSnapshot() {
    let summary = """
    LiveAstro Session Health
    State: \(sessionStateText)
    Source: \(sourceSummaryText)
    Folder: \(watchFolderSummaryText)
    Last update: \(lastUpdateSummaryText)
    Frames: \(framesSummaryText)
    Last rejection: \(lastRejectionSummaryText)
    OBS: \(obsSummaryText)
    Outputs: \(outputsSummaryText)
    """
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(summary, forType: .string)
    model.log.append("Copied session health")
}
```

- [ ] **Step 2: Add the button beside the Session Health title**

Replace the current Session Health title lines:

```swift
Text("Session Health")
    .font(.caption)
    .foregroundStyle(.secondary)
```

with:

```swift
HStack {
    Text("Session Health")
        .font(.caption)
        .foregroundStyle(.secondary)
    Spacer()
    Button("Copy Health") { copyHealthSnapshot() }
        .font(.caption)
        .help("Copy the current session health snapshot for sharing or debugging.")
}
```

- [ ] **Step 3: Run a compile check**

Run:

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

Run:

```bash
git add Sources/LiveAstroStudio/ControlView.swift
git commit -m "feat: copy session health snapshot"
```

---

### Task 2: Final Verification and Diff Review

**Files:**
- No code changes expected.

**Interfaces:**
- Consumes committed Task 1.
- Produces verified work ready for merge and push.

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
- The diff adds `copyHealthSnapshot()` and the `Copy Health` button only.

- [ ] **Step 3: Report**

Report:

- commit hash;
- verification output;
- whether manual GUI smoke was performed;
- any deviations from the spec.
