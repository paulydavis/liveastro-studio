# Latest Image Output UI Design

## Purpose

The core now writes `latest.png` for each session. Make that predictable image discoverable from the app, so users and beta testers can open or reveal it without browsing the session folder manually.

## Scope

Add `latest.png` affordances to `ControlView` session outputs.

Behavior:

- Detect `<lastSessionDirectory>/latest.png`.
- When present, show:
  - **Open Latest Image**
  - **Reveal latest.png**
- Include `Latest image: <path or (none)>` in:
  - **Copy Support Bundle**
  - **Copy Summary**

## Architecture

Keep this UI-only and local to `Sources/LiveAstroStudio/ControlView.swift`.

Add one helper:

```swift
private var latestImageURL: URL? {
    guard let dir = model.lastSessionDirectory else { return nil }
    let latest = dir.appendingPathComponent("latest.png")
    return FileManager.default.fileExists(atPath: latest.path) ? latest : nil
}
```

Add two actions:

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

## Non-goals

- No changes to how `latest.png` is written.
- No manifest changes.
- No local web server.
- No toggle or setting.
- No engine, watcher, importer, OBS, persistence, or pipeline behavior changes.

## Verification

- `swift build`
- `git diff --check`
- final diff inspection confirming production behavior changes only in `ControlView.swift`

Full `swift test` is not required because this is a SwiftUI discoverability/support-text slice.
