# Start Workflow Chooser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a plain-language Start Workflow section so public/beta users can choose the right LiveAstro path without understanding internal watch-folder terminology.

**Architecture:** Keep the change local to `ControlView`. Add small picker-routing helpers and a private SwiftUI row component, then wire the new rows to existing controller actions. Do not add new model state, controllers, persistence, or engine behavior.

**Tech Stack:** Swift 6, SwiftUI, AppKit `NSOpenPanel`, existing `AppModel`, `LiveSourceController`, and `ImportController`.

## Global Constraints

- Do not change stacking core, OBS behavior, session persistence, or release packaging.
- Place the chooser before the existing `Watch Folder` section.
- Keep existing advanced controls below the chooser.
- `Try Demo` is disabled and clearly marked "coming soon".
- NINA is not a special integration; it is the folder-watching path.
- Siril/external stackers are stacker-output watching, not native sub stacking.
- Previous-shoot stacking is offline; it does not need a live camera or OBS.
- A full `swift test` is not required unless controller, pipeline, watcher, importer, OBS, or persistence behavior changes.

---

## File Structure

- Modify `Sources/LiveAstroStudio/ControlView.swift`.
  - Add source-specific picker helpers near the existing `pickWatchFolderLive()`.
  - Add a private `WorkflowActionRow` helper view inside `ControlView`.
  - Add `Start Workflow` section above `Watch Folder`.
  - Relabel footer buttons to match public wording.
- No new production files.
- No new test files are planned because this slice is local SwiftUI routing and
  copy only.

---

### Task 1: Add Explicit Workflow Routing Helpers

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift`

**Interfaces:**
- Consumes: `AppModel.SourceMode.nativeStack`, `AppModel.SourceMode.stackerOutput`, `model.liveSource.startWatchFolderLive(source:)`, `model.importer.importSubs(from:)`.
- Produces:
  - `private func pickNativeWatchFolderLive()`
  - `private func pickStackerOutputWatchFolder()`
  - Updated `private func pickWatchFolderLive(sourceMode:title:message:)`

- [ ] **Step 1: Replace the current `pickWatchFolderLive()` helper**

In `Sources/LiveAstroStudio/ControlView.swift`, replace:

```swift
private func pickWatchFolderLive() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Watch"
    if panel.runModal() == .OK, let url = panel.url {
        model.liveSource.startWatchFolderLive(source: url)
    }
}
```

with:

```swift
private func pickNativeWatchFolderLive() {
    pickWatchFolderLive(
        sourceMode: .nativeStack,
        title: "Choose Live FITS Folder",
        message: "Select the folder where NINA, ASIAIR, or another capture app writes new FITS light frames."
    )
}

private func pickStackerOutputWatchFolder() {
    pickWatchFolderLive(
        sourceMode: .stackerOutput,
        title: "Choose Stacker Output Folder",
        message: "Select the folder where Siril or another stacker writes live_stack FITS output."
    )
}

private func pickWatchFolderLive(sourceMode: AppModel.SourceMode,
                                 title: String,
                                 message: String) {
    let panel = makeDirectoryPanel(title: title, message: message)
    panel.prompt = "Watch"
    if panel.runModal() == .OK, let url = panel.url {
        model.sourceMode = sourceMode
        model.liveSource.startWatchFolderLive(source: url)
    }
}
```

- [ ] **Step 2: Update existing footer call site temporarily**

Change the current footer button action from:

```swift
Button("Choose Folder…") { pickWatchFolderLive() }
```

to:

```swift
Button("Choose Folder…") { pickNativeWatchFolderLive() }
```

This preserves existing native live-folder behavior while making the helper explicit.

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
git commit -m "refactor: split live folder picker routes"
```

---

### Task 2: Add the Start Workflow Section

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift`

**Interfaces:**
- Consumes:
  - `model.liveSource.startSeestarLive()`
  - `model.liveSource.startASIAIRLive()`
  - `pickNativeWatchFolderLive()`
  - `pickStackerOutputWatchFolder()`
  - `pickImportFolder()`
- Produces:
  - `private struct WorkflowActionRow: View`
  - `private var liveWorkflowDisabled: Bool`
  - `private var offlineWorkflowDisabled: Bool`
  - New `Section("Start Workflow")`

- [ ] **Step 1: Add disabled-rule computed properties inside `ControlView`**

Add these near `logDisplayCap` and `logMinHeight`:

```swift
private var liveWorkflowDisabled: Bool {
    model.isRunning || model.importer.isImporting || model.liveSource.isDetecting
}

private var offlineWorkflowDisabled: Bool {
    model.isRunning || model.importer.isImporting
}
```

- [ ] **Step 2: Add the row component inside `ControlView`**

Add this private nested view near `InfoButton`:

```swift
private struct WorkflowActionRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var badge: String?
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 26)
                    .foregroundStyle(disabled ? .secondary : .accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.headline)
                        if let badge {
                            Text(badge)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
```

- [ ] **Step 3: Insert the `Start Workflow` section before `Section("Watch Folder")`**

Inside `Form {`, add this before the existing `Section("Watch Folder")`:

```swift
Section("Start Workflow") {
    WorkflowActionRow(
        title: "Live from Seestar",
        subtitle: "Auto-detect the mounted Seestar folder, relay new subs, and start native live stacking.",
        systemImage: "dot.radiowaves.left.and.right",
        disabled: liveWorkflowDisabled
    ) {
        model.liveSource.startSeestarLive()
    }

    WorkflowActionRow(
        title: "Live from ASIAIR",
        subtitle: "Auto-detect the ASIAIR Autorun/Light folder and start native live stacking.",
        systemImage: "camera.aperture",
        disabled: liveWorkflowDisabled
    ) {
        model.liveSource.startASIAIRLive()
    }

    WorkflowActionRow(
        title: "Live from Folder / NINA",
        subtitle: "Watch any folder where NINA or another capture app writes new FITS light frames.",
        systemImage: "folder.badge.plus",
        disabled: liveWorkflowDisabled
    ) {
        pickNativeWatchFolderLive()
    }

    WorkflowActionRow(
        title: "Watch Siril / External Stacker",
        subtitle: "Watch a live_stack FITS output from Siril or another stacker instead of stacking raw subs.",
        systemImage: "rectangle.stack.badge.play",
        disabled: liveWorkflowDisabled
    ) {
        pickStackerOutputWatchFolder()
    }

    WorkflowActionRow(
        title: "Stack Previous Shoot",
        subtitle: "Choose a folder of existing FITS light frames and stack them offline.",
        systemImage: "tray.and.arrow.down",
        disabled: offlineWorkflowDisabled
    ) {
        pickImportFolder()
    }

    WorkflowActionRow(
        title: "Try Demo",
        subtitle: "A built-in sample session is planned; for now use real or previously captured FITS files.",
        systemImage: "sparkles",
        badge: "coming soon",
        disabled: true
    ) {}
}
```

- [ ] **Step 4: Run a compile check**

Run:

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 5: Commit**

Run:

```bash
git add Sources/LiveAstroStudio/ControlView.swift
git commit -m "feat: add start workflow chooser"
```

---

### Task 3: Align Footer Labels and Verify

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift`

**Interfaces:**
- Consumes: helpers from Task 1.
- Produces: footer labels that match the new public wording.

- [ ] **Step 1: Relabel the footer actions**

Change:

```swift
Button("Choose Folder…") { pickNativeWatchFolderLive() }
```

to:

```swift
Button("Live from Folder / NINA…") { pickNativeWatchFolderLive() }
```

Change:

```swift
Button("Import Subs…") { pickImportFolder() }
```

to:

```swift
Button("Stack Previous Shoot…") { pickImportFolder() }
```

- [ ] **Step 2: Update footer help copy**

Ensure the folder button help says exactly:

```swift
.help("Live-stack subs from any folder your rig writes to, including NINA or another FITS capture app.")
```

Ensure the offline stack button help says exactly:

```swift
.help("Select a folder of previously captured FITS light frames to stack offline, with progress tracking and Cancel support.")
```

- [ ] **Step 3: Run verification**

Run:

```bash
swift build
git diff --check
git status --short --branch
```

Expected:

- `swift build` succeeds.
- `git diff --check` prints nothing.
- `git status --short --branch` shows only the intended `ControlView.swift` modification.

- [ ] **Step 4: Commit**

Run:

```bash
git add Sources/LiveAstroStudio/ControlView.swift
git commit -m "chore: align workflow footer wording"
```

---

### Task 4: Final Product Smoke

**Files:**
- No code changes expected.

**Interfaces:**
- Consumes: committed Tasks 1-3.
- Produces: verified implementation ready for review.

- [ ] **Step 1: Run final compile and whitespace gate**

Run:

```bash
swift build
git diff --check
```

Expected:

- `swift build` succeeds.
- `git diff --check` prints nothing.

- [ ] **Step 2: Inspect final diff**

Run:

```bash
git show --stat --oneline HEAD~3..HEAD
git diff HEAD~3..HEAD -- Sources/LiveAstroStudio/ControlView.swift
```

Expected:

- The only production file changed is `Sources/LiveAstroStudio/ControlView.swift`.
- The diff adds the chooser, picker helpers, and label/copy updates only.

- [ ] **Step 3: Manual smoke if GUI launch is available**

Open the app from the current checkout or build output and verify:

- Setup tab shows `Start Workflow` above `Watch Folder`.
- Rows appear in this order: Seestar, ASIAIR, Folder/NINA, Siril/External Stacker, Previous Shoot, Try Demo.
- `Try Demo` is disabled and shows `coming soon`.
- Advanced `Watch Folder`, calibration, OBS, display, and log sections remain visible below.
- Footer says `Live from Folder / NINA…` and `Stack Previous Shoot…`.

- [ ] **Step 4: Report**

Report:

- commit range;
- verification output;
- whether manual smoke was performed;
- any deviations from the spec.
