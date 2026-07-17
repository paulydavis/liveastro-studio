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

Each filename in the current folder generation carries exactly one state:

```
enum FileState {
    case observing(stat: StatEvidence)                 // earning two-tick stability
    case digestPending(digest: String, identity: FileIdentity,
                       firstObservedNanos: UInt64)     // mutable-policy content gate
    case ready                                         // all gates passed, awaiting order
    case settled(Settlement)                           // emittedNow | duplicateOfLastEmission
    case droppedOutOfOrder                             // ≤ high-water on first sight; log-once
    case writtenOff                                    // blocker deadline expired; log-once
}

enum Settlement {
    case emittedNow(identity: FileIdentity)
    case duplicateOfLastEmission(identity: FileIdentity)
}
```

The scan becomes two phases: **observe** (pure filesystem reads on the pinned
descriptors — stat, header, digest; no state mutation) and **reduce** (one
synchronous pass applying the complete observations to the state table). All
mutation happens in the reducer. This is the reducer/effect split from the
ledgered simplification constraints, applied to the watcher.

### 2.2 Type-separated evidence (kills P1-1)

- `emittedThisGeneration: Set<String>` — **ordering evidence**. Derived from
  states (`settled(.emittedNow)`); dies with the folder generation; drives
  blocker accounting and the high-water mark.
- `lastEmittedDigestByName: [String: String]` — **dedup evidence**. Latest
  digest per name, overwritten at each emission; **survives folder
  generations** (content-bound, per the documented asymmetry with
  location-bound identities). Consulted at exactly one reducer site: settling
  `duplicateOfLastEmission`.

Latest-per-name is deliberate and test-pinned: A→B→A re-emits A (a stacker
legitimately returning to earlier content must not freeze the broadcast), and
a global digest set would suppress Siril's byte-identical consecutive
revisions, punching holes the order machinery would then fight. The name
`contentDigestsEverEmitted` must not appear anywhere — it reads as set
semantics.

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

## 3. The reseed/master contract (kills P1-3)

### 3.1 Two ledgers, explicitly named

- **Session history** (monotone; reseed never touches it): accepted/rejected
  counts, snapshot records, integration wall-time. Already structured this way
  in `StackEngine` (`acceptedCount` etc. documented session-monotone).
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
unchanged); the master-before-`endSession()` commit ordering is untouched.

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

**Product note (ledger, not contract):** a reseed near session end now
provably discards the night's durable master (snapshots survive). A future
UI affordance — "checkpoint master before reseed" — can restore that without
touching this contract.

### 3.5 Header and manifest truth: store the count, derive the exposure (refinement 4)

`STACKCNT` = current-stack frame count from the atomic snapshot; `TOTALEXP`
is **derived** at its consumers as `stack_frame_count × subExposureSeconds`
(the manifest already carries `subExposureSeconds` — persisting a separate
exposure field would recreate the derivable-drift pair eliminated for the
high-water mark). Today's header mixes provenance (`STACKCNT` = session total
at SessionPipeline.swift:583 while `TOTALEXP` is already current-stack at
:578); the change is one provenance flip. The manifest stores
`stack_frame_count` plus the session accepted/rejected finals from the same
`finalizationState()` snapshot; snapshot records retain session history,
unchanged.

### 3.6 Oracle clause 5 (non-circular)

Clause 5 becomes: `end_time set && masterExpected` ⇒ `master_outcome`
present and consistent: `written` ⇒ `master.fit` durable **and decodes** and
its `STACKCNT == stack_frame_count`; `awaiting_seed` / `no_frames` ⇒ honest
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

`SessionPipeline.reseed()` no-ops with an honest log when
`source?.isFinite == true`. The batch contract ("MUST NOT mutate the engine
during the concurrent phase") is today documentation plus UI gating only;
violating it is a genuine data race (`register()` reads reference state
lock-free). This converts the documented contract into a checked one; live
mode is unchanged.

## 4. The review-12 P2 wave (separate, conventional, after this lands)

Oracle decodes `master.fit` (clause 5 currently passes a directory/empty/garbage
file); handshake watchdog extended to cover transport connect; send-chain
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
