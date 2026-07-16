# Inter-frame Import Batching (N-way) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import a folder of subs across a frame-per-core worker pool — register+warp run in parallel, a single serial consumer commits in completion order — cutting batch-import wall-clock while keeping the final stack correct.

**Architecture:** Split `StackEngine.process` into staged methods (`seedReference`/`register`/`warp`/`commit`) so registration+warp are pure and concurrent against an immutable reference. A new `BatchImporter` seeds serially, then runs register+warp across a bounded `withTaskGroup` pool; the group's parent task drains completions serially and commits (completion order). The live `process` path is untouched; only the Import path is rewired.

**Tech Stack:** Swift 5.10, SwiftPM, XCTest, Foundation (structured concurrency). Zero external dependencies.

## Global Constraints

- Swift 5.10, macOS 14+.
- `LiveAstroCore` imports Foundation / CoreGraphics / Accelerate only. `BatchImporter` uses Foundation.
- Zero external dependencies.
- Core logic TDD'd (`swift test --filter LiveAstroCoreTests`).
- Live (watch-folder) path unchanged; batching is Import-only.
- Reuse sub-pillar-1's `minRows` knobs — batch calls all stages with `minRows: .max` (intra-frame fanout OFF per worker, so frame-level parallelism doesn't oversubscribe cores).
- Correctness vs serial: accepted/rejected counts and coverage map EXACTLY equal; final mean within `1e-4` max abs diff (float accumulation order differs — accepted tradeoff).
- No mid-batch auto-reseed (batch import assumes one coherent target).
- Pool size = `max(1, min(ProcessInfo.processInfo.activeProcessorCount, 6))` (memory cap for 26MP).
- Co-Authored-By Claude trailer allowed in this repo.

---

### Task 1: `StackEngine` staged API (TDD)

**Files:**
- Modify: `Sources/LiveAstroCore/Stacking/StackEngine.swift` (add `RegisteredFrame` + staged methods; thread `minRows` into `displayRGB`; keep `process` unchanged)
- Test: `Tests/LiveAstroCoreTests/StackEngineStagedTests.swift`

**Interfaces:**
- Consumes: existing `StarDetector.detect`, `TriangleMatcher.correspondences`, `TransformSolver.solve`, `Warp.apply(_:transform:minRows:)`, `StackAccumulator.add(_:mask:minRows:)`, `Self.halfResLuminance(frame:minRows:)`, `Debayer.bilinear(cfa:pattern:minRows:)`.
- Produces:
  - `public struct StackEngine.RegisteredFrame { let transform: SimilarityTransform; let rgb: AstroImage }`
  - `func seedReference(_ frame: RawFrame, minRows: Int) -> Bool`
  - `func register(_ frame: RawFrame, minRows: Int) -> RegisteredFrame?`
  - `func warp(_ reg: RegisteredFrame, minRows: Int) -> (image: AstroImage, mask: [Float])`
  - `func commit(image: AstroImage, mask: [Float], minRows: Int)`
  - `func commitRejection()`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LiveAstroCoreTests/StackEngineStagedTests.swift`:

```swift
import XCTest
@testable import LiveAstroCore

final class StackEngineStagedTests: XCTestCase {
    // Gray CFA starfield (same generator as StackEngineTests).
    func cfaFrame(width: Int = 512, height: Int = 512,
                  stars: [(x: Double, y: Double)], amp: Float = 0.8,
                  name: String = "test.fit") -> RawFrame {
        var px = [Float](repeating: 0.05, count: width * height)
        for s in stars {
            for y in max(0, Int(s.y) - 8)...min(height - 1, Int(s.y) + 8) {
                for x in max(0, Int(s.x) - 8)...min(width - 1, Int(s.x) + 8) {
                    let dx = Double(x) - s.x, dy = Double(y) - s.y
                    px[y * width + x] += amp * Float(exp(-(dx * dx + dy * dy) / (2 * 3.0 * 3.0)))
                }
            }
        }
        let img = AstroImage(width: width, height: height, channels: 1, pixels: px, sourceIsLinear: true)
        return RawFrame(image: img, bayerPattern: .grbg, bottomUp: false,
                        timestamp: Date(timeIntervalSince1970: 0), sourceName: name)
    }
    let field: [(x: Double, y: Double)] = [
        (60.2, 80.5), (400.7, 90.1), (200.3, 300.9), (350.5, 420.2), (100.8, 380.4),
        (250.1, 150.6), (450.3, 250.8), (80.9, 200.2), (320.4, 60.7), (180.6, 460.3),
        (420.2, 380.5), (140.7, 120.9), (280.8, 400.1), (380.1, 160.3), (60.5, 300.7),
        (460.6, 460.9), (240.2, 240.4), (120.3, 40.6), (40.7, 440.8), (340.9, 340.2),
    ]

    func testSeedReferenceSucceedsOnStarryFrameAndFailsOnEmpty() {
        let engine = StackEngine()
        XCTAssertFalse(engine.seedReference(cfaFrame(stars: []), minRows: .max))
        XCTAssertEqual(engine.rejectedCount, 1)
        XCTAssertTrue(engine.seedReference(cfaFrame(stars: field), minRows: .max))
        XCTAssertEqual(engine.acceptedCount, 1)
        XCTAssertEqual(engine.stackFrameCount, 1)
    }

    func testRegisterReturnsNilBeforeSeedAndForStarless() {
        let engine = StackEngine()
        // No reference yet → register returns nil (does not mutate).
        XCTAssertNil(engine.register(cfaFrame(stars: field), minRows: .max))
        XCTAssertEqual(engine.acceptedCount, 0)
        XCTAssertEqual(engine.rejectedCount, 0)
        _ = engine.seedReference(cfaFrame(stars: field), minRows: .max)
        XCTAssertNil(engine.register(cfaFrame(stars: []), minRows: .max))     // too few stars
    }

    func testStagedRegisterWarpCommitEqualsMonolithicProcess() {
        let shifted = field.map { (x: $0.x + 4.6, y: $0.y - 2.2) }

        // Monolithic reference: process seed then a translated frame.
        let mono = StackEngine()
        XCTAssertEqual(mono.process(cfaFrame(stars: field, name: "a")), .becameReference)
        XCTAssertEqual(mono.process(cfaFrame(stars: shifted, name: "b")), .stacked(frameCount: 2))

        // Staged: seed then register→warp→commit the same translated frame.
        let staged = StackEngine()
        XCTAssertTrue(staged.seedReference(cfaFrame(stars: field, name: "a"), minRows: .max))
        let reg = staged.register(cfaFrame(stars: shifted, name: "b"), minRows: .max)
        XCTAssertNotNil(reg)
        let w = staged.warp(reg!, minRows: .max)
        staged.commit(image: w.image, mask: w.mask, minRows: .max)

        XCTAssertEqual(staged.acceptedCount, mono.acceptedCount)   // both 2
        XCTAssertEqual(staged.stackFrameCount, mono.stackFrameCount)
        // Same code path, same order → byte-identical stack.
        XCTAssertEqual(staged.currentStack()!.pixels, mono.currentStack()!.pixels)
        XCTAssertEqual(staged.currentCoverage()!, mono.currentCoverage()!)
    }

    func testCommitRejectionBumpsRejectedCount() {
        let engine = StackEngine()
        _ = engine.seedReference(cfaFrame(stars: field), minRows: .max)
        engine.commitRejection()
        XCTAssertEqual(engine.rejectedCount, 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter StackEngineStagedTests`
Expected: FAIL — `value of type 'StackEngine' has no member 'seedReference'` etc.

- [ ] **Step 3: Thread `minRows` into `displayRGB`**

In `Sources/LiveAstroCore/Stacking/StackEngine.swift`, change the private `displayRGB` signature and its debayer call:

```swift
    private func displayRGB(_ frame: RawFrame, minRows: Int = 64) -> AstroImage {
        var rgb: AstroImage
        if let pattern = frame.bayerPattern, frame.image.channels == 1 {
            rgb = Debayer.bilinear(cfa: frame.image, pattern: pattern, minRows: minRows)
        } else {
            rgb = frame.image
        }
        guard frame.bottomUp else { return rgb }
        let w = rgb.width, h = rgb.height, plane = w * h
        var flipped = [Float](repeating: 0, count: rgb.pixels.count)
        for c in 0..<rgb.channels {
            for y in 0..<h {
                let src = c * plane + (h - 1 - y) * w
                let dst = c * plane + y * w
                flipped.replaceSubrange(dst..<(dst + w), with: rgb.pixels[src..<(src + w)])
            }
        }
        return AstroImage(width: w, height: h, channels: rgb.channels,
                          pixels: flipped, sourceIsLinear: rgb.sourceIsLinear)
    }
```

The existing `process`/`processLocked` call `displayRGB(frame)` — unchanged (defaults to `minRows: 64`, parallel, as today).

- [ ] **Step 4: Add the `RegisteredFrame` type and staged methods**

In `Sources/LiveAstroCore/Stacking/StackEngine.swift`, add inside the class (after `process`/`processLocked`):

```swift
    /// A frame that registered against the current reference; ready to warp+commit.
    public struct RegisteredFrame {
        public let transform: SimilarityTransform   // half-res transform (lift in warp)
        public let rgb: AstroImage                  // display-oriented RGB
    }

    /// Establish the fixed reference from `frame` if it has ≥ seedMinStars.
    /// Returns true on success (frame counts as accepted). Serial — call before
    /// any concurrent register(). Bumps rejectedCount on a too-few-stars frame.
    public func seedReference(_ frame: RawFrame, minRows: Int) -> Bool {
        lock.withLock {
            let raw = frame.image
            guard raw.width >= 2, raw.height >= 2 else { rejectedCount += 1; return false }
            let (lum, hw, hh) = Self.halfResLuminance(frame: frame, minRows: minRows)
            let stars = StarDetector.detect(luminance: lum, width: hw, height: hh)
            guard stars.count >= seedMinStars else { rejectedCount += 1; return false }
            let rgb = displayRGB(frame, minRows: minRows)
            let ones = [Float](repeating: 1, count: rgb.width * rgb.height)
            let seed = rejection.apply(rgb, mask: ones)
            let acc = StackAccumulator(width: rgb.width, height: rgb.height, channels: rgb.channels)
            acc.add(seed, mask: ones, minRows: minRows)
            accumulator = acc
            referenceStars = stars
            referenceSize = (raw.width, raw.height)
            referenceChannels = rgb.channels
            acceptedCount += 1
            consecutiveNoTransform = 0
            return true
        }
    }

    /// Register `frame` against the ALREADY-SEEDED, immutable reference. Pure —
    /// mutates no engine state, so it is safe to call concurrently from a worker
    /// pool (reference state is set once by seedReference before the pool starts
    /// and is never mutated during batch import). Returns nil if rejected.
    public func register(_ frame: RawFrame, minRows: Int) -> RegisteredFrame? {
        let raw = frame.image
        guard raw.width >= 2, raw.height >= 2 else { return nil }
        guard let refSize = referenceSize, refSize == (raw.width, raw.height) else { return nil }
        let (lum, hw, hh) = Self.halfResLuminance(frame: frame, minRows: minRows)
        let stars = StarDetector.detect(luminance: lum, width: hw, height: hh)
        guard stars.count >= 3 else { return nil }
        let pairs = TriangleMatcher.correspondences(source: stars, target: referenceStars)
        guard let half = TransformSolver.solve(source: stars, target: referenceStars, pairs: pairs,
                                               minMatches: minMatches, inlierTolerance: inlierTolerance)
        else { return nil }
        let rgb = displayRGB(frame, minRows: minRows)
        guard rgb.channels == referenceChannels else { return nil }
        return RegisteredFrame(transform: half, rgb: rgb)
    }

    /// Warp a registered frame to reference alignment. Pure, concurrent-safe.
    public func warp(_ reg: RegisteredFrame, minRows: Int) -> (image: AstroImage, mask: [Float]) {
        Warp.apply(reg.rgb, transform: reg.transform.liftedToFullResolution(), minRows: minRows)
    }

    /// Accumulate a warped frame into the shared stack under the engine lock.
    /// Bumps acceptedCount. Rejection filtering runs here (serial), preserving any
    /// stateful RejectionMethod. Call from the single serial consumer.
    public func commit(image: AstroImage, mask: [Float], minRows: Int) {
        lock.withLock {
            guard let accumulator else { return }
            let cleaned = rejection.apply(image, mask: mask)
            accumulator.add(cleaned, mask: mask, minRows: minRows)
            acceptedCount += 1
            consecutiveNoTransform = 0
        }
    }

    /// Record a batch rejection (bumps rejectedCount) under the lock.
    public func commitRejection() {
        lock.withLock { rejectedCount += 1 }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter StackEngineStagedTests`
Expected: PASS — all 4 tests green.
Run: `swift test --filter StackEngineTests` and `swift test --filter AutoReseedTests`
Expected: PASS (the monolithic `process` path is unchanged).

- [ ] **Step 6: Commit**

```bash
git add Sources/LiveAstroCore/Stacking/StackEngine.swift Tests/LiveAstroCoreTests/StackEngineStagedTests.swift
git commit -m "feat: StackEngine staged API (seed/register/warp/commit) for concurrent import (TDD)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `BatchImporter` orchestrator (TDD)

**Files:**
- Create: `Sources/LiveAstroCore/Pipeline/BatchImporter.swift`
- Test: `Tests/LiveAstroCoreTests/BatchImporterTests.swift`

**Interfaces:**
- Consumes: `StackEngine.seedReference/register/warp/commit/commitRejection` (Task 1); `FrameSource` (`frames: AsyncStream<RawFrame>`, `isFinite`, `totalCount`, `start()`, `stop()`).
- Produces:
  - `public final class BatchImporter { public init(engine: StackEngine, poolSize: Int? = nil) }`
  - `public struct BatchImporter.Committed { public let index: Int; public let sourceName: String; public let timestamp: Date }`
  - `public func run(source: FrameSource, prepare: @escaping (RawFrame) -> RawFrame = { $0 }, onCommitted: @escaping (Committed) -> Void, onRejected: @escaping (String) -> Void, isCancelled: @escaping () -> Bool) async`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LiveAstroCoreTests/BatchImporterTests.swift`:

```swift
import XCTest
@testable import LiveAstroCore

final class BatchImporterTests: XCTestCase {
    // Gray CFA starfield (same generator as StackEngineTests).
    func cfaFrame(stars: [(x: Double, y: Double)], name: String) -> RawFrame {
        let width = 512, height = 512
        var px = [Float](repeating: 0.05, count: width * height)
        for s in stars {
            for y in max(0, Int(s.y) - 8)...min(height - 1, Int(s.y) + 8) {
                for x in max(0, Int(s.x) - 8)...min(width - 1, Int(s.x) + 8) {
                    let dx = Double(x) - s.x, dy = Double(y) - s.y
                    px[y * width + x] += 0.8 * Float(exp(-(dx * dx + dy * dy) / (2 * 3.0 * 3.0)))
                }
            }
        }
        let img = AstroImage(width: width, height: height, channels: 1, pixels: px, sourceIsLinear: true)
        return RawFrame(image: img, bayerPattern: .grbg, bottomUp: false,
                        timestamp: Date(timeIntervalSince1970: 0), sourceName: name)
    }
    let field: [(x: Double, y: Double)] = [
        (60.2, 80.5), (400.7, 90.1), (200.3, 300.9), (350.5, 420.2), (100.8, 380.4),
        (250.1, 150.6), (450.3, 250.8), (80.9, 200.2), (320.4, 60.7), (180.6, 460.3),
        (420.2, 380.5), (140.7, 120.9), (280.8, 400.1), (380.1, 160.3), (60.5, 300.7),
        (460.6, 460.9), (240.2, 240.4), (120.3, 40.6), (40.7, 440.8), (340.9, 340.2),
    ]

    // In-memory FrameSource yielding a fixed list.
    final class ArrayFrameSource: FrameSource {
        let list: [RawFrame]
        init(_ list: [RawFrame]) { self.list = list }
        var frames: AsyncStream<RawFrame> {
            AsyncStream { cont in
                for f in list { cont.yield(f) }
                cont.finish()
            }
        }
        var isFinite: Bool { true }
        var totalCount: Int? { list.count }
        func start() throws {}
        func stop() {}
    }

    /// N registerable subs: a seed plus jittered copies.
    func makeSubs(_ n: Int) -> [RawFrame] {
        var subs = [cfaFrame(stars: field, name: "sub_000.fit")]
        for i in 1..<n {
            let dx = Double(i % 5) * 1.3 - 2.0, dy = Double(i % 3) * 1.1 - 1.0
            let shifted = field.map { (x: $0.x + dx, y: $0.y + dy) }
            subs.append(cfaFrame(stars: shifted, name: String(format: "sub_%03d.fit", i)))
        }
        return subs
    }

    /// Serial reference: process every sub through the monolithic path.
    func serialStack(_ subs: [RawFrame]) -> (mean: [Float], coverage: [Float], accepted: Int, rejected: Int) {
        let e = StackEngine()
        for f in subs { _ = e.process(f) }
        return (e.currentStack()!.pixels, e.currentCoverage()!, e.acceptedCount, e.rejectedCount)
    }

    func testBatchMatchesSerialCountsAndCoverageAndMeanWithinEpsilon() async {
        let subs = makeSubs(12)
        let ref = serialStack(subs)

        let engine = StackEngine()
        let importer = BatchImporter(engine: engine, poolSize: 4)
        var committed = 0, rejected = 0
        await importer.run(source: ArrayFrameSource(subs),
                           onCommitted: { _ in committed += 1 },
                           onRejected: { _ in rejected += 1 },
                           isCancelled: { false })

        XCTAssertEqual(engine.acceptedCount, ref.accepted)
        XCTAssertEqual(engine.rejectedCount, ref.rejected)
        XCTAssertEqual(committed, ref.accepted)
        XCTAssertEqual(rejected, ref.rejected)
        // Coverage (binary-mask sums) is order-independent → exact.
        XCTAssertEqual(engine.currentCoverage()!, ref.coverage)
        // Mean differs only by float accumulation order → within epsilon.
        let mean = engine.currentStack()!.pixels
        XCTAssertEqual(mean.count, ref.mean.count)
        let maxDiff = zip(mean, ref.mean).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(maxDiff, 1e-4)
    }

    func testSeedsOnFirstStarryFrameSkippingLeadingBlank() async {
        var subs = [cfaFrame(stars: [], name: "blank.fit")]     // leading, too few stars
        subs.append(contentsOf: makeSubs(3))
        let engine = StackEngine()
        let importer = BatchImporter(engine: engine, poolSize: 2)
        await importer.run(source: ArrayFrameSource(subs),
                           onCommitted: { _ in }, onRejected: { _ in }, isCancelled: { false })
        XCTAssertEqual(engine.rejectedCount, 1)      // the blank
        XCTAssertEqual(engine.acceptedCount, 3)      // seed + 2
    }

    func testAllSubsAccountedFor() async {
        let subs = makeSubs(10)
        let engine = StackEngine()
        let importer = BatchImporter(engine: engine, poolSize: 3)
        await importer.run(source: ArrayFrameSource(subs),
                           onCommitted: { _ in }, onRejected: { _ in }, isCancelled: { false })
        XCTAssertEqual(engine.acceptedCount + engine.rejectedCount, subs.count)
    }

    func testStressRepeatedRunsStayConsistent() async {
        let subs = makeSubs(16)
        for _ in 0..<5 {
            let engine = StackEngine()
            let importer = BatchImporter(engine: engine, poolSize: 6)
            await importer.run(source: ArrayFrameSource(subs),
                               onCommitted: { _ in }, onRejected: { _ in }, isCancelled: { false })
            XCTAssertEqual(engine.acceptedCount + engine.rejectedCount, subs.count)
            XCTAssertEqual(engine.acceptedCount, 16)   // all register
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BatchImporterTests`
Expected: FAIL — `cannot find 'BatchImporter' in scope`.

- [ ] **Step 3: Write `BatchImporter`**

Create `Sources/LiveAstroCore/Pipeline/BatchImporter.swift`:

```swift
import Foundation

/// Imports a folder of subs across a frame-per-core worker pool: register+warp
/// run in parallel (each single-threaded via minRows: .max so frame-level
/// parallelism does not oversubscribe cores), while a single serial consumer
/// commits results in completion order. Import-only; the live path is untouched.
public final class BatchImporter {
    private let engine: StackEngine
    private let poolSize: Int

    public init(engine: StackEngine, poolSize: Int? = nil) {
        self.engine = engine
        let cores = ProcessInfo.processInfo.activeProcessorCount
        self.poolSize = max(1, min(poolSize ?? cores, 6))
    }

    public struct Committed {
        public let index: Int          // engine.acceptedCount after this commit
        public let sourceName: String
        public let timestamp: Date
    }

    /// One worker's output: a warped frame (nil = rejected).
    private struct Work {
        let warped: (image: AstroImage, mask: [Float])?
        let name: String
        let timestamp: Date
    }

    /// Run the import. Callbacks fire serially (from the single consumer) in
    /// completion order. `prepare` (e.g. calibration) runs per-frame in the worker.
    public func run(source: FrameSource,
                    prepare: @escaping (RawFrame) -> RawFrame = { $0 },
                    onCommitted: @escaping (Committed) -> Void,
                    onRejected: @escaping (String) -> Void,
                    isCancelled: @escaping () -> Bool) async {
        var iterator = source.frames.makeAsyncIterator()

        // 1. Seed serially on the first adequate frame.
        var seeded = false
        while !seeded {
            if isCancelled() { return }
            guard let frame = await iterator.next() else { return }   // stream ended before a seed
            let prepared = prepare(frame)
            if engine.seedReference(prepared, minRows: .max) {
                seeded = true
                onCommitted(Committed(index: engine.acceptedCount, sourceName: frame.sourceName, timestamp: frame.timestamp))
            } else {
                onRejected(frame.sourceName)
            }
        }

        // 2. Bounded parallel register+warp; serial commit in completion order.
        let engine = self.engine
        let pool = poolSize
        await withTaskGroup(of: Work.self) { group in
            var inFlight = 0

            func addNext() async -> Bool {
                if isCancelled() { return false }
                guard let frame = await iterator.next() else { return false }
                group.addTask {
                    let prepared = prepare(frame)
                    if let reg = engine.register(prepared, minRows: .max) {
                        let w = engine.warp(reg, minRows: .max)
                        return Work(warped: w, name: frame.sourceName, timestamp: frame.timestamp)
                    }
                    return Work(warped: nil, name: frame.sourceName, timestamp: frame.timestamp)
                }
                inFlight += 1
                return true
            }

            while inFlight < pool { if !(await addNext()) { break } }

            while inFlight > 0 {
                guard let work = await group.next() else { break }
                inFlight -= 1
                if let w = work.warped {
                    engine.commit(image: w.image, mask: w.mask, minRows: .max)
                    onCommitted(Committed(index: engine.acceptedCount, sourceName: work.name, timestamp: work.timestamp))
                } else {
                    engine.commitRejection()
                    onRejected(work.name)
                }
                _ = await addNext()
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BatchImporterTests`
Expected: PASS — 4 tests green (counts + coverage exact, mean within 1e-4, seed-skip, all-accounted, stress).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Pipeline/BatchImporter.swift Tests/LiveAstroCoreTests/BatchImporterTests.swift
git commit -m "feat: BatchImporter — frame-per-core parallel import, serial commit (TDD)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Wire the Import path through `BatchImporter`

**Files:**
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift` (route finite/importOnce native source through `BatchImporter`; extract per-frame finalize from `handleNative`; keep live/watcher + live-native paths unchanged)

**Interfaces:**
- Consumes: `BatchImporter.run(source:prepare:onCommitted:onRejected:isCancelled:)` and `BatchImporter.Committed` (Task 2).
- Produces: nothing consumed by later tasks (final task).

- [ ] **Step 1: Extract the per-frame finalize helpers**

In `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift`, add two private methods that do exactly what `handleNative`'s success/rejection branches do (snapshot save + callbacks). These run on the single serial consumer (`BatchImporter`'s completion loop), so they need no extra locking:

```swift
    /// Finalize one committed frame (import batch path): snapshot + progress.
    /// Called serially by BatchImporter in completion order.
    private func finalizeCommitted(index: Int, sourceName: String, timestamp: Date, engine: StackEngine) {
        processedCount += 1
        guard let mean = engine.currentStack() else { return }
        guard let recorder else { onLog?("recorder missing — frame dropped (\(sourceName))"); return }
        do {
            let cg = try displayCGImage(from: mean)
            let record = try recorder.save(
                cgImage: cg, linear: mean, sourceFile: sourceName,
                index: index, timestamp: timestamp,
                estimatedIntegrationSeconds: Double(engine.stackFrameCount) * profile.subExposureSeconds)
            try session.recordSnapshot(record)
            onUpdate?(cg, record)
        } catch {
            onLog?("Skipped frame (\(sourceName)): \(error)")
        }
        if let total = source?.totalCount {
            onImportProgress?(processedCount, total, engine.acceptedCount, engine.rejectedCount)
        }
    }

    private func finalizeRejected(sourceName: String, engine: StackEngine) {
        processedCount += 1
        onRejected?(.noTransform, sourceName)
        onLog?("Rejected \(sourceName)")
        if let total = source?.totalCount {
            onImportProgress?(processedCount, total, engine.acceptedCount, engine.rejectedCount)
        }
    }
```

- [ ] **Step 2: Route finite native sources through `BatchImporter` in `start()`**

In `SessionPipeline.start()`, replace the native-mode branch (currently the `if let src = source, let eng = engine { … for await frame in src.frames { handleNative … } }`) so a FINITE source (importOnce) uses `BatchImporter`, while an infinite source (live) keeps the existing serial `handleNative` loop:

```swift
        if let src = source, let eng = engine {
            // Native stacking mode
            calibrator?.onLog = { [weak self] in self?.onLog?($0) }
            try src.start()
            let done = consumeDone
            if src.isFinite {
                // IMPORT: frame-per-core parallel batch.
                let cal = calibrator
                let importer = BatchImporter(engine: eng)
                consumeTask = Task.detached(priority: .userInitiated) { [weak self] in
                    await importer.run(
                        source: src,
                        prepare: { cal?.apply($0) ?? $0 },
                        onCommitted: { c in
                            Task { @MainActor in }   // no-op; finalize is sync below
                            self?.captureMetadataAndFinalize(committed: c, engine: eng)
                        },
                        onRejected: { name in self?.finalizeRejected(sourceName: name, engine: eng) },
                        isCancelled: { self?.cancelled.isSet ?? true })
                    done.signal()
                }
            } else {
                // LIVE: serial (frames trickle in).
                consumeTask = Task.detached(priority: .userInitiated) { [weak self] in
                    for await frame in src.frames { self?.handleNative(frame, engine: eng) }
                    done.signal()
                }
            }
        } else {
            // Watcher mode (unchanged)
            try watcher?.start()
            let done = consumeDone
            consumeTask = Task.detached(priority: .userInitiated) { [weak self] in
                guard let stream = self?.watcher?.updates else { done.signal(); return }
                for await update in stream { self?.handle(update) }
                done.signal()
            }
        }
```

Add the small metadata-capturing wrapper (mirrors `handleNative`'s `sourceMetadata` capture; the first committed frame carries it — but batch commits carry only names, so capture from the seed via the source's first frame is unavailable here; instead capture lazily is dropped for import — see note) as:

```swift
    private func captureMetadataAndFinalize(committed c: BatchImporter.Committed, engine: StackEngine) {
        finalizeCommitted(index: c.index, sourceName: c.sourceName, timestamp: c.timestamp, engine: engine)
    }
```

**Note on `sourceMetadata`:** the serial path set `sourceMetadata` from the first frame's `metadata` for the v1.1 cloud gate. The batch `Committed` struct does not carry `metadata`. This is acceptable for v1 import (the master.fit + snapshots are produced identically); if metadata is needed later, add a `metadata` field to `Committed` and capture it in `finalizeCommitted`. Record this as a ledgered follow-up rather than expanding scope here.

- [ ] **Step 3: Build (debug) to verify it compiles**

Run: `swift build`
Expected: `Build complete!` with no errors. (Swift 5 language mode: capturing the non-Sendable `StackEngine`/`Calibrator` in the task closures compiles; no strict-concurrency errors.)

- [ ] **Step 4: Full Core suite green + release build**

Run: `swift test --filter LiveAstroCoreTests`
Expected: all pass — including the existing SessionPipeline e2e import test (the batch path must produce a valid master.fit + snapshots). If the e2e test asserts strict per-frame snapshot ORDER, relax it to assert the final master + accepted count (import snapshots now arrive in completion order); update that assertion in the same commit and note it.
Run: `swift build -c release`
Expected: succeeds.

- [ ] **Step 5: Manual check (RELEASE)**

`swift build -c release`; launch the app, Import a folder of subs (the fakesiril output or a real ASI2600 set), confirm: progress advances, a correct master builds, wall-clock is faster than before on a multi-sub set, and Cancel mid-import still yields a valid partial master.

- [ ] **Step 6: Commit**

```bash
git add Sources/LiveAstroCore/Pipeline/SessionPipeline.swift
git commit -m "feat: route folder Import through BatchImporter (parallel), live path unchanged

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage:**
- StackEngine staged split (seed/register/warp/commit + commitRejection) → Task 1. ✅
- `register` pure/concurrent against immutable reference; `commit` under lock → Task 1 (documented invariant). ✅
- `BatchImporter` frame-per-core pool, seed-then-parallel, serial commit in completion order, pool cap min(cores,6), `minRows: .max` per worker → Task 2. ✅
- Outcome parity (counts + coverage exact, mean within 1e-4) + seed selection + all-accounted + stress → Task 2 tests. ✅
- Import-only wiring; live/watcher unchanged → Task 3 (branch on `src.isFinite`). ✅
- Cancellation yields valid partial master → Task 2 `isCancelled` + Task 3 manual check; `cancelled.isSet` threaded. ✅
- No mid-batch auto-reseed → staged `register` never reseeds (returns nil, mutates nothing). ✅
- Progressive snapshots on commit (completion order) → Task 3 `finalizeCommitted`. ✅

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code; run steps show command + expected. The `sourceMetadata` gap and the e2e-order assertion are called out explicitly with the concrete handling (ledger / relax-and-note), not left vague.

**3. Type consistency:** `seedReference/register/warp/commit/commitRejection` and `RegisteredFrame` signatures are identical across Task 1 (definition) and Task 2 (calls). `BatchImporter.run(source:prepare:onCommitted:onRejected:isCancelled:)` and `Committed{index,sourceName,timestamp}` match across Task 2 (definition) and Task 3 (calls). `FrameSource` members used (`frames`, `isFinite`, `totalCount`, `start`, `stop`) match the protocol. `minRows: .max` used consistently for all batch stage calls.
