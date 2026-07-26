# Open Sessions Folder Design

## Purpose

Make LiveAstro’s output root discoverable even before a finished session exists. Users should be able to open `~/Documents/LiveAstro/` from the app instead of remembering the path from docs.

## Scope

Add an **Open Sessions Folder** button in the `Session Outputs` header.

Behavior:

- The button is visible whenever the footer’s `Session Outputs` section is visible.
- It opens `model.liveAstroRoot`.
- If the folder does not exist yet, create it first.
- On success, append `Opened sessions folder`.
- On create/open failure, show the existing app error alert with a concise message.

## Architecture

Keep this local to `Sources/LiveAstroStudio/ControlView.swift`.

Add one helper:

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

Add one button beside `Regenerate Replay…`:

```swift
Button("Open Sessions Folder") { openSessionsRoot() }
    .help("Open the root folder where LiveAstro writes session outputs.")
```

## Non-goals

- No output-location setting.
- No migration of existing sessions.
- No session creation.
- No changes to replay/session/master generation.
- No engine, watcher, importer, OBS, persistence, or pipeline behavior changes.

## Verification

- `swift build`
- `git diff --check`
- final diff inspection confirming production behavior changes only in `ControlView.swift`

Full `swift test` is not required because this is a SwiftUI action/display slice.
