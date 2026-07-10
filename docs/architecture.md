# LiveAstro Studio — Architecture

Design overview of LiveAstro Studio: a macOS app for **live astrophotography
broadcast** plus a **native FITS stacker** (live + offline import). Two Swift
Package targets — a UI-free core library and a SwiftUI app — with zero external
dependencies (Foundation, CoreGraphics, AVFoundation, Accelerate/vImage,
CryptoKit only).

> Diagrams use [Mermaid](https://mermaid.js.org/); GitHub renders them inline.

## 1. Packages & subsystems

```mermaid
flowchart TB
    subgraph App["LiveAstroStudio (SwiftUI app)"]
        AppModel
        MainView["MainView — Live | Setup | Help tabs"]
        ControlView["ControlView (Setup form)"]
        BroadcastView["BroadcastView (OBS-captured window)"]
        HelpView
        OBS["OBS WebSocket control"]
    end

    subgraph Core["LiveAstroCore (UI-free library)"]
        subgraph Src["Sources"]
            FolderFrameSource
            SeestarDetector
            SeestarRelay
        end
        subgraph Fits["FITS"]
            FITSReader
            FITSWriter
            SourceMetadata
        end
        subgraph Img["Imaging"]
            AstroImage
            AutoStretch
            Debayer["Debayer (bilinear CFA)"]
        end
        subgraph Stack["Stacking"]
            StackEngine
            StackAccumulator
            Warp
            RejectionMethod
            CoverageCrop
        end
        subgraph Sess["Session / Pipeline"]
            SessionPipeline
            SessionManager
            SnapshotRecorder
            ReplayGenerator
        end
        Settings["SessionSettings + Store"]
        Calibration["CalibrationStore / calibrator"]
    end

    AppModel --> SessionPipeline
    AppModel --> Settings
    AppModel --> OBS
    MainView --> AppModel
    ControlView --> AppModel
    SessionPipeline --> StackEngine
    SessionPipeline --> SessionManager
    SessionPipeline --> SnapshotRecorder
    SessionPipeline --> Calibration
    StackEngine --> StackAccumulator
    StackEngine --> Warp
    StackEngine --> RejectionMethod
    FolderFrameSource --> FITSReader
```

## 2. Session pipeline — live & import data flow

Both live capture (a watched folder / Seestar relay) and offline import feed the
**same** native-stack path (`SessionPipeline.handleNative` → `StackEngine`).

```mermaid
flowchart LR
    subgraph Sources
        Seestar["Seestar _sub folder"] --> Relay["SeestarRelay (stage-copy)"]
        Relay --> Watch["watched relay dir"]
        Folder["Import folder"]
    end
    Watch --> FFS[FolderFrameSource]
    Folder --> FFS
    FFS -->|"RawFrame (pixels + SourceMetadata)"| Cal[calibrator?]
    Cal --> ENG[StackEngine.process]
    ENG -->|"currentStack() mean"| DISP["displayCGImage: additive+mult neutralize → AutoStretch → CGImage"]
    DISP --> SNAP[SnapshotRecorder]
    DISP --> LIVE["Live/Broadcast view + OBS"]
    SNAP --> MANI["manifest.json + snapshots/"]
    ENG -. "on End Session / import done" .-> FIN["end(): finalize master"]
    MANI --> REPLAY[ReplayGenerator → replay.mp4]
```

## 3. StackEngine internals (per accepted frame)

Registration is triangle-invariant star matching → RANSAC/Umeyama solve → bilinear
warp with a coverage mask → pluggable rejection → incremental weighted-mean
accumulate.

```mermaid
flowchart TB
    RF["RawFrame"] --> DB["Debayer → RGB AstroImage"]
    DB --> SD["Star detection (half-res luminance)"]
    SD --> REF{"reference seeded?"}
    REF -- no --> SEED["seed reference; accumulate frame"]
    REF -- yes --> MATCH["triangle-invariant match vs reference"]
    MATCH --> SOLVE["RANSAC / Umeyama transform"]
    SOLVE --> OK{"enough inliers?"}
    OK -- no --> REJ["StackOutcome.rejected"]
    OK -- yes --> WARP["Warp.apply → warped RGB + binary mask"]
    WARP --> RJM["RejectionMethod.apply(frame, mask)"]
    RJM --> ACC["StackAccumulator.add(cleaned, mask)"]
    SEED --> ACC
    ACC --> MEAN["mean() = sum / weight  •  weight[i] = coverage count"]

    subgraph Pluggable["RejectionMethod (protocol)"]
        NoRej["NoRejection (identity)"]
        WSC["WinsorizedSigmaClip (online Welford κσ, warm-up W=8, update-with-clamped)"]
    end
    RJM -.-> Pluggable
```

## 4. Master finalize / export (the clean-export + crop-to-overlap path)

At session end the master is **cropped to the covered region**, then
**additive-only** background-neutralized (kills OSC green, stays linear for
downstream SPCC), then written as a **standard, header-complete FITS**.

```mermaid
flowchart TB
    CS["engine.currentStack() — full-frame mean"] --> CM["cropMaster(image, coverage)"]
    COV["engine.currentCoverage() — StackAccumulator.weight copy"] --> CM
    CM --> RECT["CoverageCrop.rect (inscribed rectangle of ≥90%-covered region)"]
    RECT --> GUARD{"safety guard: coverage nil? rect==full? crop keeps under 60% area?"}
    GUARD -- yes (skip) --> FULL["use full master"]
    GUARD -- no --> CROP["AstroImage.cropped(to: rect)"]
    CROP --> BAL
    FULL --> BAL
    BAL["neutralizeBackground ? additive-only neutralize : raw"] --> WRITE["FITSWriter.float32(...)"]
    META["SourceMetadata (first accepted sub's header)"] --> WRITE
    WRITE --> FITS["master.fit — fixed-format cards, OBJECT/RA/DEC/FOCALLEN/... + STACKCNT/TOTALEXP, no BAYERPAT, cropped NAXIS1/2"]

    note1["Live display, replay.mp4, snapshots: NEVER cropped/rebalanced"]
```

## 5. One-tap Seestar Live flow

```mermaid
sequenceDiagram
    participant U as User
    participant AM as AppModel
    participant SD as SeestarDetector
    participant SR as SeestarRelay
    participant SP as SessionPipeline
    U->>AM: tap "Seestar Live"
    AM->>SD: detect() scan /Volumes/*/MyWorks/*_sub
    SD-->>AM: Found(subDir, target, subExposure)
    AM->>AM: configure (nativeStack, prefix Light_, target, exposure)
    AM->>SR: start(source subDir, dest ~/LiveAstro/relay/TARGET-DATE-EXP)
    SR-->>SP: new subs staged into relay dir
    AM->>SP: startSession(watch: relayDir)
    AM->>AM: switch to Live tab
    Note over SR,SP: End Session / quit → relay.stop() + pipeline.end()
```

## 6. App / UI structure

```mermaid
flowchart TB
    APP["LiveAstroApp (WindowGroup + detached broadcast Window)"] --> MAIN[MainView]
    MAIN --> TABS{"segmented: Live | Setup | Help"}
    TABS --> LIVE["Live: BroadcastView (or detached placeholder)"]
    TABS --> SETUP["Setup: ControlView form + fixed Start/End footer"]
    TABS --> HELP["Help: HelpView (bundled Help.md)"]
    SETUP --> SRC["source mode, watch folder, prefix, neutralize, rejection toggle+strength, calibration, sub-exposure"]
    SETUP --> FOOT["footer: Seestar Live • Import • Start/End"]
    LIVE --> DETACH["Detach ↗ → hidden-titlebar OBS-captured window"]
    APP --> OBSSEC["OBS section: host/port/password, scene automation"]
```

## Roadmap — planned pluggable processing (NOT yet implemented)

The shipped pipeline stacks, rejects, crops, color-balances and exports. The
next pillar adds **post-stack image processing** (denoise / deconvolution /
background extraction) as a **pluggable backend** — the same pattern used for
`RejectionMethod`. Nothing below exists in the codebase yet; it documents intent.

```mermaid
flowchart TB
    MASTER["master.fit (cropped, balanced, header-complete)"] --> PROC["Processor (protocol)"]
    PROC --> OUT["processed master + preview"]

    subgraph Backends["Processor backends (user-selectable)"]
        NONE["None (passthrough)"]
        NATIVE["Native (classic NR: NLM / wavelet, Accelerate/Metal)"]
        GRAX["GraXpert (free, CLI) — bg-extraction / denoising / deconv-obj / deconv-stellar"]
        RCA["RC-Astro (paid, if standalone/CLI) — NoiseX / BlurX / StarX Terminator"]
    end
    PROC -.-> Backends

    subgraph Where["Where it runs"]
        IMPORT["Import / End-of-session: full processing on the master"]
        LIVE["Live view (periodic, optional): background-extraction on the displayed stack"]
    end
    OUT -.-> Where
```

Notes: **GraXpert is the free default** (installed standalone, CLI verified:
`GraXpert.app/Contents/MacOS/GraXpert -cli -cmd {background-extraction|denoising|deconv-obj|deconv-stellar}`);
the app calls the user's own install (can't bundle). RC-Astro is an optional
"use-what-you-own" backend where a standalone/CLI exists. A future **native**
backend (ONNX→Core ML) removes the external dependency. Real-time viability
differs by op: **background-extraction** is the live-view priority (slow-changing,
biggest visual win); denoise is mostly handled for free by stacking; deconvolution
is a final-polish step, not live. Parameter selection uses measured defaults + a
user slider (a naive auto-metric over-denoises — validated experimentally).

## Key design decisions

- **Zero external dependencies** — Apple system frameworks only, for a small,
  self-contained, privacy-preserving local app.
- **UI-free `LiveAstroCore`** — all imaging/stacking/session logic is testable
  without SwiftUI; the app is a thin shell over it.
- **One native-stack path for live and import** — `handleNative` +
  `StackEngine` serve both; import is just a bounded source.
- **Online, O(1)-in-frames stacking** — incremental weighted-mean accumulator +
  online winsorized κσ rejection; the full frame set is never held in memory.
- **Pluggable rejection** (`RejectionMethod`) — `NoRejection` default,
  `WinsorizedSigmaClip` shipped; linear-fit / GESD / RCR are future backends.
- **Crop is output-stage only** — the master is cropped from a copy at export;
  the accumulator, live view, replay, and snapshots are never cropped.
- **Ecosystem-clean export** — color-balanced (additive-only), header-complete
  (propagated from the source subs), FITS-standard master so Siril/PixInsight
  plate-solve + SPCC work with no friction.
