# In-App Try Demo v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable the existing **Try Demo** workflow row so it starts a local demo stack stream and normal LiveAstro session.

**Architecture:** Keep orchestration in `AppModel` for this v1 slice. Reuse `DemoStackGenerator` from `LiveAstroCore`; do not add a new process or bundled asset.

**Tech Stack:** SwiftUI, Swift concurrency, Foundation, existing `DemoStackGenerator`.

## Global Constraints

- Do not change watcher, stacking, or replay core behavior.
- Demo writes only to `~/Documents/LiveAstro/DemoInput`.
- Demo uses external-stacker mode and `live_stack.fit`.
- Verification commands: `swift run demo-stack /tmp/liveastro-demo-stack-ui-smoke --interval 0 --count 1`, `swift build`, `git diff --check`.

---

### Task 1: Enable Try Demo Workflow

**Files:**
- Modify: `Sources/LiveAstroStudio/AppModel.swift`
- Modify: `Sources/LiveAstroStudio/ControlView.swift`

**Interfaces:**
- Consumes: `DemoStackGenerator.run(arguments:programName:)`.
- Produces: `AppModel.startDemoSession()`.

- [ ] **Step 1: Add demo action to AppModel**

Add `startDemoSession()` that creates `liveAstroRoot/DemoInput`, configures stacker-output mode, starts the session, and launches a detached `DemoStackGenerator` run.

- [ ] **Step 2: Wire Try Demo row**

Replace the disabled "coming soon" row with an enabled action calling `model.startDemoSession()`.

- [ ] **Step 3: Verify build**

Run: `swift build`

Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/LiveAstroStudio/AppModel.swift Sources/LiveAstroStudio/ControlView.swift
git commit -m "feat: enable in-app demo session"
```

---

### Task 2: Update Demo Docs

**Files:**
- Modify: `README.md`
- Modify: `docs/beta-quickstart.md`
- Modify: `docs/roadmap.md`
- Modify: `Sources/LiveAstroStudio/Resources/Help.md`

**Interfaces:**
- Consumes: app-level **Try Demo** behavior.
- Produces: docs that prefer the in-app button while keeping `demo-stack` as source-run fallback.

- [ ] **Step 1: Update docs**

Say **Try Demo** is available in the app. Keep `swift run demo-stack ...` as the source/terminal fallback.

- [ ] **Step 2: Verify bundled Help markdown**

Run: `swift test --filter MarkdownBlocksTests`

Expected: 16 tests, 0 failures.

- [ ] **Step 3: Commit**

```bash
git add README.md docs/beta-quickstart.md docs/roadmap.md Sources/LiveAstroStudio/Resources/Help.md
git commit -m "docs: prefer in-app try demo"
```

---

### Task 3: Final Verification

**Files:**
- Verify app build and demo generator fallback.

**Interfaces:**
- Consumes: all committed demo changes.
- Produces: push-ready main.

- [ ] **Step 1: Run final gate**

```bash
swift run demo-stack /tmp/liveastro-demo-stack-ui-smoke --interval 0 --count 1
swift test --filter MarkdownBlocksTests
swift build
git diff --check
git status --short --branch
```

Expected: demo-stack writes one update, Help tests pass, build succeeds, whitespace check is clean, branch is ahead only by demo commits.

