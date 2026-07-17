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
    private(set) var state: WatcherState
    let configuration: WatcherReducerConfiguration
    private let revisionRegex: NSRegularExpression?

    init(state: WatcherState, configuration: WatcherReducerConfiguration) {
        self.state = state
        self.configuration = configuration
        if let prefix = configuration.filePrefix, !prefix.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: prefix)
            revisionRegex = try? NSRegularExpression(
                pattern: "^\(escaped)_([0-9]+)\\.([^.]+)$",
                options: [.caseInsensitive])
        } else {
            revisionRegex = nil
        }
    }

    var emittedRevisionHighWater: String? {
        state.generation.files.reduce(nil as String?) { highWater, entry in
            guard case .settled(.emittedNow) = entry.value,
                  let revision = revisionSuffix(of: entry.key) else { return highWater }
            guard let highWater else { return revision }
            switch Self.numericCompare(revision, highWater) {
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
            var effects: [WatcherEffect] = []
            for observation in batch.entries {
                effects.append(contentsOf: reduce(observation, nowNanos: batch.nowNanos))
            }
            return effects
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

    private mutating func reduce(
        _ observation: FileObservation,
        nowNanos: UInt64
    ) -> [WatcherEffect] {
        let existing = state.generation.files[observation.name]
        switch observation.outcome {
        case .absent:
            switch existing {
            case .observing, .digestPending, .ready:
                state.generation.files.removeValue(forKey: observation.name)
            case .settled, .droppedOutOfOrder, .writtenOff, nil:
                break
            }
            return []

        case .invalid:
            switch existing {
            case .observing, .digestPending, .ready:
                state.generation.files.removeValue(forKey: observation.name)
            case .settled, .droppedOutOfOrder, .writtenOff, nil:
                break
            }
            return []

        case .unstable(let identity):
            switch existing {
            case .droppedOutOfOrder, .writtenOff:
                break
            default:
                state.generation.files[observation.name] = .observing(stat: identity)
            }
            return []

        case .identityUnchanged:
            return []

        case .digested(let identity, let digest, let byteCount):
            switch existing {
            case nil:
                state.generation.files[observation.name] = .observing(stat: identity)
                return []
            case .observing(let previousIdentity):
                guard previousIdentity == identity else {
                    state.generation.files[observation.name] = .observing(stat: identity)
                    return []
                }
            case .digestPending(let pending):
                guard pending.identity == identity else {
                    state.generation.files[observation.name] = .observing(stat: identity)
                    return []
                }
            case .settled(let settlement):
                guard settlement.identity == identity else {
                    state.generation.files[observation.name] = .observing(stat: identity)
                    return []
                }
            case .ready(let candidate):
                guard candidate.identity == identity else {
                    state.generation.files[observation.name] = .observing(stat: identity)
                    return []
                }
                if candidate.digest == digest { return [] }
            case .droppedOutOfOrder, .writtenOff:
                return []
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
    ) -> [WatcherEffect] {
        if state.lastEmittedDigestByName[observation.name] == digest {
            state.generation.files[observation.name] = .settled(
                .duplicateOfLastEmission(identity: identity, digest: digest))
            return []
        }

        switch configuration.digestPolicy {
        case .mutableStackerOutput:
            if case .digestPending(let pending) = state.generation.files[observation.name],
               pending.identity == identity,
               pending.digest == digest {
                guard nowNanos >= pending.firstObservedNanos,
                      nowNanos - pending.firstObservedNanos >= configuration.quietPeriodNanos
                else { return [] }
            } else {
                state.generation.files[observation.name] = .digestPending(PendingDigest(
                    digest: digest,
                    identity: identity,
                    firstObservedNanos: nowNanos))
                return []
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
        return [.emit(EmissionIntent(generation: state.generation.id, candidate: candidate))]
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
        if let revision = revisionSuffix(of: name) {
            return .numbered(revision: revision)
        }
        switch configuration.digestPolicy {
        case .mutableStackerOutput:
            return .classicMutable
        case .immutableAfterPublish:
            return .immutable
        }
    }

    private func revisionSuffix(of name: String) -> String? {
        guard let revisionRegex else { return nil }
        let range = NSRange(name.startIndex..., in: name)
        guard let match = revisionRegex.firstMatch(in: name, range: range),
              let digitsRange = Range(match.range(at: 1), in: name),
              let extensionRange = Range(match.range(at: 2), in: name) else { return nil }
        let fileExtension = name[extensionRange].lowercased()
        guard ImageLoader.fitsExtensions.contains(fileExtension)
                || ImageLoader.bitmapExtensions.contains(fileExtension) else { return nil }
        return String(name[digitsRange])
    }

    private static func numericCompare(_ lhs: String, _ rhs: String) -> ComparisonResult {
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
}

private extension Settlement {
    var identity: FileIdentity {
        switch self {
        case .emittedNow(let identity, _), .duplicateOfLastEmission(let identity, _):
            return identity
        }
    }
}
