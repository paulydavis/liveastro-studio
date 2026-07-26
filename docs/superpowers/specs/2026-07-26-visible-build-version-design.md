# Visible Build Version Design

## Purpose

Make beta/support conversations easier by showing which LiveAstro build is running and including that identity in copied support text.

## Scope

Add a compact version label in the control footer and include the same value in the support bundle.

Behavior:

- Read version from `Bundle.main.infoDictionary["CFBundleShortVersionString"]`.
- Read build from `Bundle.main.infoDictionary["CFBundleVersion"]`.
- Display `LiveAstro vX` when version and build match.
- Display `LiveAstro vX (build Y)` when version and build differ.
- Display `LiveAstro dev` when packaged bundle metadata is absent.
- Include `App: <same display text>` near the top of the copied support bundle.

## Architecture

Keep this local to `Sources/LiveAstroStudio/ControlView.swift`.

Add one computed property:

```swift
private var appVersionText: String {
    let info = Bundle.main.infoDictionary ?? [:]
    let version = (info["CFBundleShortVersionString"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let build = (info["CFBundleVersion"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard let version, !version.isEmpty else { return "LiveAstro dev" }
    if let build, !build.isEmpty, build != version {
        return "LiveAstro v\(version) (build \(build))"
    }
    return "LiveAstro v\(version)"
}
```

Render it as small secondary text in the fixed footer, after output/progress controls and before the footer padding ends.

Add one support-bundle line:

```text
App: LiveAstro v3.0.1
```

## Non-goals

- No release-version bump.
- No changes to packaging scripts.
- No generated build metadata file.
- No About window.
- No engine, watcher, importer, OBS, persistence, or pipeline behavior changes.

## Verification

- `swift build`
- `git diff --check`
- final diff inspection confirming production behavior changes only in `ControlView.swift`

Full `swift test` is not required because this is a SwiftUI display/support-text slice.
