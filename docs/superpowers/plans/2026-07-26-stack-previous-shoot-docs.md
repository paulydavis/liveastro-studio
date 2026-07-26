# Stack Previous Shoot Docs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Align public and in-app docs with the shipped **Stack Previous Shoot…** button.

**Architecture:** Docs-only terminology refresh. Keep code unchanged because the UI label already exists.

**Tech Stack:** Markdown, SwiftPM resource bundle, existing `MarkdownBlocksTests`.

## Global Constraints

- Do not change Swift source.
- Use **Stack Previous Shoot…** when naming the button.
- Keep "import" only as explanatory prose, not as the public button name.
- Verification commands: `swift test --filter MarkdownBlocksTests`, `swift build`, `git diff --check`.

---

### Task 1: Refresh Public Docs

**Files:**
- Modify: `README.md`
- Modify: `docs/user-guide.md`
- Modify: `docs/beta-checklist.md`
- Modify: `docs/beta-quickstart.md`

**Interfaces:**
- Consumes: shipped ControlView button label.
- Produces: public docs that match the app.

- [ ] **Step 1: Replace stale public labels**

Replace stale **Import Subs…** button references with **Stack Previous Shoot…** and rename the workflow heading to "Stack previous shoot".

- [ ] **Step 2: Inspect diff**

Run: `git diff -- README.md docs/user-guide.md docs/beta-checklist.md docs/beta-quickstart.md`

Expected: Button names match **Stack Previous Shoot…** and explanatory import prose remains readable.

- [ ] **Step 3: Commit**

```bash
git add README.md docs/user-guide.md docs/beta-checklist.md docs/beta-quickstart.md
git commit -m "docs: align previous-shoot wording"
```

---

### Task 2: Refresh Bundled Help

**Files:**
- Modify: `Sources/LiveAstroStudio/Resources/Help.md`

**Interfaces:**
- Consumes: shipped ControlView button label.
- Produces: bundled Help that matches the app.

- [ ] **Step 1: Replace stale Help labels**

Replace **Import Subs…** in the quick start and source table with **Stack Previous Shoot…**.

- [ ] **Step 2: Verify Help markdown**

Run: `swift test --filter MarkdownBlocksTests`

Expected: 16 tests, 0 failures.

- [ ] **Step 3: Commit**

```bash
git add Sources/LiveAstroStudio/Resources/Help.md
git commit -m "docs: align in-app previous-shoot help"
```

---

### Task 3: Final Verification

**Files:**
- Verify docs and app build.

**Interfaces:**
- Consumes: all committed docs changes.
- Produces: push-ready branch.

- [ ] **Step 1: Run final gate**

```bash
swift test --filter MarkdownBlocksTests
swift build
git diff --check
git status --short --branch
```

Expected: markdown tests pass, build succeeds, whitespace check is clean, branch is ahead only by the docs commits.

