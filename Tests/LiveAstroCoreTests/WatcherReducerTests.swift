import XCTest
@testable import LiveAstroCore

/// Transition-table unit tests for the pure watcher reducer (phase 1 task 1) — synthetic
/// observations only, zero filesystem. Each of the four required pins (spec §2.6 pins 1–4)
/// gets dedicated tests, plus the review-12 P1 scenarios and the four cold2/review-11
/// deadline behaviors in reducer form. The reducer is exercised through a tiny harness that
/// threads (states, dedup table, episode, manual monotonic clock) across passes exactly the
/// way the ported scan loop will.
final class WatcherReducerTests: XCTestCase {

    // MARK: Harness

    private static let q: UInt64 = 1_000_000_000            // quiet period: 1 s
    private static let budget: UInt64 = 30 * q               // blocking budget: 30 s
    private static let ceiling: UInt64 = 34 * q               // budget + 4×quiet

    private func makeConfig(_ policy: StackFileWatcher.DigestPolicy = .mutableStackerOutput)
        -> WatcherReducerConfig {
        WatcherReducerConfig(digestPolicy: policy, quietPeriodNanos: Self.q,
                             blockingBudgetNanos: Self.budget, blockingGraceNanos: Self.q,
                             blockingCeilingNanos: Self.ceiling)
    }

    /// Threads reducer state across passes with a manual monotonic clock.
    private struct Harness {
        var states: [String: FileState] = [:]
        var dedup: [String: String] = [:]
        var episode: BlockingEpisode? = nil
        var now: UInt64 = 100_000_000_000
        let config: WatcherReducerConfig

        @discardableResult
        mutating func pass(_ observations: [FileObservation]) -> WatcherReducer.PassResult {
            let r = WatcherReducer.reduce(states: states, observations: observations,
                                          nowNanos: now,
                                          lastEmittedDigestByName: dedup,
                                          episode: episode, config: config)
            states = r.states
            dedup = r.lastEmittedDigestByName
            episode = r.episode
            return r
        }

        mutating func advance(seconds: Double) { now += UInt64(seconds * 1_000_000_000) }
    }

    private func harness(_ policy: StackFileWatcher.DigestPolicy = .mutableStackerOutput)
        -> Harness { Harness(config: makeConfig(policy)) }

    // MARK: Observation/identity factories

    private func ident(_ n: UInt64, size: Int = 512) -> FileIdentity {
        FileIdentity(dev: 1, ino: n, size: size, mtimeSec: Int64(n), mtimeNsec: Int64(n % 7))
    }

    private func rev(of name: String) -> String? {
        // Test-side convenience mirroring the watcher's parser output for live_stack_<d>.fit.
        guard name.hasPrefix("live_stack_"), name.hasSuffix(".fit") else { return nil }
        let digits = name.dropFirst("live_stack_".count).dropLast(".fit".count)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return String(digits)
    }

    private func absent(_ name: String) -> FileObservation {
        FileObservation(name: name, revision: rev(of: name), kind: .absent)
    }
    private func invalid(_ name: String,
                         _ why: FileObservation.Invalidity = .incompleteHeader) -> FileObservation {
        FileObservation(name: name, revision: rev(of: name), kind: .invalid(why))
    }
    private func statOnly(_ name: String, _ id: FileIdentity) -> FileObservation {
        FileObservation(name: name, revision: rev(of: name), kind: .statOnly(id))
    }
    private func content(_ name: String, _ id: FileIdentity, _ digest: String) -> FileObservation {
        FileObservation(name: name, revision: rev(of: name), kind: .content(stat: id, digest: digest))
    }

    private let classic = "live_stack.fit"
    private let f1 = "live_stack_00001.fit"
    private let f2 = "live_stack_00002.fit"
    private let f3 = "live_stack_00003.fit"
    private let f4 = "live_stack_00004.fit"
    private let f5 = "live_stack_00005.fit"

    /// Drive one file through sighting → pending → confirmed emission (mutable policy).
    private func emit(_ h: inout Harness, _ name: String, _ id: FileIdentity,
                      _ digest: String, file: StaticString = #filePath, line: UInt = #line) {
        h.pass([statOnly(name, id)])
        h.advance(seconds: 2)
        h.pass([content(name, id, digest)])
        h.advance(seconds: 2)
        let r = h.pass([content(name, id, digest)])
        XCTAssertEqual(r.emissions.map(\.name), [name],
                       "arrange: \(name) must emit", file: file, line: line)
    }

    // MARK: - Pin 1: episode invariant (blocking as a derived property)

    /// No victims ⇒ no episode: a lone failing revision starves nobody, so its clock never
    /// starts. The episode begins only when a later never-emitted revision appears.
    func testEpisode_startsOnlyWhenLaterVictimPresent() {
        var h = harness()
        h.pass([statOnly(f1, ident(1))])
        XCTAssertNil(h.episode, "a lone failing revision must not start an episode")

        h.advance(seconds: 2)
        h.pass([statOnly(f1, ident(2)), statOnly(f2, ident(100))])
        XCTAssertEqual(h.episode?.blocker, f1)
        XCTAssertEqual(h.episode?.startNanos, h.now,
                       "the episode clock starts when blocking begins, not at first sight")
    }

    /// Cold2 I1 in reducer form: lone-period teardown + fresh clock per episode. The lone
    /// wall time — however long — must never be charged; a returning blocking episode gets
    /// a full fresh budget.
    func testEpisode_lonePeriodTeardown_freshClockPerEpisode_noWriteOff() {
        var h = harness()
        h.pass([statOnly(f1, ident(1)), statOnly(f2, ident(100))])
        h.advance(seconds: 2)
        h.pass([statOnly(f1, ident(2)), statOnly(f2, ident(100))])
        XCTAssertNotNil(h.episode, "arrange: blocking episode running")

        // _00002 vanishes: nobody is blocked — the episode dies with its clock.
        h.advance(seconds: 2)
        h.pass([statOnly(f1, ident(3))])
        XCTAssertNil(h.episode, "lone-period teardown is load-bearing (cold2 I1)")

        // A lone period far past budget AND ceiling must not count.
        h.advance(seconds: 100_000)
        var r = h.pass([statOnly(f1, ident(4))])
        XCTAssertTrue(r.logs.isEmpty, "a lone in-progress revision is never written off")

        // A new blocking episode begins: FRESH clock, no instant write-off.
        h.advance(seconds: 2)
        r = h.pass([statOnly(f1, ident(5)), statOnly(f3, ident(300))])
        XCTAssertTrue(r.logs.isEmpty, "the returning blocker starts a fresh clock")
        XCTAssertEqual(h.episode?.blocker, f1)
        XCTAssertEqual(h.episode?.startNanos, h.now, "episode 2 runs its own clock")

        // The blocker completes inside the fresh budget → [1, 3] in order, no write-off.
        h.advance(seconds: 2)
        h.pass([content(f1, ident(5), "d1"), content(f3, ident(300), "d3")])
        h.advance(seconds: 2)
        r = h.pass([content(f1, ident(5), "d1"), content(f3, ident(300), "d3")])
        XCTAssertEqual(r.emissions.map(\.name), [f1, f3],
                       "order preserved — the fresh episode budget was honored")
        XCTAssertNil(h.episode)
    }

    /// Review11 in reducer form: identity churn NEVER resets the deadline under continuous
    /// blocking — write-off lands exactly at the budget, with the honest log line, and the
    /// hold releases in the SAME pass so held revisions emit immediately.
    func testEpisode_churnNeverResets_writtenOffAtBudget_victimEmitsSamePass() {
        var h = harness()
        h.pass([statOnly(f1, ident(1)), statOnly(f2, ident(100))])
        let episodeStart = h.now
        // Earn _00002's gates while _00001 churns (new identity every pass).
        h.advance(seconds: 2)
        h.pass([statOnly(f1, ident(2)), content(f2, ident(100), "d2")])
        h.advance(seconds: 2)
        var r = h.pass([statOnly(f1, ident(3)), content(f2, ident(100), "d2")])
        XCTAssertTrue(r.emissions.isEmpty, "_00002 held while _00001 blocks")
        XCTAssertEqual(h.states[f2], .ready(digest: "d2", identity: ident(100),
                                            firstObservedNanos: episodeStart + 2 * Self.q),
                       "held revision keeps its earned gate evidence")

        var churn: UInt64 = 4
        var passes = 0
        while h.now - episodeStart < Self.budget, passes < 40 {
            h.advance(seconds: 2)
            r = h.pass([statOnly(f1, ident(churn)), content(f2, ident(100), "d2")])
            churn += 1
            passes += 1
        }
        // The loop exits on the pass where now-start reached the budget: that pass wrote off.
        XCTAssertEqual(h.states[f1], .writtenOff)
        XCTAssertEqual(r.logs, ["revision 00001 blocked emissions for 30s without completing "
                                + "— abandoning it; later revisions proceed (frame lost: \(f1))"],
                       "honest write-off log, exact episode duration — churn never extended it")
        XCTAssertEqual(r.emissions.map(\.name), [f2],
                       "the hold releases in the write-off pass — the victim emits immediately")
        XCTAssertNil(h.episode)

        // The written-off revision is dead this generation: perfect content never emits,
        // the log never repeats.
        h.advance(seconds: 2)
        h.pass([content(f1, ident(churn), "good"), statOnly(f2, ident(100))])
        h.advance(seconds: 2)
        r = h.pass([content(f1, ident(churn), "good"), statOnly(f2, ident(100))])
        XCTAssertTrue(r.emissions.isEmpty, "a written-off revision must never emit")
        XCTAssertTrue(r.logs.isEmpty, "the write-off line fires once, not per pass")
        XCTAssertEqual(h.states[f1], .writtenOff)
    }

    /// Review11 hard ceiling in reducer form: repeated converging grace (same pending digest
    /// re-observed inside the quiet period) renews the deadline, but the TOTAL hold is capped
    /// at budget + 4×quiet. Never written off before the budget; written off by the ceiling.
    func testEpisode_convergingGraceRenewed_writtenOffAtHardCeiling() {
        var h = harness()
        h.pass([statOnly(f1, ident(1)), statOnly(f2, ident(100))])
        let start = h.now
        var logs: [String] = []
        var ino: UInt64 = 2
        var cycles = 0
        while logs.isEmpty, cycles < 60 {      // hard bound: a red run must terminate
            cycles += 1
            // churn: new identity (re-earn stability)
            h.advance(seconds: 0.4)
            logs += h.pass([statOnly(f1, ident(ino)), statOnly(f2, ident(100))]).logs
            if !logs.isEmpty { break }
            // stable → new pending digest
            h.advance(seconds: 0.4)
            logs += h.pass([content(f1, ident(ino), "d\(ino)"), statOnly(f2, ident(100))]).logs
            if !logs.isEmpty { break }
            // same digest again inside the quiet period → CONVERGING (grace renews)
            h.advance(seconds: 0.4)
            logs += h.pass([content(f1, ident(ino), "d\(ino)"), statOnly(f2, ident(100))]).logs
            ino += 1
        }
        XCTAssertFalse(logs.isEmpty, "the ceiling must fire despite repeated converging grace")
        guard !logs.isEmpty else { return }
        let elapsed = h.now - start
        XCTAssertGreaterThanOrEqual(elapsed, Self.budget,
                                    "never written off before the budget — grace was honored")
        XCTAssertLessThanOrEqual(elapsed, Self.ceiling + 2 * Self.q,
                                 "written off no later than the ceiling (+ one cycle of slack)")
        XCTAssertEqual(h.states[f1], .writtenOff)
        XCTAssertNil(h.episode)
    }

    /// Cold2 I1 log-honesty half: the write-off log reports the EPISODE's duration, never
    /// the preceding lone period's wall time.
    func testEpisode_writeOffLogReportsEpisodeDuration_notLoneWallTime() {
        var h = harness()
        h.pass([statOnly(f1, ident(1)), statOnly(f2, ident(100))])   // episode 1, briefly
        h.advance(seconds: 2)
        h.pass([statOnly(f1, ident(2))])                              // _00002 gone → lone
        let loneSeconds: Double = 100_000
        h.advance(seconds: loneSeconds)
        h.pass([statOnly(f1, ident(3))])                              // still lone — uncharged

        h.advance(seconds: 2)
        h.pass([statOnly(f1, ident(4)), statOnly(f3, ident(300))])    // episode 2 — fresh clock
        var line: String?
        var ino: UInt64 = 5
        var passes = 0
        while line == nil, passes < 40 {       // hard bound: a red run must terminate
            passes += 1
            h.advance(seconds: 2)
            line = h.pass([statOnly(f1, ident(ino)), statOnly(f3, ident(300))]).logs.first
            ino += 1
        }
        XCTAssertNotNil(line, "episode 2 must exhaust its own budget and log the write-off")
        guard line != nil else { return }
        let held = Int(line!.components(separatedBy: "blocked emissions for ").last!
            .components(separatedBy: "s ").first ?? "") ?? -1
        XCTAssertGreaterThanOrEqual(held, 30, "the full episode budget was honored — got \(line!)")
        XCTAssertLessThan(Double(held), loneSeconds,
                          "heldSeconds reports the EPISODE's hold, never lone wall time — got \(line!)")
    }

    /// Review-12 P1-2 in reducer form: a role round-trip (blocker → victim → blocker) can
    /// never inherit a clock — there is no per-name map to inherit from. Pre-fix, _00002's
    /// deadline (acquired as blocker) survived its victim period and expired, so it was
    /// written off the instant it blocked again.
    func testEpisode_roleRoundTrip_neverInheritsClock() {
        var h = harness()
        h.pass([statOnly(f2, ident(20)), statOnly(f3, ident(30))])
        let firstStart = h.now
        XCTAssertEqual(h.episode?.blocker, f2, "arrange: _00002 is the blocker")

        // Almost the whole budget elapses, then _00001 appears: head-of-line moves down,
        // _00002 becomes a queued victim, and the episode is _00001's with a FRESH clock.
        h.advance(seconds: 29)
        h.pass([statOnly(f1, ident(1)), statOnly(f2, ident(21)), statOnly(f3, ident(31))])
        XCTAssertEqual(h.episode?.blocker, f1)
        XCTAssertEqual(h.episode?.startNanos, h.now, "the new episode runs its own clock")

        // _00001 vanishes; _00002 is the blocker again. Its total wall time as a tracked
        // name now exceeds the budget — but the round trip must yield a FRESH clock.
        h.advance(seconds: 2)
        let r = h.pass([statOnly(f2, ident(22)), statOnly(f3, ident(32))])
        XCTAssertTrue(r.logs.isEmpty,
                      "no instant write-off — a role round-trip must not inherit a spent clock")
        XCTAssertEqual(h.episode?.blocker, f2)
        XCTAssertEqual(h.episode?.startNanos, h.now)
        XCTAssertGreaterThan(h.now, firstStart + Self.budget,
                             "sanity: an inherited clock WOULD have expired here")
        XCTAssertNotEqual(h.states[f2], .writtenOff)
    }

    /// Pin 1, duplicate-settling-while-held: a held revision that settles as
    /// duplicateOfLastEmission stops counting as a victim and ends the episode (the dedup
    /// guard runs before the holdback).
    func testEpisode_heldVictimSettlesDuplicate_episodeEnds() {
        var h = harness()
        h.dedup[f2] = "d2"          // content already delivered (earlier generation)
        h.pass([statOnly(f1, ident(1)), statOnly(f2, ident(100))])
        XCTAssertEqual(h.episode?.blocker, f1, "arrange: episode running")

        h.advance(seconds: 2)
        let r = h.pass([statOnly(f1, ident(2)), content(f2, ident(100), "d2")])
        XCTAssertEqual(h.states[f2], .settled(.duplicateOfLastEmission(identity: ident(100))),
                       "the held victim settles as a duplicate despite the hold")
        XCTAssertTrue(r.emissions.isEmpty)
        XCTAssertNil(h.episode, "no nonterminal victim remains — lone teardown applies")
    }

    // MARK: - Pin 2: per-state absence semantics

    func testAbsence_pendingStatesDie() {
        var h = harness()
        h.states = [
            "a.fit": .observing(stat: ident(1)),
            "b.fit": .digestPending(digest: "d", identity: ident(2), firstObservedNanos: h.now),
            "c.fit": .ready(digest: "d", identity: ident(3), firstObservedNanos: h.now),
        ]
        h.pass([absent("a.fit"), absent("b.fit"), absent("c.fit")])
        XCTAssertTrue(h.states.isEmpty,
                      "observing/digestPending/ready die on absence — pending evidence dies")
    }

    func testAbsence_terminalStatesImmortalWithinGeneration() {
        var h = harness()
        let terminal: [String: FileState] = [
            "d.fit": .settled(.emittedNow(identity: ident(4))),
            "e.fit": .settled(.duplicateOfLastEmission(identity: ident(5))),
            "f.fit": .droppedOutOfOrder,
            "g.fit": .writtenOff,
        ]
        h.states = terminal
        let r = h.pass([absent("d.fit"), absent("e.fit"), absent("f.fit"), absent("g.fit")])
        XCTAssertEqual(h.states, terminal,
                       "settled/dropped/writtenOff are immortal within the generation")
        XCTAssertTrue(r.logs.isEmpty, "dropped stays dropped silently — log-once holds")
    }

    /// The high-water mark is DERIVED from settled(.emittedNow), so deleting an emitted
    /// revision cannot regress it: a lower revision arriving after the deletion is still
    /// rejected below the mark.
    func testAbsence_deletedEmittedRevision_markDoesNotRegress() {
        var h = harness()
        emit(&h, f5, ident(50), "d5")
        h.advance(seconds: 2)
        let r = h.pass([absent(f5), statOnly(f4, ident(40))])   // _00005 deleted, _00004 late
        XCTAssertEqual(h.states[f5], .settled(.emittedNow(identity: ident(50))),
                       "the emitted corpse is immortal within the generation")
        XCTAssertEqual(h.states[f4], .droppedOutOfOrder)
        XCTAssertEqual(r.logs,
                       ["revision 00004 arrived out of order — skipped (high-water 00005)"],
                       "the derived mark survives the deletion")
    }

    // MARK: - Pin 3: settlements carry FileIdentity and arm the fast-path

    func testSettlements_bothCarryObservedIdentity() {
        var h = harness()
        emit(&h, f1, ident(7), "dA")
        XCTAssertEqual(h.states[f1], .settled(.emittedNow(identity: ident(7))),
                       "the emission settlement carries the observed stat identity")
        XCTAssertEqual(h.dedup[f1], "dA")

        // New generation (caller clears states + episode; dedup survives). The identical
        // content re-appears under a new identity: it settles duplicateOfLastEmission with
        // the NEW identity — that identity is what re-arms the caller's fast-path.
        h.states = [:]
        h.episode = nil
        h.advance(seconds: 2)
        h.pass([statOnly(f1, ident(8))])
        h.advance(seconds: 2)
        let r = h.pass([content(f1, ident(8), "dA")])
        XCTAssertTrue(r.emissions.isEmpty, "dedup holds across generations")
        XCTAssertEqual(h.states[f1], .settled(.duplicateOfLastEmission(identity: ident(8))))

        // Caller fast-path shape: a statOnly re-sighting of the settlement identity is inert.
        h.advance(seconds: 2)
        h.pass([statOnly(f1, ident(8))])
        XCTAssertEqual(h.states[f1], .settled(.duplicateOfLastEmission(identity: ident(8))))
    }

    func testEmission_identityCarriesDigest() {
        var h = harness()
        h.pass([statOnly(f1, ident(9))])
        h.advance(seconds: 2)
        h.pass([content(f1, ident(9), "dX")])
        h.advance(seconds: 2)
        let r = h.pass([content(f1, ident(9), "dX")])
        XCTAssertEqual(r.emissions, [WatcherEmission(name: f1, identity: ident(9).withDigest("dX"))],
                       "the emission carries the validated stat identity WITH the digest")
    }

    // MARK: - Pin 4: classic-file transitions

    func testClassic_settledMovesToDigestPendingOnDigestChange() {
        var h = harness()
        emit(&h, classic, ident(1), "dA")
        h.advance(seconds: 2)
        let r = h.pass([content(classic, ident(1), "dB")])
        XCTAssertTrue(r.emissions.isEmpty)
        XCTAssertEqual(h.states[classic],
                       .digestPending(digest: "dB", identity: ident(1), firstObservedNanos: h.now),
                       "pin 4: settled → digestPending on digest change")
    }

    /// A → (transient B) → A emits nothing: the pending B evidence is consumed by the
    /// settle-back onto the last-emitted digest.
    func testClassic_AtransientB_backToA_emitsNothing() {
        var h = harness()
        emit(&h, classic, ident(1), "dA")
        h.advance(seconds: 2)
        h.pass([content(classic, ident(1), "dB")])              // transient B → pending
        h.advance(seconds: 2)
        var r = h.pass([content(classic, ident(1), "dA")])      // back to A
        XCTAssertTrue(r.emissions.isEmpty, "A → transient B → A must emit nothing")
        XCTAssertEqual(h.states[classic], .settled(.duplicateOfLastEmission(identity: ident(1))),
                       "settle-back onto the last emission consumes the pending evidence")
        // B never re-emerges from stale evidence.
        h.advance(seconds: 2)
        r = h.pass([content(classic, ident(1), "dA")])
        XCTAssertTrue(r.emissions.isEmpty)
    }

    /// A → B (emitted) → A re-emits A — latest-per-name dedup, and A re-earns the digest
    /// gate before its second emission.
    func testClassic_AthenBEmitted_backToA_reEmitsAfterReEarningGate() {
        var h = harness()
        emit(&h, classic, ident(1), "dA")
        h.advance(seconds: 2)
        h.pass([content(classic, ident(1), "dB")])
        h.advance(seconds: 2)
        var r = h.pass([content(classic, ident(1), "dB")])
        XCTAssertEqual(r.emissions.map(\.name), [classic], "arrange: B emits")
        XCTAssertEqual(h.dedup[classic], "dB", "latest-per-name: B overwrites A")

        h.advance(seconds: 2)
        r = h.pass([content(classic, ident(1), "dA")])
        XCTAssertTrue(r.emissions.isEmpty, "returning to A must RE-EARN the gate, not free-ride")
        XCTAssertEqual(h.states[classic],
                       .digestPending(digest: "dA", identity: ident(1), firstObservedNanos: h.now))
        h.advance(seconds: 2)
        r = h.pass([content(classic, ident(1), "dA")])
        XCTAssertEqual(r.emissions.map(\.name), [classic],
                       "A re-emits — a stacker returning to earlier content must not freeze")
        XCTAssertEqual(h.dedup[classic], "dA")
    }

    // MARK: - Review-12 P1-1: dedup evidence must never affect ordering or blocker accounting

    /// After a generation reset the dedup table still knows both names. Changed same-name
    /// content must count in blocker accounting: _00002 (nonterminal, content changed) is a
    /// real victim, so the failing _00001 gets an episode and a deadline. Pre-fix, the
    /// retained digest history exempted _00002 and _00001 held it forever with no deadline
    /// and no log.
    func testGenerationReset_changedContent_countsInBlockerAccounting() {
        var h = harness()
        h.dedup = [f1: "old1", f2: "old2"]      // survives the generation; states do not
        h.pass([statOnly(f1, ident(1)), statOnly(f2, ident(100))])
        XCTAssertEqual(h.episode?.blocker, f1,
                       "the dedup table must not exclude _00002 from victim accounting")
        XCTAssertEqual(h.episode?.startNanos, h.now)

        // Ordering unaffected by the dedup table: no mark exists (nothing emitted this
        // generation), so nothing is dropped.
        h.advance(seconds: 2)
        let r = h.pass([statOnly(f1, ident(2)), content(f2, ident(100), "new2")])
        XCTAssertTrue(r.logs.isEmpty, "no out-of-order drops — the table carries no ordering evidence")
        XCTAssertEqual(h.states[f2],
                       .digestPending(digest: "new2", identity: ident(100), firstObservedNanos: h.now))
        XCTAssertNotNil(h.episode, "the episode keeps running while the victim is nonterminal")
    }

    /// The dedup table must not EXEMPT a name from the high-water mark either (the [3, 2]
    /// regression): only settled(.emittedNow) — this generation's emissions — are exempt.
    func testDedupTableEntry_doesNotExemptFromMark() {
        var h = harness()
        h.dedup[f2] = "old2"                    // stale entry from a previous generation
        emit(&h, f3, ident(30), "d3")           // this generation's mark: 00003
        h.advance(seconds: 2)
        let r = h.pass([statOnly(f2, ident(200)), statOnly(f3, ident(30))])
        XCTAssertEqual(h.states[f2], .droppedOutOfOrder,
                       "a nonterminal name below the mark is dropped — table entries are not ordering evidence")
        XCTAssertEqual(r.logs, ["revision 00002 arrived out of order — skipped (high-water 00003)"])
    }

    // MARK: - Ordering: numeric sort, holdback, reject-below-mark

    func testOrdering_unsortedObservations_emitInNumericOrder_zeroPaddingAware() {
        var h = harness()
        let a = "live_stack_10.fit", b = "live_stack_002.fit", c = "live_stack_0009.fit"
        let scrambled = [statOnly(a, ident(10)), statOnly(b, ident(2)), statOnly(c, ident(9))]
        h.pass(scrambled)
        h.advance(seconds: 2)
        h.pass([content(a, ident(10), "dA"), content(b, ident(2), "dB"), content(c, ident(9), "dC")])
        h.advance(seconds: 2)
        let r = h.pass([content(c, ident(9), "dC"), content(a, ident(10), "dA"),
                        content(b, ident(2), "dB")])
        XCTAssertEqual(r.emissions.map(\.name), [b, c, a],
                       "leading zeros are numerically insignificant: 2 < 9 < 10")
    }

    /// Holdback: a lower revision mid-gate holds a gate-satisfied higher revision (which
    /// parks in `ready`, evidence intact); both emit in order once the lower one clears.
    func testOrdering_lowerMidGate_higherHeldReady_thenBothEmitInOrder() {
        var h = harness()
        h.pass([statOnly(f2, ident(20))])                       // _00002 one tick ahead
        h.advance(seconds: 2)
        h.pass([statOnly(f1, ident(10)), content(f2, ident(20), "d2")])
        h.advance(seconds: 2)
        var r = h.pass([content(f1, ident(10), "d1"), content(f2, ident(20), "d2")])
        XCTAssertTrue(r.emissions.isEmpty, "_00002 must be held while _00001 earns its gates")
        XCTAssertEqual(h.states[f2], .ready(digest: "d2", identity: ident(20),
                                            firstObservedNanos: h.now - 2 * Self.q))
        h.advance(seconds: 2)
        r = h.pass([content(f1, ident(10), "d1"), content(f2, ident(20), "d2")])
        XCTAssertEqual(r.emissions.map(\.name), [f1, f2], "never [2, 1]")
    }

    func testOrdering_rejectBelowMark_dropsPermanently_logsOnce() {
        var h = harness()
        emit(&h, f2, ident(20), "d2")
        h.advance(seconds: 2)
        var r = h.pass([statOnly(f1, ident(10)), statOnly(f2, ident(20))])
        XCTAssertEqual(h.states[f1], .droppedOutOfOrder)
        XCTAssertEqual(r.logs, ["revision 00001 arrived out of order — skipped (high-water 00002)"])
        // Later passes: silent, and the dropped revision never emits, whatever it offers.
        h.advance(seconds: 2)
        h.pass([content(f1, ident(10), "d1"), statOnly(f2, ident(20))])
        h.advance(seconds: 2)
        r = h.pass([content(f1, ident(10), "d1"), statOnly(f2, ident(20))])
        XCTAssertTrue(r.logs.isEmpty, "the drop logs exactly once")
        XCTAssertTrue(r.emissions.isEmpty, "dropped stays dropped")
        XCTAssertEqual(h.states[f1], .droppedOutOfOrder)
    }

    // MARK: - Two-tick stability and the digest gate

    func testTwoTick_contentUnderChangedIdentity_restartsStability() {
        var h = harness()
        h.pass([statOnly(classic, ident(1))])
        XCTAssertEqual(h.states[classic], .observing(stat: ident(1)))
        // Content computed under a DIFFERENT identity than the basis: stability restarts;
        // the digest is discarded (evidence is only meaningful under its exact identity).
        h.advance(seconds: 2)
        let r = h.pass([content(classic, ident(2), "dA")])
        XCTAssertTrue(r.emissions.isEmpty)
        XCTAssertEqual(h.states[classic], .observing(stat: ident(2)))
    }

    func testDigestGate_requiresQuietSeparation_backToBackDoesNotCount() {
        var h = harness()
        h.pass([statOnly(classic, ident(1))])
        h.advance(seconds: 2)
        h.pass([content(classic, ident(1), "dA")])
        let firstObserved = h.now
        // Same digest, ~zero monotonic separation: not a separated observation.
        var r = h.pass([content(classic, ident(1), "dA")])
        XCTAssertTrue(r.emissions.isEmpty, "back-to-back passes prove nothing")
        XCTAssertEqual(h.states[classic],
                       .digestPending(digest: "dA", identity: ident(1),
                                      firstObservedNanos: firstObserved),
                       "the pending clock is NOT restarted by a same-digest re-observation")
        h.advance(seconds: 2)
        r = h.pass([content(classic, ident(1), "dA")])
        XCTAssertEqual(r.emissions.map(\.name), [classic])
    }

    func testDigestGate_restartsOnDigestChange_andOnIdentityChange() {
        var h = harness()
        h.pass([statOnly(classic, ident(1))])
        h.advance(seconds: 2)
        h.pass([content(classic, ident(1), "dA")])
        // A different digest replaces the pending one (still unemitted, fresh clock).
        h.advance(seconds: 2)
        var r = h.pass([content(classic, ident(1), "dB")])
        XCTAssertTrue(r.emissions.isEmpty, "the replaced pending digest must not emit")
        XCTAssertEqual(h.states[classic],
                       .digestPending(digest: "dB", identity: ident(1), firstObservedNanos: h.now))
        // An identity change restarts stability itself.
        h.advance(seconds: 2)
        r = h.pass([content(classic, ident(3), "dB")])
        XCTAssertTrue(r.emissions.isEmpty)
        XCTAssertEqual(h.states[classic], .observing(stat: ident(3)))
    }

    /// The dedup guard runs BEFORE the digest gate: content matching the last emission
    /// settles immediately (no pending, no quiet period) — and pending evidence dies on
    /// observed invalidity (review10 item 2).
    func testDedupBeforeGate_andInvalidityKillsPendingEvidence() {
        var h = harness()
        h.dedup[classic] = "dA"
        h.pass([statOnly(classic, ident(1))])
        h.advance(seconds: 2)
        var r = h.pass([content(classic, ident(1), "dA")])
        XCTAssertTrue(r.emissions.isEmpty)
        XCTAssertEqual(h.states[classic], .settled(.duplicateOfLastEmission(identity: ident(1))),
                       "known content settles without the gate — dedup guard first")

        // Fresh name: pending evidence dies on invalidity and re-earns from zero.
        h.advance(seconds: 2)
        h.pass([statOnly(f1, ident(10)), statOnly(classic, ident(1))])
        h.advance(seconds: 2)
        h.pass([content(f1, ident(10), "d1"), statOnly(classic, ident(1))])
        h.advance(seconds: 2)
        h.pass([invalid(f1), statOnly(classic, ident(1))])
        XCTAssertNil(h.states[f1], "observed invalidity resets ALL pending evidence")
        h.advance(seconds: 2)
        r = h.pass([content(f1, ident(10), "d1"), statOnly(classic, ident(1))])
        XCTAssertTrue(r.emissions.isEmpty,
                      "no emission off stale pre-invalidity evidence — both gates re-earn")
        XCTAssertEqual(h.states[f1], .observing(stat: ident(10)),
                       "content under a re-earned basis starts at stability, not the gate")
    }

    // MARK: - Immutable policy: no gate, no ordering machinery

    func testImmutablePolicy_emitsOnSecondTick_outOfOrderLosesNothing_invalidNeverHolds() {
        var h = harness(.immutableAfterPublish)
        let f100 = "live_stack_00100.fit"
        h.pass([statOnly(f100, ident(1000))])
        h.advance(seconds: 2)
        var r = h.pass([content(f100, ident(1000), "dH")])
        XCTAssertEqual(r.emissions.map(\.name), [f100],
                       "immutable policy: stable + valid content emits — no digest gate")

        // Lower revisions arrive later, next to a permanently invalid one: all healthy
        // files emit, nothing is held, nothing is dropped, no episode ever exists.
        h.advance(seconds: 2)
        h.pass([statOnly(f1, ident(1)), statOnly(f2, ident(2)), statOnly(f100, ident(1000))])
        XCTAssertNil(h.episode, "no blocking episodes under the immutable policy")
        h.advance(seconds: 2)
        r = h.pass([invalid(f1), content(f2, ident(2), "d2"), statOnly(f100, ident(1000))])
        XCTAssertEqual(r.emissions.map(\.name), [f2],
                       "an invalid neighbor never starves anyone under the immutable policy")
        XCTAssertTrue(r.logs.isEmpty, "no out-of-order drops under the immutable policy")
        XCTAssertEqual(h.states[f100], .settled(.emittedNow(identity: ident(1000))),
                       "the settled file is untouched (fast-path armed)")
    }
}
