import XCTest
@testable import LiveAstroCore

/// A live (isFinite == false) source that yields a fixed sequence of RawFrames up front
/// (buffered), stays open like a real live source, and finishes its stream on stop().
/// Mirrors SessionPipelineShutdownTests.BacklogLiveSource.
final class StubLiveSource: FrameSource {
    let frames: AsyncStream<RawFrame>
    private let cont: AsyncStream<RawFrame>.Continuation
    var isFinite: Bool { false }
    var totalCount: Int? { nil }
    init(sequence: [RawFrame]) {
        var c: AsyncStream<RawFrame>.Continuation!
        frames = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        cont = c
        for f in sequence { cont.yield(f) }
        // Stream stays open (live source) until stop().
    }
    func start() throws {}
    func stop() { cont.finish() }
    /// Task 7: push an additional frame after construction (e.g. post-reseed), so a test can
    /// drive a NEW reference through the real handleNative path instead of poking pipeline
    /// state directly.
    func send(_ frame: RawFrame) { cont.yield(frame) }
}
