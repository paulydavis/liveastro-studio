# Copyright/License Audit — LiveAstro Studio Stacking vs. Siril Registration (GPLv3)

**Date:** 2026-08-06
**Auditor stance:** adversarial — assume derivation, hunt for implementation fingerprints, refute independence.

**Target (Swift):** `/Users/pauldavis/liveastro-studio/Sources/LiveAstroCore/Stacking/` — StarDetector.swift, TriangleMatcher.swift, TransformSolver.swift, Warp.swift (plus SimilarityTransform.swift read for context).

**Reference (C/C++, GPLv3):** `.../scratchpad/siril-src/src/registration/` (incl. `matching/atpmatch.c` — Siril's verbatim import of Michael Richmond's `match` program, itself Groth 1986 / Valdes et al. 1995 lineage), `src/algos/star_finder.c`, `src/algos/PSF.c`, `src/opencv/opencv.cpp`, and `src/registration/mpp/*`.

---

## Executive summary

No evidence of code-level derivation from Siril was found in any of the four files. The strongest overlap found anywhere is **two shared integer defaults** in TriangleMatcher (brightest-20 stars, min-votes 2) that coincide with `atpmatch.h`'s `AT_MATCH_NBRIGHT`/`AT_MATCH_MINVOTES` — but these are the published defaults of the Groth/Valdes/Richmond `match` lineage, and every surrounding implementation decision (invariant definition, vertex ordering, tolerance semantics and magnitude, data structures, search strategy, pair selection, transform fitting) diverges from Siril, several in mutually incompatible ways. TransformSolver and Warp implement in Swift what Siril does not implement at all (it delegates both to OpenCV), so there is no Siril text to have copied. TriangleMatcher and TransformSolver show visible **astroalign** (MIT, Python) influence — invariant pair choice and 2.0-px RANSAC tolerance — which is legally unproblematic and noted below.

| File | Verdict |
|---|---|
| StarDetector.swift | **INDEPENDENT** |
| TriangleMatcher.swift | **ALGORITHM-CONVERGENT** (two shared lineage defaults noted; astroalign-style invariants) |
| TransformSolver.swift | **INDEPENDENT** (likely astroalign-influenced defaults — MIT, fine) |
| Warp.swift | **INDEPENDENT** |

---

## 1. StarDetector.swift — verdict: INDEPENDENT

The two detectors implement **different algorithms**, not merely different expressions of the same one.

**Swift design** (StarDetector.swift:11-100): SExtractor/SEP-style pipeline — 32-px cell grid of per-cell median + 1.4826·MAD sigma (lines 17-44), bilinear interpolation of the background grid in cell-center space (lines 46-55), global boolean threshold mask at bg + 5σ (lines 57-64), 4-connected flood-fill connected components with minArea 3 / maxArea 400 (lines 70-84), flux-weighted centroid (lines 85-93), sort by flux, keep top 60.

**Siril design** (star_finder.c): Gaussian smoothing kernel (star_finder.c:47 `KERNEL_SIZE 2.`), local-maximum candidate scan with saturation-plateau logic (star_finder.c:49-50 `SAT_THRESHOLD 0.7`, `SAT_DETECTION_RANGE 0.1`), per-candidate box extraction (star_finder.c:51 `MAX_BOX_RADIUS 200`), then **full nonlinear Gaussian/Moffat PSF fitting** via `psf_global_minimisation` (star_finder.c:653, GSL minimizer in PSF.c), with reject-star heuristics (star_finder.c:89) and duplicate suppression (star_finder.c:148). No connected components, no grid background, no flux centroid.

Points hunted and dismissed:
- **5σ threshold.** Swift default `sigmaThreshold: Double = 5.0` (StarDetector.swift:13); Siril hardcodes a ×5 in `compute_threshold(image, sf->sigma * 5.0, ...)` (star_finder.c:200), i.e. threshold = median + 5·k·bgnoise (star_finder.c:79). Both land on "median + 5·noise", but 5σ is the canonical DAOFIND/SExtractor detection default in the astronomy literature; the surrounding machinery (per-cell MAD grid vs. one global `statistics()` call) is entirely different. Not probative.
- **1.4826 MAD→σ constant** (StarDetector.swift:41-42). Textbook constant (1/Φ⁻¹(0.75), stated as such in the Swift comment). In the whole Siril reference tree it appears only in the unrelated robust-fit code `registration/mpp/mpp_shift.cpp:281-292` (Tukey bisquare reweighting of AP shift fields — different purpose, different structure). Siril's star finder does not use a MAD grid at all.
- No shared variable names, comment text, iteration-order quirks, or bugs found. Siril's `starc`/`psf_star`/`s_star` layouts have no analog to Swift's 3-field `Star {x, y, flux}` (StarDetector.swift:3-7).

## 2. TriangleMatcher.swift — verdict: ALGORITHM-CONVERGENT

Same algorithm family as Siril's `matching/atpmatch.c` (triangle similarity invariants + per-vertex vote accumulation — Groth 1986 / Valdes 1995, both published), so structural similarity is expected. The adversarial findings, strongest first:

### Findings that lean toward derivation (the whole case)

1. **`maxTriangleStars: Int = 20`** (TriangleMatcher.swift:56) **== `#define AT_MATCH_NBRIGHT 20`** (atpmatch.h:71). Both mean "form triangles from only the N brightest stars."
2. **`minVotes: Int = 2`** (TriangleMatcher.swift:58) **== `#define AT_MATCH_MINVOTES 2`** (atpmatch.h:146). Both mean "discard candidate pairs with fewer than 2 triangle votes." Swift applies it at TriangleMatcher.swift:78 (`.filter { $0.value >= minVotes }`); Siril at atpmatch.c:559 (`if (winner_votes[i] < AT_MATCH_MINVOTES)`).
3. **Per-vertex vote increment for each matching triangle pair**: TriangleMatcher.swift:70-74 vs. atpmatch.c:2232-2234 (`vote_matrix[...a_index][...a_index]++;` ×3). This is, however, the core published Groth/Valdes step, described verbatim in the Valdes paper and in atpmatch.c's own header comment (atpmatch.c:323 "based on the algorithm described in Valdes et al.").

**Assessment of 1–2:** these are the documented defaults of Richmond's `match` program, of which Siril's atpmatch.c is a verbatim GPL import (atpmatch.c:56-133 changelog is Richmond's). A developer reading the Groth/Valdes papers or the public `match` documentation would arrive at 20/2 without ever opening Siril. Two integer defaults, one of which (2) is the weakest nontrivial vote threshold, are consistent with reading the literature/docs (or even Siril's *header comments*, which are ideas, not expression). They are the only overlap; they carry no copied expression.

### Findings that refute copying of expression

- **Different invariant space.** Swift: `(L2/L1, L3/L2)` with sides sorted **ascending** (TriangleMatcher.swift:24, 41-43). Siril: `(b/a, c/a)` with `a` the **longest** side (atpmatch.c:1353-1441, esp. 1436-1437 `tri->ba = b / a; tri->ca = c / a`). These are numerically different signatures; matched thresholds cannot even be transplanted between them. Swift's pair is exactly astroalign's `_invariantfeatures` (`sides[2]/sides[1], sides[1]/sides[0]`) — MIT-licensed influence, order swapped.
- **Opposite vertex-ordering convention.** Swift orders vertices opposite-shortest-side first (TriangleMatcher.swift:22-23, 39-47). Siril sets `a_index` = vertex opposite the **longest** side (atpmatch.c:1321-1322, 1375-1424, a 50-line explicit if/else cascade vs. Swift's one-line sort of `(dist, index)` tuples).
- **Different, incompatible tolerance semantics.** Swift: **relative** per-component test, `|Δinv|/inv < 0.02` each (TriangleMatcher.swift:57, 67-69). Siril: **absolute Euclidean** radius in (ba,ca) space, `(Δba)² + (Δca)² < 0.002²` (atpmatch.h:41 `AT_TRIANGLE_RADIUS 0.002`; atpmatch.c:2136, 2195-2196). Different metric, different constant (0.02 vs 0.002), different dimensionality. If the Swift author had copied Siril, the natural artifact would be 0.002-Euclidean, not 0.02-relative.
- **Different candidate search.** Siril sorts triangles by `ba` and band-limits the scan (`find_ba_triangle`, atpmatch.c:2118-2193 — a real performance trick worth copying, and absent from Swift). Swift is a plain O(nA·nB) double loop (TriangleMatcher.swift:65-66).
- **Different vote storage.** Siril: dense `int **vote_matrix[nbright][nbright]` (atpmatch.c:2110-2116). Swift: sparse `[Int: Int]` dictionary keyed `src*4096 + dst` (TriangleMatcher.swift:19-20, 64, 73) — an idiosyncratic encoding with no Siril counterpart.
- **Different pair selection.** Swift enforces greedy **one-to-one** assignment with a deterministic key tie-break (TriangleMatcher.swift:77-87). Siril's `top_vote_getters` (atpmatch.c:2290+) insertion-sorts top cells **without** one-to-one enforcement, then relies on iterative sigma-clipped `iter_trans` to purge duplicates.
- **Different degeneracy filters.** Swift: `l1 > 4` px minimum shortest side and needle rejection `inv < 20` (TriangleMatcher.swift:42-46). Siril: `prune_triangle_array` drops triangles with `ba > AT_MATCH_RATIO` (0.9) (atpmatch.h:74-78, atpmatch.c:480-481). No constant or criterion in common.
- No comment echoes, no shared identifiers (`ba/ca/a_index/nbright/vote_matrix` vs. `invariant/vertices/voteKeyStride/ranked`), no shared bugs found.

**Conclusion:** the algorithm is the published one; the expression is not Siril's. The two shared defaults are lineage defaults, not copied code. ALGORITHM-CONVERGENT, not SUSPICIOUS — but if the bar is "any overlap whatsoever," the 20/2 pair at TriangleMatcher.swift:56,58 vs atpmatch.h:71,146 is the complete list.

## 3. TransformSolver.swift — verdict: INDEPENDENT

**There is no corresponding Siril code to have copied.** Siril performs robust transform estimation by calling OpenCV: `estimateAffinePartial2D(img, ref, mask, CV_RANSAC, defaultRANSACReprojThreshold)` (opencv.cpp:448; `#define defaultRANSACReprojThreshold 3`, opencv.cpp:58), `findHomography` (opencv.cpp:454), inside `cvCalculH` (opencv.cpp:398). Siril's own `iter_trans`/`calc_trans_linear` in atpmatch.c is an **iterative sigma-clipped least-squares** with Gaussian elimination (atpmatch.c:298-313, AT_MATCH_MAXITER 5, AT_MATCH_HALTSIGMA 1e-1, atpmatch.h:124,139) — not RANSAC, not Umeyama, not similarity-constrained.

Swift specifics with no Siril analog:
- Closed-form 2-D Umeyama similarity fit (TransformSolver.swift:6-32) — textbook (Umeyama 1991); Siril has no implementation of it anywhere in the reference set.
- Hand-rolled RANSAC: 2-point minimal samples (TransformSolver.swift:55-59), 500 iterations, deterministic seed `0x5EED`, Knuth MMIX LCG constants 6364136223846793005 / 1442695040888963407 (TransformSolver.swift:49-53). Grepped the entire Siril reference tree: **no LCG constants, no 500-iteration loop, no 0x5EED** anywhere.
- Divergent tuning: inlier tolerance 2.0 px (TransformSolver.swift:45) vs. Siril/OpenCV 3 (opencv.cpp:58); scale sanity bounds **[0.5, 2.0]** (TransformSolver.swift:75) vs. Siril's **[0.9, 1.1]** (global.c:283-284 `scale_min = 0.9; scale_max = 1.1;`); minMatches 8 vs. Siril's AT_MATCH_REQUIRE_LINEAR 3 / AT_MATCH_MINPAIRS 3 (atpmatch.h:85,181).

**astroalign note:** pixel tolerance 2 matches astroalign's `PIXEL_TOL = 2`, and the similarity-only model + RANSAC structure mirrors astroalign's `_ransac`/`estimate_transform('similarity')` design (astroalign samples one triangle-match per iteration; Swift samples 2 point pairs — related but not identical). astroalign is MIT; even direct derivation would be license-compatible with attribution. No verbatim astroalign expression is present (the Swift is not a transliteration of numpy code).

## 4. Warp.swift — verdict: INDEPENDENT

Again **no corresponding Siril code exists**: Siril warps via OpenCV — `warpPerspective(in, out, H, Size(...), interpolation, BORDER_TRANSPARENT)` (opencv.cpp:535) inside `cvTransformImage` (opencv.cpp:520), with interpolation methods selected from OpenCV enums. The registration/mpp stacker also uses `cv::remap` with precomputed maps (mpp_warp_stack.cpp — checked; no hand-rolled bilinear loop). `matching/apply_match.c` only transforms star **coordinates** (atApplyTrans), not pixels. `shift_methods.c` is DFT phase-correlation / KOMBAT integer shifting.

Warp.swift's substance — inverse-mapped bilinear sampling with an explicit all-taps-in-bounds coverage mask that deliberately drops the ~1-px partially covered rim (Warp.swift:3-7, 24-37), planar channel layout, `Parallel.rows` row-sliced parallelism (Warp.swift:20) — has no textual or structural counterpart anywhere in the reference set. The boundary condition idiom `x0 < w - 1 || (x0 == w - 1 && p.x == Double(w - 1))` (Warp.swift:25-26) is idiosyncratic to the Swift code; nothing similar in Siril.

---

## Cross-cutting checks performed

- Grepped reference tree for Swift magic numbers: `0x5EED`, MMIX LCG constants, `500` RANSAC iters, `0.02` invariant tolerance, cell size 32, minArea 3 / maxArea 400, maxStars 60, voteKeyStride 4096 — **none present** in Siril.
- Grepped Swift for Siril magic numbers: 0.002 triangle radius, 0.9 ratio prune, radius 5.0 / maxdist 50.0, PERCENTILE 0.35, NSIGMA 10.0, HALTSIGMA 1e-1, RANSAC threshold 3, scale 0.9–1.1, KERNEL_SIZE 2, SAT_THRESHOLD 0.7 — **none present** except the 20/2 pair discussed above.
- Comment-text comparison: no echoed phrases; Swift comments cite spec sections ("spec §4.2") and derive constants from first principles (e.g. 1.4826 = 1/Φ⁻¹(0.75)), a style absent from atpmatch/star_finder.
- Structure layouts: `s_star`/`s_triangle` (id/index/a_length/ba/ca/a_index...) vs. Swift `Star{x,y,flux}` / `Triangle{vertices,invariant}` — no correspondence.
- Shared-bug hunt: none found; notably Swift's RANSAC re-validation of the refined fit (TransformSolver.swift:68-72) and Warp's exact-edge acceptance are behaviors Siril doesn't have, and Siril's known quirks (e.g. `set_triangle` a==0 → ba=ca=1.0 hack, atpmatch.c:1430-1441) are absent from Swift.

## Final verdicts

- **StarDetector.swift — INDEPENDENT.** Different algorithm entirely from Siril's PSF-fitting finder; only overlaps are textbook constants (5σ, 1.4826).
- **TriangleMatcher.swift — ALGORITHM-CONVERGENT.** Published Groth/Valdes voting scheme; expression diverges from Siril at every decision point. Only overlap: defaults 20 (TriangleMatcher.swift:56 / atpmatch.h:71) and 2 (TriangleMatcher.swift:58 / atpmatch.h:146), both published `match`-program defaults. Invariant pair is astroalign-style (MIT).
- **TransformSolver.swift — INDEPENDENT.** Siril has no RANSAC/Umeyama code to copy (delegates to OpenCV); all constants diverge. Probable astroalign influence (PIXEL_TOL 2, similarity model) — MIT, no license issue.
- **Warp.swift — INDEPENDENT.** Siril has no hand-written warp (delegates to OpenCV warpPerspective/remap); no counterpart text exists.

**GPL exposure assessment: none identified.** No copied expression from the GPLv3 reference was found; the shared elements are published algorithms, literature defaults, and textbook constants, none of which carry Siril's (or Richmond's) copyrightable expression.
