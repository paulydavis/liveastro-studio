import XCTest
@testable import LiveAstroCore

final class WatcherReducerTests: XCTestCase {
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
                        blocker: "blocked.fit", startNanos: 100, deadlineNanos: 200))),
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
        filePrefix: String? = "live_stack"
    ) -> WatcherReducerConfiguration {
        WatcherReducerConfiguration(
            digestPolicy: digestPolicy,
            filePrefix: filePrefix,
            quietPeriodNanos: 100,
            pollIntervalNanos: 1_000)
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
                    deadlineNanos: 2_000))),
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
        digestPolicy: StackFileWatcher.DigestPolicy = .mutableStackerOutput,
        filePrefix: String? = "live_stack"
    ) -> WatcherReducer {
        WatcherReducer(
            state: WatcherState(
                generation: GenerationState(
                    id: FolderGeneration(rawValue: generation),
                    files: files,
                    ordering: RevisionOrderingState(activeBlocker: nil)),
                lastEmittedDigestByName: digests),
            configuration: makeConfiguration(
                digestPolicy: digestPolicy,
                filePrefix: filePrefix))
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
