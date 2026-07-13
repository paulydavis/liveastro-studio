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
        public let metadata: SourceMetadata?
    }

    /// One worker's output: a warped frame (nil = rejected).
    private struct Work {
        let warped: (image: AstroImage, mask: [Float])?
        let frameWeight: Float
        let backgroundModel: BackgroundExtraction.BackgroundModel?
        let name: String
        let timestamp: Date
        let metadata: SourceMetadata?
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
                onCommitted(Committed(index: engine.acceptedCount, sourceName: frame.sourceName, timestamp: frame.timestamp, metadata: frame.metadata))
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
                    let frameMeta = frame.metadata
                    if let reg = engine.register(prepared, minRows: .max) {
                        let w = engine.warp(reg, minRows: .max)
                        return Work(warped: w, frameWeight: reg.weight, backgroundModel: reg.backgroundModel, name: frame.sourceName, timestamp: frame.timestamp, metadata: frameMeta)
                    }
                    return Work(warped: nil, frameWeight: 1.0, backgroundModel: nil, name: frame.sourceName, timestamp: frame.timestamp, metadata: frameMeta)
                }
                inFlight += 1
                return true
            }

            while inFlight < pool { if !(await addNext()) { break } }

            while inFlight > 0 {
                guard let work = await group.next() else { break }
                inFlight -= 1
                if let w = work.warped {
                    engine.commit(image: w.image, mask: w.mask, frameWeight: work.frameWeight, backgroundModel: work.backgroundModel, minRows: .max)
                    onCommitted(Committed(index: engine.acceptedCount, sourceName: work.name, timestamp: work.timestamp, metadata: work.metadata))
                } else {
                    engine.commitRejection()
                    onRejected(work.name)
                }
                _ = await addNext()
            }
        }
    }
}
