# LiveAstro Studio — Fix-Wave Verification Review (Round 2, 2026-07-26)

**Target:** commits `84309b0..d054fde` ("burn down first cold-review defects" + "Fix cold-review reliability findings"), main @ `d054fde`.
**Method:** 6 verification reviewers (armed with the original round-1 findings and required to re-run the proven repros) + 1 fully-cold regression reviewer on the diff + full test suite. All probes compiled against the real library; the GraXpert probes ran against the actually-installed GraXpert 3.1.0rc2, including one run on the real `2026-07-12-ngc6888/master.fit`.
**Gate:** `swift test` = 773 passed / 4 skipped / **0 failures** (792s). The suite being green while the wave carries a proven Critical regression is itself a finding: the GraXpert tests model the tool with fake runners and never see real timing.

## Scoreboard vs round 1 (25 findings)

| Verdict | Findings |
|---|---|
| **VERIFIED closed** (14) | C1 flat clamp, C3 stacker row, I3 latch, I4 hello crash, I6 events stream, I7 slice trap, I8 BZERO, I9 DATE-OBS, I10 registration, I11 pipe drain, I14 frozen baseline*, I16 replay atomic, I17 accumulator, I18 detect clobber, I20 throttle, watcher I1 quiet gate |
| **INCOMPLETE** (5) | I13 (survives in GradientLeveler, default-on), I15 (silent truncation + wrong error persist), I19 (import pipeline missed), I21 (backup volumes still win), C2 (wrong filename reported; stale-output masking) |
| **NOT ADDRESSED** (1, expected) | Watcher I2 episode-clock aggregate starvation (re-proven: 800s starvation, zero write-offs) |
| **NEW REGRESSIONS** | 1 Critical + 4 Important/Medium (below) |

\* I14's original defect is closed but the replacement logic has a new failure mode (R4).

Watcher I1 deserves its own note: cleanest fix of the wave. Original 2 GiB-tail attack blocked (0.2 ms separation correctly refuses emission), a derivation shows no hash-time asymmetry can create an unsafe regime, and an 800-seed randomized sweep produced 61,506 emissions with zero invariant violations.

---

## NEW FINDINGS — the fix wave's own defects

### R1 — CRITICAL, PROVEN twice: the 60s ProcessRunner default timeout makes GraXpert fail on every real master
`ProcessRunner.swift:18` defaults `timeoutSeconds: 60`; the only production construction (`GraXpertProcessor.swift:9` via `ImportController.swift:189`) never overrides it. Measured: denoise on the real 93 MB NGC 6888 master = **222s**; a 16 MP synthetic reached 10% at 62s (full run ≈ 9–10 min; 26 MP ≈ 15 min). The runner SIGTERMs GraXpert at 60s and throws. Pre-wave the feature hung on pathological runs; post-wave it **deterministically fails every healthy run on real data** — strictly worse for the user. First-run AI-model download widens the gap further. Fix: workload-appropriate/configurable timeout at the call site (tens of minutes), or cancel-driven termination instead of a fixed leash.

### R2 — IMPORTANT, PROVEN: I13 persists in the default configuration — GradientLeveler still zero-clamps per frame
`GradientLeveler.swift:94` (`min(max(result, 0), 1)`) runs on every accepted 3-channel frame because background normalization defaults on (`AppModel.swift:51`). End-to-end through the real StackEngine (40 frames, background N(0, 0.02)): normalization OFF → stack bg ≈ 0 ✓; normalization ON → **0.00751 ≈ σ/√2π** — the exact round-1 defect value. The Calibrator fix only helps with normalization off or mono data. Fix: drop the 0-floor in GradientLeveler (keep NaN hardening and the 1-cap), mirroring the Calibrator change.

### R3 — IMPORTANT, PROVEN mechanism: negatives from the Calibrator disable the replay cloud gate for every dark-calibrated session
With `min(v, 1)` at `Calibrator.swift:58`, dark-subtracted backgrounds have median ≈ 0 ± noise (sign random). `FrameSelector.qualityGate`'s `baseline > 1e-12` guard (`FrameSelector.swift:90`) then keeps **everything** — probe: cloud frames sail through. Pre-wave the 0-clamp gave a small positive median and an active gate. The consumer audit for the new value range missed the snapshot-stats path (display and stacking consumers were all verified safe). Fix: gate on |median| or an absolute-deviation floor when baseline ≈ 0.

### R4 — IMPORTANT, PROVEN: the signed FrameSelector gate keeps dark dropout frames, then baseline-poisons itself and culls the recovery
`FrameSelector.swift:91`. `[0.1×3, 0.001×5, 0.1×4]` (dome/shutter/tracking dropout then recovery) → keeps the 100×-dark frames (signed gate never rejects "improvements"), baseline median becomes 0.001, and the recovered good frames read as a +9900% "high step" and die in `pendingHighStep` — the gate inverts: keeps the dip, discards the recovery. Also: a high run reaching the last frame is silently discarded at loop exit (visual jump), and there's a knife-edge at exactly `baselineWindow`: 4-frame cloud bands are 100% culled, 5-frame bands 100% adopted. Fix shape: symmetric-but-recovering gate (guard the low side, adopt sustained regimes in both directions, adopt runs that reach the tail).

### R5 — IMPORTANT/MEDIUM, PROVEN: import sessions still render with neutral display adjustments (I19's third site)
`ImportController.beginImport` constructs its SessionPipeline (`ImportController.swift:93-96`) with no `displayAdjustments` seeding, and mid-import sliders can't reach it (`applyDisplayAdjustments` guards on `AppModel.pipeline`, which is nil during imports). Every "Stack Previous Shoot" snapshot/replay ignores the user's persisted stretch/saturation/DBE. Only three construction sites exist; two were fixed, this one missed.

### R6 — IMPORTANT/MEDIUM, PROVEN: stuck `isImporting` soft-lock during the new async import prepare phase
`ImportController.swift:54` sets `isImporting = true` before the detached metadata scan; `importPipeline` stays nil until `beginImport`. In that window Cancel is a **no-op** (`cancelImport()` pokes a nil pipeline, nothing resets the flag), a hung SMB scan (no timeout) locks out every start action app-wide indefinitely, and a Cancel that does land is ignored — `beginImport` starts the import anyway when the scan returns. Fix: prepare-phase cancelled flag checked by `beginImport`; `cancelImport()` resets `isImporting` when pipeline is nil.

### R7 — MEDIUM, PROVEN: OBSSocket's shared delegate has no session-identity check — a stale callback spuriously fails a fresh connect
`OBSSocket.swift:136-156`. The settled-reset fixed the park-forever, but `invalidateAndCancel`'s async completion from connect #1's session can land after `awaitOpen` reset `settled` for connect #2 and fail it in ~1 ms (probe with a live WS server: reproduced; control connects succeed). Symmetric hazard for a late didOpen. Fix (small): store the expected task in `awaitOpen`, compare in both callbacks.

### R8 — MEDIUM, PROVEN + regression: detector allowlists don't close the round-1 hole and break a legit rig
`SeestarDetector.swift:41-44`, `ASIAIRDetector.swift:52-54`. `MySeestarBackup` contains "seestar" — the literal round-1 attack volume still wins on mtime (probe re-proven). Meanwhile an ASIAIR writing to attached USB storage exports the share under the drive's own label ("T7", "USB_SSD") — now **rejected**, breaking one-tap detection for a configuration that worked pre-wave (probe-proven rejection). Also fragile: macOS duplicate mounts ("EMMC Images-1") fail the `==` check. Needs a device-share discriminator (volume network/removable attributes, exact-share preference ordering) rather than name substrings.

### R9 — MEDIUM, PROVEN: ProcessRunner timeout path — SIGTERM-only, orphaned children, one leaked blocked thread per timeout
A TERM-ignoring child (GraXpert wedged in native inference) survives forever — nothing SIGKILLs it or its process group; app-quit orphaning is unchanged from round 1 (re-proven); each timeout parks a waiter thread in `waitUntilExit` forever (probe: +7 threads after 3 timeouts; dispatch pool caps ~64). The `waitStarted` flag is vestigial. Also Low: closing the read handle in `defer` can race an in-flight `availableData` (uncatchable NSFileHandleOperationException, exotic).

### R10 — MEDIUM, PROVEN: import-drain residuals (I15)
(a) A single healthy read >~70s still cancels (120 MB ASIAIR frame below ~1.7 MB/s — degraded Wi-Fi SMB regime); (b) activity-free gaps still silently truncate — probe: 4-frame import finalized as "Import complete" with 2 frames, **zero log lines** on the internal cancel; (c) the `shutdownTimeout` error still maps to **"No .fit files found in the chosen folder"** for a folder full of valid subs (`ImportController.swift:132-150`) — the round-1 lie survives at a higher threshold. Fixes: log the internal cancel, distinguish `shutdownTimeout` in the error branch, scale the active-read allowance to bytes/throughput.

### R11 — (carried) IMPORTANT: watcher episode-clock aggregate starvation (round-1 I2) untouched
Re-proven this round: alternating stalled blockers starved a ready revision for 800 simulated seconds with zero write-offs (budget ~34s). `WatcherFileState.swift:532-561`. The padding-churn carve-out (76a0d91) covers only equal-numeric name churn.

### R12 — MEDIUM, PROVEN: GraXpert residuals (C2)
(a) The app logs/UI point at `master_processed.fit` while GraXpert 3.1.0rc2 actually writes `master_processed.fit.fits` — `process()` computes the real path in its final check and discards it (`GraXpertProcessor.swift:45`); user is told to look for a file that doesn't exist (`ImportController.swift:188,197`, `ControlView.swift:371,699`). (b) A stale output variant from a prior run masks a failed re-run as success (no pre-run cleanup of variants).

### Minor / theoretical (ledger)
- FITS-legal *undefined-value* `BZERO =` card (blank value field) now rejects the whole file; old default-0 was standard-correct (`FITSReader.swift:196-204`). Treat empty value as absent.
- Scene automation: a real operator override re-latches + logs every stall/resume cycle forever (`lastAutomationScene` never refreshed, `BroadcastController.swift:1353-1356`); the first genuine stall after a latency false-latch shows no scope scene. Contract-conformant but the false positive is undistinguished from a real override.
- `OBSMessage.encode` still NSException-crashable by caller-supplied Date/NaN in requestData (no current caller does; add `isValidJSONObject` guard).
- Sentinel event `__LiveAstroConnectionLost` spoofable by the peer → false "connection lost" teardown (peer controls the socket anyway; Low).
- Crash mid-render orphans hidden `.replay-*.mp4` temps invisible to DirectoryFootprint/pruner; no sweep exists.
- Date-only (`2026-01-02`) and `DD/MM/YY` DATE-OBS still fall back to mtime (legacy-only).
- External ADU-scale float master (≫1) now subtracts at full magnitude instead of clamping — garbage-in amplified, unbounded (Theoretical).
- `startWatchFolderLive`'s `sourceMode` default parameter is a latent C3-shaped footgun for future callers; `observedAtNanos: UInt64?` + silent fallback is convention-dependent (make non-optional or assert).
- `neutralizeBackgroundAdditive` asymmetric per-channel zero-clamp writes a tiny channel pedestal into master.fit when neutralize is on (∝ σ_stack/√2π; far smaller than I13).
- SourceMetadata numeric fields (EXPTIME etc.) keep the silent-default class (advisory-only).
- Session started **and ended** during a hung detect still applies a minutes-old click (no detect timeout).

## What held up under attack this round
halfResLuminance index math (exhaustively re-derived, all parities in bounds, correct fix), drain arithmetic core (no starvation/double-count/early break), parseDateObs (11 forms incl. 6/7-digit fractions — Foundation handles them correctly), Data rebase (no hot-path copy; all callers zero-based), OBS events lifecycle/buffering/deinit, take-for-close locking, FrameSelector pooling mechanics (sorted/unique/in-range over 2000 random sequences), ReplayGenerator temp+rename semantics (same-volume rename, stale replay preserved on failure), ProcessRunner line integrity (300 runs, zero loss/dup).

## Suggested wave-3 order
1. **R1** (one-line-ish: pass a real timeout / make it cancel-driven) — unblocks the GraXpert feature entirely; pair with R9 (SIGKILL escalation + process-group) and R12a (report the real output path).
2. **R2 + R3 + R4** together — they're one coherent "value-range and gate semantics" pass across GradientLeveler/Calibrator/FrameSelector, with the round-1 σ/√2π and cloud-gate probes as regression tests.
3. **R5, R6** (small app-layer patches: seed the import pipeline; prepare-phase cancel flag).
4. **R7** (task-identity check in OpenDelegate), **R10** (log + error mapping), **R8** (rethink discriminator), **R11** (episode-clock aggregate bound — the standing watcher-wave item).
5. Minors batched per module.
