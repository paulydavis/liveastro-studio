# Beta Readiness Docs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add public beta documentation that lets testers try LiveAstro without a telescope and record useful feedback.

**Architecture:** Add two focused Markdown docs and link them from README and the public user guide. No app/runtime changes.

**Tech Stack:** Markdown documentation.

## Global Constraints

- Do not modify app behavior.
- Do not change the notarization submission already in progress.
- Do not require clear skies or real hardware for the beta quickstart.
- Keep field-only checks explicitly separated from no-sky checks.

---

### Task 1: No-Sky Quickstart

**Files:**
- Create: `docs/beta-quickstart.md`

**Steps:**

- [ ] Add a no-sky path using `fakesiril`.
- [ ] Include OBS capture as optional but recommended.
- [ ] State what the demo proves and does not prove.

### Task 2: Beta Checklist

**Files:**
- Create: `docs/beta-checklist.md`

**Steps:**

- [ ] Add no-sky checks.
- [ ] Add OBS checks.
- [ ] Add import checks.
- [ ] Add distribution/package checks.
- [ ] Add future field checks.
- [ ] Add feedback fields to record.

### Task 3: Link From Public Docs

**Files:**
- Modify: `README.md`
- Modify: `docs/user-guide.md`

**Steps:**

- [ ] Link quickstart and checklist from README.
- [ ] Link quickstart and checklist from user guide.

### Task 4: Verify

**Steps:**

- [ ] Run `rg "TODO|TBD|pauldavis|Paul|internal|ledger|P1|P2" README.md docs/beta-quickstart.md docs/beta-checklist.md docs/user-guide.md`.
- [ ] Run `swift build -c release`.
- [ ] Run `git diff --check`.
- [ ] Commit with `docs: add beta readiness guide`.

