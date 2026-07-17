# Post-tag Tiny Cleanups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix two post-tag minor findings: honest reseed refusal after failed finalization, and coherent derived integration captions.

**Architecture:** Keep the sticky finalization barrier. Add a distinct retry-pending reseed result and derive caption display time from rounded frame count.

**Tech Stack:** Swift, XCTest, existing LiveAstroCore tests.

## Global Constraints

- TDD: write failing tests before production code.
- No production architecture rewrite.
- No behavior change to explicit `caption(seconds:frames:subSeconds:)`.
- No full-suite run until focused tests pass.

---

### Task 1: Honest retry-window reseed refusal

**Files:**
- Modify: `Sources/LiveAstroCore/Pipeline/SessionPipeline.swift`
- Modify: `Sources/LiveAstroStudio/AppModel.swift`
- Test: `Tests/LiveAstroCoreTests/SessionPipelineShutdownTests.swift`

**Interfaces:**
- Produces: `SessionPipeline.ReseedResult.finalizationRetryPending`

- [ ] Add failing tests that expect `.finalizationRetryPending` after failed `end()`.
- [ ] Implement a minimal stored flag set only when `end()` throws after claiming finalization.
- [ ] Update AppModel log wording for the new result.
- [ ] Run focused SessionPipeline shutdown tests.
- [ ] Commit.

### Task 2: Coherent derived integration captions

**Files:**
- Modify: `Sources/LiveAstroCore/Session/SessionModels.swift`
- Test: `Tests/LiveAstroCoreTests/IntegrationFormatTests.swift`

**Interfaces:**
- Consumes: `IntegrationFormat.caption(seconds:subSeconds:)`

- [ ] Add a failing test for `90s` at `60s/sub` displaying `2m · 2 × 60s`.
- [ ] Derive displayed seconds from rounded frame count in the derived overload.
- [ ] Run focused IntegrationFormat tests.
- [ ] Commit.

### Final Gate

- [ ] Run focused combined tests:
  `swift test --filter SessionPipelineShutdownTests && swift test --filter IntegrationFormat`
- [ ] Run release build:
  `swift build -c release`
- [ ] Run `git diff --check`
