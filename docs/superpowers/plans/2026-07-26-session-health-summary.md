# Session Health Summary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a compact Session Health block that summarizes current LiveAstro state, source, folder, latest update, counts, last rejection, OBS, and output availability.

**Architecture:** Keep the slice local to `ControlView`. Add computed display-text helpers and a small nested SwiftUI label/value view; render existing `AppModel` and controller state without adding model state, persistence, telemetry, or engine calls.

**Tech Stack:** Swift 6, SwiftUI, existing `AppModel`, existing `BroadcastController` state.

## Global Constraints

- Do not change stacking, watching, importing, OBS control, session persistence, or output generation.
- Derive display text from existing `AppModel` and controller state only.
- Add no new persisted state.
- Add no new model, controller, persistence, or core type.
- Use public wording: `.nativeStack` → `Native stacking`; `.stackerOutput` → `Siril / external stacker`.
- Missing folder renders `(none selected)`.
- Missing rejection renders `(none)`.
- Missing outputs renders `no finished session yet`.
- Replay present renders `replay ready`.
- Session folder present but replay absent renders `session folder ready`.
- A full `swift test` is not required unless implementation touches model, controller, pipeline, watcher, importer, OBS, or persistence behavior.

---

## File Structure

- Modify `Sources/LiveAstroStudio/ControlView.swift`.
  - Add computed text helpers near existing footer helper properties.
  - Add nested `HealthItem` view near the existing nested helper views.
  - Add the `Session Health` block in the fixed footer before the broadcast row.
- No new production files.
- No new test files are planned because this slice is local SwiftUI display text only.

---

### Task 1: Add Session Health Text Helpers

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift`

**Interfaces:**
- Consumes: `model.liveSource.isDetecting`, `model.importer.isImporting`, `model.importer.isGeneratingReplay`, `model.isRunning`, `model.sourceMode`, `model.watchFolder`, `model.latestRecord`, `model.integrationCaption`, `model.acceptedCount`, `model.rejectedCount`, `model.log`, `model.broadcast.broadcastState`, `model.broadcast.streamHealth`, `model.lastSessionDirectory`, `model.replayURL`, existing `formatDuration(_:)`.
- Produces:
  - `private var sessionStateText: String`
  - `private var sourceSummaryText: String`
  - `private var watchFolderSummaryText: String`
  - `private var lastUpdateSummaryText: String`
  - `private var framesSummaryText: String`
  - `private var lastRejectionSummaryText: String`
  - `private var obsSummaryText: String`
  - `private var outputsSummaryText: String`

- [ ] **Step 1: Add state/source/folder helpers**

In `Sources/LiveAstroStudio/ControlView.swift`, add these near `hasSessionOutputs` and `latestMasterURL`:

```swift
private var sessionStateText: String {
    if model.liveSource.isDetecting { return "Detecting source" }
    if model.importer.isImporting { return "Importing" }
    if model.importer.isGeneratingReplay { return "Rendering replay" }
    if model.isRunning { return "Running" }
    return "Idle"
}

private var sourceSummaryText: String {
    switch model.sourceMode {
    case .nativeStack:
        return "Native stacking"
    case .stackerOutput:
        return "Siril / external stacker"
    }
}

private var watchFolderSummaryText: String {
    model.watchFolder?.path ?? "(none selected)"
}
```

- [ ] **Step 2: Add update/count/rejection helpers**

Add:

```swift
private var lastUpdateSummaryText: String {
    guard let record = model.latestRecord else { return model.integrationCaption }
    return "#\(record.index) · \(record.snapshotFile)"
}

private var framesSummaryText: String {
    "accepted \(model.acceptedCount) · rejected \(model.rejectedCount)"
}

private var lastRejectionSummaryText: String {
    guard let line = model.log.last(where: { $0.hasPrefix("✗ rejected ") }) else {
        return "(none)"
    }
    let prefix = "✗ rejected "
    if line.hasPrefix(prefix) {
        return String(line.dropFirst(prefix.count))
    }
    return line
}
```

- [ ] **Step 3: Add OBS/output helpers**

Add:

```swift
private var obsSummaryText: String {
    switch model.broadcast.broadcastState {
    case .idle:
        return "idle"
    case .unknown:
        return "not checked"
    case .connecting:
        return "connecting"
    case .live:
        if let h = model.broadcast.streamHealth {
            return "live · \(formatDuration(h.durationSeconds)) · \(h.skippedFrames) dropped · \(Int((h.congestion * 100).rounded()))% congestion"
        }
        return "live"
    case .endingSession:
        return "ending session"
    case .stopping:
        return "stopping"
    case .stopUnconfirmed:
        return "may still be live"
    }
}

private var outputsSummaryText: String {
    if model.replayURL != nil { return "replay ready" }
    if model.lastSessionDirectory != nil { return "session folder ready" }
    return "no finished session yet"
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
git commit -m "feat: add session health summary helpers"
```

---

### Task 2: Render the Session Health Block

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift`

**Interfaces:**
- Consumes helper properties from Task 1.
- Produces:
  - `private struct HealthItem: View`
  - A `Session Health` block in the fixed footer.

- [ ] **Step 1: Add nested `HealthItem` view**

Add this near the existing nested helper views (`InfoButton`, `WorkflowActionRow`):

```swift
private struct HealthItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
```

- [ ] **Step 2: Insert `Session Health` block before the broadcast row**

In the fixed footer `VStack`, after the first action-button `HStack` and before the comment `// Go Live / End Broadcast — decoupled from session start.`, insert:

```swift
VStack(alignment: .leading, spacing: 6) {
    Text("Session Health")
        .font(.caption)
        .foregroundStyle(.secondary)

    LazyVGrid(columns: [
        GridItem(.flexible(minimum: 120), alignment: .leading),
        GridItem(.flexible(minimum: 120), alignment: .leading),
        GridItem(.flexible(minimum: 120), alignment: .leading),
        GridItem(.flexible(minimum: 120), alignment: .leading)
    ], alignment: .leading, spacing: 8) {
        HealthItem(label: "State", value: sessionStateText)
        HealthItem(label: "Source", value: sourceSummaryText)
        HealthItem(label: "Folder", value: watchFolderSummaryText)
        HealthItem(label: "Last update", value: lastUpdateSummaryText)
        HealthItem(label: "Frames", value: framesSummaryText)
        HealthItem(label: "Last rejection", value: lastRejectionSummaryText)
        HealthItem(label: "OBS", value: obsSummaryText)
        HealthItem(label: "Outputs", value: outputsSummaryText)
    }
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
git commit -m "feat: show session health summary"
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
- The diff adds helper text properties, `HealthItem`, and a `Session Health` block only.

- [ ] **Step 3: Manual smoke if GUI access is available**

Open the app and verify:

- Footer shows `Session Health`.
- Idle state shows `Idle`.
- Missing folder shows `(none selected)`.
- Source reads `Native stacking` or `Siril / external stacker`.
- Last update reads `waiting for first stack…` before any update.
- Outputs reads `no finished session yet` before a completed session/import.
- Existing broadcast and output action rows still appear.

- [ ] **Step 4: Report**

Report:

- commit range;
- verification output;
- whether manual smoke was performed;
- any deviations from the spec.
