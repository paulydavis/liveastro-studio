# Output Footprint Guardrail Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a user-triggered output-size readout for the LiveAstro output root and last session folder.

**Architecture:** Add a small Foundation-only `DirectoryFootprint` utility in LiveAstroCore with targeted tests. Wire it into `ControlView` behind a `Refresh Sizes` button so recursive filesystem scanning happens only on explicit user action.

**Tech Stack:** Swift 6, Foundation `FileManager`, SwiftUI, XCTest.

## Global Constraints

- Recursive size calculation must be user-triggered only.
- Do not scan output folders from SwiftUI body/render.
- Add no cleanup/delete behavior.
- Add no new persisted state.
- Add no session/replay/snapshot generation changes.
- Button label must be `Refresh Sizes`.
- Default display must be `Output footprint: not checked`.
- Failure display must be `Output footprint: unavailable`.
- Failure log line must begin `Could not calculate output footprint: `.

---

## File Structure

- Create `Sources/LiveAstroCore/Util/DirectoryFootprint.swift`.
- Create `Tests/LiveAstroCoreTests/DirectoryFootprintTests.swift`.
- Modify `Sources/LiveAstroStudio/ControlView.swift`.
  - Add state text.
  - Add refresh action.
  - Display output footprint in Session Outputs.
  - Include output footprint in support bundle.

---

### Task 1: Add DirectoryFootprint Tests

**Files:**
- Create: `Tests/LiveAstroCoreTests/DirectoryFootprintTests.swift`

**Interfaces:**
- Consumes future `DirectoryFootprint.byteCount(at:fileManager:) throws -> Int64`.
- Produces tests for the utility.

- [ ] **Step 1: Create test file**

Create `Tests/LiveAstroCoreTests/DirectoryFootprintTests.swift`:

```swift
import XCTest
@testable import LiveAstroCore

final class DirectoryFootprintTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("footprint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testByteCountSumsNestedRegularFiles() throws {
        try Data(repeating: 0x01, count: 10).write(to: root.appendingPathComponent("a.bin"))
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 0x02, count: 25).write(to: nested.appendingPathComponent("b.bin"))

        let bytes = try DirectoryFootprint.byteCount(at: root)

        XCTAssertEqual(bytes, 35)
    }

    func testByteCountReturnsZeroForEmptyDirectory() throws {
        XCTAssertEqual(try DirectoryFootprint.byteCount(at: root), 0)
    }

    func testByteCountThrowsForMissingRoot() throws {
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        XCTAssertThrowsError(try DirectoryFootprint.byteCount(at: missing))
    }
}
```

- [ ] **Step 2: Run red test**

Run:

```bash
swift test --filter DirectoryFootprintTests
```

Expected before implementation: fails to compile because `DirectoryFootprint` is missing.

- [ ] **Step 3: Commit tests**

Run:

```bash
git add Tests/LiveAstroCoreTests/DirectoryFootprintTests.swift
git commit -m "test: pin directory footprint sizing"
```

---

### Task 2: Implement DirectoryFootprint

**Files:**
- Create: `Sources/LiveAstroCore/Util/DirectoryFootprint.swift`

**Interfaces:**
- Produces: `public enum DirectoryFootprint` with `public static func byteCount(at:fileManager:) throws -> Int64`.

- [ ] **Step 1: Create implementation**

Create `Sources/LiveAstroCore/Util/DirectoryFootprint.swift`:

```swift
import Foundation

public enum DirectoryFootprint {
    public static func byteCount(at root: URL, fileManager: FileManager = .default) throws -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
```

- [ ] **Step 2: Run green targeted test**

Run:

```bash
swift test --filter DirectoryFootprintTests
```

Expected: all `DirectoryFootprintTests` pass.

- [ ] **Step 3: Commit implementation**

Run:

```bash
git add Sources/LiveAstroCore/Util/DirectoryFootprint.swift
git commit -m "feat: add directory footprint sizing"
```

---

### Task 3: Wire Output Footprint into ControlView

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift`

**Interfaces:**
- Consumes:
  - `DirectoryFootprint.byteCount(at:)`
  - `model.liveAstroRoot`
  - `model.lastSessionDirectory`
- Produces:
  - `@State private var outputFootprintText = "not checked"`
  - `private func refreshOutputFootprint()`

- [ ] **Step 1: Add state**

Inside `ControlView`, below existing constants:

```swift
@State private var outputFootprintText = "not checked"
```

- [ ] **Step 2: Add display and button**

In the `Session Outputs` header row, before `Open Sessions Folder`, add:

```swift
Text("Output footprint: \(outputFootprintText)")
    .font(.caption2)
    .foregroundStyle(.secondary)
Button("Refresh Sizes") { refreshOutputFootprint() }
    .help("Calculate the size of the LiveAstro output root and latest session folder.")
```

- [ ] **Step 3: Add support bundle line**

In `copySupportBundle()`, add this line in the `Session Outputs` section:

```swift
Output footprint: \(outputFootprintText)
```

- [ ] **Step 4: Add refresh helper**

Near output helper functions, add:

```swift
private func refreshOutputFootprint() {
    do {
        let rootBytes = try DirectoryFootprint.byteCount(at: model.liveAstroRoot)
        let rootSize = ByteCountFormatter.string(fromByteCount: rootBytes, countStyle: .file)
        if let session = model.lastSessionDirectory {
            let sessionBytes = try DirectoryFootprint.byteCount(at: session)
            let sessionSize = ByteCountFormatter.string(fromByteCount: sessionBytes, countStyle: .file)
            outputFootprintText = "root \(rootSize) · last session \(sessionSize)"
        } else {
            outputFootprintText = "root \(rootSize)"
        }
        model.log.append("Refreshed output footprint")
    } catch {
        outputFootprintText = "unavailable"
        model.log.append("Could not calculate output footprint: \(error.localizedDescription)")
    }
}
```

- [ ] **Step 5: Run compile check**

Run:

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 6: Commit UI wiring**

Run:

```bash
git add Sources/LiveAstroStudio/ControlView.swift
git commit -m "feat: show output footprint guardrail"
```

---

### Task 4: Final Verification and Push Readiness

**Files:**
- No code changes expected.

- [ ] **Step 1: Run final gates**

Run:

```bash
swift test --filter DirectoryFootprintTests
swift build
git diff --check
git status --short --branch
```

Expected:

- `DirectoryFootprintTests` pass.
- `swift build` succeeds.
- `git diff --check` prints nothing.
- `git status --short --branch` shows a clean feature branch.

- [ ] **Step 2: Inspect final diff**

Run:

```bash
git show --stat --oneline HEAD~3..HEAD
git diff HEAD~3..HEAD -- Sources/LiveAstroCore/Util/DirectoryFootprint.swift Tests/LiveAstroCoreTests/DirectoryFootprintTests.swift Sources/LiveAstroStudio/ControlView.swift
```

Expected:

- New core utility and targeted tests.
- `ControlView` only adds explicit refresh/display/support-bundle wiring.
- No generation/persistence behavior changes.

- [ ] **Step 3: Report**

Report commit range, verification output, and whether full suite was skipped with rationale.
