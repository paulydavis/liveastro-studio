# Runbook — First Live Dry Run (2026-07-06, Round Rock TX)

**Goal:** full production chain under real sky: Seestar S30 Pro → SMB relay → Siril livestack → LiveAstro Studio → OBS (stack + scope RTSP + camera) → unlisted YouTube stream → auto replay.

**Conditions:** patchy clouds 27–47% (usable), astro dark 22:12, moon 54% rises **00:40** — wrap by ~00:30. Dew point 20–22 °C: **Anti-Dew ON**.

**Target:** NGC 7000 (North America Nebula) — high all evening, Ha-strong, LP-filter friendly.

Known-good facts from today's recon: Seestar SMB share is always-on in Station Mode (no app setting) — guest, share name `EMMC Images`, host `seestar.local` (was 192.168.1.28; may change after power cycle). RTSP port 4554 only opens while the camera is active.

---

## Phase 0 — Daylight prep (any time before dark)

- [ ] Charge / power plan for Seestar (69% earlier — top it up; battery session ≈ 4-5 h with Anti-Dew on)
- [ ] Seestar app → device settings → **Anti-Dew: ON**
- [ ] Confirm **Station Mode** still joined to the house Wi-Fi (SpectrumSetup-6242)
- [ ] Mac on the same Wi-Fi; close Slack/Teams/etc. (bandwidth + no notification pops on stream)
- [ ] OBS open once; confirm the scene from yesterday still lists the LiveAstro Broadcast window
- [ ] Rebuild the app fresh so tonight runs current main:
  ```
  cd ~/Desktop/liveastro-studio && git pull && swift build
  ```
- [ ] Empty local watch folder:
  ```
  rm -rf ~/Desktop/livestack_live && mkdir -p ~/Desktop/livestack_live
  ```

## Phase 1 — Scope up (~21:45)

- [ ] Seestar outside, level-ish, clear view NE–overhead
- [ ] App: goto **NGC 7000** → let it plate-solve and center
- [ ] Start imaging (20 s subs). **Confirm subs are saving** (app shows frame counter climbing)
- [ ] Verify the sub folder appeared:
  ```
  ls ~/seestar_mnt/MyWorks/ 2>/dev/null || echo "mount first (Phase 2)"
  ```

## Phase 2 — Mac plumbing (~21:55)

Terminal 1 — mount the Seestar + start the relay:
```
mkdir -p ~/seestar_mnt
mount_smbfs -o nobrowse "//GUEST:@seestar.local/EMMC%20Images" ~/seestar_mnt
ls ~/seestar_mnt/MyWorks/          # find tonight's exact folder name
~/Desktop/liveastro-studio/Scripts/seestar_relay.sh \
    ~/seestar_mnt/MyWorks/"NGC 7000_sub" ~/Desktop/livestack_live
```
(If `seestar.local` doesn't resolve, get the IP from the app's RTSP Get dialog and use it in place of the hostname.)

- [ ] Relay counter starts climbing within one sub cadence

Siril:
- [ ] Open Siril → hamburger menu → **Livestacking**
- [ ] Watch folder: `~/Desktop/livestack_live`
- [ ] **Debayer ON** (subs are GRBG OSC), registration on → Start
- [ ] Confirm `live_stack.fit` appears in `~/Desktop/livestack_live` after 1–2 subs

Terminal 2 — LiveAstro:
```
cd ~/Desktop/liveastro-studio && swift run LiveAstroStudio
```
- [ ] Watch folder: `~/Desktop/livestack_live`
- [ ] File name filter: `live_stack` (default — leave it)
- [ ] Profile: `NGC 7000 North America Nebula` / Seestar S30 Pro / 20 s subs / Round Rock, TX / Bortle 7
- [ ] Open Broadcast Window → **Start Session**
- [ ] First stack appears in the broadcast window (may take 2–3 subs)

## Phase 3 — OBS scenes (~22:05)

Scene "Stack" (main):
- [ ] macOS Screen Capture → window "LiveAstro Broadcast" → Fit to screen (⌘F)

Scene additions (build once, reuse):
- [ ] **Scope view**: app → Advanced Feature → Telephoto RTSP → Get (port opens only while imaging) → OBS + → **Media Source** → uncheck Local File → paste `rtsp://…:4554/stream` → shrink to top-right PiP
- [ ] **You**: OBS + → **Video Capture Device** → Mac camera or iPhone Continuity Camera → top-left PiP, modest size
- [ ] Optional extra scenes: "Scope full" (RTSP fullscreen) and "Mix" — switch live as the night flows

## Phase 4 — Go live (~22:15)

- [ ] YouTube Studio → Create → **Go Live** → visibility **Unlisted** (or Public if feeling brave) → copy stream key
- [ ] OBS → Settings → Stream → YouTube → paste key → OK → **Start Streaming**
- [ ] Check the stream on your phone: image updating, overlay legible, audio levels sane if mic on
- [ ] Talk to the void (or post the link to the astro friends — it's a dry run, low stakes)

## Phase 5 — During (22:15 – 00:30)

- Clouds will pass through — that's fine and even good content; the stack pauses (Siril rejects bad subs) and resumes
- Watch the LiveAstro control-window log occasionally: `✓ update N` lines should track Siril's stack revisions
- Every 30–45 min: glance at the Seestar window for dew (Anti-Dew should handle it)
- Scene-switch when something happens: meridian-ish jumps, cloud gaps, goto adjustments → "Scope full" scene

## Phase 6 — Wrap (~00:30, before moonrise 00:40)

1. [ ] **End Session** in LiveAstro *while still streaming* — say goodnight over the final frame (no black flash)
2. [ ] Stop Streaming in OBS
3. [ ] Stop imaging in the Seestar app; park/shutdown scope; bring it in
4. [ ] Ctrl+C the relay; unmount: `umount ~/seestar_mnt`
5. [ ] Watch `replay.mp4` (Reveal in Finder from LiveAstro) — tonight's whole session in 45 s
6. [ ] Session folder: `~/Documents/LiveAstro/2026-07-06-ngc7000…/` — safe to re-render any time via Regenerate

## Fallbacks

| Problem | Move |
|---|---|
| SMB mount refuses | Use IP instead of seestar.local; power-cycle Seestar re-joins Station Mode |
| Relay copies nothing | Check exact folder name (`ls ~/seestar_mnt/MyWorks/`) — target name in app sets it |
| Siril livestack won't start / errors | Fall back: skip Siril; LiveAstro can't stack, so stream RTSP + camera only; after the session run `Scripts/build_session_from_subs.py` (edit SRC/OUT paths) for the replay |
| live_stack.fit appears but LiveAstro silent | Check filter field says `live_stack`; check control-window log for skip errors |
| RTSP won't connect in OBS | Get the address again while actively imaging (port closes when idle) |
| Stream stutters | OBS Settings → Output → lower bitrate to 4500 Kbps; house upload may be modest |
| Clouds win completely | Everything above minus sky: it's still a full rig rehearsal, and fakesiril can stand in |

## Success = any of these

- Replay.mp4 of real NGC 7000 photons captured live tonight
- 30+ min of stable multi-source stream
- A list of what annoyed you (that's next week's worklist)
