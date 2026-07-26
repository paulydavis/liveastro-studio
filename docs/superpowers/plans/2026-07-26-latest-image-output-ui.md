# Latest Image Output UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface the session `latest.png` in app output controls and copied summaries.

**Architecture:** Keep the change local to `ControlView`. Add a computed URL helper, two NSWorkspace actions, two output buttons, and one copied-summary line.

**Tech Stack:** Swift 6, SwiftUI, AppKit `NSWorkspace`, Foundation `FileManager`, existing `AppModel`.

## Global Constraints

- Modify production behavior only in `Sources/LiveAstroStudio/ControlView.swift`.
- Add no new persisted state.
- Add no new model, controller, persistence, core, importer, watcher, OBS, or pipeline type.
- Button labels must be `Open Latest Image` and `Reveal latest.png`.
- Copied summary line must start `Latest image: `.
- Full `swift test` is not required because this is a SwiftUI discoverability/support-text slice.

---

## File Structure

- Modify `Sources/LiveAstroStudio/ControlView.swift`.
  - Add `latestImageURL`.
  - Add `openLatestImage()` and `revealLatestImage()`.
  - Add latest image buttons in Session Outputs.
  - Add latest image path to copy payloads.
- No new production files.
- No new test files.

---

### Task 1: Add Latest Image Helper and Actions

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift`

**Interfaces:**
- Consumes: `model.lastSessionDirectory`, `FileManager.default.fileExists(atPath:)`, `NSWorkspace.shared`.
- Produces:
  - `private var latestImageURL: URL?`
  - `private func openLatestImage()`
  - `private func revealLatestImage()`

- [ ] **Step 1: Add `latestImageURL`**

Near `latestMasterURL`, add:

```swift
private var latestImageURL: URL? {
    guard let dir = model.lastSessionDirectory else { return nil }
    let latest = dir.appendingPathComponent("latest.png")
    return FileManager.default.fileExists(atPath: latest.path) ? latest : nil
}
```

- [ ] **Step 2: Add actions**

Near `openReplay()` and reveal helpers, add:

```swift
private func openLatestImage() {
    guard let url = latestImageURL else { return }
    NSWorkspace.shared.open(url)
}

private func revealLatestImage() {
    guard let url = latestImageURL else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
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
git commit -m "feat: add latest image output helpers"
```

---

### Task 2: Render Latest Image Buttons and Copy Lines

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift`

**Interfaces:**
- Consumes: `latestImageURL`, `openLatestImage()`, `revealLatestImage()`.

- [ ] **Step 1: Add buttons in Session Outputs open/reveal row**

After `Open Session Folder`, add:

```swift
if latestImageURL != nil {
    Button("Open Latest Image") { openLatestImage() }
        .help("Open the session's latest.png monitor image.")

    Button("Reveal latest.png") { revealLatestImage() }
        .help("Show the session's latest.png monitor image in Finder.")
}
```

- [ ] **Step 2: Add latest image path to copied payloads**

In both `copySupportBundle()` and `copySessionSummary()`, add:

```swift
let latestImagePath = latestImageURL?.path ?? "(none)"
```

Then add this line to each copied summary's `Session Outputs` path block:

```swift
Latest image: \(latestImagePath)
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
git commit -m "feat: show latest image output"
```

---

### Task 3: Final Verification and Push Readiness

**Files:**
- No code changes expected.

**Interfaces:**
- Consumes committed Tasks 1-2.

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

- [ ] **Step 3: Report**

Report commit range, verification output, and whether full suite was skipped with rationale.
