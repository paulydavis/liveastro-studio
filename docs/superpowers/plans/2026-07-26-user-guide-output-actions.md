# User Guide Output Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Document current Session Outputs controls in the public user guide.

**Architecture:** Docs-only update to `docs/user-guide.md`; no code or bundled resource changes.

**Tech Stack:** Markdown.

## Global Constraints

- Do not change Swift source.
- Do not imply LiveAstro deletes files from Refresh Sizes.
- Preserve the folder-boundary story: source capture files stay upstream; session outputs live under `~/Documents/LiveAstro/`.
- Verification commands: `swift build`, `git diff --check`.

---

### Task 1: Expand Session Outputs in User Guide

**Files:**
- Modify: `docs/user-guide.md`

**Interfaces:**
- Consumes: current `ControlView` output action labels.
- Produces: public guide text matching the app.

- [ ] **Step 1: Edit the Session Outputs section**

Add `latest.png` and a "Useful output actions" list with the current app buttons.

- [ ] **Step 2: Inspect diff**

Run: `git diff -- docs/user-guide.md`

Expected: The section mentions `latest.png`, Refresh Sizes, Copy Summary, Copy Support Bundle, and the open/reveal actions.

- [ ] **Step 3: Commit**

```bash
git add docs/user-guide.md
git commit -m "docs: document output actions in user guide"
```

---

### Task 2: Final Verification

**Files:**
- Verify: `docs/user-guide.md`

**Interfaces:**
- Consumes: committed docs.
- Produces: push-ready main.

- [ ] **Step 1: Run final gate**

```bash
swift build
git diff --check
git status --short --branch
```

Expected: build succeeds, whitespace check is clean, branch is ahead only by docs commits.

