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
    case emittedNow(identity: FileIdentity, digest: String)
    case duplicateOfLastEmission(identity: FileIdentity, digest: String)
}

struct BlockingEpisode: Equatable {
    let blocker: String
    let startNanos: UInt64
    var deadlineNanos: UInt64
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
}

enum ObservationOutcome: Equatable {
    case absent
    case invalid(reason: String)
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

    var emittedRevisionHighWater: String? {
        state.generation.files.reduce(nil as String?) { highWater, entry in
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
            guard result.outcome == .yielded,
                  result.intent.generation == state.generation.id,
                  state.generation.files[result.intent.candidate.name]
                    == .ready(result.intent.candidate) else { return [] }
            let candidate = result.intent.candidate
            state.generation.files[candidate.name] = .settled(.emittedNow(
                identity: candidate.identity,
                digest: candidate.digest))
            state.lastEmittedDigestByName[candidate.name] = candidate.digest
            return []
        }
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
            let isConverging = classify(observation, nowNanos: batch.nowNanos)
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
        guard revisionOrderingEnabled, let mark = emittedRevisionHighWater else { return [] }
        var effects: [WatcherEffect] = []
        for item in classified where item.isPresent {
            guard let revision = item.revision,
                  !isTerminal(state.generation.files[item.observation.name]),
                  revisionOrder.compare(revision, mark) != .orderedDescending
            else { continue }
            state.generation.files[item.observation.name] = .droppedOutOfOrder
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

        func appendIntent(
            named name: String,
            state: WatcherState,
            to effects: inout [WatcherEffect],
            intentNames: inout Set<String>
        ) {
            guard intentNames.insert(name).inserted,
                  case .ready(let candidate) = state.generation.files[name]
            else { return }
            effects.append(.emit(EmissionIntent(
                generation: state.generation.id,
                candidate: candidate)))
        }

        for item in classified
        where item.isPresent && item.revision == nil {
            appendIntent(
                named: item.observation.name,
                state: state,
                to: &effects,
                intentNames: &intentNames)
        }

        let numbered = classified.filter { item in
            item.isPresent && item.revision != nil
                && !isTerminal(state.generation.files[item.observation.name])
        }
        guard revisionOrderingEnabled else {
            state.generation.ordering.activeBlocker = nil
            for item in numbered {
                appendIntent(
                    named: item.observation.name,
                    state: state,
                    to: &effects,
                    intentNames: &intentNames)
            }
            return effects
        }

        while true {
            let potential = numbered.filter {
                !isTerminal(state.generation.files[$0.observation.name])
            }
            guard let blockerIndex = potential.firstIndex(where: {
                guard case .ready = state.generation.files[$0.observation.name] else {
                    return true
                }
                return false
            }) else {
                state.generation.ordering.activeBlocker = nil
                for item in potential {
                    appendIntent(
                        named: item.observation.name,
                        state: state,
                        to: &effects,
                        intentNames: &intentNames)
                }
                return effects
            }

            for item in potential[..<blockerIndex] {
                appendIntent(
                    named: item.observation.name,
                    state: state,
                    to: &effects,
                    intentNames: &intentNames)
            }

            let laterVictims = potential.index(after: blockerIndex) < potential.endIndex
            guard laterVictims else {
                state.generation.ordering.activeBlocker = nil
                return effects
            }

            let blocker = potential[blockerIndex]
            let blockerName = blocker.observation.name
            if state.generation.ordering.activeBlocker?.blocker != blockerName {
                state.generation.ordering.activeBlocker = BlockingEpisode(
                    blocker: blockerName,
                    startNanos: nowNanos,
                    deadlineNanos: nowNanos &+ blockingBudgetNanos)
                return effects
            }

            guard var episode = state.generation.ordering.activeBlocker else {
                return effects
            }
            let ceiling = episode.startNanos &+ blockingCeilingNanos
            if blocker.isConverging {
                let renewed = min(nowNanos &+ blockingGraceNanos, ceiling)
                if renewed > episode.deadlineNanos {
                    episode.deadlineNanos = renewed
                    state.generation.ordering.activeBlocker = episode
                }
            }
            guard nowNanos >= min(episode.deadlineNanos, ceiling) else { return effects }

            state.generation.files[blockerName] = .writtenOff
            state.generation.ordering.activeBlocker = nil
            let heldSeconds = Int(
                (Double(nowNanos &- episode.startNanos) / 1_000_000_000).rounded())
            effects.append(.log(
                "revision \(blocker.revision ?? "") blocked emissions for \(heldSeconds)s "
                + "without completing — abandoning it; later revisions proceed "
                + "(frame lost: \(blockerName))"))
        }
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
            case .settled, .droppedOutOfOrder, .writtenOff, nil:
                break
            }
            return false

        case .invalid:
            switch existing {
            case .observing, .digestPending, .ready:
                state.generation.files.removeValue(forKey: observation.name)
            case .settled, .droppedOutOfOrder, .writtenOff, nil:
                break
            }
            return false

        case .unstable(let identity):
            switch existing {
            case .droppedOutOfOrder, .writtenOff:
                break
            case .settled(.emittedNow) where revisionOrder.revision(in: observation.name) != nil:
                break
            default:
                state.generation.files[observation.name] = .observing(stat: identity)
            }
            return false

        case .identityUnchanged:
            return false

        case .digested(let identity, let digest, let byteCount):
            if case .settled(.emittedNow) = existing,
               revisionOrder.revision(in: observation.name) != nil {
                return false
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
               case .settled(let settlement) = state.generation.files[entry.name],
               settlement.identity == entry.identity {
                return .acceptIdentity(FileObservation(
                    name: entry.name,
                    url: entry.url,
                    kind: kind,
                    outcome: .identityUnchanged(identity: entry.identity)))
            }
            return .readContent(
                name: entry.name,
                url: entry.url,
                kind: kind,
                identity: entry.identity,
                isFITS: entry.isFITS)
        }
    }

    private func entryKind(for name: String) -> WatcherEntryKind {
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

private struct NumberedRevisionOrder {
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
        case .emittedNow(let identity, _), .duplicateOfLastEmission(let identity, _):
            return identity
        }
    }
}
