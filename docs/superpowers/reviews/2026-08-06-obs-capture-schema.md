# Real-OBS capture settings-schema probe (Task 1 gate)

**Date:** 2026-08-06
**OBS version:** 32.1.2 (obs-websocket 5.7.3)
**Method:** `Scripts/obs_smoke.swift --probe-capture` run against a locally running OBS 32.1.2 instance (WebSocket server on `localhost:4455`, auth enabled), via `GetInputList` + `GetInputSettings` for every input in the user's real profile/scene collection.

## Scene contents at probe time

Scene `"Scene"` (the user's real scene, used for a real stream the night before) contained three inputs. Only `"macOS Screen Capture"` is in scope for the provisioning schema; the other two are included for completeness.

## Capture input: `macOS Screen Capture`

- **inputKind:** `screen_capture`
- **Full settings JSON (verbatim, pretty-printed, sorted keys):**

```json
{
  "application" : "",
  "display_uuid" : "37D8832A-2D66-02CA-B9F7-8F30A301B230",
  "show_empty_names" : true,
  "show_hidden_windows" : false,
  "type" : 1,
  "window" : 101370
}
```

**Window binding key:** `window` (an integer — a macOS `CGWindowID`). `type: 1` selects Window Capture mode (0 = Display Capture, 2 = Application Capture, per OBS's macOS `screen_capture` source). `application` is present but empty — it is only populated for `type: 2` (Application Capture); it is not a window-title/owner key for the Window Capture case.

**No title/owner string is persisted in the input settings.** The settings blob is purely the opaque numeric `window` id plus the capture mode/display metadata above — there is no `window_name`, `owner_name`, or similar key in `GetInputSettings` output for this kind.

### How the title actually appears (cross-check via `GetInputPropertiesListPropertyItems`)

To find where a human-readable title/owner shows up at all, the probe additionally called `GetInputPropertiesListPropertyItems` (propertyName `"window"`) against the same input. That call returns the *live enumeration of all currently open windows* OBS offers in its window picker, as `{itemName, itemValue}` pairs, e.g.:

```json
{ "itemName": "[LiveAstro Studio] LiveAstro", "itemValue": 101370 },
{ "itemName": "[LiveAstro Studio] Window",    "itemValue": 103858 },
{ "itemName": "[OBS Studio] OBS 32.1.2 - Profile: Untitled - Scenes: Untitled", "itemValue": 103852 },
...
```

`itemName` is formatted `"[<owning app name>] <window title>"`; `itemValue` is the same integer that appears as `window` in the persisted settings. **This is the only place `owner`/`title` strings appear at all** — they exist solely in this live, ephemeral enumeration, never in `GetInputSettings`.

### Important finding: the persisted `window` id is not stable across window lifecycles

At probe time, `window: 101370` (the value saved from last night's stream, when it was bound to the "LiveAstro Broadcast" window) now resolves via the property-items enumeration to `"[LiveAstro Studio] LiveAstro"` — the app's **main** window title, not `"LiveAstro Broadcast"`. The "LiveAstro Broadcast" window is not currently open (the app is running but the broadcast window is closed), and macOS appears to have reused the numeric `CGWindowID` 101370 for the newly created main window after the original broadcast window closed.

**Implication for Task 5 (`OBSCaptureSchema`):** the persisted `window` integer id is a snapshot, not a stable handle — it can silently point at the wrong window (or a since-closed/reused id) after any window churn. A correct provisioning flow must **re-derive** the id at Go Live time by calling `GetInputPropertiesListPropertyItems` for `"window"` and matching on the `"[<owner>] <title>"` string (owner = app name, title = `"LiveAstro Broadcast"` per `BroadcastWindowConfigurator`), then writing the matched `itemValue` into `SetInputSettings`, rather than trusting/reusing whatever numeric `window` id happens to already be in the input's settings.

## Other inputs (not in scope, recorded for completeness)

- `Mic/Aux` — kind `coreaudio_input_capture` — `{"device_id": "default"}`
- `Seestar Scope` — kind `ffmpeg_source` — `{"input": "rtsp://192.168.1.28:4554/stream", "is_local_file": false}`

## Summary

| Item | Value |
|---|---|
| OBS version | 32.1.2 |
| obs-websocket version | 5.7.3 |
| Capture input kind | `screen_capture` |
| Window-binding key (persisted) | `window` (integer `CGWindowID`) |
| Mode key | `type` (`1` = Window Capture) |
| Title/owner source | **not** in persisted settings; only in `GetInputPropertiesListPropertyItems` item names, formatted `"[owner] title"` |
