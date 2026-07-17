import XCTest
@testable import LiveAstroCore

final class SessionPipelineReseedContractTests: XCTestCase {
    private final class PausedFiniteSource: FrameSource {
        let frames: AsyncStream<RawFrame>
        private let continuation: AsyncStream<RawFrame>.Continuation
        var isFinite: Bool { true }
        var totalCount: Int? { nil }

        init() {
            var cont: AsyncStream<RawFrame>.Continuation!
            frames = AsyncStream { cont = $0 }
            continuation = cont
        }

        func start() throws {}
        func stop() { continuation.finish() }
    }

    private final class EmptyLiveSource: FrameSource {
        let frames: AsyncStream<RawFrame>
        private let continuation: AsyncStream<RawFrame>.Continuation
        var isFinite: Bool { false }
        var totalCount: Int? { nil }

        init() {
            var cont: AsyncStream<RawFrame>.Continuation!
            frames = AsyncStream { cont = $0 }
            continuation = cont
        }

        func start() throws {}
        func stop() { continuation.finish() }
    }

    private func profile(_ target: String = "Reseed Contract") -> SessionProfile {
        SessionProfile(targetName: target, telescope: "T", camera: "C", mount: "M",
                       filter: "F", locationLabel: "L", bortle: 5,
                       subExposureSeconds: 20, notes: "")
    }

    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func seededEngine() throws -> StackEngine {
        let engine = StackEngine()
        XCTAssertEqual(engine.process(FaultMatrixLifecycleTests.starField(name: "seed.fit", dx: 0, dy: 0)),
                       .becameReference)
        XCTAssertEqual(try engine.finalizationState().stackState, .active)
        return engine
    }

    func testFiniteImportReseedBeforeStartIsUnavailableAndDoesNotMutateEngine() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try seededEngine()
        let pipeline = SessionPipeline(nativeSource: PausedFiniteSource(), engine: engine,
                                       profile: profile(), rootDirectory: root)

        XCTAssertEqual(pipeline.reseed(), .unavailableDuringImport)
        let final = try engine.finalizationState()
        XCTAssertEqual(final.stackState, .active)
        XCTAssertEqual(final.frameCount, 1)
    }

    func testFiniteImportReseedWhileRunningIsUnavailableAndDoesNotMutateEngine() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = PausedFiniteSource()
        let engine = try seededEngine()
        let pipeline = SessionPipeline(nativeSource: source, engine: engine,
                                       profile: profile(), rootDirectory: root)
        pipeline.drainPrimaryTimeout = .milliseconds(100)
        pipeline.drainGraceTimeout = .milliseconds(100)

        try pipeline.start()
        XCTAssertEqual(pipeline.reseed(), .unavailableDuringImport)
        let final = try engine.finalizationState()
        XCTAssertEqual(final.stackState, .active)
        XCTAssertEqual(final.frameCount, 1)

        source.stop()
        _ = try? pipeline.end()
    }

    func testLiveNativeReseedReturnsReseeded() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = SessionPipeline(nativeSource: EmptyLiveSource(), engine: try seededEngine(),
                                       profile: profile(), rootDirectory: root)

        XCTAssertEqual(pipeline.reseed(), .reseeded)
    }

    func testWatcherModeReseedReturnsNotNative() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let watch = root.appendingPathComponent("watch")
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        let pipeline = SessionPipeline(watchFolder: watch, profile: profile(),
                                       rootDirectory: sessions)

        XCTAssertEqual(pipeline.reseed(), .notNative)
    }
}
