# Try Demo Cancellation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the in-app demo generator when the demo session ends or the app quits.

**Architecture:** Add a small cancellation seam to the shared `DemoStackGenerator`; wire `Task.isCancelled` from the app task; cancel that task from `endSession()`.

**Tech Stack:** Swift 5.10, XCTest, Swift concurrency, Foundation.

## Global Constraints

- Keep existing `demo-stack` and `fakesiril` command-line behavior unchanged unless cancelled through the new injected seam.
- Do not change generated FITS content for normal runs.
- Verification commands: `swift test --filter DemoStackGeneratorTests`, `swift run demo-stack /tmp/liveastro-demo-cancel-smoke --interval 0 --count 1`, `swift build`, `git diff --check`.

---

### Task 1: Add Generator Cancellation Seam

**Files:**
- Create: `Tests/LiveAstroCoreTests/DemoStackGeneratorTests.swift`
- Modify: `Sources/LiveAstroCore/Demo/DemoStackGenerator.swift`

**Interfaces:**
- Produces: `DemoStackGenerator.run(arguments:programName:shouldContinue:)`.

- [ ] **Step 1: Write failing test**

Test that a generator configured for many updates stops after `shouldContinue` becomes false.

- [ ] **Step 2: Verify red**

Run: `swift test --filter DemoStackGeneratorTests`

Expected: compile failure because `shouldContinue` does not exist.

- [ ] **Step 3: Implement seam**

Add `shouldContinue: () -> Bool = { true }`, check before each update and before sleeping.

- [ ] **Step 4: Verify green**

Run: `swift test --filter DemoStackGeneratorTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveAstroCore/Demo/DemoStackGenerator.swift Tests/LiveAstroCoreTests/DemoStackGeneratorTests.swift
git commit -m "test: pin demo stack cancellation"
```

---

### Task 2: Cancel Demo Task from App

**Files:**
- Modify: `Sources/LiveAstroStudio/AppModel.swift`

**Interfaces:**
- Consumes: `DemoStackGenerator.run(arguments:programName:shouldContinue:)`.

- [ ] **Step 1: Wire cancellation**

Pass `shouldContinue: { !Task.isCancelled }` from the detached demo task and cancel `demoTask` in `endSession()`.

- [ ] **Step 2: Verify build**

Run: `swift build`

Expected: build succeeds with no new warnings.

- [ ] **Step 3: Commit**

```bash
git add Sources/LiveAstroStudio/AppModel.swift
git commit -m "feat: cancel demo generator on session end"
```

---

### Task 3: Final Verification

**Files:**
- Verify core test, command-line fallback, and app build.

- [ ] **Step 1: Run final gate**

```bash
swift test --filter DemoStackGeneratorTests
swift run demo-stack /tmp/liveastro-demo-cancel-smoke --interval 0 --count 1
swift build
git diff --check
git status --short --branch
```

Expected: test passes, command writes one update, build succeeds, whitespace check is clean, branch is ahead only by cancellation commits.

