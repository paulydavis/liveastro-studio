# Frame summary CSV plan

1. Add failing `SessionManagerTests` for `frame-summary.csv` with one snapshot and with zero snapshots.
2. Add a small `SessionFrameCSV` renderer/writer in `LiveAstroCore/Session`.
3. Call it from `SessionManager.endSession()` after manifest finalization succeeds.
4. Document `frame-summary.csv` in README, in-app Help, and user guide.
5. Verify targeted tests, build, whitespace, commit, and push.
