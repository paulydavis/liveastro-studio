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
            observation(name: one, revision: "00001", outcome: .invalid),
            observation(name: two, revision: "00002", outcome: .digested(
                identity: twoIdentity, digest: "changed-two", byteCount: twoIdentity.size)),
            observation(name: three, revision: "00003", outcome: .digested(
                identity: threeIdentity, digest: "three", byteCount: threeIdentity.size)),
        ], nowNanos: 10, reducer: &reducer)

        XCTAssertTrue(firstPass.isEmpty)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.blocker, one)
        XCTAssertEqual(
            reducer.state.generation.ordering.victimLedgers[two]?
                .segments[RevisionKey("1")]?.firstChargeNanos,
            10)
        XCTAssertEqual(
            reducer.state.generation.ordering.victimLedgers[three]?
                .segments[RevisionKey("1")]?.firstChargeNanos,
            10)

        XCTAssertTrue(observeBatch([
            observation(name: one, revision: "00001", outcome: .invalid),
            observation(name: two, revision: "00002", outcome: .digested(
                identity: twoIdentity, digest: "changed-two", byteCount: twoIdentity.size)),
            observation(name: three, revision: "00003", outcome: .digested(
                identity: threeIdentity, digest: "three", byteCount: threeIdentity.size)),
        ], nowNanos: 20, reducer: &reducer).isEmpty)
        let heldEffects = observeBatch([
            observation(name: one, revision: "00001", outcome: .invalid),
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
            observation(name: one, revision: "00001", outcome: .invalid),
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

    func testEqualNumericPaddingChurnDoesNotResetBlockingEpisodeClock() {
        let rawBlocker = "live_stack_7.fit"
        let paddedBlocker = "live_stack_007.fit"
        let victim = "live_stack_8.fit"
        let victimIdentity = makeIdentity(8)
        var reducer = makeReducer(files: [
            victim: .ready(makeCandidate(
                name: victim,
                identity: victimIdentity,
                digest: "victim",
                kind: .numbered(revision: "8"))),
        ])

        XCTAssertTrue(observeBatch([
            observation(name: rawBlocker, revision: "7", outcome: .invalid),
            observation(name: victim, revision: "8", outcome: .identityUnchanged(
                identity: victimIdentity)),
        ], nowNanos: 10, reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.blocker, rawBlocker)
        XCTAssertEqual(
            reducer.state.generation.ordering.victimLedgers[victim]?
                .segments[RevisionKey("7")]?.firstChargeNanos,
            10)

        let released = observeBatch([
            observation(name: rawBlocker, revision: "7", outcome: .absent),
            observation(name: paddedBlocker, revision: "007", outcome: .invalid),
            observation(name: victim, revision: "8", outcome: .identityUnchanged(
                identity: victimIdentity)),
        ], nowNanos: 30_000_000_010, reducer: &reducer)

        XCTAssertEqual(emittedNames(in: released), [victim],
                       "same numeric blocker with different zero padding must spend the original episode budget")
        XCTAssertEqual(reducer.state.generation.files[paddedBlocker], .writtenOff)
        XCTAssertNil(reducer.state.generation.ordering.activeBlocker)
    }

    func testDigestQuietPeriodUsesPerFileReadTimestampNotBatchEnd() {
        let name = "live_stack.fit"
        let identity = makeIdentity(42)
        var reducer = makeReducer(
            files: [name: .digestPending(PendingDigest(
                digest: "A",
                identity: identity,
                firstObservedNanos: 0))],
            quietPeriodNanos: 100)

        let tooEarly = observeBatch([
            FileObservation(
                name: name,
                url: URL(fileURLWithPath: "/watch/\(name)"),
                kind: .classicMutable,
                outcome: .digested(identity: identity, digest: "A", byteCount: identity.size),
                observedAtNanos: 50),
        ], nowNanos: 100, reducer: &reducer)

        XCTAssertTrue(tooEarly.isEmpty,
                      "a slow scan ending after the quiet period must not emit a file read before the quiet period elapsed")

        let emitted = observeBatch([
            FileObservation(
                name: name,
                url: URL(fileURLWithPath: "/watch/\(name)"),
                kind: .classicMutable,
                outcome: .digested(identity: identity, digest: "A", byteCount: identity.size),
                observedAtNanos: 100),
        ], nowNanos: 150, reducer: &reducer)
        XCTAssertEqual(emittedNames(in: emitted), [name])
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
                        owner: RevisionKey("2"),
                        victims: [revisionName("00003")]))

        XCTAssertTrue(observeBatch([
            invalidRevision("00001"),
            invalidRevision("00002"),
            invalidRevision("00003"),
        ], nowNanos: 200, reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.blocker,
                       revisionName("00001"))
        XCTAssertEqual(
            reducer.state.generation.ordering.victimLedgers[revisionName("00003")]?
                .segments[RevisionKey("2")]?.firstChargeNanos,
            100,
            "00003 has been continuously blocked since the first episode; victim clocks survive blocker role changes.")

        XCTAssertTrue(observeBatch([
            observation(name: revisionName("00001"), revision: "00001", outcome: .absent),
            invalidRevision("00002"),
            invalidRevision("00003"),
        ], nowNanos: 300, reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker,
                       BlockingEpisode(
                        blocker: revisionName("00002"),
                        owner: RevisionKey("2"),
                        victims: [revisionName("00003")]),
                       "the victim's starvation clock, not the blocker role, defines the episode age")
        XCTAssertEqual(
            reducer.state.generation.ordering.victimLedgers[revisionName("00003")]?
                .segments[RevisionKey("2")]?.firstChargeNanos,
            100)
        XCTAssertEqual(
            reducer.state.generation.ordering.victimLedgers[revisionName("00003")]?
                .segments[RevisionKey("2")]?.accruedNanos,
            100,
            "segment 2 accrued 100ns across the pass-2 role swap, then resumed")
    }

    func testAggregateBlockerChurnDoesNotStarveContinuouslyHeldVictim() {
        let firstBlocker = revisionName("00001")
        let secondBlocker = revisionName("00002")
        let victim = revisionName("00003")
        let victimIdentity = makeIdentity(3)
        var reducer = makeReducer(files: [
            victim: .ready(makeCandidate(
                name: victim,
                identity: victimIdentity,
                digest: "victim",
                kind: .numbered(revision: "00003"))),
        ])

        XCTAssertTrue(observeBatch([
            invalidRevision("00001"),
            observation(name: secondBlocker, revision: "00002", outcome: .absent),
            observation(name: victim, revision: "00003", outcome: .identityUnchanged(
                identity: victimIdentity)),
        ], nowNanos: 10, reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.blocker, firstBlocker)
        XCTAssertEqual(
            reducer.state.generation.ordering.victimLedgers[victim]?
                .segments[RevisionKey("1")]?.firstChargeNanos,
            10)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.victims, [victim])

        XCTAssertTrue(observeBatch([
            observation(name: firstBlocker, revision: "00001", outcome: .absent),
            invalidRevision("00002"),
            observation(name: victim, revision: "00003", outcome: .identityUnchanged(
                identity: victimIdentity)),
        ], nowNanos: 20, reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.blocker, secondBlocker)
        XCTAssertEqual(
            reducer.state.generation.ordering.victimLedgers[victim]?
                .segments[RevisionKey("2")]?.firstChargeNanos,
            20,
            "the continuously held victim owns the aggregate starvation clock")

        let released = observeBatch([
            invalidRevision("00001"),
            observation(name: secondBlocker, revision: "00002", outcome: .absent),
            observation(name: victim, revision: "00003", outcome: .identityUnchanged(
                identity: victimIdentity)),
        ], nowNanos: 30_000_000_010, reducer: &reducer)

        XCTAssertEqual(emittedNames(in: released), [victim])
        XCTAssertEqual(reducer.state.generation.files[firstBlocker], .writtenOff)
        XCTAssertNil(reducer.state.generation.ordering.activeBlocker)
    }

    func testDisjointBlockerHandoffDoesNotStarveContinuouslyHeldVictim() {
        let victim = revisionName("00004")
        let victimIdentity = makeIdentity(4)
        var reducer = makeReducer(files: [
            victim: .ready(makeCandidate(
                name: victim,
                identity: victimIdentity,
                digest: "victim",
                kind: .numbered(revision: "00004"))),
        ])

        for step in 0..<8 {
            let blockerRevision = String(format: "%05d", step.isMultiple(of: 2) ? 1 : 2)
            let otherRevision = String(format: "%05d", step.isMultiple(of: 2) ? 2 : 1)
            let now = UInt64(step + 1) * 5_000_000_000
            let effects = observeBatch([
                invalidRevision(blockerRevision),
                observation(name: revisionName(otherRevision), revision: otherRevision, outcome: .absent),
                observation(name: victim, revision: "00004", outcome: .identityUnchanged(
                    identity: victimIdentity)),
            ], nowNanos: now, reducer: &reducer)

            if now < 30_000_000_000 {
                XCTAssertTrue(effects.isEmpty)
            }
        }

        XCTAssertTrue(
            reducer.state.generation.files[revisionName("00001")] == .writtenOff
                || reducer.state.generation.files[revisionName("00002")] == .writtenOff,
            "At least one blocker must be written off; alternating names cannot hold \(victim) forever.")
    }

    func testRoleSwapDoesNotStarveContinuouslyBlockedVictims() {
        var reducer = makeReducer()

        for step in 0..<14 {
            let first: [FileObservation]
            if step.isMultiple(of: 2) {
                first = [
                    invalidRevision("00001"),
                    invalidRevision("00002"),
                    observation(name: revisionName("00003"), revision: "00003", outcome: .absent),
                ]
            } else {
                first = [
                    observation(name: revisionName("00001"), revision: "00001", outcome: .absent),
                    invalidRevision("00002"),
                    invalidRevision("00003"),
                ]
            }
            _ = observeBatch(first, nowNanos: UInt64(step + 1) * 5_000_000_000, reducer: &reducer)
        }

        XCTAssertTrue(
            reducer.state.generation.files[revisionName("00001")] == .writtenOff
                || reducer.state.generation.files[revisionName("00002")] == .writtenOff,
            "Alternating blocker/victim roles must not reset every starvation clock forever.")
    }

    func testVictimDisappearancePausesClockAndReappearanceResumes() {
        var reducer = makeReducer()

        XCTAssertTrue(observeBatch([
            invalidRevision("00001"),
            invalidRevision("00002"),
        ], nowNanos: 10, reducer: &reducer).isEmpty)
        XCTAssertEqual(
            reducer.state.generation.ordering.victimLedgers[revisionName("00002")]?
                .segments[RevisionKey("1")]?.firstChargeNanos,
            10)

        XCTAssertTrue(observeBatch([
            invalidRevision("00001"),
            observation(name: revisionName("00002"), revision: "00002", outcome: .absent),
        ], nowNanos: 10_000_000_000, reducer: &reducer).isEmpty)
        XCTAssertNil(reducer.state.generation.ordering.activeBlocker)

        XCTAssertTrue(observeBatch([
            invalidRevision("00001"),
            invalidRevision("00002"),
        ], nowNanos: 100_000_000_000, reducer: &reducer).isEmpty)
        XCTAssertEqual(
            reducer.state.generation.ordering.victimLedgers[revisionName("00002")]?
                .segments[RevisionKey("1")]?.accruedNanos,
            9_999_999_990,
            "the victim's clock should pause while absent, not restart or age through the gap")

        let released = observeBatch([
            invalidRevision("00001"),
            invalidRevision("00002"),
        ], nowNanos: 120_000_000_011, reducer: &reducer)

        XCTAssertEqual(reducer.state.generation.files[revisionName("00001")], .writtenOff)
        XCTAssertFalse(released.isEmpty,
                       "the resumed victim clock must eventually write off the blocker instead of starving forever")
    }

    func testVictimClockClearedWhenNoLongerBehindLiveBlocker() {
        let blocker = revisionName("00001")
        let victim = revisionName("00002")
        let victimIdentity = makeIdentity(2)
        var reducer = makeReducer(files: [
            victim: .ready(makeCandidate(
                name: victim,
                identity: victimIdentity,
                digest: "victim",
                kind: .numbered(revision: "00002"))),
        ])

        XCTAssertTrue(observeBatch([
            invalidRevision("00001"),
            observation(name: victim, revision: "00002", outcome: .identityUnchanged(
                identity: victimIdentity)),
        ], nowNanos: 10, reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.victims, [victim])

        XCTAssertEqual(emittedNames(in: observeBatch([
            observation(name: blocker, revision: "00001", outcome: .absent),
            observation(name: victim, revision: "00002", outcome: .identityUnchanged(
                identity: victimIdentity)),
        ], nowNanos: 40_000_000_000, reducer: &reducer)), [victim])
        XCTAssertNil(reducer.state.generation.ordering.activeBlocker)
        XCTAssertNil(reducer.state.generation.ordering.victimLedgers[victim],
                     "once the blocker is gone, the old victim clock cannot shorten a future episode")

        let freshEffects = observeBatch([
            invalidRevision("00001"),
            observation(name: victim, revision: "00002", outcome: .identityUnchanged(
                identity: victimIdentity)),
        ], nowNanos: 42_000_000_000, reducer: &reducer)

        XCTAssertTrue(freshEffects.isEmpty,
                      "a genuinely fresh blocker must receive a fresh budget, not inherit the stale victim clock")
        XCTAssertEqual(reducer.state.generation.files[blocker], nil)
        XCTAssertEqual(
            reducer.state.generation.ordering.victimLedgers[victim]?
                .segments[RevisionKey("1")]?.firstChargeNanos,
            42_000_000_000)
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
        XCTAssertEqual(
            reducer.state.generation.ordering.victimLedgers[revisionName("00002")]?
                .segments[RevisionKey("1")]?.firstChargeNanos,
            10)
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
                    ordering: RevisionOrderingState(
                        activeBlocker: BlockingEpisode(
                            blocker: blocker,
                            owner: RevisionKey("1"),
                            victims: [revisionName("00002")]),
                        victimLedgers: [
                            revisionName("00002"): VictimWaitLedger(
                                segments: [
                                    RevisionKey("1"): AccrualSegment(
                                        owner: RevisionKey("1"),
                                        firstChargeNanos: 0,
                                        accruedNanos: 0,
                                        runningSinceNanos: 0)
                                ])
                        ])),
                lastEmittedDigestByName: [:]),
            configuration: configuration)

        XCTAssertTrue(observeBatch([
            observation(name: blocker, revision: "00001", outcome: .digested(
                identity: identity, digest: "stable", byteCount: identity.size)),
            invalidRevision("00002"),
        ], nowNanos: ceiling - 2, reducer: &reducer).isEmpty,
                      "renewed grace holds — no write-off before the owner-anchored ceiling")
        XCTAssertEqual(
            reducer.state.generation.ordering.ownerGraceUntil[RevisionKey("1")],
            ceiling - 2 + configuration.quietPeriodNanos,
            "a converging sighting renews the current owner's grace by one quiet period")

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
        XCTAssertEqual(reducer.derivedRevisionHighWater, nil,
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
        XCTAssertEqual(reducer.derivedRevisionHighWater, "007",
                       "the raw-digit-first revision remains the derived tie survivor")
    }

    func testNestedReplacementRejectedAfterEarlierEqualRevisionSettles() {
        let firstName = "live_stack_007.fit"
        let replacementName = "live_stack_07.fit"
        let firstCandidate = makeCandidate(
            name: firstName,
            identity: makeIdentity(7),
            digest: "first-seven",
            kind: .numbered(revision: "007"))
        let replacementCandidate = makeCandidate(
            name: replacementName,
            identity: makeIdentity(70),
            digest: "replacement-seven",
            kind: .numbered(revision: "07"))
        let firstIntent = EmissionIntent(
            generation: FolderGeneration(rawValue: 1),
            candidate: firstCandidate)
        let replacementIntent = EmissionIntent(
            generation: FolderGeneration(rawValue: 1),
            candidate: replacementCandidate)
        var reducer = makeReducer(files: [
            firstName: .ready(firstCandidate),
            replacementName: .settled(.duplicateOfLastEmission(
                identity: makeIdentity(700),
                digest: "old-seven",
                replacement: .ready(replacementCandidate))),
        ])

        XCTAssertNil(reducer.derivedRevisionHighWater)
        XCTAssertEqual(observeBatch([
            observation(
                name: replacementName,
                revision: "07",
                outcome: .identityUnchanged(identity: replacementCandidate.identity)),
            observation(
                name: firstName,
                revision: "007",
                outcome: .identityUnchanged(identity: firstCandidate.identity)),
        ], nowNanos: 10, reducer: &reducer), [
            .emit(firstIntent),
            .emit(replacementIntent),
        ])

        XCTAssertTrue(reducer.shouldExecuteEmission(firstIntent))
        XCTAssertTrue(reducer.reduce(.emissionFinished(EmissionResult(
            intent: firstIntent,
            outcome: .yielded))).isEmpty)
        XCTAssertEqual(reducer.derivedRevisionHighWater, "007")
        XCTAssertFalse(reducer.shouldExecuteEmission(replacementIntent))

        XCTAssertEqual(reducer.reduce(.emissionFinished(EmissionResult(
            intent: replacementIntent,
            outcome: .rejected))), [
                .log("revision 07 arrived out of order — skipped (high-water 007)"),
            ])
        let ignoredReplacement = FileState.settled(.duplicateOfLastEmission(
            identity: makeIdentity(700),
            digest: "old-seven",
            replacement: .ignoredOutOfOrder(identity: replacementCandidate.identity)))
        XCTAssertEqual(reducer.state.generation.files[replacementName], ignoredReplacement)
        XCTAssertTrue(reducer.reduce(.emissionFinished(EmissionResult(
            intent: replacementIntent,
            outcome: .rejected))).isEmpty)
        XCTAssertEqual(reducer.state.generation.files[replacementName], ignoredReplacement)
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
        XCTAssertEqual(reducer.derivedRevisionHighWater, "00003")

        XCTAssertTrue(observeBatch(batch, nowNanos: 20, reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.derivedRevisionHighWater, "00003")
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

        XCTAssertNil(reducer.derivedRevisionHighWater)
        XCTAssertTrue(reducer.reduce(.emissionFinished(EmissionResult(
            intent: intent,
            outcome: .rejected))).isEmpty)
        XCTAssertNil(reducer.derivedRevisionHighWater)

        XCTAssertTrue(reducer.reduce(.emissionFinished(EmissionResult(
            intent: intent,
            outcome: .yielded))).isEmpty)
        XCTAssertEqual(reducer.derivedRevisionHighWater, "00007")
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
        XCTAssertNil(reducer.derivedRevisionHighWater,
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
                        owner: RevisionKey("1"),
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
        XCTAssertEqual(
            reducer.state.generation.ordering.victimLedgers[revisionName("00004")]?
                .segments[RevisionKey("3")]?.firstChargeNanos,
            30,
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
        XCTAssertEqual(episodeBeforeEmission?.victims, [victim])
        XCTAssertEqual(
            reducer.state.generation.ordering.victimLedgers[victim]?
                .segments[RevisionKey("1")]?.firstChargeNanos,
            100)

        XCTAssertTrue(reducer.reduce(.emissionFinished(EmissionResult(
            intent: classicIntent,
            outcome: .yielded))).isEmpty)

        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker,
                       episodeBeforeEmission,
                       "unrelated classic completion cannot erase invalid victim \(victim)")
        XCTAssertEqual(
            reducer.state.generation.ordering.victimLedgers[victim]?
                .segments[RevisionKey("1")]?.firstChargeNanos,
            100)
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
        XCTAssertEqual(
            reducer.state.generation.ordering.victimLedgers[remainingVictim]?
                .segments[RevisionKey("1")]?.firstChargeNanos,
            100)
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
        XCTAssertEqual(
            reducer.state.generation.ordering.victimLedgers[remainingVictim]?
                .segments[RevisionKey("1")]?.firstChargeNanos,
            100)
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
                owner: RevisionKey("1"),
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
            "settled.fit": .settled(.emittedNow(
                identity: identity,
                digest: "settled",
                replacement: .observing(stat: makeIdentity(2)))),
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
                        blocker: revisionName("00001"),
                        owner: RevisionKey("1"),
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

    func testGenerationChangeClearsVictimLedgersButKeepsDigestDedup() {
        let victim = revisionName("00002")
        var reducer = makeReducer(
            files: [
                revisionName("00001"): .writtenOff,
                victim: .ready(makeCandidate(
                    name: victim,
                    identity: makeIdentity(2),
                    digest: "victim",
                    kind: .numbered(revision: "00002")))
            ],
            digests: [victim: "victim"],
            victimLedgers: [
                victim: VictimWaitLedger(
                    segments: [
                        RevisionKey("1"): AccrualSegment(
                            owner: RevisionKey("1"),
                            firstChargeNanos: 10,
                            accruedNanos: 20,
                            runningSinceNanos: nil)
                    ],
                    pausedAtNanos: 30)
            ])

        let effects = reducer.reduce(.replaceGeneration(FolderGeneration(rawValue: 2)))

        XCTAssertTrue(effects.isEmpty)
        XCTAssertTrue(reducer.state.generation.ordering.victimLedgers.isEmpty)
        XCTAssertEqual(reducer.state.lastEmittedDigestByName[victim], "victim")
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
        XCTAssertEqual(reducer.derivedRevisionHighWater, "10")
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

    func testReadPlanFirstSightingReturnsNoContentObservationForEveryEntryKind() {
        struct TestCase {
            let label: String
            let reducer: WatcherReducer
            let name: String
            let kind: WatcherEntryKind
        }
        let identity = makeIdentity(1)
        let cases = [
            TestCase(
                label: "classic mutable",
                reducer: makeReducer(filePrefix: nil),
                name: "live_stack.fit",
                kind: .classicMutable),
            TestCase(
                label: "numbered mutable",
                reducer: makeReducer(filePrefix: "live_stack"),
                name: "live_stack_00001.fit",
                kind: .numbered(revision: "00001")),
            TestCase(
                label: "immutable",
                reducer: makeReducer(
                    digestPolicy: .immutableAfterPublish,
                    filePrefix: nil),
                name: "sub.fit",
                kind: .immutable),
        ]

        for testCase in cases {
            let url = URL(fileURLWithPath: "/watch/\(testCase.name)")
            XCTAssertEqual(testCase.reducer.readPlan(for: [EnumeratedEntry(
                name: testCase.name,
                url: url,
                identity: identity,
                isFITS: true)]), [
                    .observeWithoutContent(FileObservation(
                        name: testCase.name,
                        url: url,
                        kind: testCase.kind,
                        outcome: .unstable(identity: identity))),
                ], testCase.label)
        }
    }

    func testReadPlanChangedIdentityReturnsNoContentObservationAcrossEveryFileState() {
        let name = "live_stack.fit"
        let url = URL(fileURLWithPath: "/watch/\(name)")
        let oldIdentity = makeIdentity(1)
        let currentIdentity = makeIdentity(2)
        let cases: [(label: String, state: FileState)] = [
            ("observing", .observing(stat: oldIdentity)),
            ("digest pending", .digestPending(PendingDigest(
                digest: "old", identity: oldIdentity, firstObservedNanos: 10))),
            ("ready", .ready(makeCandidate(
                name: name, identity: oldIdentity, digest: "old"))),
            ("emitted settlement", .settled(.emittedNow(
                identity: oldIdentity, digest: "old"))),
            ("duplicate settlement", .settled(.duplicateOfLastEmission(
                identity: oldIdentity, digest: "old"))),
            ("dropped", .droppedOutOfOrder),
            ("written off", .writtenOff),
        ]

        for testCase in cases {
            let reducer = makeReducer(files: [name: testCase.state], filePrefix: nil)
            XCTAssertEqual(reducer.readPlan(for: [EnumeratedEntry(
                name: name,
                url: url,
                identity: currentIdentity,
                isFITS: true)]), [
                    .observeWithoutContent(FileObservation(
                        name: name,
                        url: url,
                        kind: .classicMutable,
                        outcome: .unstable(identity: currentIdentity))),
                ], testCase.label)
        }
    }

    func testReadPlanMatchingEvidenceAllowsContentAndPreservesSettledFastPaths() {
        let name = "live_stack.fit"
        let url = URL(fileURLWithPath: "/watch/\(name)")
        let identity = makeIdentity(1)
        let contentStates: [(label: String, state: FileState)] = [
            ("observing", .observing(stat: identity)),
            ("digest pending", .digestPending(PendingDigest(
                digest: "pending", identity: identity, firstObservedNanos: 10))),
            ("ready", .ready(makeCandidate(
                name: name, identity: identity, digest: "ready"))),
            ("emitted settlement", .settled(.emittedNow(
                identity: identity, digest: "emitted"))),
            ("duplicate settlement", .settled(.duplicateOfLastEmission(
                identity: identity, digest: "duplicate"))),
        ]

        for testCase in contentStates {
            let reducer = makeReducer(files: [name: testCase.state], filePrefix: nil)
            XCTAssertEqual(reducer.readPlan(for: [EnumeratedEntry(
                name: name,
                url: url,
                identity: identity,
                isFITS: true)]), [
                    .readContent(
                        name: name,
                        url: url,
                        kind: .classicMutable,
                        identity: identity,
                        isFITS: true),
                ], testCase.label)
        }

        let numberedName = "live_stack_00001.fit"
        let numberedURL = URL(fileURLWithPath: "/watch/\(numberedName)")
        let immutableName = "sub.fit"
        let immutableURL = URL(fileURLWithPath: "/watch/\(immutableName)")
        let reducer = makeReducer(
            files: [
                numberedName: .settled(.emittedNow(
                    identity: identity, digest: "numbered")),
                immutableName: .settled(.duplicateOfLastEmission(
                    identity: identity, digest: "immutable")),
            ],
            digestPolicy: .immutableAfterPublish)

        XCTAssertEqual(reducer.readPlan(for: [
            EnumeratedEntry(
                name: numberedName,
                url: numberedURL,
                identity: identity,
                isFITS: true),
            EnumeratedEntry(
                name: immutableName,
                url: immutableURL,
                identity: identity,
                isFITS: true),
        ]), [
            .acceptIdentity(FileObservation(
                name: numberedName,
                url: numberedURL,
                kind: .numbered(revision: "00001"),
                outcome: .identityUnchanged(identity: identity))),
            .acceptIdentity(FileObservation(
                name: immutableName,
                url: immutableURL,
                kind: .immutable,
                outcome: .identityUnchanged(identity: identity))),
        ])
    }

    func testSettledNumberedReplacementReearnsStatStabilityWithoutRegressingHighWater() {
        let name = "live_stack_00007.fit"
        let url = URL(fileURLWithPath: "/watch/\(name)")
        let oldIdentity = makeIdentity(1)
        let replacementIdentity = makeIdentity(2)
        var reducer = makeReducer(
            files: [
                name: .settled(.emittedNow(
                    identity: oldIdentity,
                    digest: "old")),
            ],
            digests: [name: "old"])
        let replacementEntry = EnumeratedEntry(
            name: name,
            url: url,
            identity: replacementIdentity,
            isFITS: true)

        XCTAssertEqual(reducer.derivedRevisionHighWater, "00007")
        let firstPlan = reducer.readPlan(for: [replacementEntry])
        XCTAssertEqual(firstPlan, [
            .observeWithoutContent(FileObservation(
                name: name,
                url: url,
                kind: .numbered(revision: "00007"),
                outcome: .unstable(identity: replacementIdentity))),
        ])
        guard case .observeWithoutContent(let observation) = firstPlan[0] else {
            return XCTFail("first replacement sighting must not request content")
        }

        XCTAssertTrue(reducer.reduce(.observe(ObservationBatch(
            generation: reducer.state.generation.id,
            entries: [observation],
            nowNanos: 10))).isEmpty)
        XCTAssertEqual(reducer.state.generation.files[name], .settled(.emittedNow(
            identity: oldIdentity,
            digest: "old",
            replacement: .observing(stat: replacementIdentity))))
        XCTAssertEqual(reducer.derivedRevisionHighWater, "00007")

        XCTAssertEqual(reducer.readPlan(for: [replacementEntry]), [
            .readContent(
                name: name,
                url: url,
                kind: .numbered(revision: "00007"),
                identity: replacementIdentity,
                isFITS: true),
        ])
        XCTAssertEqual(reducer.derivedRevisionHighWater, "00007")
    }

    func testSettledNumberedReplacementChangedDigestPassesGateAndYieldsAsNewEmission() {
        let name = "live_stack_00007.fit"
        let oldIdentity = makeIdentity(1)
        let replacementIdentity = makeIdentity(2)
        let candidate = makeCandidate(
            name: name,
            identity: replacementIdentity,
            digest: "new",
            kind: .numbered(revision: "00007"))
        var reducer = makeReducer(
            files: [
                name: .settled(.emittedNow(
                    identity: oldIdentity,
                    digest: "old",
                    replacement: .observing(stat: replacementIdentity))),
            ],
            digests: [name: "old"],
            quietPeriodNanos: 100)

        XCTAssertTrue(observe(
            name: name,
            kind: .numbered(revision: "00007"),
            outcome: .digested(
                identity: replacementIdentity,
                digest: "new",
                byteCount: replacementIdentity.size),
            nowNanos: 10,
            reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.state.generation.files[name], .settled(.emittedNow(
            identity: oldIdentity,
            digest: "old",
            replacement: .digestPending(PendingDigest(
                digest: "new",
                identity: replacementIdentity,
                firstObservedNanos: 10)))))
        XCTAssertEqual(reducer.derivedRevisionHighWater, "00007")

        let intent = EmissionIntent(
            generation: reducer.state.generation.id,
            candidate: candidate)
        XCTAssertEqual(observe(
            name: name,
            kind: .numbered(revision: "00007"),
            outcome: .digested(
                identity: replacementIdentity,
                digest: "new",
                byteCount: replacementIdentity.size),
            nowNanos: 110,
            reducer: &reducer), [
                .emit(intent),
            ])
        XCTAssertEqual(reducer.state.generation.files[name], .settled(.emittedNow(
            identity: oldIdentity,
            digest: "old",
            replacement: .ready(candidate))))
        XCTAssertEqual(reducer.derivedRevisionHighWater, "00007")
        XCTAssertTrue(reducer.shouldExecuteEmission(intent))

        XCTAssertTrue(reducer.reduce(.emissionFinished(EmissionResult(
            intent: intent,
            outcome: .yielded))).isEmpty)
        XCTAssertEqual(reducer.state.generation.files[name], .settled(.emittedNow(
            identity: replacementIdentity,
            digest: "new")))
        XCTAssertEqual(reducer.state.lastEmittedDigestByName[name], "new")
        XCTAssertEqual(reducer.derivedRevisionHighWater, "00007")
    }

    func testSettledReplacementBelowHigherMarkIsRejectedOnceWithoutEmission() {
        let replacementName = "live_stack_7.fit"
        let higherName = "live_stack_8.fit"
        let settledIdentity = makeIdentity(7)
        let replacementIdentity = makeIdentity(70)
        let candidate = makeCandidate(
            name: replacementName,
            identity: replacementIdentity,
            digest: "replacement-seven",
            kind: .numbered(revision: "7"))
        let intent = EmissionIntent(
            generation: FolderGeneration(rawValue: 1),
            candidate: candidate)
        let replacementURL = URL(fileURLWithPath: "/watch/\(replacementName)")
        let unchangedReplacement = FileObservation(
            name: replacementName,
            url: replacementURL,
            kind: .numbered(revision: "7"),
            outcome: .identityUnchanged(identity: replacementIdentity))
        let unchangedHigher = FileObservation(
            name: higherName,
            url: URL(fileURLWithPath: "/watch/\(higherName)"),
            kind: .numbered(revision: "8"),
            outcome: .identityUnchanged(identity: makeIdentity(8)))
        var reducer = makeReducer(files: [
            replacementName: .settled(.emittedNow(
                identity: settledIdentity,
                digest: "seven",
                replacement: .ready(candidate))),
            higherName: .settled(.emittedNow(
                identity: makeIdentity(8),
                digest: "eight")),
        ])

        XCTAssertEqual(reducer.derivedRevisionHighWater, "8")
        XCTAssertEqual(reducer.reduce(.observe(ObservationBatch(
            generation: reducer.state.generation.id,
            entries: [unchangedReplacement, unchangedHigher],
            nowNanos: 10))), [
                .log("revision 7 arrived out of order — skipped (high-water 8)"),
            ])
        XCTAssertFalse(reducer.shouldExecuteEmission(intent))
        let ignoredReplacement = FileState.settled(.emittedNow(
            identity: settledIdentity,
            digest: "seven",
            replacement: .ignoredOutOfOrder(identity: replacementIdentity)))
        XCTAssertEqual(reducer.state.generation.files[replacementName], ignoredReplacement)
        XCTAssertEqual(reducer.derivedRevisionHighWater, "8")
        XCTAssertEqual(reducer.readPlan(for: [EnumeratedEntry(
            name: replacementName,
            url: replacementURL,
            identity: replacementIdentity,
            isFITS: true)]), [
                .acceptIdentity(unchangedReplacement),
            ])
        XCTAssertTrue(reducer.reduce(.observe(ObservationBatch(
            generation: reducer.state.generation.id,
            entries: [unchangedReplacement, unchangedHigher],
            nowNanos: 20))).isEmpty)
        XCTAssertEqual(reducer.state.generation.files[replacementName], ignoredReplacement)
    }

    func testDuplicateSettlementReplacementBehindBlockerIsHeldWithoutEmission() {
        let blockerName = "live_stack_1.fit"
        let replacementName = "live_stack_2.fit"
        let laterName = "live_stack_3.fit"
        let replacementIdentity = makeIdentity(2)
        let candidate = makeCandidate(
            name: replacementName,
            identity: replacementIdentity,
            digest: "replacement-two",
            kind: .numbered(revision: "2"))
        let intent = EmissionIntent(
            generation: FolderGeneration(rawValue: 1),
            candidate: candidate)
        let readyDuplicate = FileState.settled(.duplicateOfLastEmission(
            identity: makeIdentity(20),
            digest: "two",
            replacement: .ready(candidate)))
        var reducer = makeReducer(files: [replacementName: readyDuplicate])

        let effects = reducer.reduce(.observe(ObservationBatch(
            generation: reducer.state.generation.id,
            entries: [
                FileObservation(
                    name: blockerName,
                    url: URL(fileURLWithPath: "/watch/\(blockerName)"),
                    kind: .numbered(revision: "1"),
                    outcome: .invalid),
                FileObservation(
                    name: replacementName,
                    url: URL(fileURLWithPath: "/watch/\(replacementName)"),
                    kind: .numbered(revision: "2"),
                    outcome: .identityUnchanged(identity: replacementIdentity)),
                FileObservation(
                    name: laterName,
                    url: URL(fileURLWithPath: "/watch/\(laterName)"),
                    kind: .numbered(revision: "3"),
                    outcome: .invalid),
            ],
            nowNanos: 10)))

        XCTAssertTrue(effects.isEmpty)
        XCTAssertFalse(reducer.shouldExecuteEmission(intent))
        XCTAssertEqual(reducer.state.generation.files[replacementName], readyDuplicate)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.blocker, blockerName)
        XCTAssertEqual(
            reducer.state.generation.ordering.activeBlocker?.victims,
            Set([replacementName, laterName]))
    }

    func testImmutableSettledReplacementChangedDigestBecomesReadyWithoutDigestDelay() {
        let name = "sub.fit"
        let oldIdentity = makeIdentity(1)
        let replacementIdentity = makeIdentity(2)
        let candidate = makeCandidate(
            name: name,
            identity: replacementIdentity,
            digest: "new",
            kind: .immutable)
        var reducer = makeReducer(
            files: [
                name: .settled(.emittedNow(
                    identity: oldIdentity,
                    digest: "old",
                    replacement: .observing(stat: replacementIdentity))),
            ],
            digests: [name: "old"],
            digestPolicy: .immutableAfterPublish,
            filePrefix: nil)
        let intent = EmissionIntent(
            generation: reducer.state.generation.id,
            candidate: candidate)

        XCTAssertEqual(observe(
            name: name,
            kind: .immutable,
            outcome: .digested(
                identity: replacementIdentity,
                digest: "new",
                byteCount: replacementIdentity.size),
            nowNanos: 10,
            reducer: &reducer), [.emit(intent)])
        XCTAssertEqual(reducer.state.generation.files[name], .settled(.emittedNow(
            identity: oldIdentity,
            digest: "old",
            replacement: .ready(candidate))))
        XCTAssertTrue(reducer.shouldExecuteEmission(intent))
    }

    func testSettledNumberedReplacementIdenticalDigestRefreshesIdentityWithoutEmission() {
        let name = "live_stack_00007.fit"
        let url = URL(fileURLWithPath: "/watch/\(name)")
        let oldIdentity = makeIdentity(1)
        let replacementIdentity = makeIdentity(2)
        var reducer = makeReducer(
            files: [
                name: .settled(.emittedNow(
                    identity: oldIdentity,
                    digest: "same",
                    replacement: .observing(stat: replacementIdentity))),
            ],
            digests: [name: "same"])

        XCTAssertTrue(observe(
            name: name,
            kind: .numbered(revision: "00007"),
            outcome: .digested(
                identity: replacementIdentity,
                digest: "same",
                byteCount: replacementIdentity.size),
            nowNanos: 10,
            reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.state.generation.files[name], .settled(.emittedNow(
            identity: replacementIdentity,
            digest: "same")))
        XCTAssertEqual(reducer.state.lastEmittedDigestByName[name], "same")
        XCTAssertEqual(reducer.derivedRevisionHighWater, "00007")
        XCTAssertEqual(reducer.readPlan(for: [EnumeratedEntry(
            name: name,
            url: url,
            identity: replacementIdentity,
            isFITS: true)]), [
                .acceptIdentity(FileObservation(
                    name: name,
                    url: url,
                    kind: .numbered(revision: "00007"),
                    outcome: .identityUnchanged(identity: replacementIdentity))),
        ])
    }

    func testSettledReplacementAbsenceClearsOnlyNestedProgressAndPreservesHighWater() {
        let name = "live_stack_00007.fit"
        let oldIdentity = makeIdentity(1)
        let replacementIdentity = makeIdentity(2)
        var reducer = makeReducer(
            files: [
                name: .settled(.emittedNow(
                    identity: oldIdentity,
                    digest: "old",
                    replacement: .digestPending(PendingDigest(
                        digest: "new",
                        identity: replacementIdentity,
                        firstObservedNanos: 10)))),
            ],
            digests: [name: "old"])

        XCTAssertTrue(observe(
            name: name,
            kind: .numbered(revision: "00007"),
            outcome: .absent,
            nowNanos: 20,
            reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.state.generation.files[name], .settled(.emittedNow(
            identity: oldIdentity,
            digest: "old")))
        XCTAssertEqual(reducer.state.lastEmittedDigestByName[name], "old")
        XCTAssertEqual(reducer.derivedRevisionHighWater, "00007")
    }

    func testDuplicateSettlementReplacementPreservesOutcomeUntilNewContentYields() {
        let name = "live_stack_00007.fit"
        let url = URL(fileURLWithPath: "/watch/\(name)")
        let oldIdentity = makeIdentity(1)
        let identicalIdentity = makeIdentity(2)
        let changedIdentity = makeIdentity(3)
        var reducer = makeReducer(
            files: [
                name: .settled(.duplicateOfLastEmission(
                    identity: oldIdentity,
                    digest: "same",
                    replacement: .observing(stat: identicalIdentity))),
            ],
            digests: [name: "same"],
            quietPeriodNanos: 100)

        XCTAssertTrue(observe(
            name: name,
            kind: .numbered(revision: "00007"),
            outcome: .digested(
                identity: identicalIdentity,
                digest: "same",
                byteCount: identicalIdentity.size),
            nowNanos: 10,
            reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.state.generation.files[name], .settled(
            .duplicateOfLastEmission(identity: identicalIdentity, digest: "same")))
        XCTAssertEqual(reducer.readPlan(for: [EnumeratedEntry(
            name: name,
            url: url,
            identity: identicalIdentity,
            isFITS: true)]), [
                .acceptIdentity(FileObservation(
                    name: name,
                    url: url,
                    kind: .numbered(revision: "00007"),
                    outcome: .identityUnchanged(identity: identicalIdentity))),
            ])
        XCTAssertNil(reducer.derivedRevisionHighWater)

        XCTAssertTrue(observe(
            name: name,
            kind: .numbered(revision: "00007"),
            outcome: .unstable(identity: changedIdentity),
            nowNanos: 20,
            reducer: &reducer).isEmpty)
        XCTAssertTrue(observe(
            name: name,
            kind: .numbered(revision: "00007"),
            outcome: .digested(
                identity: changedIdentity,
                digest: "new",
                byteCount: changedIdentity.size),
            nowNanos: 20,
            reducer: &reducer).isEmpty)

        let candidate = makeCandidate(
            name: name,
            identity: changedIdentity,
            digest: "new",
            kind: .numbered(revision: "00007"))
        let intent = EmissionIntent(
            generation: reducer.state.generation.id,
            candidate: candidate)
        XCTAssertEqual(observe(
            name: name,
            kind: .numbered(revision: "00007"),
            outcome: .digested(
                identity: changedIdentity,
                digest: "new",
                byteCount: changedIdentity.size),
            nowNanos: 120,
            reducer: &reducer), [.emit(intent)])
        let readyDuplicate = FileState.settled(.duplicateOfLastEmission(
            identity: identicalIdentity,
            digest: "same",
            replacement: .ready(candidate)))
        XCTAssertEqual(reducer.state.generation.files[name], readyDuplicate)
        XCTAssertNil(reducer.derivedRevisionHighWater)
        XCTAssertTrue(reducer.shouldExecuteEmission(intent))

        XCTAssertTrue(reducer.reduce(.emissionFinished(EmissionResult(
            intent: intent,
            outcome: .rejected))).isEmpty)
        XCTAssertEqual(reducer.state.generation.files[name], readyDuplicate)
        XCTAssertEqual(reducer.state.lastEmittedDigestByName[name], "same")
        XCTAssertNil(reducer.derivedRevisionHighWater)

        XCTAssertTrue(reducer.reduce(.emissionFinished(EmissionResult(
            intent: intent,
            outcome: .yielded))).isEmpty)
        XCTAssertEqual(reducer.state.generation.files[name], .settled(.emittedNow(
            identity: changedIdentity,
            digest: "new")))
        XCTAssertEqual(reducer.state.lastEmittedDigestByName[name], "new")
        XCTAssertEqual(reducer.derivedRevisionHighWater, "00007")
    }

    func testSettledReplacementOuterIdentityReturnClearsNestedProgress() {
        let name = "live_stack_00007.fit"
        let settledIdentity = makeIdentity(1)
        let replacementIdentity = makeIdentity(2)
        var reducer = makeReducer(
            files: [
                name: .settled(.emittedNow(
                    identity: settledIdentity,
                    digest: "old",
                    replacement: .digestPending(PendingDigest(
                        digest: "new",
                        identity: replacementIdentity,
                        firstObservedNanos: 10)))),
            ],
            digests: [name: "old"])

        XCTAssertTrue(observe(
            name: name,
            kind: .numbered(revision: "00007"),
            outcome: .identityUnchanged(identity: settledIdentity),
            nowNanos: 20,
            reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.state.generation.files[name], .settled(.emittedNow(
            identity: settledIdentity,
            digest: "old")))
        XCTAssertEqual(reducer.derivedRevisionHighWater, "00007")
    }

    func testSettledReplacementInvalidObservationClearsNestedProgress() {
        let name = "live_stack_00007.fit"
        let settledIdentity = makeIdentity(1)
        let replacementIdentity = makeIdentity(2)
        var reducer = makeReducer(
            files: [
                name: .settled(.emittedNow(
                    identity: settledIdentity,
                    digest: "old",
                    replacement: .digestPending(PendingDigest(
                        digest: "new",
                        identity: replacementIdentity,
                        firstObservedNanos: 10)))),
            ],
            digests: [name: "old"])

        XCTAssertTrue(observe(
            name: name,
            kind: .numbered(revision: "00007"),
            outcome: .invalid,
            nowNanos: 20,
            reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.state.generation.files[name], .settled(.emittedNow(
            identity: settledIdentity,
            digest: "old")))
        XCTAssertEqual(reducer.state.lastEmittedDigestByName[name], "old")
        XCTAssertEqual(reducer.derivedRevisionHighWater, "00007")
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

    func testSettledFastPathRejectsChangedIdentityWithoutContentRead() {
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
                .observeWithoutContent(FileObservation(
                    name: name,
                    url: url,
                    kind: .numbered(revision: "00001"),
                    outcome: .unstable(identity: currentIdentity))),
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
            let reducer = makeReducer(
                files: [testCase.name: .observing(stat: identity)],
                filePrefix: testCase.prefix)
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
                .observeWithoutContent(FileObservation(
                    name: name,
                    url: url,
                    kind: .numbered(revision: thirtyDigitRevision),
                    outcome: .unstable(identity: makeIdentity(2)))),
            ])
        XCTAssertEqual(reducer.derivedRevisionHighWater, thirtyDigitRevision)
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
            outcome: .invalid,
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

    func testNumberedEmissionClearsPausedVictimClockWhenEpisodeAlreadyDissolved() {
        let blocker = "live_stack_00001.fit"
        let victim = "live_stack_00002.fit"
        let identity = makeIdentity(1)
        let candidate = makeCandidate(
            name: blocker,
            identity: identity,
            digest: "blocker-complete",
            kind: .numbered(revision: "00001"))
        let intent = EmissionIntent(
            generation: FolderGeneration(rawValue: 1),
            candidate: candidate)
        var ledger = VictimWaitLedger()
        ledger.startOrContinue(owner: RevisionKey("1"), at: 10)
        ledger.pause(at: 20)
        var reducer = makeReducer(
            files: [blocker: .ready(candidate)],
            victimLedgers: [victim: ledger])

        XCTAssertTrue(reducer.reduce(.emissionFinished(EmissionResult(
            intent: intent,
            outcome: .yielded))).isEmpty)

        XCTAssertNil(reducer.state.generation.ordering.victimLedgers[victim],
                     "when the blocker emits after its victim disappeared, the paused victim clock is stale")
    }

    func testDriverEmissionClearsPausedClockChargedUnderEmittedOwnerBeforeFreshBlockerStarts() {
        let oldBlocker = revisionName("00001")
        let freshBlocker = revisionName("00002")
        let victim = revisionName("00003")
        let oldIdentity = makeIdentity(1)
        let victimIdentity = makeIdentity(3)
        let victimCandidate = makeCandidate(
            name: victim,
            identity: victimIdentity,
            digest: "victim",
            kind: .numbered(revision: "00003"))
        var reducer = makeReducer(files: [victim: .ready(victimCandidate)])

        XCTAssertTrue(observeBatch([
            observation(name: oldBlocker, revision: "00001", outcome: .digested(
                identity: oldIdentity, digest: "old", byteCount: oldIdentity.size)),
            observation(name: victim, revision: "00003", outcome: .identityUnchanged(
                identity: victimIdentity)),
        ], nowNanos: 10, reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.blocker, oldBlocker)

        XCTAssertTrue(observeBatch([
            observation(name: oldBlocker, revision: "00001", outcome: .digested(
                identity: oldIdentity, digest: "old", byteCount: oldIdentity.size)),
            observation(name: victim, revision: "00003", outcome: .identityUnchanged(
                identity: victimIdentity)),
        ], nowNanos: 110, reducer: &reducer).isEmpty)

        let completionBatchNanos: UInt64 = 22_000_000_010
        let effects = observeBatch([
            observation(name: oldBlocker, revision: "00001", outcome: .digested(
                identity: oldIdentity, digest: "old", byteCount: oldIdentity.size)),
            invalidRevision("00002"),
            observation(name: victim, revision: "00003", outcome: .absent),
        ], nowNanos: completionBatchNanos, reducer: &reducer)

        guard case .emit(let oldIntent) = effects.first else {
            return XCTFail("old blocker should emit before the fresh blocker starts")
        }
        XCTAssertNil(reducer.state.generation.ordering.activeBlocker)
        XCTAssertNotNil(reducer.state.generation.ordering.victimLedgers[victim],
                        "the absent victim clock is retained until the owner emission settles")

        XCTAssertTrue(reducer.reduce(.emissionFinished(EmissionResult(
            intent: oldIntent,
            outcome: .yielded))).isEmpty)

        XCTAssertNil(reducer.state.generation.ordering.victimLedgers[victim],
                     "the real driver path must clear the paused clock when its charged owner emits")

        let victimReturnNanos = completionBatchNanos &+ 9_000_000_000
        XCTAssertTrue(observeBatch([
            invalidRevision("00002"),
            observation(name: victim, revision: "00003", outcome: .identityUnchanged(
                identity: victimIdentity)),
        ], nowNanos: victimReturnNanos, reducer: &reducer).isEmpty)

        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.blocker, freshBlocker)
        XCTAssertEqual(
            reducer.state.generation.ordering.victimLedgers[victim]?
                .segments[RevisionKey("2")]?.firstChargeNanos,
            victimReturnNanos,
            "the fresh blocker must receive a fresh budget, not inherited old accrual")
    }

    func testLowerEmissionDoesNotClearPausedClockChargedUnderLaterBlocker() {
        let lower = revisionName("00003")
        let blocker = revisionName("00005")
        let victim = revisionName("00006")
        let lowerIdentity = makeIdentity(3)
        let victimIdentity = makeIdentity(6)
        let lowerCandidate = makeCandidate(
            name: lower,
            identity: lowerIdentity,
            digest: "lower",
            kind: .numbered(revision: "00003"))
        var reducer = makeReducer(files: [
            lower: .ready(lowerCandidate),
            victim: .ready(makeCandidate(
                name: victim,
                identity: victimIdentity,
                digest: "victim",
                kind: .numbered(revision: "00006"))),
        ])

        XCTAssertTrue(observeBatch([
            invalidRevision("00005"),
            observation(name: victim, revision: "00006", outcome: .identityUnchanged(
                identity: victimIdentity)),
        ], nowNanos: 10, reducer: &reducer).isEmpty)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.blocker, blocker)

        let effects = observeBatch([
            observation(name: lower, revision: "00003", outcome: .identityUnchanged(
                identity: lowerIdentity)),
            invalidRevision("00005"),
            observation(name: victim, revision: "00006", outcome: .absent),
        ], nowNanos: 20, reducer: &reducer)

        guard case .emit(let lowerIntent) = effects.first else {
            return XCTFail("ready lower revision should emit before the later blocker")
        }
        XCTAssertNil(reducer.state.generation.ordering.activeBlocker)
        XCTAssertNotNil(reducer.state.generation.ordering.victimLedgers[victim],
                        "the absent victim clock is paused under \(blocker)")

        XCTAssertTrue(reducer.reduce(.emissionFinished(EmissionResult(
            intent: lowerIntent,
            outcome: .yielded))).isEmpty)

        XCTAssertNotNil(reducer.state.generation.ordering.victimLedgers[victim],
                        "emitting \(lower) did not resolve \(blocker), so it must not wipe \(victim)'s charged clock")
        XCTAssertNotNil(
            reducer.state.generation.ordering.victimLedgers[victim]?
                .segments[RevisionKey("5")])
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
                    blocker: revisionName("00001"),
                    owner: RevisionKey("1"),
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
        victimLedgers: [String: VictimWaitLedger] = [:],
        digestPolicy: StackFileWatcher.DigestPolicy = .mutableStackerOutput,
        filePrefix: String? = "live_stack",
        quietPeriodNanos: UInt64 = 100,
        pollIntervalNanos: UInt64 = 1_000
    ) -> WatcherReducer {
        var ordering = RevisionOrderingState(activeBlocker: activeBlocker)
        ordering.victimLedgers = victimLedgers
        return WatcherReducer(
            state: WatcherState(
                generation: GenerationState(
                    id: FolderGeneration(rawValue: generation),
                    files: files,
                    ordering: ordering),
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
            outcome: .invalid)
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

    func testRevisionKeyNormalizesPaddingAndUsesNumericOrdering() {
        let order = NumberedRevisionOrder(prefix: "live_stack")

        XCTAssertEqual(
            order.revisionKey(in: "live_stack_7.fit"),
            order.revisionKey(in: "live_stack_007.fit"))
        XCTAssertTrue(order.orderedBefore(RevisionKey("9"), RevisionKey("10")))
        XCTAssertFalse(order.orderedBefore(RevisionKey("10"), RevisionKey("9")))
        // The §3.1 ban on lexicographic RevisionKey ordering, pinned as a sort:
        XCTAssertEqual(
            [RevisionKey("10"), RevisionKey("9")].sorted { order.orderedBefore($0, $1) },
            [RevisionKey("9"), RevisionKey("10")])
    }

    func testVictimWaitLedgerAccruesPausesRedeemsAndTotalsSegments() {
        let order = NumberedRevisionOrder(prefix: "live_stack")
        var ledger = VictimWaitLedger()
        let first = RevisionKey("1")
        let second = RevisionKey("2")

        ledger.startOrContinue(owner: first, at: 10)
        ledger.pause(at: 30)
        XCTAssertEqual(ledger.totalUnredeemedNanos(at: 100), 20)

        ledger.startOrContinue(owner: second, at: 100)
        XCTAssertEqual(ledger.totalUnredeemedNanos(at: 120), 40)

        ledger.redeem(owner: first)
        XCTAssertEqual(ledger.totalUnredeemedNanos(at: 120), 20)
        XCTAssertEqual(
            ledger.segments.keys.sorted { order.orderedBefore($0, $1) },
            [second])
    }

    func testVictimWaitLedgerConsumeTruncatesAndPreservesRemainder() {
        var ledger = VictimWaitLedger()
        ledger.startOrContinue(owner: RevisionKey("1"), at: 0)
        ledger.pause(at: 40)                                  // owner 1 holds 40
        ledger.startOrContinue(owner: RevisionKey("2"), at: 100)
        ledger.pause(at: 130)                                 // owner 2 holds 30

        ledger.consume([RevisionKey("1"): 25, RevisionKey("2"): 30], at: 200)

        XCTAssertEqual(ledger.segments[RevisionKey("1")]?.accruedNanos, 15,
                       "partial consumption truncates; the remainder is still owed")
        XCTAssertNil(ledger.segments[RevisionKey("2")],
                     "full consumption removes the segment")
        XCTAssertEqual(ledger.totalUnredeemedNanos(at: 200), 15)
    }

    func testSegmentModel_d9RedeemsPausedDebtOnYieldedOwnerEmission() {
        // Development probe: reducer-only, injected .ready states.
        // Driver-faithful acceptance: WatcherSegmentBatteryTests.test_d9_* (Task 9).
        let ownerName = revisionName("00001")
        let victim = revisionName("00002")
        let owner = RevisionKey("1")
        var ledger = VictimWaitLedger()
        ledger.startOrContinue(owner: owner, at: 0)
        ledger.pause(at: 22_000_000_000)

        let ownerCandidate = makeCandidate(
            name: ownerName,
            identity: makeIdentity(1),
            digest: "owner",
            kind: .numbered(revision: "00001"))
        var reducer = makeReducer(
            files: [ownerName: .ready(ownerCandidate)],
            victimLedgers: [victim: ledger])

        let effects = reducer.reduce(.emissionFinished(EmissionResult(
            intent: EmissionIntent(
                generation: reducer.state.generation.id,
                candidate: ownerCandidate),
            outcome: .yielded)))

        XCTAssertTrue(effects.isEmpty)
        XCTAssertNil(reducer.state.generation.ordering.victimLedgers[victim],
                     "owner 1's paused segment was the only debt; redemption empties and removes the ledger")
    }

    func testSegmentModel_d4VanishedOwnerDebtSurvivesUnrelatedSuccessorEmission() {
        // Development probe: reducer-only, injected states. d4 provenance: round-8 M4
        // ("vanished = still owed"), round-7 fix direction ("d4's vanished-owner carry
        // is preserved"). Driver-faithful acceptance: WatcherSegmentBatteryTests.test_d4_*.
        let successorName = revisionName("00002")
        let victim = revisionName("00005")
        var ledger = VictimWaitLedger()
        ledger.startOrContinue(owner: RevisionKey("1"), at: 0)   // owner 1 later vanished
        ledger.pause(at: 10_000_000_000)                          // 10s unresolved debt
        ledger.startOrContinue(owner: RevisionKey("2"), at: 12_000_000_000)
        ledger.pause(at: 20_000_000_000)                          // owner 2 holds 8s

        let successorCandidate = makeCandidate(
            name: successorName,
            identity: makeIdentity(2),
            digest: "successor",
            kind: .numbered(revision: "00002"))
        var reducer = makeReducer(
            files: [
                successorName: .ready(successorCandidate),
                victim: .ready(makeCandidate(
                    name: victim,
                    identity: makeIdentity(5),
                    digest: "victim",
                    kind: .numbered(revision: "00005")))
            ],
            activeBlocker: BlockingEpisode(
                blocker: successorName,
                owner: RevisionKey("2"),
                victims: [victim]),
            victimLedgers: [victim: ledger])

        _ = reducer.reduce(.emissionFinished(EmissionResult(
            intent: EmissionIntent(
                generation: reducer.state.generation.id,
                candidate: successorCandidate),
            outcome: .yielded)))

        XCTAssertNil(
            reducer.state.generation.ordering.victimLedgers[victim]?.segments[RevisionKey("2")],
            "the emitting owner's own segment is redeemed")
        XCTAssertEqual(
            reducer.state.generation.ordering.victimLedgers[victim]?.segments[RevisionKey("1")]?.accruedNanos,
            10_000_000_000,
            "the vanished owner's carried debt must survive an unrelated successor's emission (d4)")
    }

    func testSegmentModelRejectedEmissionDoesNotRedeemDebt() {
        // Development probe: reducer-only, injected states.
        let ownerName = revisionName("00001")
        let victim = revisionName("00002")
        let owner = RevisionKey("1")
        var ledger = VictimWaitLedger()
        ledger.startOrContinue(owner: owner, at: 0)
        ledger.pause(at: 10_000_000_000)

        let ownerCandidate = makeCandidate(
            name: ownerName,
            identity: makeIdentity(1),
            digest: "owner",
            kind: .numbered(revision: "00001"))
        var reducer = makeReducer(
            files: [ownerName: .ready(ownerCandidate)],
            victimLedgers: [victim: ledger])

        _ = reducer.reduce(.emissionFinished(EmissionResult(
            intent: EmissionIntent(
                generation: reducer.state.generation.id,
                candidate: ownerCandidate),
            outcome: .rejected)))

        XCTAssertNotNil(reducer.state.generation.ordering.victimLedgers[victim]?.segments[owner],
                        "a rejected emission is not stream progress and redeems nothing")
    }

    func testSegmentModelVictimOwnYieldedEmissionClearsItsLedger() {
        // Development probe: reducer-only, injected states. §5.2: "The victim's own
        // successful emission also clears its ledger."
        let victim = revisionName("00003")
        var ledger = VictimWaitLedger()
        ledger.startOrContinue(owner: RevisionKey("1"), at: 0)   // stale predecessor debt
        ledger.pause(at: 9_000_000_000)

        let victimCandidate = makeCandidate(
            name: victim,
            identity: makeIdentity(3),
            digest: "victim",
            kind: .numbered(revision: "00003"))
        var reducer = makeReducer(
            files: [victim: .ready(victimCandidate)],
            victimLedgers: [victim: ledger])

        _ = reducer.reduce(.emissionFinished(EmissionResult(
            intent: EmissionIntent(
                generation: reducer.state.generation.id,
                candidate: victimCandidate),
            outcome: .yielded)))

        XCTAssertNil(reducer.state.generation.ordering.victimLedgers[victim],
                     "the victim emitted — no owed wait can explain any future hold")
    }

    func testSegmentModel_h4DefersSuccessorChargingUntilPendingEmissionSettles() {
        // Development probe: reducer-only, injected .ready states (an unready file cannot
        // become ready and emit in a single sighting — see Global Constraints).
        // Driver-faithful acceptance: WatcherSegmentBatteryTests.test_h4_*.
        let resolving = revisionName("00001")
        let victim = revisionName("00003")
        let resolvingCandidate = makeCandidate(
            name: resolving,
            identity: makeIdentity(1),
            digest: "resolved",
            kind: .numbered(revision: "00001"))
        var reducer = makeReducer(files: [
            resolving: .ready(resolvingCandidate),
            victim: .ready(makeCandidate(
                name: victim,
                identity: makeIdentity(3),
                digest: "victim",
                kind: .numbered(revision: "00003")))
        ])

        let effects = observeBatch([
            observation(name: resolving, revision: "00001",
                        outcome: .identityUnchanged(identity: makeIdentity(1))),
            invalidRevision("00002"),
            observation(name: victim, revision: "00003",
                        outcome: .identityUnchanged(identity: makeIdentity(3))),
        ], nowNanos: 1_000, reducer: &reducer)

        XCTAssertEqual(emittedNames(in: effects), [resolving])
        XCTAssertTrue(reducer.state.generation.ordering.victimLedgers.isEmpty,
                      "successor charging is barrier-deferred in the intent's own pass")
        XCTAssertEqual(reducer.state.generation.ordering.pendingEmissionOwners, [RevisionKey("1")])
    }

    func testSegmentModelSuccessorChargesAfterPendingEmissionSettles() {
        // Development probe: reducer-only, injected .ready states.
        let resolving = revisionName("00001")
        let successor = revisionName("00002")
        let victim = revisionName("00003")
        let resolvingCandidate = makeCandidate(
            name: resolving,
            identity: makeIdentity(1),
            digest: "resolved",
            kind: .numbered(revision: "00001"))
        var reducer = makeReducer(files: [
            resolving: .ready(resolvingCandidate),
            victim: .ready(makeCandidate(
                name: victim,
                identity: makeIdentity(3),
                digest: "victim",
                kind: .numbered(revision: "00003")))
        ])

        let effects = observeBatch([
            observation(name: resolving, revision: "00001",
                        outcome: .identityUnchanged(identity: makeIdentity(1))),
            invalidRevision("00002"),
            observation(name: victim, revision: "00003",
                        outcome: .identityUnchanged(identity: makeIdentity(3))),
        ], nowNanos: 1_000, reducer: &reducer)
        guard case .emit(let intent) = effects.first else {
            return XCTFail("expected the resolving revision's emission intent")
        }

        _ = reducer.reduce(.emissionFinished(EmissionResult(intent: intent, outcome: .yielded)))
        XCTAssertTrue(reducer.state.generation.ordering.pendingEmissionOwners.isEmpty,
                      "settlement removes the pending owner for every terminal outcome")

        _ = observeBatch([
            observation(name: resolving, revision: "00001",
                        outcome: .identityUnchanged(identity: makeIdentity(1))),
            invalidRevision("00002"),
            observation(name: victim, revision: "00003",
                        outcome: .identityUnchanged(identity: makeIdentity(3))),
        ], nowNanos: 2_000, reducer: &reducer)

        XCTAssertEqual(
            reducer.state.generation.ordering.victimLedgers[victim]?.segments[RevisionKey("2")]?.firstChargeNanos,
            2_000)
        XCTAssertEqual(reducer.state.generation.ordering.activeBlocker?.blocker, successor)
    }

    func testSegmentModel_b1DischargesDebtAfterPresentUnblockedObservePass() {
        // Development probe: reducer-only, injected ledger. b1/W4-2a provenance: round-4
        // W4-2a (stale clocks age while unblocked), round-5 "W4-2a fully closed".
        // Driver-faithful acceptance: WatcherSegmentBatteryTests.test_b1_*.
        let victim = revisionName("00003")
        var ledger = VictimWaitLedger()
        ledger.startOrContinue(owner: RevisionKey("1"), at: 0)
        ledger.pause(at: 29_000_000_000)
        var reducer = makeReducer(victimLedgers: [victim: ledger])

        // One full pass: victim present (first .digested sighting → .observing is enough —
        // discharge needs presence, not readiness), and no lower revision in the batch.
        _ = observeBatch([
            observation(name: victim, revision: "00003", outcome: .digested(
                identity: makeIdentity(3),
                digest: "victim",
                byteCount: makeIdentity(3).size))
        ], nowNanos: 30_000_000_000, reducer: &reducer)

        XCTAssertNil(reducer.state.generation.ordering.victimLedgers[victim],
                     "a present-and-unblocked pass discharges stale debt (§5.2)")
    }

    func testSegmentModelInvalidLowerWithoutFilesEntryStillBlocksDischarge() {
        // Development probe: reducer-only, injected ledger.
        let victim = revisionName("00003")
        var ledger = VictimWaitLedger()
        ledger.startOrContinue(owner: RevisionKey("2"), at: 0)
        ledger.pause(at: 10_000_000_000)
        var reducer = makeReducer(victimLedgers: [victim: ledger])

        _ = observeBatch([
            invalidRevision("00002"),   // present, unready, and NEVER in state.generation.files
            observation(name: victim, revision: "00003", outcome: .digested(
                identity: makeIdentity(3),
                digest: "victim",
                byteCount: makeIdentity(3).size))
        ], nowNanos: 11_000_000_000, reducer: &reducer)

        XCTAssertNotNil(reducer.state.generation.ordering.victimLedgers[victim],
                        "an invalid lower revision is batch-present and unready — the victim is blocked")
    }

    func testSegmentModelBarrierDeferredSuccessorStillMeansVictimIsBlocked() {
        // Development probe: reducer-only, injected states. The barrier is not an
        // unblocked signal (§5.2): an unready lower revision keeps the victim blocked
        // even while charging is barrier-deferred.
        let victim = revisionName("00003")
        var ledger = VictimWaitLedger()
        ledger.startOrContinue(owner: RevisionKey("1"), at: 0)
        ledger.pause(at: 10_000_000_000)
        var ordering = RevisionOrderingState(activeBlocker: nil)
        ordering.victimLedgers = [victim: ledger]
        ordering.pendingEmissionOwners = [RevisionKey("1")]
        var reducer = WatcherReducer(
            state: WatcherState(
                generation: GenerationState(
                    id: FolderGeneration(rawValue: 1),
                    files: [victim: .ready(makeCandidate(
                        name: victim,
                        identity: makeIdentity(3),
                        digest: "victim",
                        kind: .numbered(revision: "00003")))],
                    ordering: ordering),
                lastEmittedDigestByName: [:]),
            configuration: makeConfiguration())

        _ = observeBatch([
            invalidRevision("00002"),
            observation(name: victim, revision: "00003",
                        outcome: .identityUnchanged(identity: makeIdentity(3))),
        ], nowNanos: 11_000_000_000, reducer: &reducer)

        XCTAssertNotNil(reducer.state.generation.ordering.victimLedgers[victim])
    }

    func testSegmentModelAllReadyPassPausesAbsentVictimLedgerInsteadOfDeleting() {
        // Development probe: reducer-only, injected ledger and .ready state. True-red
        // probe for Task 6: the interim all-ready branch wipes victimLedgers wholesale;
        // the end-of-pass settlement must instead pause (tombstone) an absent victim's
        // charged ledger so its accrual survives the pass (M3).
        let ready = revisionName("00001")
        let victim = revisionName("00003")
        var ledger = VictimWaitLedger()
        ledger.startOrContinue(owner: RevisionKey("2"), at: 0)
        ledger.pause(at: 5_000_000_000)
        var reducer = makeReducer(
            files: [ready: .ready(makeCandidate(
                name: ready,
                identity: makeIdentity(1),
                digest: "ready",
                kind: .numbered(revision: "00001")))],
            victimLedgers: [victim: ledger])

        _ = observeBatch([
            observation(name: ready, revision: "00001",
                        outcome: .identityUnchanged(identity: makeIdentity(1))),
            observation(name: victim, revision: "00003", outcome: .absent),
        ], nowNanos: 10_000_000_000, reducer: &reducer)

        XCTAssertNotNil(reducer.state.generation.ordering.victimLedgers[victim],
                        "an absent victim's ledger is paused (tombstoned), never deleted, on an all-ready pass")
        XCTAssertEqual(
            reducer.state.generation.ordering.victimLedgers[victim]?
                .segments[RevisionKey("2")]?.accruedNanos,
            5_000_000_000,
            "the tombstone pause preserves accrual across the absence")
    }

    func testSegmentModelConsumesPredecessorDebtButLogsCurrentOwnerTimeSeparately() {
        let blockerName = revisionName("00002")
        var ledger = VictimWaitLedger()
        ledger.startOrContinue(owner: RevisionKey("1"), at: 0)
        ledger.pause(at: 29_500_000_000)
        ledger.startOrContinue(owner: RevisionKey("2"), at: 30_000_000_000)

        let reducer = makeReducer(
            quietPeriodNanos: 100_000_000,
            pollIntervalNanos: 1_000_000_000)

        let decision = reducer.writeOffDecision(
            for: RevisionKey("2"),
            blockerName: blockerName,
            victimLedger: ledger,
            nowNanos: 35_000_000_000)

        XCTAssertEqual(decision?.blocker, RevisionKey("2"))
        XCTAssertEqual(decision?.blockerNameForLog, blockerName)
        XCTAssertEqual(decision?.attributedNanos, 5_000_000_000)
        XCTAssertEqual(decision?.consumedSegments, [RevisionKey("1"): 25_000_000_000])
        XCTAssertNil(decision?.consumedSegments[RevisionKey("2")],
                     "the blocker's own segment must never appear under predecessor debt (M9)")
    }

    func testSegmentModelDoesNotWriteOffConvergingFreshOwnerInsideRenewedGrace() {
        let blockerName = revisionName("00002")
        var ledger = VictimWaitLedger()
        ledger.startOrContinue(owner: RevisionKey("1"), at: 0)
        ledger.pause(at: 29_500_000_000)
        ledger.startOrContinue(owner: RevisionKey("2"), at: 30_000_000_000)

        var reducer = makeReducer(
            quietPeriodNanos: 1_000_000_000,
            pollIntervalNanos: 1_000_000_000)
        reducer.noteConvergingOwner(RevisionKey("2"), at: 34_000_000_000)

        XCTAssertNil(
            reducer.writeOffDecision(
                for: RevisionKey("2"),
                blockerName: blockerName,
                victimLedger: ledger,
                nowNanos: 34_500_000_000),
            "total (34e9) exceeds budget (30e9) — only the renewed grace defers the decision")

        let afterGrace = reducer.writeOffDecision(
            for: RevisionKey("2"),
            blockerName: blockerName,
            victimLedger: ledger,
            nowNanos: 35_000_000_000)
        XCTAssertEqual(afterGrace?.attributedNanos, 5_000_000_000)
        XCTAssertEqual(afterGrace?.consumedSegments, [RevisionKey("1"): 25_000_000_000])
    }

    func testSegmentModelNonConvergingChurnDoesNotRenewOwnerGrace() {
        // Development probe: reducer-only, injected victim state.
        let blocker = revisionName("00001")
        let victim = revisionName("00002")
        var reducer = makeReducer(files: [
            victim: .ready(makeCandidate(
                name: victim,
                identity: makeIdentity(2),
                digest: "victim",
                kind: .numbered(revision: "00002")))
        ])

        // Invalid churn: never converging.
        for tick in 1...3 {
            _ = observeBatch([
                invalidRevision("00001"),
                observation(name: victim, revision: "00002",
                            outcome: .identityUnchanged(identity: makeIdentity(2))),
            ], nowNanos: UInt64(tick) * 1_000, reducer: &reducer)
        }
        XCTAssertNil(reducer.state.generation.ordering.ownerGraceUntil[RevisionKey("1")],
                     "invalid churn is not convergence and renews nothing")

        // Genuine convergence: same digest re-sighted inside the quiet period (quiet=100).
        _ = observeBatch([
            observation(name: blocker, revision: "00001", outcome: .digested(
                identity: makeIdentity(1), digest: "c", byteCount: makeIdentity(1).size)),
            observation(name: victim, revision: "00002",
                        outcome: .identityUnchanged(identity: makeIdentity(2))),
        ], nowNanos: 4_000, reducer: &reducer)             // -> .observing
        _ = observeBatch([
            observation(name: blocker, revision: "00001", outcome: .digested(
                identity: makeIdentity(1), digest: "c", byteCount: makeIdentity(1).size)),
            observation(name: victim, revision: "00002",
                        outcome: .identityUnchanged(identity: makeIdentity(2))),
        ], nowNanos: 5_000, reducer: &reducer)             // -> .digestPending(first=5_000)
        _ = observeBatch([
            observation(name: blocker, revision: "00001", outcome: .digested(
                identity: makeIdentity(1), digest: "c", byteCount: makeIdentity(1).size)),
            observation(name: victim, revision: "00002",
                        outcome: .identityUnchanged(identity: makeIdentity(2))),
        ], nowNanos: 5_050, reducer: &reducer)             // same digest, 50 < quiet(100) -> converging

        XCTAssertEqual(reducer.state.generation.ordering.ownerGraceUntil[RevisionKey("1")],
                       5_050 + 100,
                       "a converging observation renews the CURRENT owner's grace by one quiet period")
    }

    func testGenerationChangeClearsBarrierAndGraceState() {
        // Development probe: reducer-only, injected state. M8: everything ordering-scoped
        // dies with the generation.
        var ordering = RevisionOrderingState(activeBlocker: nil)
        ordering.victimLedgers = [revisionName("00002"): VictimWaitLedger(
            segments: [RevisionKey("1"): AccrualSegment(
                owner: RevisionKey("1"), firstChargeNanos: 0, accruedNanos: 5, runningSinceNanos: nil)],
            pausedAtNanos: 5)]
        ordering.pendingEmissionOwners = [RevisionKey("1")]
        ordering.ownerGraceUntil = [RevisionKey("1"): 99]
        var reducer = WatcherReducer(
            state: WatcherState(
                generation: GenerationState(
                    id: FolderGeneration(rawValue: 1), files: [:], ordering: ordering),
                lastEmittedDigestByName: ["keep.fit": "digest"]),
            configuration: makeConfiguration())

        XCTAssertTrue(reducer.reduce(.replaceGeneration(FolderGeneration(rawValue: 2))).isEmpty)

        XCTAssertTrue(reducer.state.generation.ordering.victimLedgers.isEmpty)
        XCTAssertTrue(reducer.state.generation.ordering.pendingEmissionOwners.isEmpty)
        XCTAssertTrue(reducer.state.generation.ordering.ownerGraceUntil.isEmpty)
        XCTAssertEqual(reducer.state.lastEmittedDigestByName["keep.fit"], "digest")
    }

    func testOrderingMapsEmptyAtQuiescenceAfterWriteOffAndEmissions() {
        // Development probe: reducer-only, injected .ready victim. Drives a full
        // blocked -> write-off -> victim-emits -> all-settled cycle and asserts H2:
        // every ordering map is empty once nothing is blocked or pending.
        let victim = revisionName("00002")
        let victimCandidate = makeCandidate(
            name: victim, identity: makeIdentity(2), digest: "victim",
            kind: .numbered(revision: "00002"))
        var reducer = makeReducer(files: [victim: .ready(victimCandidate)])

        _ = observeBatch([
            invalidRevision("00001"),
            observation(name: victim, revision: "00002",
                        outcome: .identityUnchanged(identity: makeIdentity(2))),
        ], nowNanos: 10, reducer: &reducer)
        let released = observeBatch([
            invalidRevision("00001"),
            observation(name: victim, revision: "00002",
                        outcome: .identityUnchanged(identity: makeIdentity(2))),
        ], nowNanos: 30_000_000_010, reducer: &reducer)
        guard case .emit(let intent)? = released.last(where: {
            if case .emit = $0 { return true }; return false
        }) else { return XCTFail("write-off must release the victim's intent") }
        _ = reducer.reduce(.emissionFinished(EmissionResult(intent: intent, outcome: .yielded)))
        _ = observeBatch([
            observation(name: victim, revision: "00002",
                        outcome: .identityUnchanged(identity: makeIdentity(2))),
        ], nowNanos: 31_000_000_010, reducer: &reducer)

        XCTAssertTrue(reducer.state.generation.ordering.victimLedgers.isEmpty, "H2: no leaked ledgers")
        XCTAssertTrue(reducer.state.generation.ordering.pendingEmissionOwners.isEmpty, "H2: no leaked barrier owners")
        XCTAssertTrue(reducer.state.generation.ordering.ownerGraceUntil.isEmpty, "H2: no leaked grace entries")
        XCTAssertNil(reducer.state.generation.ordering.activeBlocker)
    }
}
