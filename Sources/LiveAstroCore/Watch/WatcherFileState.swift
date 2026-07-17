import Foundation   // ComparisonResult only — this file must contain ZERO filesystem APIs
                    // (no FileManager, no FileHandle, no Darwin stat/open/readdir): every fact
                    // the reducer consumes arrives as data in a FileObservation.

// MARK: - Revision ordering (the single parser-adjacent comparator)
//
// Moved VERBATIM from StackFileWatcher (review9 items 1+2, review10 item 6) so the watcher's
// scan loop and the pure reducer share ONE comparator — classification, candidate ordering,
// and the order gate can never disagree. Behavior unchanged.

enum RevisionOrdering {

    /// Numeric comparison of two digit strings with leading zeros stripped (an all-zeros
    /// string strips to the empty suffix, which behaves as "0"). The ONE comparator behind
    /// candidate ordering AND the emitted-revision high-water mark (review10 items 1+6).
    static func numericCompare(_ a: String, _ b: String) -> ComparisonResult {
        let na = a.drop { $0 == "0" }, nb = b.drop { $0 == "0" }
        if na.count != nb.count { return na.count < nb.count ? .orderedAscending : .orderedDescending }
        if na == nb { return .orderedSame }
        return na < nb ? .orderedAscending : .orderedDescending
    }

    /// Numeric order for digit strings without Int conversion (review10 item 6): leading
    /// zeros are numerically insignificant. Equal numeric VALUES with different padding
    /// ("007" vs "7") tie-break on the raw string, so this stays a stable total order.
    static func digitStringLess(_ a: String, _ b: String) -> Bool {
        switch numericCompare(a, b) {
        case .orderedAscending:  return true
        case .orderedDescending: return false
        case .orderedSame:       return a < b
        }
    }

    /// Deterministic candidate order (review9 item 2): numbered revisions sort numerically
    /// (digit-string compare, full-name tiebreak); non-numbered names sort lexicographically
    /// and BEFORE the revision series. Ties are impossible (names are unique + full-name
    /// tiebreak), so this is a total order — no reliance on sort stability.
    static func orderedBefore(_ a: (name: String, revision: String?),
                              _ b: (name: String, revision: String?)) -> Bool {
        switch (a.revision, b.revision) {
        case let (ra?, rb?): return ra == rb ? a.name < b.name : digitStringLess(ra, rb)
        case (nil, nil):     return a.name < b.name
        case (nil, .some):   return true
        case (.some, nil):   return false
        }
    }
}

// MARK: - State model (spec §2.1)
//
// Each filename in the current folder generation carries exactly ONE authoritative state.
// All states die at a folder-generation change (the CALLER clears the table and the episode);
// the dedup side table survives generations (spec §2.2 — content-bound, unlike identities).

/// How a file finished earning its gates this generation (spec §2.5). BOTH settlements carry
/// the observed stat identity and arm the identity fast-path for numbered revisions and the
/// immutable policy — the caller skips all content work when a fresh fstat equals the
/// settlement identity. The classic fixed-name file is exempt (permanent full-rehash policy,
/// enforced by the caller's observe phase, which keeps producing `.content` for it).
enum Settlement: Equatable, Sendable {
    /// This name EMITTED this generation. The set of such names IS `emittedThisGeneration`
    /// — the ordering evidence the high-water mark and blocker accounting derive from.
    case emittedNow(identity: FileIdentity)
    /// This name settled onto content already recorded in `lastEmittedDigestByName` WITHOUT
    /// emitting this generation (identical re-publication, or a cross-generation re-sighting
    /// of already-delivered content).
    case duplicateOfLastEmission(identity: FileIdentity)

    /// The stat identity observed at settlement (digest-free — the caller's fast-path
    /// compares it against a bare fstat identity).
    var identity: FileIdentity {
        switch self {
        case .emittedNow(let identity), .duplicateOfLastEmission(let identity): return identity
        }
    }
}

/// One authoritative per-file state (spec §2.1). Absence semantics (spec §2.4, pin 2):
/// `observing`/`digestPending`/`ready` DIE when the name is absent from a scan (pending
/// evidence dies — review10 item 2); `settled`/`droppedOutOfOrder`/`writtenOff` are IMMORTAL
/// within the generation (a briefly-invisible corpse must not resurrect, and the high-water
/// mark — derived from `settled(.emittedNow)` — cannot regress when an emitted revision is
/// deleted).
enum FileState: Equatable, Sendable {
    /// Earning two-tick stat stability: `stat` is the identity observed last pass; the file
    /// advances only when the SAME identity is observed again.
    case observing(stat: FileIdentity)
    /// Mutable-policy content gate (review8 finding 1): a new digest observed under a stable
    /// identity, emitted only after the SAME digest is observed again under the SAME identity
    /// at least one quiet period of monotonic time later.
    case digestPending(digest: String, identity: FileIdentity, firstObservedNanos: UInt64)
    /// All gates passed, awaiting order (held back below an unemitted lower revision —
    /// review10 item 1). Carries the earned gate evidence so a held revision re-qualifies
    /// immediately once the blocker clears, and so a digest/identity change while held is
    /// still detected (it must re-earn the gate, not ride stale readiness).
    case ready(digest: String, identity: FileIdentity, firstObservedNanos: UInt64)
    /// Emitted or deduplicated this generation; arms the identity fast-path (spec §2.5).
    case settled(Settlement)
    /// Arrived at or below the emitted high-water mark — dropped permanently, logged once.
    case droppedOutOfOrder
    /// Blocking deadline expired (review11) — dead for this generation, logged once.
    case writtenOff

    /// Terminal states are immortal within the generation and inert to observations.
    var isTerminal: Bool {
        switch self {
        case .settled, .droppedOutOfOrder, .writtenOff: return true
        case .observing, .digestPending, .ready: return false
        }
    }

    var isSettled: Bool {
        if case .settled = self { return true }
        return false
    }

    /// True when this name emitted this generation — the ONLY ordering evidence
    /// (spec §2.2, pin: the dedup table must never influence ordering).
    var isEmittedNow: Bool {
        if case .settled(.emittedNow) = self { return true }
        return false
    }

    /// The stat identity the state's evidence was earned under — the two-tick stability
    /// basis a fresh observation is compared against. nil for terminal non-settled states
    /// (they carry no evidence and take no part in stability).
    var statBasis: FileIdentity? {
        switch self {
        case .observing(let stat): return stat
        case .digestPending(_, let identity, _), .ready(_, let identity, _): return identity
        case .settled(let settlement): return settlement.identity
        case .droppedOutOfOrder, .writtenOff: return nil
        }
    }
}

// MARK: - Blocking episode (spec §2.3)

/// At most ONE blocking episode per folder — never a per-name map (kills review-12 P1-2:
/// with a single episode whose clock is a field, a role round-trip has no keyed map to
/// inherit a spent deadline from). The episode exists IFF the head-of-line numbered revision
/// fails to emit AND at least one later, never-emitted, nonterminal numbered revision is
/// present to be starved (pin 1). Lone-period teardown — no victims ⇒ episode destroyed —
/// is load-bearing (cold2 I1): the budget charges blocking-without-emitting time only.
struct BlockingEpisode: Equatable, Sendable {
    /// The head-of-line numbered revision failing to emit.
    let blocker: String
    /// Monotonic episode start — episode-scoped, never inherited across episodes.
    let startNanos: UInt64
    /// start + budget, grace-extended by converging observations, never past
    /// start + ceiling (the hard total-deadline check — churn never resets it).
    var deadlineNanos: UInt64
}

// MARK: - Observations (the observe phase's complete output)

/// Everything the observe phase learned about one candidate file this pass, as pure data.
/// The observe phase performs the filesystem reads on the pinned descriptors (unchanged);
/// the reducer consumes only these facts. The caller must supply EXACTLY ONE observation per
/// tracked name (absent names included, so terminal-state revisions keep contributing their
/// revision string to the derived high-water mark) and one per eligible enumerated candidate
/// (the enumeration filters — hidden/.tmp/extension/prefix — remain caller concerns).
struct FileObservation: Equatable, Sendable {
    /// The file name (unique key of the state table).
    let name: String
    /// Pre-parsed numbered-revision digit suffix (the watcher's anchored-regex parse), or
    /// nil for the classic fixed-name file and every non-numbered candidate.
    let revision: String?
    let kind: Kind

    /// Why a present file yielded no usable content this pass. All invalidities reduce
    /// identically (pending evidence dies — review10 item 2); the cases exist so the observe
    /// phase reports honestly and tests can name their scenario.
    enum Invalidity: Equatable, Sendable {
        case openFailed          // openat failure (vanished since enumeration, symlink, FIFO…)
        case statFailedOrEmpty   // fstat failure or zero size
        case incompleteHeader    // malformed FITS header, or size < header-declared minimum
        case digestFailed        // digest read/seek failure (aborted digests never reach the reducer)
    }

    enum Kind: Equatable, Sendable {
        /// Tracked name absent from this pass's (fd-pinned) enumeration.
        case absent
        /// Present but invalid — pending evidence must die; the file re-earns from zero.
        case invalid(Invalidity)
        /// Stat observed; content work not performed this pass (first sighting, unstable
        /// identity, or the caller's identity fast-path against a settlement identity).
        /// Also used for the mid-read revalidation mismatch: the LATEST clean stat is
        /// reported and stability re-earns from it (review6 finding 1 branch shape).
        case statOnly(FileIdentity)
        /// Stable identity + (for FITS) complete header + full-file digest, all from the
        /// same pinned descriptor, revalidated after the read.
        case content(stat: FileIdentity, digest: String)
    }
}

// MARK: - Reducer output

/// One ordered emission the caller must publish (URL construction and yielding stay caller
/// concerns). `identity` is the observed stat identity with the content digest attached —
/// exactly what StackUpdate carries.
struct WatcherEmission: Equatable, Sendable {
    let name: String
    let identity: FileIdentity
}

// MARK: - Configuration

/// Pure-value configuration for one reducer pass. Budget/grace/ceiling are precomputed by
/// the owner (budget = max(30 s, 10×quiet, 5×poll); grace = 1×quiet; ceiling = budget +
/// 4×quiet — review11, unchanged) so the reducer never sees wall-clock policy.
struct WatcherReducerConfig: Sendable {
    let digestPolicy: StackFileWatcher.DigestPolicy
    /// The digest-stability gate's minimum monotonic separation (review8 finding 1).
    let quietPeriodNanos: UInt64
    let blockingBudgetNanos: UInt64
    let blockingGraceNanos: UInt64
    let blockingCeilingNanos: UInt64

    /// Cold1 I3: ordering machinery — mark, drops, holdback, blocking deadline — exists for
    /// replay/revision semantics, i.e. `.mutableStackerOutput` only. Numeric SORTING stays
    /// for both policies (harmless determinism within a pass).
    var revisionOrderingEnabled: Bool { digestPolicy == .mutableStackerOutput }

    init(digestPolicy: StackFileWatcher.DigestPolicy, quietPeriodNanos: UInt64,
         blockingBudgetNanos: UInt64, blockingGraceNanos: UInt64, blockingCeilingNanos: UInt64) {
        self.digestPolicy = digestPolicy
        self.quietPeriodNanos = quietPeriodNanos
        self.blockingBudgetNanos = blockingBudgetNanos
        self.blockingGraceNanos = blockingGraceNanos
        self.blockingCeilingNanos = blockingCeilingNanos
    }
}

// MARK: - The reducer (spec §2 — the ONLY mutation site of the watcher's ordering state)

/// Pure function layer: (states, observations, clock, dedup table, episode, config) →
/// (states′, ordered emissions, log lines, dedup table′, episode′). No filesystem access,
/// no side effects, no hidden clocks — a pass is fully determined by its inputs.
///
/// Evidence separation (spec §2.2, kills review-12 P1-1):
/// - ORDERING evidence is derived from states: `settled(.emittedNow)` names are
///   `emittedThisGeneration`; the high-water mark is their maximum revision. Both die with
///   the generation because the caller clears the state table.
/// - DEDUP evidence is `lastEmittedDigestByName` (latest digest per name, overwritten at
///   each emission, survives generations). The reducer consults it at EXACTLY ONE site —
///   settling `duplicateOfLastEmission` — so it is structurally incapable of affecting
///   blocker accounting or the mark.
enum WatcherReducer {

    struct PassResult {
        var states: [String: FileState]
        var emissions: [WatcherEmission]
        var logs: [String]
        var lastEmittedDigestByName: [String: String]
        var episode: BlockingEpisode?
    }

    static func reduce(states startStates: [String: FileState],
                       observations: [FileObservation],
                       nowNanos now: UInt64,
                       lastEmittedDigestByName: [String: String],
                       episode startEpisode: BlockingEpisode?,
                       config: WatcherReducerConfig) -> PassResult {
        var states = startStates
        var dedup = lastEmittedDigestByName
        var episode = startEpisode
        var logs: [String] = []
        var emissions: [WatcherEmission] = []

        // One observation per name (caller contract); a later duplicate wins defensively.
        var obsByName: [String: FileObservation] = [:]
        for o in observations { obsByName[o.name] = o }
        let presentNames = Set(obsByName.values.lazy.filter { $0.kind != .absent }.map(\.name))

        // ---- Phase 1: absence (spec §2.4, pin 2). Tracked names with no observation at
        // all are treated as absent (a caller-contract violation degrades conservatively:
        // pending evidence dies, terminal states stay immortal).
        for (name, state) in states where !presentNames.contains(name) && !state.isTerminal {
            states[name] = nil
        }

        // ---- Phase 2: derive the high-water mark from settled(.emittedNow) — the ONLY
        // ordering evidence (pin: deleting an emitted revision cannot regress the mark,
        // because terminal states are immortal under absence). Revisions come from the
        // observations (absent ones included), never from the dedup table.
        let ordering = config.revisionOrderingEnabled
        var mark: String? = nil
        if ordering {
            for (name, state) in states where state.isEmittedNow {
                guard let rev = obsByName[name]?.revision else { continue }
                if mark.map({ RevisionOrdering.numericCompare(rev, $0) == .orderedDescending })
                    ?? true { mark = rev }
            }
        }

        // ---- Phase 3: deterministic candidate order (review9 item 2).
        let candidates = obsByName.values.filter { $0.kind != .absent }
            .sorted { RevisionOrdering.orderedBefore(($0.name, $0.revision), ($1.name, $1.revision)) }

        // ---- Phase 4: later-victim suffix flags from PASS-START states (review11: a
        // failing revision runs the deadline only while it actually BLOCKS someone). A
        // potential victim is a later, present, numbered revision whose state is
        // nonterminal — including untracked first sightings. The dedup table takes NO part
        // in this (review-12 P1-1: retained digest history is dedup evidence only).
        var laterVictim = [Bool](repeating: false, count: candidates.count)
        if ordering {
            var seen = false
            for i in stride(from: candidates.count - 1, through: 0, by: -1) {
                laterVictim[i] = seen
                let c = candidates[i]
                if c.revision != nil, !(startStates[c.name]?.isTerminal ?? false) { seen = true }
            }
        }

        // ---- Phase 5: one ordered pass. `holdActive` is the review10 holdback: once a
        // numbered revision proves not yet emittable, no higher-numbered revision emits
        // this pass (gates still advance; the dedup guard still settles).
        var holdActive = false

        for (index, obs) in candidates.enumerated() {
            let name = obs.name
            let revision = ordering ? obs.revision : nil   // cold1 I3: machinery is mutable-only
            let state = states[name]

            // Terminal-and-dead names are inert: written off or dropped this generation —
            // no gates, no holds, no repeat logs (log-once lives in the state itself).
            if state == .writtenOff || state == .droppedOutOfOrder { continue }

            /// Register that this numbered revision FAILED TO EMIT this pass (any cause) —
            /// the episode engine (spec §2.3). `converging` is true ONLY for the digest
            /// gate advancing under a stable identity; churn never renews grace.
            func failedToEmit(converging: Bool) {
                guard let revision else { return }
                if holdActive {
                    // Queued victim: its own clock never runs, and any episode it still
                    // heads from an earlier pass dies here — it becomes the blocker again
                    // only with a fresh clock (review-12 P1-2, cold2 I1).
                    if episode?.blocker == name { episode = nil }
                    return
                }
                holdActive = true
                guard laterVictim[index] else {
                    // Lone failing revision: nobody is blocked. The episode — if it was
                    // ours — is over and its clock dies with it (lone-period teardown,
                    // cold2 I1: the budget charges blocking-without-emitting time only).
                    if episode?.blocker == name { episode = nil }
                    return
                }
                guard var ep = episode, ep.blocker == name else {
                    // A new blocking episode begins with a FRESH clock. There is no keyed
                    // map to inherit a deadline from — the single episode IS the clock.
                    episode = BlockingEpisode(blocker: name, startNanos: now,
                                              deadlineNanos: now &+ config.blockingBudgetNanos)
                    return
                }
                let ceiling = ep.startNanos &+ config.blockingCeilingNanos
                if converging {
                    // One quiet period of grace per converging observation, clamped at the
                    // ceiling — renewal can never push the hold past budget + 4×quiet.
                    let renewed = min(now &+ config.blockingGraceNanos, ceiling)
                    if renewed > ep.deadlineNanos { ep.deadlineNanos = renewed }
                }
                guard now >= min(ep.deadlineNanos, ceiling) else {
                    episode = ep
                    return
                }
                // Deadline passed: written off. The hold releases THIS pass, later
                // revisions proceed, the frame is lost — honestly. The mark is untouched
                // (only real emissions advance it).
                episode = nil
                states[name] = .writtenOff
                let heldSeconds = Int((Double(now &- ep.startNanos) / 1_000_000_000).rounded())
                logs.append("revision \(revision) blocked emissions for \(heldSeconds)s "
                            + "without completing — abandoning it; later revisions proceed "
                            + "(frame lost: \(name))")
                holdActive = false
            }

            /// The single point a file becomes consumer-visible: settle, record dedup
            /// evidence, advance the mark, clear the episode this blocker headed.
            func emit(stat: FileIdentity, digest: String) {
                states[name] = .settled(.emittedNow(identity: stat))
                dedup[name] = digest
                emissions.append(WatcherEmission(name: name, identity: stat.withDigest(digest)))
                if episode?.blocker == name { episode = nil }
                if let revision,
                   mark.map({ RevisionOrdering.numericCompare(revision, $0) == .orderedDescending })
                       ?? true { mark = revision }
            }

            /// Settle back onto the last emission WITHOUT emitting: pending evidence is
            /// consumed and the identity fast-path re-arms (spec §2.5/§2.6). A name that
            /// already emitted this generation keeps its `emittedNow` standing (identity
            /// updated) — identical content republished under a fresh identity must not
            /// regress the derived mark or the emitted-this-generation set.
            func settleDuplicate(stat: FileIdentity) {
                if case .settled(.emittedNow) = state {
                    states[name] = .settled(.emittedNow(identity: stat))
                } else {
                    states[name] = .settled(.duplicateOfLastEmission(identity: stat))
                }
            }

            // REJECT BELOW THE MARK (review10 item 1b): a numbered revision that has not
            // emitted THIS GENERATION (state-derived — a dedup-table entry is NOT an
            // exemption, review-12 P1-1) at or below the mark arrived out of order.
            // Settled names are exempt: their re-sightings are governed by the fast-path
            // and the dedup guard, never re-dropped.
            if let revision, !(state?.isSettled ?? false), let m = mark,
               RevisionOrdering.numericCompare(revision, m) != .orderedDescending {
                states[name] = .droppedOutOfOrder
                logs.append("revision \(revision) arrived out of order — skipped (high-water \(m))")
                continue
            }

            switch obs.kind {
            case .absent:
                continue    // not a candidate (filtered above); unreachable

            case .invalid:
                // Observed invalidity resets EVERYTHING pending (review10 item 2):
                // stability and content evidence re-earn from zero. A SETTLED file stays
                // settled — settlement is content-delivery history, not pending evidence;
                // it neither resurrects gates nor blocks anyone (a settled name satisfied
                // the order already, so it cannot be the head-of-line failure).
                if state?.isSettled ?? false { continue }
                states[name] = nil
                failedToEmit(converging: false)

            case .statOnly(let stat):
                if case .settled(let settlement)? = state {
                    if settlement.identity == stat { continue }   // fast-path hit: inert
                    // The published version moved: it re-earns everything from zero.
                    states[name] = .observing(stat: stat)
                    failedToEmit(converging: false)
                    continue
                }
                if state?.statBasis != stat {
                    // First sighting or unstable identity (incl. the mid-read revalidation
                    // mismatch, which reports the LATEST clean stat): stability restarts.
                    states[name] = .observing(stat: stat)
                }
                // Stable-but-no-content is still not emittable this pass.
                failedToEmit(converging: false)

            case .content(let stat, let digest):
                // Two-tick stability: content evidence only counts under the exact
                // identity the state already holds; any mismatch restarts stability (and
                // the digest gate with it — review8 finding 1).
                guard let basis = state?.statBasis, basis == stat else {
                    states[name] = .observing(stat: stat)
                    failedToEmit(converging: false)
                    continue
                }
                // DEDUP GUARD — the reducer's ONLY consultation of the dedup table, and it
                // runs BEFORE the digest gate and BEFORE the holdback (a held victim can
                // settle and stop counting, spec §2.3).
                if dedup[name] == digest {
                    settleDuplicate(stat: stat)
                    continue
                }
                if config.digestPolicy == .mutableStackerOutput {
                    // Digest-stability gate (review8 finding 1).
                    switch state {
                    case .digestPending(let d, let id, let t) where d == digest && id == stat:
                        guard now >= t, now &- t >= config.quietPeriodNanos else {
                            // Mid-gate, and the ONLY converging branch: the SAME pending
                            // digest observed again under a stable identity.
                            failedToEmit(converging: true)
                            continue
                        }
                        if revision != nil, holdActive {
                            // Gate earned but held below a blocker: park in `ready` with
                            // the evidence intact (emits the pass the blocker clears).
                            states[name] = .ready(digest: digest, identity: stat,
                                                  firstObservedNanos: t)
                            continue
                        }
                        emit(stat: stat, digest: digest)
                    case .ready(let d, let id, _) where d == digest && id == stat:
                        if revision != nil, holdActive { continue }   // still held, evidence intact
                        emit(stat: stat, digest: digest)
                    default:
                        // A NEW digest (or a changed one, or readiness invalidated by a
                        // digest change) starts the gate over — churn, never convergence.
                        states[name] = .digestPending(digest: digest, identity: stat,
                                                      firstObservedNanos: now)
                        failedToEmit(converging: false)
                    }
                    continue
                }
                // Immutable policy: no content gate, no ordering machinery — a stable,
                // valid, undelivered file emits now.
                emit(stat: stat, digest: digest)
            }
        }

        // ---- Phase 6: the episode is a DERIVED property of the state table (pin 1) —
        // re-check the invariant against the FINAL states. It survives only while its
        // blocker is present and nonterminal AND at least one later, present, nonterminal
        // numbered revision remains to be starved. This is the lone-period teardown and
        // the settled/absent-blocker teardown in one rule; the next episode, whenever it
        // forms, runs a fresh clock.
        if let ep = episode {
            let blockerAlive = presentNames.contains(ep.blocker)
                && !(states[ep.blocker]?.isTerminal ?? false)
            let blockerRevision = obsByName[ep.blocker]?.revision ?? nil
            let hasVictim = candidates.contains { c in
                guard c.name != ep.blocker, c.revision != nil,
                      !(states[c.name]?.isTerminal ?? false) else { return false }
                return RevisionOrdering.orderedBefore((ep.blocker, blockerRevision),
                                                      (c.name, c.revision))
            }
            if !blockerAlive || !hasVictim { episode = nil }
        }

        return PassResult(states: states, emissions: emissions, logs: logs,
                          lastEmittedDigestByName: dedup, episode: episode)
    }
}
