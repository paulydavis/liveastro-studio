# Copy Log Tail Design

## Purpose

Make support/debugging easier during beta use. When a user reports a problem, they should be able to copy the same recent log lines visible in the app without taking a screenshot or manually selecting text.

## Scope

Add a **Copy Log** button to the `Log` section header in `ControlView`.

Behavior:

- The button is disabled when `model.log` is empty.
- The copied text is the visible capped tail: `model.log.suffix(logDisplayCap).joined(separator: "\n")`.
- After copying, append one log line: `Copied log tail`.
- The copied text is computed before appending the confirmation line, so the confirmation does not appear in the copied payload.

## Architecture

Keep this UI-only and local to `Sources/LiveAstroStudio/ControlView.swift`.

Add one helper:

```swift
private func copyLogTail() {
    let tail = model.log.suffix(logDisplayCap).joined(separator: "\n")
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(tail, forType: .string)
    model.log.append("Copied log tail")
}
```

Change the log section from a string-title section to a section with a header view:

```swift
Section {
    ...
} header: {
    HStack {
        Text("Log")
        Spacer()
        Button("Copy Log") { copyLogTail() }
            .font(.caption)
            .disabled(model.log.isEmpty)
            .help("Copy the visible recent log lines for sharing or debugging.")
    }
}
```

## Non-goals

- No full log export.
- No file writing.
- No session manifest changes.
- No changes to what gets logged.
- No engine, watcher, importer, OBS, persistence, or pipeline behavior changes.

## Verification

- `swift build`
- `git diff --check`
- final diff inspection confirming production behavior changes only in `ControlView.swift`

Full `swift test` is not required because this is a SwiftUI action/display slice.
