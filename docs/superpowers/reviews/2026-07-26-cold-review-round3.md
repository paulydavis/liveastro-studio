# LiveAstro Studio — Fix-Wave Verification Review (Round 3, 2026-07-26)

**Target:** commit `b747fb9..55d9624` ("Fix cold review round 2 defects"), main @ `55d9624`.
**Method:** 4 finding-armed verifiers (all accumulated round-1/2 probes re-run against the real library; GraXpert against the installed app; OBS socket against a live WebSocket server; watcher against 1000-seed randomized sweeps) + 1 cold diff reviewer. Paul's own gates noted: 784/4-skip/0-fail, release build clean.

## Scoreboard vs the round-2 board

| Round-2 item | Verdict |
|---|---|
| R1 GraXpert 60s timeout | **VERIFIED** — 1800s reaches the only production call site; real run succeeds; ≥2× margin per step |
| R2 leveler zero-clamp | **VERIFIED at the leveler** — but the defect class has a third instance (N1 below) |
| R3 cloud gate off (calibrated) | **VERIFIED** — clouds culled again in the near-zero regime (regime caveats below) |
| R4 dark dropout / poisoning | **PARTIAL** — poisoning gone, dropouts culled, tail steps adopted; but no low-side adoption (N2) |
| R5 import adjustments seeding | **VERIFIED** (mid-import slider residual unchanged, by design) |
| R6 stuck-isImporting cancel | **VERIFIED for claimed paths** + new regression (N5) |
| R7 socket identity check | **VERIFIED** — live stale-callback attack 6/6 clean; pre-existing nanosecond park window unchanged |
| R8 detector allowlists | **PARTIAL** — claimed cases pass (T7 accepted, MySeestarBackup rejected, EMMC Images-N accepted); blocklist evadable (N6) |
| R9 SIGTERM-only kill | **VERIFIED for direct children** (TERM-immune child dies at timeout+grace+ε; waiter threads unblock); grandchildren + app-quit orphaning remain (known) |
| R10 drain messaging | **VERIFIED as scoped** — stall logged, shutdownTimeout gets an actionable message; truncation-labeled-complete and ~70s envelope remain |
| R11 watcher episode clock | **INCOMPLETE** — named repro fixed (32s write-off, was ∞); three escape conditions are proven starvation paths + one new regression (N3) |
| R12 GraXpert reporting/staleness | **VERIFIED** (true filename logged; stale-masking closed) + new regression (N4) |
| Minors (blank BZERO, encode guard) | **VERIFIED** (residuals unchanged: `{}` frame drops the session; both graded Minor) |

---

## NEW / SURVIVING FINDINGS — round-3 board

### N1 — IMPORTANT, PROVEN: the noise-floor rectification has a THIRD instance — the RCD debayer, which is the app default
`Debayer.swift:403-405` clamps every interior pixel to [0,1] per frame, before warp/leveling/accumulation. RCD is the default (`AppModel.swift:53`). For OSC dark-calibrated data (exactly the ASI2600MC-Air path) the stack background biases **+0.008..+0.011** — larger than the leveler bias just fixed. Round-2 probes used 3-channel frames (no debayer), which is why this was invisible. The defect has now been fixed at Calibrator (round 2) and GradientLeveler (round 3) while surviving here — **this is a class, not an instance**. Recommended: one sweep of every pre-accumulation clamp site with a single end-to-end σ/√2π regression test on the RCD path (bilinear is clean; Warp/accumulator/sigma-clip verified sign-agnostic; BackgroundExtraction clamps are display-only).

### N2 — IMPORTANT, PROVEN: FrameSelector has no low-side adoption — one −80% step loses the rest of the replay
`FrameSelector.swift:94-96`. The dropout branch culls and never updates the baseline; `pendingHighStep` has no dark twin, although the code's own comment says sustained regime changes (naming reseed explicitly) must be adopted. Probes: reseed shape `[0.5×10, 0.05×90]` → 89/100 frames culled forever; bright-first-snapshot then clear sky at 0.015 → **kept 2/31** (old code kept all and recovered). Reachable via reseed/target switch (stack median craters in one step when the stack resets to one frame). Fix shape: symmetric pending-adoption for sustained low regimes (mirror of the high side), distinct from true transient dropouts.

### N3 — IMPORTANT, PROVEN: watcher episode-clock fix closes the named repro but all three escape conditions are unbounded starvation paths, and preservation adds a frame-loss regression
`WatcherFileState.swift:524-562`. Fixed: alternating stalled blockers now write off at 32.0s (was ∞); padding churn intact; resolved-blocker episodes clear correctly. Proven open (each: 800 simulated seconds, zero write-offs, silent):
- **Role swap** — blocker/victim sets exchange members on alternate scans → both reset conditions fire every flip (two flickering incomplete files suffice).
- **Victims-empty destruction** — the untouched destroy-on-empty path; round-1's enumeration-flicker starvation persists verbatim.
- **Disjoint handoff** — consecutive episodes sharing no victim reset every time.
Randomized sweep: **14/500 mutableStackerOutput seeds starved organically** (>150s, zero progress) — these holes fire under realistic producers, not just adversarial scripts. New regression: a genuinely-writing fresh blocker appearing in the same scan the old blocker resolves **inherits the old clock** and is written off in as little as 4s — the frame is permanently lost and the log misstates the blocking duration. The escape conditions exist to prevent exactly that inheritance, so patching them re-opens the other side. **This mechanism has hit the stop-patching threshold: a per-victim clock (starvation is a property of the victim, not the blocker) is the shape that closes both sides.** Invariant sweep otherwise clean (1000 seeds, 76,758 yields, zero violations of ordering/dedup/stale/high-water/liveness).

### N4 — IMPORTANT, PROVEN: GraXpert pre-run cleanup destroys the prior good output on a failed re-run
`GraXpertProcessor.swift:27-29` deletes all output variants before launching anything. Re-run "Process master" after a past success and the new run fails (tool broken, offline model fetch, disk full) → the only processed master is destroyed; pre-fix code preserved it. Reachable in one click in-app. Public-API variant (unreachable from the app): `outputVariants(outputURL)` can contain the **input** master (`X.fits` → `X.fit`), destroying the input before the run. Fix: delete stale variants only after step 1 succeeds, or render to temp and rename over variants on success.

### N5 — MEDIUM, PROVEN (trace): double-cancel conflates "preparing" with "draining-after-cancel" — premature unlock + state clobber
`ImportController.swift:152-157`. Cancel #1 with a live pipeline nils it while `isImporting` stays true (correct — end() still draining, up to ~75s on a hung share). Cancel #2 in that window hits the nil branch and forces `isImporting = false`: the UI unlocks while pipeline A is still writing master.fit/rendering; starting import B lets A's completion later clobber B's state and publish A's replayURL under B. Pre-fix the second click was a harmless no-op. Fix: a separate prepare-in-flight flag so the nil branch only fires during prepare.

### N6 — MEDIUM, PROVEN: detector blocklist evadable; ASIAIR false-positive surface widened; the actual mechanism (newest-mtime, no recency) still untouched
`seestar-restore` (contains "seestar", not blocklisted) beat the live share; ASIAIR now accepts ANY non-backup-named volume, so a months-old copied `Autorun/Light` tree on "EditingDrive" wins silently when the device is idle/absent. The named round-2 cases do pass (T7 accepted, MySeestarBackup/asiair_backup rejected, EMMC Images-N dedup handled — though macOS's dedup suffix has historically been a **space** ("EMMC Images 1"), which the hyphen-only regex misses). Three rounds in, the durable fix is a **recency gate** (newest .fit mtime within N minutes / growing) — which is also the 2026-07-09 ledgered "stale-folder guard" feature request — rather than more name heuristics.

### Minors / theoretical (ledger)
- Grandchild processes survive SIGKILL (no process-group kill) — probes orphaned 22 shell-wrapped grandchildren; **empirically Minor today**: the installed GraXpert ran as a single process under observation (the cold reviewer's PyInstaller-bootloader claim did not match the observed process tree; re-check during a real timeout). App-quit orphaning also remains (pre-existing).
- Hung `newestFITSMetadata` scan blocks a Swift-concurrency cooperative-pool thread forever per occurrence (fixed-width pool — repeated cancel/retry cycles can starve all detached tasks).
- FrameSelector: unconditional tail adoption admits terminal transient clouds (≤ baselineWindow−1 frames); the 0.01 absolute floor blinds the gate below ~0.005 absolute deviation (dark-site baselines 0.001–0.005: a 3× background jump passes) and randomly culls ~2%/7.6%/32% of clean frames at median jitter σ=0.002/0.003/0.005 (steady-state native jitter is far smaller; exposure is early-session and watch-mode); 5-frame cloud-band knife edge unchanged.
- `{}` invalid-encode frame still silently drops the OBS session (better than the crash it replaced); `timedOut(seconds: 1800.0)` raw enum in the user-facing error; stall log says "finalizing" on a path that can still throw; watcher write-off log attributes aggregate held-time to the final blocker; pid-reuse race on kill() (microseconds, noted only).
- Pre-existing unchanged: OBSSocket nanosecond park window (close between setState and awaitOpen), mid-import sliders can't reach the import pipeline, ~70s single-read envelope, truncation-labeled-complete (now at least logged).

## What held up
1800s timeout plumbing; SIGKILL escalation for direct children (16 consecutive timeouts, flat thread count); socket identity guard under live attack; leveler math (levels correctly, negatives survive, NaN passthrough); cloud gate in the calibrated regime; blank/comment-only FITS cards; import prepare-generation logic for its claimed paths; display-adjustments plumbing; Processor protocol migration (all conformers/call sites); watcher invariant core (1000 seeds clean).

## Trend assessment (three rounds in)
Each wave reliably closes the named repros — but three areas keep sprouting adjacent instances of the same defect class, which is the recorded signal to stop patching instances:
1. **Pre-accumulation value clamps** (Calibrator → GradientLeveler → Debayer-RCD): needs one class sweep + one end-to-end RCD regression test, not a fourth instance fix.
2. **Watcher blocking episodes**: per-victim clock redesign (small, reducer-local) — the per-episode clock cannot satisfy both "no starvation" and "no inheritance" simultaneously.
3. **FrameSelector gate**: needs symmetric adoption semantics designed once (high/low regimes, transients, tail) rather than per-round constants.
Detector detection wants the ledgered recency gate instead of name heuristics. The remaining items (N4, N5, minors) are ordinary spot fixes.
