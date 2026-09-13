import Foundation

/// What a live source did with everything the watcher handed it, counted AT THE SOURCE
/// BOUNDARY — at ADMISSION, before any later step can drop an update unrecorded.
///
/// A session used to end saying only how many subs it stacked. Updates the watcher had
/// already detected, but which were never handed to the stacker before shutdown, were
/// reported nowhere: neither stacked nor rejected, and unmentioned. This session did not
/// delete the original files; what was missing was any account of them.
public struct SourceIntake: Equatable, Sendable, Codable {
    /// Every update the source accepted from the watcher. The categories below partition it.
    public var admitted: Int
    /// Pre-existing subs the operator chose to skip ("New arrivals only"). Deliberate.
    public var excludedPreExisting: Int
    /// Handed to the stacker as a decoded frame — each became accepted or rejected.
    public var delivered: Int
    /// Pulled, but the file could not be read or decoded (identity mismatch, deletion,
    /// corruption). Counted separately: an attempted decode is NOT a processed frame, and
    /// these never appear in the accepted/rejected accounting.
    public var readFailures: Int
    /// Admitted but never pulled before the session ended. Derived, never stored separately,
    /// so the partition cannot drift.
    public var unprocessedAtShutdown: Int {
        max(admitted - excludedPreExisting - delivered - readFailures, 0)
    }
    /// False when the relay could not be brought to a stop within its budget, so later
    /// admissions may be missing from these tallies. A count that cannot be completed is
    /// said to be incomplete rather than quietly published as final.
    public var accountingComplete: Bool

    public init(admitted: Int = 0, excludedPreExisting: Int = 0, delivered: Int = 0,
                readFailures: Int = 0, accountingComplete: Bool = true) {
        self.admitted = admitted
        self.excludedPreExisting = excludedPreExisting
        self.delivered = delivered
        self.readFailures = readFailures
        self.accountingComplete = accountingComplete
    }

    /// Nothing beyond the ordinary accepted/rejected counts to tell the operator about.
    public var isUneventful: Bool {
        excludedPreExisting == 0 && unprocessedAtShutdown == 0 && readFailures == 0
            && accountingComplete
    }
}

/// A source that can account for what it admitted. Mirrors `FrameSourceActivityReporting`:
/// the pipeline asks through the protocol rather than knowing the concrete source type.
public protocol FrameSourceIntakeReporting: AnyObject {
    var intakeSnapshot: SourceIntake { get }
}

/// Lock-guarded tallies plus the accounting barrier.
///
/// ADMISSION IS COUNTED FIRST — before the exclusion decision and before the yield — so an
/// update cannot be dropped between being received and being counted. `awaitRelayCompletion`
/// is the barrier finalization waits on: without it, `stop()` could cancel the relay while
/// updates were still being admitted, and the persisted counts would describe a moment that
/// had already moved on.
final class IntakeCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var admitted = 0
    private var excluded = 0
    private var delivered = 0
    private var readFailures = 0
    private var relayDone = false
    private var relayAbandoned = false
    private let relayFinished = DispatchGroup()

    init() { relayFinished.enter() }

    func noteAdmitted() { lock.withLock { admitted += 1 } }
    func noteExcluded() { lock.withLock { excluded += 1 } }
    func noteDelivered() { lock.withLock { delivered += 1 } }
    func noteReadFailure() { lock.withLock { readFailures += 1 } }

    /// The relay loop ran to completion: every update the watcher produced has been admitted.
    func noteRelayFinished() {
        let firstTime: Bool = lock.withLock {
            guard !relayDone else { return false }
            relayDone = true
            return true
        }
        if firstTime { relayFinished.leave() }
    }

    /// Blocks until the relay finishes or the budget expires. Returns true when the tallies
    /// are complete. A false return is recorded, not ignored.
    @discardableResult
    func awaitRelayCompletion(timeout: DispatchTime) -> Bool {
        _ = relayFinished.wait(timeout: timeout)
        // Resolve completion versus timeout under the same lock used by the producer.
        // A late completion can never clear an earlier abandonment, including on retry.
        return lock.withLock {
            if !relayDone { relayAbandoned = true }
            return relayDone && !relayAbandoned
        }
    }

    var snapshot: SourceIntake {
        lock.withLock {
            SourceIntake(admitted: admitted, excludedPreExisting: excluded,
                         delivered: delivered, readFailures: readFailures,
                         accountingComplete: relayDone && !relayAbandoned)
        }
    }
}

extension DispatchTime {
    /// Saturating conversion: .never arrives as +infinity; invalid/negative budgets
    /// grant no time. Avoid floating-point-to-integer traps for enormous budgets.
    static func deadline(after seconds: TimeInterval) -> DispatchTime {
        let now = DispatchTime.now()
        guard !seconds.isNaN, seconds > 0 else { return now }
        guard let ns = UInt64(exactly: (seconds * 1_000_000_000).rounded(.down)) else {
            return .distantFuture
        }
        let end = now.uptimeNanoseconds.addingReportingOverflow(ns)
        return end.overflow ? .distantFuture : DispatchTime(uptimeNanoseconds: end.partialValue)
    }
    /// Seconds remaining from `other` to this deadline; negative when already past.
    /// Used so one shutdown deadline can be split across sequential steps.
    func distanceInSeconds(from other: DispatchTime) -> TimeInterval {
        if self == .distantFuture { return .infinity }
        if uptimeNanoseconds >= other.uptimeNanoseconds {
            return TimeInterval(uptimeNanoseconds - other.uptimeNanoseconds) / 1_000_000_000
        }
        return -TimeInterval(other.uptimeNanoseconds - uptimeNanoseconds) / 1_000_000_000
    }
}
