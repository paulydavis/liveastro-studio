# OBS + YouTube End-to-End Validation (MVP DoD gate)

Spec §10 requires a real session streamed to YouTube via OBS before v1 is done.
Record results inline; this file is the evidence.

## Setup
- [x] LiveAstro Studio running; broadcast window open (1920×1080)
- [x] OBS: Settings → Video → Base & Output canvas 1920×1080, 30 fps
- [x] OBS: add Source → macOS Screen Capture (or Window Capture) → window "LiveAstro Broadcast"
- [x] Grant macOS Screen Recording permission to OBS if prompted
- [x] Source fills the canvas exactly (right-click → Transform → Fit to screen)
- [x] YouTube Studio → Create → Go Live → obtain stream key (set visibility **Unlisted** for the test)
- [x] OBS: Settings → Stream → YouTube, paste key

## Live test (can use fakesiril if the sky doesn't cooperate)
- [x] Start Session in LiveAstro; confirm stack updates appear
- [x] Start Streaming in OBS; watch the YouTube preview
- [x] Verify on a second device (phone): image updates visible within one stack cadence
- [x] Verify overlay legibility at YouTube 1080p compression: target name, integration
      counter, equipment line, elapsed clock all readable
- [x] Let it run ≥ 15 minutes; confirm no broadcast-window blanking or stutter
- [x] End Session in LiveAstro while still streaming; confirm broadcast window keeps
      the final frame (no black flash on stream)
- [x] Stop streaming; confirm replay.mp4 plays in QuickTime and looks correct

## Results
| Date | Source (real Siril / fakesiril) | Stream URL | Overlay legible? | Issues |
|------|--------------------------------|-----------|------------------|--------|
| 2026-07-06 | fakesiril (241 × 20s synthetic session) | unlisted YouTube test stream (URL withheld) | Yes — target name, integration caption, elapsed clock all readable at YouTube 1080p compression | Two setup issues found & fixed: OBS needed Screen Recording permission + restart; broadcast window needed a window-server title for ScreenCaptureKit listing (fixed in 45cf6b8). End Session held final frame on stream, no black flash. replay.mp4 played correctly. |
