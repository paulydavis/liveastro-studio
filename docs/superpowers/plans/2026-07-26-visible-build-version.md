# Visible Build Version Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the running LiveAstro version/build in the UI and copied support bundle.

**Architecture:** Keep the change local to `ControlView`. Add one computed property that derives display text from `Bundle.main.infoDictionary`, render it in the footer, and include it in `copySupportBundle()`.

**Tech Stack:** Swift 6, SwiftUI, Foundation `Bundle`, existing `ControlView`.

## Global Constraints

- Modify production behavior only in `Sources/LiveAstroStudio/ControlView.swift`.
- Add no new persisted state.
- Add no new model, controller, persistence, core, importer, watcher, OBS, or pipeline type.
- Do not change packaging scripts or bump versions.
- Fallback text must be `LiveAstro dev`.
- Support bundle line must start with `App: `.
- Full `swift test` is not required because this is a SwiftUI display/support-text slice.

---

## File Structure

- Modify `Sources/LiveAstroStudio/ControlView.swift`.
  - Add `appVersionText`.
  - Render `appVersionText` in the footer.
  - Add `App: \(appVersionText)` to `copySupportBundle()`.
- No new production files.
- No new test files.

---

### Task 1: Add Version Text Helper

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift`

**Interfaces:**
- Consumes: `Bundle.main.infoDictionary`.
- Produces: `private var appVersionText: String`.

- [ ] **Step 1: Add `appVersionText`**

Near the other footer display helpers, add:

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

- [ ] **Step 2: Run compile check**

Run:

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

Run:

```bash
git add Sources/LiveAstroStudio/ControlView.swift
git commit -m "feat: derive app version label"
```

---

### Task 2: Render Version and Include It in Support Bundle

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift`

**Interfaces:**
- Consumes: `appVersionText`.
- Produces: visible footer version label and support-bundle `App:` line.

- [ ] **Step 1: Render footer version label**

Near the bottom of the fixed footer `VStack`, after the existing progress controls and before `.padding(...)`, add:

```swift
Text(appVersionText)
    .font(.caption2)
    .foregroundStyle(.tertiary)
    .frame(maxWidth: .infinity, alignment: .trailing)
```

- [ ] **Step 2: Add app line to support bundle**

In `copySupportBundle()`, after `LiveAstro Support Bundle`, add:

```swift
App: \(appVersionText)
```

The start of the string should become:

```swift
let summary = """
LiveAstro Support Bundle
App: \(appVersionText)

Session Health
...
"""
```

- [ ] **Step 3: Run compile check**

Run:

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

Run:

```bash
git add Sources/LiveAstroStudio/ControlView.swift
git commit -m "feat: show app version in support surfaces"
```

---

### Task 3: Final Verification and Push Readiness

**Files:**
- No code changes expected.

**Interfaces:**
- Consumes committed Tasks 1-2.
- Produces verified work ready for merge/push.

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
- The diff adds only `appVersionText`, footer display text, and support-bundle app line.

- [ ] **Step 3: Report**

Report commit range, verification output, and whether GUI smoke was performed.
