# Roadmap Notes

This is a lightweight product roadmap for work that does not depend on immediate clear-sky field validation.

## After Public Docs

Once the public guide, beta quickstart, visual docs, and distribution notes are in good shape, shift from explaining the app to improving the product path itself.

## Current Status

Shipped public-polish items:

- **Start workflow chooser** — the app now names user intents directly.
- **Stack Previous Shoot…** — public wording now matches how users think about offline stacking.
- **Output discoverability** — replay, session folder, latest image, master, summaries, support bundle, log tail, and output-footprint actions are visible after a session.
- **Operational support surface** — session health, build version, output footprint, support bundle, and `latest.png` are available for beta/support conversations.
- **No-sky demo path** — **Try Demo** now starts a local sample stack stream in the app; `swift run demo-stack ...` remains available from source.
- **Completed-session reports v1** — finished sessions write `session-summary.md` and `frame-summary.csv`, with app shortcuts to open them.

Remaining near-term product candidates:

1. previous-shoot quality workflow: ETA, richer per-sub quality metrics, final report;
2. optional problem notifications / unattended confidence;
3. visual identity and release screenshots;
4. test-harness hygiene for OBS mock continuation warnings.

### 1. First-Run Workflow Chooser — shipped

Add a first-run or prominent start workflow that names the user intent directly:

- **Live from Seestar**
- **Live from ASIAIR**
- **Live from Folder / NINA**
- **Watch Siril / External Stacker**
- **Stack Previous Shoot**
- **Try Demo**

This should reduce confusion around why some systems have named buttons and others use a folder picker. NINA should be explicitly presented as the **Live from Folder / NINA** path because NINA already writes FITS files to a normal output folder.

Status: shipped in the Start Workflow section. **Try Demo** now starts a local sample stack stream.

### 2. Rename “Import Subs” for Public Users — shipped

The current label is technically accurate but engineering-flavored. Public users are more likely to think:

> I have last night’s FITS files. Can this stack them?

Candidate public label:

- **Stack Previous Shoot…**

Supporting copy:

- “Choose a folder of existing FITS light frames.”
- “LiveAstro will stack them offline and write a replay plus native master.”

The app can keep using the existing import pipeline behind that clearer public wording.

Status: shipped as **Stack Previous Shoot…** in the app, README, user guide, beta checklist, and bundled Help.

### 3. Make Outputs Obvious — shipped

After ending a session or finishing an offline stack, make artifacts discoverable without Finder archaeology:

- **Open Replay**
- **Reveal Replay**
- **Open Session Folder**
- **Open Sessions Folder**
- **Reveal master.fit**
- **Open Latest Image**
- **Reveal latest.png**
- **Copy Session Summary**
- **Copy Support Bundle**
- **Copy Log Tail**
- **Refresh Sizes**

This is a trust feature. Users should immediately see what LiveAstro produced.

Status: shipped for output actions. `latest.png`, support bundle, and output footprint were added as follow-on polish.

### 4. In-App Demo Mode — v1 shipped, refinements future

Replace the terminal-oriented sample stack generator path with an app-level demo:

- **Try Demo** starts a local sample stack stream and normal LiveAstro session.
- Future refinement: auto-open or highlight the broadcast window.
- Future refinement: optional auto-end / replay walkthrough.

The command-line `demo-stack` generator remains available for development and source-run fallback, but public first impressions no longer depend on Terminal.

### 5. Better Status and Diagnostics

Add a status/diagnostic surface that answers:

- Which folder is LiveAstro watching?
- What was the last file seen?
- What was the last accepted frame?
- Why was the last frame rejected?
- Is OBS connected?
- Is OBS streaming/recording?
- Where is the session output going?

This helps beta users self-debug and gives better feedback when they report issues.

Partial progress: the fixed footer now shows a session health summary and exposes **Copy Health**, **Open Watch Folder**, **Copy Support Bundle**, recent log copying, and completed-session report artifacts. Deeper live per-frame diagnostics remain future work.

### 6. Operational Polish

Borrow the useful unattended-operation ideas from all-sky monitoring tools
without turning LiveAstro into an all-sky camera app. These are product polish
items for deep-sky sessions:

- **Latest image output** — write a `latest.png`
  beside the session so a local web page, Discord bot, or simple monitor can
  show the current stack. **Shipped.**
- **Session health summary** — show accepted frames, rejected frames, last
  rejection reason, current output folder, replay status, and OBS status in one
  place. **Shipped.**
- **Folder size guardrails** — show the output footprint on request and include
  it in support bundles. **Initial informational guardrail shipped; warnings
  and cleanup controls remain future.**
- **Problem notifications** — future optional notifications for session-ending
  errors, stalled input folders, OBS disconnects, or disk-space problems.
- **Unattended run confidence** — make it obvious whether LiveAstro is actively
  receiving frames, holding the last good frame, waiting for input, generating a
  replay, or finished. **Partially shipped through the health summary; stronger
  notifications remain future.**
- **Simple local status page** — possible future read-only page for LAN viewing
  of current stack, session status, and output links.
- **Completed-session summary files** — write readable `session-summary.md` and
  spreadsheet-friendly `frame-summary.csv` beside the manifest. **Shipped.**

These should stay downstream of LiveAstro's real job: DSO stacking, broadcast,
session records, and replay. Camera acquisition, all-sky scheduling, meteor
detection, keograms, and long-term sky monitoring remain outside the product
lane.

### 7. Previous-Shoot Quality Workflow

If “Stack Previous Shoot” becomes first-class, polish the offline path:

- clearer calibration setup
- progress ETA
- final quality report
- richer per-sub exposure and quality metrics, ideally as both an in-app table
  and an expanded CSV for later inspection
- Siril parity report output when a benchmark corpus is available
- processing summary saved with the session. **Initial `session-summary.md` and
  `frame-summary.csv` shipped; richer quality scoring remains future.**

Future mixed-setup handling belongs here, not in the live stacker. A later
offline-only pass could preflight a folder for different cameras, dimensions,
binning, focal lengths, or image scales; warn when the data appears to come
from multiple setups; and either group compatible frames or offer a slower
deep-registration path. Live stacking should stay optimized for timely,
consistent-frame broadcast work rather than trying to solve arbitrary
multi-rig archival registration in real time.

### 8. Visual Identity

After the workflow is clearer:

- app icon
- About window
- visible version/build
- release screenshots
- optional DMG polish
- simple public landing page or GitHub visual section

### 9. Test Harness Hygiene

The OBS mock socket should be hardened so overlapping or abandoned test
receives cannot leak a checked continuation. This is test-only cleanup — the
production OBS client has a single receive loop — but the default suite should
eventually run without runtime continuation warnings.

## Recommended Next Product Slice

After the shipped docs/output/health polish, the highest-leverage implementation slices are:

1. **Previous-shoot quality report**
2. **Per-sub exposure and quality metrics**
3. **Problem notifications / unattended confidence**
4. **Visual identity and release screenshots**
5. **Test-harness hygiene for OBS mock continuation warnings**

That is the shortest path from “people can understand it” to “people can evaluate it without clear skies.”
