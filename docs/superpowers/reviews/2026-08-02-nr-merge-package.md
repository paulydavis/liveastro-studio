# Native Noise Reduction — Merge Package (2026-08-02)

**Branch:** `feature/native-noise-reduction` @ `90c7dc5` — pushed. **Status: CLEAR FOR MERGE — decision is the maintainer's.**
**Spec:** `docs/superpowers/specs/2026-08-02-native-noise-reduction-design.md` (incl. the owner-approved amended gate).

## What this branch does
The live-view noise pillar: a native, classic, deterministic two-stage denoiser (`Denoiser.swift` — luma-edge-guided coarse chroma smoothing that kills the green/magenta mottle, plus sigma-adaptive edge-preserving luma smoothing with star/filament protection), applied non-destructively in the display path (one **Denoise** slider; broadcast, snapshots, `latest.png`, and replay inherit; `master.fit` never touched; strength 0 = zero cost), and the same engine as **Native NR** in the master post-process picker (None | GraXpert | Native NR) — a denoise option with no external install. Zero new dependencies; GraXpert byte-unchanged.

## Validation chain
1. **Prototype-first gate on your real data** (M8 + Veil): first run failed validly → the blur-everything bound analysis proved the metric (not the algorithm) was the constraint on M8's background-free field → you approved the amended flattest-tile/bounded-target gate → **passed with margin** (M8 bg 32.6% vs 30.3 target, chroma 49.2 vs 40.4; Veil 56.0/51.6 vs 40/49.1; FWHM 0.35/0.39% ≤2; filament 95.5% ≥95). Constants graduated verbatim into Swift.
2. **Cross-language port exactness:** golden pin at **5.96e-08** vs the 2e-3 gate; Swift refactor pin **bit-identical**; the cold reviewer's independent 11-case differential (odd dimensions, extreme aspects, mono, both domains, five strengths) maxed at **1.2e-7**.
3. **All seven plan tasks red-first/pinned**, with every deviation recorded (filament fixture re-derivation cross-checked to 6e-8 against the prototype; the T7 full-suite gate caught and fixed a stale T6 enum pin — the gate doing its job).
4. **Gates:** perf pin **0.29–0.50s at 26MP** vs the 1.0s budget (re-measured independently at 0.35s); full suite **860/6-skip/0-fail** (twice); release build clean; watcher suites zero-diff on the branch.
5. **External round:** conformance GATE CONFIRMED first-hand (incl. the py-golden's never-regenerated single-commit history and the amended-gate arithmetic recomputed from raw numbers); cold adversarial review: **no Critical/Important** — the first fully clean cold pass on a new pillar in this project.

## Your eyeball (the one gate only you can run)
`~/Desktop/denoise-ab/` — before/after at strengths 0.25/0.5/0.75/1.0 for M8 and the Veil. The metrics say the filaments survive; confirm with your own eyes before or after merging. Default ships **off** — nothing changes until the slider moves.

## Minors carried to the post-merge ledger (none block)
- Import throughput: denoise adds ~0.3s serialized per committed frame at 26MP (~+1 min per 200-sub import) — traced safe against the drain's windows; an off-critical-path render is a future optimization if it ever matters.
- Pre-existing unordered re-render race (`applyDisplayAdjustments` detached tasks, no generation counter) — denoise widens the stale-overwrite window to ~0.3–1.5s in idle sessions; small fix candidate (generation counter), predates this branch.
- Float32-vs-float64 knife-edge at the stage-2 residual threshold — measure-zero, matters only to future golden regeneration; noted in the regen procedure.
- Memory: ~4–5 GB transient peaks possible during imports with denoise enabled on 26MP (fine on 16GB+; swap pressure on 8GB machines — a docs note candidate).
- T5's fixture deviation recorded in source comment rather than commit body (docs nit).

## Merge mechanics (when approved)
```
git checkout main && git pull
git merge --no-ff feature/native-noise-reduction
swift test          # expect ~860/6-skip/0-fail
git push
```
Post-merge: repackage dist app so the slider ships; the A/B eyeball at real scale on your next clear night is the true acceptance.
