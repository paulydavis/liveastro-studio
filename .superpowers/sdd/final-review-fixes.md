# Final-Review Wave — Fix Report

## FIX 1: Concurrent-end guard (AppModel.swift)

**File:** `Sources/LiveAstroStudio/AppModel.swift`

Added `guard !isGeneratingReplay else { return }` immediately after the existing
`guard let p = pipeline else { return }` at the top of `endSession()`.
This ensures that if `endSession()` is called a second time while a replay is
already in progress, the call is silently dropped instead of racing on
`SessionPipeline.end()`.

---

## FIX 2: Session directory collision uniquification (SessionManager.swift + test)

**File:** `Sources/LiveAstroCore/Session/SessionManager.swift`

In `startSession`, if the computed session directory already exists (same
profile + date), the code now loops appending `-2`, `-3`, … until it finds a
name whose path does not exist in the file system.  The
`SessionManifest.sessionId` is set to the final, collision-free name so the
manifest always matches its containing directory.

**Test added:** `SessionManagerTests.testSessionDirCollisionUniquifiesAndPreservesFirst`
- Starts and ends a first session at a fixed date.
- Saves a copy of the first manifest before the second session is created.
- Starts a second session with the same profile + date on the same root directory.
- Asserts the two session directories have different names.
- Asserts the second session's manifest `sessionId` equals its directory name.
- Asserts the first session's `manifest.json` is still decodable and its `sessionId` is unchanged.

---

## FIX 3: BT.709 color tags for YouTube (ReplayGenerator.swift)

**File:** `Sources/LiveAstroCore/Replay/ReplayGenerator.swift`

Added `AVVideoColorPropertiesKey` to the `AVAssetWriterInput` output settings
dictionary containing:
- `AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2`
- `AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2`
- `AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2`

Without these tags, YouTube and other platforms assume BT.601, causing a subtle
color shift on upload.

---

## FIX 4: Bounded keyframe decode for full-res cameras (ReplayGenerator.swift)

**File:** `Sources/LiveAstroCore/Replay/ReplayGenerator.swift`

Replaced `CGImageSourceCreateImageAtIndex(src, 0, nil)` with
`CGImageSourceCreateThumbnailAtIndex(src, 0, opts)` using options:
- `kCGImageSourceCreateThumbnailFromImageAlways: true`
- `kCGImageSourceCreateThumbnailWithTransform: true`
- `kCGImageSourceThumbnailMaxPixelSize: max(settings.width, settings.height)`

A 26 MP raw snapshot (e.g. ZWO ASI2600MC) decodes to ~104 MB when loaded
full-resolution; with dozens of keyframes this previously exhausted memory.
The thumbnail decode caps output at canvas resolution (1920×1080 or configured
size).  Aspect ratio is preserved by the OS thumbnail pipeline, so the existing
`aspectFitRect` layout math is unaffected.  Existing tests use small synthetic
images and continue to pass without modification.

---

## FIX 5: Silent frame-drop check (ReplayGenerator.swift)

**File:** `Sources/LiveAstroCore/Replay/ReplayGenerator.swift`

`AVAssetWriterInputPixelBufferAdaptor.append(_:withPresentationTime:)` returns
`Bool` but the result was previously discarded.  The result is now captured; if
`false`, the code throws:

```
ReplayError.writerFailed(writer.error?.localizedDescription ?? "pixel buffer append failed at frame \(f)")
```

This surfaces `AVAssetWriter` rejections (e.g. out-of-order timestamps,
premature finish) that were previously silently swallowed, producing a
truncated or corrupt output file with no diagnostic.

---

## Test Output (tail)

```
Test Suite 'LiveAstroStudioPackageTests.xctest' passed at 2026-07-05 22:21:41.002.
	 Executed 46 tests, with 0 failures (0 unexpected) in 14.249 (14.252) seconds
Test Suite 'All tests' passed at 2026-07-05 22:21:41.002.
	 Executed 46 tests, with 0 failures (0 unexpected) in 14.249 (14.253) seconds
```

46 tests (was 45; +1 for `testSessionDirCollisionUniquifiesAndPreservesFirst`), 0 failures.
