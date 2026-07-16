# Relay Auto-Prune — Design

**Date:** 2026-07-13
**Branch:** `feature/relay-auto-prune` (off `main` @ adbb57f)
**Status:** approved for planning

## Problem

Every live session (Seestar / ASIAIR / watch-folder start) copies incoming subs into a per-session staging folder under `~/LiveAstro/relay/` so the watcher never reads partial files off a slow SMB share. Nothing ever deletes those folders: the relay root accumulates forever (currently 19 GB across 4 sessions, dominated by two NGC 6960 nights). The relayed subs are by-design duplicates of the originals on the Seestar EMMC / source rig, so old sessions are pure reclaimable space.

## Goal

Age-based auto-prune, run at session start: just before a new relay session is created, delete relay session folders strictly older than a configurable retention window (default **7 days**, settable Off/3/7/14/30). Deletions are name-pattern-guarded, never touch the active or about-to-be-created session, and are logged with the space freed.

## Non-Goals

- No size-cap policy (age-based only; a cap can be a later refinement).
- No launch-time or background/scheduled pruning — session start only (relays only matter when a session runs).
- No manual "Clean now" button in v1.
- Never touches anything outside `~/LiveAstro/relay/`; never deletes the masters/sessions/replays trees.
- No Trash round-trip — direct delete (the contents are by-design duplicates), each removal logged.

## Components

### 1. `RelayPruner` — new, `Sources/LiveAstroCore/Live/RelayPruner.swift`

Pure, testable, no app state:

```swift
public enum RelayPruner {
    public struct Removed: Equatable {
        public let name: String
        public let bytes: Int64
    }
    /// Delete session dirs under `root` whose NAME-embedded date is strictly older
    /// than `now − olderThanDays` (date granularity). Returns what was removed.
    /// `olderThanDays <= 0` ⇒ no-op. `excluding` (the active / about-to-be-created
    /// session dir) is never deleted even if its date qualifies.
    public static func prune(root: URL, olderThanDays: Int, now: Date = Date(),
                             excluding: URL? = nil) -> [Removed]
    /// The YYYY-MM-DD session date parsed from a relay dir name
    /// ("<target>-YYYY-MM-DD[-<exp>s]"), or nil if the name doesn't embed one.
    static func sessionDate(fromName: String) -> Date?
}
```

- **Date from the NAME, not mtime** — relaying touches file/dir mtimes, and the app's own naming (all 3 creation sites in `AppModel`) embeds `YYYY-MM-DD`. Parse the LAST occurrence of a `\d{4}-\d{2}-\d{2}` token that validates as a real calendar date (target names can contain digits/hyphens; a trailing `-30.0s` exposure suffix may follow). Interpret in the user's current calendar/timezone at start-of-day.
- **Unparseable name ⇒ never deleted.** Any folder without a valid embedded date is skipped (safety default for hand-made or foreign folders).
- **Strictly older than the cutoff:** delete iff `sessionDate < startOfDay(now) − olderThanDays` (date-granularity; a 7-day setting always retains a full week, and today's session is never eligible).
- Only immediate subdirectories of `root` are considered (never files, never recursion above/below); `root` missing or empty ⇒ `[]`. Deletion failures are skipped and not reported as removed (best-effort; never throws).
- `bytes` = recursive allocated size before deletion (for the log line).

### 2. Settings — `SessionSettings.relayRetentionDays: Int`

Default **7**; `0` = Off. Full codable pattern (stored property, init param + assignment, CodingKeys, `decodeIfPresent ?? 7`), mirroring `frameWeightingEnabled`.

### 3. `AppModel` wiring

- `var relayRetentionDays = 7`, persisted via `currentSettings()`/`loadSettings()` like siblings.
- At EACH of the 3 relay-creation sites (`configureAndStartWatchFolder`, `configureAndStartSeestar`, the ASIAIR path — the `relayDir` construction points), immediately before `relay.start()`:

```swift
let relayRoot = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("LiveAstro/relay", isDirectory: true)
for r in RelayPruner.prune(root: relayRoot, olderThanDays: relayRetentionDays, excluding: relayDir) {
    log.append("pruned relay \(r.name) (\(ByteCountFormatter.string(fromByteCount: r.bytes, countStyle: .file)))")
}
```

Prune is synchronous and fast for a handful of dirs; it runs on the same (main-actor) path that is about to start a session. Directory removal of multi-GB trees is filesystem-metadata work, not data copying — acceptable at session start.

### 4. UI — `ControlView`

A "Keep relay sessions" row in the Watch Folder section (near the source picker), using the existing ⓘ pattern:

```swift
HStack(spacing: 6) {
    Text("Keep relay sessions")
    InfoButton(text: "Live sessions stage incoming subs in ~/LiveAstro/relay. Sessions older than this are deleted automatically when a new session starts — they are copies; originals stay on the Seestar/rig. Off disables pruning.")
    Spacer()
    Picker("", selection: $model.relayRetentionDays) {
        Text("Off").tag(0); Text("3 days").tag(3); Text("7 days").tag(7)
        Text("14 days").tag(14); Text("30 days").tag(30)
    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
}
.disabled(model.isRunning || model.isImporting)
```

(Exact layout may follow sibling rows; the ⓘ + picker semantics are the requirement.)

## Determinism / Safety summary

- Name-pattern-guarded, strictly-older-than, date-granularity, exclusion of the active dir, unparseable ⇒ skip, relay-root-only, best-effort non-throwing, every removal logged with size. `olderThanDays <= 0` ⇒ no-op.

## Testing

**Core (TDD, `RelayPrunerTests`):** date parsing (plain `Target-2026-07-09`, exposure-suffixed `NGC 6960-2026-07-11-30.0s`, digits/hyphens in target like `NGC 6960`, invalid date `2026-13-99` ⇒ nil, no date ⇒ nil); cutoff boundary (exactly-N-days-old kept, N+1 deleted); `excluding` honored; unparseable dir survives; files at root untouched; `0` ⇒ no-op; missing/empty root ⇒ `[]`; removed list carries names.
**Settings:** default 7, round-trip, backward-compat blob decodes to 7.
**App/UI:** build-verified; toggle persists; a real prune logs the removals (manual verification on the 19 GB relay root after merge — expected: everything but sessions within 7 days is reclaimed).

## Global Constraints

- Swift 5.10, macOS 14+. LiveAstroCore imports Foundation / CoreGraphics / Accelerate only; zero external deps.
- Deletion ONLY under `~/LiveAstro/relay`, only name-dated immediate subdirectories, strictly older than the window, never `excluding`.
- Default 7 days; 0 = Off; persisted with backward-compat decode `?? 7`.
- Core logic TDD'd; app/UI build-verified.

## Task Order (for the plan)

1. **T1 — `RelayPruner` (TDD).** Parsing + prune semantics, all safety rails.
2. **T2 — Settings + AppModel wiring at the 3 sites + ControlView picker (TDD settings + build).**
