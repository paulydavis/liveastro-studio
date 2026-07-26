# LiveAstro Studio — Extreme Adversarial Cold Review (2026-07-26)

**Target:** main @ `c65cf29` (v3.0.4+2, clean tree). 86 commits past v3.0.0 — everything after the v3.0.0 post-tag cold gate was previously unreviewed.
**Method:** 8 parallel cold reviewers, distinct lenses, zero plan/spec context, refutation-framed. All PROVEN findings carry a runnable probe (compiled against the real LiveAstroCore, verbatim-copy sources diff-verified) or an exact line-level trace. Probe sources retained in the session scratchpad (`cold-*/`); binaries deleted; repo untouched. The single trace-only Critical (C3) was independently re-verified against source by the controller.

**Verdict:** 3 Critical + 22 Important, all PROVEN. The v3.0.0-stabilized cores (watcher reducer, OBS epoch/generation machinery, transform solver, FITS writer) survived every attack — the damage is concentrated in post-v3.0.0 code: calibration, GraXpert, import/replay, and the new workflow rows.

---

## CRITICAL

### C1 — Saved master flats are silently corrupted; vignetting correction half-destroyed every session
`FITSReader.swift:152` clamps all pixels to [0,1] on read; `MasterBuilder.normalizedFlat` (MasterBuilder.swift:68-75) normalizes to median 1, so ~half the flat (everything brighter than the median — the whole center) is > 1.0 by construction. Save→load flattens all of it to exactly 1.0, and the production flow **always** reloads from disk at session start (`CalibrationSelection.swift:49`). Probe: center pixels 1.333 → 1.0000 after round-trip; uniform sky through the vignette comes out with the center 33% too bright. External master flats stored in physical ADU (values ≫1) load as all-1.0 → flat calibration is a silent no-op. Tests miss it because the only round-trip test uses values ≤ 1.
**Fix shape:** an unclamped read path (or clamp-opt-out) for calibration masters; regression test round-tripping a non-uniform flat.

### C2 — GraXpert post-processing can never succeed against the installed GraXpert; leaks ~200 MB hidden temp per attempt
`GraXpertProcessor.swift:25-43`. GraXpert 3.1.0rc2 **appends** `.fits` to the `-output` value (empirically verified with the app's exact argv). Step 1's output lands at `._graxpert_bg_<UUID>.fits.fits`; step 2 is fed the nonexistent path and dies; `process()` always throws `stepFailed("denoising")`. Even if step 2 ran, neither `outputURL` nor the extension-*replacing* `altOutput` fallback matches the appended name. The `defer` cleanup removes a path that never existed; the real full-frame temp is left in the session directory — and its `._` prefix makes it invisible to `FileManager.contentsOfDirectory`. The fake-runner test encodes the wrong model (replace, not append).
**Fix shape:** accept both append/replace behaviors (probe for the actual output name), drop the `._` prefix from temp names, and clean up on failure. Also see I11/I12 (ProcessRunner) before shipping this feature.

### C3 — "Watch Siril / External Stacker" workflow row silently runs the wrong pipeline and processes zero frames (controller re-verified)
`ControlView.swift:746-752` sets `.stackerOutput`, then `LiveSourceController.configureAndStartWatchFolder` (:73) unconditionally applies `DetectedProfile(sourceMode: .nativeStack)`; the `sourceMode.didSet` (AppModel.swift:56-64) swaps the prefix `live_stack` → `Light_`; `startSession()` (AppModel.swift:318-320) builds a native `FolderFrameSource` filtering `Light_*`. Siril writes `live_stack_*` → the session accepts **zero frames forever**, no error. With a user-customized prefix it's worse: cumulative Siril stacks get re-stacked as independent subs (invalid integration). The manual picker + Start Session path still works, which is why this has been masked. `.stackerOutput` is unreachable through the workflow row.
**Fix shape:** the watch-folder configure path must honor the row's mode (parameterize `DetectedProfile` by the picked mode); regression test that the stacker row yields a `.stackerOutput` pipeline.

---

## IMPORTANT — all PROVEN

### Watcher (2)
- **I1 — Quiet-period gate measures batch-end timestamps, not read times** — `StackFileWatcher.swift:609` / `WatcherFileState.swift:772-777`. Both content reads of `live_stack.fit` happen at scan start; the stability timestamps are captured after all per-file hashing. A slow tail hash (52 MB ≈ 0.1–2 s vs the 0.5 s gate) inflates measured separation so two reads milliseconds apart pass — re-opening the mid-rewrite-pause torn-hybrid-emission hole the gate exists to close. Repro'd on the real watcher (2 GiB tail: emits with ~0 ms actual separation; control blocks).
- **I2 — Blocking-episode clock restarts on every blocker-name change / victim flicker; aggregate starvation unbounded and silent** — `WatcherFileState.swift:520-559`. Probes: alternating incomplete revisions and a 20 s enumeration flicker each starved a ready revision for 800 simulated seconds with zero write-offs (control writes off at ~32 s). Bites `.mutableStackerOutput` on a flaky SMB share; stream freezes forever, no log. (This is the previously-ledgered "key episodes on normalized revision" fix's bigger sibling: the clock needs an aggregate bound, not just better keying.)

### OBS (4)
- **I3 — Manual-override latch permanently kills scene automation; OBS latency alone triggers it** — `BroadcastController.swift:1327,1343-1345,1358-1372`. The only clear of `manualOverride` is inside `if showingScopeDueToStall`, which can never become true again once the latch is set. A delayed `setScene` round-trip (OBS modal >15 s tick) sets it with no operator action. Automation silently dead for the rest of an hours-long broadcast.
- **I4 — One malformed Hello-shaped frame aborts the app (uncatchable NSException)** — `OBSMessage.swift:93-95`. Op-0 branch feeds non-collection `d` into `JSONSerialization.data(withJSONObject:)` → `NSInvalidArgumentException`, uncatchable by Swift `do/catch`. `{"op":0,"d":null}` from any port-squatter on the configured localhost port kills the app. The event/response branches have the `as? [String:Any]` guard; only Hello is missing it.
- **I5 — `URLSessionOBSSocket` second connect parks forever; watchdog cannot rescue it** — `OBSSocket.swift:108-120`. `OpenDelegate.settled` latches on first open and is never reset; a second `connect` drops the open callback AND the watchdog's close-induced error callback on the same guard → `OBSClient.connect` hangs with a leaked continuation. Latent today (OBSController builds a fresh socket per attempt) but it defeats the exact wedge-protection the watchdog exists for. Companion: **unsynchronized `task`/`session` vars** make close-during-connect a data race (crash or unrescuable park; theoretical).
- **I6 — Same-client reconnect permanently kills the events stream** — `OBSClient.swift:106-108,297,334`. The events `AsyncStream` is created once and `finish()`ed on first teardown; session 2's events are silently dropped and the documented connection-loss signal can never fire again. Latent (app builds a new client per attempt); real for the public API and exercised reconnect tests.

### FITS (3)
- **I7 — Reader traps (SIGTRAP), doesn't throw, on any `Data` slice with non-zero startIndex** — `FITSReader.swift:27,115`. `subdata(in:)` ranges computed from 0 against slice indices. All current call sites happen to pass zero-based buffers; public parser API in an app where crash = broadcast outage.
- **I8 — Unparseable BZERO/BSCALE silently defaults to 0/1 → whole-frame corruption** — `FITSReader.swift:69-70`. FITS-legal `D` exponents (`3.2768D+04`) parse as nil → bzero 0 → 16-bit data destroyed by the [0,1] clamp, no error. A garbled NAXIS throws; a garbled BZERO must too.
- **I9 — DATE-OBS never parses on real capture-software timestamps; every frame timestamp is file mtime** — `FolderFrameSource.swift:481-491`. Both ISO8601 formatters require a timezone designator; FITS DATE-OBS has none. The DATE-OBS branch is dead code in the field; mtime flows into snapshots/CSV. Proven end-to-end.

### Stacking (1)
- **I10 — Odd-height bottom-up frames misregister under rotation (2 px at meridian flip)** — `StackEngine.swift:337` + `SimilarityTransform.swift:29-35`. Superpixel-granularity flip bins the wrong raw rows when height is odd; lifted transform carries `2·sin(θ/2)` px of translation error (probe matched analytically: 0.026 px @ 3°, ~1 px stack error @ 180°). Silent for pure translation. Fix: bin raw rows `{h-2-2j, h-1-2j}` for bottomUp.

### Calibration / external processes (3)
- **I11 — `FoundationProcessRunner` deadlocks permanently when `log == nil` and the child writes >64 KB** — `ProcessRunner.swift:17-30`. Pipe attached unconditionally, drained only when logging; child blocks on full kernel buffer, `waitUntilExit` waits forever, no timeout anywhere. Probe: 200 KB child never returned.
- **I12 — No timeout, no cancellation, no child termination anywhere in the process chain** — `ProcessRunner.swift:30`, `ImportController.swift:150-183`. Hung GraXpert wedges `isProcessing` until app restart (no UI cancel covers it); app quit orphans the child (proven: `/bin/sleep 600` survived parent exit).
- **I13 — Zero-clamp after dark subtraction rectifies the noise floor before stacking** — `Calibrator.swift:58`. Stacked background converges to σ/√(2π) instead of 0 (probe matched to 0.3%). Bites dark-site/narrowband/mismatched-dark regimes. Standard remedy: signed floats or a pedestal through the stack.

### Session / import / replay (4)
- **I14 — Replay quality gate's frozen baseline guts the replay after any persistent median step** — `FrameSelector.swift:74-95`. Baseline = median of last 5 *kept* medians; dropped frames never update it, so a persistent >50% step (haze clearing, reseed, moonrise) culls everything after it. Probe: 6/100 frames kept. Symmetric `abs()` culls improvements like clouds. Nothing logged.
- **I15 — Progress-blind import drain cancels a healthy import on a slow share; empty result reported as "No .fit files found"** — `SessionPipeline.swift:502-522` + `ImportController.swift:97-115`. Progress ticks only on *finalized* frames; a first sub taking >10 s to read over SMB (target hardware!) times out the drain → cancel → "No .fit files found" over a folder of valid subs. Mid-import: any 10 s gap without a commit silently truncates and reports success.
- **I16 — replay.mp4 written non-atomically at its final name, after the manifest commit point** — `ReplayGenerator.swift:82-125`, ordering `SessionPipeline.swift:648-651`. Crash/quit mid-render leaves a truncated replay inside a sealed session, indistinguishable from good. Every other durable artifact is temp+rename; this is the one that isn't.
- **I17 — ImportController retains the full-res stack accumulator (~0.5 GB) forever after an import** — `ImportController.swift:37,83,94-119`. No completion path nils `importPipeline` (contrast AppModel.swift:519).

### App layer (5)
- **I18 — Auto-detect completions never re-check session state; they clobber a session started mid-detect and keep an orphan relay** — `LiveSourceController.swift:71,116,171` (no re-guard after the async hop; footer Start Session stays enabled during detect, `ControlView.swift:478-480`). Detect completion flips `sourceMode` mid-session, overwrites+persists `watchFolder`, starts a relay nothing consumes — and the failure check inverts (`:139-142` sees the *foreign* session running, keeps the orphan). All three detect paths.
- **I19 — Persisted display adjustments never reach a new session's pipeline** — `AppModel.swift:243,304-330` vs `SessionPipeline.swift:91,323,350-355`. After relaunch every session renders neutral (live image, latest.png, snapshots) while the sliders show the saved values — until a slider wiggles.
- **I20 — The 80 ms adjustment throttle drops the state push, not just the render** — `AppModel.swift:251-269`. Guard returns before the only write of adjustments into the pipeline; no trailing retry. Slider-release+Reset within 80 ms → pipeline stale indefinitely while settings persisted the new values.
- **I21 — Seestar/ASIAIR detectors match ANY volume with the right directory shape; newest-mtime prefers backups** — `SeestarDetector.swift:15-27`, `ASIAIRDetector.swift:26-43`. No share-name check at all; a mounted backup drive with a copied `MyWorks` tree outranks the live share whenever its mtime is newer → silently relays and stacks a previous shoot. Probe-proven.
- **I22 — `importSubs` does a synchronous SMB scan + 256 KB FITS header read on the main actor** — `ImportController.swift:54` (the live paths run the same call detached, with the comment saying why). Hung SMB mount beachballs the UI for the full SMB timeout.

---

## MINOR (selected; full detail in the per-lens reports)
- Stale demo-task completion nils the current demo's handle; Try Demo permanently clobbers persisted settings even when start fails (AppModel.swift:384-417).
- `DemoStackGenerator` traps on `--count 0`; `exit(1)` in library code (DemoStackGenerator.swift:11,51).
- Replay captions wrong after reseed (session-total index × per-stack integration, ReplayService.swift:23-26); zero-snapshot import logs a replay path that doesn't exist.
- Manual reseed between `process()` and `currentStack()` silently un-records an accepted frame (SessionPipeline.swift:363-371).
- `SessionManager.endSession` `try?`-swallows summary/CSV write failures; `SnapshotRecorder.updateLatestImage` swallows all errors (stale OBS overlay, no log).
- Summary-markdown escape misses `\r`; slash-bearing OBJECT names nest unprunable relay dirs; relays live in `~/LiveAstro` while sessions live in `~/Documents/LiveAstro`.
- Drain demotes healthy `.live` → `.stopUnconfirmed` on one timed-out status read while the health poll deliberately tolerates the same observation (BroadcastController.swift:1032-1044 vs 1262-1275); Retry then stops a live stream. `settleStaleStart` seizes `.stopping` from a live owner (:770-787).
- `OBSMessage.encode` non-plist leaves crash / catchable failures send `{}` which OBS answers by closing the session.
- Flat `flatFloor` applied in normalized space permits 65535× gain → stuck white pixels (Calibrator.swift:55); flat build silently skips bias on dimension mismatch; GraXpert discovery is one hard-coded path.
- One non-ASCII byte anywhere in a FITS header rejects the file; NAXIS3=1 degenerate mono rejected; `.fts` files stack but yield no metadata; XBAYROFF/YBAYROFF ignored.
- Permanently-invalid classic file skipped silently forever (no log path); `ImportCursor` caches the first enumeration failure and rethrows forever, contradicting its retry contract (FolderFrameSource.swift:416-418).
- WinsorizedSigmaClip population-σ at count 2 + winsorized-σ without consistency correction (tighter early clips); σ=0 permanent pixel freeze needs bit-identical warm-ups (theoretical).
- Sigma-clip/NaN display packing traps on non-FITS NaN sources (unreachable today; cheap hardening in `makeCGImage`).

## THEORETICAL (ledger-grade)
Sparse-file NAXIS allocation DoS (~120 GB alloc passes all guards); mmap SIGBUS on cold-cache external truncation (repro attempted, did not fire); `CGContext` inout-escape UB in ImageLoader; OBSSocket close-vs-connect data race; per-request timeout task runs expiry body after cancel (guard asymmetry vs connect watchdog); orphaned `.stopping` owner's unconditional StopStream is safe only by executor FIFO, not by guard; identity fast-path aliasing on inode recycling + coarse SMB mtime; `lastEmittedDigestByName` unbounded (tiny) growth; hard-link double-count in DirectoryFootprint; ImportController progress-after-cancel ordering; `[weak self]`+`self!` in surface closures; unguarded `wireCallbacks` pipeline identity during end-drain.

---

## What held up (attacked, no refutation)
- **Watcher reducer core**: 800 randomized simulations, both digest policies, ~59k emissions — zero invariant violations (ordering, dedup, no stale emission, high-water monotonicity, liveness). The redesign paid off.
- **OBS controller machinery**: epoch/generation guards, connect coalescing, dirty-drain lost-wakeup invariant, send-chain FIFO, deferred reconcile — every stabilization-arc invariant survived line-by-line attack. 116/116 OBS tests pass.
- **OBSAuth** (byte-for-byte vs independent reimplementation, multibyte passwords), request correlation under out-of-order/duplicate/unknown ids, cancel races.
- **TransformSolver/TriangleMatcher/Warp/Debayer/StackAccumulator/CoverageCrop/GradientLeveler/AutoStretch/BackgroundExtraction**: exact-recovery probes ≤1e-13, 25% outlier tolerance, 1000-frame drift 7e-7, no Bayer-phase aliasing (debayer precedes warp/crop), pivoting correct.
- **FITSWriter** (block padding, ASCII sanitization, bit-exact big-endian round-trips), FITSTypes overflow-safety.
- **FrameRelay** (wildcard matcher, stability gate, torn-copy discard), **BatchImporter** (bounded parallel register/commit, cancellation), **SnapshotRecorder** atomicity (latest.png can never point at a torn file), CSV RFC-4180 escaping, AtomicCounter, Parallel band arithmetic (exhaustive 1–500 × 1–64).

## Suggested fix order
1. **Broadcast-night visible wrongness:** C3 (dead workflow row), C1 (flat corruption), I3 (scene automation death), I15 (false "No .fit files"), I14 (gutted replays), I19/I20 (adjustments never applied).
2. **Data integrity:** I8, I9, I10, I13, I16, I1.
3. **Robustness/DoS:** I4 (one-frame app kill), I11/I12 + C2 (ship-blocker for the GraXpert feature), I18, I21, I22, I5/I6 (latent API traps), I2, I7.
4. Minors batched per module; Theoreticals ledgered.

Per-lens full reports (probes, no-refutation detail): returned inline by each reviewer; probe sources under the session scratchpad `cold-watcher/ cold-obs-state/ cold-obs-proto/ cold-fits/ cold-math/ cold-calib/ cold-session/ cold-app/`.
