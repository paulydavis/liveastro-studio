import Foundation

/// Semaphore-gated wedge for pipeline callbacks (`onUpdate`/rejection seams), generalizing the
/// drain-timeout test pattern. The test controls EXACTLY when the consumer wedges and when (if
/// ever) it releases — no sleeps, all coordination via semaphores.
///
/// Usage: inside the callback under test, call `wedge()`. That signals `entered` (so the test
/// knows the callback is now blocked at the seam) and then blocks until the test calls
/// `releaseNow()`. If the test never releases, the callback stays wedged — exercising the
/// drain-timeout / hung-consumer path deterministically.
final class SlowConsumer {
    let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    /// Call INSIDE the callback: announce entry, then block until released.
    func wedge() {
        entered.signal()
        release.wait()
    }

    /// Unblock a wedged callback. Safe to call even if no callback is currently wedged
    /// (the signal is remembered for the next `wedge`).
    func releaseNow() {
        release.signal()
    }
}
