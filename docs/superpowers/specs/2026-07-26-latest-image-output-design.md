# Latest Image Output Design

## Purpose

Write a stable `latest.png` beside each session so external tools can monitor the current stack without parsing the manifest or discovering the newest numbered snapshot.

Examples:

- a local status page can show one static image URL;
- a Discord bot can upload one predictable file;
- an operator can keep Finder/Preview pointed at the same filename.

## Scope

When `SnapshotRecorder.save(...)` successfully writes a numbered snapshot, also update:

```text
<session>/latest.png
```

with the same display-ready PNG bytes.

Behavior:

- `snapshots/NNNN.png` remains the manifest truth.
- `latest.png` is not added to the manifest.
- `latest.png` is auxiliary: failure to update it must not make `save(...)` fail after the numbered snapshot succeeds.
- `latest.png` should be updated from the already-written numbered PNG, avoiding a second image encode path.
- Existing numbered snapshot behavior and returned `SnapshotRecord` remain unchanged.

## Architecture

Keep the feature in `Sources/LiveAstroCore/Session/SnapshotRecorder.swift`.

Add a private helper:

```swift
private func updateLatestImage(from snapshotURL: URL) {
    let latestURL = sessionDirectory.appendingPathComponent("latest.png")
    let tempURL = sessionDirectory.appendingPathComponent(".latest-\(UUID().uuidString).png")
    do {
        try FileManager.default.copyItem(at: snapshotURL, to: tempURL)
        if FileManager.default.fileExists(atPath: latestURL.path) {
            _ = try FileManager.default.replaceItemAt(latestURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: latestURL)
        }
    } catch {
        try? FileManager.default.removeItem(at: tempURL)
    }
}
```

Call it immediately after the numbered snapshot `CGImageDestinationFinalize(...)` succeeds.

This keeps readers away from partially encoded `latest.png`: the image is encoded to its numbered snapshot first, then copied to a hidden temp file and moved/replaced into the stable latest path.

## Tests

Add two tests to `SnapshotRecorderTests`:

1. `testSaveWritesLatestPNG` — after a save, `latest.png` exists and decodes.
2. `testLatestPNGTracksMostRecentSnapshot` — save two different image sizes; `latest.png` decodes to the second size while the first numbered snapshot still exists.

## Non-goals

- No `latest.jpg`.
- No configurable output path.
- No local web server.
- No manifest schema change.
- No app UI toggle.
- No deletion/cleanup policy change.

## Verification

- `swift test --filter SnapshotRecorderTests`
- `swift build`
- `git diff --check`

Full `swift test` is not required for this slice unless targeted tests uncover broader regressions.
