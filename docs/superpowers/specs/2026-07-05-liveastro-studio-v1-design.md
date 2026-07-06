# LiveAstro Studio — v1 Design Specification

**Date:** 2026-07-05
**Status:** Approved
**Authors:** Paul Davis (product brief) · Claude (technical design)
**Working name:** LiveAstro Studio

## 1. Product Statement

Turn a live astrophotography session into a polished livestream and an automatic recap video — without manual video editing.

LiveAstro Studio does **not** replace Siril, SharpCap, or other live-stacking software. It monitors live-stack output, presents it cleanly for OBS streaming, and automatically generates a post-session "stack evolution" video showing the image improving over time.

**Trajectory:** shareable tool for the author and astro friends first (GitHub repo + notarized DMG), real product later. Built product-grade from day one; shipped scrappy.

## 2. Primary Use Case

The user images deep-sky objects with varying scopes, cameras, locations, and sub-exposure lengths (20 s to 600 s). Locations range from dark sites to Bortle 7 suburbs.

The app never assumes a fixed update rate. **Each new live-stack image is an event.**

Day-one ingest source: **Siril livestacking**, which writes a single `live_stack.fit` FITS file, updated in place after each accepted sub-exposure.

## 3. Core Workflow

1. User runs Siril (or other live-stacker) which periodically rewrites a stack image in a folder.
2. LiveAstro Studio watches that file/folder.
3. On each completed update: load, auto-stretch, display in the broadcast window, save a snapshot + metadata.
4. OBS captures the broadcast window; user streams via OBS (YouTube/Twitch/etc.).
5. User clicks **End Session**; the app generates a 45-second stack-evolution MP4.

**Design decision: OBS is the streaming hub.** LiveAstro Studio never talks to YouTube/Twitch directly in v1. It focuses on astronomy-specific presentation and recap generation.

## 4. Technology Choices

| Concern | Choice | Rationale |
|---|---|---|
| Language / UI | Swift + SwiftUI, macOS 14+ | macOS-first; crisp broadcast window; clean DMG distribution path to tier-3 product; avoids Python-app translocation/signing pathology |
| Video generation | AVFoundation `AVAssetWriter` | Native H.264 MP4; **zero bundled ffmpeg** |
| Folder watching | DispatchSource file-system events | Native, reliable, no polling in steady state |
| FITS decoding | Purpose-built minimal reader | Siril output is the simple subset (single HDU, 2D/3D, int16/float32). ~200 lines, fully unit-tested. CFITSIO only if exotic files ever demanded |
| Other formats | Apple ImageIO | PNG/JPG/TIFF effectively free |
| Persistence | JSON manifest + PNG snapshots on disk | Human-inspectable, crash-safe, re-renderable |

## 5. Architecture

Single SwiftUI app. Two windows:

- **Control window** — session setup form, folder picker, status log, Start/End Session buttons. Utilitarian; never captured.
- **Broadcast window** — fixed 1920×1080 content, borderless, dark background, zero interactive controls. The only window OBS captures. **Never blanks:** on any error it holds the last good frame. A stream must never flash black because a file was half-written.

### 5.1 Module Map

```
FolderWatcher ──StackUpdate event──▶ ImageLoader ──AstroImage──▶ AutoStretch
                                                                    │
                                              ┌─────────────────────┤
                                              ▼                     ▼
                                        BroadcastView        SnapshotRecorder
                                                                    │
SessionManager (owns state, profile, integration math) ◀────────────┘
                                              │
                                   End Session▼
                                        ReplayGenerator ──▶ replay.mp4
```

### 5.2 FolderWatcher

- Watches user-selected folder **and** the specific stack file (Siril rewrites `live_stack.fit` in place — this is modification-watching, not new-file detection).
- Debounce: quiet period (default 500 ms) after last write event before evaluating.
- **Write-completion check:**
  - FITS: parse header, compute exact expected byte length (header blocks + NAXIS1×NAXIS2×NAXIS3×|BITPIX|/8, padded to 2880-byte blocks). Accept only when file size ≥ expected length. Bulletproof.
  - PNG/JPG/TIFF: file-size stability across two polls 300 ms apart.
- Ignores temp files (`.tmp`, dotfiles, editor droppings).
- De-duplicates: if content hash (cheap: size + mtime + first/last 64 KB digest) matches previous accepted update, skip.
- Emits `StackUpdate` events on an `AsyncStream`.

### 5.3 ImageLoader

- Input formats v1: **FITS (primary)**, PNG, JPG/JPEG, TIFF.
- FITS reader scope: SIMPLE conforming, single primary HDU, `BITPIX ∈ {8, 16, 32, -32, -64}`, `NAXIS ∈ {2, 3}` (mono or 3-plane RGB), honors `BSCALE`/`BZERO`, big-endian data per standard. Anything outside scope → clean error, update skipped.
- Output: `AstroImage` — width, height, channel count, Float32 planar buffer normalized to 0…1, plus linear-data statistics (mean, median, stddev per channel).
- Normalizes orientation (TIFF/EXIF).

### 5.4 AutoStretch

Linear FITS data displayed raw is a black rectangle. This module applies the standard midtone-transfer-function autostretch:

- Shadows clip: `median − 2.8 × MAD` (clamped ≥ 0)
- Midtone balance solved so stretched background lands at target ≈ 0.25
- **Linked channels** for color images (single transform from luminance statistics applied to all channels) so color balance is preserved
- Output: display-ready `CGImage`

PNG/JPG inputs are assumed display-ready; stretch is skipped (user-overridable toggle later if someone feeds linear TIFFs).

### 5.5 SessionManager

State machine: `idle → running → ended`.

Owns:
- **SessionProfile:** target name, telescope, camera, mount, filter, location label, Bortle class, sub-exposure seconds, notes.
- Elapsed wall-clock time.
- Accepted-update count (= frame count assumption: one Siril livestack update per accepted sub).
- **Estimated total integration** = accepted updates × sub-exposure length. Shown live; user-correctable at session end (Siril may reject frames).
- Session manifest, written atomically (temp file + rename) after every snapshot. A crash loses at most the in-flight update.

### 5.6 BroadcastView

- Latest stretched image, fit-to-frame on black, centered.
- Overlay in safe margins, clean typography (SF Pro), fixed layout:
  - Target name (headline)
  - Total integration time (live-ticking)
  - Frame count × sub-exposure length
  - Telescope · Camera
  - Location/Bortle (optional)
  - Session elapsed time
- Broadcast content is a 16:9 composition rendered proportionally at any window size (default 1280×720, minimum 640×360); OBS captures the window at its current size, and users on large displays can size it to 1920×1080 or full screen for maximum capture resolution. Note: this superseded the original fixed-1920×1080 decision on 2026-07-06 after laptop-screen testing. (9:16 vertical: deferred.)

### 5.7 SnapshotRecorder

On every accepted update:
- Save **post-stretch PNG** to `snapshots/NNNN.png` (replay is built from display-ready frames).
- Append manifest entry: index, timestamp, source file path, snapshot path, estimated integration seconds, source dimensions, linear stats (mean/median/stddev).

Snapshots are driven by **stack updates, not wall-clock intervals.** Long subs (10 min) → few snapshots, all kept. Short subs (20 s) → many snapshots, all kept; replay selection thins later.

### 5.8 ReplayGenerator

Runs at End Session (and via a **Regenerate** button that re-renders any past session from disk — algorithm improvements retroactively benefit old sessions).

**Frame selection (v1 algorithm):**
1. Always include first and final snapshots.
2. Logarithmic sampling over snapshot index — early-biased, because improvement is dramatic early and slow late.
3. Near-duplicate removal: mean absolute difference of 64×64 grayscale thumbnails below threshold → drop the later frame.
4. Cap at 30–60 keyframes (default target 45).

**Rendering:**
- AVAssetWriter, H.264 MP4, 1920×1080, 30 fps, default 45 s duration.
- Crossfade between keyframes (Core Image dissolve).
- Caption per keyframe: cumulative integration ("2h 14m · 402 × 20s") + target name.
- Output: `replay.mp4` in the session folder.

Deferred: 15-s vertical Short, GIF, before/after still, thumbnail, intro/outro cards.

### 5.9 Behavior Across Session Types

| Scenario | Snapshots | Replay behavior |
|---|---|---|
| 20 s subs, bright target | Hundreds saved | Log-sampling selects subset, early-heavy |
| 600 s subs | Few saved | Nearly all used |
| Dark site, fast improvement | — | Early change dominates video |
| Bortle 7, slow improvement | — | Later integration milestones preserved by dedupe threshold |

## 6. Session Storage

```
~/Documents/LiveAstro/
  2026-07-05-ngc6888/
    manifest.json
    snapshots/0001.png …
    replay.mp4
```

Manifest schema (per original brief):

```json
{
  "session_id": "2026-07-05-ngc6888",
  "target_name": "NGC 6888 Crescent Nebula",
  "start_time": "2026-07-05T22:15:00-05:00",
  "end_time": null,
  "sub_exposure_seconds": 120,
  "bortle": 7,
  "location_label": "Round Rock, TX",
  "telescope": "120 APO",
  "camera": "ASI2600MC Air",
  "filter": "Dual-band",
  "mount": "AM5N",
  "notes": "",
  "snapshots": [
    {
      "index": 1,
      "timestamp": "2026-07-05T22:17:00-05:00",
      "source_file": "live_stack.fit",
      "snapshot_file": "snapshots/0001.png",
      "estimated_integration_seconds": 120,
      "width": 6248,
      "height": 4176,
      "mean": 0.12,
      "median": 0.08,
      "stddev": 0.04
    }
  ]
}
```

## 7. Error Handling

| Failure | Behavior |
|---|---|
| Partial/corrupt image file | Skip update, log to control window, broadcast holds last good frame |
| FITS outside reader subset | Same as above, with format detail in log |
| Watched folder disappears (drive eject) | Pause watching, banner in control window, auto-resume on reappearance |
| Replay render failure | Snapshots + manifest intact; error surfaced; Regenerate re-runs from disk |
| App crash mid-session | Manifest is atomic-per-snapshot; on relaunch offer to resume or finalize the interrupted session |

## 8. Testing Strategy

- **FITS reader:** unit tests against synthetic files covering every BITPIX, 2D/3D, BSCALE/BZERO, truncated files, junk headers.
- **FolderWatcher:** temp-dir tests simulating slow writes, partial writes, rapid successive rewrites, temp-file noise.
- **AutoStretch:** golden-image tests (known input buffer → known output buffer within tolerance).
- **Frame selection:** pure function over synthetic snapshot lists — verify first/last inclusion, early bias, dedupe, cap.
- **ReplayGenerator:** integration test rendering a tiny (few-frame, low-res) MP4; assert file validity via AVAsset.
- **End-to-end:** scripted fake "Siril" writing FITS files into a temp folder; assert display updates, snapshots, manifest, and replay generation.

## 8.5 Explicitly Deferred from v1 (decided 2026-07-05 during implementation)

- **Integration-time correction at session end** (§5.5): not implemented; manifest JSON is hand-editable as a workaround. Revisit in v1.1.
- **Folder-disappearance banner** (§7): watcher silently pauses and auto-resumes via its poll fallback; no UI feedback yet. Revisit in v1.1.
- **Crash-resume offer on relaunch** (§7): manifest is crash-safe (atomic per snapshot); the relaunch flow is post-MVP.

## 9. Non-Goals for v1

Camera control, native live stacking, mount control, guiding, plate solving, direct YouTube/Twitch upload, OBS plugin/WebSocket/Browser Source, AI narration, automatic target recognition, star counting, vertical formats, XISF.

## 10. Definition of Done (MVP)

- Runs on macOS 14+.
- Monitors a folder containing a changing stack image (FITS from Siril livestack, or PNG/JPG/TIFF).
- Display updates automatically; linear FITS is auto-stretched to look correct.
- OBS captures the broadcast window cleanly.
- **Validated end-to-end on YouTube:** a real session streamed live to YouTube via OBS, with the broadcast window as the primary scene — overlay legible at YouTube's 1080p compression, image updates visible to viewers.
- Snapshots recorded per stack update; session manifest written.
- Generates a usable 45 s 1920×1080 H.264 MP4 evolution video at session end.
- Works with both frequent (20 s subs) and slow (600 s subs) update cadences.

## 11. Long-Term Vision (context, not commitment)

Educational overlays, object database + auto facts, integration milestones, star/nebula labels, Shorts export, chat overlay, OBS WebSocket automation, session reports, before/after generator, smart best-moment detection, XISF, native stacking only if ever needed.

**Differentiator:** not live stacking — automatically turning a technical imaging session into a polished, shareable astronomy experience.
