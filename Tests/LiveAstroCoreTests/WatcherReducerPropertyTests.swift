import XCTest
@testable import LiveAstroCore

final class WatcherReducerPropertyTests: XCTestCase {
    private static let seed: UInt64 = 0x5EED_C0DE_2026_0716
    private static let transitionCount = 1_000

    func testDerivedHighWaterIsMonotoneWithinGeneration() {
        let name = revisionName("00001")
        let initialIdentity = makeIdentity(1)
        let candidate = makeCandidate(
            name: name,
            identity: initialIdentity,
            digest: "one",
            revision: "00001")
        var reducer = makeReducer(files: [name: .ready(candidate)])
        var generator = SplitMix64(seed: Self.seed)
        var previousMark: UInt64 = 0

        for transition in 0..<Self.transitionCount {
            if transition == 0 {
                _ = reducer.reduce(.emissionFinished(EmissionResult(
                    intent: EmissionIntent(
                        generation: reducer.state.generation.id,
                        candidate: candidate),
                    outcome: .yielded)))
            } else {
                let identity = makeIdentity(Int64(2 + generator.next() % 10_000))
                let outcome: ObservationOutcome
                switch transition {
                case 1:
                    outcome = .unstable(identity: identity)
                case 2:
                    outcome = .digested(
                        identity: identity,
                        digest: "changed-\(generator.next())",
                        byteCount: identity.size)
                default:
                    outcome = generator.next().isMultiple(of: 2)
                        ? .absent
                        : .identityUnchanged(identity: initialIdentity)
                }
                _ = observe(
                    name: name,
                    revision: "00001",
                    outcome: outcome,
                    nowNanos: UInt64(transition),
                    reducer: &reducer)
            }

            let mark = reducer.derivedRevisionHighWater.flatMap(UInt64.init) ?? 0
            XCTAssertGreaterThanOrEqual(
                mark,
                previousMark,
                "seed=\(Self.seed) transition=\(transition)")
            previousMark = mark
        }
    }

    func testNoNumberedRevisionAtOrBelowMarkProducesEmissionIntent() {
        let markName = revisionName("50")
        var files: [String: FileState] = [
            markName: .settled(.emittedNow(identity: makeIdentity(50), digest: "mark")),
        ]
        var revisions: [(name: String, revision: String, identity: FileIdentity)] = []
        for transition in 0..<Self.transitionCount {
            let value = transition % 50
            let revision = String(repeating: "0", count: transition / 50) + String(value)
            let name = revisionName(revision)
            let identity = makeIdentity(Int64(1_000 + transition))
            let candidate = makeCandidate(
                name: name,
                identity: identity,
                digest: "late-\(transition)",
                revision: revision)
            files[name] = .ready(candidate)
            revisions.append((name, revision, identity))
        }
        var generator = SplitMix64(seed: Self.seed)
        for index in stride(from: revisions.count - 1, through: 1, by: -1) {
            revisions.swapAt(index, Int(generator.next() % UInt64(index + 1)))
        }
        var reducer = makeReducer(files: files)

        for (transition, item) in revisions.enumerated() {
            let effects = observe(
                name: item.name,
                revision: item.revision,
                outcome: .identityUnchanged(identity: item.identity),
                nowNanos: UInt64(transition),
                reducer: &reducer)

            XCTAssertFalse(
                effects.contains(where: { if case .emit = $0 { return true }; return false }),
                "seed=\(Self.seed) transition=\(transition) revision=\(item.revision)")
            XCTAssertEqual(reducer.derivedRevisionHighWater, "50",
                           "seed=\(Self.seed) transition=\(transition)")
        }
    }

    func testActiveBlockerExactlyMatchesHeadBlockerVictimPredicate() {
        var generator = SplitMix64(seed: Self.seed)

        for transition in 0..<Self.transitionCount {
            var files: [String: FileState] = [:]
            var digests: [String: String] = [:]
            var entries: [FileObservation] = []
            var presentNames: [String] = []

            for value in 1...5 {
                let revision = String(value)
                let name = revisionName(revision)
                let identity = makeIdentity(Int64(transition * 10 + value + 1))
                let role = generator.next() % 6
                let outcome: ObservationOutcome
                switch role {
                case 0:
                    outcome = .absent
                case 1:
                    outcome = .invalid(reason: "incomplete")
                    presentNames.append(name)
                case 2:
                    outcome = .unstable(identity: identity)
                    presentNames.append(name)
                case 3:
                    let candidate = makeCandidate(
                        name: name,
                        identity: identity,
                        digest: "ready-\(transition)-\(value)",
                        revision: revision)
                    files[name] = .ready(candidate)
                    outcome = .identityUnchanged(identity: identity)
                    presentNames.append(name)
                case 4:
                    files[name] = .settled(.duplicateOfLastEmission(
                        identity: identity,
                        digest: "terminal-\(transition)-\(value)"))
                    outcome = .identityUnchanged(identity: identity)
                    presentNames.append(name)
                default:
                    let digest = "duplicate-\(transition)-\(value)"
                    files[name] = .digestPending(PendingDigest(
                        digest: digest,
                        identity: identity,
                        firstObservedNanos: 0))
                    digests[name] = digest
                    outcome = .digested(
                        identity: identity,
                        digest: digest,
                        byteCount: identity.size)
                    presentNames.append(name)
                }
                entries.append(makeObservation(
                    name: name,
                    revision: revision,
                    outcome: outcome))
            }

            var reducer = makeReducer(files: files, digests: digests)
            _ = reduce(entries, nowNanos: 1, reducer: &reducer)
            let potential = presentNames.filter {
                !isTerminal(reducer.state.generation.files[$0])
            }
            let firstFailure = potential.firstIndex {
                guard case .ready = reducer.state.generation.files[$0] else { return true }
                return false
            }
            let expectedBlocker: String?
            let expectedVictims: Set<String>?
            if let firstFailure,
               potential.index(after: firstFailure) < potential.endIndex {
                expectedBlocker = potential[firstFailure]
                expectedVictims = Set(potential[potential.index(after: firstFailure)...])
            } else {
                expectedBlocker = nil
                expectedVictims = nil
            }

            XCTAssertEqual(
                reducer.state.generation.ordering.activeBlocker?.blocker,
                expectedBlocker,
                "seed=\(Self.seed) transition=\(transition) potential=\(potential)")
            XCTAssertEqual(
                reducer.state.generation.ordering.activeBlocker?.victims,
                expectedVictims,
                "seed=\(Self.seed) transition=\(transition) potential=\(potential)")
        }
    }

    func testOuterDigestHistoryCannotChangeBlockerAccountingOrDerivedMark() {
        var generator = SplitMix64(seed: Self.seed)
        let mark = revisionName("10")
        let blocker = revisionName("11")
        let victim = revisionName("12")
        let markIdentity = makeIdentity(10)
        let victimIdentity = makeIdentity(12)
        let files: [String: FileState] = [
            mark: .settled(.emittedNow(identity: markIdentity, digest: "mark")),
            victim: .digestPending(PendingDigest(
                digest: "current-victim",
                identity: victimIdentity,
                firstObservedNanos: 0)),
        ]
        let entries = [
            makeObservation(
                name: blocker,
                revision: "11",
                outcome: .invalid(reason: "incomplete")),
            makeObservation(
                name: victim,
                revision: "12",
                outcome: .digested(
                    identity: victimIdentity,
                    digest: "current-victim",
                    byteCount: victimIdentity.size)),
        ]

        for transition in 0..<Self.transitionCount {
            let emptyHistory: [String: String] = [:]
            var populatedHistory = [
                blocker: "nonmatching-blocker-\(generator.next())",
                victim: "nonmatching-victim-\(generator.next())",
            ]
            let extraKeyCount = Int(generator.next() % 5)
            for extra in 0..<extraKeyCount {
                populatedHistory[revisionName(String(20 + transition * 5 + extra))]
                    = "nonmatching-extra-\(generator.next())"
            }
            if transition.isMultiple(of: 2) {
                populatedHistory["classic-\(transition).fit"]
                    = "nonmatching-classic-\(generator.next())"
            }
            var reducerA = makeReducer(files: files, digests: emptyHistory)
            var reducerB = makeReducer(files: files, digests: populatedHistory)

            let effectsA = reduce(entries, nowNanos: UInt64(transition), reducer: &reducerA)
            let effectsB = reduce(entries, nowNanos: UInt64(transition), reducer: &reducerB)

            XCTAssertEqual(
                effectsA,
                effectsB,
                "seed=\(Self.seed) transition=\(transition)")
            XCTAssertEqual(
                reducerA.state.generation.files,
                reducerB.state.generation.files,
                "seed=\(Self.seed) transition=\(transition) duplicate classification diverged")
            XCTAssertEqual(
                reducerA.derivedRevisionHighWater,
                reducerB.derivedRevisionHighWater,
                "seed=\(Self.seed) transition=\(transition)")
            XCTAssertEqual(
                reducerA.state.generation.ordering.activeBlocker,
                reducerB.state.generation.ordering.activeBlocker,
                "seed=\(Self.seed) transition=\(transition)")
        }
    }

    func testRoleRoundTripsNeverInheritEpisodeClocks() {
        var generator = SplitMix64(seed: Self.seed)
        var transition = 0

        for cycle in 0..<334 {
            let base = Int(generator.next() % 100_000) * 10 + 10
            let lowerRevision = String(base)
            let returningRevision = String(base + 1)
            let victimRevision = String(base + 2)
            let returning = revisionName(returningRevision)
            var reducer = makeReducer()
            let firstTime = UInt64(cycle * 10_000) + generator.next() % 1_000
            let secondTime = firstTime + 1 + generator.next() % 1_000
            let thirdTime = secondTime + 1 + generator.next() % 1_000

            _ = reduce([
                invalidObservation(returningRevision),
                invalidObservation(victimRevision),
            ], nowNanos: firstTime, reducer: &reducer)
            transition += 1
            XCTAssertEqual(
                reducer.state.generation.ordering.activeBlocker?.startNanos,
                firstTime,
                "seed=\(Self.seed) transition=\(transition)")

            _ = reduce([
                invalidObservation(lowerRevision),
                invalidObservation(returningRevision),
                invalidObservation(victimRevision),
            ], nowNanos: secondTime, reducer: &reducer)
            transition += 1
            XCTAssertEqual(
                reducer.state.generation.ordering.activeBlocker?.blocker,
                revisionName(lowerRevision),
                "seed=\(Self.seed) transition=\(transition)")

            _ = reduce([
                makeObservation(
                    name: revisionName(lowerRevision),
                    revision: lowerRevision,
                    outcome: .absent),
                invalidObservation(returningRevision),
                invalidObservation(victimRevision),
            ], nowNanos: thirdTime, reducer: &reducer)
            transition += 1
            XCTAssertEqual(
                reducer.state.generation.ordering.activeBlocker?.blocker,
                returning,
                "seed=\(Self.seed) transition=\(transition)")
            XCTAssertEqual(
                reducer.state.generation.ordering.activeBlocker?.startNanos,
                thirdTime,
                "seed=\(Self.seed) transition=\(transition) inherited=\(firstTime)")
        }

        XCTAssertGreaterThanOrEqual(transition, Self.transitionCount)
    }

    func testAbsenceNeverChangesTerminalStateWithinGeneration() {
        var generator = SplitMix64(seed: Self.seed)
        var files: [String: FileState] = [:]
        var expected: [String: FileState] = [:]
        for transition in 0..<Self.transitionCount {
            let name = "terminal_\(transition).fit"
            let identity = makeIdentity(Int64(10_000 + transition))
            let state: FileState
            switch generator.next() % 4 {
            case 0:
                state = .settled(.emittedNow(
                    identity: identity,
                    digest: "emitted-\(transition)"))
            case 1:
                state = .settled(.duplicateOfLastEmission(
                    identity: identity,
                    digest: "duplicate-\(transition)"))
            case 2:
                state = .droppedOutOfOrder
            default:
                state = .writtenOff
            }
            files[name] = state
            expected[name] = state
        }
        var reducer = makeReducer(files: files)

        for transition in 0..<Self.transitionCount {
            let name = "terminal_\(transition).fit"
            _ = reducer.reduce(.observe(ObservationBatch(
                generation: reducer.state.generation.id,
                entries: [FileObservation(
                    name: name,
                    url: URL(fileURLWithPath: "/watch/\(name)"),
                    kind: .classicMutable,
                    outcome: .absent)],
                nowNanos: UInt64(transition))))

            XCTAssertEqual(
                reducer.state.generation.files[name],
                expected[name],
                "seed=\(Self.seed) transition=\(transition)")
        }
    }

    private func makeReducer(
        files: [String: FileState] = [:],
        digests: [String: String] = [:]
    ) -> WatcherReducer {
        WatcherReducer(
            state: WatcherState(
                generation: GenerationState(
                    id: FolderGeneration(rawValue: 1),
                    files: files,
                    ordering: RevisionOrderingState(activeBlocker: nil)),
                lastEmittedDigestByName: digests),
            configuration: WatcherReducerConfiguration(
                digestPolicy: .mutableStackerOutput,
                filePrefix: "live_stack",
                quietPeriodNanos: 100,
                pollIntervalNanos: 1_000))
    }

    private func observe(
        name: String,
        revision: String,
        outcome: ObservationOutcome,
        nowNanos: UInt64,
        reducer: inout WatcherReducer
    ) -> [WatcherEffect] {
        reduce([
            makeObservation(name: name, revision: revision, outcome: outcome),
        ], nowNanos: nowNanos, reducer: &reducer)
    }

    private func reduce(
        _ entries: [FileObservation],
        nowNanos: UInt64,
        reducer: inout WatcherReducer
    ) -> [WatcherEffect] {
        reducer.reduce(.observe(ObservationBatch(
            generation: reducer.state.generation.id,
            entries: entries,
            nowNanos: nowNanos)))
    }

    private func makeObservation(
        name: String,
        revision: String,
        outcome: ObservationOutcome
    ) -> FileObservation {
        FileObservation(
            name: name,
            url: URL(fileURLWithPath: "/watch/\(name)"),
            kind: .numbered(revision: revision),
            outcome: outcome)
    }

    private func invalidObservation(_ revision: String) -> FileObservation {
        makeObservation(
            name: revisionName(revision),
            revision: revision,
            outcome: .invalid(reason: "incomplete"))
    }

    private func isTerminal(_ state: FileState?) -> Bool {
        switch state {
        case .settled, .droppedOutOfOrder, .writtenOff:
            return true
        case .observing, .digestPending, .ready, nil:
            return false
        }
    }

    private func makeIdentity(_ value: Int64) -> FileIdentity {
        FileIdentity(
            dev: value,
            ino: UInt64(value),
            size: Int(value) * 10,
            mtimeSec: value,
            mtimeNsec: value)
    }

    private func makeCandidate(
        name: String,
        identity: FileIdentity,
        digest: String,
        revision: String
    ) -> EmissionCandidate {
        EmissionCandidate(
            name: name,
            url: URL(fileURLWithPath: "/watch/\(name)"),
            kind: .numbered(revision: revision),
            identity: identity,
            digest: digest,
            byteCount: identity.size)
    }

    private func revisionName(_ revision: String) -> String {
        "live_stack_\(revision).fit"
    }
}

private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
