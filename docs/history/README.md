# Process history

Point-in-time development artifacts — design specs and implementation plans for
each shipped pillar, preserved as a record of *how* the code got here. They are
**not** current truth: code evolves after its pillar merges, and later fix waves
are not folded back into these documents.

For current truth, read:

- [`/ARCHITECTURE.md`](../../ARCHITECTURE.md) — subsystems, data flow, design decisions
- [`docs/superpowers/fault-matrix.md`](../superpowers/fault-matrix.md) — living fault-injection
  coverage matrix (updated whenever a boundary or fault cell changes)
- The code and its tests

Convention: new pillars still write their spec/plan under `docs/superpowers/`
while in flight; they move here when the pillar merges.

Layout: `specs/` (approved designs), `plans/` (task-by-task implementation plans),
both named `YYYY-MM-DD-<topic>`.
