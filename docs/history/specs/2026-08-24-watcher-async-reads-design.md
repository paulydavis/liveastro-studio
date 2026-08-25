# Watcher async content-read decoupling — design

**Status:** design, pending review
**Branch:** `fix/watcher-async-reads`
**Related:** the M8 detection stall (root-caused + watchdog-detected in `84704bc`). This is the "never freezes in the first place" follow-up to that watchdog.

## Problem (confirmed root cause)

`StackFileWatcher` polls its watched folder on a single serial queue (`liveastro.watcher`). Every poll, `scan()` calls `observeFile(named:)` **synchronously** for each present file. For a new/unsettled file, `observeFile` takes the `.readContent` path and performs a **blocking** whole-file content digest read (`FileIdentity.contentDigest`, `StackFileWatcher.swift:778`). The fd is opened `O_NONBLOCK` then has non-blocking **cleared** (`openFile`, `fcntl(F_SETFL, flags & ~O_NONBLOCK)`), so that `read()` blocks indefinitely if the backing store stalls (dead SMB mount, iCloud fileprovider that never faults the bytes in).

Because that read runs on the serial poll queue, a single hung read freezes the queue: the poll timer (same queue) can never fire again, so detection silently stops. This exactly matches the M8 all-nighter symptom — app idle ~3% CPU, no data loss, only on the iCloud-synced watch folder; a local-disk repro of 800 subs over 3h stayed clean.

The already-merged watchdog **detects** this (separate `watchdogQueue`, fires `onStall` → macOS notification within 30s) so the operator can end + restart. This design removes the freeze itself.

### Why only the content read blocks

For an iCloud-evicted (dataless) file, `open()` returns immediately with a valid fd and `fstat()` returns metadata **without materializing** the bytes (verified previously; also why the "fstat old published files" path was ruled out as a stall cause). The fileprovider fault happens on the first content `read()`. So `open` + `fstat` + `readPlan` are safe on the serial queue; **only** the `.readContent` digest read (and the FITS header pre-read that precedes it) can hang. The fix moves exactly that, and nothing else, off the serial queue.

## Reducer contract analysis (the risk gate)

The async integration hands the reducer a **single-entry** `.observe` batch when a read completes — out of order relative to other files, and possibly many polls "late." A full read of `WatcherFileState.swift` (the 1371-line pure reducer) establishes:

1. **The reducer never infers absence from omission.** A file is marked absent only when handed an explicit `.absent` outcome entry (built in `scan()` from the tracked-minus-present set). Omitting an in-flight file from a batch does **not** flap it or any other file out. (`scan()` lines 683–692.)

2. **No traps in the ordering path.** There is no `precondition`/`assert`/`fatalError`/`try!`/`as!`/optional force-unwrap anywhere in the file. Every `!` is logical negation or `!isEmpty`. A late, out-of-order, one-entry batch **cannot crash** the reducer.

3. **All time math is saturating/guarded.** `totalNanos`, `pauseRunning`, `consume`, budget math all use `nowNanos >= since ? … : 0` guards and `&+`/`&*`. A completion timestamped on a different queue whose `nowNanos` is *smaller* than a segment's start cannot underflow.

4. **One-entry batches structurally cannot charge the victim ledgers.** A blocking episode needs a non-empty victim set (`potential[victimStart...]`); a single entry yields an empty set → `BlockingEpisode.init?` returns nil. So late one-entry observations add zero accounting and cannot double-count, go negative, or orphan an owner. Emit/drop paths (`reconcileActiveBlocker`, `redeemSegments`, `consumeSegmentsEverywhere`) clean an owner out of *every* ledger.

5. **Ordered emission is a soft correctness property, not a hard invariant.** The stated intent (from comments) is monotonic *latest-frame-wins* progression with **bounded, abandonable** blocking — the whole write-off subsystem exists precisely to break ordering under duress and keep making progress. There is no downstream replay-sequence / index invariant that a reorder would violate.

**Verdict: feeding the reducer late/out-of-order one-entry batches is SAFE — it cannot corrupt or crash.** What it *changes* is emission order and frame retention, and that is the one thing we must control (next section).

## The behavioral gap the naive design leaves — and the fix

If in-flight files are simply **omitted** from the batch (the first design sketch), the per-batch blocker collapses (`orderedEffects` clears `activeBlocker` when no batch-present file is un-ready), so a **healthy but slower** concurrent read that completes *after* a later-revision file already emitted gets **dropped by the high-water mark** — a good frame silently lost, never stacked. For live stacking, where every sub is integration time, that is a regression.

**Fix (the "do it properly" end state): keep in-flight files in the batch as a present-but-not-ready placeholder.** An in-flight read contributes a synthetic observation that lands the file in a non-ready, non-terminal `FileState` (the reducer already has `.observing` / `.digestPending` for exactly this shape). Consequences:

- The in-flight file stays in `numbered`/`potential` and remains the **blocker**, holding later frames instead of letting them race past and drop.
- A **healthy slow read** completes → its real `.digested` observation is integrated → the file becomes `ready` → it and everything it held emit **in revision order, zero loss**.
- A **genuinely hung read** keeps the placeholder present every poll → the existing blocking **budget accrues** (wall-clock) → after the ~30s write-off the blocker is abandoned and later frames proceed. Bounded hold → progress. Only the truly stuck frame is lost — which is correct.

This is strictly better than both today's behavior (freeze) and the naive omit (loss on healthy slow reads).

## Design

### Ownership split

- **Serial poll queue (`queue`)** keeps doing: folder existence/identity checks, `enumerateDirectory` (readdir — metadata only, does not materialize; residual hang risk stays covered by the watchdog), `open` + `fstat` + `readPlan` per file (safe, non-materializing), building the absent set, running the reducer, and executing effects (`continuation.yield`). All non-blocking.
- **New concurrent reader queue (`readerQueue`, `.concurrent`)** does *only* the blocking work for `.readContent` files: the FITS header pre-read, `FileIdentity.contentDigest`, and the post-read `fstat`. Concurrent (not serial) so one hung read never blocks another file's read.

### scan() per-file decision (revised)

For each tracked present name, on the serial queue:

1. If the name is already in `inFlightReads` → do **not** re-open or re-dispatch. Emit a **placeholder observation** from the identity captured at dispatch (no fs touch) so the file stays present-but-not-ready in this batch. Continue.
2. Otherwise `open` + `fstat` + `readPlan(entry)` (all non-blocking):
   - `.acceptIdentity` / `.observeWithoutContent` → build the observation synchronously (no content read), close the handle, add to the batch. Unchanged from today.
   - `.readContent` → insert name into `inFlightReads`, capture `(identity, kind, isFITS, generation)`, and **dispatch** the blocking read to `readerQueue` handing over the open `FileHandle` (the reader task owns it and closes it in its own `defer`). Add a **placeholder observation** to this batch (present-but-not-ready). Do **not** wait.
3. Build the batch from the synchronous observations + placeholders + absent entries; run the reducer; execute effects — exactly as today.

### Read completion → integration

The reader task, when the blocking read finishes, hops **back onto the serial queue** and calls `integrateCompletedRead(name:observation:generation:)`:

- If `generation != reducer.state.generation.id` (folder was replaced while the read was in flight) → drop, remove from `inFlightReads`, close nothing (already closed). Stale reads never touch the new generation.
- Else remove the name from `inFlightReads` and reduce a **one-entry** `.observe` batch `[observation]` with `generation: current`, then `execute` its effects. (Safe per the contract analysis.)
- Update the watchdog liveness stamp here too, so a burst of completions counts as progress.

### `inFlightReads`

A `Set<String>` confined to the serial queue (only touched inside `scan()` / `integrateCompletedRead` / teardown, all on `queue`). Prevents dispatching a second read for a file whose read is pending, and drives the "emit a placeholder instead of re-observing" branch.

### Placeholder observation

A synthetic `FileObservation` whose outcome routes to a non-ready, non-terminal `FileState`. Preferred: reuse the existing not-ready path (`.observing`/`.unstable` semantics with the dispatch-time identity) so **no new reducer state** is introduced; a dedicated `.pendingRead` outcome is the fallback if reuse muddies the settle logic. TDD (below) decides which — the acceptance test is: an in-flight file holds later frames and, if never completing, is written off after the budget exactly as a stuck-growing file is today.

### Teardown / stop

- `stop()` sets the atomic `stopRequested` (already checked by `contentDigest`'s `shouldAbort`). In-flight reader tasks observe it and abort their read, returning promptly; their `integrateCompletedRead` hop early-returns because `stopRequested` / state is not `.running`.
- Do not block teardown waiting on reader tasks; each task closes its own handle. The generation guard + stop flag make a late hop after teardown a no-op.
- deinit already cancels the watchdog; also drop `readerQueue` references. No handle is leaked because every reader task closes its handle in `defer` on every path (success, invalid, stop-abort, stale-generation).

## Testing plan (TDD)

New/changed tests in `StackFileWatcherTests.swift` (and reducer-level tests in `WatcherFileStateTests.swift` where the placeholder semantics live):

1. **Freeze test, inverted (the core regression pin).** Reuse the `beforeContentReadForTesting` seam to block *one* file's read on a semaphore. Assert that **other** files continue to be detected and emitted while that one read is blocked — i.e. detection does **not** freeze. (Today's `testBlockedContentReadFreezesDetection` asserts the opposite for the pre-fix code; it is replaced by this.)
2. **Healthy out-of-order completion preserves all frames.** Two subs; make the earlier revision's read finish *after* the later one's. Assert **both** emit, in revision order, none dropped.
3. **Hung read is bounded then written off.** Block one read forever; advance the reducer's clock past the budget via additional polls; assert the held later frames eventually emit and the stuck frame is written off (matching today's stuck-growing-file write-off).
4. **Late completion after generation replacement is dropped.** Dispatch a read, replace the folder generation, then complete the read; assert nothing emits for the stale file and no crash.
5. **`inFlightReads` prevents duplicate dispatch.** A file whose read is pending across several polls triggers exactly one `_digestComputations` increment.
6. **Reducer unit tests** for the placeholder: a present-but-not-ready placeholder entry holds a higher-revision victim (blocker set), and a subsequent `.digested` one-entry batch releases both in order; and a placeholder that never resolves is written off after the budget.

Full `swift test` suite must stay green (1007+ tests) before merge.

## Adversarial review (before merge)

Per `adversarial-cold-review`: dispatch ≥2 parallel refutation subagents with **no** spec/plan context, distinct lenses:
- **Concurrency / ordering lens** — hunt for a fd/handle handed across queues being read after close, a generation race between dispatch and integrate, a lost wakeup, an `inFlightReads` entry that is never cleared (permanent placeholder → permanent blocker), reader tasks outliving teardown.
- **Resource-lifetime / robustness lens** — fd leaks on every early-return path, unbounded reader-queue growth under a flood of new files, behavior when the same name's inode swaps while a read is in flight, placeholder identity going stale.

PROVEN-Critical/Important findings → fix + regression test before merge to main.

## Out of scope

- Moving `enumerateDirectory`/`open`/`fstat` off the serial queue (they don't materialize; residual hang stays watchdog-covered).
- Changing the digest algorithm, the poll cadence, or the `.immutableAfterPublish` policy.
- Any change to `FolderFrameSource` / `SessionPipeline` / `AppModel` wiring — the stall relay + notification shipped already and are unaffected.
