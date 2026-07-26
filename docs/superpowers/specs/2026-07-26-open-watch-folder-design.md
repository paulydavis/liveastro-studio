# Open Watch Folder Design

## Purpose

Make the watched input folder actionable from the same place that displays it. If a user is unsure what LiveAstro is watching, they should be able to open that folder directly instead of copying a long path or hunting in Finder.

## Scope

Add an **Open Watch Folder** button beside **Copy Health** in the Session Health header.

Behavior:

- Enabled when `model.watchFolder` is set.
- Disabled when no watch folder is selected.
- Opens `model.watchFolder` with `NSWorkspace.shared.open(_:)`.
- Appends one log line: `Opened watch folder`.

## Architecture

Keep the slice local to `Sources/LiveAstroStudio/ControlView.swift`.

Add one helper:

```swift
private func openWatchFolder() {
    guard let url = model.watchFolder else { return }
    NSWorkspace.shared.open(url)
    model.log.append("Opened watch folder")
}
```

Render one button in the existing Session Health title row:

```swift
Button("Open Watch Folder") { openWatchFolder() }
    .font(.caption)
    .disabled(model.watchFolder == nil)
    .help("Open the folder LiveAstro is currently watching for FITS files.")
```

## Non-goals

- No watch-folder selection changes.
- No watcher, importer, pipeline, OBS, persistence, or engine behavior changes.
- No new state.
- No automatic folder reveal or Finder selection behavior; open the folder only.

## Verification

- `swift build`
- `git diff --check`
- final diff inspection confirming production behavior changes only in `ControlView.swift`

Full `swift test` is not required because this is a SwiftUI action/display slice.
