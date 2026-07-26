# Session summary artifact plan

1. Add a failing `SessionManagerTests` assertion that ending a session writes `session-summary.md` with target, frame/count, master outcome, and integration content.
2. Add `SessionSummaryMarkdown` in `LiveAstroCore/Session` to render a manifest to Markdown.
3. Call the writer from `SessionManager.endSession()` after manifest finalization succeeds.
4. Update user-facing docs that list session outputs.
5. Run targeted tests, help/docs checks if touched, `swift build`, `git diff --check`, commit, and push.
