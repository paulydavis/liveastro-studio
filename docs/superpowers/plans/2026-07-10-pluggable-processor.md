# Pluggable Processor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add explicit, non-destructive, pluggable post-stack processing (GraXpert background-extraction → denoising) that writes `master_processed.fit` alongside the untouched raw master.

**Architecture:** A `Processor` protocol (like `RejectionMethod`) with a `GraXpertProcessor` backend that shells out to the GraXpert CLI through an injectable `ProcessRunner` seam (real = Foundation `Process`; fake in tests). Triggered by an explicit "Process master" app action mirroring `regenerateReplay`.

**Tech Stack:** Swift 5.10, macOS 14+, LiveAstroCore (Foundation only — `Process` is Foundation), SwiftUI app, XCTest.

## Global Constraints

- Swift 5.10, macOS 14+. LiveAstroCore = **Foundation only** (Foundation `Process` is allowed). Zero third-party deps.
- Core-logic tests: `swift test --filter LiveAstroCoreTests`.
- `GraXpertProcessor` is tested with a **fake `ProcessRunner`** — **NO real GraXpert in CI**.
- Op order: **background-extraction THEN denoising**; a non-zero exit on step 1 must **skip step 2 and throw**.
- `denoiseStrength` default **0.5**; always pass **`-gpu false`**.
- Output is `master_processed.fit`; the **raw `master.fit` is never modified**.
- App wiring (AppModel/ControlView) is **manual-validation** (RELEASE build verified; SwiftUI not unit-tested in scope).
- TDD for all Core-logic tasks; frequent commits.

---

### Task 1: `Processor` protocol + `ProcessorBackend` + `ProcessorError`

**Files:**
- Create: `Sources/LiveAstroCore/Processing/Processor.swift`
- Test: `Tests/LiveAstroCoreTests/ProcessorTests.swift`

**Interfaces:**
- Produces: `public protocol Processor { var name: String { get }; var isAvailable: Bool { get }; func process(masterURL: URL, outputURL: URL, log: ((String)->Void)?) throws }`; `public enum ProcessorBackend: String, CaseIterable, Codable { case none, graxpert }`; `public enum ProcessorError: Error, Equatable { case notAvailable; case stepFailed(cmd: String, code: Int32); case noOutput }`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class ProcessorTests: XCTestCase {
    func testBackendIsCodableStringEnum() throws {
        XCTAssertEqual(ProcessorBackend.allCases, [.none, .graxpert])
        let data = try JSONEncoder().encode(ProcessorBackend.graxpert)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"graxpert\"")
        XCTAssertEqual(try JSONDecoder().decode(ProcessorBackend.self, from: data), .graxpert)
    }

    func testProcessorErrorEquatable() {
        XCTAssertEqual(ProcessorError.noOutput, ProcessorError.noOutput)
        XCTAssertEqual(ProcessorError.stepFailed(cmd: "denoising", code: 1),
                       ProcessorError.stepFailed(cmd: "denoising", code: 1))
        XCTAssertNotEqual(ProcessorError.notAvailable, ProcessorError.noOutput)
    }

    // A trivial conforming type proves the protocol shape compiles/usable.
    private struct StubProcessor: Processor {
        var name = "Stub"; var isAvailable = true
        func process(masterURL: URL, outputURL: URL, log: ((String)->Void)?) throws { log?("ran") }
    }
    func testProtocolIsUsable() throws {
        var msgs: [String] = []
        let p: Processor = StubProcessor()
        try p.process(masterURL: URL(fileURLWithPath: "/a"), outputURL: URL(fileURLWithPath: "/b")) { msgs.append($0) }
        XCTAssertEqual(p.name, "Stub"); XCTAssertTrue(p.isAvailable); XCTAssertEqual(msgs, ["ran"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ProcessorTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'ProcessorBackend' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// A pluggable post-stack image processor (background extraction, denoising, …).
public protocol Processor {
    var name: String { get }
    /// True when the backend can actually run (e.g. its tool is installed).
    var isAvailable: Bool { get }
    /// Read `masterURL`, write the processed result to `outputURL`. Throws on failure.
    func process(masterURL: URL, outputURL: URL, log: ((String) -> Void)?) throws
}

/// User-selectable processing backend.
public enum ProcessorBackend: String, CaseIterable, Codable {
    case none, graxpert
}

public enum ProcessorError: Error, Equatable {
    case notAvailable
    case stepFailed(cmd: String, code: Int32)
    case noOutput
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ProcessorTests 2>&1 | tail -5`
Expected: PASS — 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Processing/Processor.swift Tests/LiveAstroCoreTests/ProcessorTests.swift
git commit -m "feat: Processor protocol + ProcessorBackend + ProcessorError"
```

---

### Task 2: `ProcessRunner` seam + `FoundationProcessRunner`

**Files:**
- Create: `Sources/LiveAstroCore/Processing/ProcessRunner.swift`
- Test: `Tests/LiveAstroCoreTests/ProcessRunnerTests.swift`

**Interfaces:**
- Produces: `public protocol ProcessRunner { func run(executable: URL, arguments: [String], log: ((String)->Void)?) throws -> Int32 }`; `public struct FoundationProcessRunner: ProcessRunner { public init() }`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class ProcessRunnerTests: XCTestCase {
    // Smoke test: the real runner actually launches a process and returns its exit code.
    // Uses /bin/echo (exit 0) and /usr/bin/false (exit 1) — no third-party binary.
    func testFoundationRunnerReturnsExitCodeZero() throws {
        let runner = FoundationProcessRunner()
        var out: [String] = []
        let code = try runner.run(executable: URL(fileURLWithPath: "/bin/echo"),
                                  arguments: ["hello"], log: { out.append($0) })
        XCTAssertEqual(code, 0)
    }

    func testFoundationRunnerReturnsNonZeroExit() throws {
        let runner = FoundationProcessRunner()
        let code = try runner.run(executable: URL(fileURLWithPath: "/usr/bin/false"),
                                  arguments: [], log: nil)
        XCTAssertEqual(code, 1)
    }

    // A fake conforming type proves the protocol is injectable (used heavily in Task 3).
    private struct FakeRunner: ProcessRunner {
        var recorded: [(URL, [String])] = []
        mutating func run(executable: URL, arguments: [String], log: ((String)->Void)?) throws -> Int32 {
            recorded.append((executable, arguments)); return 0
        }
    }
    func testFakeRunnerRecords() throws {
        var f = FakeRunner()
        _ = try f.run(executable: URL(fileURLWithPath: "/x"), arguments: ["a","b"], log: nil)
        XCTAssertEqual(f.recorded.count, 1)
        XCTAssertEqual(f.recorded[0].1, ["a","b"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ProcessRunnerTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'FoundationProcessRunner'`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Abstraction over launching an external process. The real implementation
/// uses Foundation `Process`; tests inject a fake that records commands.
public protocol ProcessRunner {
    /// Run `executable` with `arguments`, forwarding merged stdout/stderr lines to
    /// `log`. Returns the process exit code. Throws if the process cannot launch.
    func run(executable: URL, arguments: [String], log: ((String) -> Void)?) throws -> Int32
}

public struct FoundationProcessRunner: ProcessRunner {
    public init() {}
    public func run(executable: URL, arguments: [String], log: ((String) -> Void)?) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        if let log {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty, let s = String(data: data, encoding: .utf8) {
                    s.split(separator: "\n").forEach { log(String($0)) }
                }
            }
        }
        try process.run()
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        return process.terminationStatus
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ProcessRunnerTests 2>&1 | tail -5`
Expected: PASS — 3 tests. (If `/usr/bin/false` differs on the runner, use `["-c","exit 1"]` via `/bin/sh`; but `/usr/bin/false` exists on macOS.)

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Processing/ProcessRunner.swift Tests/LiveAstroCoreTests/ProcessRunnerTests.swift
git commit -m "feat: ProcessRunner seam + FoundationProcessRunner"
```

---

### Task 3: `GraXpertProcessor` (via fake `ProcessRunner`)

**Files:**
- Create: `Sources/LiveAstroCore/Processing/GraXpertProcessor.swift`
- Test: `Tests/LiveAstroCoreTests/GraXpertProcessorTests.swift`

**Interfaces:**
- Consumes: `Processor`, `ProcessorError` (Task 1); `ProcessRunner` (Task 2).
- Produces: `public struct GraXpertProcessor: Processor { public init(executable: URL, runner: ProcessRunner = FoundationProcessRunner(), denoiseStrength: Double = 0.5, fileManager: FileManager = .default); public static func defaultExecutable(fileManager: FileManager = .default) -> URL? }`.

**Behavior:** `process` runs two `ProcessRunner` calls via a temp file:
1. `[-cli, -cmd, background-extraction, -gpu, false, -output, <bgTmp>, <master>]`
2. `[-cli, -cmd, denoising, -strength, "0.5", -gpu, false, -output, <outputURL>, <bgTmp>]`
Step 1 non-zero → throw `stepFailed`, step 2 skipped. After step 2, verify `outputURL` exists (else `noOutput`), then remove `bgTmp`. `isAvailable` = executable is an existing file. `outputURL` is written **exactly as passed** (the caller decides the name).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LiveAstroCore

final class GraXpertProcessorTests: XCTestCase {
    // Fake runner: records every call; optionally creates the -output file to
    // simulate GraXpert writing its result; returns a scripted exit code per call.
    final class FakeRunner: ProcessRunner {
        var calls: [[String]] = []
        var exitCodes: [Int32]
        var writeOutputOnCallIndex: Int?   // create the file named after this call's -output
        init(exitCodes: [Int32], writeOutputOnCallIndex: Int? = nil) {
            self.exitCodes = exitCodes; self.writeOutputOnCallIndex = writeOutputOnCallIndex
        }
        func run(executable: URL, arguments: [String], log: ((String)->Void)?) throws -> Int32 {
            let idx = calls.count
            calls.append(arguments)
            if writeOutputOnCallIndex == idx, let oi = arguments.firstIndex(of: "-output"), oi+1 < arguments.count {
                FileManager.default.createFile(atPath: arguments[oi+1], contents: Data("fake".utf8))
            }
            return idx < exitCodes.count ? exitCodes[idx] : 0
        }
    }
    private var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("master.fit").path, contents: Data("m".utf8))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testRunsBgThenDenoiseWithExpectedArgs() throws {
        let runner = FakeRunner(exitCodes: [0, 0], writeOutputOnCallIndex: 1)
        let exe = URL(fileURLWithPath: "/Applications/GraXpert.app/Contents/MacOS/GraXpert")
        let proc = GraXpertProcessor(executable: exe, runner: runner, denoiseStrength: 0.5)
        let master = tmp.appendingPathComponent("master.fit")
        let out = tmp.appendingPathComponent("master_processed.fit")
        try proc.process(masterURL: master, outputURL: out, log: nil)

        XCTAssertEqual(runner.calls.count, 2)
        // call 0 = background-extraction
        XCTAssertTrue(runner.calls[0].contains("background-extraction"))
        XCTAssertEqual(zip(runner.calls[0], runner.calls[0].dropFirst()).first { $0.0 == "-gpu" }?.1, "false")
        XCTAssertEqual(runner.calls[0].last, master.path)   // input is the master
        // call 1 = denoising with strength 0.5, input = the bg temp (call 0's -output)
        XCTAssertTrue(runner.calls[1].contains("denoising"))
        let sIdx = runner.calls[1].firstIndex(of: "-strength")!
        XCTAssertEqual(runner.calls[1][sIdx+1], "0.5")
        let bgOutIdx = runner.calls[0].firstIndex(of: "-output")!
        XCTAssertEqual(runner.calls[1].last, runner.calls[0][bgOutIdx+1])  // denoise input == bg output
        let dOutIdx = runner.calls[1].firstIndex(of: "-output")!
        XCTAssertEqual(runner.calls[1][dOutIdx+1], out.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
    }

    func testStep1FailureThrowsAndSkipsStep2() throws {
        let runner = FakeRunner(exitCodes: [3, 0])
        let proc = GraXpertProcessor(executable: URL(fileURLWithPath: "/x"), runner: runner)
        XCTAssertThrowsError(try proc.process(masterURL: tmp.appendingPathComponent("master.fit"),
                                              outputURL: tmp.appendingPathComponent("o.fit"), log: nil)) { err in
            XCTAssertEqual(err as? ProcessorError, .stepFailed(cmd: "background-extraction", code: 3))
        }
        XCTAssertEqual(runner.calls.count, 1)   // step 2 never ran
    }

    func testMissingOutputThrowsNoOutput() throws {
        // both steps exit 0 but nothing writes the output file
        let runner = FakeRunner(exitCodes: [0, 0], writeOutputOnCallIndex: nil)
        let proc = GraXpertProcessor(executable: URL(fileURLWithPath: "/x"), runner: runner)
        XCTAssertThrowsError(try proc.process(masterURL: tmp.appendingPathComponent("master.fit"),
                                              outputURL: tmp.appendingPathComponent("o.fit"), log: nil)) { err in
            XCTAssertEqual(err as? ProcessorError, .noOutput)
        }
    }

    func testIsAvailableReflectsExecutableExistence() {
        let present = GraXpertProcessor(executable: tmp.appendingPathComponent("master.fit")) // exists
        XCTAssertTrue(present.isAvailable)
        let absent = GraXpertProcessor(executable: tmp.appendingPathComponent("nope"))
        XCTAssertFalse(absent.isAvailable)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GraXpertProcessorTests 2>&1 | tail -6`
Expected: FAIL — `cannot find 'GraXpertProcessor'`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

public struct GraXpertProcessor: Processor {
    private let executable: URL
    private let runner: ProcessRunner
    private let denoiseStrength: Double
    private let fileManager: FileManager

    public init(executable: URL, runner: ProcessRunner = FoundationProcessRunner(),
                denoiseStrength: Double = 0.5, fileManager: FileManager = .default) {
        self.executable = executable; self.runner = runner
        self.denoiseStrength = denoiseStrength; self.fileManager = fileManager
    }

    public var name: String { "GraXpert" }
    public var isAvailable: Bool { fileManager.fileExists(atPath: executable.path) }

    public static func defaultExecutable(fileManager: FileManager = .default) -> URL? {
        let url = URL(fileURLWithPath: "/Applications/GraXpert.app/Contents/MacOS/GraXpert")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    public func process(masterURL: URL, outputURL: URL, log: ((String) -> Void)?) throws {
        guard isAvailable else { throw ProcessorError.notAvailable }
        let bgTmp = outputURL.deletingLastPathComponent()
            .appendingPathComponent("._graxpert_bg_\(UUID().uuidString).fits")
        defer { try? fileManager.removeItem(at: bgTmp) }

        let bgArgs = ["-cli", "-cmd", "background-extraction", "-gpu", "false",
                      "-output", bgTmp.path, masterURL.path]
        let c1 = try runner.run(executable: executable, arguments: bgArgs, log: log)
        guard c1 == 0 else { throw ProcessorError.stepFailed(cmd: "background-extraction", code: c1) }

        let strength = String(format: "%g", denoiseStrength)   // 0.5 -> "0.5"
        let dnArgs = ["-cli", "-cmd", "denoising", "-strength", strength, "-gpu", "false",
                      "-output", outputURL.path, bgTmp.path]
        let c2 = try runner.run(executable: executable, arguments: dnArgs, log: log)
        guard c2 == 0 else { throw ProcessorError.stepFailed(cmd: "denoising", code: c2) }

        guard fileManager.fileExists(atPath: outputURL.path) else { throw ProcessorError.noOutput }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GraXpertProcessorTests 2>&1 | tail -5`
Then full core: `swift test --filter LiveAstroCoreTests 2>&1 | tail -5`
Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Processing/GraXpertProcessor.swift Tests/LiveAstroCoreTests/GraXpertProcessorTests.swift
git commit -m "feat: GraXpertProcessor (bg-extraction → denoise) via ProcessRunner"
```

---

### Task 4: `SessionSettings.processorBackend` (backward-compatible)

**Files:**
- Modify: `Sources/LiveAstroCore/Settings/SessionSettings.swift`
- Test: `Tests/LiveAstroCoreTests/SessionSettingsTests.swift` (append)

**Interfaces:**
- Consumes: `ProcessorBackend` (Task 1).
- Produces: `SessionSettings.processorBackend: ProcessorBackend` (default `.none`), present in the memberwise init, `.defaults`, `CodingKeys`, and the custom `init(from:)` via `decodeIfPresent(...) ?? .none`.

**Context:** `SessionSettings` already has an explicit `CodingKeys` + custom `init(from:)` (added by the rejection + clean-export pillars) that uses `decodeIfPresent ?? default` for newer fields. Add `processorBackend` the SAME way, so an old settings blob without the key decodes to `.none` without wiping other fields.

- [ ] **Step 1: Write the failing test**

```swift
// append to SessionSettingsTests.swift
func testProcessorBackendDefaultAndRoundTrip() throws {
    XCTAssertEqual(SessionSettings.defaults.processorBackend, .none)
    var s = SessionSettings.defaults
    s.processorBackend = .graxpert
    let data = try JSONEncoder().encode(s)
    XCTAssertEqual(try JSONDecoder().decode(SessionSettings.self, from: data).processorBackend, .graxpert)
}

func testOldBlobWithoutProcessorBackendDecodesToNone() throws {
    // A prior-version blob: has the existing keys but NOT processor_backend.
    let json = """
    {"source_mode_raw":"nativeStack","file_prefix":"Light_","neutralize_background":true,
     "sub_exposure_seconds":30,"target_name":"M8","calibration":{},
     "rejection_enabled":true,"rejection_strength":"medium"}
    """.data(using: .utf8)!
    let s = try JSONDecoder().decode(SessionSettings.self, from: json)
    XCTAssertEqual(s.processorBackend, .none)     // missing key -> default
    XCTAssertEqual(s.targetName, "M8")            // existing fields intact
}
```

> Adjust the old-blob JSON keys to match the real `CodingKeys` snake-case in `SessionSettings.swift` (check the existing `testOldBlobWithoutRejectionKeysDecodesToDefaults` test and mirror its exact key names). The point: a blob lacking `processor_backend` decodes to `.none` while other fields survive.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionSettingsTests 2>&1 | tail -6`
Expected: FAIL — no `processorBackend` member.

- [ ] **Step 3: Write minimal implementation**

In `SessionSettings.swift`: add the stored property, a `CodingKeys` case, the memberwise-init parameter (defaulted), the `.defaults` value, and the `init(from:)` decode line — mirroring the existing `rejectionStrength` handling:

```swift
    public var processorBackend: ProcessorBackend
```
```swift
    // CodingKeys: add
    case processorBackend
```
```swift
    // memberwise init: add parameter (default .none) + assignment
    processorBackend: ProcessorBackend = .none,
    ...
    self.processorBackend = processorBackend
```
```swift
    // .defaults: add
    processorBackend: .none,
```
```swift
    // init(from:): add, alongside the rejection decodes
    processorBackend = try container.decodeIfPresent(ProcessorBackend.self, forKey: .processorBackend) ?? .none
```

> Match the file's real member order and the exact `CodingKeys` style already present. Do not change any existing field's decode.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SessionSettingsTests 2>&1 | tail -5`
Then full core: `swift test --filter LiveAstroCoreTests 2>&1 | tail -5`
Expected: both PASS (all existing SessionSettings tests still green).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Settings/SessionSettings.swift Tests/LiveAstroCoreTests/SessionSettingsTests.swift
git commit -m "feat: persist processorBackend in SessionSettings (backward-compatible)"
```

---

### Task 5: AppModel wiring — `processMaster` + `lastSessionDirectory` (manual-validation)

**Files:**
- Modify: `Sources/LiveAstroStudio/AppModel.swift`
- Verify: RELEASE build + manual checklist (no unit test — SwiftUI/app lifecycle)

**Interfaces:**
- Consumes: `GraXpertProcessor` / `GraXpertProcessor.defaultExecutable()` (Task 3), `ProcessorBackend` + `SessionSettings.processorBackend` (Tasks 1, 4).
- Produces: `@Published var isProcessing`, `private(set) var lastSessionDirectory: URL?`, `@Published var processorBackend: ProcessorBackend` (loaded/saved with settings), `func processMaster(sessionDirectory: URL)`.

**Read the real source first** (this task has "match the real API" points):
- `AppModel.swift` — `regenerateReplay(sessionDirectory:)` (~line 371) is your template for `processMaster`. The end/import completion sites where a session URL is produced: `startSession`'s end path (`let url = try p.end()`, ~446) and `importSubs` (`let url = try importPipeline.end()`, ~336) — set `lastSessionDirectory` from those (on the MainActor). Also find where `SessionSettings` is loaded (`loadSettings`) and where `currentSettings()` builds the blob — add `processorBackend` to both, mirroring `rejectionStrength`.

- [ ] **Step 1: Add state + settings load/save**

```swift
    @Published var isProcessing = false
    @Published var processorBackend: ProcessorBackend = .none
    private(set) var lastSessionDirectory: URL?
```
In `loadSettings()` add `processorBackend = settings.processorBackend`; in `currentSettings()` pass `processorBackend: processorBackend` into the `SessionSettings(...)` initializer (mirror how `rejectionStrength` is handled).

- [ ] **Step 2: Capture `lastSessionDirectory`**

At each end/import completion (the `let url = try ....end()` sites), on the MainActor set `self.lastSessionDirectory = url` (the returned URL is the session directory; if `end()` returns something else, resolve the session dir — confirm against the real return type of `SessionPipeline.end()`).

- [ ] **Step 3: Add `processMaster`, mirroring `regenerateReplay`**

```swift
    func processMaster(sessionDirectory: URL) {
        guard !isProcessing, !isImporting, !isRunning else { return }
        guard processorBackend == .graxpert, let exe = GraXpertProcessor.defaultExecutable() else {
            errorMessage = "GraXpert not found — install it from graxpert.com"; return
        }
        isProcessing = true
        log.append("Processing master with GraXpert…")
        Task.detached { [weak self] in
            do {
                let master = sessionDirectory.appendingPathComponent("master.fit")
                let out = sessionDirectory.appendingPathComponent("master_processed.fit")
                let proc = GraXpertProcessor(executable: exe)
                try proc.process(masterURL: master, outputURL: out) { m in
                    Task { @MainActor in self?.log.append(m) }
                }
                await MainActor.run {
                    self?.isProcessing = false
                    self?.log.append("Processed → \(out.lastPathComponent)")
                }
            } catch {
                await MainActor.run {
                    self?.isProcessing = false
                    self?.errorMessage = "Processing failed: \(error)"
                }
            }
        }
    }
```

- [ ] **Step 4: Build RELEASE + core tests**

Run: `swift build -c release --scratch-path /private/tmp/las-release-build 2>&1 | tail -5`
Then: `swift test --filter LiveAstroCoreTests 2>&1 | tail -5`
Expected: build succeeds; core tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroStudio/AppModel.swift
git commit -m "feat: AppModel processMaster + lastSessionDirectory + backend persistence"
```

**Manual-validation checklist (in the report):** with GraXpert installed and a finished session — selecting GraXpert then "Process master" produces `master_processed.fit` in the session dir (raw `master.fit` unchanged); with GraXpert absent, the action sets the "not found" error. **REAL-WORLD INTEGRATION RISK (verify here):** GraXpert's `-output` may append `.fits` (writing `master_processed.fits` rather than `master_processed.fit`). Run it once for real and confirm the produced filename; if GraXpert appends `.fits`, either pass `master_processed` (no extension) as the output stem or resolve/rename the actual produced file so the sibling is predictably named. Document what GraXpert actually does.

---

### Task 6: ControlView — Post-process picker + "Process master" button (manual-validation)

**Files:**
- Modify: `Sources/LiveAstroStudio/ControlView.swift`
- Verify: RELEASE build + manual checklist

**Interfaces:**
- Consumes: `AppModel.processorBackend`, `AppModel.isProcessing`, `AppModel.lastSessionDirectory`, `AppModel.processMaster(sessionDirectory:)` (Task 5); `GraXpertProcessor.defaultExecutable()` (Task 3); `ProcessorBackend` (Task 1).

**Read `ControlView.swift` first** and match its existing idioms (`@Bindable var model`, `Picker(...).pickerStyle(.segmented)`, `.disabled(model.isRunning || model.isImporting)`, `.help(...)` tooltips — as used by the rejection toggle/picker).

- [ ] **Step 1: Add the Post-process picker**

Near the other stacking options (by the rejection controls):

```swift
    Picker("Post-process", selection: $model.processorBackend) {
        Text("None").tag(ProcessorBackend.none)
        Text("GraXpert").tag(ProcessorBackend.graxpert)
    }
    .pickerStyle(.segmented)
    .disabled(model.isRunning || model.isImporting || model.isProcessing)
    .help("After stacking, optionally run GraXpert (background extraction + denoise) to write master_processed.fit next to the raw master. Requires GraXpert installed.")
```

- [ ] **Step 2: Add the "Process master" button**

Where session actions live (footer / session controls):

```swift
    if model.processorBackend == .graxpert, let dir = model.lastSessionDirectory {
        Button(model.isProcessing ? "Processing…" : "Process master") {
            model.processMaster(sessionDirectory: dir)
        }
        .disabled(model.isProcessing || GraXpertProcessor.defaultExecutable() == nil)
        .help(GraXpertProcessor.defaultExecutable() == nil
              ? "GraXpert not found — install from graxpert.com"
              : "Run GraXpert on the last stacked master → master_processed.fit")
    }
```

- [ ] **Step 3: Build RELEASE**

Run: `swift build -c release --scratch-path /private/tmp/las-release-build 2>&1 | tail -5`
Then: `swift test --filter LiveAstroCoreTests 2>&1 | tail -5`
Expected: build succeeds; core tests green.

- [ ] **Step 4: Commit**

```bash
git add Sources/LiveAstroStudio/ControlView.swift
git commit -m "feat: ControlView post-process picker + Process master button"
```

**Manual-validation checklist (in the report):** picker shows None/GraXpert; GraXpert path disables the button + shows the hint when GraXpert is absent; after a session, selecting GraXpert + clicking Process master runs (spinner label), then logs "Processed → master_processed.fit"; the button is hidden/disabled during a run/import/processing.

---

## Notes for the implementer

- **`FoundationProcessRunner` reads merged stdout/stderr** so GraXpert's progress lines flow to the log. GraXpert prints a lot; that's fine (it goes to the session log).
- **Order matters and is asserted:** background-extraction MUST precede denoising, and a non-zero exit on step 1 MUST prevent step 2 (Task 3 tests this).
- **The output-extension risk (Task 5) is the one real-world unknown** — everything else is deterministic and unit-tested. Verify GraXpert's actual `-output` filename behavior during Task 5 manual validation.
- **Don't bundle GraXpert.** `defaultExecutable()` points at the user's `/Applications` install; absence is handled gracefully everywhere.
