# Roadmap Status Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refresh the roadmap so shipped polish is visibly distinct from remaining work.

**Architecture:** Docs-only edit to `docs/roadmap.md`.

**Tech Stack:** Markdown.

## Global Constraints

- Do not change Swift source.
- Do not add target dates.
- Keep future product slices visible.
- Verification command: `git diff --check`.

---

### Task 1: Mark Shipped Roadmap Items

**Files:**
- Modify: `docs/roadmap.md`

**Interfaces:**
- Consumes: recent shipped commits on workflow chooser, output actions, session health, latest image, output footprint, and demo-stack command.
- Produces: roadmap with shipped/remaining status.

- [ ] **Step 1: Edit roadmap status**

Add a short "Current status" section and update relevant headings/bullets to show shipped vs future.

- [ ] **Step 2: Inspect diff**

Run: `git diff -- docs/roadmap.md`

Expected: shipped items are clearly marked, future items remain.

- [ ] **Step 3: Verify whitespace**

Run: `git diff --check`

Expected: no whitespace errors.

- [ ] **Step 4: Commit**

```bash
git add docs/roadmap.md
git commit -m "docs: refresh roadmap status"
```

