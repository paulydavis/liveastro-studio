# OBS + YouTube End-to-End Validation (MVP DoD gate)

Spec §10 requires a real session streamed to YouTube via OBS before v1 is done.
Record results inline; this file is the evidence.

## Setup
- [ ] LiveAstro Studio running; broadcast window open (1920×1080)
- [ ] OBS: Settings → Video → Base & Output canvas 1920×1080, 30 fps
- [ ] OBS: add Source → macOS Screen Capture (or Window Capture) → window "LiveAstro Broadcast"
- [ ] Grant macOS Screen Recording permission to OBS if prompted
- [ ] Source fills the canvas exactly (right-click → Transform → Fit to screen)
- [ ] YouTube Studio → Create → Go Live → obtain stream key (set visibility **Unlisted** for the test)
- [ ] OBS: Settings → Stream → YouTube, paste key

## Live test (can use fakesiril if the sky doesn't cooperate)
- [ ] Start Session in LiveAstro; confirm stack updates appear
- [ ] Start Streaming in OBS; watch the YouTube preview
- [ ] Verify on a second device (phone): image updates visible within one stack cadence
- [ ] Verify overlay legibility at YouTube 1080p compression: target name, integration
      counter, equipment line, elapsed clock all readable
- [ ] Let it run ≥ 15 minutes; confirm no broadcast-window blanking or stutter
- [ ] End Session in LiveAstro while still streaming; confirm broadcast window keeps
      the final frame (no black flash on stream)
- [ ] Stop streaming; confirm replay.mp4 plays in QuickTime and looks correct

## Results
| Date | Source (real Siril / fakesiril) | Stream URL | Overlay legible? | Issues |
|------|--------------------------------|-----------|------------------|--------|
|      |                                |           |                  |        |
