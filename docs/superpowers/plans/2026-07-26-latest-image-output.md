# Latest Image Output Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Write/update `latest.png` in each session folder whenever a snapshot is successfully recorded.

**Architecture:** Keep the feature in `SnapshotRecorder`. After the numbered snapshot PNG is encoded successfully, copy that file to a hidden temp file and move/replace it into `<session>/latest.png`; treat latest-update failure as auxiliary so the numbered snapshot and returned manifest record still succeed.

**Tech Stack:** Swift 6, Foundation `FileManager`, CoreGraphics/ImageIO existing snapshot path, XCTest.

## Global Constraints

- Modify production behavior only in `Sources/LiveAstroCore/Session/SnapshotRecorder.swift`.
- Modify tests only in `Tests/LiveAstroCoreTests/SnapshotRecorderTests.swift`.
- Do not change `SnapshotRecord`.
- Do not change `SessionManifest`.
- Do not add app UI.
- Do not change replay generation.
- `latest.png` must not be listed in the manifest.
- A failure while updating `latest.png` must not throw from `save(...)` after the numbered snapshot has been written.

---

## File Structure

- Modify `Sources/LiveAstroCore/Session/SnapshotRecorder.swift`.
  - Add private `updateLatestImage(from:)`.
  - Call it after numbered snapshot finalize succeeds.
- Modify `Tests/LiveAstroCoreTests/SnapshotRecorderTests.swift`.
  - Add tests for initial `latest.png` write and update-to-most-recent behavior.

---

### Task 1: Add Failing Latest PNG Tests

**Files:**
- Modify: `Tests/LiveAstroCoreTests/SnapshotRecorderTests.swift`

**Interfaces:**
- Consumes existing `SnapshotRecorder.save(...)`, `ImageLoader.load(url:)`, `AutoStretch.makeCGImage(...)`.
- Produces no production interfaces.

- [ ] **Step 1: Add a tiny image helper**

Inside `SnapshotRecorderTests`, add:

```swift
private func makeImage(width: Int, height: Int, value: Float) -> (AstroImage, CGImage) {
    let img = AstroImage(width: width, height: height, channels: 1,
                         pixels: [Float](repeating: value, count: width * height),
                         sourceIsLinear: true)
    let cg = AutoStretch.makeCGImage(AutoStretch.stretch(img))!
    return (img, cg)
}
```

- [ ] **Step 2: Add `testSaveWritesLatestPNG`**

Add:

```swift
func testSaveWritesLatestPNG() throws {
    let (img, cg) = makeImage(width: 8, height: 6, value: 0.1)

    _ = try SnapshotRecorder(sessionDirectory: tmp).save(
        cgImage: cg, linear: img, sourceFile: "live_stack.fit",
        index: 1, timestamp: Date(), estimatedIntegrationSeconds: 60)

    let latest = tmp.appendingPathComponent("latest.png")
    XCTAssertTrue(FileManager.default.fileExists(atPath: latest.path))
    let decoded = try ImageLoader.load(url: latest)
    XCTAssertEqual(decoded.width, 8)
    XCTAssertEqual(decoded.height, 6)
}
```

- [ ] **Step 3: Add `testLatestPNGTracksMostRecentSnapshot`**

Add:

```swift
func testLatestPNGTracksMostRecentSnapshot() throws {
    let recorder = SnapshotRecorder(sessionDirectory: tmp)
    let (first, firstCG) = makeImage(width: 8, height: 6, value: 0.1)
    let (second, secondCG) = makeImage(width: 4, height: 3, value: 0.5)

    let rec1 = try recorder.save(cgImage: firstCG, linear: first,
                                 sourceFile: "first.fit", index: 1,
                                 timestamp: Date(), estimatedIntegrationSeconds: 60)
    _ = try recorder.save(cgImage: secondCG, linear: second,
                          sourceFile: "second.fit", index: 2,
                          timestamp: Date(), estimatedIntegrationSeconds: 120)

    XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent(rec1.snapshotFile).path))
    let latest = try ImageLoader.load(url: tmp.appendingPathComponent("latest.png"))
    XCTAssertEqual(latest.width, 4)
    XCTAssertEqual(latest.height, 3)
}
```

- [ ] **Step 4: Run red test**

Run:

```bash
swift test --filter SnapshotRecorderTests
```

Expected before implementation: the new latest PNG tests fail because `latest.png` is not created.

- [ ] **Step 5: Commit tests**

Run:

```bash
git add Tests/LiveAstroCoreTests/SnapshotRecorderTests.swift
git commit -m "test: pin latest snapshot output"
```

---

### Task 2: Implement Latest PNG Update

**Files:**
- Modify: `Sources/LiveAstroCore/Session/SnapshotRecorder.swift`

**Interfaces:**
- Consumes existing numbered snapshot URL.
- Produces private helper `updateLatestImage(from snapshotURL: URL)`.

- [ ] **Step 1: Call latest update after numbered finalize**

In `SnapshotRecorder.save(...)`, after:

```swift
guard CGImageDestinationFinalize(dest) else { throw SnapshotError.encodeFailed }
```

add:

```swift
updateLatestImage(from: url)
```

- [ ] **Step 2: Add private helper**

Inside `SnapshotRecorder`, add:

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

- [ ] **Step 3: Run green targeted test**

Run:

```bash
swift test --filter SnapshotRecorderTests
```

Expected after implementation: all `SnapshotRecorderTests` pass.

- [ ] **Step 4: Commit implementation**

Run:

```bash
git add Sources/LiveAstroCore/Session/SnapshotRecorder.swift
git commit -m "feat: write latest snapshot image"
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
swift test --filter SnapshotRecorderTests
swift build
git diff --check
git status --short --branch
```

Expected:

- `SnapshotRecorderTests` pass.
- `swift build` succeeds.
- `git diff --check` prints nothing.
- `git status --short --branch` shows a clean feature branch.

- [ ] **Step 2: Inspect final diff**

Run:

```bash
git show --stat --oneline HEAD~2..HEAD
git diff HEAD~2..HEAD -- Sources/LiveAstroCore/Session/SnapshotRecorder.swift Tests/LiveAstroCoreTests/SnapshotRecorderTests.swift
```

Expected:

- Production diff only changes `SnapshotRecorder.swift`.
- Test diff only changes `SnapshotRecorderTests.swift`.
- `latest.png` is not added to manifest models.

- [ ] **Step 3: Report**

Report commit range, verification output, and whether full suite was skipped with rationale.
