# Siril Parity Benchmark Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a skipped-by-default XCTest benchmark that compares LiveAstro's production native stack against Siril's `resultat.fit` for a locally supplied corpus.

**Architecture:** Keep everything in the test target. A small test-only metrics helper computes correlations, affine-normalized error, background/star metrics, and report text. The real test drives `FolderFrameSource(.importOnce)` + `BatchImporter` + `StackEngine`, with calibration injected via `BatchImporter.prepare`.

**Tech Stack:** Swift XCTest, LiveAstroCore test target, local FITS corpus via `LIVEASTRO_PARITY_DATASET`, no new dependencies.

## Global Constraints

- Never commit corpus files, derived FITS/PNG data, or parity reports.
- The real corpus test must `XCTSkip` when `LIVEASTRO_PARITY_DATASET` is unset or incomplete.
- Do not change production stacking behavior for parity.
- The benchmark report must always be written for real runs, pass or fail.
- No concurrent SwiftPM commands.

---

### Task 1: Metric Helpers

**Files:**
- Create: `Tests/LiveAstroCoreTests/SirilParityTests.swift`

**Interfaces:**
- Produces:
  - `SirilParityMetrics.pearson(_:_:) -> Double`
  - `SirilParityMetrics.affineNormalizedMAE(reference:candidate:) -> Double`
  - `SirilParityMetrics.luminance(_:) -> (pixels: [Float], width: Int, height: Int)`
  - `SirilParityMetrics.matchedStarMetrics(reference:candidate:) -> (matchedRatio: Double, medianFWHMRatio: Double)`

- [ ] **Step 1: Write failing helper tests**

Add `SirilParityMetricTests` in `SirilParityTests.swift`:

```swift
final class SirilParityMetricTests: XCTestCase {
    func testPearsonDetectsLinearAgreementAndDisagreement() {
        XCTAssertGreaterThan(SirilParityMetrics.pearson([1, 2, 3, 4], [2, 4, 6, 8]), 0.999)
        XCTAssertLessThan(SirilParityMetrics.pearson([1, 2, 3, 4], [8, 6, 4, 2]), -0.999)
    }

    func testAffineNormalizedMAEIgnoresScaleAndOffset() {
        let err = SirilParityMetrics.affineNormalizedMAE(reference: [1, 2, 3, 4], candidate: [12, 14, 16, 18])
        XCTAssertLessThan(err, 1e-6)
    }

    func testLuminanceAveragesRGBPlanes() {
        let image = AstroImage(width: 2, height: 1, channels: 3,
                               pixels: [1, 0, 0,  0, 1, 0],
                               sourceIsLinear: true)
        let lum = SirilParityMetrics.luminance(image)
        XCTAssertEqual(lum.width, 2)
        XCTAssertEqual(lum.height, 1)
        XCTAssertEqual(lum.pixels, [Float(1.0 / 3.0), Float(1.0 / 3.0)])
    }
}
```

- [ ] **Step 2: Run red**

Run: `swift test --filter SirilParityMetricTests`

Expected: fail because `SirilParityMetrics` does not exist.

- [ ] **Step 3: Implement helper**

Create an internal `enum SirilParityMetrics` in the same test file. Implement Pearson with double-precision sums, affine-normalized MAE by least-squares fitting `candidate ≈ a * reference + b`, and luminance as mono passthrough or per-pixel RGB average across planes.

- [ ] **Step 4: Run green**

Run: `swift test --filter SirilParityMetricTests`

Expected: all helper tests pass.

- [ ] **Step 5: Commit**

```bash
git add Tests/LiveAstroCoreTests/SirilParityTests.swift
git commit -m "test: add siril parity metric helpers"
```

---

### Task 2: Dataset Loader and Skip Contract

**Files:**
- Modify: `Tests/LiveAstroCoreTests/SirilParityTests.swift`

**Interfaces:**
- Produces:
  - `SirilParityDataset.fromEnvironment() throws -> SirilParityDataset`
  - `SirilParityDataset` with `root`, `lights`, `darks`, `flats`, `biases`, `sirilMaster`.

- [ ] **Step 1: Write failing skip/loader tests**

Add:

```swift
final class SirilParityDatasetTests: XCTestCase {
    func testDatasetLoaderReportsSkipWhenEnvMissing() {
        XCTAssertThrowsError(try SirilParityDataset.fromEnvironment(environment: [:])) { error in
            guard case XCTSkip = error else { return XCTFail("expected XCTSkip, got \(error)") }
        }
    }

    func testDatasetLoaderFindsExpectedFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Brutes_180s", "Darks_180s", "Flats_3s", "Offsets_3s"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            try Data().write(to: root.appendingPathComponent(name).appendingPathComponent("one.fit"))
        }
        try Data().write(to: root.appendingPathComponent("resultat.fit"))

        let dataset = try SirilParityDataset.fromEnvironment(environment: ["LIVEASTRO_PARITY_DATASET": root.path])
        XCTAssertEqual(dataset.lights.count, 1)
        XCTAssertEqual(dataset.darks.count, 1)
        XCTAssertEqual(dataset.flats.count, 1)
        XCTAssertEqual(dataset.biases.count, 1)
        XCTAssertEqual(dataset.sirilMaster.lastPathComponent, "resultat.fit")
    }
}
```

- [ ] **Step 2: Run red**

Run: `swift test --filter SirilParityDatasetTests`

Expected: fail because `SirilParityDataset` does not exist.

- [ ] **Step 3: Implement loader**

Implement `SirilParityDataset.fromEnvironment(environment:)`. Sort FITS URLs by `lastPathComponent`. Throw `XCTSkip` when env var is missing, path is incomplete, or any required folder/file is absent.

- [ ] **Step 4: Run green**

Run: `swift test --filter SirilParityDatasetTests`

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Tests/LiveAstroCoreTests/SirilParityTests.swift
git commit -m "test: add siril parity dataset skip contract"
```

---

### Task 3: Real Corpus Pipeline and Report

**Files:**
- Modify: `Tests/LiveAstroCoreTests/SirilParityTests.swift`

**Interfaces:**
- Consumes `SirilParityDataset`, `SirilParityMetrics`.
- Produces:
  - `SirilParityTests.testLiveAstroNativeStackMatchesSirilReference() async throws`
  - local markdown report artifact in a temporary directory.

- [ ] **Step 1: Write the real benchmark test**

Add `SirilParityTests`:

```swift
final class SirilParityTests: XCTestCase {
    func testLiveAstroNativeStackMatchesSirilReference() async throws {
        let dataset = try SirilParityDataset.fromEnvironment()
        let report = try await SirilParityRunner.run(dataset: dataset)
        print("Siril parity report: \(report.reportURL.path)")

        XCTAssertGreaterThanOrEqual(report.acceptedCount, 10)
        XCTAssertEqual(report.liveAstro.width, report.siril.width)
        XCTAssertEqual(report.liveAstro.height, report.siril.height)
        for channel in report.channels {
            XCTAssertGreaterThanOrEqual(channel.pearson, 0.94)
            XCTAssertLessThanOrEqual(channel.affineMAE, 0.08)
        }
        XCTAssertGreaterThanOrEqual(report.starMatchedRatio, 0.70)
        XCTAssertLessThanOrEqual(report.starMatchedRatio, 1.30)
        XCTAssertGreaterThanOrEqual(report.medianFWHMRatio, 0.75)
        XCTAssertLessThanOrEqual(report.medianFWHMRatio, 1.35)
        XCTAssertGreaterThanOrEqual(report.backgroundSigmaRatio, 0.50)
        XCTAssertLessThanOrEqual(report.backgroundSigmaRatio, 1.80)
    }
}
```

- [ ] **Step 2: Run red without corpus env**

Run: `swift test --filter SirilParityTests/testLiveAstroNativeStackMatchesSirilReference`

Expected: skipped with a diagnostic because env var is absent.

- [ ] **Step 3: Implement runner**

Implement `SirilParityRunner.run(dataset:)` in the test file:

1. Build bias/dark/flat masters with `MasterBuilder`.
2. Build `Calibrator`.
3. Create `FolderFrameSource(folder: dataset.lightFolder, mode: .importOnce)` and call `start()`.
4. Run `BatchImporter(engine: StackEngine(), poolSize: 4)` with `prepare: calibrator.apply`.
5. Load Siril master using `FITSReader.read(..., normalizeRowOrder: true)`.
6. Compute channel metrics, star metrics, background ratio.
7. Write `parity-report.md` in a temporary directory.

- [ ] **Step 4: Run skip and helper gates**

Run: `swift test --filter 'SirilParityMetricTests|SirilParityDatasetTests|SirilParityTests'`

Expected: helper/dataset tests pass and real corpus test skips unless env var is present.

- [ ] **Step 5: Run real local corpus**

Run: `LIVEASTRO_PARITY_DATASET=/Users/pauldavis/LiveAstroCorpus/siril-m8-asi2600 swift test --filter SirilParityTests/testLiveAstroNativeStackMatchesSirilReference`

Expected: either pass or fail with a report path and measured values. If thresholds fail, inspect the report and adjust only if the failure is a metric calibration issue, not a real harness bug.

- [ ] **Step 6: Full gates**

Run:

```bash
swift test --filter SirilParity
swift test
swift build -c release
git diff --check
```

Expected: skipped-by-default suite remains green; release build clean; diff check clean.

- [ ] **Step 7: Commit**

```bash
git add Tests/LiveAstroCoreTests/SirilParityTests.swift
git commit -m "test: add siril parity benchmark"
```
