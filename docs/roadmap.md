# Roadmap Notes

This is a lightweight product roadmap for work that does not depend on immediate clear-sky field validation.

## After Public Docs

Once the public guide, beta quickstart, visual docs, and distribution notes are in good shape, shift from explaining the app to improving the product path itself.

### 1. First-Run Workflow Chooser

Add a first-run or prominent start workflow that names the user intent directly:

- **Live from Seestar**
- **Live from ASIAIR**
- **Live from Folder / NINA**
- **Watch Siril / External Stacker**
- **Stack Previous Shoot**
- **Try Demo**

This should reduce confusion around why some systems have named buttons and others use a folder picker. NINA should be explicitly presented as the **Live from Folder / NINA** path because NINA already writes FITS files to a normal output folder.

### 2. Rename “Import Subs” for Public Users

The current label is technically accurate but engineering-flavored. Public users are more likely to think:

> I have last night’s FITS files. Can this stack them?

Candidate public label:

- **Stack Previous Shoot…**

Supporting copy:

- “Choose a folder of existing FITS light frames.”
- “LiveAstro will stack them offline and write a replay plus native master.”

The app can keep using the existing import pipeline behind that clearer public wording.

### 3. Make Outputs Obvious

After ending a session or finishing an offline stack, make artifacts discoverable without Finder archaeology:

- **Open Replay**
- **Open Session Folder**
- **Reveal master.fit**
- **Copy Session Summary**

This is a trust feature. Users should immediately see what LiveAstro produced.

### 4. In-App Demo Mode

Replace the terminal-oriented sample stack generator path with an app-level demo:

- **Try Demo**
- generate or play a sample stack stream
- open the broadcast window
- end with a sample replay/session output

Keep the command-line sample stack generator for development, but do not make public users depend on Terminal for the first impression.

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

### 6. Operational Polish

Borrow the useful unattended-operation ideas from all-sky monitoring tools
without turning LiveAstro into an all-sky camera app. These are product polish
items for deep-sky sessions:

- **Latest image output** — optionally write a `latest.png` or `latest.jpg`
  beside the session so a local web page, Discord bot, or simple monitor can
  show the current stack.
- **Session health summary** — show accepted frames, rejected frames, last
  rejection reason, current output folder, replay status, and OBS status in one
  place.
- **Folder size guardrails** — warn before relay/snapshot/replay outputs grow
  unexpectedly large; eventually offer per-session cleanup controls.
- **Problem notifications** — future optional notifications for session-ending
  errors, stalled input folders, OBS disconnects, or disk-space problems.
- **Unattended run confidence** — make it obvious whether LiveAstro is actively
  receiving frames, holding the last good frame, waiting for input, generating a
  replay, or finished.
- **Simple local status page** — possible future read-only page for LAN viewing
  of current stack, session status, and output links.

These should stay downstream of LiveAstro's real job: DSO stacking, broadcast,
session records, and replay. Camera acquisition, all-sky scheduling, meteor
detection, keograms, and long-term sky monitoring remain outside the product
lane.

### 7. Previous-Shoot Quality Workflow

If “Stack Previous Shoot” becomes first-class, polish the offline path:

- clearer calibration setup
- progress ETA
- final quality report
- per-sub exposure and quality data, ideally as both an in-app table and an
  exportable CSV/summary for later inspection
- Siril parity report output when a benchmark corpus is available
- processing summary saved with the session

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

After the docs/distribution branch lands, the highest-leverage implementation slice is:

1. **First-run workflow chooser**
2. **Stack Previous Shoot wording**
3. **Open Replay / Open Session Folder actions**
4. **Session health summary**

That is the shortest path from “powerful app” to “people understand how to use it without an explanation.”
