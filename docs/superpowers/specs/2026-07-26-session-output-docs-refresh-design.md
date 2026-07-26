# Session Output Docs Refresh Design

## Goal

Make the current output/support controls understandable to a first-time user without changing application behavior.

## Scope

Update the public README and bundled in-app Help to describe:

- where LiveAstro writes session output folders;
- the difference between original capture files and LiveAstro output copies;
- `latest.png` as the stable monitor image for the most recent snapshot;
- **Open Sessions Folder**, **Open Latest Image**, **Reveal latest.png**, **Refresh Sizes**, **Copy Support Bundle**, and **Copy Log Tail**;
- what **Refresh Sizes** does and does not do.

## Non-goals

- No SwiftUI changes.
- No file cleanup/delete workflow.
- No changes to session manifests, snapshot writing, support bundle generation, or output paths.
- No new screenshots or GIFs in this slice.

## User-facing wording decisions

Use plain terms:

- "watched folder" for incoming files from Seestar, ASIAIR, NINA, Siril, or another app;
- "session folder" for LiveAstro's own outputs under `~/Documents/LiveAstro/`;
- "stable monitor image" for `latest.png`.

Do not imply LiveAstro gets files off the camera. The docs must keep the folder-boundary story explicit: another tool writes files; LiveAstro watches that folder.

## Verification

This is docs-only. Verification is:

- `swift test --filter MarkdownBlocksTests`
- `swift build`
- `git diff --check`

