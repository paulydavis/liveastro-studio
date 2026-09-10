import Foundation

/// One native-online DBE result. This stores pixels before neutralization/stretch, not a display
/// transform. Watcher and clean-master renders deliberately do not participate.
final class CommittedFlattenCache {
    struct Key: Equatable {
        let generation: Int
        let count: Int
        let width: Int
        let height: Int
        let channels: Int
        let scale: Double
        let smoothest: Double
    }

    struct Metrics {
        let hits: Int
        let misses: Int
        let retainedBytes: Int
    }

    private let lock = NSLock()
    private var entry: (key: Key, image: AstroImage)?
    private var epoch: UInt64 = 0
    private var retired = false
    private var minimumGeneration = Int.min
    private var hits = 0
    private var misses = 0

    var metrics: Metrics {
        lock.lock(); defer { lock.unlock() }
        return Metrics(hits: hits, misses: misses,
                       retainedBytes: (entry?.image.pixels.count ?? 0) * MemoryLayout<Float>.size)
    }

    /// A miss evicts the previous slot before allocating its replacement. Readers may still own
    /// the old Array, so one slot is a retention bound, not a bound on process peak memory.
    func image(for key: Key, compute: () -> AstroImage) -> AstroImage {
        lock.lock()
        if retired || key.generation < minimumGeneration {
            lock.unlock()
            return compute()
        }
        if let entry, entry.key == key {
            hits += 1
            lock.unlock()
            return entry.image
        }
        misses += 1
        epoch &+= 1
        let ticket = epoch
        entry = nil
        lock.unlock()

        let result = compute()
        lock.lock()
        // Invalidation, retirement, or a newer miss wins over this computation. The caller can
        // still use its result; it must not repopulate a cache whose source was invalidated.
        if !retired, epoch == ticket { entry = (key, result) }
        lock.unlock()
        return result
    }

    func invalidate(minimumGeneration: Int? = nil, retiring: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        epoch &+= 1
        entry = nil
        if let minimumGeneration {
            self.minimumGeneration = max(self.minimumGeneration, minimumGeneration)
        }
        retired = retired || retiring
    }
}
