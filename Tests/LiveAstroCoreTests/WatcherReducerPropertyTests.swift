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

    func testNumberedCandidatesRespectMarkAndBlockerEligibility() {
        enum CandidateShape: String {
            case topLevel
            case emittedReplacement
            case duplicateReplacement
        }

        var generator = SplitMix64(seed: Self.seed)

        for transition in 0..<Self.transitionCount {
            let shape: CandidateShape
            switch transition % 3 {
            case 0:
                shape = .topLevel
            case 1:
                shape = .emittedReplacement
            default:
                shape = .duplicateReplacement
            }
            let markRevision = "00050"
            let markName = revisionName(markRevision)
            let generatedCandidateValue = Int(generator.next() % 50) + 1
            // Multiples of 25 rotate all three shapes through numeric equality.
            let candidateValue = transition.isMultiple(of: 25)
                ? 50
                : generatedCandidateValue
            let candidateRevision = String(
                repeating: "0",
                count: Int(generator.next() % 3)) + String(candidateValue)
            let candidateName = revisionName(candidateRevision)
            let candidateIdentity = makeIdentity(Int64(1_000 + transition))
            let candidate = makeCandidate(
                name: candidateName,
                identity: candidateIdentity,
                digest: "replacement-\(transition)",
                revision: candidateRevision)
            let candidateState: FileState
            switch shape {
            case .topLevel:
                candidateState = .ready(candidate)
            case .emittedReplacement:
                candidateState = .settled(.emittedNow(
                    identity: makeIdentity(Int64(10_000 + transition)),
                    digest: "outer-emitted-\(transition)",
                    replacement: .ready(candidate)))
            case .duplicateReplacement:
                candidateState = .settled(.duplicateOfLastEmission(
                    identity: makeIdentity(Int64(10_000 + transition)),
                    digest: "outer-duplicate-\(transition)",
                    replacement: .ready(candidate)))
            }
            var markReducer = makeReducer(files: [
                markName: .settled(.emittedNow(
                    identity: makeIdentity(50),
                    digest: "mark")),
                candidateName: candidateState,
            ])

            let markEffects = observe(
                name: candidateName,
                revision: candidateRevision,
                outcome: .identityUnchanged(identity: candidateIdentity),
                nowNanos: UInt64(transition),
                reducer: &markReducer)
            let markEmitted = markEffects.contains {
                if case .emit(let intent) = $0 { return intent.candidate == candidate }
                return false
            }
            let isSanctionedCurrentMarkReplacement =
                candidateValue == 50 && shape == .emittedReplacement
            XCTAssertEqual(
                markEmitted,
                isSanctionedCurrentMarkReplacement,
                "seed=\(Self.seed) transition=\(transition) mark candidate=\(candidateRevision) "
                    + "shape=\(shape.rawValue)")
            XCTAssertEqual(
                markReducer.shouldExecuteEmission(EmissionIntent(
                    generation: markReducer.state.generation.id,
                    candidate: candidate)),
                isSanctionedCurrentMarkReplacement,
                "seed=\(Self.seed) transition=\(transition) mark approval")

            let blockerRevision = "00025"
            let candidatePrecedesBlocker = (transition / 3).isMultiple(of: 2)
            let blockerCandidateValue = candidatePrecedesBlocker
                ? Int(generator.next() % 24) + 1
                : Int(generator.next() % 34) + 26
            let blockerCandidateRevision = String(
                repeating: "0",
                count: Int(generator.next() % 3)) + String(blockerCandidateValue)
            let blockerCandidateName = revisionName(blockerCandidateRevision)
            let blockerCandidateIdentity = makeIdentity(Int64(20_000 + transition))
            let blockerCandidate = makeCandidate(
                name: blockerCandidateName,
                identity: blockerCandidateIdentity,
                digest: "blocked-\(transition)",
                revision: blockerCandidateRevision)
            var blockerReducer = makeReducer(files: [
                blockerCandidateName: .settled(.duplicateOfLastEmission(
                    identity: makeIdentity(Int64(30_000 + transition)),
                    digest: "outer-\(transition)",
                    replacement: .ready(blockerCandidate))),
            ])
            let blockerEffects = reduce([
                invalidObservation(blockerRevision),
                makeObservation(
                    name: blockerCandidateName,
                    revision: blockerCandidateRevision,
                    outcome: .identityUnchanged(identity: blockerCandidateIdentity)),
                invalidObservation("00060"),
            ], nowNanos: UInt64(transition), reducer: &blockerReducer)
            let blockerEmitted = blockerEffects.contains {
                if case .emit(let intent) = $0 { return intent.candidate == blockerCandidate }
                return false
            }
            XCTAssertEqual(
                blockerEmitted,
                candidatePrecedesBlocker,
                "seed=\(Self.seed) transition=\(transition) blocker candidate="
                    + "\(blockerCandidateRevision)")
            XCTAssertEqual(
                blockerReducer.shouldExecuteEmission(EmissionIntent(
                    generation: blockerReducer.state.generation.id,
                    candidate: blockerCandidate)),
                candidatePrecedesBlocker,
                "seed=\(Self.seed) transition=\(transition) blocker approval")
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
                    outcome = .invalid
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
                outcome: .invalid),
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

    func testRoleRoundTripsPreserveOnlyContinuousVictimClocks() {
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
                reducer.state.generation.ordering.victimLedgers[revisionName(victimRevision)]?
                    .segments[RevisionKey(returningRevision)]?.firstChargeNanos,
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
                reducer.state.generation.ordering.victimLedgers[revisionName(victimRevision)]?
                    .segments[RevisionKey(returningRevision)]?.firstChargeNanos,
                firstTime,
                "seed=\(Self.seed) transition=\(transition) victim clock reset unexpectedly")
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

    func testDriverFaithfulSweepHoldsTimingBoundInvariantsN1AndN2() {
        // ≥3000 runs across both digest policies (1500 × 2). Commands only; the hook
        // observes decisions; per-pass snapshots supply exact anchors for N1. N2
        // (round 9) additionally bounds the JUSTIFIER's cumulative present-and-blocked
        // wall time — accumulated by the harness from the batches it constructs, and
        // re-anchored only when the victim's unredeemed ledger empties or observed
        // stream progress redeems a segment it held. Owner-attributed time freezes
        // during barrier pauses; wall time does not, so N2 catches an over-broad
        // barrier (R9-F1) that N1 cannot see.
        let runsPerPolicy = 1_500
        let pollTick: UInt64 = 1_000_000_000
        let order = NumberedRevisionOrder(prefix: "live_stack")
        for policy in [StackFileWatcher.DigestPolicy.mutableStackerOutput, .immutableAfterPublish] {
            var immutableDecisions = 0
            for run in 0..<runsPerPolicy {
                var generator = SplitMix64(seed: Self.seed ^ UInt64(run) &* 0x9E37)
                var reducer = WatcherReducer(
                    state: WatcherState(
                        generation: GenerationState(
                            id: FolderGeneration(rawValue: 1),
                            files: [:],
                            ordering: RevisionOrderingState(activeBlocker: nil)),
                        lastEmittedDigestByName: [:]),
                    configuration: WatcherReducerConfiguration(
                        digestPolicy: policy,
                        filePrefix: "live_stack",
                        quietPeriodNanos: 100_000_000,
                        pollIntervalNanos: 1_000_000_000))

                // Per-pass snapshots taken BEFORE each observe: exact N1 anchors.
                var snapshotLedgers: [String: VictimWaitLedger] = [:]
                var snapshotGrace: [RevisionKey: UInt64] = [:]
                var wallBlockedNanos: [String: UInt64] = [:]
                var pendingNow: UInt64 = 0
                var violations: [String] = []
                reducer.writeOffDecisionHookForTesting = { decision, justifyingVictim, now in
                    let budget: UInt64 = 30_000_000_000     // budget at this config; cross-checked below
                    let grace: UInt64 = 100_000_000
                    let ceiling: UInt64 = 30_400_000_000
                    let firstCharge = snapshotLedgers.values
                        .compactMap { $0.segments[decision.blocker]?.firstChargeNanos }
                        .min() ?? pendingNow                 // segment opened this pass
                    if now < firstCharge &+ budget {
                        if decision.consumedSegments.isEmpty {
                            violations.append("early write-off without explicit predecessor debt at \(now)")
                        }
                        let renewal = snapshotGrace[decision.blocker] ?? 0
                        let graceEdge = min(firstCharge &+ ceiling,
                                            max(firstCharge &+ grace, renewal))
                        if now < graceEdge {
                            violations.append("write-off inside the owner's own grace at \(now)")
                        }
                    }
                    // N2: the justifying victim's cumulative present-and-blocked wall
                    // time (harness-accumulated) must be within ceiling + one poll tick.
                    let wall = wallBlockedNanos[justifyingVictim] ?? 0
                    if wall > ceiling &+ pollTick {
                        violations.append("N2: justifier \(justifyingVictim) waited "
                            + "\(Double(wall) / 1e9)s present-and-blocked > ceiling+tick at \(now)")
                    }
                    // A write-off is adjudicated progress for every victim it consumed
                    // wait from (the abandoned owner's segments die in ALL ledgers,
                    // R9-F2): re-anchor them — AFTER the check above, so the decision
                    // itself is still judged against the pre-write-off wall time.
                    for (victim, ledger) in snapshotLedgers
                    where ledger.segments[decision.blocker] != nil {
                        wallBlockedNanos[victim] = 0
                    }
                    wallBlockedNanos[justifyingVictim] = 0
                }
                XCTAssertEqual(reducer.blockingBudgetNanos, 30_000_000_000)
                XCTAssertEqual(reducer.blockingGraceNanos, 100_000_000)
                XCTAssertEqual(reducer.blockingCeilingNanos, 30_400_000_000)

                var digestsByName: [String: String] = [:]
                var now: UInt64 = 0
                var unsettled: [EmissionIntent] = []
                for _ in 0..<120 {
                    now &+= pollTick
                    pendingNow = now
                    snapshotLedgers = reducer.state.generation.ordering.victimLedgers
                    snapshotGrace = reducer.state.generation.ordering.ownerGraceUntil

                    var entries: [FileObservation] = []
                    var present = [Bool](repeating: false, count: 7)
                    for value in 1...6 {
                        let revision = String(value)
                        let name = revisionName(revision)
                        let identity = makeIdentity(Int64(value))
                        let roll = generator.next() % 100
                        let outcome: ObservationOutcome
                        switch roll {
                        case ..<15: outcome = .absent
                        case ..<40: outcome = .invalid
                        case ..<50: outcome = .unstable(identity: identity)
                        case ..<60:
                            digestsByName[name] = "churn-\(generator.next() % 1_000)"
                            outcome = .digested(
                                identity: identity,
                                digest: digestsByName[name]!,
                                byteCount: identity.size)
                        default:
                            let digest = digestsByName[name] ?? "stable-\(value)"
                            digestsByName[name] = digest
                            outcome = .digested(
                                identity: identity, digest: digest, byteCount: identity.size)
                        }
                        present[value] = outcome != .absent
                        entries.append(makeObservation(name: name, revision: revision, outcome: outcome))
                    }

                    // N2 bookkeeping: re-anchor victims whose unredeemed ledger is
                    // empty at the pass boundary (their past wait is fully settled).
                    for value in 1...6 {
                        let name = revisionName(String(value))
                        if snapshotLedgers[name]?.segments.isEmpty != false {
                            wallBlockedNanos[name] = 0
                        }
                    }
                    let prePassFiles = reducer.state.generation.files

                    let effects = reduce(entries, nowNanos: now, reducer: &reducer)

                    // Accumulate one poll tick of present-and-blocked wall time per
                    // victim (blockedness judged from THIS batch's presence and the
                    // pre-pass file states of lower revisions) — EXCEPT ticks whose
                    // wait is provisionally attributed to an in-flight emission: when
                    // a pending owner holds a segment in the victim's ledger, the
                    // barrier has paused exactly that owner's charge pending its
                    // settlement (yield → redeemed and re-anchored below; rejection →
                    // the tick is the spec's event-bounded barrier cost, §4). An
                    // over-broad barrier (R9-F1) pauses charging while NO pending
                    // owner is in the ledger, so those ticks still count.
                    let pendingOwnersNow = reducer.state.generation.ordering.pendingEmissionOwners
                    for value in 1...6 where present[value] {
                        let name = revisionName(String(value))
                        let blocked = (1..<value).contains { lower in
                            present[lower] && isUnreadyBlockerState(
                                prePassFiles[revisionName(String(lower))])
                        }
                        guard blocked else { continue }
                        let ledgerOwners = reducer.state.generation.ordering
                            .victimLedgers[name]?.segments.keys
                        let attributedToInFlightOwner = ledgerOwners.map {
                            !pendingOwnersNow.isDisjoint(with: $0)
                        } ?? false
                        if !attributedToInFlightOwner {
                            wallBlockedNanos[name, default: 0] &+= pollTick
                        }
                    }
                    for effect in effects {
                        if case .emit(let intent) = effect { unsettled.append(intent) }
                        if case .log(let line) = effect, policy == .immutableAfterPublish,
                           line.contains("abandoning") {
                            immutableDecisions += 1
                        }
                    }
                    while !unsettled.isEmpty {
                        let intent = unsettled.removeFirst()
                        let outcome: EmissionResult.Outcome =
                            generator.next() % 5 == 0 ? .rejected : .yielded
                        if outcome == .yielded {
                            // Observed stream progress re-anchors N2 for every victim
                            // whose ledger held the emitting owner's segment, and for
                            // the emitter itself (its own wait is cleared, §5.2).
                            if let owner = order.revisionKey(in: intent.candidate.name) {
                                for (victim, ledger) in reducer.state.generation.ordering.victimLedgers
                                where ledger.segments[owner] != nil {
                                    wallBlockedNanos[victim] = 0
                                }
                            }
                            wallBlockedNanos[intent.candidate.name] = 0
                        }
                        _ = reducer.reduce(.emissionFinished(EmissionResult(
                            intent: intent, outcome: outcome)))
                    }
                    XCTAssertTrue(violations.isEmpty,
                                  "seed=\(Self.seed) run=\(run) policy=\(policy): \(violations)")
                }
            }
            if policy == .immutableAfterPublish {
                XCTAssertEqual(immutableDecisions, 0,
                               "ordering (and write-off) is mutable-policy-only")
            }
        }
    }

    func testDriverFaithfulS9ShapeHoldsWallClockInvariantN2() {
        // Deterministic S9-family anchor for N2 (round 9): settled r_1 is rewritten in
        // place and emits every 3 ticks while r_2 stalls and victim r_3 stays present
        // and blocked. r_1 never charges r_3's ledger, so no redemption ever re-anchors
        // the wall accumulator — exactly the regime where an over-broad barrier (R9-F1)
        // freezes owner-attributed time while wall time keeps growing. With the
        // dependence-scoped barrier, the write-off lands with wall ≤ ceiling + 1 tick.
        let pollTick: UInt64 = 1_000_000_000
        var reducer = WatcherReducer(
            state: WatcherState(
                generation: GenerationState(
                    id: FolderGeneration(rawValue: 1),
                    files: [:],
                    ordering: RevisionOrderingState(activeBlocker: nil)),
                lastEmittedDigestByName: [:]),
            configuration: WatcherReducerConfiguration(
                digestPolicy: .mutableStackerOutput,
                filePrefix: "live_stack",
                quietPeriodNanos: 100_000_000,
                pollIntervalNanos: pollTick))
        let ceiling = reducer.blockingCeilingNanos

        var wallBlockedNanos: [String: UInt64] = [:]
        var decisions: [(victim: String, wallNanos: UInt64, nowNanos: UInt64)] = []
        reducer.writeOffDecisionHookForTesting = { _, justifyingVictim, now in
            decisions.append((justifyingVictim, wallBlockedNanos[justifyingVictim] ?? 0, now))
        }

        let one = revisionName("1")
        let two = revisionName("2")
        let three = revisionName("3")
        for tick in 1...60 {
            let now = UInt64(tick) * pollTick
            var entries: [FileObservation] = []
            var presentNames: [String] = []
            if tick <= 3 {
                entries.append(makeObservation(name: one, revision: "1", outcome: .digested(
                    identity: makeIdentity(101), digest: "v0", byteCount: makeIdentity(101).size)))
                presentNames = [one]
            } else {
                let version = (tick - 4) / 3 + 1
                let identity = makeIdentity(Int64(200 + version))
                entries = [
                    makeObservation(name: one, revision: "1", outcome: .digested(
                        identity: identity, digest: "rw-\(version)", byteCount: identity.size)),
                    makeObservation(name: two, revision: "2", outcome: .invalid),
                    makeObservation(name: three, revision: "3", outcome: .digested(
                        identity: makeIdentity(3), digest: "v", byteCount: makeIdentity(3).size)),
                ]
                presentNames = [one, two, three]
            }

            // N2 bookkeeping, identical rules to the sweep.
            for name in [one, two, three] {
                if reducer.state.generation.ordering.victimLedgers[name]?.segments.isEmpty != false {
                    wallBlockedNanos[name] = 0
                }
            }
            let prePassFiles = reducer.state.generation.files

            let effects = reduce(entries, nowNanos: now, reducer: &reducer)

            let pendingOwnersNow = reducer.state.generation.ordering.pendingEmissionOwners
            for (index, name) in presentNames.enumerated() where index > 0 {
                let blocked = presentNames[..<index].contains { lower in
                    isUnreadyBlockerState(prePassFiles[lower])
                }
                guard blocked else { continue }
                let ledgerOwners = reducer.state.generation.ordering.victimLedgers[name]?.segments.keys
                let attributedToInFlightOwner = ledgerOwners.map {
                    !pendingOwnersNow.isDisjoint(with: $0)
                } ?? false
                if !attributedToInFlightOwner {
                    wallBlockedNanos[name, default: 0] &+= pollTick
                }
            }

            for case .emit(let intent) in effects {
                let outcome: EmissionResult.Outcome =
                    reducer.shouldExecuteEmission(intent) ? .yielded : .rejected
                if outcome == .yielded {
                    let owner = RevisionKey("1")   // only r_1 ever emits in this shape
                    for (victim, ledger) in reducer.state.generation.ordering.victimLedgers
                    where ledger.segments[owner] != nil {
                        wallBlockedNanos[victim] = 0
                    }
                    wallBlockedNanos[intent.candidate.name] = 0
                }
                _ = reducer.reduce(.emissionFinished(EmissionResult(intent: intent, outcome: outcome)))
            }
        }

        XCTAssertEqual(decisions.count, 1, "the stalled r_2 must be written off exactly once")
        XCTAssertEqual(reducer.state.generation.files[two], .writtenOff)
        for decision in decisions {
            XCTAssertEqual(decision.victim, three)
            XCTAssertLessThanOrEqual(
                decision.wallNanos,
                ceiling &+ pollTick,
                "N2 violated: justifier \(decision.victim) accumulated "
                    + "\(Double(decision.wallNanos) / 1e9)s of present-and-blocked wall time "
                    + "before the write-off at \(Double(decision.nowNanos) / 1e9)s "
                    + "(ceiling \(Double(ceiling) / 1e9)s + one tick)")
        }
    }

    /// N2 blockedness predicate (mirrors the reducer's participates/ready facts on the
    /// PRE-pass file state): nil/observing/digestPending block; ready, terminal, and
    /// settled states do not.
    private func isUnreadyBlockerState(_ state: FileState?) -> Bool {
        switch state {
        case nil, .observing, .digestPending:
            return true
        case .ready, .settled, .droppedOutOfOrder, .writtenOff:
            return false
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
            outcome: .invalid)
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
