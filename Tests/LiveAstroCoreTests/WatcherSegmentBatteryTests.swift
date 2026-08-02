import XCTest
@testable import LiveAstroCore

/// Regenerated watcher battery. The original fw6/fw7/fw8 probe sources are lost;
/// each scenario below is re-derived from its description in
/// docs/superpowers/reviews/2026-07-26-cold-review-round[4-6].md and
/// docs/superpowers/reviews/2026-07-27-cold-review-round[7-8].md.
/// CONTROL-PORTABLE: stable reducer API + observable asserts only (Task 10 drops
/// this file unchanged into control worktrees at 0ec11f8 / 6cb370a / fe843eb).
final class WatcherSegmentBatteryTests: XCTestCase {

    private struct ScriptedWatcherDriver {
        var reducer: WatcherReducer
        var emitted: [EmissionIntent] = []
        var logs: [(nanos: UInt64, line: String)] = []
        private var lastNowNanos: UInt64 = 0

        init(configuration: WatcherReducerConfiguration) {
            reducer = WatcherReducer(
                state: WatcherState(
                    generation: GenerationState(
                        id: FolderGeneration(rawValue: 1),
                        files: [:],
                        ordering: RevisionOrderingState(activeBlocker: nil)),
                    lastEmittedDigestByName: [:]),
                configuration: configuration)
        }

        mutating func observe(_ entries: [FileObservation], at nowNanos: UInt64) {
            lastNowNanos = nowNanos
            apply(reducer.reduce(.observe(ObservationBatch(
                generation: reducer.state.generation.id,
                entries: entries,
                nowNanos: nowNanos))))
        }

        /// Settles every outstanding intent in emission order, honoring the real
        /// driver's pre-yield check (`shouldExecuteEmission`), then records outcomes.
        mutating func settleAll(_ outcome: EmissionResult.Outcome = .yielded) {
            while !emitted.isEmpty {
                let intent = emitted.removeFirst()
                let effective: EmissionResult.Outcome =
                    reducer.shouldExecuteEmission(intent) ? outcome : .rejected
                apply(reducer.reduce(.emissionFinished(EmissionResult(
                    intent: intent, outcome: effective))))
            }
        }

        var abandonLogs: [(nanos: UInt64, line: String)] {
            logs.filter { $0.line.contains("abandoning") }
        }

        private mutating func apply(_ effects: [WatcherEffect]) {
            for effect in effects {
                switch effect {
                case .emit(let intent): emitted.append(intent)
                case .log(let line): logs.append((lastNowNanos, line))
                }
            }
        }
    }

    private func makeDriver() -> ScriptedWatcherDriver {
        ScriptedWatcherDriver(configuration: WatcherReducerConfiguration(
            digestPolicy: .mutableStackerOutput,
            filePrefix: "live_stack",
            quietPeriodNanos: 100_000_000,
            pollIntervalNanos: 1_000_000_000))
    }

    private func revisionName(_ revision: String) -> String { "live_stack_\(revision).fit" }

    private func makeIdentity(_ value: Int64) -> FileIdentity {
        FileIdentity(dev: value, ino: UInt64(value), size: Int(value) * 10,
                     mtimeSec: value, mtimeNsec: value)
    }

    private func digested(_ revision: String, _ digest: String, id: Int64) -> FileObservation {
        let identity = makeIdentity(id)
        return FileObservation(
            name: revisionName(revision),
            url: URL(fileURLWithPath: "/watch/\(revisionName(revision))"),
            kind: .numbered(revision: revision),
            outcome: .digested(identity: identity, digest: digest, byteCount: identity.size))
    }

    private func invalid(_ revision: String) -> FileObservation {
        FileObservation(
            name: revisionName(revision),
            url: URL(fileURLWithPath: "/watch/\(revisionName(revision))"),
            kind: .numbered(revision: revision),
            outcome: .invalid)
    }

    private func absent(_ revision: String) -> FileObservation {
        FileObservation(
            name: revisionName(revision),
            url: URL(fileURLWithPath: "/watch/\(revisionName(revision))"),
            kind: .numbered(revision: revision),
            outcome: .absent)
    }

    private func iu(_ revision: String, id: Int64) -> FileObservation {
        FileObservation(
            name: revisionName(revision),
            url: URL(fileURLWithPath: "/watch/\(revisionName(revision))"),
            kind: .numbered(revision: revision),
            outcome: .identityUnchanged(identity: makeIdentity(id)))
    }

    private func ownSeconds(in line: String) -> Int? {
        Int(line.components(separatedBy: "blocked emissions for ").last?
            .components(separatedBy: "s ").first ?? "")
    }

    // MARK: - Redemption family

    // d1 — present-victim (running-segment) redemption. Provenance: round-8 C3
    // ("running clocks never reset on owner emission"), spec §5.1 uniform redemption.
    // Expected on scalar controls: RED on all three (write-off of the successor before
    // its own budget, off inherited accrual).
    func test_d1_ownerEmissionWhileVictimPresentGivesSuccessorFreshBudget() {
        var d = makeDriver()
        let sec: UInt64 = 1_000_000_000

        // Victim 3 becomes ready behind invalid 1 (three sightings; blocked throughout).
        d.observe([invalid("00001"), digested("00003", "v", id: 3)], at: 0)
        d.observe([invalid("00001"), digested("00003", "v", id: 3)], at: 1 * sec)
        d.observe([invalid("00001"), digested("00003", "v", id: 3)], at: 2 * sec)
        // Owner 1 converges and emits at t=5s, victim PRESENT the whole time; a stalled
        // invalid 2 is present at the emission pass so the victim never becomes unblocked.
        d.observe([digested("00001", "done", id: 1), invalid("00002"), iu("00003", id: 3)], at: 3 * sec)
        d.observe([digested("00001", "done", id: 1), invalid("00002"), iu("00003", id: 3)], at: 4 * sec)
        d.observe([digested("00001", "done", id: 1), invalid("00002"), iu("00003", id: 3)], at: 5 * sec)
        XCTAssertEqual(d.emitted.map(\.candidate.name), [revisionName("00001")])
        d.settleAll(.yielded)

        // Successor 2 stalls; charging starts at t=6s. Fresh budget => first write-off
        // may fire no earlier than t=36s.
        for tick in 6...35 {
            d.observe([invalid("00002"), iu("00003", id: 3)], at: UInt64(tick) * sec)
            XCTAssertTrue(d.abandonLogs.isEmpty,
                          "successor written off at t=\(tick)s — inherited accrual (d1/C3); got \(d.logs)")
        }
        d.observe([invalid("00002"), iu("00003", id: 3)], at: 36 * sec)
        XCTAssertEqual(d.abandonLogs.count, 1, "fresh budget exhausts exactly at 30s of own tenure")
        XCTAssertEqual(d.reducer.state.generation.files[revisionName("00002")], .writtenOff)
        // The write-off frees victim 3 in the same pass (blockerScan re-derives).
        XCTAssertEqual(d.emitted.map(\.candidate.name), [revisionName("00003")])
        d.settleAll(.yielded)
        guard case .settled(.emittedNow)? = d.reducer.state.generation.files[revisionName("00003")] else {
            return XCTFail("victim 3 must settle as emitted after the write-off releases it")
        }
    }

    // d2 — paused-victim redemption. Provenance: round-7 R7-1 fix direction (paused
    // charge must clear when its owner emits), spec §5.1 "d9's paused case".
    // Observed on controls: green on all three (informative, non-binding — recorded in
    // the reconciliation doc). On 6cb370a the paused-clock equality clear handles this
    // single-flicker shape correctly; r7's defect bites running clocks (e1/e7), not
    // this paused case.
    func test_d2_ownerEmissionDuringVictimAbsenceRedeemsPausedDebt() {
        var d = makeDriver()
        let sec: UInt64 = 1_000_000_000

        d.observe([invalid("00001"), digested("00003", "v", id: 3)], at: 0)
        d.observe([invalid("00001"), digested("00003", "v", id: 3)], at: 1 * sec)
        d.observe([invalid("00001"), digested("00003", "v", id: 3)], at: 2 * sec)
        // 20s of charge under owner 1, then the victim flickers absent while owner 1
        // converges and emits.
        d.observe([invalid("00001"), iu("00003", id: 3)], at: 20 * sec)
        d.observe([digested("00001", "done", id: 1), absent("00003")], at: 21 * sec)
        d.observe([digested("00001", "done", id: 1), absent("00003")], at: 22 * sec)
        d.observe([digested("00001", "done", id: 1), absent("00003")], at: 23 * sec)
        XCTAssertEqual(d.emitted.map(\.candidate.name), [revisionName("00001")])
        d.settleAll(.yielded)

        // Victim returns behind fresh stalled 2 at t=25s: fresh budget, write-off ≥ 55s.
        for tick in 25...54 {
            d.observe([invalid("00002"), digested("00003", "v", id: 3)], at: UInt64(tick) * sec)
            XCTAssertTrue(d.abandonLogs.isEmpty,
                          "paused 20s not redeemed by owner emission (d2) — write-off at t=\(tick)s")
        }
        d.observe([invalid("00002"), digested("00003", "v", id: 3)], at: 55 * sec)
        XCTAssertEqual(d.abandonLogs.count, 1)
    }

    // d9 — emitted-owner pause + same-batch successor arrival. Provenance: round-7 R7-1
    // repro and the round-8 control table row 1 (RED on 6cb370a: 9.0s; green on
    // 0ec11f8/fe843eb: 31.0s). Spec §§4, 5.1.
    func test_d9_freshSuccessorArrivingWithOwnersEmissionGetsFullBudget() {
        var d = makeDriver()
        let sec: UInt64 = 1_000_000_000

        d.observe([digested("00001", "c0", id: 1), digested("00003", "v", id: 3)], at: 0)
        d.observe([digested("00001", "c1", id: 1), digested("00003", "v", id: 3)], at: 1 * sec)
        d.observe([digested("00001", "c2", id: 1), digested("00003", "v", id: 3)], at: 2 * sec)
        // Victim 3 is ready and blocked behind churning 1; charge runs 2s..22s.
        d.observe([digested("00001", "final", id: 1), iu("00003", id: 3)], at: 22 * sec)
        // Emission pass: 1 becomes ready and emits; stalled 2 arrives in the SAME batch;
        // the victim flickers absent.
        d.observe([digested("00001", "final", id: 1), invalid("00002"), absent("00003")], at: 23 * sec)
        XCTAssertEqual(d.emitted.map(\.candidate.name), [revisionName("00001")])
        d.settleAll(.yielded)

        // Victim returns at t=31s; successor 2's budget anchors at ITS first charge
        // (t=31s) => no write-off before t=61s.
        for tick in 31...60 {
            d.observe([invalid("00002"), digested("00003", "v", id: 3)], at: UInt64(tick) * sec)
            XCTAssertTrue(d.abandonLogs.isEmpty,
                          "d9 regression: successor written off at t=\(tick)s on inherited debt")
        }
        d.observe([invalid("00002"), digested("00003", "v", id: 3)], at: 61 * sec)
        XCTAssertEqual(d.abandonLogs.count, 1)
        XCTAssertEqual(d.reducer.state.generation.files[revisionName("00002")], .writtenOff)
    }

    // MARK: - Carry family

    // d4 — vanished owner's debt survives an unrelated successor's emission and is
    // consumed with honest attribution. Provenance: round-8 M4 + round-7 fix direction;
    // spec §§5.2, 5.4, 5.5. The log assertion here is the driver-level log-honesty
    // gate: own time and predecessor debt are separate facts (M9).
    func test_d4_vanishedOwnerDebtSurvivesUnrelatedEmissionAndIsConsumedHonestly() {
        var d = makeDriver()
        let sec: UInt64 = 1_000_000_000

        // Owner 1 (invalid) charges victim 5 from t=0; victim ready by t=2s.
        d.observe([invalid("00001"), digested("00005", "v", id: 5)], at: 0)
        d.observe([invalid("00001"), digested("00005", "v", id: 5)], at: 1 * sec)
        d.observe([invalid("00001"), digested("00005", "v", id: 5)], at: 2 * sec)
        // ... 20s of charge, then owner 1 VANISHES exactly as stalled 4 appears.
        d.observe([invalid("00001"), iu("00005", id: 5)], at: 19 * sec)
        d.observe([absent("00001"), invalid("00004"), iu("00005", id: 5)], at: 20 * sec)
        // Unrelated lower 2 converges and emits (23s..25s) while 4 still stalls.
        d.observe([digested("00002", "x", id: 2), invalid("00004"), iu("00005", id: 5)], at: 23 * sec)
        d.observe([digested("00002", "x", id: 2), invalid("00004"), iu("00005", id: 5)], at: 24 * sec)
        d.observe([digested("00002", "x", id: 2), invalid("00004"), iu("00005", id: 5)], at: 25 * sec)
        XCTAssertEqual(d.emitted.map(\.candidate.name), [revisionName("00002")])
        d.settleAll(.yielded)

        // Owner 1's 20s carried debt + owner 4's own tenure reach budget at t=33s:
        // charge under 4 ran 20..23 (3s) and resumes 26s.. => own = 3 + (t-26).
        // total = 20 + own >= 30 at t = 33s. If a resurrected removeAll had wiped the
        // carried debt at 2's emission, write-off would wait until ~t=56s.
        for tick in 26...32 {
            d.observe([invalid("00004"), iu("00005", id: 5)], at: UInt64(tick) * sec)
            XCTAssertTrue(d.abandonLogs.isEmpty)
        }
        d.observe([invalid("00004"), iu("00005", id: 5)], at: 33 * sec)
        XCTAssertEqual(d.abandonLogs.count, 1,
                       "carried predecessor debt must accelerate the stalled successor's write-off (d4)")
        let line = d.abandonLogs[0].line
        XCTAssertEqual(ownSeconds(in: line), 10,
                       "own-time clause reports owner 4's tenure only (3s+7s), never the 30s total")
        XCTAssertTrue(line.contains("consumed predecessor debt"), "log: \(line)")
        XCTAssertTrue(line.contains("1=20.0s"),
                      "the vanished owner's consumed 20s is named as a separate fact: \(line)")
    }

    // C2 — vanished-owner hijack with the lying 30s log. Provenance: round-8 C2
    // (0.5s write-off, log claims "blocked emissions for 30s"). Spec §§5.4, 5.5.
    // Expected on controls: RED on all three (early write-off with a lying own-time log).
    func test_C2_acceleratedWriteOffAfterVanishedOwnerKeepsLogHonest() {
        var d = makeDriver()
        let sec: UInt64 = 1_000_000_000

        d.observe([invalid("00001"), digested("00003", "v", id: 3)], at: 0)
        d.observe([invalid("00001"), digested("00003", "v", id: 3)], at: 1 * sec)
        d.observe([invalid("00001"), digested("00003", "v", id: 3)], at: 2 * sec)
        for tick in 3...28 {
            d.observe([invalid("00001"), iu("00003", id: 3)], at: UInt64(tick) * sec)
        }
        // Owner 1 vanishes at 29s with 29s owed; brand-new stalled 2 takes over.
        d.observe([absent("00001"), invalid("00002"), iu("00003", id: 3)], at: 29 * sec)
        // total >= 30e9 at t=30s and owner 2's base grace (0.1s) expired => accelerated
        // write-off IS allowed — but only with honest attribution.
        d.observe([invalid("00002"), iu("00003", id: 3)], at: 30 * sec)
        XCTAssertEqual(d.abandonLogs.count, 1)
        let line = d.abandonLogs[0].line
        let own = ownSeconds(in: line) ?? -1
        XCTAssertLessThanOrEqual(own, 2,
                                 "C2's lying log: own-time clause must be ~1s, not the inherited 30s: \(line)")
        XCTAssertTrue(line.contains("consumed predecessor debt") && line.contains("1=29.0s"),
                      "predecessor debt appears as its own labeled fact: \(line)")
    }

    // MARK: - Transient-occupant family

    // e1 — unrelated-lower emission must not clear a live stalled blocker's charge.
    // Provenance: round-6 R6-1 (57s hold), round-8 R8-1 + control table (RED on
    // 0ec11f8 and fe843eb; green on 6cb370a at 3.0s/30s). Spec §§5.1, M7.
    func test_e1_transientLowerEmissionDoesNotClearLiveStalledBlockerCharge() {
        var d = makeDriver()
        let sec: UInt64 = 1_000_000_000

        // Stalled 5 charges victim 6 from t=0 (victim ready by 2s).
        d.observe([invalid("00005"), digested("00006", "v", id: 6)], at: 0)
        d.observe([invalid("00005"), digested("00006", "v", id: 6)], at: 1 * sec)
        d.observe([invalid("00005"), digested("00006", "v", id: 6)], at: 2 * sec)
        d.observe([invalid("00005"), iu("00006", id: 6)], at: 19 * sec)
        // Transient lower 3 passes through the blocker slot (20s..22s) and emits.
        d.observe([digested("00003", "low", id: 3), invalid("00005"), iu("00006", id: 6)], at: 20 * sec)
        d.observe([digested("00003", "low", id: 3), invalid("00005"), iu("00006", id: 6)], at: 21 * sec)
        d.observe([digested("00003", "low", id: 3), invalid("00005"), iu("00006", id: 6)], at: 22 * sec)
        XCTAssertEqual(d.emitted.map(\.candidate.name), [revisionName("00003")])
        d.settleAll(.yielded)

        // Owner 5's 20s survives; its own accrual resumes at 23s => write-off by t=33s
        // (20 + (33-23) = 30). A scalar broad clear restarts and holds until ~52s.
        for tick in 23...32 {
            d.observe([invalid("00005"), iu("00006", id: 6)], at: UInt64(tick) * sec)
            XCTAssertTrue(d.abandonLogs.isEmpty)
        }
        d.observe([invalid("00005"), iu("00006", id: 6)], at: 33 * sec)
        XCTAssertEqual(d.abandonLogs.count, 1,
                       "e1: the live blocker's charge survived the transient's emission — bounded hold")
        XCTAssertEqual(d.reducer.state.generation.files[revisionName("00005")], .writtenOff)
    }

    // e7 — repeated adversarial lower arrivals; the hold must not grow per arrival.
    // Provenance: round-7 closed list (36.0s), round-8 R8-1 ("grows linearly with
    // adversarial arrivals — unbounded pattern"); control table: RED on 0ec11f8 and
    // fe843eb, green on 6cb370a. Spec §§4, 5.3.
    func test_e7_adversarialLowerArrivalsDoNotGrowTheStalledBlockersHold() {
        var d = makeDriver()
        let sec: UInt64 = 1_000_000_000

        d.observe([invalid("00008"), digested("00009", "v", id: 9)], at: 0)
        d.observe([invalid("00008"), digested("00009", "v", id: 9)], at: 1 * sec)
        d.observe([invalid("00008"), digested("00009", "v", id: 9)], at: 2 * sec)
        // Four adversarial cycles: lower k converges over 3 ticks and emits, each
        // pausing owner 8's accrual for its transient tenure + one barrier tick.
        var tick: UInt64 = 3
        for lower in ["00001", "00002", "00003", "00004"] {
            for _ in 0..<3 {
                d.observe([digested(lower, "low-\(lower)", id: Int64(lower)!),
                           invalid("00008"), iu("00009", id: 9)], at: tick * sec)
                tick += 1
            }
            d.settleAll(.yielded)
        }
        // Owner 8 charged 0..3, then per cycle its segment pauses ~2 transient ticks +
        // 1 barrier tick; accrual = wall - 4*3 = wall - 12. Budget reached at wall 42s.
        while tick <= 41 {
            d.observe([invalid("00008"), iu("00009", id: 9)], at: tick * sec)
            XCTAssertTrue(d.abandonLogs.isEmpty,
                          "premature write-off at t=\(tick)s — transient inherited the charge")
            tick += 1
        }
        d.observe([invalid("00008"), iu("00009", id: 9)], at: 42 * sec)
        XCTAssertEqual(d.abandonLogs.count, 1,
                       "e7: bounded at budget + per-cycle pause cost; scalar builds grow per arrival")
    }

    // MARK: - Identity family

    // h3 — owner padding-renames during the victim's absence; its emission must still
    // redeem. Provenance: round-8 R8-2 + control table (RED on all three: 9.0s).
    // Spec §3.1 (RevisionKey normalization).
    // DISCRIMINATIVE INGREDIENTS (broadened from the R8-2 shape after control runs):
    // (1) the fresh stalled blocker 00009 arrives in the SAME observe batch where the
    // renamed owner 007 emits — the episode is already re-assigned, so scalar builds
    // never reach their dissolution-time clears; (2) the victim STAYS PRESENT — an
    // absent victim dissolves the episode and round-6's over-broad ordering clear
    // then wipes the clock (accidental green). Red mechanisms per sha are recorded in
    // the reconciliation doc; the segment-green half proves padding-normalized
    // owner redemption.
    func test_h3_paddingRenameDuringAbsenceStillRedeemsOnEmission() {
        var d = makeDriver()
        let sec: UInt64 = 1_000_000_000

        // Owner "7" (unpadded) charges victim 10 for 10s; victim ready by 2s.
        // Victim revision 00010 sits ABOVE both the owner (7) and the fresh
        // stalled blocker (00009), so it stays genuinely blocked throughout.
        d.observe([invalid("7"), digested("00010", "v", id: 10)], at: 0)
        d.observe([invalid("7"), digested("00010", "v", id: 10)], at: 1 * sec)
        d.observe([invalid("7"), digested("00010", "v", id: 10)], at: 2 * sec)
        d.observe([invalid("7"), iu("00010", id: 10)], at: 9 * sec)
        // The victim STAYS PRESENT through the rename (essential: an absent victim
        // dissolves the episode on scalar builds, letting round-6's over-broad
        // ordering clear wipe the clock and go green by accident). The owner is
        // renamed to "007" and converges (10s..12s); stalled 00009 arrives in the
        // SAME batch as 007's third sighting/emission at t=12.
        d.observe([digested("007", "done", id: 7), iu("00010", id: 10)], at: 10 * sec)
        d.observe([digested("007", "done", id: 7), iu("00010", id: 10)], at: 11 * sec)
        d.observe([digested("007", "done", id: 7), invalid("00009"), iu("00010", id: 10)], at: 12 * sec)
        XCTAssertEqual(d.emitted.map(\.candidate.name), [revisionName("007")])
        d.settleAll(.yielded)

        // Segment-model accrual: the victim charges RUNNING under owner 7/007 from
        // t=0 to t=12 (12s; padding rename keeps the same RevisionKey). At t=12 the
        // pending-emission barrier pauses charging; 007's yielded settlement redeems
        // ALL owner-7 segments (RevisionKey("007") == RevisionKey("7") — the h3
        // property). 00009 first-charges at t=13; unredeemed total = t-13 reaches the
        // 30s budget exactly at t=43 => no write-off before then. Scalar builds retain
        // the stale ~12s (r6: episode-alive skips the clear; r7: running clocks are
        // never paused so the paused-only clear misses; r8: charge re-stamped to the
        // transient blocker defeats equality) => premature write-off ~t=30, in-loop.
        for tick in 13...42 {
            d.observe([invalid("00009"), digested("00010", "v", id: 10)], at: UInt64(tick) * sec)
            XCTAssertTrue(d.abandonLogs.isEmpty,
                          "h3: stale unredeemed padding-variant debt shortened the fresh budget (t=\(tick)s)")
        }
        d.observe([invalid("00009"), digested("00010", "v", id: 10)], at: 43 * sec)
        XCTAssertEqual(d.abandonLogs.count, 1)
    }

    // h4 — same-batch present handoff. Provenance: round-8 R8-3 + control table
    // (RED on all three: 8.0s, no flicker needed). Spec §4 (pending-emission barrier).
    func test_h4_sameBatchPresentHandoffDoesNotInheritRedeemedTime() {
        var d = makeDriver()
        let sec: UInt64 = 1_000_000_000

        d.observe([digested("00001", "c0", id: 1), digested("00003", "v", id: 3)], at: 0)
        d.observe([digested("00001", "c1", id: 1), digested("00003", "v", id: 3)], at: 1 * sec)
        d.observe([digested("00001", "c2", id: 1), digested("00003", "v", id: 3)], at: 2 * sec)
        d.observe([digested("00001", "final", id: 1), iu("00003", id: 3)], at: 24 * sec)
        // Handoff batch at 25s: 1 ready+emits, stalled 2 arrives, victim PRESENT.
        d.observe([digested("00001", "final", id: 1), invalid("00002"), iu("00003", id: 3)], at: 25 * sec)
        XCTAssertEqual(d.emitted.map(\.candidate.name), [revisionName("00001")])
        d.settleAll(.yielded)

        // Successor 2 charges from 26s => no write-off before t=56s.
        for tick in 26...55 {
            d.observe([invalid("00002"), iu("00003", id: 3)], at: UInt64(tick) * sec)
            XCTAssertTrue(d.abandonLogs.isEmpty,
                          "h4: same-batch handoff inherited the old owner's 25s (t=\(tick)s)")
        }
        d.observe([invalid("00002"), iu("00003", id: 3)], at: 56 * sec)
        XCTAssertEqual(d.abandonLogs.count, 1)
    }

    // S9 — settled lower REWRITTEN IN PLACE below a stalled blocker: the pending-
    // emission barrier must defer only work that DEPENDS on the pending owner (§4),
    // never pause the stalled blocker's own running charge. Provenance: round-9 cold
    // review R9-F1 (S9 probe: 44s wall-clock present-and-blocked vs [budget=30s,
    // ceiling=32s]); the rewriter never occupies the head-blocker slot, so its
    // recurring emission cycle must cost the victim nothing.
    // Expected on scalar controls: RED (broad clears/hijacks, no owner-keyed segments).
    func test_S9_inPlaceRewritingLowerDoesNotDelayStalledBlockerWriteOff() {
        var d = makeDriver()
        let sec: UInt64 = 1_000_000_000

        // Establish r_1 as a settled emission (ticks 0-2; three-sighting digest gate).
        d.observe([digested("00001", "v0", id: 1)], at: 0)
        d.observe([digested("00001", "v0", id: 1)], at: 1 * sec)
        d.observe([digested("00001", "v0", id: 1)], at: 2 * sec)
        XCTAssertEqual(d.emitted.map(\.candidate.name), [revisionName("00001")])
        d.settleAll(.yielded)

        // From t=3: stalled 2 + victim 3 (present and blocked EVERY tick from t=3, so
        // cumulative present-and-blocked wall time = t-3), while settled r_1 is
        // rewritten in place on a 3-tick cycle (replacement observing → digestPending
        // → ready+emit at every t ≡ 2 (mod 3) from t=5). r_1 never re-enters numbered
        // ordering while unready (settled files do not participate), so owner 2's
        // segment must charge CONTINUOUSLY from t=3: unredeemed total reaches the 30s
        // budget at t=33 (grace 0.1s long expired; t=33 is not a barrier tick).
        // Defective barrier (whole-ledger pause each emission tick) accrues 2s per
        // 3-tick cycle => write-off slips to t=48 (45s of wall), past ceiling+tick.
        var rewriteEmissions = 0
        var tick: UInt64 = 3
        while tick <= 60 {
            let version = Int((tick - 3) / 3) + 1
            d.observe([
                digested("00001", "rw-\(version)", id: Int64(100 + version)),
                invalid("00002"),
                digested("00003", "v", id: 3),
            ], at: tick * sec)
            rewriteEmissions += d.emitted.filter { $0.candidate.name == revisionName("00001") }.count
            d.settleAll(.yielded)
            if !d.abandonLogs.isEmpty { break }
            tick += 1
        }
        XCTAssertGreaterThanOrEqual(rewriteEmissions, 8,
                                    "probe shape: the settled lower must emit repeatedly while 2 stalls")
        XCTAssertEqual(d.abandonLogs.count, 1, "stalled 2 must be written off (S9)")
        let wallNanos = d.abandonLogs[0].nanos - 3 * sec
        XCTAssertGreaterThanOrEqual(wallNanos, 30 * sec,
                                    "write-off before the victim's own budget of present-and-blocked time")
        XCTAssertLessThanOrEqual(wallNanos, 30 * sec + 400_000_000 + 1 * sec,
                                 "S9/R9-F1: \(Double(wallNanos) / 1e9)s of present-and-blocked wall time "
                                     + "exceeds ceiling (30.4s) + one poll tick — the barrier paused the "
                                     + "non-pending owner's running segment on every rewrite emission")
        XCTAssertEqual(d.reducer.state.generation.files[revisionName("00002")], .writtenOff)
        let line = d.abandonLogs[0].line
        XCTAssertEqual(ownSeconds(in: line), 30, "owner 2's own attributed time is the full budget: \(line)")
        XCTAssertFalse(line.contains("consumed predecessor debt"),
                       "no predecessor debt exists in this shape: \(line)")
        // The write-off frees the victim in the same pass.
        guard case .settled(.emittedNow)? = d.reducer.state.generation.files[revisionName("00003")] else {
            return XCTFail("victim 3 must emit once the written-off blocker is gone")
        }
    }

    // S4 — padding twin of a WRITTEN-OFF owner. Provenance: round-9 cold review R9-F2:
    // write-off consumed only the justifying victim's ledger copy; the surviving copy
    // under the other victim handed twin r_05 (same RevisionKey) the dead owner's
    // firstChargeNanos => written off 0.0s after appearing, "blocked for 30s" logged,
    // consumedSegments=[] — the same stall billed twice, second frame lost (M2/M9).
    // Round-9 interpretation of spec §4 step 3: write-off consumes the abandoned
    // owner's segments across ALL victims' ledgers. Expected on scalar controls: RED.
    func test_S4_paddingTwinOfWrittenOffOwnerGetsFreshBudgetAndHonestAttribution() {
        var d = makeDriver()
        let sec: UInt64 = 1_000_000_000

        // Phase 1: stalled 5 blocks victims 6 (unready — the numerically-first
        // justifier) and 7 (ready by t=2) from t=0; both charge under owner 5.
        for tick in 0...29 {
            d.observe([invalid("00005"), invalid("00006"), digested("00007", "v", id: 7)],
                      at: UInt64(tick) * sec)
            XCTAssertTrue(d.abandonLogs.isEmpty, "premature write-off of 5 at t=\(tick)s")
        }
        d.observe([invalid("00005"), invalid("00006"), digested("00007", "v", id: 7)], at: 30 * sec)
        XCTAssertEqual(d.abandonLogs.count, 1, "owner 5 written off at exactly one budget")
        XCTAssertEqual(d.reducer.state.generation.files[revisionName("00005")], .writtenOff)
        XCTAssertEqual(ownSeconds(in: d.abandonLogs[0].line), 30)

        // Phase 2: twin 005 (RevisionKey "5" — the written-off owner's key) arrives
        // stalling at t=31 and heads the line over 6 and 7. Its budget/grace must
        // anchor at ITS first charge (t=31). Ledger 7 legitimately carries 1s of
        // owner-6 debt (6 headed during t=30..31 and never emitted), so ledger 7
        // reaches budget at t=60: 29s of twin tenure + 1s consumed from 6 — the twin
        // survives its own budget less only the NAMED predecessor second. A surviving
        // owner-5 copy (R9-F2 defect) instead fires at t=31 with a lying 30s log.
        for tick in 31...59 {
            d.observe([invalid("005"), invalid("00006"), digested("00007", "v", id: 7)],
                      at: UInt64(tick) * sec)
            XCTAssertEqual(d.abandonLogs.count, 1,
                           "twin written off after \(tick - 31)s of own tenure — inherited the "
                               + "dead owner's segment copy (R9-F2); log: \(d.abandonLogs.last?.line ?? "")")
        }
        d.observe([invalid("005"), invalid("00006"), digested("00007", "v", id: 7)], at: 60 * sec)
        XCTAssertEqual(d.abandonLogs.count, 2, "twin write-off lands when ITS OWN ledger justifies it")
        let line = d.abandonLogs[1].line
        XCTAssertEqual(ownSeconds(in: line), 29,
                       "own-time clause is the twin's own tenure (t=31..60), never the dead owner's 30s: \(line)")
        XCTAssertTrue(line.contains("consumed predecessor debt") && line.contains("6=1.0s"),
                      "the 1s of owner-6 debt is named as a separate fact: \(line)")
        XCTAssertEqual(d.reducer.state.generation.files[revisionName("005")], .writtenOff)
    }

    // c3 + padding twins — victim identity churn between padding variants stays
    // bounded, each twin holding its own filename-keyed ledger. Provenance: rounds 4-6
    // ("identity churn r_10<->r_010 ... bounded (62.0s)"), round-6 "padding twins get
    // their own budgets". Spec §§3.1, 5.2.
    func test_c3_victimPaddingChurnBehindStalledBlockerStaysBounded() {
        var d = makeDriver()
        let sec: UInt64 = 1_000_000_000

        // Stalled 9 blocks; the victim alternates names 10 / 010 every tick, so each
        // twin accrues ~half the wall time. Either ledger reaches 30s by wall ~60s;
        // assert write-off of 9 by the round-6 bound of 62s.
        var tick: UInt64 = 0
        while tick <= 62 {
            let twin = tick.isMultiple(of: 2) ? "10" : "010"
            let gone  = tick.isMultiple(of: 2) ? "010" : "10"
            d.observe([invalid("00009"),
                       digested(twin, "v", id: 10),
                       absent(gone)], at: tick * sec)
            if !d.abandonLogs.isEmpty { break }
            tick += 1
        }
        XCTAssertFalse(d.abandonLogs.isEmpty,
                       "c3: alternating padding-twin victims must not starve forever")
        XCTAssertLessThanOrEqual(d.abandonLogs[0].nanos, 62 * sec,
                                 "bounded at ~2x budget under 50% alternation (round-6: 62.0s)")
        XCTAssertEqual(d.reducer.state.generation.files[revisionName("00009")], .writtenOff)
    }

    // MARK: - Lifecycle family

    // S5 — victim flicker (absent 1 scan in 5) must not starve. Provenance: round-1 S5
    // via round-4 W4-2 ("never emitted in 800s"), round-5 "emits at 33-40s". Spec M1/M3.
    func test_S5_victimFlickerPausesButStillReachesWriteOffWithinCeiling() {
        var d = makeDriver()
        let sec: UInt64 = 1_000_000_000

        var tick: UInt64 = 0
        while tick <= 40 {
            let victimObservation = tick % 5 == 4
                ? absent("00002")
                : digested("00002", "v", id: 2)
            d.observe([invalid("00001"), victimObservation], at: tick * sec)
            if !d.abandonLogs.isEmpty { break }
            tick += 1
        }
        XCTAssertFalse(d.abandonLogs.isEmpty, "S5: flickering victim starved (no write-off by 40s)")
        XCTAssertLessThanOrEqual(d.abandonLogs[0].nanos, 40 * sec,
                                 "cumulative present-blocked time bounds the hold (round-5: 33-40s)")
        // The victim emits once the corpse is gone and its digest gate re-earns.
        let t = d.abandonLogs[0].nanos / sec
        d.observe([digested("00002", "v", id: 2)], at: (t + 1) * sec)
        d.observe([digested("00002", "v", id: 2)], at: (t + 2) * sec)
        d.observe([digested("00002", "v", id: 2)], at: (t + 3) * sec)
        XCTAssertTrue(d.emitted.map(\.candidate.name).contains(revisionName("00002")))
    }

    // b1 / W4-2a — a long unblocked stretch precedes a fresh blocker: no stale debt
    // may shorten the fresh budget. Provenance: round-4 W4-2a; closed since round 5,
    // expected GREEN on all controls. Spec §5.2.
    func test_b1_freshBlockerAfterLongUnblockedStretchGetsFullBudget() {
        var d = makeDriver()
        let sec: UInt64 = 1_000_000_000

        // Early episode: stalled 1 charges victim 2 for 10s, then 1 vanishes and the
        // victim emits (present and unblocked).
        d.observe([invalid("00001"), digested("00002", "v", id: 2)], at: 0)
        d.observe([invalid("00001"), digested("00002", "v", id: 2)], at: 1 * sec)
        d.observe([invalid("00001"), digested("00002", "v", id: 2)], at: 2 * sec)
        d.observe([invalid("00001"), iu("00002", id: 2)], at: 10 * sec)
        d.observe([absent("00001"), iu("00002", id: 2)], at: 11 * sec)
        XCTAssertEqual(d.emitted.map(\.candidate.name), [revisionName("00002")])
        d.settleAll(.yielded)

        // 90 quiet seconds later a fresh stalled 3 blocks new victim 4: full budget.
        d.observe([invalid("00003"), digested("00004", "v", id: 4)], at: 100 * sec)
        d.observe([invalid("00003"), digested("00004", "v", id: 4)], at: 101 * sec)
        d.observe([invalid("00003"), digested("00004", "v", id: 4)], at: 102 * sec)
        for tick in 103...129 {
            d.observe([invalid("00003"), iu("00004", id: 4)], at: UInt64(tick) * sec)
            XCTAssertTrue(d.abandonLogs.isEmpty,
                          "b1: stale pre-stretch debt shortened the fresh budget (t=\(tick)s)")
        }
        d.observe([invalid("00003"), iu("00004", id: 4)], at: 130 * sec)
        XCTAssertEqual(d.abandonLogs.count, 1, "write-off exactly one budget after the fresh first charge")
    }

    // e9 + barrier cost — a stream of resolving lower emissions delays the stalled
    // blocker's write-off only by the per-cycle pause cost; the bound is linear with
    // NO compounding reset, identical shape at higher cycle counts. Provenance:
    // round-7 e9 ("bounded at 48.0s, identical at 20/60/100 cycles"), spec §§4, 5.3.
    func test_e9_writeOffBoundGrowsOnlyByPerCyclePauseCostNeverResets() {
        let sec: UInt64 = 1_000_000_000
        // Blocker 00030 / victim 00040 keep every transient lower (up to 00020)
        // genuinely BELOW the blocker at all three cycle counts.
        for cycles in [2, 5, 20] {
            var d = makeDriver()
            d.observe([invalid("00030"), digested("00040", "v", id: 40)], at: 0)
            d.observe([invalid("00030"), digested("00040", "v", id: 40)], at: 1 * sec)
            d.observe([invalid("00030"), digested("00040", "v", id: 40)], at: 2 * sec)
            var tick: UInt64 = 3
            for lower in 1...cycles {
                let revision = String(format: "%05d", lower)
                for _ in 0..<3 {
                    d.observe([digested(revision, "low-\(lower)", id: Int64(lower)),
                               invalid("00030"), iu("00040", id: 40)], at: tick * sec)
                    tick += 1
                }
                d.settleAll(.yielded)
            }
            // Owner 30's accrual = wall - 3*cycles; budget reached at 30 + 3*cycles.
            let bound = UInt64(30 + 3 * cycles)
            while tick < bound {
                d.observe([invalid("00030"), iu("00040", id: 40)], at: tick * sec)
                XCTAssertTrue(d.abandonLogs.isEmpty,
                              "cycles=\(cycles): premature write-off at t=\(tick)s")
                tick += 1
            }
            d.observe([invalid("00030"), iu("00040", id: 40)], at: bound * sec)
            XCTAssertEqual(d.abandonLogs.count, 1,
                           "cycles=\(cycles): bound is budget + per-cycle cost — no compounding, no reset")
        }
    }
}
