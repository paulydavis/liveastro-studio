# Public User Guide Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add public-facing user documentation for LiveAstro Studio.

**Architecture:** Keep the README short, put the complete public guide in `docs/user-guide.md`, and keep in-app help focused on field use. No production behavior changes.

**Tech Stack:** Markdown documentation in the existing Swift package.

## Global Constraints

- Do not describe LiveAstro as camera-control software.
- Keep the public workflow generic; mention Seestar, ASIAIR, NINA, Siril, and generic folders as examples, not private assumptions.
- Do not include private file paths except standard user output locations such as `~/Documents/LiveAstro/`.
- Keep OBS guidance product-level; no development smoke-test instructions in user-facing help.

---

### Task 1: Public Guide

**Files:**
- Create: `docs/user-guide.md`

**Interfaces:**
- Consumes: existing workflows from `README.md` and `Sources/LiveAstroStudio/Resources/Help.md`.
- Produces: a public guide linked by README.

- [ ] **Step 1: Write `docs/user-guide.md`**

Create sections for overview, requirements, workflows, normal-night procedure, OBS, outputs, reseed, troubleshooting, and boundaries.

- [ ] **Step 2: Review for private assumptions**

Search the guide for private-only wording and remove it.

### Task 2: README Front Door

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: `docs/user-guide.md`.
- Produces: a concise public project entry point.

- [ ] **Step 1: Rewrite README around the public story**

Keep the pitch, supported workflows, quick start, requirements, development commands, and links.

- [ ] **Step 2: Verify the README links to `docs/user-guide.md`**

Run `rg "docs/user-guide.md" README.md`.

### Task 3: In-App Help Alignment

**Files:**
- Modify: `Sources/LiveAstroStudio/Resources/Help.md`

**Interfaces:**
- Consumes: the public guide.
- Produces: concise in-app help aligned with the same workflows.

- [ ] **Step 1: Update Help.md**

Keep it task-oriented: choose a source, start stacking, detach for OBS, end session, understand outputs, troubleshoot.

- [ ] **Step 2: Verify the app resource still builds**

Run `swift build -c release`.

### Task 4: Documentation Verification

**Files:**
- Read: all modified markdown files.

**Interfaces:**
- Consumes: Tasks 1-3.
- Produces: verified documentation change ready to commit.

- [ ] **Step 1: Run markdown path checks**

Run `rg "TODO|TBD|pauldavis|Paul" README.md docs/user-guide.md Sources/LiveAstroStudio/Resources/Help.md`.

- [ ] **Step 2: Run git hygiene**

Run `git diff --check` and `git status --short --branch`.

- [ ] **Step 3: Commit**

Commit with `docs: add public user guide`.

