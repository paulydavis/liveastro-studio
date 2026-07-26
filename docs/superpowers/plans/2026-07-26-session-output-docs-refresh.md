# Session Output Docs Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update README and bundled Help so users understand session output files and the recent support/output controls.

**Architecture:** Docs-only change. Keep the public README concise and use the bundled Help as the task-oriented in-app reference.

**Tech Stack:** Markdown, SwiftPM resource bundle, existing `MarkdownBlocksTests`.

## Global Constraints

- Do not change app behavior.
- Do not imply LiveAstro controls cameras or mounts.
- Keep `latest.png` described as auxiliary and stable, not as the linear master.
- Verification commands: `swift test --filter MarkdownBlocksTests`, `swift build`, `git diff --check`.

---

### Task 1: Document Session Outputs in README

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: existing README workflow language.
- Produces: public session-output description users can read before installing.

- [ ] **Step 1: Update the `Session Outputs` section**

Replace the current short list with a clearer explanation of session folders, output files, and app buttons.

- [ ] **Step 2: Verify the README diff**

Run: `git diff -- README.md`

Expected: The diff mentions `latest.png`, Refresh Sizes, Copy Support Bundle, and original files staying upstream.

- [ ] **Step 3: Commit**

Run:

```bash
git add README.md
git commit -m "docs: refresh README session outputs"
```

---

### Task 2: Document Session Outputs in Bundled Help

**Files:**
- Modify: `Sources/LiveAstroStudio/Resources/Help.md`

**Interfaces:**
- Consumes: existing in-app Help source-mode and troubleshooting language.
- Produces: in-app task reference for the current output/support buttons.

- [ ] **Step 1: Update the `Session Outputs` section**

Describe common outputs and each relevant button in concise bullets.

- [ ] **Step 2: Add one troubleshooting line**

Clarify that **Refresh Sizes** is informational only and does not delete anything.

- [ ] **Step 3: Verify bundled markdown parsing**

Run: `swift test --filter MarkdownBlocksTests`

Expected: PASS.

- [ ] **Step 4: Commit**

Run:

```bash
git add Sources/LiveAstroStudio/Resources/Help.md
git commit -m "docs: refresh in-app session output help"
```

---

### Task 3: Final Verification

**Files:**
- Verify: `README.md`
- Verify: `Sources/LiveAstroStudio/Resources/Help.md`

**Interfaces:**
- Consumes: committed docs.
- Produces: final proof the docs are clean and app still builds.

- [ ] **Step 1: Run final docs/build gate**

Run:

```bash
swift test --filter MarkdownBlocksTests
swift build
git diff --check
git status --short --branch
```

Expected: markdown test passes, build succeeds, whitespace check is clean, branch is ahead only by the docs commits.

