# Session Outputs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a finished-session output toolbox so users can open/reveal replay, open the session folder, reveal `master.fit`, and copy a simple summary.

**Architecture:** Keep the slice local to `ControlView`. Use existing `AppModel.replayURL`, `AppModel.lastSessionDirectory`, frame counters, and `NSWorkspace`/`NSPasteboard`; add no new model state, controller behavior, persistence, or output files.

**Tech Stack:** Swift 6, SwiftUI, AppKit `NSWorkspace`, AppKit `NSPasteboard`, existing `AppModel`.

## Global Constraints

- Do not change the stacking core, session manifest schema, replay generation, import pipeline, watcher, OBS, or release packaging.
- Only show the section when `!model.isRunning` and either `model.replayURL` or `model.lastSessionDirectory` exists.
- Disable `Open Replay` and `Reveal Replay` when `replayURL` is nil.
- Disable `Open Session Folder` when `lastSessionDirectory` is nil.
- Enable `Reveal master.fit` only when `lastSessionDirectory/master.fit` exists.
- Keep `Regenerate Replay…` disabled while `model.importer.isGeneratingReplay`.
- Keep `Process master` behavior unchanged.
- External-stacker sessions and failed/empty native sessions may not have `master.fit`; that is expected and must not be presented as an error.
- A full `swift test` is not required unless implementation touches model, controller, pipeline, watcher, importer, OBS, or persistence behavior.

---

## File Structure

- Modify `Sources/LiveAstroStudio/ControlView.swift`.
  - Add computed helpers near other private helper properties.
  - Add output action helper methods near the existing picker helpers.
  - Replace the current finished-session footer row with a `Session Outputs` block.
- No new production files.
- No new test files are planned because this slice is SwiftUI/AppKit routing and copy only.

---

### Task 1: Add Session Output Helper Methods

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift`

**Interfaces:**
- Consumes: `model.replayURL`, `model.lastSessionDirectory`, `model.targetName`, `model.acceptedCount`, `model.rejectedCount`, `NSWorkspace.shared`, `NSPasteboard.general`.
- Produces:
  - `private var hasSessionOutputs: Bool`
  - `private var latestMasterURL: URL?`
  - `private func openReplay()`
  - `private func revealReplay()`
  - `private func openSessionFolder()`
  - `private func revealMaster()`
  - `private func copySessionSummary()`

- [ ] **Step 1: Add computed output helpers**

In `Sources/LiveAstroStudio/ControlView.swift`, add these near `liveWorkflowDisabled` and `offlineWorkflowDisabled`:

```swift
private var hasSessionOutputs: Bool {
    !model.isRunning && (model.replayURL != nil || model.lastSessionDirectory != nil)
}

private var latestMasterURL: URL? {
    guard let dir = model.lastSessionDirectory else { return nil }
    let master = dir.appendingPathComponent("master.fit")
    return FileManager.default.fileExists(atPath: master.path) ? master : nil
}
```

- [ ] **Step 2: Add output action methods**

Add these near `pickSessionDirectory()`:

```swift
private func openReplay() {
    guard let url = model.replayURL else { return }
    NSWorkspace.shared.open(url)
}

private func revealReplay() {
    guard let url = model.replayURL else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
}

private func openSessionFolder() {
    guard let url = model.lastSessionDirectory else { return }
    NSWorkspace.shared.open(url)
}

private func revealMaster() {
    guard let url = latestMasterURL else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
}

private func copySessionSummary() {
    let target = model.targetName.trimmingCharacters(in: .whitespacesAndNewlines)
    let sessionPath = model.lastSessionDirectory?.path ?? "(none)"
    let replayPath = model.replayURL?.path ?? "(none)"
    let masterPath = latestMasterURL?.path ?? "(none)"
    let summary = """
    LiveAstro Session
    Target: \(target.isEmpty ? "(untitled)" : target)
    Session folder: \(sessionPath)
    Replay: \(replayPath)
    Master: \(masterPath)
    Accepted frames: \(model.acceptedCount)
    Rejected frames: \(model.rejectedCount)
    """
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(summary, forType: .string)
    model.log.append("Copied session summary")
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
git commit -m "feat: add session output helpers"
```

---

### Task 2: Add the Session Outputs Footer Block

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift`

**Interfaces:**
- Consumes helper methods and properties from Task 1.
- Produces a visible `Session Outputs` block in the fixed footer area.

- [ ] **Step 1: Replace the existing not-running replay row**

In `Sources/LiveAstroStudio/ControlView.swift`, replace:

```swift
if !model.isRunning {
    HStack {
        Button("Regenerate Replay…") { pickSessionDirectory() }
            .disabled(model.importer.isGeneratingReplay)
        if let url = model.replayURL {
            Spacer()
            Button("Reveal Replay in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}
```

with:

```swift
if !model.isRunning {
    VStack(alignment: .leading, spacing: 6) {
        HStack {
            Text("Session Outputs")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Regenerate Replay…") { pickSessionDirectory() }
                .disabled(model.importer.isGeneratingReplay)
        }

        if hasSessionOutputs {
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

                Button("Copy Summary") { copySessionSummary() }
                    .help("Copy target, output paths, and accepted/rejected frame counts.")
            }
            .font(.caption)
        } else {
            Text("Finish a session or stack a previous shoot to see output shortcuts here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 2: Run a compile check**

Run:

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

Run:

```bash
git add Sources/LiveAstroStudio/ControlView.swift
git commit -m "feat: show session output shortcuts"
```

---

### Task 3: Final Verification and Diff Review

**Files:**
- No code changes expected.

**Interfaces:**
- Consumes committed Tasks 1-2.
- Produces verified work ready for merge/PR choice.

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
- The diff adds output helpers and the `Session Outputs` footer block only.

- [ ] **Step 3: Manual smoke if GUI access is available**

Open the app and verify:

- Footer still shows `Regenerate Replay…` while not running.
- With no output state, the section says to finish a session or stack a previous shoot.
- After a session/import/regenerate, output buttons are visible.
- `No master.fit` appears disabled when the master is absent.
- `Process master` still appears only under its existing GraXpert/native conditions.

- [ ] **Step 4: Report**

Report:

- commit range;
- verification output;
- whether manual smoke was performed;
- any deviations from the spec.
