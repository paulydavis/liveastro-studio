import XCTest
import Darwin
import CryptoKit
@testable import LiveAstroCore

/// Pipeline-level native memory comparison, not a whole-app/OBS ceiling measurement.
/// Preparation is a SEPARATE invocation. Measurement never constructs pixels or rewrites originals.
/// Run on/off in fresh processes against the same manifest:
/// LAS_PREPARE_NATIVE_CACHE_MEMORY=1 swift test -c release --filter NativeLiveCacheMemoryMeasurementTests.testPrepareFixtures
/// LAS_RUN_NATIVE_CACHE_MEMORY=1 LAS_CACHE_MODE=on|off swift test -c release --skip-build --filter NativeLiveCacheMemoryMeasurementTests.testMeasurement
final class NativeLiveCacheMemoryMeasurementTests: XCTestCase {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
    private struct Manifest: Codable {
        let width: Int
        let height: Int
        let hashes: [String]
    }
    private static let count = 6
    private var fixtureRoot: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["LAS_NATIVE_CACHE_FIXTURES"]
            ?? "/private/tmp/liveastro-native-cache-fixtures-v2")
    }
    private static func name(_ seed: Int) -> String { String(format: "Light_%04d.fit", seed) }
    private static func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Preparation refuses to overwrite a store. Measurements require a complete hashed manifest.
    private func prepare(at root: URL, width w: Int, height h: Int) throws {
        guard !FileManager.default.fileExists(atPath: root.path) else {
            throw Failure("fixture store already exists; use another LAS_NATIVE_CACHE_FIXTURES path")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let channels = 3
        for seed in 0..<Self.count {
        var px = [Float](repeating: 0, count: w * h * channels)
        var s = UInt64(0xFEED &+ UInt64(seed &* 7919))
        for c in 0..<channels {
            for i in 0..<(w * h) {
                s = s &* 6364136223846793005 &+ 1442695040888963407
                px[c * w * h + i] = 0.0104 + Float(c) * 0.0008
                    + (Float(s >> 40) / Float(1 << 24) - 0.5) * 0.006
            }
        }
        for (fx, fy, amp) in [(0.216, 0.239, Float(0.8)), (0.583, 0.611, 0.5),
                              (0.792, 0.333, 0.65), (0.292, 0.500, 0.6), (0.417, 0.167, 0.55),
                              (0.542, 0.833, 0.65), (0.667, 0.222, 0.5), (0.875, 0.556, 0.7),
                              (0.188, 0.722, 0.55), (0.479, 0.389, 0.6), (0.771, 0.722, 0.5),
                              (0.250, 0.889, 0.65), (0.833, 0.139, 0.55), (0.375, 0.611, 0.6),
                              (0.708, 0.500, 0.5), (0.917, 0.833, 0.6), (0.208, 0.389, 0.55),
                              (0.604, 0.917, 0.6)] {
            for c in 0..<channels {
                let sx = Int(fx * Double(w)), sy = Int(fy * Double(h))
                for dy in -10...10 { for dx in -10...10 {
                    let x = sx + dx, y = sy + dy
                    guard x >= 0, x < w, y >= 0, y < h else { continue }
                    px[c * w * h + y * w + x] += amp * exp(-Float(dx * dx + dy * dy) / 16.0)
                } }
            }
        }
            try FITSWriter.float32(width: w, height: h, channels: channels, pixels: px)
                .write(to: root.appendingPathComponent(Self.name(seed)), options: .atomic)
        }
        let hashes = try (0..<Self.count).map { try Self.hash(root.appendingPathComponent(Self.name($0))) }
        let manifest = Manifest(width: w, height: h, hashes: hashes)
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
    }
    private func verify(_ root: URL) throws -> Manifest {
        let manifest = try JSONDecoder().decode(Manifest.self,
            from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        guard manifest.hashes.count == Self.count else { throw Failure("incomplete fixture manifest") }
        for seed in 0..<Self.count {
            guard try Self.hash(root.appendingPathComponent(Self.name(seed))) == manifest.hashes[seed] else {
                throw Failure("fixture digest mismatch: \(Self.name(seed))")
            }
        }
        return manifest
    }

    func testPrepareFixtures() throws {
        guard ProcessInfo.processInfo.environment["LAS_PREPARE_NATIVE_CACHE_MEMORY"] == "1" else {
            throw XCTSkip("opt-in fixture preparation, not a measurement")
        }
        try prepare(at: fixtureRoot, width: 6236, height: 4159)
        _ = try verify(fixtureRoot)
        print("NATIVE-MEM prepared \(fixtureRoot.path)")
    }
    func testMeasurement() throws {
        guard ProcessInfo.processInfo.environment["LAS_RUN_NATIVE_CACHE_MEMORY"] == "1" else {
            throw XCTSkip("set LAS_RUN_NATIVE_CACHE_MEMORY=1 and LAS_CACHE_MODE=on|off; prepare fixtures first")
        }
        let mode = try XCTUnwrap(ProcessInfo.processInfo.environment["LAS_CACHE_MODE"])
        guard mode == "on" || mode == "off" else { throw Failure("LAS_CACHE_MODE must be on|off") }
        let manifest = try verify(fixtureRoot)
        guard manifest.width == 6236, manifest.height == 4159 else { throw Failure("not 26 MP fixtures") }
        try exercise(root: fixtureRoot, manifest: manifest, enabled: mode == "on", timeout: 600)
    }
    /// Small, real native pipelines check the harness itself. These are NOT RSS comparisons:
    /// preparation and both modes share this process. No full-size work in the routine suite.
    func testSmallHarnessOn() throws { try smoke(enabled: true) }
    func testSmallHarnessOff() throws { try smoke(enabled: false) }
    private func smoke(enabled: Bool) throws {
        let root = try temporaryDirectory().appendingPathComponent("fixtures")
        try prepare(at: root, width: 640, height: 480)
        try exercise(root: root, manifest: verify(root), enabled: enabled, timeout: 45)
    }

    private struct Event {
        let name: String
        let revision: UInt64
        let time: TimeInterval
    }
    private struct State {
        var events: [Event] = []
        var requested = Set<UInt64>()
        var terminal = Set<UInt64>()
        var activeWorkers = Set<UInt64>()
        var frameCount = 0
        var activeFrame = false
        var recorded = 0
        var cleanCount = 0
        var arm = false
        var targetFrame: UInt64?
        var apply: UInt64?
        var draftDone = false
        var failed = false
        var inputs: [SessionPipeline.RenderInputFacts] = []
        var editedRenders = Set<UInt64>()
        var editedDeliveries = Set<UInt64>()
        // Model-like ownership: keep the currently displayed images, including the draft.
        var preview: CGImage?
        var broadcast: CGImage?
        var draft: CGImage?
        var displaysIdle: Bool { activeWorkers.isEmpty && requested.isSubset(of: terminal) }
        mutating func mark(_ name: String, _ revision: UInt64 = 0) {
            events.append(Event(name: name, revision: revision, time: ProcessInfo.processInfo.systemUptime))
        }
    }
    private final class Locked<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        func update<R>(_ body: (inout T) -> R) -> R {
            lock.lock(); defer { lock.unlock() }; return body(&stored)
        }
        var value: T { update { $0 } }
    }
    private func awaitState(_ description: String, timeout: TimeInterval, _ ready: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !ready() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure("timeout: \(description)") }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func exercise(root: URL, manifest: Manifest, enabled: Bool, timeout: TimeInterval) throws {
        let sandbox = try temporaryDirectory()
        let watch = sandbox.appendingPathComponent("watch")
        let stage = sandbox.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        for seed in 0..<Self.count {
            let name = Self.name(seed)
            try FileManager.default.copyItem(at: root.appendingPathComponent(name), to: stage.appendingPathComponent(name))
            guard try Self.hash(stage.appendingPathComponent(name)) == manifest.hashes[seed] else {
                throw Failure("copied fixture differs")
            }
        }
        func release(_ seed: Int) throws {
            // Consume only this run's copy. The shared fixture store is never moved or rewritten.
            try FileManager.default.moveItem(at: stage.appendingPathComponent(Self.name(seed)),
                                             to: watch.appendingPathComponent(Self.name(seed)))
        }
        let source = FolderFrameSource(folder: watch, mode: .live, fileNamePrefix: "Light_")
        let pipeline = SessionPipeline(nativeSource: source, engine: StackEngine(),
            profile: SessionProfile(targetName: "NativeMem", subExposureSeconds: 20),
            rootDirectory: sandbox.appendingPathComponent("sessions"))
        pipeline.rendersReplay = false
        if !enabled {
            guard pipeline.disableCommittedFlattenCacheBeforeStartForTesting() else { throw Failure("cache disable refused") }
        }
        var live = DisplayAdjustments.neutral
        live.backgroundExtraction = true
        live.bgScale = 2.9611440772720226
        live.bgSmoothest = 0.5
        var changed = live
        changed.blackPoint = 0.25
        let edit = Locked(changed)
        let state = Locked(State())
        let applyMarker = "native-memory-apply-\(UUID().uuidString)"
        let drafts = DispatchGroup()

        pipeline.displayRenderPhaseProbeForTest = { revision, phase in
            state.update { s in
                switch phase {
                case .requested:
                    s.requested.insert(revision)
                    if Thread.current.threadDictionary[applyMarker] != nil {
                        s.apply = revision
                        s.mark("applyRequested", revision)
                    }
                case .workerStarted: s.activeWorkers.insert(revision)
                case .renderBegan: s.mark("refreshBegan", revision)
                case .renderFinished:
                    s.mark("refreshFinished", revision)
                    s.terminal.insert(revision)
                    s.activeWorkers.remove(revision)
                case .superseded:
                    s.mark("superseded", revision)
                    s.terminal.insert(revision)
                    s.activeWorkers.remove(revision)
                case .frameLockReleased:
                    s.activeFrame = false
                    if let target = s.targetFrame { s.mark("frameFinished", target) }
                default: break
                }
            }
        }
        pipeline.displayRenderInputProbeForTest = { facts in state.update { $0.inputs.append(facts) } }
        pipeline.displayRenderSettingsProbeForTest = { [weak pipeline] revision, adjustments, origin in
            let launch = state.update { s -> Bool in
                if origin == "refresh", adjustments.blackPoint == edit.value.blackPoint { s.editedRenders.insert(revision) }
                guard origin == "frame" else { return false }
                s.frameCount += 1
                s.activeFrame = true
                guard s.arm, s.frameCount == Self.count else { return false }
                s.arm = false
                s.targetFrame = revision
                s.mark("frameBegan", revision)
                return true
            }
            guard launch else { return }
            guard let pipeline else { state.update { $0.failed = true }; return }
            // Retain only for the finite draft task, not in the pipeline-owned probe.
            // Only renderPreview is invoked concurrently, as in the app's draft worker.
            let draftPipeline = Locked(pipeline)
            drafts.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                state.update { $0.mark("draftBegan") }
                let image = draftPipeline.value.renderPreview(source: .clean, adjustments: edit.value, quality: .draft)
                state.update {
                    $0.draft = image
                    $0.failed = $0.failed || image == nil
                    $0.draftDone = true
                    $0.mark("draftFinished")
                }
                drafts.leave()
            }
            // The synchronous .requested probe identifies this call, even if another thread
            // claims a display revision before applyCommittedAdjustments returns.
            Thread.current.threadDictionary[applyMarker] = true
            let accepted = pipeline.applyCommittedAdjustments(edit.value)
            Thread.current.threadDictionary.removeObject(forKey: applyMarker)
            if accepted == nil { state.update { $0.failed = true } }
        }
        pipeline.onUpdate = { _, record in state.update { $0.recorded = max($0.recorded, record.index) } }
        pipeline.onDisplayUpdate = { update in
            state.update { s in
                s.preview = update.previewImage
                s.broadcast = update.broadcastImage
                s.cleanCount = update.cleanMasterSubCount ?? 0
                if update.broadcastImage != nil, update.cleanMasterSubCount != nil,
                   s.editedRenders.contains(update.revision) {
                    s.editedDeliveries.insert(update.revision)
                    s.mark("editedCleanDelivered", update.revision)
                }
            }
        }
        pipeline.displayAdjustments = live
        pipeline.configureLiveRejection(enabled: true)
        let refiner = try XCTUnwrap(pipeline.refinerForTest())
        let baseline = try Self.residentBytes()
        let sampler = Sampler()
        sampler.start()
        defer { sampler.stop() }
        try pipeline.start()
        defer {
            // Test-owned draft work must unwind before its inputs/sandbox can be destroyed.
            if drafts.wait(timeout: .now() + timeout) != .success {
                XCTFail("timeout: draining draft worker during teardown")
            }
            _ = try? pipeline.end()
        }
        for seed in 0..<5 {
            try release(seed)
            try awaitState("recorded frame \(seed + 1)", timeout: timeout) { state.value.recorded == seed + 1 }
        }
        try awaitState("five-sub clean broadcast and idle workers", timeout: timeout) {
            guard refiner.isIdleForTesting else { return false }
            let s = state.value
            return s.cleanCount == 5 && !s.activeFrame && s.displaysIdle
        }
        let beforeOverlap = pipeline.committedFlattenMetrics
        state.update { $0.arm = true }
        try release(5)
        try awaitState("frame/draft/Apply/publication completion", timeout: timeout) {
            guard refiner.isIdleForTesting else { return false }
            let s = state.value
            guard let apply = s.apply else { return false }
            return s.recorded == Self.count && s.cleanCount == Self.count && s.draftDone
                && s.terminal.contains(apply) && !s.editedDeliveries.isEmpty
                && !s.activeFrame && s.displaysIdle
        }
        guard drafts.wait(timeout: .now() + timeout) == .success else {
            throw Failure("timeout: draining completed draft worker")
        }
        sampler.stop()
        let settled = try Self.residentBytes()
        let s = state.value
        let metrics = pipeline.committedFlattenMetrics
        guard !s.failed, s.frameCount == Self.count else { throw Failure("missing work or unexpected frame count") }
        func time(_ name: String) throws -> TimeInterval {
            guard let event = s.events.first(where: { $0.name == name }) else { throw Failure("missing \(name)") }
            return event.time
        }
        let frameStart = try time("frameBegan"), frameEnd = try time("frameFinished")
        let draftStart = try time("draftBegan"), draftEnd = try time("draftFinished")
        let request = try time("applyRequested")
        guard request >= frameStart, request <= frameEnd else { throw Failure("Apply request did not overlap frame") }
        guard draftStart < frameEnd, draftEnd > frameStart else { throw Failure("draft execution did not overlap frame") }
        guard let rendered = s.editedDeliveries.first(where: { s.terminal.contains($0) }),
              s.events.contains(where: { $0.name == "refreshBegan" && $0.revision == rendered }) else {
            throw Failure("no completed refresh delivered the edited clean image")
        }
        guard !s.inputs.isEmpty, s.inputs.allSatisfy({
            Double($0.width * $0.height) >= Double(manifest.width * manifest.height) * 0.98
                && $0.channels == 3 && $0.sourceIsLinear && $0.backgroundExtraction
                && $0.bgScale == live.bgScale && $0.bgSmoothest == live.bgSmoothest
        }) else { throw Failure("render inputs did not match fixture dimensions / RGB / DBE settings") }
        let sampled = sampler.result
        guard sampled.errors == 0, sampled.count > 0 else { throw Failure("RSS sampling failed") }
        if enabled {
            guard metrics.hits > beforeOverlap.hits, metrics.retainedBytes > 0 else { throw Failure("overlap phase did not use cache") }
        } else {
            guard metrics.hits == 0, metrics.misses == 0, metrics.retainedBytes == 0 else { throw Failure("cache-off retained/reused data") }
        }
        _ = try verify(root) // originals remain byte-identical; verification is OUTSIDE sampling.
        let digest = try Self.hash(root.appendingPathComponent("manifest.json"))
        print("NATIVE-MEM mode=\(enabled ? "on" : "off") manifest=\(digest) size=\(manifest.width)x\(manifest.height)x3")
        print("NATIVE-MEM bytes baseline=\(baseline) peakSampled=\(max(baseline, sampled.peak)) postWork=\(settled) retained=\(metrics.retainedBytes)")
        print("NATIVE-MEM frames=\(s.frameCount) cleanSubs=\(s.cleanCount) hits=\(metrics.hits) misses=\(metrics.misses) samples=\(sampled.count)")
        for event in s.events where event.time >= frameStart {
            print("NATIVE-MEM \(event.name) rev=\(event.revision) ms=\((event.time - frameStart) * 1000)")
        }
        // A superseded original Apply is explicitly visible in the trace. Completion is defined
        // by an observed, finished refresh delivering the edit, not a guessed revision or a hit.
    }

    private static func residentBytes() throws -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw Failure("task_info failed: \(result)") }
        return UInt64(info.resident_size)
    }
    private final class Sampler: @unchecked Sendable {
        private let queue = DispatchQueue(label: "native-memory-sampler")
        private lazy var timer = DispatchSource.makeTimerSource(queue: queue)
        private let values = Locked((peak: UInt64(0), count: 0, errors: 0))
        var result: (peak: UInt64, count: Int, errors: Int) { values.value }
        func start() {
            timer.schedule(deadline: .now(), repeating: .milliseconds(5))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                do {
                    let bytes = try NativeLiveCacheMemoryMeasurementTests.residentBytes()
                    self.values.update { $0.peak = max($0.peak, bytes); $0.count += 1 }
                } catch { self.values.update { $0.errors += 1 } }
            }
            timer.resume()
        }
        func stop() { timer.cancel(); queue.sync {} }
    }
}
