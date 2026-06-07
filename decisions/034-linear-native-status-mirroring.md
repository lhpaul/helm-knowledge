# ADR-034: Linear native status mirroring (stage → workflow state)

**Date:** 2026-06-05
**Status:** Accepted
**Context:** Continuation of ADR-033 (tracker writeback / `helm:*` label). Follows
ADR-032 (`merged`/`released` split) and ADR-029 (item store kept pure-local).
Surfaced by the Arriendo Fácil pilot: after the writeback backfill the `helm:*`
labels were current, but the team's **native** Linear Status column still read
`Backlog` for every LEA item (verified 2026-06-05).

---

## Context

ADR-033 closed the store→tracker loop by writing each stage to a `helm:*` label
(Linear) / "Helm Stage" single-select (GitHub Projects). But a Linear team's
**native workflow Status** — the Status / Kanban column that drives Linear's
default board view — is a separate field from a label. So a board viewed by the
native column still showed every item at `Backlog`, even though the `helm:*`
label was correct. The label is legible to someone who knows to look for it; the
native Status is what the team actually sees by default.

**Intake note (verified against the real code):**

- **The Linear adapter already loads ALL team states with their `type`.**
  `packages/adapters/src/linear/adapter.ts` `loadStates()` runs `LIST_TEAM_STATES`
  (`workflowStates(filter:{team…}, first:100)` → `{id, name, type}`) and currently
  keeps only `openStateId` / `closedStateId` by type preference. The full node
  list is already fetched — a `type → stateId` map is an extension, not a new
  query.
- **Linear state `type`** ∈ `backlog | unstarted | started | completed |
  cancelled | triage` — standard across teams. Mapping by `type` (not display
  name) is robust to a team renaming "In Development".
- **`setStatus` is open/closed only** (via `UPDATE_ISSUE_STATE`). It cannot set an
  arbitrary state. The new capability reuses the same `UPDATE_ISSUE_STATE`
  mutation with a type-resolved `stateId`.
- **The writeback choke point exists** — `apps/api/src/services/item-service.ts`
  `writebackStage()` (ADR-033) already runs best-effort after every
  non-tracker-originated transition, with anti-echo + a timeout. Native-state
  mirroring extends this function; it does not add a second writeback path.
- **GitHub Projects is out of scope.** Its `setStatus` is open/closed only and
  doesn't touch the project Status field; native mirroring there is a new
  capability (write the project single-select) deferred to a follow-up.

## Decision

Mirror the Helm stage into Linear's **native workflow state** on the same
best-effort writeback path (`item-service.writebackStage`, ADR-033), using a
2-bucket mapping by Linear state **type**:

- pre-merged stages (`discovery` … `code-review` … `remediation`) → a
  `started`-type state ("In Development")
- `merged` / `released` → a `completed`-type state ("Completed"; a completed-type
  state closes the issue, subsuming the deferred `setStatus`-close idea)

`backlog` and `cancelled` are never auto-set — they stay human/initial. An issue
Helm hasn't picked up stays in `Backlog`; the moment Helm acts on it (create at
`discovery`, or any agent/manual transition) it leaves Backlog → In Development.

### Locked decisions

- **2-bucket mapping, by state TYPE.** `nativeStateTypeForStage(stage)` lives in
  `@helm/workflow` beside the state machine — the single source of truth, so it
  can never drift from `WORKFLOW_STAGES`. `completed` iff stage ∈
  {`merged`, `released`}, else `started`. Map by Linear state `type`, never by
  display name. Never auto-set `backlog` / `cancelled`.
- **New adapter capability, feature-detected.** `setWorkflowStateByType(externalId,
  type)` is an **optional** method on `IssueTrackerAdapter`. The Linear adapter
  builds a `stateTypeToId: Map<type, stateId>` (first state per type by position)
  from the existing `LIST_TEAM_STATES` fetch and reuses `UPDATE_ISSUE_STATE`;
  it throws `LinearNotFoundError` if the team has no state of the requested type.
  `setStatus` (open/closed) is unchanged and still used elsewhere. GitHub
  Projects leaves the method undefined; call sites feature-detect and gate on a
  Linear product, so non-Linear adapters skip cleanly.
- **Independent best-effort, inside `writebackStage`.** The native-state set runs
  after the `setSubStage` label write, as its own try/timeout step — a failure in
  one cannot block the other. The label is the **primary** signal; the native
  state a **secondary** mirror. Same anti-echo posture (tracker-originated
  transitions write neither).
- **Linear-only this session.** Gate the native-state step on
  `issue_tracker.provider === 'linear'`. GitHub products skip it.
- **Backfill extended.** `writeback-backfill` also sets the native state per
  Linear item (best-effort per item; a native failure does **not** flip the
  item's label-reconcile result), reporting `nativeReconciled` / `nativeFailed`.
  This moves the existing AF items (LEA-103…109 → Completed).

### Implementation notes

- **First state per type, by position.** `loadStates()` keeps the first state for
  each `type` (Linear returns them ordered by position, so first === the team's
  primary state of that type). AF has exactly one `started` and one `completed`,
  so the choice is unambiguous; a per-product override for teams with several
  states of a type is a future hook, not built here.
- **Two independent writes, not one.** `writebackStage` performs the label write
  and the native-state write under separate `try` blocks, each bounded by
  `TRACKER_WRITE_TIMEOUT_MS`. Resolving the adapter/config once up front; a
  failure to resolve them skips both.

## Alternatives considered

- **3-bucket using the team's idle `Planned` (`unstarted`) state for the planning
  phases.** Rejected by LH for now — 2-bucket matches the mental model
  (pre-merged = being worked).
- **Map by state display name.** Rejected: brittle across teams and renames;
  `type` is stable.
- **A separate `setStatus`-only close-on-terminal path.** Subsumed by
  `merged`/`released` → `completed` (a completed-type state already closes).
- **Per-product stage→state config.** Deferred: AF has one state per type, so
  by-type resolves uniquely. Add it when a team needs explicit selection.
- **A second writeback path for the native state.** Rejected: ADR-033 already has
  the one choke point with anti-echo + timeout; extend it rather than duplicate.

## Consequences

- The native Kanban now reflects progress for Linear products — the default board
  view is legible without knowing to filter by the `helm:*` label.
- `merged`/`released` items land in a `completed`-type state and therefore close
  in Linear automatically.
- Teams with multiple states of a type get the first by position until a
  per-product override is added.
- GitHub products are unaffected (native-state step skipped) until the deferred
  follow-up adds project-Status single-select mirroring.
- Best-effort + independent means the native Status can drift from the label
  transiently; `writeback-backfill` reconciles both.

## Tests

- `packages/workflow/src/state-machine.test.ts` — `nativeStateTypeForStage`:
  `merged`/`released` → `completed`; every other `WORKFLOW_STAGE` → `started`
  (exhaustive, with a 2-bucket invariant check).
- `packages/adapters/src/linear/adapter.test.ts` — `setWorkflowStateByType`
  resolves the right `stateId` for `started` and `completed` and calls
  `UPDATE_ISSUE_STATE`; throws `LinearNotFoundError` when the team has no state of
  the requested type (no update call).
- `apps/api/src/services/item-service.test.ts` — native state set on a normal
  transition (`started`); `completed` for `merged`/`released`; independent
  best-effort (native throw → label still set + result returned + logged; label
  throw → native still set); anti-echo skips both; GitHub product skips the
  native step even when the adapter supports it.
- `apps/api/src/services/writeback-backfill.test.ts` — native state set per Linear
  item with the mapped type; per-item native failure does not abort and does not
  flip `failed`; GitHub product skips the native step.

## Revisit when

- A team has multiple `started` / `completed` states and needs explicit selection
  — add the per-product override.
- GitHub Projects native Status mirroring is wanted — new adapter capability
  (write the project Status single-select, not just open/closed).

## References

- ADR-033 — tracker writeback / `helm:*` label (the path this extends).
- ADR-032 — `merged`/`released` split (the terminal stages mapped to `completed`).
- ADR-029 — item store kept pure-local (the boundary preserved).
- `packages/workflow/src/state-machine.ts` — `nativeStateTypeForStage`.
- `packages/adapters/src/linear/adapter.ts` — `setWorkflowStateByType` +
  `stateTypeToId`.
- `apps/api/src/services/item-service.ts`,
  `apps/api/src/services/writeback-backfill.ts` — the wiring + backfill.
- AF pilot — gap surfaced (native Status stayed `Backlog` despite the label).
