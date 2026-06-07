# ADR-035: Per-product native-state override (by id)

**Date:** 2026-06-07
**Status:** Accepted
**Context:** Continuation of ADR-034 (Linear native status mirroring / by-type
2-bucket). Builds on ADR-033 (tracker writeback) and ADR-032 (`merged`/`released`
split). Surfaced by the Arriendo Fácil native backfill (**EP#13**, 2026-06-07):
the AF Linear team has two `completed`-type states (`Merged` + `Released`), and
the backfill put `released` items onto `Merged`.

---

## Context

ADR-034 mirrors a Helm stage into Linear's native workflow state by state
**type**: `merged`/`released` → a `completed`-type state, every earlier stage →
a `started`-type state. The Linear adapter resolves a type to a concrete state by
keeping the **first** state of each type (Linear returns states ordered by
position). ADR-034 explicitly noted this is unambiguous only when the team has
exactly one state per type, and deferred "a per-product override for teams with
several states of a type" as a future hook.

That future arrived with concrete evidence. The AF team has **two**
`completed`-type states — `Merged` and `Released` — modelling the H5
merged/released split (ADR-032) natively. By-type resolution collapses both Helm
stages onto the first completed state (`Merged`), so `released` items mirror to
the wrong column and the split is invisible at the native-Status layer — the very
layer the team views by default.

**Intake note (verified against the real code on `develop`):**

- **The Linear adapter already loads all team states with their `type`.**
  `loadStates()` runs `LIST_TEAM_STATES` (`{id, name, type}`) and builds
  `stateTypeToId` (first per type). Tracking the full set of valid state **ids**
  is a one-line extension of the same loop, not a new query.
- **`nativeStateTypeForStage(stage)`** in `@helm/workflow` is the by-type default
  and stays the fallback — unchanged.
- **The writeback choke point exists** — `item-service.writebackStage` →
  `writebackNativeState` runs best-effort after the label write, Linear-gated and
  feature-detected, with its own try/timeout and anti-echo. The backfill
  (`writeback-backfill.ts`) has the equivalent native step per item.
- **By id, not name** (LH's call): a Linear workflow-state id is a stable UUID
  that survives a display-name rename; a name would break on rename.

## Decision

Add `workflow.native_state_map: { <stage>: <linear state id> }` — a per-product,
per-stage override of the native Status, resolved by Linear state **id**. For a
mapped stage, the writeback (and the backfill) write the exact configured id; for
unmapped stages and products without a map, they fall back to the ADR-034 by-type
default. Linear-only; best-effort. Ship a `list-linear-states` helper so operators
can discover the ids.

### Locked decisions

- **Per-product, per-stage, by id.** `workflow.native_state_map` maps a Helm
  stage to an exact Linear workflow-state id. **Any** stage may be mapped, not
  just `merged`/`released` (a team with two `started` states could map
  `code-review`/`in-development` too). Keys are validated against
  `WORKFLOW_STAGES`; values are non-empty id strings.
- **By id, not display name.** Stable across renames in Linear, at the cost of
  readability — offset by the `list-linear-states` discovery helper.
- **By-type fallback (ADR-034) preserved exactly.** Unmapped stages, and any
  product without a `native_state_map`, keep the by-type behavior unchanged. The
  feature is additive and backward-compatible — no map means no behavior change.
- **New adapter capability, feature-detected.** `setWorkflowStateById(externalId,
  stateId)` is an **optional** method on `IssueTrackerAdapter` (sibling of
  `setWorkflowStateByType`). The Linear adapter validates `stateId` against a
  `Set` of the team's real state ids (built in `loadStates`) and reuses
  `UPDATE_ISSUE_STATE`; it throws `LinearNotFoundError` for an id not in the team.
  GitHub Projects leaves it undefined; call sites feature-detect and gate on a
  Linear product.
- **Precedence resolved in one shared place.** A single helper
  (`resolveNativeStateWrite`) computes by-id-override-vs-by-type-default and is
  used by both the live writeback and the backfill, so they cannot drift. Same
  Linear-gate, feature-detect, independent best-effort, timeout, and anti-echo as
  ADR-034.
- **Best-effort on a bad id.** A configured id that isn't a valid team state is
  logged and swallowed (same posture as ADR-033/034); it never fails the
  transition. The `list-linear-states` helper reduces typo risk up front.

### Implementation notes

- **Precedence:** for a mapped stage AND a `setWorkflowStateById`-capable adapter
  → write the id; otherwise → `setWorkflowStateByType(nativeStateTypeForStage)`.
  An adapter that lacks `setWorkflowStateById` falls through to by-type even for a
  mapped stage.
- **Id validation is local.** `loadStates` keeps a `Set<stateId>` of the team's
  states; `setWorkflowStateById` checks membership before mutating, so a stale or
  typo'd config id surfaces as `LinearNotFoundError` rather than an opaque
  GraphQL failure.
- **Discovery helper.** `pnpm --filter @helm/api list-linear-states <slug>` prints
  each team state as `id  name  (type)` (backed by a public
  `LinearAdapter.listWorkflowStates()`), mirroring the `writeback-backfill` script
  bootstrap (product + Linear key resolution). No-op for non-Linear products.

## Alternatives considered

- **Resolve by name.** Rejected by LH: breaks on a display-name rename; the id is
  the stable long-term key.
- **Require a full explicit per-stage map.** Rejected: the by-type fallback keeps
  config minimal and backward-compatible — map only the stages that need it.
- **A heuristic (match state name to stage).** Rejected: magic and brittle;
  explicit config is correct and auditable.
- **Config-load-time validation of ids against the live team.** Deferred: needs
  an API call at load; runtime best-effort + the discovery helper is the posture.

## Consequences

- Teams with rich native states (distinct `Merged`/`Released`, or `In
  Progress`/`In Review`) get accurate native mirroring; the H5 merged/released
  split is finally visible on the default Linear board.
- Teams without a map keep the ADR-034 by-type default unchanged.
- Config carries opaque ids; the `list-linear-states` helper offsets this.
- GitHub products are unaffected (native mirroring there is still deferred).

## Tests

- `packages/shared/src/config/product-schema.test.ts` — `native_state_map`
  parses; rejects a non-stage key; rejects an empty id; absent map is fine
  (backward-compatible default).
- `packages/adapters/src/linear/adapter.test.ts` — `setWorkflowStateById` sets the
  configured id (incl. a non-primary state of a type); throws
  `LinearNotFoundError` for an id not in the team (no update call);
  `listWorkflowStates` returns `{id, name, type}` in position order.
- `apps/api/src/services/item-service.test.ts` — override used for a mapped stage;
  falls back to by-type for an unmapped stage and for an adapter without
  `setWorkflowStateById`; independent best-effort (a by-id throw still sets the
  label + returns the result + logs).
- `apps/api/src/services/writeback-backfill.test.ts` — by-id override per mapped
  item + by-type for unmapped; a per-item by-id native failure does not abort and
  does not flip `failed`.
- All ADR-034 tests unchanged (the no-map path is identical).

## Revisit when

- GitHub Projects native Status mirroring is wanted — a new adapter capability
  (write the project Status single-select), which could carry an analogous by-id
  override.
- Config-load validation of ids against the live team is justified (e.g. a setup
  wizard step that verifies the map at configure time).

## References

- ADR-034 — Linear native status mirroring / by-type 2-bucket (the default this
  overrides).
- ADR-033 — tracker writeback / `helm:*` label (the path both extend).
- ADR-032 — `merged`/`released` split (the two completed-type stages a rich team
  models as distinct native states).
- `packages/shared/src/config/product-schema.ts` — `workflow.native_state_map`.
- `packages/adapters/src/linear/adapter.ts` — `setWorkflowStateById`,
  `validStateIds`, `listWorkflowStates`.
- `apps/api/src/services/native-state-writeback.ts` — `resolveNativeStateWrite`
  (shared precedence).
- `apps/api/src/scripts/list-linear-states.ts` — the discovery helper.
- AF pilot EP#13 — the AF team's `Merged`/`Released` states; backfill put
  `released` on `Merged`.
