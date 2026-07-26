# Copy Support Bundle Design

## Purpose

Make beta support easier by collecting the useful “what happened?” context into one clipboard action: current health, output paths, and the recent visible log tail.

## Scope

Add a **Copy Support Bundle** button in the `Session Outputs` actions row, shown when `hasSessionOutputs` is true.

The copied text is plain text with three sections:

```text
LiveAstro Support Bundle

Session Health
State: Idle
Source: Native stacking
Folder: /path/to/input
Last update: #12 · snapshot_0012.fit
Frames: accepted 12 · rejected 1
Last rejection: (none)
OBS: idle
Outputs: replay ready

Session Outputs
Target: M31
Session folder: /path/to/session
Replay: /path/to/replay.mp4
Master: /path/to/master.fit

Recent Log
...
```

After copying, append one log line: `Copied support bundle`.

The log section is captured before appending the confirmation line, so the copied bundle does not include its own copy-confirmation entry.

## Architecture

Keep this UI-only and local to `Sources/LiveAstroStudio/ControlView.swift`.

Reuse existing display helpers:

- `sessionStateText`
- `sourceSummaryText`
- `watchFolderSummaryText`
- `lastUpdateSummaryText`
- `framesSummaryText`
- `lastRejectionSummaryText`
- `obsSummaryText`
- `outputsSummaryText`
- `latestMasterURL`

Add one helper:

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

## Non-goals

- No zip file.
- No file export.
- No privacy redaction pass.
- No manifest changes.
- No changes to log production.
- No engine, watcher, importer, OBS, persistence, or pipeline behavior changes.

## Verification

- `swift build`
- `git diff --check`
- final diff inspection confirming production behavior changes only in `ControlView.swift`

Full `swift test` is not required because this is a SwiftUI action/display slice.
