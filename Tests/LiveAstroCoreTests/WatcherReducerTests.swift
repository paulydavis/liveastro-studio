import XCTest
@testable import LiveAstroCore

final class WatcherReducerTests: XCTestCase {
    func testRetainedDigestIsNeverGenerationOrderingEvidence() {
        let one = "live_stack_00001.fit"
        let two = "live_stack_00002.fit"
        let three = "live_stack_00003.fit"
        let twoIdentity = makeIdentity(2)
        let threeIdentity = makeIdentity(3)
        var reducer = makeReducer(
            generation: 1,
            files: [
                two: .settled(.emittedNow(identity: makeIdentity(20), digest: "old-two")),
            ],
            digests: [two: "old-two"])

        XCTAssertTrue(reducer.reduce(.replaceGeneration(
            FolderGeneration(rawValue: 2))).isEmpty)

        let firstPass = observeBatch([
            observation(name: one, revision: "00001", outcome: .invalid(reason: "truncated")),
            observation(name: two, revision: "00002", outcome: .digested(
                identity: twoIdentity, digest: "changed-two", byteCount: twoIdentity.size)),
            observation(name: three, revision: "00003", outcome: .digested(
                identity: threeIdentity, digest: "three", byteCount: threeIdentity.size)),
        ], nowNanos: 10, reducer: &reducer)

        XCTAssertTrue(firstPass.isEmpty)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.blocker, one)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.startNanos, 10)
        XCTAssertGreaterThan(
            reducer.state.generation.ordering.activeBlocker?.deadlineNanos ?? 0,
            10)

        XCTAssertTrue(observeBatch([
            observation(name: one, revision: "00001", outcome: .invalid(reason: "truncated")),
            observation(name: two, revision: "00002", outcome: .digested(
                identity: twoIdentity, digest: "changed-two", byteCount: twoIdentity.size)),
            observation(name: three, revision: "00003", outcome: .digested(
                identity: threeIdentity, digest: "three", byteCount: threeIdentity.size)),
        ], nowNanos: 20, reducer: &reducer).isEmpty)
        let heldEffects = observeBatch([
            observation(name: one, revision: "00001", outcome: .invalid(reason: "truncated")),
            observation(name: two, revision: "00002", outcome: .digested(
                identity: twoIdentity, digest: "changed-two", byteCount: twoIdentity.size)),
            observation(name: three, revision: "00003", outcome: .digested(
                identity: threeIdentity, digest: "three", byteCount: threeIdentity.size)),
        ], nowNanos: 120, reducer: &reducer)
        XCTAssertTrue(heldEffects.isEmpty, "later revisions stay held")
        XCTAssertEqual(reducer.state.generation.files[two], .ready(makeCandidate(
            name: two,
            identity: twoIdentity,
            digest: "changed-two",
            kind: .numbered(revision: "00002"))))

        let released = observeBatch([
            observation(name: one, revision: "00001", outcome: .invalid(reason: "truncated")),
            observation(name: two, revision: "00002", outcome: .identityUnchanged(
                identity: twoIdentity)),
            observation(name: three, revision: "00003", outcome: .identityUnchanged(
                identity: threeIdentity)),
        ], nowNanos: 30_000_000_010, reducer: &reducer)

        XCTAssertEqual(emittedNames(in: released), [two, three],
                       "write-off must release victims in numeric order, never [3, 2]")
        XCTAssertEqual(reducer.state.generation.files[one], .writtenOff)
    }

    func testEqualNumericRevisionIntentInvalidatesAfterEarlierSettlementAndRejectedDropLogs() {
        let paddedName = "live_stack_007.fit"
        let plainName = "live_stack_7.fit"
        let padded = makeCandidate(
            name: paddedName,
            identity: makeIdentity(7),
            digest: "padded",
            kind: .numbered(revision: "007"))
        let plain = makeCandidate(
            name: plainName,
            identity: makeIdentity(8),
            digest: "plain",
            kind: .numbered(revision: "7"))
        var reducer = makeReducer(files: [
            paddedName: .ready(padded),
            plainName: .ready(plain),
        ])

        let effects = observeBatch([
            observation(
                name: paddedName,
                revision: "007",
                outcome: .identityUnchanged(identity: padded.identity)),
            observation(
                name: plainName,
                revision: "7",
                outcome: .identityUnchanged(identity: plain.identity)),
        ], nowNanos: 10, reducer: &reducer)

        XCTAssertEqual(emittedNames(in: effects), [paddedName, plainName])
        let intents = effects.compactMap { effect -> EmissionIntent? in
            guard case .emit(let intent) = effect else { return nil }
            return intent
        }
        XCTAssertTrue(intents.allSatisfy { reducer.shouldExecuteEmission($0) })
        XCTAssertTrue(reducer.reduce(.emissionFinished(EmissionResult(
            intent: intents[0],
            outcome: .yielded))).isEmpty)

        XCTAssertFalse(reducer.shouldExecuteEmission(intents[1]),
                       "the first settlement's derived mark invalidates its equal sibling")
        let rejectedEffects = reducer.reduce(.emissionFinished(EmissionResult(
            intent: intents[1],
            outcome: .rejected)))
        XCTAssertEqual(rejectedEffects, [
            .log("revision 7 arrived out of order — skipped (high-water 007)"),
        ])
        XCTAssertEqual(reducer.state.generation.files[plainName], .droppedOutOfOrder)
    }

    func testRoleRoundTripStartsFreshEpisodeClock() {
        var reducer = makeReducer()

        XCTAssertTrue(observeBatch([
            invalidRevision("00002"),
            invalidRevision("00003"),
        ], nowNanos: 100, reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker,
                       BlockingEpisode(
                        blocker: revisionName("00002"),
                        startNanos: 100,
                        deadlineNanos: 100 &+ reducer.blockingBudgetNanos,
                        victims: [revisionName("00003")]))

        XCTAssertTrue(observeBatch([
            invalidRevision("00001"),
            invalidRevision("00002"),
            invalidRevision("00003"),
        ], nowNanos: 200, reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.blocker,
                       revisionName("00001"))
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.startNanos, 200,
                       "00002 is now a victim, so its first blocker clock is gone")

        XCTAssertTrue(observeBatch([
            observation(name: revisionName("00001"), revision: "00001", outcome: .absent),
            invalidRevision("00002"),
            invalidRevision("00003"),
        ], nowNanos: 300, reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker,
                       BlockingEpisode(
                        blocker: revisionName("00002"),
                        startNanos: 300,
                        deadlineNanos: 300 &+ reducer.blockingBudgetNanos,
                        victims: [revisionName("00003")]),
                       "the second blocker role starts a new episode at the transition")
    }

    func testVictimDisappearanceDestroysEpisodeAndReappearanceStartsFresh() {
        var reducer = makeReducer()

        XCTAssertTrue(observeBatch([
            invalidRevision("00001"),
            invalidRevision("00002"),
        ], nowNanos: 10, reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.startNanos, 10)

        XCTAssertTrue(observeBatch([
            invalidRevision("00001"),
            observation(name: revisionName("00002"), revision: "00002", outcome: .absent),
        ], nowNanos: 20, reducer: &reducer).isEmpty)
        XCTAssertNil(reducer.state.generation.ordering.activeBlocker)

        XCTAssertTrue(observeBatch([
            invalidRevision("00001"),
            invalidRevision("00002"),
        ], nowNanos: 30, reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.startNanos, 30)
    }

    func testDuplicateSettlementWhileHeldRemovesVictimAndEpisode() {
        let victim = revisionName("00002")
        let identity = makeIdentity(2)
        var reducer = makeReducer(
            files: [victim: .digestPending(PendingDigest(
                digest: "same", identity: identity, firstObservedNanos: 0))],
            digests: [victim: "same"])

        XCTAssertTrue(observeBatch([
            invalidRevision("00001"),
            observation(name: victim, revision: "00002", outcome: .identityUnchanged(
                identity: identity)),
        ], nowNanos: 10, reducer: &reducer).isEmpty)
        XCTAssertNotNil(reducer.state.generation.ordering.activeBlocker)

        XCTAssertTrue(observeBatch([
            invalidRevision("00001"),
            observation(name: victim, revision: "00002", outcome: .digested(
                identity: identity, digest: "same", byteCount: identity.size)),
        ], nowNanos: 20, reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.state.generation.files[victim], .settled(
            .duplicateOfLastEmission(identity: identity, digest: "same")))
        XCTAssertNil(reducer.state.generation.ordering.activeBlocker)
    }

    func testLoneBlockerNeverOwnsEpisode() {
        var reducer = makeReducer()

        XCTAssertTrue(observeBatch([
            invalidRevision("00001"),
        ], nowNanos: 10, reducer: &reducer).isEmpty)

        XCTAssertNil(reducer.state.generation.ordering.activeBlocker)
    }

    func testBlockingBudgetFormulaGraceAndCeiling() {
        let quietDominates = makeReducer(quietPeriodNanos: 4_000_000_000,
                                         pollIntervalNanos: 1_000_000_000)
        XCTAssertEqual(quietDominates.blockingBudgetNanos, 40_000_000_000)
        XCTAssertEqual(quietDominates.blockingGraceNanos, 4_000_000_000)
        XCTAssertEqual(quietDominates.blockingCeilingNanos, 56_000_000_000)

        let pollDominates = makeReducer(quietPeriodNanos: 1_000_000_000,
                                        pollIntervalNanos: 7_000_000_000)
        XCTAssertEqual(pollDominates.blockingBudgetNanos, 35_000_000_000)
        XCTAssertEqual(pollDominates.blockingGraceNanos, 1_000_000_000)
        XCTAssertEqual(pollDominates.blockingCeilingNanos, 39_000_000_000)
    }

    func testBlockerChurnNeverResetsEpisodeClock() {
        var reducer = makeReducer()
        XCTAssertTrue(observeBatch([
            invalidRevision("00001"),
            invalidRevision("00002"),
        ], nowNanos: 10, reducer: &reducer).isEmpty)
        let originalEpisode = reducer.state.generation.ordering.activeBlocker

        XCTAssertTrue(observeBatch([
            observation(
                name: revisionName("00001"),
                revision: "00001",
                outcome: .unstable(identity: makeIdentity(99))),
            invalidRevision("00002"),
        ], nowNanos: 20, reducer: &reducer).isEmpty)

        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker, originalEpisode)
    }

    func testConvergenceGraceClampsToCeilingAndWriteOffLogsEpisodeDuration() {
        let blocker = revisionName("00001")
        let identity = makeIdentity(1)
        let configuration = makeConfiguration(quietPeriodNanos: 10, pollIntervalNanos: 1_000)
        let budget = max(
            WatcherReducer.blockerBudgetFloorNanos,
            WatcherReducer.blockerBudgetQuietPeriods &* configuration.quietPeriodNanos,
            WatcherReducer.blockerBudgetPollIntervals &* configuration.pollIntervalNanos)
        let ceiling = budget &+ WatcherReducer.maxBlockerGraceExtensions
            &* configuration.quietPeriodNanos
        var reducer = WatcherReducer(
            state: WatcherState(
                generation: GenerationState(
                    id: FolderGeneration(rawValue: 1),
                    files: [
                        blocker: .digestPending(PendingDigest(
                            digest: "stable",
                            identity: identity,
                            firstObservedNanos: ceiling - 5)),
                    ],
                    ordering: RevisionOrderingState(activeBlocker: BlockingEpisode(
                        blocker: blocker,
                        startNanos: 0,
                        deadlineNanos: ceiling - 1,
                        victims: [revisionName("00002")]))),
                lastEmittedDigestByName: [:]),
            configuration: configuration)

        XCTAssertTrue(observeBatch([
            observation(name: blocker, revision: "00001", outcome: .digested(
                identity: identity, digest: "stable", byteCount: identity.size)),
            invalidRevision("00002"),
        ], nowNanos: ceiling - 2, reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.deadlineNanos, ceiling)

        let effects = observeBatch([
            observation(name: blocker, revision: "00001", outcome: .digested(
                identity: identity, digest: "stable", byteCount: identity.size)),
            invalidRevision("00002"),
        ], nowNanos: ceiling, reducer: &reducer)

        XCTAssertEqual(effects, [.log(
            "revision 00001 blocked emissions for 30s without completing "
            + "— abandoning it; later revisions proceed (frame lost: \(blocker))")])
        XCTAssertEqual(reducer.state.generation.files[blocker], .writtenOff)
        XCTAssertNil(reducer.state.generation.ordering.activeBlocker)
        XCTAssertEqual(reducer.emittedRevisionHighWater, nil,
                       "write-off must never advance the derived mark")
    }

    func testNumberedReadyIntentsUseNumericOrder() {
        let two = revisionName("002")
        let ten = revisionName("10")
        let twoCandidate = makeCandidate(
            name: two,
            identity: makeIdentity(2),
            digest: "two",
            kind: .numbered(revision: "002"))
        let tenCandidate = makeCandidate(
            name: ten,
            identity: makeIdentity(10),
            digest: "ten",
            kind: .numbered(revision: "10"))
        var reducer = makeReducer(files: [two: .ready(twoCandidate), ten: .ready(tenCandidate)])

        let effects = observeBatch([
            observation(name: ten, revision: "10", outcome: .identityUnchanged(
                identity: tenCandidate.identity)),
            observation(name: two, revision: "002", outcome: .identityUnchanged(
                identity: twoCandidate.identity)),
        ], nowNanos: 10, reducer: &reducer)

        XCTAssertEqual(emittedNames(in: effects), [two, ten])
    }

    func testNumericEqualRevisionUsesRawDigitsBeforeFullNameTiebreak() {
        let rawSeven = "LIVE_STACK_7.fit"
        let paddedSeven = "live_stack_007.fit"
        let rawCandidate = makeCandidate(
            name: rawSeven,
            identity: makeIdentity(7),
            digest: "raw-seven",
            kind: .numbered(revision: "7"))
        let paddedCandidate = makeCandidate(
            name: paddedSeven,
            identity: makeIdentity(70),
            digest: "padded-seven",
            kind: .numbered(revision: "007"))
        var reducer = makeReducer(files: [
            rawSeven: .ready(rawCandidate),
            paddedSeven: .ready(paddedCandidate),
        ])

        let effects = observeBatch([
            observation(name: rawSeven, revision: "7", outcome: .identityUnchanged(
                identity: rawCandidate.identity)),
            observation(name: paddedSeven, revision: "007", outcome: .identityUnchanged(
                identity: paddedCandidate.identity)),
        ], nowNanos: 10, reducer: &reducer)

        XCTAssertEqual(
            emittedNames(in: effects),
            [paddedSeven, rawSeven],
            "numeric ties compare raw digit strings before case-varied full names")
        for effect in effects {
            guard case .emit(let intent) = effect else { continue }
            XCTAssertTrue(reducer.reduce(.emissionFinished(EmissionResult(
                intent: intent,
                outcome: .yielded))).isEmpty)
        }
        XCTAssertEqual(reducer.emittedRevisionHighWater, "007",
                       "the raw-digit-first revision remains the derived tie survivor")
    }

    func testMarkDropLogsOnceAndNeverEmitsOrAdvancesHighWater() {
        let identity = makeIdentity(3)
        let emitted = revisionName("00003")
        let late = revisionName("00002")
        var reducer = makeReducer(files: [
            emitted: .settled(.emittedNow(identity: identity, digest: "three")),
        ])
        let batch = [invalidRevision("00002")]

        XCTAssertEqual(observeBatch(batch, nowNanos: 10, reducer: &reducer), [.log(
            "revision 00002 arrived out of order — skipped (high-water 00003)")])
        XCTAssertEqual(reducer.state.generation.files[late], .droppedOutOfOrder)
        XCTAssertEqual(reducer.emittedRevisionHighWater, "00003")

        XCTAssertTrue(observeBatch(batch, nowNanos: 20, reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.emittedRevisionHighWater, "00003")
    }

    func testOnlyYieldedEmissionAdvancesDerivedHighWater() {
        let name = revisionName("00007")
        let candidate = makeCandidate(
            name: name,
            identity: makeIdentity(7),
            digest: "seven",
            kind: .numbered(revision: "00007"))
        var reducer = makeReducer(files: [name: .ready(candidate)])
        let intent = EmissionIntent(generation: reducer.state.generation.id, candidate: candidate)

        XCTAssertNil(reducer.emittedRevisionHighWater)
        XCTAssertTrue(reducer.reduce(.emissionFinished(EmissionResult(
            intent: intent,
            outcome: .rejected))).isEmpty)
        XCTAssertNil(reducer.emittedRevisionHighWater)

        XCTAssertTrue(reducer.reduce(.emissionFinished(EmissionResult(
            intent: intent,
            outcome: .yielded))).isEmpty)
        XCTAssertEqual(reducer.emittedRevisionHighWater, "00007")
    }

    func testImmutableNumberedEmissionSettlesWithoutDerivedHighWater() {
        let name = revisionName("00007")
        let candidate = makeCandidate(
            name: name,
            identity: makeIdentity(7),
            digest: "seven",
            kind: .numbered(revision: "00007"))
        var reducer = makeReducer(
            files: [name: .ready(candidate)],
            digestPolicy: .immutableAfterPublish)

        XCTAssertTrue(reducer.reduce(.emissionFinished(EmissionResult(
            intent: EmissionIntent(generation: reducer.state.generation.id, candidate: candidate),
            outcome: .yielded))).isEmpty)

        XCTAssertEqual(reducer.state.generation.files[name], .settled(.emittedNow(
            identity: candidate.identity,
            digest: candidate.digest)))
        XCTAssertEqual(reducer.state.lastEmittedDigestByName[name], candidate.digest)
        XCTAssertNil(reducer.emittedRevisionHighWater,
                     "revision ordering and its derived mark are mutable-policy-only")
    }

    func testVictimEmissionResultImmediatelyPrunesExhaustedEpisode() {
        let blocker = revisionName("00001")
        let victim = revisionName("00002")
        let victimCandidate = makeCandidate(
            name: victim,
            identity: makeIdentity(2),
            digest: "victim",
            kind: .numbered(revision: "00002"))
        var reducer = makeReducer(files: [victim: .ready(victimCandidate)])

        let issued = observeBatch([
            observation(name: victim, revision: "00002", outcome: .identityUnchanged(
                identity: victimCandidate.identity)),
        ], nowNanos: 10, reducer: &reducer)
        guard case .emit(let victimIntent) = issued.first else {
            return XCTFail("higher ready revision must first receive an intent")
        }

        XCTAssertTrue(observeBatch([
            invalidRevision("00001"),
            observation(name: victim, revision: "00002", outcome: .identityUnchanged(
                identity: victimCandidate.identity)),
        ], nowNanos: 20, reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker,
                       BlockingEpisode(
                        blocker: blocker,
                        startNanos: 20,
                        deadlineNanos: 20 &+ reducer.blockingBudgetNanos,
                        victims: [victim]))

        XCTAssertTrue(reducer.reduce(.emissionFinished(EmissionResult(
            intent: victimIntent,
            outcome: .yielded))).isEmpty)
        XCTAssertNil(reducer.state.generation.ordering.activeBlocker,
                     "the sole victim became terminal, so the episode predicate is false")

        XCTAssertTrue(observeBatch([
            invalidRevision("00003"),
            invalidRevision("00004"),
        ], nowNanos: 30, reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.startNanos, 30,
                       "a later victim starts a fresh episode, never the stale clock")
    }

    func testUnrelatedClassicEmissionPreservesInvalidVictimEpisode() {
        let blocker = revisionName("00001")
        let victim = revisionName("00002")
        let classic = "live_stack.fit"
        let classicCandidate = makeCandidate(
            name: classic,
            identity: makeIdentity(9),
            digest: "classic")
        var reducer = makeReducer(files: [classic: .ready(classicCandidate)])

        let effects = observeBatch([
            FileObservation(
                name: classic,
                url: classicCandidate.url,
                kind: .classicMutable,
                outcome: .identityUnchanged(identity: classicCandidate.identity)),
            invalidRevision("00001"),
            invalidRevision("00002"),
        ], nowNanos: 100, reducer: &reducer)
        guard let classicIntent = effects.compactMap({ effect -> EmissionIntent? in
            guard case .emit(let intent) = effect,
                  intent.candidate.name == classic else { return nil }
            return intent
        }).first else {
            return XCTFail("ready classic entry must receive an earlier emission intent")
        }
        let episodeBeforeEmission = reducer.state.generation.ordering.activeBlocker
        XCTAssertEqual(episodeBeforeEmission?.blocker, blocker)
        XCTAssertEqual(episodeBeforeEmission?.startNanos, 100)
        XCTAssertEqual(episodeBeforeEmission?.deadlineNanos,
                       100 &+ reducer.blockingBudgetNanos)
        XCTAssertEqual(episodeBeforeEmission?.victims, [victim])

        XCTAssertTrue(reducer.reduce(.emissionFinished(EmissionResult(
            intent: classicIntent,
            outcome: .yielded))).isEmpty)

        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker,
                       episodeBeforeEmission,
                       "unrelated classic completion cannot erase invalid victim \(victim)")
    }

    func testTerminalizingOneOfMultipleVictimsRetainsClockAndRemainingVictim() {
        let blocker = revisionName("00001")
        let terminalizingVictim = revisionName("00002")
        let remainingVictim = revisionName("00003")
        let identity = makeIdentity(2)
        let digest = "already-emitted"
        var reducer = makeReducer(
            files: [terminalizingVictim: .digestPending(PendingDigest(
                digest: digest,
                identity: identity,
                firstObservedNanos: 0))],
            digests: [terminalizingVictim: digest])

        XCTAssertTrue(observeBatch([
            invalidRevision("00001"),
            observation(
                name: terminalizingVictim,
                revision: "00002",
                outcome: .identityUnchanged(identity: identity)),
            invalidRevision("00003"),
        ], nowNanos: 100, reducer: &reducer).isEmpty)
        let originalEpisode = reducer.state.generation.ordering.activeBlocker
        XCTAssertEqual(originalEpisode?.blocker, blocker)
        XCTAssertEqual(originalEpisode?.victims, [terminalizingVictim, remainingVictim])

        XCTAssertTrue(observeBatch([
            invalidRevision("00001"),
            observation(
                name: terminalizingVictim,
                revision: "00002",
                outcome: .digested(
                    identity: identity,
                    digest: digest,
                    byteCount: identity.size)),
            invalidRevision("00003"),
        ], nowNanos: 200, reducer: &reducer).isEmpty)

        XCTAssertEqual(reducer.state.generation.files[terminalizingVictim],
                       .settled(.duplicateOfLastEmission(identity: identity, digest: digest)))
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.blocker, blocker)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.startNanos,
                       originalEpisode?.startNanos)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.deadlineNanos,
                       originalEpisode?.deadlineNanos)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.victims,
                       [remainingVictim])
    }

    func testObservationRefreshReplacesVictimSnapshotAndTearsDownWhenEmpty() {
        let blocker = revisionName("00001")
        let firstVictim = revisionName("00002")
        let remainingVictim = revisionName("00003")
        var reducer = makeReducer()

        XCTAssertTrue(observeBatch([
            invalidRevision("00001"),
            invalidRevision("00002"),
            invalidRevision("00003"),
        ], nowNanos: 100, reducer: &reducer).isEmpty)
        let originalEpisode = reducer.state.generation.ordering.activeBlocker
        XCTAssertEqual(originalEpisode?.blocker, blocker)
        XCTAssertEqual(originalEpisode?.victims, [firstVictim, remainingVictim])

        XCTAssertTrue(observeBatch([
            invalidRevision("00001"),
            observation(name: firstVictim, revision: "00002", outcome: .absent),
            invalidRevision("00003"),
        ], nowNanos: 200, reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.startNanos,
                       originalEpisode?.startNanos)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.deadlineNanos,
                       originalEpisode?.deadlineNanos)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.victims,
                       [remainingVictim])

        XCTAssertTrue(observeBatch([
            invalidRevision("00001"),
            observation(name: firstVictim, revision: "00002", outcome: .absent),
            observation(name: remainingVictim, revision: "00003", outcome: .absent),
        ], nowNanos: 300, reducer: &reducer).isEmpty)
        XCTAssertNil(reducer.state.generation.ordering.activeBlocker)
    }

    func testSuccessfulEmissionOfActiveBlockerPrunesInconsistentEpisode() {
        let blocker = revisionName("00001")
        let victim = revisionName("00002")
        let candidate = makeCandidate(
            name: blocker,
            identity: makeIdentity(1),
            digest: "blocker",
            kind: .numbered(revision: "00001"))
        var reducer = makeReducer(
            files: [
                blocker: .ready(candidate),
                victim: .observing(stat: makeIdentity(2)),
            ],
            activeBlocker: BlockingEpisode(
                blocker: blocker,
                startNanos: 10,
                deadlineNanos: 20,
                victims: [victim]))

        XCTAssertTrue(reducer.reduce(.emissionFinished(EmissionResult(
            intent: EmissionIntent(generation: reducer.state.generation.id, candidate: candidate),
            outcome: .yielded))).isEmpty)

        XCTAssertNil(reducer.state.generation.ordering.activeBlocker,
                     "terminalizing the recorded blocker must remove an impossible episode")
    }

    func testGenerationReplacementPreservesOnlyLatestDigestByName() {
        let identity = makeIdentity(1)
        let candidate = makeCandidate(name: "ready.fit", identity: identity, digest: "ready")
        let files: [String: FileState] = [
            "observing.fit": .observing(stat: identity),
            "pending.fit": .digestPending(PendingDigest(
                digest: "pending", identity: identity, firstObservedNanos: 10)),
            "ready.fit": .ready(candidate),
            "settled.fit": .settled(.emittedNow(identity: identity, digest: "settled")),
            "dropped.fit": .droppedOutOfOrder,
            "written-off.fit": .writtenOff,
        ]
        let digests = ["settled.fit": "settled"]
        var reducer = WatcherReducer(
            state: WatcherState(
                generation: GenerationState(
                    id: FolderGeneration(rawValue: 41),
                    files: files,
                    ordering: RevisionOrderingState(activeBlocker: BlockingEpisode(
                        blocker: "blocked.fit",
                        startNanos: 100,
                        deadlineNanos: 200,
                        victims: ["victim.fit"]))),
                lastEmittedDigestByName: digests),
            configuration: makeConfiguration())

        let effects = reducer.reduce(.replaceGeneration(FolderGeneration(rawValue: 42)))

        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(reducer.state.generation.id, FolderGeneration(rawValue: 42))
        XCTAssertTrue(reducer.state.generation.files.isEmpty)
        XCTAssertNil(reducer.state.generation.ordering.activeBlocker)
        XCTAssertEqual(reducer.state.lastEmittedDigestByName, digests)
    }

    func testEqualGenerationReplacementLeavesEntireWatcherStateUnchanged() {
        let original = makePopulatedWatcherState(generation: 42)
        var reducer = WatcherReducer(state: original, configuration: makeConfiguration())

        let effects = reducer.reduce(.replaceGeneration(FolderGeneration(rawValue: 42)))

        XCTAssertTrue(effects.isEmpty)
        assertWatcherState(reducer.state, equals: original)
    }

    func testRegressiveGenerationReplacementLeavesEntireWatcherStateUnchanged() {
        let original = makePopulatedWatcherState(generation: 42)
        var reducer = WatcherReducer(state: original, configuration: makeConfiguration())

        let effects = reducer.reduce(.replaceGeneration(FolderGeneration(rawValue: 41)))

        XCTAssertTrue(effects.isEmpty)
        assertWatcherState(reducer.state, equals: original)
    }

    func testAbsenceSemantics() {
        let identity = makeIdentity(1)
        let candidate = makeCandidate(name: "file.fit", identity: identity, digest: "ready")
        let cases: [(label: String, state: FileState, survives: Bool)] = [
            ("observing", .observing(stat: identity), false),
            ("digest pending", .digestPending(PendingDigest(
                digest: "pending", identity: identity, firstObservedNanos: 10)), false),
            ("ready", .ready(candidate), false),
            ("settled", .settled(.emittedNow(identity: identity, digest: "settled")), true),
            ("dropped", .droppedOutOfOrder, true),
            ("written off", .writtenOff, true),
        ]

        for testCase in cases {
            var reducer = makeReducer(files: ["file.fit": testCase.state])
            let effects = reducer.reduce(.observe(ObservationBatch(
                generation: reducer.state.generation.id,
                entries: [FileObservation(
                    name: "file.fit",
                    url: URL(fileURLWithPath: "/watch/file.fit"),
                    kind: .classicMutable,
                    outcome: .absent)],
                nowNanos: 20)))

            XCTAssertTrue(effects.isEmpty, testCase.label)
            if testCase.survives {
                XCTAssertEqual(reducer.state.generation.files["file.fit"], testCase.state,
                               testCase.label)
            } else {
                XCTAssertNil(reducer.state.generation.files["file.fit"], testCase.label)
            }
        }
    }

    func testEmittedEvidenceAndNumericHighWaterAreDerivedOnlyFromEmittedSettlements() {
        let identity = makeIdentity(1)
        let files: [String: FileState] = [
            "live_stack.fit": .settled(.emittedNow(identity: identity, digest: "classic")),
            "live_stack_00002.fit": .settled(.emittedNow(identity: identity, digest: "two")),
            "live_stack_10.fit": .settled(.emittedNow(identity: identity, digest: "ten")),
            "live_stack_999.fit": .settled(.duplicateOfLastEmission(
                identity: identity, digest: "duplicate")),
            "live_stack_1000.fit": .ready(makeCandidate(
                name: "live_stack_1000.fit",
                identity: identity,
                digest: "ready",
                kind: .numbered(revision: "1000"))),
            "live_stack_2000.fit": .droppedOutOfOrder,
        ]
        let reducer = makeReducer(files: files)

        XCTAssertEqual(
            reducer.state.generation.emittedThisGeneration,
            Set(["live_stack.fit", "live_stack_00002.fit", "live_stack_10.fit"]))
        XCTAssertEqual(reducer.emittedRevisionHighWater, "10")
    }

    func testBothSettlementVariantsRetainIdentityAndDigestForFastPath() {
        let emittedIdentity = makeIdentity(1)
        let duplicateIdentity = makeIdentity(2)
        let numberedURL = URL(fileURLWithPath: "/watch/live_stack_00001.fit")
        let immutableURL = URL(fileURLWithPath: "/watch/other.fit")
        let reducer = makeReducer(
            files: [
                "live_stack_00001.fit": .settled(.emittedNow(
                    identity: emittedIdentity, digest: "emitted-digest")),
                "other.fit": .settled(.duplicateOfLastEmission(
                    identity: duplicateIdentity, digest: "duplicate-digest")),
            ],
            digestPolicy: .immutableAfterPublish)

        let plan = reducer.readPlan(for: [
            EnumeratedEntry(
                name: "live_stack_00001.fit",
                url: numberedURL,
                identity: emittedIdentity,
                isFITS: true),
            EnumeratedEntry(
                name: "other.fit",
                url: immutableURL,
                identity: duplicateIdentity,
                isFITS: true),
        ])

        XCTAssertEqual(plan, [
            .acceptIdentity(FileObservation(
                name: "live_stack_00001.fit",
                url: numberedURL,
                kind: .numbered(revision: "00001"),
                outcome: .identityUnchanged(identity: emittedIdentity))),
            .acceptIdentity(FileObservation(
                name: "other.fit",
                url: immutableURL,
                kind: .immutable,
                outcome: .identityUnchanged(identity: duplicateIdentity))),
        ])
    }

    func testClassicMutableSettlementStillRequestsContentRead() {
        let identity = makeIdentity(1)
        let url = URL(fileURLWithPath: "/watch/live_stack.fit")
        let reducer = makeReducer(files: [
            "live_stack.fit": .settled(.emittedNow(identity: identity, digest: "digest")),
        ])

        XCTAssertEqual(reducer.readPlan(for: [EnumeratedEntry(
            name: "live_stack.fit",
            url: url,
            identity: identity,
            isFITS: true)]), [
                .readContent(
                    name: "live_stack.fit",
                    url: url,
                    kind: .classicMutable,
                    identity: identity,
                    isFITS: true),
            ])
    }

    func testSettledFastPathRequiresCurrentIdentityToMatchSettlement() {
        let settledIdentity = makeIdentity(1)
        let currentIdentity = makeIdentity(2)
        let name = "live_stack_00001.fit"
        let url = URL(fileURLWithPath: "/watch/\(name)")
        let reducer = makeReducer(files: [
            name: .settled(.emittedNow(identity: settledIdentity, digest: "digest")),
        ])

        XCTAssertEqual(reducer.readPlan(for: [EnumeratedEntry(
            name: name,
            url: url,
            identity: currentIdentity,
            isFITS: true)]), [
                .readContent(
                    name: name,
                    url: url,
                    kind: .numbered(revision: "00001"),
                    identity: currentIdentity,
                    isFITS: true),
            ])
    }

    func testRevisionReadPlanClassificationIsAnchoredEscapedAndPrefixAware() {
        struct ClassificationCase {
            let label: String
            let prefix: String?
            let name: String
            let isFITS: Bool
            let expectedKind: WatcherEntryKind
        }

        let escapedPrefix = "live.stack+(v1)"
        let cases = [
            ClassificationCase(
                label: "escaped metacharacters",
                prefix: escapedPrefix,
                name: "live.stack+(v1)_00001.fit",
                isFITS: true,
                expectedKind: .numbered(revision: "00001")),
            ClassificationCase(
                label: "anchored at start",
                prefix: escapedPrefix,
                name: "xlive.stack+(v1)_00001.fit",
                isFITS: true,
                expectedKind: .classicMutable),
            ClassificationCase(
                label: "anchored at end",
                prefix: escapedPrefix,
                name: "live.stack+(v1)_00001.fit.bak",
                isFITS: false,
                expectedKind: .classicMutable),
            ClassificationCase(
                label: "case insensitive",
                prefix: escapedPrefix,
                name: "LIVE.STACK+(V1)_00002.FIT",
                isFITS: true,
                expectedKind: .numbered(revision: "00002")),
            ClassificationCase(
                label: "unsupported extension",
                prefix: escapedPrefix,
                name: "live.stack+(v1)_00003.txt",
                isFITS: false,
                expectedKind: .classicMutable),
            ClassificationCase(
                label: "empty prefix",
                prefix: "",
                name: "live_stack_00004.fit",
                isFITS: true,
                expectedKind: .classicMutable),
            ClassificationCase(
                label: "nil prefix",
                prefix: nil,
                name: "live_stack_00005.fit",
                isFITS: true,
                expectedKind: .classicMutable),
        ]
        let identity = makeIdentity(1)

        for testCase in cases {
            let reducer = makeReducer(filePrefix: testCase.prefix)
            let url = URL(fileURLWithPath: "/watch/\(testCase.name)")
            XCTAssertEqual(reducer.readPlan(for: [EnumeratedEntry(
                name: testCase.name,
                url: url,
                identity: identity,
                isFITS: testCase.isFITS)]), [
                    .readContent(
                        name: testCase.name,
                        url: url,
                        kind: testCase.expectedKind,
                        identity: identity,
                        isFITS: testCase.isFITS),
                ], testCase.label)
        }
    }

    func testOrderedNamesForScanUsesAnchoredNumericComparator() {
        let reducer = makeReducer(filePrefix: "live.stack+(v1)")

        XCTAssertEqual(reducer.orderedNamesForScan([
            "live.stack+(v1)_10.fit",
            "z.fit",
            "live.stack+(v1)_002.fit",
            "live.stack+(v1)_1.fit",
            "a.fit",
        ]), [
            "a.fit",
            "z.fit",
            "live.stack+(v1)_1.fit",
            "live.stack+(v1)_002.fit",
            "live.stack+(v1)_10.fit",
        ])
    }

    func testEntryKindForPreReadFailureUsesAnchoredReducerClassification() {
        let mutable = makeReducer(filePrefix: "live.stack+(v1)")
        XCTAssertEqual(mutable.entryKind(for: "live.stack+(v1)_0007.fit"),
                       .numbered(revision: "0007"))
        XCTAssertEqual(mutable.entryKind(for: "live.stack+(v1)_extra_0007.fit"),
                       .classicMutable)

        let immutable = makeReducer(digestPolicy: .immutableAfterPublish)
        XCTAssertEqual(immutable.entryKind(for: "frame.fit"), .immutable)
    }

    func testThirtyDigitRevisionClassifiesAndDerivesHighWaterWithoutIntConversion() {
        let identity = makeIdentity(1)
        let smallerRevision = "99999999999999999999999999999"
        let thirtyDigitRevision = "123456789012345678901234567890"
        let name = "live_stack_\(thirtyDigitRevision).fit"
        let reducer = makeReducer(files: [
            "live_stack_\(smallerRevision).fit": .settled(.emittedNow(
                identity: identity, digest: "smaller")),
            name: .settled(.emittedNow(identity: identity, digest: "larger")),
        ])
        let url = URL(fileURLWithPath: "/watch/\(name)")

        XCTAssertEqual(reducer.readPlan(for: [EnumeratedEntry(
            name: name,
            url: url,
            identity: makeIdentity(2),
            isFITS: true)]), [
                .readContent(
                    name: name,
                    url: url,
                    kind: .numbered(revision: thirtyDigitRevision),
                    identity: makeIdentity(2),
                    isFITS: true),
            ])
        XCTAssertEqual(reducer.emittedRevisionHighWater, thirtyDigitRevision)
    }

    func testClassicTransientDigestReturnsToLastEmissionWithoutYield() {
        let identity = makeIdentity(1)
        var reducer = makeReducer(
            files: [
                "live_stack.fit": .settled(.emittedNow(identity: identity, digest: "A")),
            ],
            digests: ["live_stack.fit": "A"])

        let transientEffects = observe(
            name: "live_stack.fit",
            kind: .classicMutable,
            outcome: .digested(identity: identity, digest: "B", byteCount: identity.size),
            nowNanos: 10,
            reducer: &reducer)
        XCTAssertTrue(transientEffects.isEmpty)
        XCTAssertEqual(reducer.state.generation.files["live_stack.fit"], .digestPending(
            PendingDigest(digest: "B", identity: identity, firstObservedNanos: 10)))

        let returnEffects = observe(
            name: "live_stack.fit",
            kind: .classicMutable,
            outcome: .digested(identity: identity, digest: "A", byteCount: identity.size),
            nowNanos: 20,
            reducer: &reducer)

        XCTAssertTrue(returnEffects.isEmpty)
        XCTAssertEqual(reducer.state.generation.files["live_stack.fit"], .settled(
            .duplicateOfLastEmission(identity: identity, digest: "A")))
        XCTAssertEqual(reducer.state.lastEmittedDigestByName["live_stack.fit"], "A")
    }

    func testClassicEmittedBThenAReearnsGateAndYieldsA() {
        let identity = makeIdentity(1)
        var reducer = makeReducer(
            files: [
                "live_stack.fit": .settled(.emittedNow(identity: identity, digest: "B")),
            ],
            digests: ["live_stack.fit": "B"])

        let firstEffects = observe(
            name: "live_stack.fit",
            kind: .classicMutable,
            outcome: .digested(identity: identity, digest: "A", byteCount: identity.size),
            nowNanos: 100,
            reducer: &reducer)
        XCTAssertTrue(firstEffects.isEmpty)
        XCTAssertEqual(reducer.state.generation.files["live_stack.fit"], .digestPending(
            PendingDigest(digest: "A", identity: identity, firstObservedNanos: 100)))

        let secondEffects = observe(
            name: "live_stack.fit",
            kind: .classicMutable,
            outcome: .digested(identity: identity, digest: "A", byteCount: identity.size),
            nowNanos: 200,
            reducer: &reducer)

        let candidate = makeCandidate(
            name: "live_stack.fit",
            identity: identity,
            digest: "A")
        XCTAssertEqual(reducer.state.generation.files["live_stack.fit"], .ready(candidate))
        XCTAssertEqual(secondEffects, [.emit(EmissionIntent(
            generation: reducer.state.generation.id,
            candidate: candidate))])
        XCTAssertEqual(reducer.state.lastEmittedDigestByName["live_stack.fit"], "B")
    }

    func testNewMutableEntryRequiresStatStabilityThenDigestStability() {
        let identity = makeIdentity(1)
        let outcome = ObservationOutcome.digested(
            identity: identity,
            digest: "A",
            byteCount: identity.size)
        var reducer = makeReducer()

        XCTAssertTrue(observe(
            name: "live_stack.fit", kind: .classicMutable, outcome: outcome,
            nowNanos: 0, reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.state.generation.files["live_stack.fit"],
                       .observing(stat: identity))

        XCTAssertTrue(observe(
            name: "live_stack.fit", kind: .classicMutable, outcome: outcome,
            nowNanos: 50, reducer: &reducer).isEmpty)
        let pending = PendingDigest(digest: "A", identity: identity, firstObservedNanos: 50)
        XCTAssertEqual(reducer.state.generation.files["live_stack.fit"], .digestPending(pending))

        XCTAssertTrue(observe(
            name: "live_stack.fit", kind: .classicMutable, outcome: outcome,
            nowNanos: 149, reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.state.generation.files["live_stack.fit"], .digestPending(pending))

        let candidate = makeCandidate(name: "live_stack.fit", identity: identity, digest: "A")
        XCTAssertEqual(observe(
            name: "live_stack.fit", kind: .classicMutable, outcome: outcome,
            nowNanos: 150, reducer: &reducer), [
                .emit(EmissionIntent(generation: FolderGeneration(rawValue: 1), candidate: candidate)),
            ])
        XCTAssertEqual(reducer.state.generation.files["live_stack.fit"], .ready(candidate))
    }

    func testChangedIdentityRestartsStatStability() {
        let oldIdentity = makeIdentity(1)
        let newIdentity = makeIdentity(2)
        var reducer = makeReducer(files: [
            "live_stack.fit": .digestPending(PendingDigest(
                digest: "A", identity: oldIdentity, firstObservedNanos: 10)),
        ])

        let effects = observe(
            name: "live_stack.fit",
            kind: .classicMutable,
            outcome: .digested(
                identity: newIdentity, digest: "A", byteCount: newIdentity.size),
            nowNanos: 200,
            reducer: &reducer)

        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(reducer.state.generation.files["live_stack.fit"],
                       .observing(stat: newIdentity))
    }

    func testIdentityChangeRestartsStatStabilityFromReadyAndSettled() {
        let oldIdentity = makeIdentity(1)
        let newIdentity = makeIdentity(2)
        let cases: [(String, FileState)] = [
            ("ready", .ready(makeCandidate(
                name: "live_stack.fit", identity: oldIdentity, digest: "A"))),
            ("settled", .settled(.emittedNow(identity: oldIdentity, digest: "A"))),
        ]

        for testCase in cases {
            var reducer = makeReducer(files: ["live_stack.fit": testCase.1])
            let effects = observe(
                name: "live_stack.fit",
                kind: .classicMutable,
                outcome: .digested(
                    identity: newIdentity, digest: "B", byteCount: newIdentity.size),
                nowNanos: 200,
                reducer: &reducer)

            XCTAssertTrue(effects.isEmpty, testCase.0)
            XCTAssertEqual(reducer.state.generation.files["live_stack.fit"],
                           .observing(stat: newIdentity), testCase.0)
        }
    }

    func testInvalidObservationClearsPendingEvidence() {
        let identity = makeIdentity(1)
        var reducer = makeReducer(files: [
            "live_stack.fit": .digestPending(PendingDigest(
                digest: "A", identity: identity, firstObservedNanos: 10)),
        ])

        let effects = observe(
            name: "live_stack.fit",
            kind: .classicMutable,
            outcome: .invalid(reason: "truncated"),
            nowNanos: 20,
            reducer: &reducer)

        XCTAssertTrue(effects.isEmpty)
        XCTAssertNil(reducer.state.generation.files["live_stack.fit"])
    }

    func testUnstableObservationRestartsWithLatestIdentity() {
        let oldIdentity = makeIdentity(1)
        let newIdentity = makeIdentity(2)
        var reducer = makeReducer(files: [
            "live_stack.fit": .digestPending(PendingDigest(
                digest: "A", identity: oldIdentity, firstObservedNanos: 10)),
        ])

        let effects = observe(
            name: "live_stack.fit",
            kind: .classicMutable,
            outcome: .unstable(identity: newIdentity),
            nowNanos: 20,
            reducer: &reducer)

        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(reducer.state.generation.files["live_stack.fit"],
                       .observing(stat: newIdentity))
    }

    func testImmutableEntryEmitsAfterTwoMatchingStatObservations() {
        let identity = makeIdentity(1)
        let outcome = ObservationOutcome.digested(
            identity: identity,
            digest: "A",
            byteCount: identity.size)
        var reducer = makeReducer(digestPolicy: .immutableAfterPublish)

        XCTAssertTrue(observe(
            name: "sub.fit", kind: .immutable, outcome: outcome,
            nowNanos: 10, reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.state.generation.files["sub.fit"], .observing(stat: identity))

        let candidate = makeCandidate(
            name: "sub.fit", identity: identity, digest: "A", kind: .immutable)
        XCTAssertEqual(observe(
            name: "sub.fit", kind: .immutable, outcome: outcome,
            nowNanos: 20, reducer: &reducer), [
                .emit(EmissionIntent(generation: FolderGeneration(rawValue: 1), candidate: candidate)),
            ])
        XCTAssertEqual(reducer.state.generation.files["sub.fit"], .ready(candidate))
    }

    func testStaleGenerationEmissionResultCannotSettleOrChangeDigest() {
        let identity = makeIdentity(1)
        let candidate = makeCandidate(
            name: "live_stack.fit", identity: identity, digest: "new")
        var reducer = makeReducer(
            generation: 2,
            files: ["live_stack.fit": .ready(candidate)],
            digests: ["live_stack.fit": "old"])
        let staleIntent = EmissionIntent(
            generation: FolderGeneration(rawValue: 1),
            candidate: candidate)

        let effects = reducer.reduce(.emissionFinished(EmissionResult(
            intent: staleIntent,
            outcome: .yielded)))

        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(reducer.state.generation.files["live_stack.fit"], .ready(candidate))
        XCTAssertEqual(reducer.state.lastEmittedDigestByName["live_stack.fit"], "old")
    }

    func testCurrentGenerationSuccessfulEmissionSettlesAndChangesDigest() {
        let identity = makeIdentity(1)
        let candidate = makeCandidate(
            name: "live_stack.fit", identity: identity, digest: "new")
        var reducer = makeReducer(
            files: ["live_stack.fit": .ready(candidate)],
            digests: ["live_stack.fit": "old"])
        let intent = EmissionIntent(
            generation: FolderGeneration(rawValue: 1),
            candidate: candidate)

        let effects = reducer.reduce(.emissionFinished(EmissionResult(
            intent: intent,
            outcome: .yielded)))

        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(reducer.state.generation.files["live_stack.fit"], .settled(
            .emittedNow(identity: identity, digest: "new")))
        XCTAssertEqual(reducer.state.lastEmittedDigestByName["live_stack.fit"], "new")
    }

    func testCurrentGenerationRejectedEmissionPreservesReadyStateAndDigest() {
        let identity = makeIdentity(1)
        let candidate = makeCandidate(
            name: "live_stack.fit", identity: identity, digest: "new")
        var reducer = makeReducer(
            files: ["live_stack.fit": .ready(candidate)],
            digests: ["live_stack.fit": "old"])
        let intent = EmissionIntent(
            generation: FolderGeneration(rawValue: 1),
            candidate: candidate)

        let effects = reducer.reduce(.emissionFinished(EmissionResult(
            intent: intent,
            outcome: .rejected)))

        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(reducer.state.generation.files["live_stack.fit"], .ready(candidate))
        XCTAssertEqual(reducer.state.lastEmittedDigestByName["live_stack.fit"], "old")
    }

    private func makeConfiguration(
        digestPolicy: StackFileWatcher.DigestPolicy = .mutableStackerOutput,
        filePrefix: String? = "live_stack",
        quietPeriodNanos: UInt64 = 100,
        pollIntervalNanos: UInt64 = 1_000
    ) -> WatcherReducerConfiguration {
        WatcherReducerConfiguration(
            digestPolicy: digestPolicy,
            filePrefix: filePrefix,
            quietPeriodNanos: quietPeriodNanos,
            pollIntervalNanos: pollIntervalNanos)
    }

    private func makePopulatedWatcherState(generation: UInt64) -> WatcherState {
        let identity = makeIdentity(9)
        return WatcherState(
            generation: GenerationState(
                id: FolderGeneration(rawValue: generation),
                files: [
                    "live_stack.fit": .digestPending(PendingDigest(
                        digest: "pending",
                        identity: identity,
                        firstObservedNanos: 123)),
                    "settled.fit": .settled(.emittedNow(
                        identity: identity,
                        digest: "settled")),
                ],
                ordering: RevisionOrderingState(activeBlocker: BlockingEpisode(
                    blocker: "live_stack.fit",
                    startNanos: 1_000,
                    deadlineNanos: 2_000,
                    victims: ["victim.fit"]))),
            lastEmittedDigestByName: ["settled.fit": "settled"])
    }

    private func assertWatcherState(
        _ actual: WatcherState,
        equals expected: WatcherState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.generation.id, expected.generation.id, file: file, line: line)
        XCTAssertEqual(actual.generation.files, expected.generation.files, file: file, line: line)
        XCTAssertEqual(
            actual.generation.ordering.activeBlocker,
            expected.generation.ordering.activeBlocker,
            file: file,
            line: line)
        XCTAssertEqual(
            actual.lastEmittedDigestByName,
            expected.lastEmittedDigestByName,
            file: file,
            line: line)
    }

    private func makeReducer(
        generation: UInt64 = 1,
        files: [String: FileState] = [:],
        digests: [String: String] = [:],
        activeBlocker: BlockingEpisode? = nil,
        digestPolicy: StackFileWatcher.DigestPolicy = .mutableStackerOutput,
        filePrefix: String? = "live_stack",
        quietPeriodNanos: UInt64 = 100,
        pollIntervalNanos: UInt64 = 1_000
    ) -> WatcherReducer {
        WatcherReducer(
            state: WatcherState(
                generation: GenerationState(
                    id: FolderGeneration(rawValue: generation),
                    files: files,
                    ordering: RevisionOrderingState(activeBlocker: activeBlocker)),
                lastEmittedDigestByName: digests),
            configuration: makeConfiguration(
                digestPolicy: digestPolicy,
                filePrefix: filePrefix,
                quietPeriodNanos: quietPeriodNanos,
                pollIntervalNanos: pollIntervalNanos))
    }

    private func makeIdentity(_ value: Int64) -> FileIdentity {
        FileIdentity(
            dev: value,
            ino: UInt64(value),
            size: Int(value) * 10,
            mtimeSec: value,
            mtimeNsec: value)
    }

    private func observe(
        name: String,
        kind: WatcherEntryKind,
        outcome: ObservationOutcome,
        nowNanos: UInt64,
        reducer: inout WatcherReducer
    ) -> [WatcherEffect] {
        reducer.reduce(.observe(ObservationBatch(
            generation: reducer.state.generation.id,
            entries: [FileObservation(
                name: name,
                url: URL(fileURLWithPath: "/watch/\(name)"),
                kind: kind,
                outcome: outcome)],
            nowNanos: nowNanos)))
    }

    private func observeBatch(
        _ entries: [FileObservation],
        nowNanos: UInt64,
        reducer: inout WatcherReducer
    ) -> [WatcherEffect] {
        reducer.reduce(.observe(ObservationBatch(
            generation: reducer.state.generation.id,
            entries: entries,
            nowNanos: nowNanos)))
    }

    private func observation(
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

    private func revisionName(_ revision: String) -> String {
        "live_stack_\(revision).fit"
    }

    private func invalidRevision(_ revision: String) -> FileObservation {
        observation(
            name: revisionName(revision),
            revision: revision,
            outcome: .invalid(reason: "incomplete"))
    }

    private func emittedNames(in effects: [WatcherEffect]) -> [String] {
        effects.compactMap { effect in
            guard case .emit(let intent) = effect else { return nil }
            return intent.candidate.name
        }
    }

    private func makeCandidate(
        name: String,
        identity: FileIdentity,
        digest: String,
        kind: WatcherEntryKind = .classicMutable
    ) -> EmissionCandidate {
        EmissionCandidate(
            name: name,
            url: URL(fileURLWithPath: "/watch/\(name)"),
            kind: kind,
            identity: identity,
            digest: digest,
            byteCount: identity.size)
    }
}
