# Exposure accounting

Native live and import stacks sum exposures of contributing frames, rather than
multiplying the first header's EXPTIME by a count. A missing, zero or invalid
exposure uses the session-start profile for that frame only and is marked estimated.
Rejection adds no exposure; a reseed clears the current stack's exposure.

Exposure summaries travel with online snapshots and clean refiner results. A
shallow clean master therefore has its own total, distinct from the deeper online
preview. Refiner load failures are excluded from both its count and exposure.

- `TOTALEXP` is the sum for the written master.
- `EXPTIME` is emitted only for a uniform, header-verified stack.
- `EXPEST` is a project-defined FITS card counting estimated-exposure contributors;
  it is omitted when zero.
- Manifest `exposure` describes the current written master; each snapshot retains
  its own `exposure`. `sub_exposure_seconds` is zero for a mixed stack, not the
  first frame's value. The frame CSV leaves that scalar empty for mixed snapshots.
- Live sub records retain exposure/provenance for re-stack. Batch imports retain
  accepted-frame provenance in `import_frame_exposures`, flushed with snapshots
  and finalization rather than adding a disk write for every imported sub.
- Captions show total plus frame count for mixed/estimated stacks and disclose
  the number of estimated contributors. Replay uses each snapshot's summary.

Re-stack uses recorded exposures, including the original fallback. Old records
without exposure are reconstructed from raw headers/profile and explicitly marked
estimated. Old manifests remain readable. Historical snapshots are not rewritten
when a re-stack updates the current master, manifest and session summary.

Master and manifest replacement are individually atomic, not a multi-file
transaction. A manifest-write failure after master replacement is reported as
partial completion and keeps re-stack available for retry; it must not claim the
old master is unchanged. Summary-only failure is reported even after success.

External stacker/watcher mode still has no per-sub inputs and retains estimated
accounting. This change does not reconstruct the external stacker's membership.
