# Demo Stack Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a public-friendly `demo-stack` executable alias for the no-sky demo generator.

**Architecture:** Extract the existing `fakesiril` top-level implementation into `LiveAstroCore.DemoStackGenerator.run(arguments:programName:)`; make both `fakesiril` and `demo-stack` tiny wrappers over that shared function.

**Tech Stack:** SwiftPM executable targets, Swift 5.10, Foundation, existing `FITSWriter`.

## Global Constraints

- Keep `fakesiril` working.
- Public docs should use `demo-stack`.
- Do not change generated FITS content.
- Verification commands: red `swift run demo-stack`, green smoke commands for both executables, `swift build`, `git diff --check`.

---

### Task 1: Add Shared Demo Generator

**Files:**
- Create: `Sources/LiveAstroCore/Demo/DemoStackGenerator.swift`
- Modify: `Sources/fakesiril/main.swift`
- Modify: `Package.swift`
- Create: `Sources/demo-stack/main.swift`

**Interfaces:**
- Produces: `public enum DemoStackGenerator { public static func run(arguments: [String], programName: String) throws }`
- Consumes: `FITSWriter.float32(width:height:channels:pixels:)`

- [ ] **Step 1: Red check missing command**

Run: `swift run demo-stack`

Expected: FAIL because no executable target named `demo-stack` exists.

- [ ] **Step 2: Extract implementation and add alias target**

Move the existing demo generator logic into `DemoStackGenerator.run`, replace `fakesiril/main.swift` with a wrapper, add `Sources/demo-stack/main.swift`, and add `.executableTarget(name: "demo-stack", dependencies: ["LiveAstroCore"])` to `Package.swift`.

- [ ] **Step 3: Smoke both executables**

Run:

```bash
swift run demo-stack /tmp/liveastro-demo-stack-smoke --interval 0 --count 1
test -f /tmp/liveastro-demo-stack-smoke/live_stack.fit
swift run fakesiril /tmp/liveastro-fakesiril-smoke --interval 0 --count 1
test -f /tmp/liveastro-fakesiril-smoke/live_stack.fit
```

Expected: both commands print one stack update and write `live_stack.fit`.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources/LiveAstroCore/Demo/DemoStackGenerator.swift Sources/fakesiril/main.swift Sources/demo-stack/main.swift
git commit -m "feat: add demo stack command"
```

---

### Task 2: Update Public Demo Docs

**Files:**
- Modify: `README.md`
- Modify: `docs/beta-quickstart.md`
- Modify: `docs/beta-checklist.md`

**Interfaces:**
- Consumes: `swift run demo-stack`.
- Produces: public docs without the off-putting `fakesiril` first impression.

- [ ] **Step 1: Replace public command references**

Use "demo stack generator" in prose and `swift run demo-stack ...` in commands.

- [ ] **Step 2: Inspect diff**

Run: `git diff -- README.md docs/beta-quickstart.md docs/beta-checklist.md`

Expected: public docs use `demo-stack`; historical docs are untouched.

- [ ] **Step 3: Commit**

```bash
git add README.md docs/beta-quickstart.md docs/beta-checklist.md
git commit -m "docs: use demo stack command"
```

---

### Task 3: Final Verification

**Files:**
- Verify: executable targets and docs.

**Interfaces:**
- Consumes: all committed changes.
- Produces: push-ready main.

- [ ] **Step 1: Run final gate**

```bash
swift run demo-stack /tmp/liveastro-demo-stack-smoke-final --interval 0 --count 1
swift run fakesiril /tmp/liveastro-fakesiril-smoke-final --interval 0 --count 1
swift build
git diff --check
git status --short --branch
```

Expected: both smoke commands write one update, build succeeds, whitespace check is clean, branch is ahead only by these commits.

