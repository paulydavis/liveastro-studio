# OBS Broadcast Pre-flight & One-Button Go Live — Design

**Goal:** kill the broadcast setup friction from the 2026-08-06 real session ("it worked but
was cumbersome to setup"): after one-time YouTube linking, a session is *launch app → Start
Seestar → Go Live*. The app provisions and verifies the whole OBS chain itself and shows a
live status panel, so "is it ready?" is answered on screen instead of by checking two apps.

**Decisions (owner, 2026-08-06):** one-button Go Live + status panel; adopt-and-repair the
user's own scenes (never an app-owned layout while the user has scenes); stream key is
check-only — the app never stores or writes it.

**Non-goals:** no in-app layout/PiP/scene-template editor — OBS remains the compositor for
camera PiP, AirPlay-mirrored Seestar/ASIAIR apps, NINA captures, and multi-scene combos; the
app guarantees only its own feed exists in the selected stack scene. No YouTube OAuth / stream
key management. No change to stall-based scene automation, quit-safety, or reconcile
semantics. No OBS config file writes.

## 1. UX / flow

The OBS section becomes a **pre-flight status panel**: five links rendered as a chain, each
grey (unchecked) / spinner (checking or fixing) / green (ok) / red (failed + one-line reason +
remedy hint):

1. **OBS running** — auto-launch via existing NSWorkspace path if not.
2. **Connected** — WebSocket session up (auto-discovered credentials, §3).
3. **Stack scene capture** — selected stack scene contains a working capture of the broadcast
   window; add/repair only that one source.
4. **Stream service** — OBS has a streaming service + non-empty key configured.
5. **Streaming** — stream active (adopt-don't-restart reconcile semantics, unchanged).

**Go Live** walks the chain top to bottom, halting at the first failure; pressing it again
resumes from the first non-green link. The broadcast window is opened automatically before
link 3 (OBS binds by window title; a window that isn't on screen can't be captured). The
manual host/port/password fields remain as an override for remote or nonstandard setups.

Help tab gains a **recipes section** (documentation, not code): adding a camera PiP,
mirroring the Seestar/ASIAIR phone app via AirPlay, capturing NINA, multi-scene combos.

## 2. Architecture

Single owner of broadcast choreography, three pieces:

- **`PreflightState`** (LiveAstroCore, value type): the five links, each
  `unknown | checking | ok | failed(reason: String, remedy: String)`. Published by
  `BroadcastController`; the UI renders it dumbly.
- **`OBSLocalConfig`** (LiveAstroCore, new small type): read-only parser for
  `~/Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json`
  (`server_enabled`, `server_port`, `server_password`). Read fresh at each Go Live (the
  password can regenerate). Missing/unreadable file → fall back to manual fields. Never
  writes.
- **`OBSController`** gains the obs-websocket v5 provisioning primitives:
  `GetSceneItemList`, `GetInputSettings`, `SetInputSettings`, `CreateInput`, `CreateScene`,
  `GetStreamServiceSettings`. `BroadcastController.goLive()` becomes the staged chain driving
  them; End Session / quit / Disconnect cancel the in-flight chain exactly like the existing
  `obsBringUpTask` pattern (the 2026-07 bring-up-race and quit-safety invariants carry over
  unchanged).

## 3. Provisioning details

- **Config discovery:** read `OBSLocalConfig` at Go Live. `server_enabled: false` → link 2
  red with the one-time "enable in OBS → Tools → WebSocket Server Settings" remedy (cannot be
  flipped remotely). Auth failure with an auto-read password → one config re-read + reconnect
  retry (regenerated-password case), then red with manual-field hint.
- **Capture verification (adopt-by-name, then by-target):** `GetSceneItemList` on the
  selected stack scene → find an input named **"LiveAstro Stack"**, else any capture-kind
  input already targeting the broadcast window (adopts pre-existing user setups without
  renaming). Found-but-mistargeted → `SetInputSettings` repair. Absent → `CreateInput` into
  the user's scene. No scenes at all → `CreateScene("LiveAstro")` + `CreateInput`. The
  broadcast window is opened and confirmed present (bounded retry) first.
  *(Amended 2026-08-06 per the Task-1 probe: OBS 32 persists window capture as a numeric
  CGWindowID only — no title string exists in settings, and saved ids go stale across window
  recreation. The app therefore derives the id from its own window (`NSWindow.windowNumber`)
  at every Go Live and rebinds the source when it differs; the title identifies our window
  app-side only. A rebind on the first Go Live of each launch is expected behavior.)*
- **Settings-schema gate (binding):** the exact macOS `screen_capture` input-kind settings
  schema (how OBS 32 encodes "capture this window") is probed against real OBS during
  implementation — create the source by hand once, `GetInputSettings`, copy the schema
  verbatim into constants — not trusted from docs. Task 1 of the plan; no provisioning code
  ships before the probe.
- **Stream check:** `GetStreamServiceSettings`; key **presence** only — the value is never
  logged, stored, or displayed.

## 4. Error handling & safety invariants

- Every stage has a bounded timeout; failures carry reason + remedy; the chain is resumable.
- All provisioning is **additive and idempotent**: adopt-before-create means re-runs never
  duplicate; the app **never deletes, renames, or reorders** any OBS object. The only objects
  it ever creates or modifies: the "LiveAstro Stack" input and (only when the user has no
  scenes) the "LiveAstro" scene.
- Cancellation (End Session / quit / Disconnect) aborts the chain; no rollback is needed
  because nothing destructive ever runs.
- Binding invariants from 2026-07, unchanged and re-verified: quit never stops a stream; only
  End Session / End Broadcast send StopStream; a cancelled bring-up can never start a
  broadcast after end. Existing tests pinning these must pass unmodified.

## 5. Testing

- **`OBSLocalConfig`:** fixture-JSON parse tests — normal, server disabled, missing fields,
  corrupt file, absent file.
- **Provisioning (ScriptedOBSServer mock):** adopt-by-name; adopt-by-target; repair
  (SetInputSettings recorded with correct schema); create-input; create-scene; stream-key
  absent; plus an invariant test asserting **no removal-type request is ever emitted** across
  all paths.
- **Stage machine:** ordering, halt-on-fail, resume-from-first-non-green, mid-stage
  cancellation, per-stage timeout.
- **Regression:** existing quit-safety and bring-up-race suites unmodified and green.
- **Manual smoke:** extend `Scripts/obs_smoke.swift` against real OBS 32 — doubles as the
  §3 settings-schema probe.
