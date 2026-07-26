# In-App Demo Help Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `demo-stack` no-sky workflow to bundled Help.

**Architecture:** Docs-only resource update; no Swift behavior changes.

**Tech Stack:** Markdown resource rendered by the existing Help parser.

## Global Constraints

- Use `demo-stack`, not `fakesiril`.
- Do not imply the demo validates camera acquisition or real field quality.
- Verification commands: `swift test --filter MarkdownBlocksTests`, `swift build`, `git diff --check`.

---

### Task 1: Add Try Without a Telescope Help Section

**Files:**
- Modify: `Sources/LiveAstroStudio/Resources/Help.md`

**Interfaces:**
- Consumes: `swift run demo-stack <folder> [--interval seconds] [--count n]`.
- Produces: bundled Help text for no-sky demo testing.

- [ ] **Step 1: Insert Help section**

Add a concise section after **Source Modes** and before **OBS and Go Live**.

- [ ] **Step 2: Verify Help markdown**

Run: `swift test --filter MarkdownBlocksTests`

Expected: 16 tests, 0 failures.

- [ ] **Step 3: Commit**

```bash
git add Sources/LiveAstroStudio/Resources/Help.md
git commit -m "docs: add demo stack path to in-app help"
```

---

### Task 2: Final Verification

**Files:**
- Verify: bundled Help resource.

**Interfaces:**
- Consumes: committed Help update.
- Produces: push-ready main.

- [ ] **Step 1: Run final gate**

```bash
swift test --filter MarkdownBlocksTests
swift build
git diff --check
git status --short --branch
```

Expected: markdown tests pass, build succeeds, whitespace check is clean, branch is ahead only by docs commits.

