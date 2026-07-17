import Foundation   // ComparisonResult + NSRegularExpression only — this file must contain ZERO
                    // filesystem APIs (no FileManager, no FileHandle, no Darwin stat/open/readdir):
                    // every fact the reducer consumes arrives as data in a FileObservation.

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
// ONE authoritative mutable value. The cross-generation survival rule is a TYPE boundary,
// not coordinated clearing calls: `GenerationState` is replaced WHOLESALE on disappear/
// return, re-arm, or directory identity replacement; the outer `lastEmittedDigestByName`
// (dedup evidence — spec §2.2, content-bound) is the sole survivor.

/// Monotonically increasing folder-generation token — NOT merely the current directory
/// `(dev, ino)`: disappear/return must invalidate old emission intents even when the
/// filesystem later reports a reused identity (inode reuse must not resurrect intents).
/// The DRIVER allocates tokens monotonically; the reducer only compares them.
struct FolderGeneration: Equatable, Hashable, Sendable {
    let rawValue: UInt64
}

/// The one authoritative watcher state (spec §2.1).
struct WatcherState: Equatable, Sendable {
    var generation: GenerationState
    /// DEDUP evidence — latest digest per name, overwritten at each emission; survives
    /// folder generations (spec §2.2). Consulted at exactly ONE reducer site: settling
    /// `duplicateOfLastEmission`. Structurally incapable of affecting ordering (P1-1).
    var lastEmittedDigestByName: [String: String]
}

/// Everything that dies with a folder generation. Constructed fresh — never field-cleared.
struct GenerationState: Equatable, Sendable {
    let id: FolderGeneration
    var files: [String: FileState]
    var ordering: RevisionOrderingState

    /// `emittedThisGeneration` — a DERIVED projection, never a stored set (spec §2.2):
    /// names in `settled(.emittedNow)`. Dies with the generation; drives blocker
    /// accounting and the derived high-water mark.
    var emittedThisGeneration: Set<String> {
        Set(files.compactMap { $0.value.isEmittedNow ? $0.key : nil })
    }
}

/// Generation-local ordering state: at most ONE blocking episode per folder (spec §2.3).
struct RevisionOrderingState: Equatable, Sendable {
    var activeBlocker: BlockingEpisode?
}

/// Mutable-policy content gate evidence (review8 finding 1): a new digest observed under a
/// stable identity, emitted only after the SAME digest is observed again under the SAME
/// identity at least one quiet period of monotonic time later.
struct PendingDigest: Equatable, Sendable {
    let digest: String
    let identity: FileIdentity
    let firstObservedNanos: UInt64
}

/// How a file finished earning its gates this generation (spec §2.5). BOTH settlements carry
/// the observed stat identity AND the settled digest, and arm the identity fast-path for
/// numbered revisions and the immutable policy — `readPlan` selects the O(1)
/// `.acceptIdentity` path when a fresh fstat equals the settlement identity. The classic
/// fixed-name file is exempt (permanent full-rehash policy, enforced in `readPlan`).
enum Settlement: Equatable, Sendable {
    /// This name EMITTED this generation (a driver yield actually happened — settlement is
    /// applied by `.emissionFinished(.yielded)`, never at intent staging). The set of such
    /// names IS `emittedThisGeneration` — the ordering evidence the high-water mark and
    /// blocker accounting derive from.
    case emittedNow(identity: FileIdentity, digest: String)
    /// This name settled onto content already recorded in `lastEmittedDigestByName` WITHOUT
    /// emitting this generation (identical re-publication, or a cross-generation
    /// re-sighting of already-delivered content).
    case duplicateOfLastEmission(identity: FileIdentity, digest: String)

    /// The stat identity observed at settlement (the fast-path comparison basis).
    var identity: FileIdentity {
        switch self {
        case .emittedNow(let identity, _), .duplicateOfLastEmission(let identity, _):
            return identity
        }
    }

    /// The digest the settlement landed on.
    var digest: String {
        switch self {
        case .emittedNow(_, let digest), .duplicateOfLastEmission(_, let digest):
            return digest
        }
    }
}

/// One authoritative per-file state (spec §2.1). Absence semantics (spec §2.4, pin 2):
/// `observing`/`digestPending`/`ready` DIE when the name is absent from a scan (pending
/// evidence dies — review10 item 2); `settled`/`droppedOutOfOrder`/`writtenOff` are IMMORTAL
/// within the generation (a briefly-invisible corpse must not resurrect, and the high-water
/// mark — derived from `settled(.emittedNow)` — cannot regress when an emitted revision is
/// deleted). ALL states die at generation replacement (a whole-value property, spec §2.4).
enum FileState: Equatable, Sendable {
    /// Earning two-tick stat stability: `stat` is the identity observed last pass; the file
    /// advances only when the SAME identity is observed again.
    case observing(stat: FileIdentity)
    /// Mutable-policy content gate in progress (review8 finding 1).
    case digestPending(PendingDigest)
    /// All gates passed — awaiting order and/or the driver's yield. Carries the full earned
    /// candidate so a held revision re-qualifies immediately once the blocker clears, a
    /// digest/identity change while held is still detected (it must re-earn the gate, not
    /// ride stale readiness), and a staged-but-unyielded emission stays re-emittable. A
    /// `ready` file with an intent outstanding is NOT emitted evidence (spec §2.1 step 4):
    /// only `.emissionFinished(.yielded)` settles it.
    case ready(EmissionCandidate)
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
        case .digestPending(let pending): return pending.identity
        case .ready(let candidate): return candidate.identity
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

// MARK: - Configuration

/// Pure-value configuration for the reducer. Budget/grace/ceiling are DERIVED here from the
/// quiet/poll intervals (budget = max(30 s, 10×quiet, 5×poll); grace = 1×quiet; ceiling =
/// budget + 4×quiet — review11, unchanged; the scale constants stay single-sourced on
/// StackFileWatcher) so the reducer's clock policy has exactly one origin.
struct WatcherReducerConfiguration: Sendable {
    let digestPolicy: StackFileWatcher.DigestPolicy
    /// The configured stacker filename prefix — the reducer builds the ONE anchored
    /// revision parser from it (nil/empty → no revision series is ever recognized).
    let filePrefix: String?
    /// The digest-stability gate's minimum monotonic separation (review8 finding 1).
    let quietPeriodNanos: UInt64
    let pollIntervalNanos: UInt64

    var blockingBudgetNanos: UInt64 {
        max(StackFileWatcher.blockerBudgetFloorNanos,
            StackFileWatcher.blockerBudgetQuietPeriods &* quietPeriodNanos,
            StackFileWatcher.blockerBudgetPollIntervals &* pollIntervalNanos)
    }
    var blockingGraceNanos: UInt64 { quietPeriodNanos }
    var blockingCeilingNanos: UInt64 {
        blockingBudgetNanos &+ StackFileWatcher.maxBlockerGraceExtensions &* blockingGraceNanos
    }

    /// Cold1 I3: ordering machinery — mark, drops, holdback, blocking deadline — exists for
    /// replay/revision semantics, i.e. `.mutableStackerOutput` only. Numeric SORTING stays
    /// for both policies (harmless determinism within a pass).
    var revisionOrderingEnabled: Bool { digestPolicy == .mutableStackerOutput }
}

// MARK: - Read plan and observations (the reducer/effect cycle's data boundary)

/// How the reducer classifies one directory entry — attached to every read request and
/// copied verbatim by the driver into the resulting observation.
enum WatcherEntryKind: Equatable, Sendable {
    /// The fixed-name in-place-rewritten file under the mutable policy — permanently
    /// exempt from the identity fast path (full rehash every stable sighting).
    case classicMutable
    /// A numbered stacker revision of the configured prefix (anchored parse).
    case numbered(revision: String)
    /// Any other entry under the immutable policy.
    case immutable
}

/// One eligible directory entry after the driver's cheap open/fstat step (the enumeration
/// filters — hidden/.tmp/extension/prefix — remain driver concerns).
struct EnumeratedEntry: Equatable, Sendable {
    let name: String
    let url: URL
    let identity: FileIdentity
    let isFITS: Bool
}

/// The reducer's per-entry read decision (spec §2.1 step 1). `.acceptIdentity` is the O(1)
/// fast path: the completed observation is returned ready-made, no content work required.
/// `.readContent` instructs the driver to run the full pinned-descriptor read (header +
/// digest); open/stat/type failures become `.invalid` observations directly and never
/// enter the plan.
enum ReadRequest: Equatable, Sendable {
    case acceptIdentity(FileObservation)
    case readContent(name: String, url: URL, kind: WatcherEntryKind,
                     identity: FileIdentity, isFITS: Bool)
}

/// Everything the driver learned about one candidate file this pass, as pure data.
struct FileObservation: Equatable, Sendable {
    let name: String
    let url: URL
    let kind: WatcherEntryKind
    let outcome: ObservationOutcome
}

/// Why/how a tracked or enumerated file observed this pass. The driver must supply EXACTLY
/// ONE observation per tracked name (absences included — the complete-batch contract) and
/// one per eligible enumerated candidate.
enum ObservationOutcome: Equatable, Sendable {
    /// Tracked name absent from this pass's (fd-pinned) enumeration.
    case absent
    /// Present but invalid (open/stat failure, zero size, malformed or incomplete FITS,
    /// digest read failure) — pending evidence must die; the file re-earns from zero.
    case invalid(reason: String)
    /// Two-tick stability in progress: first sighting, changed identity, or a mid-read
    /// revalidation mismatch (the LATEST clean stat is reported and stability re-earns
    /// from it — review6 finding 1 branch shape). No content facts this pass.
    case unstable(identity: FileIdentity)
    /// The identity fast-path accepted (spec §2.5): the fresh fstat equals a settlement
    /// identity, so content is trusted unchanged and no read was performed.
    case identityUnchanged(identity: FileIdentity)
    /// Stable identity + (for FITS) complete header + full-file digest, all from the same
    /// pinned descriptor, revalidated after the read.
    case digested(identity: FileIdentity, digest: String, byteCount: Int)
}

/// A fully gate-passed emission candidate — the payload of `.ready` and of every emission
/// intent, carrying everything the driver needs to yield without re-deriving facts.
struct EmissionCandidate: Equatable, Sendable {
    let name: String
    let url: URL
    let kind: WatcherEntryKind
    let identity: FileIdentity
    let digest: String
    let byteCount: Int
}

/// One complete immutable observation batch (spec §2.1 step 2): every tracked name and
/// eligible candidate, tracked absences included, one monotonic clock reading.
struct ObservationBatch: Equatable, Sendable {
    let generation: FolderGeneration
    let entries: [FileObservation] // complete batch, including tracked absences
    let nowNanos: UInt64
}

// MARK: - Commands and effects (the reducer's ONLY inputs and outputs)

enum WatcherCommand: Equatable, Sendable {
    /// A disappear/return, re-arm, or `(dev, ino)` replacement event: construct a fresh
    /// `GenerationState` under the driver-allocated monotonic token. Never clears fields
    /// individually; the outer dedup table is retained unchanged.
    case replaceGeneration(FolderGeneration)
    /// Apply one complete observation batch synchronously (spec §2.1 step 3).
    case observe(ObservationBatch)
    /// The driver's yield result for one emission intent (spec §2.1 step 4). Only a
    /// successful, current-generation result settles `.ready` → `.settled(.emittedNow)`
    /// and overwrites the dedup entry. A stale-generation result is a no-op.
    case emissionFinished(EmissionResult)
}

/// A generation-tagged emission the driver must attempt to yield (after its existing
/// folder-identity revalidation). URL construction and yielding stay driver concerns.
struct EmissionIntent: Equatable, Sendable {
    let generation: FolderGeneration
    let candidate: EmissionCandidate
}

struct EmissionResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable { case yielded, rejected }
    /// The ORIGINAL generation-tagged intent, returned whole so the reducer can validate
    /// the generation and settle the exact candidate that was yielded.
    let intent: EmissionIntent
    let outcome: Outcome
}

/// Ordered reducer output: the driver executes these in returned order.
enum WatcherEffect: Equatable, Sendable {
    case log(String)
    case emit(EmissionIntent)
}

// MARK: - The reducer (spec §2 — the ONLY semantic mutation site of the watcher)

/// Command-driven reducer: `(state, command, configuration) → (state′, ordered effects)`.
/// No filesystem access, no side effects, no hidden clocks — a pass is fully determined by
/// its inputs. Evidence separation (spec §2.2, kills review-12 P1-1):
/// - ORDERING evidence is derived from states: `settled(.emittedNow)` names are
///   `emittedThisGeneration`; the high-water mark is their maximum revision. Both die with
///   the generation because `replaceGeneration` swaps the whole `GenerationState`.
/// - DEDUP evidence is the outer `lastEmittedDigestByName` (latest digest per name,
///   overwritten at each settlement, survives generations). Consulted at exactly one site.
struct WatcherReducer {
    private(set) var state: WatcherState
    let configuration: WatcherReducerConfiguration

    /// The ONE anchored revision parser (review9 items 1+2), compiled from
    /// `configuration.filePrefix` exactly as the scan loop compiles its own today:
    /// `^<escapedPrefix>_([0-9]+)\.([^.]+)$`, case-insensitive, supported image extension
    /// required. `readPlan` attaches its classification to each request; the driver copies
    /// it into the resulting observation — but ordering logic always re-derives from this
    /// parser, so classification and the order gate can never disagree.
    private let revisionRegex: NSRegularExpression?

    init(state: WatcherState, configuration: WatcherReducerConfiguration) {
        self.state = state
        self.configuration = configuration
        if let prefix = configuration.filePrefix, !prefix.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: prefix)
            // Escaped data + fixed syntax cannot fail to compile; a nil regex would only
            // mean "no numbered revisions recognized" — strictly more conservative.
            self.revisionRegex = try? NSRegularExpression(
                pattern: "^\(escaped)_([0-9]+)\\.([^.]+)$", options: [.caseInsensitive])
        } else {
            self.revisionRegex = nil
        }
    }

    // MARK: Classification

    /// The digit-string revision of `name` when it is a numbered revision of the configured
    /// prefix; nil for everything else — including the classic fixed-name file and
    /// near-misses, which conservatively keep full mutable-policy re-hashing.
    func revisionSuffix(of name: String) -> String? {
        guard let regex = revisionRegex else { return nil }
        let range = NSRange(name.startIndex..., in: name)
        guard let m = regex.firstMatch(in: name, options: [], range: range),
              let digitsRange = Range(m.range(at: 1), in: name),
              let extRange = Range(m.range(at: 2), in: name) else { return nil }
        let ext = name[extRange].lowercased()
        guard ImageLoader.fitsExtensions.contains(ext) || ImageLoader.bitmapExtensions.contains(ext)
        else { return nil }
        return String(name[digitsRange])
    }

    func entryKind(of name: String) -> WatcherEntryKind {
        if let revision = revisionSuffix(of: name) { return .numbered(revision: revision) }
        return configuration.digestPolicy == .mutableStackerOutput ? .classicMutable : .immutable
    }

    // MARK: Read plan (spec §2.1 step 1)

    /// Derive the per-entry read plan from current state. `.acceptIdentity` is selected
    /// ONLY for a settled immutable or numbered entry whose current identity equals the
    /// settlement payload (spec §2.5 — both settlement variants arm the fast path). Every
    /// other regular entry gets `.readContent`; the classic mutable file ALWAYS does
    /// (permanent full-rehash policy).
    func readPlan(for entries: [EnumeratedEntry]) -> [ReadRequest] {
        entries.map { entry in
            let kind = entryKind(of: entry.name)
            if kind != .classicMutable,
               case .settled(let settlement)? = state.generation.files[entry.name],
               settlement.identity == entry.identity {
                return .acceptIdentity(FileObservation(
                    name: entry.name, url: entry.url, kind: kind,
                    outcome: .identityUnchanged(identity: entry.identity)))
            }
            return .readContent(name: entry.name, url: entry.url, kind: kind,
                                identity: entry.identity, isFITS: entry.isFITS)
        }
    }

    // MARK: Reduce

    mutating func reduce(_ command: WatcherCommand) -> [WatcherEffect] {
        switch command {
        case .replaceGeneration(let id):
            // Wholesale replacement (spec §2.1): all per-file states, the episode, and any
            // outstanding intents' authority die here as a TYPE property — never a set of
            // coordinated clears. The dedup table is the sole survivor (spec §2.2).
            state.generation = GenerationState(id: id, files: [:],
                                               ordering: RevisionOrderingState(activeBlocker: nil))
            return []

        case .observe(let batch):
            // A batch gathered under a superseded generation must not touch the fresh one
            // (the same wholesale-replacement rule that governs emission results).
            guard batch.generation == state.generation.id else { return [] }
            return observe(batch)

        case .emissionFinished(let result):
            // Generation validation at the result boundary: an intent from an old folder
            // generation cannot settle in the current one, even if the filesystem reused
            // (dev, ino) — the monotonic token, not the directory identity, is compared.
            guard result.intent.generation == state.generation.id else { return [] }
            guard result.outcome == .yielded else {
                // Rejected by the driver's pre-yield revalidation: the intent is discarded
                // and the file (still `.ready`, evidence intact) stays re-emittable. No
                // dedup update — nothing was delivered.
                return []
            }
            // The ONLY transition into `.settled(.emittedNow)` and the ONLY dedup
            // overwrite (spec §2.1 step 4): a yield actually happened, so record it —
            // this is what makes an outstanding intent "not emitted yet" everywhere else.
            let candidate = result.intent.candidate
            state.generation.files[candidate.name] =
                .settled(.emittedNow(identity: candidate.identity, digest: candidate.digest))
            state.lastEmittedDigestByName[candidate.name] = candidate.digest
            if state.generation.ordering.activeBlocker?.blocker == candidate.name {
                // The blocker emitted — its episode is over (the next observe pass's
                // derived-invariant check would also conclude this; clearing here keeps
                // the episode honest between commands).
                state.generation.ordering.activeBlocker = nil
            }
            return []
        }
    }

    // MARK: Observe (spec §2.1 step 3 — one complete batch, applied synchronously)

    private mutating func observe(_ batch: ObservationBatch) -> [WatcherEffect] {
        let config = configuration
        let now = batch.nowNanos
        let generationID = state.generation.id
        let startFiles = state.generation.files      // pass-start states for victim flags
        var files = state.generation.files
        var dedup = state.lastEmittedDigestByName
        var episode = state.generation.ordering.activeBlocker
        var effects: [WatcherEffect] = []

        // One observation per name (driver contract); a later duplicate wins defensively.
        var obsByName: [String: FileObservation] = [:]
        for o in batch.entries { obsByName[o.name] = o }
        let presentNames = Set(obsByName.values.lazy.filter { $0.outcome != .absent }.map(\.name))

        // ---- Phase 1: absence (spec §2.4, pin 2). Tracked names with no observation at
        // all are treated as absent (a driver-contract violation degrades conservatively:
        // pending evidence dies, terminal states stay immortal).
        for (name, fileState) in files where !presentNames.contains(name) && !fileState.isTerminal {
            files[name] = nil
        }

        // ---- Phase 2: derive the high-water mark from settled(.emittedNow) — the ONLY
        // ordering evidence (pin: deleting an emitted revision cannot regress the mark,
        // because terminal states are immortal under absence). Revisions come from the
        // reducer's own parser, never from the dedup table.
        let ordering = config.revisionOrderingEnabled
        var mark: String? = nil
        if ordering {
            for (name, fileState) in files where fileState.isEmittedNow {
                guard let rev = revisionSuffix(of: name) else { continue }
                if mark.map({ RevisionOrdering.numericCompare(rev, $0) == .orderedDescending })
                    ?? true { mark = rev }
            }
        }

        // ---- Phase 3: deterministic candidate order (review9 item 2), revisions parsed
        // once per name.
        let candidates = obsByName.values.filter { $0.outcome != .absent }
            .map { (obs: $0, revision: revisionSuffix(of: $0.name)) }
            .sorted { RevisionOrdering.orderedBefore(($0.obs.name, $0.revision),
                                                     ($1.obs.name, $1.revision)) }

        // ---- Phase 4: later-victim suffix flags from PASS-START states (review11: a
        // failing revision runs the deadline only while it actually BLOCKS someone). A
        // potential victim is a later, present, numbered revision whose state is
        // nonterminal — including untracked first sightings. A `ready` file with an
        // in-flight intent is nonterminal, so it still counts (an outstanding intent is
        // NOT emitted evidence). The dedup table takes NO part in this (review-12 P1-1).
        var laterVictim = [Bool](repeating: false, count: candidates.count)
        if ordering {
            var seen = false
            for i in stride(from: candidates.count - 1, through: 0, by: -1) {
                laterVictim[i] = seen
                let c = candidates[i]
                if c.revision != nil, !(startFiles[c.obs.name]?.isTerminal ?? false) { seen = true }
            }
        }

        // ---- Phase 5: one ordered pass. `holdActive` is the review10 holdback: once a
        // numbered revision proves not yet emittable, no higher-numbered revision emits
        // this pass (gates still advance; the dedup guard still settles).
        var holdActive = false

        for (index, element) in candidates.enumerated() {
            let obs = element.obs
            let name = obs.name
            let revision = ordering ? element.revision : nil   // cold1 I3: machinery is mutable-only
            let fileState = files[name]

            // Terminal-and-dead names are inert: written off or dropped this generation —
            // no gates, no holds, no repeat logs (log-once lives in the state itself).
            if fileState == .writtenOff || fileState == .droppedOutOfOrder { continue }

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
                files[name] = .writtenOff
                let heldSeconds = Int((Double(now &- ep.startNanos) / 1_000_000_000).rounded())
                effects.append(.log("revision \(revision) blocked emissions for \(heldSeconds)s "
                                    + "without completing — abandoning it; later revisions proceed "
                                    + "(frame lost: \(name))"))
                holdActive = false
            }

            /// Stage an emission (spec §2.1 step 4's first half): the file parks in
            /// `.ready` with the full candidate and the intent goes out as an effect. It
            /// is NOT settled, the dedup table is NOT touched, the mark does NOT advance —
            /// only `.emissionFinished(.yielded)` does those (settle-on-yield).
            func stage(_ candidate: EmissionCandidate) {
                files[name] = .ready(candidate)
                effects.append(.emit(EmissionIntent(generation: generationID,
                                                    candidate: candidate)))
            }

            /// Settle back onto the last emission WITHOUT emitting: pending evidence is
            /// consumed and the identity fast-path re-arms (spec §2.5/§2.6). A name that
            /// already emitted this generation keeps its `emittedNow` standing (identity
            /// updated) — identical content republished under a fresh identity must not
            /// regress the derived mark or the emitted-this-generation set.
            func settleDuplicate(stat: FileIdentity, digest: String) {
                if case .settled(.emittedNow)? = fileState {
                    files[name] = .settled(.emittedNow(identity: stat, digest: digest))
                } else {
                    files[name] = .settled(.duplicateOfLastEmission(identity: stat, digest: digest))
                }
            }

            /// Shared stat-sighting rule for `.unstable` and `.identityUnchanged` (both are
            /// stat-only facts): a settled name re-sighted at its settlement identity is
            /// inert (fast-path hit); any other sighting restarts or holds two-tick
            /// stability at the reported identity and counts as a failure to emit.
            func reduceStatSighting(_ stat: FileIdentity) {
                if case .settled(let settlement)? = fileState {
                    if settlement.identity == stat { return }   // fast-path hit: inert
                    // The published version moved: it re-earns everything from zero.
                    files[name] = .observing(stat: stat)
                    failedToEmit(converging: false)
                    return
                }
                if fileState?.statBasis != stat {
                    // First sighting or unstable identity (incl. the mid-read revalidation
                    // mismatch, which reports the LATEST clean stat): stability restarts.
                    files[name] = .observing(stat: stat)
                }
                // Stable-but-no-content is still not emittable this pass.
                failedToEmit(converging: false)
            }

            // REJECT BELOW THE MARK (review10 item 1b): a numbered revision that has not
            // emitted THIS GENERATION (state-derived — a dedup-table entry is NOT an
            // exemption, review-12 P1-1) at or below the mark arrived out of order.
            // Settled names are exempt: their re-sightings are governed by the fast-path
            // and the dedup guard, never re-dropped.
            if let revision, !(fileState?.isSettled ?? false), let m = mark,
               RevisionOrdering.numericCompare(revision, m) != .orderedDescending {
                files[name] = .droppedOutOfOrder
                effects.append(.log("revision \(revision) arrived out of order — skipped "
                                    + "(high-water \(m))"))
                continue
            }

            switch obs.outcome {
            case .absent:
                continue    // not a candidate (filtered above); unreachable

            case .invalid:
                // Observed invalidity resets EVERYTHING pending (review10 item 2):
                // stability and content evidence re-earn from zero. A SETTLED file stays
                // settled — settlement is content-delivery history, not pending evidence;
                // it neither resurrects gates nor blocks anyone (a settled name satisfied
                // the order already, so it cannot be the head-of-line failure).
                if fileState?.isSettled ?? false { continue }
                files[name] = nil
                failedToEmit(converging: false)

            case .unstable(let stat):
                reduceStatSighting(stat)

            case .identityUnchanged(let stat):
                // The read-plan fast path round-tripped (spec §2.5). Reduced by the same
                // stat-sighting rule: a settlement-identity match is inert; anything else
                // (a driver-contract drift) degrades conservatively to re-earning.
                reduceStatSighting(stat)

            case .digested(let stat, let digest, let byteCount):
                // Two-tick stability: content evidence only counts under the exact
                // identity the state already holds; any mismatch restarts stability (and
                // the digest gate with it — review8 finding 1).
                guard let basis = fileState?.statBasis, basis == stat else {
                    files[name] = .observing(stat: stat)
                    failedToEmit(converging: false)
                    continue
                }
                // DEDUP GUARD — the reducer's ONLY consultation of the dedup table, and it
                // runs BEFORE the digest gate and BEFORE the holdback (a held victim can
                // settle and stop counting, spec §2.3).
                if dedup[name] == digest {
                    settleDuplicate(stat: stat, digest: digest)
                    continue
                }
                let candidate = EmissionCandidate(name: name, url: obs.url, kind: obs.kind,
                                                  identity: stat, digest: digest,
                                                  byteCount: byteCount)
                if config.digestPolicy == .mutableStackerOutput {
                    // Digest-stability gate (review8 finding 1).
                    switch fileState {
                    case .digestPending(let pending)
                        where pending.digest == digest && pending.identity == stat:
                        guard now >= pending.firstObservedNanos,
                              now &- pending.firstObservedNanos >= config.quietPeriodNanos else {
                            // Mid-gate, and the ONLY converging branch: the SAME pending
                            // digest observed again under a stable identity.
                            failedToEmit(converging: true)
                            continue
                        }
                        if revision != nil, holdActive {
                            // Gate earned but held below a blocker: park in `ready` with
                            // the evidence intact (emits the pass the blocker clears).
                            files[name] = .ready(candidate)
                            continue
                        }
                        stage(candidate)
                    case .ready(let held) where held.digest == digest && held.identity == stat:
                        if revision != nil, holdActive { continue }   // still held, evidence intact
                        stage(candidate)
                    default:
                        // A NEW digest (or a changed one, or readiness invalidated by a
                        // digest change) starts the gate over — churn, never convergence.
                        files[name] = .digestPending(PendingDigest(digest: digest, identity: stat,
                                                                   firstObservedNanos: now))
                        failedToEmit(converging: false)
                    }
                    continue
                }
                // Immutable policy: no content gate, no ordering machinery — a stable,
                // valid, undelivered file stages its emission now.
                stage(candidate)
            }
        }

        // ---- Phase 6: the episode is a DERIVED property of the state table (pin 1) —
        // re-check the invariant against the FINAL states. It survives only while its
        // blocker is present and nonterminal AND at least one later, present, nonterminal
        // numbered revision remains to be starved. This is the lone-period teardown and
        // the settled/absent-blocker teardown in one rule; the next episode, whenever it
        // forms, runs a fresh clock. (A blocker that STAGED an emission this pass is still
        // nonterminal `ready` — its episode ends at `.emissionFinished(.yielded)`.)
        if let ep = episode {
            let blockerAlive = presentNames.contains(ep.blocker)
                && !(files[ep.blocker]?.isTerminal ?? false)
            let blockerRevision = revisionSuffix(of: ep.blocker)
            let hasVictim = candidates.contains { c in
                guard c.obs.name != ep.blocker, c.revision != nil,
                      !(files[c.obs.name]?.isTerminal ?? false) else { return false }
                return RevisionOrdering.orderedBefore((ep.blocker, blockerRevision),
                                                      (c.obs.name, c.revision))
            }
            if !blockerAlive || !hasVictim { episode = nil }
        }

        state.generation.files = files
        state.generation.ordering.activeBlocker = episode
        state.lastEmittedDigestByName = dedup
        return effects
    }
}
