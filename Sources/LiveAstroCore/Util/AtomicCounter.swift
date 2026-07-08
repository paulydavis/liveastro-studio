import Foundation

/// Minimal thread-safe counter for callbacks that fire off the main actor.
///
/// NSLock-based rather than lock-free: callers increment at most a few times
/// per frame, so contention is negligible and simplicity wins.
public final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    public init() {}

    /// Atomically adds one to the counter.
    public func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    /// Current value; safe to read from any thread.
    public var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
