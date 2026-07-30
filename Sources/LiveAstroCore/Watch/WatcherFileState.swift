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

    mutating func refreshVictims(_ victims: Set<String>) -> Bool {
        guard !victims.isEmpty else { return false }
        self.victims = victims
        return true
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
        // Task 7 extends this function with ownerGraceUntil[owner] = nil (M8 hygiene).
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
            guard victimStart < potential.endIndex else {
                state.generation.ordering.activeBlocker = nil
                break blockerScan
            }
            let victimNames = Set(potential[victimStart...].map(\.observation.name))

            let blockerName = blocker.observation.name
            let blockerOwner = blocker.revision.map(RevisionKey.init)
            if let blockerOwner, hasPendingLowerOwner(before: blockerOwner) {
                // A lower revision's emission intent is still unsettled: defer this
                // successor owner's charging, consumption, and write-off until it
                // settles. Pausing matters — a segment left running through a barrier
                // pass would silently extend under the deferred owner, which is
                // exactly what the barrier forbids. The barrier defers ledger
                // operations only; file-state updates, intent recording, and mark
                // drops proceeded normally above.
                for victim in victimNames {
                    state.generation.ordering.victimLedgers[victim]?.pause(at: nowNanos)
                }
                break blockerScan
            }
            for victim in victimNames {
                guard let blockerOwner else { continue }
                state.generation.ordering.victimLedgers[victim, default: VictimWaitLedger()]
                    .startOrContinue(owner: blockerOwner, at: nowNanos)
            }

            state.generation.ordering.activeBlocker = blockerOwner.flatMap {
                BlockingEpisode(blocker: blockerName, owner: $0, victims: victimNames)
            }
            // Convergence grace returns in Task 7 (ownerGraceUntil)
            guard victimNames.contains(where: { victim in
                guard let ledger = state.generation.ordering.victimLedgers[victim] else { return false }
                return totalWaitWriteOffCandidate(victimLedger: ledger, nowNanos: nowNanos)
            }) else { break blockerScan }

            let heldNanos = victimNames
                .compactMap { state.generation.ordering.victimLedgers[$0]?.totalUnredeemedNanos(at: nowNanos) }
                .max() ?? 0
            state.generation.files[blockerName] = .writtenOff
            for victim in victimNames {
                state.generation.ordering.victimLedgers[victim] = nil   // TEMPORARY — Task 7 consumes per decision
            }
            state.generation.ordering.activeBlocker = nil
            let heldSeconds = Int((Double(heldNanos) / 1_000_000_000).rounded())
            effects.append(.log(
                "revision \(blocker.revision ?? "") blocked emissions for \(heldSeconds)s "
                + "without completing — abandoning it; later revisions proceed "
                + "(frame lost: \(blockerName))"))
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
        return effects
    }

    private func hasPendingLowerOwner(before owner: RevisionKey) -> Bool {
        state.generation.ordering.pendingEmissionOwners.contains { pending in
            revisionOrder.orderedBefore(pending, owner)
        }
    }

    // TEMPORARY Task-3 gate: total-wait only. Task 7 replaces this with
    // writeOffDecision(for:blockerName:victimLedger:nowNanos:).
    private func totalWaitWriteOffCandidate(
        victimLedger: VictimWaitLedger,
        nowNanos: UInt64
    ) -> Bool {
        victimLedger.totalUnredeemedNanos(at: nowNanos) >= blockingBudgetNanos
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
