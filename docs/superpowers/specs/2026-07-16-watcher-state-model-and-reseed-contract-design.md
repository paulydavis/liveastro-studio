# Watcher State Model + Reseed/Master Contract — Design

**Trigger:** outside review #12 found three watcher/session P1s on main `b5d21bd`,
activating the recorded convergence rule: stop patching individual interleavings
in the failed component; simplify its state model. The failed component is the
watcher's numbered-revision ordering subsystem (eight per-name maps mutated
under cross-generation and cross-role rules), plus one session-truth defect
(reseed vs. `end()`). This spec replaces the ordering machinery with a per-file
state machine driven by a synchronous reducer, and states the reseed/master
contract explicitly. Design reviewed and approved by the outside design
consultation (2026-07-16), including four required pins (§2.6) and four
required amendments (§3.6).

**Non-goals:** no behavior change to stat stability, FITS completeness, digest
computation, digest policies, emission identity, generation detection, or the
OBS layer. The seven review-12 P2s are a separate conventional wave (§4).

---

## 1. The defect class being closed

- P1-1: `lastEmittedDigest` (content dedup evidence, survives folder
  generations) was consulted as *generation-local ordering evidence* — a
  replaced same-name file was excluded from blocker accounting, so a bad
  `_00001` held a changed `_00002` forever with no deadline and no log, and a
  new generation could emit `[3, 2]`.
- P1-2: blocker deadlines lived in a side map keyed by name; a revision held as
  a *victim* did not clear a deadline it had acquired earlier as a *blocker*,
  so a role round-trip inherited an expired clock and was written off instantly.
- Root cause (reviewer's phrasing, adopted as the brief): *retained digest
  history used as ordering evidence instead of dedup evidence only.* The fix is
  type separation and a single authoritative state per file — making the
  confusions unrepresentable, not re-guarded.

## 2. The watcher state model

### 2.1 One authoritative state per file

The cross-generation survival rule is represented by the type boundary, not
by coordinated clearing calls:

```
struct WatcherState {
    var generation: GenerationState
    var lastEmittedDigestByName: [String: String]  // the sole survivor
}

struct GenerationState {
    let id: FolderGeneration
    var files: [String: FileState]
    var ordering: RevisionOrderingState
}

struct RevisionOrderingState {
    var activeBlocker: BlockingEpisode?
}
```

`FolderGeneration` is a monotonically increasing token, not merely the current
directory `(dev, ino)`: disappear/return must invalidate old intents even when
the filesystem later reports a reused identity.

A disappear/return, re-arm, or `(dev, ino)` replacement event constructs a
fresh `GenerationState`; it never clears generation fields individually. The
outer `lastEmittedDigestByName` map is retained unchanged.

Each filename in the current folder generation carries exactly one state:

```
enum FileState {
    case observing(stat: StatEvidence)                 // earning two-tick stability
    case digestPending(digest: String, identity: FileIdentity,
                       firstObservedNanos: UInt64)     // mutable-policy content gate
    case ready(candidate: EmissionCandidate)           // all gates passed, awaiting order
    case settled(Settlement)                           // emittedNow | duplicateOfLastEmission
    case droppedOutOfOrder                             // ≤ high-water on first sight; log-once
    case writtenOff                                    // blocker deadline expired; log-once
}

enum Settlement {
    case emittedNow(identity: FileIdentity, digest: String,
                    replacement: ReplacementProgress? = nil)
    case duplicateOfLastEmission(identity: FileIdentity, digest: String,
                                 replacement: ReplacementProgress? = nil)
}

enum ReplacementProgress {
    case observing(stat: StatEvidence)
    case digestPending(digest: String, identity: FileIdentity,
                       firstObservedNanos: UInt64)
    case ready(candidate: EmissionCandidate)
}
```

The nested replacement progress is deliberate. If the same numbered filename
is replaced in place, its outer settlement remains the generation's ordering
evidence while the replacement re-earns stat and digest gates. Identical bytes
refresh the settlement identity and clear the nested progress without an
emission; changed bytes may emit only after the nested state reaches `ready`.
This avoids both a permanently stranded replacement and a regressing derived
high-water mark, without introducing a parallel side table.

The scan becomes a reducer/effect cycle:

1. The reducer derives a read plan from current state. Settled numbered and
   immutable entries with a matching current-generation identity retain the
   O(1) fast path; the classic mutable file still requests a full digest.
2. The effect layer gathers one complete immutable observation batch through
   the pinned directory/file descriptors (enumeration, stat, header, digest).
   It never mutates semantic state.
3. The reducer applies the complete batch synchronously, after every later
   candidate has been classified as changed, duplicate, incomplete, or absent.
   It returns ordered log, lifecycle, and emission intents tagged with the
   folder-generation id.
4. Before yielding an emission, the driver performs the existing folder-
   identity revalidation. The yield result returns to the reducer as an event;
   only a successful yield transitions `ready` to `settled(.emittedNow)` and
   updates `lastEmittedDigestByName`. A generation mismatch discards the old
   intent and replaces `GenerationState` wholesale.

No semantic mutation occurs outside the reducer. Consumer-side verification
of the emitted file identity/digest remains unchanged and continues to close
the residual path-resolution race after yield.

### 2.2 Type-separated evidence (kills P1-1)

- `emittedThisGeneration` — a **derived projection**, never a stored set. It
  consists of names in `settled(.emittedNow)`; it dies with the folder
  generation and drives blocker accounting and the derived high-water mark.
- `lastEmittedDigestByName: [String: String]` — **dedup evidence**. Latest
  digest per name, overwritten at each emission; **survives folder
  generations** (content-bound, per the documented asymmetry with
  location-bound identities). Consulted at exactly one reducer site: settling
  `duplicateOfLastEmission`.

Latest-per-name is deliberate and test-pinned: A→B→A re-emits A (a stacker
legitimately returning to earlier content must not freeze the broadcast), and
a global digest set would suppress Siril's byte-identical consecutive
revisions, punching holes the order machinery would then fight. No plural or
"ever emitted" alternative name is permitted; either would imply set semantics
rather than the approved latest-per-name contract.

- `lastEmittedIdentity` (the immutable fast-path) is carried in the
  `Settlement` payloads (§2.5) and dies with the generation, unchanged.

### 2.3 Blocking as a derived property (kills P1-2)

There is at most **one** `BlockingEpisode` per folder, not a per-name map:

```
struct BlockingEpisode {
    let blocker: String            // head-of-line revision failing to emit
    let startNanos: UInt64         // monotonic; episode-scoped
    var deadlineNanos: UInt64      // start + budget, grace-extended, ≤ start + ceiling
}
```

**Episode invariant (required pin 1):** an episode exists **iff** the
head-of-line numbered revision fails to emit **and at least one later,
never-emitted (nonterminal potential victim) numbered revision is present**.
The lone-period teardown — no victims ⇒ episode destroyed — is the
load-bearing rule (cold2 I1 was a blocker that neither changed nor disappeared
while its victims vanished). A held revision that settles as
`duplicateOfLastEmission` stops counting as a victim and can end the episode
(the dedup guard runs before the holdback). Because the clock is a field of
the single episode and the episode is derived from the state table each pass,
a role round-trip cannot inherit a clock: there is no keyed map to inherit
from. Budget, grace, and ceiling semantics are unchanged from cold2
(budget = max(30 s, 10×quiet, 5×poll); grace = one quiet period per converging
observation; hard total ceiling = budget + 4×quiet; churn never resets;
write-off = honest log, `writtenOff` state, mark not advanced).

### 2.4 Per-state absence semantics (required pin 2)

On a scan where a tracked name is absent from the (fd-pinned) enumeration:

- `observing`, `digestPending`, `ready` — **die** (pending evidence dies;
  review-10 item 2 unchanged).
- Replacement progress nested in a `settled` state also **dies**, while its
  outer settlement remains immortal and continues to anchor ordering evidence.
- `settled`, `droppedOutOfOrder`, `writtenOff` — **immortal within the
  generation**: a briefly-invisible corpse must not resurrect (pinned); dropped
  stays dropped, log-once; and the high-water mark, being derived from
  `settled(.emittedNow)`, cannot regress when an emitted revision is deleted —
  which is precisely what makes deriving the mark safe and removes the stored
  mark/state drift pair.

All states die at a folder-generation change, except the dedup table (§2.2).
The seven coordinated `removeAll()` calls become a type property of the state
table.

### 2.5 Settlements arm the fast-path (required pin 3)

Both `emittedNow` and `duplicateOfLastEmission` carry the observed
`FileIdentity` and arm the identity fast-path for numbered revisions and the
immutable policy — the shipped code records `lastEmittedIdentity` in the dedup
branch specifically so a re-published identical revision stops being re-hashed
every scan; the cost-model test pins this. The classic fixed-name file is
exempt (permanent full-rehash policy).

### 2.6 Classic-file transitions (required pin 4)

The classic in-place file moves `settled → digestPending` on digest change,
and settling back onto the last-emitted digest lands `duplicateOfLastEmission`
with the pending evidence consumed: A→(transient B)→A emits nothing;
A→B(emitted)→A re-earns the gate and emits A again. Both directions follow
from latest-digest-per-name and are already test-pinned.

### 2.7 Conformance oracle (acceptance criterion for the implementation)

The existing suite is the behavioral contract. In particular, these pass
**unmodified** or the port has drifted semantics (a finding, not an
adaptation): `testMutablePolicy_loneBlockerPeriodNotCharged_freshClockPerBlockingEpisode`,
`testMutablePolicy_writeOffLogReportsEpisodeDuration_notLoneWallTime`, the
oscillator/ceiling pair, the mark-drop tests, the digest-computation
cost-model test — plus the full watcher suite. The sanctioned exceptions are
listed in §3.5 (deliberate reseed-contract changes) and harness-mechanical
edits only.

The reducer additionally gets deterministic pins for both review-12 P1 traces,
victim disappearance/reappearance, state-specific absence, whole-generation
replacement, both settlement fast paths, classic A→(transient B)→A, and
stale-generation effect rejection. Table/property tests assert that within one
generation: the derived high-water never decreases; `activeBlocker` exists iff
the episode invariant in §2.3 holds; no higher revision emits behind a blocker;
and generation replacement preserves only `lastEmittedDigestByName`.

## 3. The reseed/master contract (kills P1-3)

### 3.1 Two ledgers, explicitly named

- **Session history** (monotone; reseed never touches it): accepted/rejected
  engine counts and snapshot records. Engine accepted count, engine rejected
  count, and durable `snapshots.count` are three distinct facts: a snapshot
  persistence failure can make accepted count exceed snapshot count, and no
  rejected count is persisted today. The final manifest therefore gains
  explicit optional session accepted/rejected totals; snapshots remain their
  own durable ledger. Fields are optional for legacy decoding.
- **Current stack** (reset by manual or automatic reseed): accumulator,
  reference, `stackFrameCount`. Current-stack **exposure is derived**
  (`stackFrameCount × profile.subExposureSeconds`), not a fourth ledger
  (amendment 4).

### 3.2 Stored `CurrentStackState`, event-driven — never derived (refinement 1)

The engine stores an explicit stack state, transitioned **only on named
events** (seed, commit-of-seed, manual reseed, auto-reseed):

```
enum CurrentStackState {
    case initialEmpty                                  // no seed yet this session
    case active                                        // stack has frames
    case awaitingSeedAfterReseed(manual: Int, auto: Int)  // cleared, not re-seeded
}
```

It must **not** be derived from `accumulator == nil && reseedCount > 0` — a
derived state self-exempts on accidental accumulator loss. Stored state vs.
reality disagreement is the *breach signal*: stored `.active` with a nil
accumulator (or `accepted > 0` under stored `.initialEmpty`) means the engine
is corrupt — `end()` **throws and does not stamp `end_time`** (the session
stays recoverable, per the invariant). Auto-reseed is a first-class door to
`awaitingSeedAfterReseed` (refinement 2): the counts distinguish manual from
automatic, and no persisted outcome or log line may claim an operator action
when auto-reseed did it.

### 3.3 Master decision, atomic snapshot, finalization barrier (amendment 1 + refinement 3)

`end()` writes `master.fit` **iff `CurrentStackState == .active`**. It reads
one **atomic engine snapshot** — `finalizationState()` returning (image,
coverage, frameCount, stackState, session accepted/rejected finals) under a
single lock acquisition — once, after the drain completes, before the write.
Header `STACKCNT`, the manifest facts, and the outcome all derive from that
single value; today's three separate lock acquisitions tear against a racing
public `reseed()` (masked only by app-side UI gating).

**Finalization barrier:** `end()` claims a barrier that `reseed()` respects
(a reseed after finalization begins is refused with an honest log). Claim
order: reentrancy guard → session-state guard → **then** the barrier — a
rejected reentrant or not-running call must not poison reseed for a live
session. Across a **failed** `end()` (`shutdownTimeout`: session stays
`.running`, `end()` retryable) the barrier **stays claimed** — a reseed
between a failed end and its retry has no legitimate use and reopens the
race. `masterExpected` stays session-semantic and immutable (review-11,
unchanged); under this contract it means that the native current-stack master
policy applies, not that every ended native session unconditionally has an
artifact. `master_outcome` supplies the exhaustive final requirement. The
master-before-`endSession()` commit ordering is untouched.

### 3.4 Honest outcomes: `master_outcome` manifest field + logs

The manifest records `master_outcome` at end, from the atomic snapshot:
`written` | `awaiting_seed` | `no_frames` (and watcher sessions'
`masterExpected == false` needs no outcome). Logs match:

- `.initialEmpty` → `"no frames accepted — no master written"` (the existing
  line, now only for its true case);
- `.awaitingSeedAfterReseed` → `"reference cleared by reseed (manual or
  automatic) and never re-seeded — no master available (N snapshots
  retained)"` — wording covers both doors, and the outcome/log must not
  attribute auto-reseed to the operator;
- `masterExpected == false` → the watcher-mode line, unchanged.

### 3.5 Header and manifest truth: store the count, derive the exposure (refinement 4)

`STACKCNT` = current-stack frame count from the atomic snapshot; `TOTALEXP`
is **derived** at its consumers as `stack_frame_count × subExposureSeconds`
(the manifest already carries `subExposureSeconds` — persisting a separate
exposure field would recreate the derivable-drift pair eliminated for the
high-water mark). Today's header mixes provenance (`STACKCNT` = session total
at SessionPipeline.swift:583 while `TOTALEXP` is already current-stack at
:578); the change is one provenance flip. The manifest stores optional
`stack_frame_count` plus optional session accepted/rejected finals from the
same `finalizationState()` snapshot; snapshot records retain their separate
durable history, unchanged. Running and legacy manifests may omit these
final-only fields.

### 3.6 Oracle clause 5 (non-circular)

Clause 5 becomes: `end_time set && masterExpected` ⇒ `master_outcome`
present and consistent: `written` ⇒ `master.fit` is a regular, nonempty file,
**decodes structurally as FITS**, and its `STACKCNT == stack_frame_count`;
`awaiting_seed` / `no_frames` ⇒ honest
log line matches (clause 6 patterns per §3.4) and no master required. The
outcome is a recorded fact from the atomic snapshot, never an echo of write
success — a failed native master write still trips clause 5 (`.active` count
> 0, `end_time` absent by the review-2 ordering, so a stamped end with
outcome `written` and no decodable master is dishonest by construction).
Legacy manifests without the fields fall back to the review-11 rule
(`!snapshots.isEmpty`), era-documented, decoding never throws.

**Deliberate contract change (sanctioned test-drift exception):** the STACKCNT
provenance flip. Sweep result: **zero existing tests pin the old semantics**
(FITSWriterMetadataTests pins an explicit passed value; CleanExportPipelineTests
pins presence only; NativePipelineTests' integration pin already rides
`stackFrameCount`). The implementation owes these pins: reseed → accept K
frames → end ⇒ master `STACKCNT == K`, manifest `stack_frame_count == K`,
session finals retained; reseed → never re-seeded → end ⇒ no master,
`master_outcome == awaiting_seed`, oracle passes; zero-frame ⇒
`initialEmpty`/`no_frames`, oracle passes; the breach case ⇒ `end()` refuses
to commit (`end_time` nil); the no-reseed case stays byte-identical.

### 3.7 Reseed enforcement on finite imports (amendment 2)

`SessionPipeline.reseed()` rejects the request with a typed
`reseedUnavailableDuringImport` result/error (and an honest app-level log) when
`source?.isFinite == true`; a caller must not have to infer rejection from a
silent no-op. The batch contract ("MUST NOT mutate the engine
during the concurrent phase") is today documentation plus UI gating only;
violating it is a genuine data race (`register()` reads reference state
lock-free). This converts the documented contract into a checked one; live
mode is unchanged.

## 4. The review-12 P2 wave (separate, conventional, after this lands)

The oracle master validation is part of §3 because the reseed/master contract
depends on it. The remaining conventional wave is: handshake watchdog extended
to cover transport connect; send-chain
abandon on reconnect (one stuck send must not poison Retry — BroadcastController
must not skip reconnecting while claiming connected); import enumeration errors
surface instead of becoming `[]` (an unreadable folder must not end as a
successful empty session); scene-list response stamping; the one stale-stop
path missing `runDeferredReconcileIfNeeded()`; OBSClient receive-loop
strong-self promotion + OBSController teardown fallback (client/socket leak);
plus the two debug-test-build warnings (the zero-warnings gate now checks the
test build too).

## 5. Sequencing

Spec (this document, user-reviewed) → implementation plan → SDD execution
(reducer port first, reseed contract second, P2 wave third) → both cold lenses
on the result → outside review. Step 6 (Siril parity) and v3.0.0 + first tag
remain parked behind the whole sequence per the convergence rule.
