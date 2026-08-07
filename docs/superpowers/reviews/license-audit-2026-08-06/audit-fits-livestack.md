# Copyright/License Audit — LiveAstro Studio (Swift) vs. Siril (C, GPLv3)

Date: 2026-08-06
Auditor stance: adversarial — assumed derivation, hunted for evidence to refute independence.

TARGET: /Users/pauldavis/liveastro-studio/Sources/LiveAstroCore/
REFERENCE: /private/tmp/claude-501/-Users-pauldavis/2349d1c1-e213-4a31-a397-bea11f9674d7/scratchpad/siril-src/src/ (io/, livestacking/)

---

## Verdict Summary

| Swift file | Verdict |
|---|---|
| FITS/FITSReader.swift | INDEPENDENT |
| FITS/FITSWriter.swift | INDEPENDENT |
| Watch/StackFileWatcher.swift | INDEPENDENT |
| Watch/WatcherFileState.swift | INDEPENDENT |
| Live/FrameRelay.swift | ALGORITHM-CONVERGENT (no textual/structural derivation) |

Tree-wide sweep: NO Siril identifiers, NO GPL header text, NO French comments, NO drizzle
implementation. ONE major license flag UNRELATED to Siril's own code: an admitted GPL-3.0
port in Stacking/Debayer.swift (librtprocess RCD) — see §7.

---

## 1. FITSReader.swift — INDEPENDENT

Structural impossibility of derivation, verified as instructed:

- Siril performs NO FITS parsing of its own. All header/pixel access in
  siril-src/src/io/image_format_fits.c goes through cfitsio:
  - image_format_fits.c:71, 81, 531, 536 — `fits_read_key(...)`
  - image_format_fits.c:741, 746, 833 — `fits_read_img(...)`
  - image_format_fits.c:215 — `fits_read_keyn(...)`
  - image_format_fits.c:864 — comment "let cfitsio do the conversion"
  A grep of src/io/ for `2880`/block-size logic finds nothing: Siril's tree contains no
  hand-rolled card/block parser that FITSReader.swift could have been translated from.
  (ser.c parses SER, a different format, with a different layout — no overlap.)

- FITSReader.swift:8-10 hand-parses raw 2880-byte blocks / 80-char cards
  (`blockSize = 2880`, `cardSize = 80`, `cardsPerBlock`), FITSReader.swift:84-109 parses
  card values including doubled-quote escaping — all of this is the public NASA FITS
  Standard 4.0 (§3.1, §4.2.1), and none of it exists in Siril in any form.

Closest look-alike, examined and dismissed:

- FITSReader.swift:136 `func physical(_ v: Double) -> Double { h.bzero + h.bscale * v }`
  vs. image_format_fits.c:512 comment `physical = BZERO + BSCALE * stored`.
  This is the FITS standard's own scaling equation (FITS 4.0 §4.4.2, also printed in the
  cfitsio manual). A one-line standard formula; not derivation evidence.

- ROWORDER handling (FITSReader.swift:72, FITSTypes.swift:8) vs. fits_keywords.c:66,125,358.
  ROWORDER is a Siril-popularized *file-format convention keyword* (also used by NINA,
  SharpCap). Reading the keyword is interoperability with Siril-produced *files*; the Swift
  parsing code (default BOTTOM-UP, string compare against "TOP-DOWN") shares no expression
  with Siril's cfitsio-callback handler `roworder_handler_read`.

No shared identifiers, no shared control flow, no shared comments. Swift-native error
taxonomy (FITSError, FITSTypes.swift:43-49), Swift overflow-checked dimension validation
(FITSReader.swift:61-69) with no C counterpart.

## 2. FITSWriter.swift — INDEPENDENT

- Siril writes FITS exclusively through cfitsio (`savefits` → fits_write_* in
  image_format_fits.c); it contains no textual card-formatting code.
- FITSWriter.swift:15-42 builds cards by string padding (`padding(toLength: 80 ...)`,
  right-justified value ending column 30, quoted strings padded to 8 chars per FITS §4.2.1)
  — that is a from-the-standard implementation with no possible Siril source text.
- Output branding is native: FITSWriter.swift:68 `HISTORY Stacked by LiveAstro Studio`;
  keyword set (STACKCNT, TOTALEXP) is not Siril's vocabulary (Siril uses LIVETIME/STACKCNT
  via cfitsio keyword tables; no card-layout code overlaps).

## 3. StackFileWatcher.swift — INDEPENDENT

The two watchers solve *opposite* problems with disjoint mechanisms:

| Aspect | Siril livestacking.c | StackFileWatcher.swift |
|---|---|---|
| Event source | GLib `g_file_monitor_directory` (livestacking.c:253), CREATED/MOVED_IN only (livestacking.c:188) | macOS DispatchSource kqueue `.write/.extend` on folder fd (StackFileWatcher.swift:458-459) + poll-timer fallback (429) |
| What it watches for | NEW input subs appearing; explicitly *excludes* its own `live_stack*` outputs (livestacking.c:219-221) | In-place REWRITES of the stacker's output (`live_stack.fit`) — modification-watching (StackFileWatcher.swift:170-172) |
| Completion check | size polled every 80 ms, max 15 iters = 1.2 s, break when size repeats (livestacking.c:56-57, 156-184) | fstat identity (dev,ino,size,mtime-ns) pinned on a per-file descriptor + full-file streaming SHA-256 + digest-stability quiet period (StackFileWatcher.swift:9-133, 633-720) |
| Handoff | GAsyncQueue + `:EXIT:` token to stacker thread (livestacking.c:58, 228, 591) | AsyncStream of StackUpdate with verified FileIdentity (202, 750-753) |
| State model | static globals + booleans (livestacking.c:60-83) | generation-keyed pure reducer, fd-relative enumeration (openat/fdopendir, 298-314), TOCTOU re-validation |

Fingerprint candidates hunted and dismissed:
- Hidden-file skip: livestacking.c:193 `filename[0] == '.'` vs StackFileWatcher.swift:623
  `name.hasPrefix(".")`. Universal idiom; Swift also skips `.tmp`, which Siril does not.
- `live_stack` prefix knowledge (SessionPipeline.swift:139-141, watcher `fileNamePrefix`):
  used to *include* Siril's output files — the inverse of Siril's own strncmp exclusion
  (livestacking.c:219-221). This is interop with Siril's documented output naming, and the
  Swift comments say so openly (StackFileWatcher.swift:171 "Siril rewrites live_stack.fit
  in place"). Knowing a program's output filenames is not code derivation.
- No shared constants: Siril 80 ms/15 iters/1.2 s vs Swift 0.5 s quiet / 2.0 s poll /
  30 s blocker floor. No shared function names, no GLib idioms, no translated control flow.

## 4. WatcherFileState.swift — INDEPENDENT

1371-line pure reducer (WatcherState/GenerationState/RevisionOrderingState/VictimWaitLedger/
WriteOffDecision, WatcherFileState.swift:7-157; command/effect types 272-296; reducer 298+).
Siril's livestacking module has no state machine at all — its entire file-state logic is the
15-iteration size loop (livestacking.c:156-184) and a blocking queue pop (591). There is
literally no reference text this file could derive from; concepts (folder generations,
revision high-water marks, wait-debt write-off accounting) have no Siril analog. Grep of the
file for Siril constants/filenames: only hit is the constructor-supplied `prefix` regex
(1228-1233), which is caller-configured, not hardcoded.

## 5. FrameRelay.swift — ALGORITHM-CONVERGENT

The one genuine conceptual overlap in the audit:

- Siril: wait_for_file_to_be_written(), livestacking.c:156-184 — after a creation event,
  poll disk usage every 80 ms (WAIT_FILE_WRITTEN_US, line 56); if size repeats, the file is
  done; give up after 15 iterations.
- Swift: FrameRelay.swift:106-125 — cross-tick (size, mtime) comparison against the
  previous poll's record (116-119), plus a within-tick 50 ms re-stat (120-124), plus a
  post-copy re-stat discarding torn copies (137-141).

Both implement "a file is complete when its size stops changing" — folklore shared by every
folder-ingest tool (hot-folder watchers, FTP pollers). Evidence AGAINST derivation:
- No shared structure: Siril is a bounded 15-iteration blocking loop on one file after an
  inotify-style event; the relay is a persistent 5 s DispatchSourceTimer sweep over a glob,
  with a baseline snapshot (68-75), staged copy via itemReplacementDirectory + atomic
  rename/replaceItemAt (128-156) — none of which exists in Siril.
- No shared constants (80 ms/1.2 s vs 5 s/50 ms), no failure-after-N-iters semantics, and
  the relay tracks (size, mtime) pairs keyed per name across ticks — a different algorithm
  shape from Siril's single-file size-repeat loop.
- Self-documented independent lineage: FrameRelay.swift:5 "Mirrors the proven
  seestar_relay.sh: mktemp stage → cp source→stage → cp stage→dest" — a translation of the
  author's own shell script, and the mktemp/two-cp pipeline is visibly what the Swift code
  does (84, 132-133).
Verdict: convergent write-completion heuristic; no copied expression. Not SUSPICIOUS.

## 6. Tree-wide identifier sweep (all of Sources/)

- GPL text / origin markers: `grep -rn "GNU General Public|GPL|free-astro|siril.org|Francois Meyer"` → 0 hits.
- Siril-distinctive identifiers: `grep -rniE "imgdata|regdata|imstats|seqname|selnum|readfits|savefits|clearfits|buildseqfile|writeseqfile|seq_check|gfit|com\.wd|com\.pref|siril_log|free_sequence|initialize_sequence|generic_seq|livestacking_display|prepro_"` → 0 hits.
- GLib idioms: `grep -rniE "gchar|gboolean|g_async|GFileMonitor|TYPEFITS|wait_for_file|EXIT_TOKEN|live_stacker"` → 0 hits.
- French comments: accent-class grep → only "Luis Sanz Rodríguez" (a Spanish author credit,
  Debayer.swift:80) and a "÷" glyph in an English comment (MasterBuilder.swift:11). No
  French text.
- Drizzle: `grep -rniE drizzle Sources/` → 0 hits. CONFIRMED: no drizzle implementation.
- "Siril" appears ~25 times, all in comments/UI strings/help text describing interop with
  Siril as an *external producer* (e.g. ControlView.swift:264, Help.md:179, AppModel.swift:22)
  — consistent with independent software that watches Siril's output, and inconsistent with
  concealed copying (a copier scrubs the name; this tree advertises it as a peer product).

## 7. FLAG (out of the five verdicts, in-scope for a license audit): GPL port in Debayer.swift

Sources/LiveAstroCore/Stacking/Debayer.swift:78-83 states verbatim:
  "Faithful Swift port of Luis Sanz Rodríguez's RCD 2.3 from librtprocess
   src/demosaic/rcd.cc, via the validated Python prototype scratchpad/rcd_debayer.py.
   Arithmetic is per-pixel translation of that prototype".

- librtprocess (the RawTherapee-derived demosaicing library, which Siril itself links for
  RCD) is GPL-licensed (GPL-3.0 in its upstream repository — verify the exact version of
  the copied rcd.cc). A self-described "faithful ... per-pixel translation" is a derivative
  work; translation to Swift via a Python intermediary does not launder the copyright.
- The repository has NO LICENSE file (repo root listing) and README/ARCHITECTURE contain no
  license or librtprocess/GPL acknowledgment. If LiveAstro Studio is distributed under a
  non-GPL-compatible license (or none), Debayer.rcd() is the compliance problem in this
  tree — not the Siril comparison.
- Note: this is derivation from librtprocess, NOT from Siril's own src/ (Siril consumes
  librtprocess as a dependency; the reference tree provided contains no rcd.cc), so it does
  not change any of the five per-file verdicts above.

Minor note, no action: Imaging/AutoStretch.swift:4 implements the published PixInsight
midtone-transfer-function autostretch ("PixInsight STF / Siril autostretch family") — the
MTF formula is publicly documented; algorithm-level only, and Siril's implementation is
outside the provided reference dirs.

## 8. Method

Read in full: FITSReader.swift, FITSWriter.swift, FITSTypes.swift, StackFileWatcher.swift,
FrameRelay.swift, WatcherFileState.swift (first 400 lines + targeted greps over remainder),
siril livestacking.c (complete, 878 lines), livestacking.h; targeted reads/greps of
image_format_fits.c and fits_keywords.c to verify cfitsio delegation; identifier/GPL/French/
drizzle sweeps over all of Sources/.
