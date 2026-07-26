# Stack Previous Shoot Docs Design

## Goal

Make the offline stacking path read like a user action instead of an internal implementation detail.

## Scope

Update user-facing docs that still say **Import Subs…** or **Import existing subs** when naming the app button/workflow. The app already uses **Stack Previous Shoot…**, so this slice aligns the README, bundled Help, user guide, beta checklist, and beta quickstart with the shipped UI.

## Wording

- Button/action label: **Stack Previous Shoot…**
- Workflow label: **Stack previous shoot**
- Explanatory text may still use "import" as a verb when describing what the app does after the user chooses a folder.

## Non-goals

- No SwiftUI changes.
- No importer pipeline changes.
- No renamed types, filenames, tests, or command-line tools.

## Verification

- `swift test --filter MarkdownBlocksTests`
- `swift build`
- `git diff --check`

