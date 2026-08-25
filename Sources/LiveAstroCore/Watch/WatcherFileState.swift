import Foundation

struct FolderGeneration: Equatable, Hashable, Sendable {
    let rawValue: UInt64
}

struct WatcherState {
    var generation: GenerationState
    var lastEmittedDigestByName: [String: String]
}

struct GenerationState {
    let id: FolderGeneration
    var files: [String: FileState]
    var ordering: RevisionOrderingState

    var emittedThisGeneration: Set<String> {
        Set(files.compactMap { name, fileState in
            guard case .settled(.emittedNow) = fileState else { return nil }
            return name
        })
    }
}

struct RevisionOrderingState {
    var activeBlocker: BlockingEpisode?
    var victimLedgers: [String: VictimWaitLedger] = [:]
    var pendingEmissionOwners: Set<RevisionKey> = []
    var ownerGraceUntil: [RevisionKey: UInt64] = [:]
}

struct RevisionKey: Hashable, Equatable {
    let normalizedDigits: String

    init(_ digits: String) {
        let stripped = digits.drop { $0 == "0" }
        normalizedDigits = stripped.isEmpty ? "0" : String(stripped)
    }
}

struct AccrualSegment: Equatable {
    let owner: RevisionKey
    var firstChargeNanos: UInt64
    var accruedNanos: UInt64
    var runningSinceNanos: UInt64?

    var isRunning: Bool {
        runningSinceNanos != nil
    }

    func totalNanos(at nowNanos: UInt64) -> UInt64 {
        guard let runningSinceNanos else { return accruedNanos }
        return accruedNanos &+ (nowNanos >= runningSinceNanos ? nowNanos - runningSinceNanos : 0)
    }
}

struct VictimWaitLedger: Equatable {
    var segments: [RevisionKey: AccrualSegment] = [:]
    var pausedAtNanos: UInt64?

    var isEmpty: Bool {
        segments.isEmpty
    }

    mutating func startOrContinue(owner: RevisionKey, at nowNanos: UInt64) {
        pauseRunning(at: nowNanos)
        pausedAtNanos = nil
        if var segment = segments[owner] {
            if segment.runningSinceNanos == nil {
                segment.runningSinceNanos = nowNanos
            }
            segments[owner] = segment
        } else {
            segments[owner] = AccrualSegment(
                owner: owner,
                firstChargeNanos: nowNanos,
                accruedNanos: 0,
                runningSinceNanos: nowNanos)
        }
    }

    mutating func pause(at nowNanos: UInt64) {
        pauseRunning(at: nowNanos)
        if pausedAtNanos == nil {
            pausedAtNanos = nowNanos
        }
    }

    mutating func pauseRunning(at nowNanos: UInt64) {
        for key in segments.keys {
            guard var segment = segments[key],
                  let runningSinceNanos = segment.runningSinceNanos else { continue }
            segment.accruedNanos = segment.accruedNanos &+ (nowNanos >= runningSinceNanos ? nowNanos - runningSinceNanos : 0)
            segment.runningSinceNanos = nil
            segments[key] = segment
        }
    }

    /// Barrier-scoped pause (§4 dependence, R9-F1): freezes only the given (pending)
    /// owners' running segments. Other owners' running segments keep accruing — the
    /// victim is present and still genuinely waiting on them. Never stamps
    /// `pausedAtNanos`: that marker means absence, and the victim is not absent.
    mutating func pauseSegments(ownedBy owners: Set<RevisionKey>, at nowNanos: UInt64) {
        for owner in owners {
            guard var segment = segments[owner],
                  let runningSinceNanos = segment.runningSinceNanos else { continue }
            segment.accruedNanos = segment.accruedNanos &+ (nowNanos >= runningSinceNanos ? nowNanos - runningSinceNanos : 0)
            segment.runningSinceNanos = nil
            segments[owner] = segment
        }
    }

    mutating func redeem(owner: RevisionKey) {
        segments.removeValue(forKey: owner)
        if segments.isEmpty {
            pausedAtNanos = nil
        }
    }

    /// Write-off consumption TRUNCATES (§5.6 rationale): a single write-off consumes
    /// exactly the debt that justified it; any remainder is still-unresolved wait and
    /// keeps counting toward the NEXT blocker's write-off progress, so escalation
    /// stays bounded over unredeemed wait (M1) instead of granting the next blocker
    /// a silently discounted budget. (The alternative — deleting whole segments on
    /// partial consumption — would erase owed wait the decision never claimed.)
    mutating func consume(_ consumed: [RevisionKey: UInt64], at nowNanos: UInt64) {
        pauseRunning(at: nowNanos)
        for (owner, amount) in consumed {
            guard var segment = segments[owner] else { continue }
            if segment.accruedNanos > amount {
                segment.accruedNanos -= amount
                segments[owner] = segment
            } else {
                segments.removeValue(forKey: owner)
            }
        }
        if segments.isEmpty {
            pausedAtNanos = nil
        }
    }

    func totalUnredeemedNanos(at nowNanos: UInt64) -> UInt64 {
        segments.values.reduce(0) { partial, segment in
            partial &+ segment.totalNanos(at: nowNanos)
        }
    }
}

/// `consumedSegments` holds PREDECESSOR debt only — the blocker's own key must never
/// appear in it (M9: own time and inherited debt are separate facts). Zero-amount
/// entries are excluded at construction (Task 7).
struct WriteOffDecision: Equatable {
    let blocker: RevisionKey
    let blockerNameForLog: String
    let attributedNanos: UInt64
    let consumedSegments: [RevisionKey: UInt64]
}

enum FileState: Equatable {
    case observing(stat: FileIdentity)
    case digestPending(PendingDigest)
    case ready(EmissionCandidate)
    case settled(Settlement)
    case droppedOutOfOrder
    case writtenOff
}

struct PendingDigest: Equatable {
    let digest: String
    let identity: FileIdentity
    let firstObservedNanos: UInt64
}

enum Settlement: Equatable {
    case emittedNow(
        identity: FileIdentity,
        digest: String,
        replacement: ReplacementProgress? = nil)
    case duplicateOfLastEmission(
        identity: FileIdentity,
        digest: String,
        replacement: ReplacementProgress? = nil)
}

enum ReplacementProgress: Equatable {
    case observing(stat: FileIdentity)
    case digestPending(PendingDigest)
    case ready(EmissionCandidate)
    case ignoredOutOfOrder(identity: FileIdentity)
}

struct BlockingEpisode: Equatable {
    let blocker: String
    let owner: RevisionKey
    private(set) var victims: Set<String>

    init?(blocker: String, owner: RevisionKey, victims: Set<String>) {
        guard !victims.isEmpty else { return nil }
        self.blocker = blocker
        self.owner = owner
        self.victims = victims
    }

    mutating func removeVictim(named name: String) -> Bool {
        victims.remove(name)
        return !victims.isEmpty
    }
}

struct WatcherReducerConfiguration {
    let digestPolicy: StackFileWatcher.DigestPolicy
    let filePrefix: String?
    let quietPeriodNanos: UInt64
    let pollIntervalNanos: UInt64
}

enum WatcherEntryKind: Equatable {
    case classicMutable
    case numbered(revision: String)
    case immutable
}

struct EnumeratedEntry: Equatable {
    let name: String
    let url: URL
    let identity: FileIdentity
    let isFITS: Bool
}

enum ReadRequest: Equatable {
    case acceptIdentity(FileObservation)
    case observeWithoutContent(FileObservation)
    case readContent(
        name: String,
        url: URL,
        kind: WatcherEntryKind,
        identity: FileIdentity,
        isFITS: Bool)
}

struct EmissionCandidate: Equatable {
    let name: String
    let url: URL
    let kind: WatcherEntryKind
    let identity: FileIdentity
    let digest: String
    let byteCount: Int
}

struct FileObservation: Equatable {
    let name: String
    let url: URL
    let kind: WatcherEntryKind
    let outcome: ObservationOutcome
    var observedAtNanos: UInt64? = nil
}

enum ObservationOutcome: Equatable {
    case absent
    case invalid
    case unstable(identity: FileIdentity)
    case identityUnchanged(identity: FileIdentity)
    /// The file exists and its identity is known, but its blocking content read has been
    /// dispatched to the reader queue and has not completed yet. Keeps the file present and
    /// not-ready (`.observing`) so it holds its place in numbered ordering as the blocker —
    /// a healthy slow read then completes in order (no lost frame), and a genuinely hung read
    /// is abandoned by the existing write-off budget instead of freezing detection.
    case pendingRead(identity: FileIdentity)
    case digested(identity: FileIdentity, digest: String, byteCount: Int)
}

struct ObservationBatch: Equatable {
    let generation: FolderGeneration
    let entries: [FileObservation]
    let nowNanos: UInt64
}

enum WatcherCommand {
    case replaceGeneration(FolderGeneration)
    case observe(ObservationBatch)
    case emissionFinished(EmissionResult)
}

struct EmissionIntent: Equatable {
    let generation: FolderGeneration
    let candidate: EmissionCandidate
}

struct EmissionResult: Equatable {
    enum Outcome: Equatable {
        case yielded
        case rejected
    }

    let intent: EmissionIntent
    let outcome: Outcome
}

enum WatcherEffect: Equatable {
    case log(String)
    case emit(EmissionIntent)
}

struct WatcherReducer {
    static let blockerBudgetFloorNanos: UInt64 = 30_000_000_000
    static let blockerBudgetQuietPeriods: UInt64 = 10
    static let blockerBudgetPollIntervals: UInt64 = 5
    static let maxBlockerGraceExtensions: UInt64 = 4

    private(set) var state: WatcherState
    let configuration: WatcherReducerConfiguration
    private let revisionOrder: NumberedRevisionOrder

    var blockingBudgetNanos: UInt64 {
        max(Self.blockerBudgetFloorNanos,
            Self.blockerBudgetQuietPeriods &* configuration.quietPeriodNanos,
            Self.blockerBudgetPollIntervals &* configuration.pollIntervalNanos)
    }

    var blockingGraceNanos: UInt64 { configuration.quietPeriodNanos }

    var blockingCeilingNanos: UInt64 {
        blockingBudgetNanos &+ Self.maxBlockerGraceExtensions &* blockingGraceNanos
    }

    private var revisionOrderingEnabled: Bool {
        configuration.digestPolicy == .mutableStackerOutput
    }

    init(state: WatcherState, configuration: WatcherReducerConfiguration) {
        self.state = state
        self.configuration = configuration
        revisionOrder = NumberedRevisionOrder(prefix: configuration.filePrefix)
    }

    var derivedRevisionHighWater: String? {
        guard revisionOrderingEnabled else { return nil }
        return state.generation.files.reduce(nil as String?) { highWater, entry in
            guard case .settled(.emittedNow) = entry.value,
                  let revision = revisionOrder.revision(in: entry.key) else { return highWater }
            guard let highWater else { return revision }
            switch revisionOrder.compare(revision, highWater) {
            case .orderedDescending:
                return revision
            case .orderedAscending:
                return highWater
            case .orderedSame:
                return min(revision, highWater)
            }
        }
    }

    mutating func reduce(_ command: WatcherCommand) -> [WatcherEffect] {
        switch command {
        case .replaceGeneration(let generation):
            guard generation.rawValue > state.generation.id.rawValue else { return [] }
            state.generation = GenerationState(
                id: generation,
                files: [:],
                ordering: RevisionOrderingState(activeBlocker: nil))
            return []
        case .observe(let batch):
            guard batch.generation == state.generation.id else { return [] }
            return reduce(batch)
        case .emissionFinished(let result):
            guard result.intent.generation == state.generation.id else { return [] }
            // The pending-emission barrier lifts on every terminal outcome
            // (yielded, rejected, or stale candidate state below) — a settled
            // intent must never keep deferring successor charging.
            if let owner = revisionOrder.revisionKey(in: result.intent.candidate.name) {
                state.generation.ordering.pendingEmissionOwners.remove(owner)
            }
            let candidate = result.intent.candidate
            if case .settled(let settlement) = state.generation.files[candidate.name],
               settlement.replacement == .ready(candidate) {
                if result.outcome == .rejected {
                    guard revisionOrderingEnabled,
                          case .numbered(let revision) = candidate.kind,
                          let mark = derivedRevisionHighWater,
                          !isEligibleAgainstDerivedHighWater(
                            candidate,
                            fileState: .settled(settlement),
                            mark: mark)
                    else { return [] }
                    state.generation.files[candidate.name] = .settled(
                        settlement.withReplacement(.ignoredOutOfOrder(
                            identity: candidate.identity)))
                    state.generation.ordering.victimLedgers[candidate.name] = nil  // aligned with applyMarkDrops
                    return [.log(
                        "revision \(revision) arrived out of order — skipped "
                            + "(high-water \(mark))")]
                }
                state.generation.files[candidate.name] = .settled(.emittedNow(
                    identity: candidate.identity,
                    digest: candidate.digest))
                state.lastEmittedDigestByName[candidate.name] = candidate.digest
                reconcileActiveBlocker(afterEmitting: candidate)
                return []
            }
            guard state.generation.files[candidate.name] == .ready(candidate) else { return [] }
            if result.outcome == .rejected {
                guard revisionOrderingEnabled,
                      case .numbered(let revision) = candidate.kind,
                      let mark = derivedRevisionHighWater,
                      !isEligibleAgainstDerivedHighWater(
                        candidate,
                        fileState: .ready(candidate),
                        mark: mark)
                else { return [] }
                state.generation.files[candidate.name] = .droppedOutOfOrder
                state.generation.ordering.victimLedgers[candidate.name] = nil  // aligned with applyMarkDrops
                return [.log(
                    "revision \(revision) arrived out of order — skipped (high-water \(mark))")]
            }
            state.generation.files[candidate.name] = .settled(.emittedNow(
                identity: candidate.identity,
                digest: candidate.digest))
            state.lastEmittedDigestByName[candidate.name] = candidate.digest
            reconcileActiveBlocker(afterEmitting: candidate)
            return []
        }
    }

    /// An intent may be invalidated by feedback from an earlier effect in the same batch.
    /// The driver asks immediately before performing the filesystem-facing yield.
    func shouldExecuteEmission(_ intent: EmissionIntent) -> Bool {
        guard intent.generation == state.generation.id else { return false }
        let fileState = state.generation.files[intent.candidate.name]
        guard readyCandidate(in: fileState) == intent.candidate else { return false }
        let mark = derivedRevisionHighWater
        return isEligibleAgainstDerivedHighWater(
            intent.candidate,
            fileState: fileState,
            mark: mark)
            && isEligibleAgainstActiveBlocker(intent.candidate)
    }

    private func readyCandidate(in fileState: FileState?) -> EmissionCandidate? {
        switch fileState {
        case .ready(let candidate):
            return candidate
        case .settled(let settlement):
            guard case .ready(let candidate) = settlement.replacement else { return nil }
            return candidate
        case .observing, .digestPending, .droppedOutOfOrder, .writtenOff, nil:
            return nil
        }
    }

    private func participatesInNumberedOrdering(_ fileState: FileState?) -> Bool {
        readyCandidate(in: fileState) != nil || !isTerminal(fileState)
    }

    /// Callers derive the mark once per decision scope; batch callers must not rescan per file.
    private func isEligibleAgainstDerivedHighWater(
        _ candidate: EmissionCandidate,
        fileState: FileState?,
        mark: String?
    ) -> Bool {
        guard revisionOrderingEnabled,
              case .numbered(let revision) = candidate.kind,
              let mark else { return true }
        switch revisionOrder.compare(revision, mark) {
        case .orderedDescending:
            return true
        case .orderedAscending:
            return false
        case .orderedSame:
            guard case .settled(let settlement) = fileState,
                  case .emittedNow = settlement,
                  settlement.replacement == .ready(candidate)
            else { return false }
            return true
        }
    }

    private func isEligibleAgainstActiveBlocker(_ candidate: EmissionCandidate) -> Bool {
        guard revisionOrderingEnabled,
              case .numbered(let revision) = candidate.kind,
              let episode = state.generation.ordering.activeBlocker,
              let blockerRevision = revisionOrder.revision(in: episode.blocker)
        else { return true }
        if candidate.name == episode.blocker { return true }
        return revisionOrder.orderedBefore(
            (name: candidate.name, revision: revision),
            (name: episode.blocker, revision: blockerRevision))
    }

    private mutating func reconcileActiveBlocker(afterEmitting candidate: EmissionCandidate) {
        // (b) The emitting victim's own ledger discharges (§5.2): its emission proves
        // no owed wait explains any future hold on it.
        state.generation.ordering.victimLedgers[candidate.name] = nil

        // (a) Owner-keyed redemption — uniform over running and paused segments (§5.1).
        // This replaces every scalar-era removeAll(): other owners' unredeemed segments
        // (vanished predecessors, still-live blockers) must survive this emission (d4, e1).
        if let owner = revisionOrder.revisionKey(in: candidate.name) {
            redeemSegments(for: owner)
        }

        guard var episode = state.generation.ordering.activeBlocker else { return }

        if candidate.name == episode.blocker {
            state.generation.ordering.activeBlocker = nil   // episode over; ledgers already settled above
            return
        }

        if episode.victims.contains(candidate.name) {
            state.generation.ordering.activeBlocker =
                episode.removeVictim(named: candidate.name) ? episode : nil
        }

        guard state.generation.ordering.activeBlocker != nil,
              revisionOrder.revision(in: candidate.name) != nil,
              let blockerRevision = revisionOrder.revision(in: episode.blocker),
              let mark = derivedRevisionHighWater,
              revisionOrder.compare(blockerRevision, mark) != .orderedDescending
        else { return }
        state.generation.ordering.activeBlocker = nil       // episode inconsistent with the derived mark
    }

    private mutating func redeemSegments(for owner: RevisionKey) {
        for victim in Array(state.generation.ordering.victimLedgers.keys) {
            state.generation.ordering.victimLedgers[victim]?.redeem(owner: owner)
            if state.generation.ordering.victimLedgers[victim]?.isEmpty == true {
                state.generation.ordering.victimLedgers[victim] = nil
            }
        }
        state.generation.ordering.ownerGraceUntil[owner] = nil   // M8 hygiene
    }

    private struct ClassifiedObservation {
        let observation: FileObservation
        let revision: String?
        let isPresent: Bool
        let isConverging: Bool
    }

    private mutating func reduce(_ batch: ObservationBatch) -> [WatcherEffect] {
        var classifiedByName: [String: ClassifiedObservation] = [:]
        for observation in batch.entries {
            // Finish classification (including duplicate settlement) for the complete batch
            // before either ordering evidence or victim roles are derived.
            let isConverging = classify(
                observation,
                nowNanos: observation.observedAtNanos ?? batch.nowNanos)
            classifiedByName[observation.name] = ClassifiedObservation(
                observation: observation,
                revision: revisionOrder.revision(in: observation.name),
                isPresent: observation.outcome.isPresent,
                isConverging: isConverging)
        }

        let classified = classifiedByName.values.sorted {
            revisionOrder.orderedBefore(
                (name: $0.observation.name, revision: $0.revision),
                (name: $1.observation.name, revision: $1.revision))
        }
        var effects = applyMarkDrops(in: classified)
        effects.append(contentsOf: orderedEffects(
            for: classified,
            nowNanos: batch.nowNanos))
        return effects
    }

    private mutating func applyMarkDrops(
        in classified: [ClassifiedObservation]
    ) -> [WatcherEffect] {
        guard revisionOrderingEnabled, let mark = derivedRevisionHighWater else { return [] }
        var effects: [WatcherEffect] = []
        for item in classified where item.isPresent {
            guard let revision = item.revision else { continue }
            let name = item.observation.name
            let fileState = state.generation.files[name]
            if let candidate = readyCandidate(in: fileState) {
                guard !isEligibleAgainstDerivedHighWater(
                    candidate,
                    fileState: fileState,
                    mark: mark)
                else { continue }
                if case .settled(let settlement) = fileState {
                    state.generation.files[name] = .settled(
                        settlement.withReplacement(.ignoredOutOfOrder(
                            identity: candidate.identity)))
                } else {
                    state.generation.files[name] = .droppedOutOfOrder
                }
            } else {
                guard !isTerminal(fileState),
                      revisionOrder.compare(revision, mark) != .orderedDescending
                else { continue }
                state.generation.files[name] = .droppedOutOfOrder
            }
            state.generation.ordering.victimLedgers[name] = nil
            effects.append(.log(
                "revision \(revision) arrived out of order — skipped (high-water \(mark))"))
        }
        return effects
    }

    private mutating func orderedEffects(
        for classified: [ClassifiedObservation],
        nowNanos: UInt64
    ) -> [WatcherEffect] {
        var effects: [WatcherEffect] = []
        var intentNames: Set<String> = []
        var pendingOwners = state.generation.ordering.pendingEmissionOwners

        func appendIntent(
            named name: String,
            state: WatcherState,
            to effects: inout [WatcherEffect],
            intentNames: inout Set<String>,
            pendingOwners: inout Set<RevisionKey>
        ) {
            guard intentNames.insert(name).inserted else { return }
            guard let candidate = readyCandidate(in: state.generation.files[name]) else { return }
            effects.append(.emit(EmissionIntent(
                generation: state.generation.id,
                candidate: candidate)))
            if let owner = revisionOrder.revisionKey(in: candidate.name) {
                pendingOwners.insert(owner)
            }
        }

        for item in classified where item.isPresent && item.revision == nil {
            appendIntent(
                named: item.observation.name,
                state: state,
                to: &effects,
                intentNames: &intentNames,
                pendingOwners: &pendingOwners)
        }

        let numbered = classified.filter { item in
            item.isPresent && item.revision != nil
                && participatesInNumberedOrdering(
                    state.generation.files[item.observation.name])
        }
        let classifiedByName = Dictionary(
            uniqueKeysWithValues: classified.map { ($0.observation.name, $0) })
        guard revisionOrderingEnabled else {
            state.generation.ordering.activeBlocker = nil
            state.generation.ordering.victimLedgers.removeAll()
            state.generation.ordering.pendingEmissionOwners.removeAll()
            for item in numbered {
                appendIntent(
                    named: item.observation.name,
                    state: state,
                    to: &effects,
                    intentNames: &intentNames,
                    pendingOwners: &pendingOwners)
            }
            return effects
        }

        blockerScan: while true {
            let potential = numbered.filter {
                participatesInNumberedOrdering(
                    state.generation.files[$0.observation.name])
            }
            guard let blockerIndex = potential.firstIndex(where: {
                readyCandidate(in: state.generation.files[$0.observation.name]) == nil
            }) else {
                state.generation.ordering.activeBlocker = nil
                for item in potential {
                    appendIntent(
                        named: item.observation.name,
                        state: state,
                        to: &effects,
                        intentNames: &intentNames,
                        pendingOwners: &pendingOwners)
                }
                state.generation.ordering.pendingEmissionOwners = pendingOwners
                break blockerScan
            }

            for item in potential[..<blockerIndex] {
                appendIntent(
                    named: item.observation.name,
                    state: state,
                    to: &effects,
                    intentNames: &intentNames,
                    pendingOwners: &pendingOwners)
            }
            // Written back before the barrier check so it sees both prior-pass
            // unsettled owners and this pass's intents.
            state.generation.ordering.pendingEmissionOwners = pendingOwners

            let victimStart = potential.index(after: blockerIndex)
            let blocker = potential[blockerIndex]
            let victimNames = Set(potential[victimStart...].map(\.observation.name))

            let blockerName = blocker.observation.name
            guard let blockerOwner = blocker.revision.map(RevisionKey.init) else {
                break blockerScan   // unreachable: `numbered` items always parse a revision
            }

            state.generation.ordering.activeBlocker = BlockingEpisode(
                blocker: blockerName,
                owner: blockerOwner,
                victims: victimNames)   // nil (episode-less) when victimNames is empty — lone blockers own nothing

            guard !victimNames.isEmpty else { break blockerScan }

            // Pending-emission barrier (§4, scoped by DEPENDENCE — R9-F1): while a lower
            // owner's intent is unsettled, defer only what depends on the PENDING owners:
            // opening/extending the current head's segment, consuming pending owners'
            // segments, and any write-off decision whose justifying ledger contains them.
            // Segments owned by non-pending owners keep running — the barrier is an
            // attribution-ordering rule, not a global pause (an in-place-rewriting settled
            // lower would otherwise freeze the stalled head's charge every emission cycle).
            let barrierDeferred = hasPendingLowerOwner(before: blockerOwner)
            if barrierDeferred {
                for victim in victimNames {
                    state.generation.ordering.victimLedgers[victim]?
                        .pauseSegments(ownedBy: pendingOwners, at: nowNanos)
                }
            } else {
                // Charge (§4 step 5): one running segment per victim, keyed by the current owner.
                for victim in victimNames {
                    state.generation.ordering.victimLedgers[victim, default: VictimWaitLedger()]
                        .startOrContinue(owner: blockerOwner, at: nowNanos)
                }

                // Convergence grace (§5.4): renew the CURRENT owner only.
                if blocker.isConverging {
                    noteConvergingOwner(blockerOwner, at: nowNanos)
                }
            }

            // Write-off (§§5.5-5.6): ONE blocked victim with a justified decision suffices.
            // Victims are scanned in numeric revision order (determinism only: with the
            // cross-ledger consumption below, the justifier choice no longer selects who
            // "loses" segments).
            var justified: (victim: String, decision: WriteOffDecision)?
            for victim in orderedVictimNames(victimNames) {
                guard let ledger = state.generation.ordering.victimLedgers[victim] else { continue }
                if barrierDeferred {
                    // §4 dependence: the decision may not rest on any pending owner.
                    guard !pendingOwners.contains(blockerOwner),
                          pendingOwners.isDisjoint(with: ledger.segments.keys)
                    else { continue }
                }
                guard let decision = writeOffDecision(
                    for: blockerOwner,
                    blockerName: blockerName,
                    victimLedger: ledger,
                    nowNanos: nowNanos)
                else { continue }
                justified = (victim, decision)
                break
            }
            guard let (justifyingVictim, decision) = justified else { break blockerScan }

            writeOffDecisionHookForTesting?(decision, justifyingVictim, nowNanos)
            state.generation.files[blockerName] = .writtenOff
            // Predecessor-debt consumption (truncating) applies to the justifying ledger:
            // exactly the debt the decision claimed (§5.5).
            state.generation.ordering.victimLedgers[justifyingVictim]?
                .consume(decision.consumedSegments, at: nowNanos)
            if state.generation.ordering.victimLedgers[justifyingVictim]?.isEmpty == true {
                state.generation.ordering.victimLedgers[justifyingVictim] = nil
            }
            // R9-F2 (§4 step 3, consume-across-all-ledgers): the write-off resolves the
            // abandoned owner's debt for EVERY victim, not only the justifier. A surviving
            // copy under another victim would hand a later same-RevisionKey blocker
            // (padding twin) the dead owner's firstChargeNanos — instant write-off, zero
            // own tenure, dishonest log (M2/M9). Other owners' segments in those ledgers
            // remain owed (§5.2); the next pass discharges them if the write-off left
            // their victims unblocked.
            consumeSegmentsEverywhere(ownedBy: decision.blocker)
            state.generation.ordering.activeBlocker = nil
            state.generation.ordering.ownerGraceUntil[decision.blocker] = nil

            let heldSeconds = Int((Double(decision.attributedNanos) / 1_000_000_000).rounded())
            var message = "revision \(blocker.revision ?? decision.blocker.normalizedDigits) "
                + "blocked emissions for \(heldSeconds)s without completing — abandoning it; "
                + "later revisions proceed (frame lost: \(decision.blockerNameForLog))"
            if !decision.consumedSegments.isEmpty {
                message += "; consumed predecessor debt: "
                    + formatConsumedSegments(decision.consumedSegments)
            }
            effects.append(.log(message))
            continue blockerScan   // re-derive the next blocker; newly unblocked ready files emit this pass
        }

        // End-of-pass ledger settlement (M3 tombstones + §5.2 discharge). Runs on every
        // exit from blockerScan — including barrier deferrals and write-off passes.
        let currentVictims = state.generation.ordering.activeBlocker?.victims ?? []
        for name in Array(state.generation.ordering.victimLedgers.keys) {
            if currentVictims.contains(name) { continue }          // charging this pass
            if isPresentAndUnblocked(name: name, classifiedByName: classifiedByName) {
                state.generation.ordering.victimLedgers[name] = nil // discharge (§5.2)
            } else {
                state.generation.ordering.victimLedgers[name]?.pause(at: nowNanos)  // tombstone / not charged
            }
        }

        // ownerGraceUntil holds entries only for owners that still matter: live segments
        // or the current head blocker. Everything else (vanished never-charged owners,
        // discharged debt) is pruned so the map is empty at quiescence (H2).
        let liveOwners = Set(state.generation.ordering.victimLedgers.values.flatMap { $0.segments.keys })
        let headOwner = state.generation.ordering.activeBlocker?.owner
        state.generation.ordering.ownerGraceUntil = state.generation.ordering.ownerGraceUntil
            .filter { liveOwners.contains($0.key) || $0.key == headOwner }
        return effects
    }

    private func hasPendingLowerOwner(before owner: RevisionKey) -> Bool {
        state.generation.ordering.pendingEmissionOwners.contains { pending in
            revisionOrder.orderedBefore(pending, owner)
        }
    }

    /// Deterministic victim scan order: numeric revision order via the shared comparator
    /// (never lexicographic — `"10" < "9"` is a correctness bug per §3.1).
    private func orderedVictimNames(_ names: Set<String>) -> [String] {
        names.sorted { lhs, rhs in
            revisionOrder.orderedBefore(
                (name: lhs, revision: revisionOrder.revision(in: lhs)),
                (name: rhs, revision: revisionOrder.revision(in: rhs)))
        }
    }

    /// R9-F2: a written-off owner's segments are consumed from every victim's ledger —
    /// the owner is abandoned and the write-off resolved its debt for all of them.
    private mutating func consumeSegmentsEverywhere(ownedBy owner: RevisionKey) {
        for victim in Array(state.generation.ordering.victimLedgers.keys) {
            guard var ledger = state.generation.ordering.victimLedgers[victim],
                  ledger.segments.removeValue(forKey: owner) != nil else { continue }
            state.generation.ordering.victimLedgers[victim] = ledger.isEmpty ? nil : ledger
        }
    }

    /// Test-only observation point for the N1/N2 sweeps (Task 8, round 9). Nil in
    /// production. Arguments: decision, justifying victim name, decision-time nanos.
    var writeOffDecisionHookForTesting: ((WriteOffDecision, String, UInt64) -> Void)?

    /// §§5.4-5.6. Nil when the ledger lacks budget-worth of unredeemed wait, or when
    /// the current owner is still inside its own convergence grace window.
    /// `consumedSegments` = predecessor debt only, oldest debt first (ascending
    /// `firstChargeNanos`, numeric owner order on ties), truncating,
    /// zero-amount entries excluded. Budget/grace/ceiling reuse the reducer properties.
    func writeOffDecision(
        for blocker: RevisionKey,
        blockerName: String,
        victimLedger: VictimWaitLedger,
        nowNanos: UInt64
    ) -> WriteOffDecision? {
        let budget = blockingBudgetNanos
        guard victimLedger.totalUnredeemedNanos(at: nowNanos) >= budget else { return nil }
        guard currentOwnerGraceExpired(owner: blocker, in: victimLedger, nowNanos: nowNanos)
        else { return nil }

        let attributedNanos = victimLedger.segments[blocker]?.totalNanos(at: nowNanos) ?? 0
        var remaining = budget > attributedNanos ? budget - attributedNanos : 0
        var consumed: [RevisionKey: UInt64] = [:]
        let predecessors = victimLedger.segments.values
            .filter { $0.owner != blocker }
            .sorted { lhs, rhs in
                lhs.firstChargeNanos != rhs.firstChargeNanos
                    ? lhs.firstChargeNanos < rhs.firstChargeNanos
                    : revisionOrder.orderedBefore(lhs.owner, rhs.owner)
            }
            .map(\.owner)
        for owner in predecessors {
            guard remaining > 0, let segment = victimLedger.segments[owner] else { continue }
            let amount = min(segment.totalNanos(at: nowNanos), remaining)
            guard amount > 0 else { continue }   // zero-amount entries pollute the decision map
            consumed[owner] = amount
            remaining -= amount
        }
        return WriteOffDecision(
            blocker: blocker,
            blockerNameForLog: blockerName,
            attributedNanos: attributedNanos,
            consumedSegments: consumed)
    }

    /// §5.4: base tenure is one grace period from the owner's own first charge;
    /// converging observations renew it (ownerGraceUntil); the hard cap is the
    /// owner-anchored ceiling. Predecessor debt never shortens a fresh owner's grace,
    /// and grace never rewrites predecessor segments.
    private func currentOwnerGraceExpired(
        owner: RevisionKey,
        in ledger: VictimWaitLedger,
        nowNanos: UInt64
    ) -> Bool {
        guard let segment = ledger.segments[owner] else { return false }
        let ceiling = segment.firstChargeNanos &+ blockingCeilingNanos
        if nowNanos >= ceiling { return true }
        if let renewedUntil = state.generation.ordering.ownerGraceUntil[owner],
           nowNanos < renewedUntil {
            return false
        }
        return nowNanos >= segment.firstChargeNanos &+ blockingGraceNanos
    }

    mutating func noteConvergingOwner(_ owner: RevisionKey, at nowNanos: UInt64) {
        state.generation.ordering.ownerGraceUntil[owner] = nowNanos &+ blockingGraceNanos
    }

    private func formatSeconds(_ nanos: UInt64) -> String {
        String(format: "%.1fs", Double(nanos) / 1_000_000_000)
    }

    private func formatConsumedSegments(_ segments: [RevisionKey: UInt64]) -> String {
        segments
            .sorted { revisionOrder.orderedBefore($0.key, $1.key) }
            .map { "\($0.key.normalizedDigits)=\(formatSeconds($0.value))" }
            .joined(separator: ", ")
    }

    /// Discharge predicate (§5.2). Present and unblocked is a batch/file-state/numeric-order
    /// fact: the victim appeared present in THIS batch and no batch-present lower revision
    /// is unready. Never derived from BlockingEpisode, charging, or pendingEmissionOwners.
    private func isPresentAndUnblocked(
        name: String,
        classifiedByName: [String: ClassifiedObservation]
    ) -> Bool {
        guard let victim = classifiedByName[name],
              victim.isPresent,
              let victimRevision = victim.revision
        else { return false }
        for item in classifiedByName.values {
            guard item.observation.name != name,
                  item.isPresent,
                  let revision = item.revision,
                  revisionOrder.orderedBefore(
                      (name: item.observation.name, revision: revision),
                      (name: name, revision: victimRevision)),
                  participatesInNumberedOrdering(state.generation.files[item.observation.name]),
                  readyCandidate(in: state.generation.files[item.observation.name]) == nil
            else { continue }
            return false
        }
        return true
    }

    private func isTerminal(_ fileState: FileState?) -> Bool {
        switch fileState {
        case .settled, .droppedOutOfOrder, .writtenOff:
            return true
        case .observing, .digestPending, .ready, nil:
            return false
        }
    }

    private mutating func classify(
        _ observation: FileObservation,
        nowNanos: UInt64
    ) -> Bool {
        let existing = state.generation.files[observation.name]
        switch observation.outcome {
        case .absent:
            switch existing {
            case .observing, .digestPending, .ready:
                state.generation.files.removeValue(forKey: observation.name)
            case .settled(let settlement):
                state.generation.files[observation.name] = .settled(
                    settlement.withReplacement(nil))
            case .droppedOutOfOrder, .writtenOff, nil:
                break
            }
            return false

        case .invalid:
            switch existing {
            case .observing, .digestPending, .ready:
                state.generation.files.removeValue(forKey: observation.name)
            case .settled(let settlement):
                state.generation.files[observation.name] = .settled(
                    settlement.withReplacement(nil))
            case .droppedOutOfOrder, .writtenOff, nil:
                break
            }
            return false

        case .unstable(let identity):
            switch existing {
            case .droppedOutOfOrder, .writtenOff:
                break
            case .settled(let settlement) where observation.kind != .classicMutable:
                state.generation.files[observation.name] = .settled(
                    settlement.withReplacement(.observing(stat: identity)))
            default:
                state.generation.files[observation.name] = .observing(stat: identity)
            }
            return false

        case .identityUnchanged(let identity):
            if case .settled(let settlement) = existing,
               settlement.identity == identity {
                state.generation.files[observation.name] = .settled(
                    settlement.withReplacement(nil))
            }
            return false

        case .pendingRead(let identity):
            // A content read is in flight. For a brand-new/observing file, hold it not-ready so it
            // keeps its ordering slot as the blocker. For a file that ALREADY has digest progress
            // (.digestPending / .ready) — a stability re-read in flight — PRESERVE that progress:
            // resetting it to .observing would wipe the stability gate and the file could never
            // emit. Terminal/settled states are likewise never disturbed.
            switch existing {
            case .observing, nil:
                state.generation.files[observation.name] = .observing(stat: identity)
            case .digestPending, .ready, .settled, .droppedOutOfOrder, .writtenOff:
                break
            }
            return false

        case .digested(let identity, let digest, let byteCount):
            if case .settled(let settlement) = existing,
               observation.kind != .classicMutable {
                return reduceSettledReplacementDigest(
                    observation,
                    settlement: settlement,
                    identity: identity,
                    digest: digest,
                    byteCount: byteCount,
                    nowNanos: nowNanos)
            }
            switch existing {
            case nil:
                state.generation.files[observation.name] = .observing(stat: identity)
                return false
            case .observing(let previousIdentity):
                guard previousIdentity == identity else {
                    state.generation.files[observation.name] = .observing(stat: identity)
                    return false
                }
            case .digestPending(let pending):
                guard pending.identity == identity else {
                    state.generation.files[observation.name] = .observing(stat: identity)
                    return false
                }
            case .settled(let settlement):
                guard settlement.identity == identity else {
                    state.generation.files[observation.name] = .observing(stat: identity)
                    return false
                }
            case .ready(let candidate):
                guard candidate.identity == identity else {
                    state.generation.files[observation.name] = .observing(stat: identity)
                    return false
                }
            case .droppedOutOfOrder, .writtenOff:
                return false
            }
            return reduceStableDigest(
                observation,
                identity: identity,
                digest: digest,
                byteCount: byteCount,
                nowNanos: nowNanos)
        }
    }

    private mutating func reduceSettledReplacementDigest(
        _ observation: FileObservation,
        settlement: Settlement,
        identity: FileIdentity,
        digest: String,
        byteCount: Int,
        nowNanos: UInt64
    ) -> Bool {
        guard settlement.replacement?.identity == identity else {
            state.generation.files[observation.name] = .settled(
                settlement.withReplacement(.observing(stat: identity)))
            return false
        }

        if settlement.digest == digest {
            state.generation.files[observation.name] = .settled(
                settlement.refreshingIdentity(identity))
            return false
        }

        if case .ready(let candidate) = settlement.replacement,
           candidate.identity == identity,
           candidate.digest == digest {
            return false
        }

        switch configuration.digestPolicy {
        case .mutableStackerOutput:
            if case .digestPending(let pending) = settlement.replacement,
               pending.identity == identity,
               pending.digest == digest {
                guard nowNanos >= pending.firstObservedNanos,
                      nowNanos - pending.firstObservedNanos >= configuration.quietPeriodNanos
                else { return true }
            } else {
                state.generation.files[observation.name] = .settled(
                    settlement.withReplacement(.digestPending(PendingDigest(
                        digest: digest,
                        identity: identity,
                        firstObservedNanos: nowNanos))))
                return false
            }
        case .immutableAfterPublish:
            break
        }

        let candidate = EmissionCandidate(
            name: observation.name,
            url: observation.url,
            kind: observation.kind,
            identity: identity,
            digest: digest,
            byteCount: byteCount)
        state.generation.files[observation.name] = .settled(
            settlement.withReplacement(.ready(candidate)))
        return false
    }

    private mutating func reduceStableDigest(
        _ observation: FileObservation,
        identity: FileIdentity,
        digest: String,
        byteCount: Int,
        nowNanos: UInt64
    ) -> Bool {
        if state.lastEmittedDigestByName[observation.name] == digest {
            state.generation.files[observation.name] = .settled(
                .duplicateOfLastEmission(identity: identity, digest: digest))
            return false
        }

        if case .ready(let candidate) = state.generation.files[observation.name],
           candidate.identity == identity,
           candidate.digest == digest {
            return false
        }

        switch configuration.digestPolicy {
        case .mutableStackerOutput:
            if case .digestPending(let pending) = state.generation.files[observation.name],
               pending.identity == identity,
               pending.digest == digest {
                guard nowNanos >= pending.firstObservedNanos,
                      nowNanos - pending.firstObservedNanos >= configuration.quietPeriodNanos
                else { return true }
            } else {
                state.generation.files[observation.name] = .digestPending(PendingDigest(
                    digest: digest,
                    identity: identity,
                    firstObservedNanos: nowNanos))
                return false
            }
        case .immutableAfterPublish:
            break
        }

        let candidate = EmissionCandidate(
            name: observation.name,
            url: observation.url,
            kind: observation.kind,
            identity: identity,
            digest: digest,
            byteCount: byteCount)
        state.generation.files[observation.name] = .ready(candidate)
        return false
    }

    func readPlan(for entries: [EnumeratedEntry]) -> [ReadRequest] {
        entries.map { entry in
            let kind = entryKind(for: entry.name)
            if kind != .classicMutable,
               case .settled(let settlement) = state.generation.files[entry.name] {
                let matchesIgnoredReplacement: Bool
                if case .ignoredOutOfOrder(let identity) = settlement.replacement {
                    matchesIgnoredReplacement = identity == entry.identity
                } else {
                    matchesIgnoredReplacement = false
                }
                if settlement.identity == entry.identity || matchesIgnoredReplacement {
                    return .acceptIdentity(FileObservation(
                        name: entry.name,
                        url: entry.url,
                        kind: kind,
                        outcome: .identityUnchanged(identity: entry.identity)))
                }
            }
            guard hasMatchingStatEvidence(
                state.generation.files[entry.name],
                identity: entry.identity) else {
                return .observeWithoutContent(FileObservation(
                    name: entry.name,
                    url: entry.url,
                    kind: kind,
                    outcome: .unstable(identity: entry.identity)))
            }
            return .readContent(
                name: entry.name,
                url: entry.url,
                kind: kind,
                identity: entry.identity,
                isFITS: entry.isFITS)
        }
    }

    private func hasMatchingStatEvidence(
        _ fileState: FileState?,
        identity: FileIdentity
    ) -> Bool {
        switch fileState {
        case .observing(let previousIdentity):
            return previousIdentity == identity
        case .digestPending(let pending):
            return pending.identity == identity
        case .ready(let candidate):
            return candidate.identity == identity
        case .settled(let settlement):
            return settlement.identity == identity
                || settlement.replacement?.identity == identity
        case .droppedOutOfOrder, .writtenOff, nil:
            return false
        }
    }

    /// Deterministic descriptor-work order for the effect driver, using the same anchored
    /// parser/comparator as classification, high-water derivation, and reducer effects.
    func orderedNamesForScan(_ names: [String]) -> [String] {
        names.map { (name: $0, revision: revisionOrder.revision(in: $0)) }
            .sorted(by: revisionOrder.orderedBefore)
            .map(\.name)
    }

    /// Pure classification shared with the driver for failures that occur before a read plan
    /// can be built (open/stat/type). The anchored parser remains reducer-owned.
    func entryKind(for name: String) -> WatcherEntryKind {
        if let revision = revisionOrder.revision(in: name) {
            return .numbered(revision: revision)
        }
        switch configuration.digestPolicy {
        case .mutableStackerOutput:
            return .classicMutable
        case .immutableAfterPublish:
            return .immutable
        }
    }

}

struct NumberedRevisionOrder {
    private let regex: NSRegularExpression?

    init(prefix: String?) {
        if let prefix, !prefix.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: prefix)
            regex = try? NSRegularExpression(
                pattern: "^\(escaped)_([0-9]+)\\.([^.]+)$",
                options: [.caseInsensitive])
        } else {
            regex = nil
        }
    }

    func revision(in name: String) -> String? {
        guard let regex else { return nil }
        let range = NSRange(name.startIndex..., in: name)
        guard let match = regex.firstMatch(in: name, range: range),
              let digitsRange = Range(match.range(at: 1), in: name),
              let extensionRange = Range(match.range(at: 2), in: name) else { return nil }
        let fileExtension = name[extensionRange].lowercased()
        guard ImageLoader.fitsExtensions.contains(fileExtension)
                || ImageLoader.bitmapExtensions.contains(fileExtension) else { return nil }
        return String(name[digitsRange])
    }

    func revisionKey(in name: String) -> RevisionKey? {
        revision(in: name).map(RevisionKey.init)
    }

    func orderedBefore(_ lhs: RevisionKey, _ rhs: RevisionKey) -> Bool {
        compare(lhs.normalizedDigits, rhs.normalizedDigits) == .orderedAscending
    }

    func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let normalizedLHS = lhs.drop { $0 == "0" }
        let normalizedRHS = rhs.drop { $0 == "0" }
        if normalizedLHS.count != normalizedRHS.count {
            return normalizedLHS.count < normalizedRHS.count
                ? .orderedAscending
                : .orderedDescending
        }
        if normalizedLHS == normalizedRHS { return .orderedSame }
        return normalizedLHS < normalizedRHS ? .orderedAscending : .orderedDescending
    }

    func orderedBefore(
        _ lhs: (name: String, revision: String?),
        _ rhs: (name: String, revision: String?)
    ) -> Bool {
        switch (lhs.revision, rhs.revision) {
        case let (lhsRevision?, rhsRevision?):
            switch compare(lhsRevision, rhsRevision) {
            case .orderedAscending:
                return true
            case .orderedDescending:
                return false
            case .orderedSame:
                if lhsRevision != rhsRevision {
                    return lhsRevision < rhsRevision
                }
                return lhs.name < rhs.name
            }
        case (nil, nil):
            return lhs.name < rhs.name
        case (nil, .some):
            return true
        case (.some, nil):
            return false
        }
    }
}

private extension ObservationOutcome {
    var isPresent: Bool {
        if case .absent = self { return false }
        return true
    }
}

private extension Settlement {
    var identity: FileIdentity {
        switch self {
        case .emittedNow(let identity, _, _),
             .duplicateOfLastEmission(let identity, _, _):
            return identity
        }
    }

    var replacement: ReplacementProgress? {
        switch self {
        case .emittedNow(_, _, let replacement),
             .duplicateOfLastEmission(_, _, let replacement):
            return replacement
        }
    }

    var digest: String {
        switch self {
        case .emittedNow(_, let digest, _),
             .duplicateOfLastEmission(_, let digest, _):
            return digest
        }
    }

    func refreshingIdentity(_ identity: FileIdentity) -> Settlement {
        switch self {
        case .emittedNow(_, let digest, _):
            return .emittedNow(identity: identity, digest: digest)
        case .duplicateOfLastEmission(_, let digest, _):
            return .duplicateOfLastEmission(identity: identity, digest: digest)
        }
    }

    func withReplacement(_ replacement: ReplacementProgress?) -> Settlement {
        switch self {
        case .emittedNow(let identity, let digest, _):
            return .emittedNow(
                identity: identity,
                digest: digest,
                replacement: replacement)
        case .duplicateOfLastEmission(let identity, let digest, _):
            return .duplicateOfLastEmission(
                identity: identity,
                digest: digest,
                replacement: replacement)
        }
    }
}

private extension ReplacementProgress {
    var identity: FileIdentity {
        switch self {
        case .observing(let identity):
            return identity
        case .digestPending(let pending):
            return pending.identity
        case .ready(let candidate):
            return candidate.identity
        case .ignoredOutOfOrder(let identity):
            return identity
        }
    }
}
