# Copy Log Tail Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `Copy Log` button that copies the visible recent app log lines.

**Architecture:** Keep the change local to `ControlView`. Convert the `Log` section title into a header view with a button, and add one helper that copies `model.log.suffix(logDisplayCap)` via `NSPasteboard`.

**Tech Stack:** Swift 6, SwiftUI, AppKit `NSPasteboard`, existing `AppModel`.

## Global Constraints

- Modify production behavior only in `Sources/LiveAstroStudio/ControlView.swift`.
- Add no new persisted state.
- Add no new model, controller, persistence, core, importer, watcher, OBS, or pipeline type.
- Button label must be `Copy Log`.
- Button must be disabled when `model.log.isEmpty`.
- Copied payload must be `model.log.suffix(logDisplayCap).joined(separator: "\n")`.
- Append `Copied log tail` only after setting the pasteboard string.
- Full `swift test` is not required because this is a SwiftUI action/display slice.

---

## File Structure

- Modify `Sources/LiveAstroStudio/ControlView.swift`.
  - Add `copyLogTail()`.
  - Change the `Log` section to use a custom header containing `Copy Log`.
- No new production files.
- No new test files.

---

### Task 1: Add Copy Log Action

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift`

**Interfaces:**
- Consumes: `model.log: [String]`, `logDisplayCap: Int`, `NSPasteboard.general`.
- Produces: `private func copyLogTail()`.

- [ ] **Step 1: Convert the Log section header**

Replace:

```swift
Section("Log") {
    ScrollView {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(model.log.suffix(logDisplayCap).enumerated()), id: \.offset) {
                Text($0.element).font(.system(.caption, design: .monospaced))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }.frame(minHeight: logMinHeight)
}
```

with:

```swift
Section {
    ScrollView {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(model.log.suffix(logDisplayCap).enumerated()), id: \.offset) {
                Text($0.element).font(.system(.caption, design: .monospaced))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }.frame(minHeight: logMinHeight)
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

- [ ] **Step 2: Add `copyLogTail()`**

Near `copyHealthSnapshot()`, add:

```swift
private func copyLogTail() {
    let tail = model.log.suffix(logDisplayCap).joined(separator: "\n")
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(tail, forType: .string)
    model.log.append("Copied log tail")
}
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
git commit -m "feat: copy visible log tail"
```

---

### Task 2: Final Verification and Push Readiness

**Files:**
- No code changes expected.

**Interfaces:**
- Consumes committed Task 1.
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
git show --stat --oneline HEAD
git diff HEAD~1..HEAD -- Sources/LiveAstroStudio/ControlView.swift
```

Expected:

- The only production file changed is `Sources/LiveAstroStudio/ControlView.swift`.
- The diff adds only `copyLogTail()` and the `Copy Log` section-header button.

- [ ] **Step 3: Report**

Report commit hash, verification output, and whether GUI smoke was performed.
