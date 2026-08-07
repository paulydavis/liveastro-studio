# License / Derivation Audit — LiveAstroCore vs Siril (GPLv3)

**Date:** 2026-08-06 · **Trigger:** community warning (Naztronomy) that an AI-built app was
shut down for copying Siril's stacking/drizzle code despite instructions not to.
**Method:** five independent adversarial reviewers, each instructed to *refute independence*:
structural comparison of every LiveAstroCore module against Siril `master` source
(shallow clone), hunting implementation fingerprints — matching magic constants beyond
published algorithm parameters, identical decomposition/loop structure, naming echoes,
comment echoes, shared bugs. Same *published algorithm* explicitly did not count as evidence.

**DO NOT COMMIT/PUBLISH this directory until the RCD remediation (below) is decided and done.**

## Verdicts

| Module | Verdict | Key evidence |
|---|---|---|
| WinsorizedSigmaClip / StackAccumulator / StackEngine | **INDEPENDENT** | Online Welford clamp vs Siril's batch median iteration (distinctive 1.134/0.0005 constants absent from our tree); different accumulation strategy; fingerprint grep empty |
| Calibrator / MasterBuilder | **INDEPENDENT** | median-1 flat + 1/65535 floor from own prototype vs Siril central-mean + golden-section dark optimization |
| StarDetector | **INDEPENDENT** | Different algorithm entirely (threshold+CC+MAD grid vs Gaussian-smooth+peak+GSL PSF fit) |
| TriangleMatcher | ALGORITHM-CONVERGENT | Published Groth/Valdes voting; only overlap = published `match`-program defaults (20/2); astroalign (MIT) lineage |
| TransformSolver / Warp | **INDEPENDENT** | Siril has no own RANSAC/Umeyama/warp to copy — it delegates to OpenCV |
| AutoStretch (MTF) | ALGORITHM-CONVERGENT | Published PixInsight STF math/defaults (−2.8/0.25) only; implementation diverges from Siril mtf.c |
| BackgroundExtraction (DBE, incl. flattenMultiscale) | ALGORITHM-CONVERGENT | Recipe skeleton from AutoGradientRemoval.py's *public description* (credited in spec, which records the recipe was NOT available); every discretionary choice differs (D=4 downsample-first vs full-res; one-sided 3σ vs 2σ/4σ; 5 fixed iters vs 20+convergence; dilate-2 vs threshold/amount; replace-with-blur vs normalized-lowpass inpaint); Swift matches own committed prototype 1:1 |
| Denoiser | **INDEPENDENT** | No counterpart in Siril (noise.c is measurement only); full prototype/gate provenance in-repo |
| FITSReader / FITSWriter | **INDEPENDENT** | Siril has no FITS parser (delegates to cfitsio); Swift implements the NASA standard |
| StackFileWatcher / WatcherFileState | **INDEPENDENT** | kqueue+digest vs GFileMonitor+size-poll; 1371-line reducer has no Siril analog |
| FrameRelay | ALGORITHM-CONVERGENT | Size-stability polling folklore only; self-documented lineage from own seestar_relay.sh |
| Drizzle | **ABSENT** | No drizzle implementation anywhere in the tree |
| **Debayer.swift — RCD section** | **DERIVED (declared)** | Self-documented "faithful Swift port... per-pixel translation" of librtprocess `src/demosaic/rcd.cc` (**GPL-3.0**, verified), via `scratchpad/rcd_debayer.py` (also tracked in repo) |

Tree-wide sweeps: no GPL header text, no Siril-distinctive identifiers, no French comments,
no Siril magic constants. All "Siril" strings are output-file interop or docs.

## The two findings

1. **RCD debayer is a GPL-3.0 derivative** (openly attributed in code — the opposite of
   concealed copying, but attribution does not cure a license conflict).
2. **The repo has no LICENSE file** — public GitHub, all-rights-reserved default. This is
   a standalone problem (users have no rights) and incompatible with hosting (1).

## Remediation options (owner's decision)

- **Option A — license the project GPL-3.0-or-later.** Cures (1) completely and (2);
  keeps RCD; requires COPYING file + source-file license headers + NOTICE crediting
  librtprocess/Luis Sanz Rodríguez. Cost: closed/commercial forks are off the table.
- **Option B — excise RCD, choose a permissive license.** Remove the RCD section of
  Debayer.swift + `scratchpad/rcd_debayer.py`, rewrite public git history (past commits
  on a public repo are also distribution), fall back to bilinear (or implement a
  paper-based demosaicer cleanly), then MIT/Apache-2.0 + LICENSE file.

Detailed per-module evidence: `audit-stacking.md`, `audit-registration.md`,
`audit-imaging.md`, `audit-fits-livestack.md` (this directory).
