# In-App Demo Help Design

## Goal

Make the no-sky demo path discoverable from LiveAstro's bundled Help.

## Scope

Update `Sources/LiveAstroStudio/Resources/Help.md` with a short **Try Without a Telescope** section that explains the `demo-stack` command and how to point LiveAstro at its folder.

## Wording

- Use `demo-stack`, not `fakesiril`.
- Explain that the command writes a Siril-style `live_stack.fit` stream into a folder.
- State that the path tests folder watching, display updates, snapshots, and replay generation, but not camera acquisition or field quality.

## Non-goals

- No in-app demo implementation.
- No Swift source changes.
- No screenshots.
- No changes to README, beta quickstart, or validation history.

## Verification

- `swift test --filter MarkdownBlocksTests`
- `swift build`
- `git diff --check`

