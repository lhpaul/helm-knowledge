# issue_142 — Specification

## Context
Re-dispatching the implementer for an item that is already in `in-development` (for example after a previous run was cut off) fails with `Cannot transition from 'in-development' to 'in-development'`. `packages/orchestrator/src/dispatcher.ts` always calls `transition({ toStage: 'in-development' })` after provisioning the code workspace, and `packages/workflow/src/state-machine.ts` correctly rejects a self-transition. Today the only way out is the manual ADR-029 rollback (`in-development → plan-ready`) and a new dispatch.

## Acceptance Criteria
- Dispatching the implementer for an item whose `currentStage` is `in-development` is idempotent: the dispatcher skips the `in-development` transition (no-op) and the implementer runs normally (spawn, publish, `in-development → code-review`).
- The state machine is unchanged: no `in-development → in-development` edge; every other transition validation stays as today.
- Dispatching the implementer from any other non-valid stage (e.g. `code-review`) still fails with the same transition error as today.
- A normal dispatch from `plan-ready` still transitions to `in-development` before spawning the agent.
- Tests cover the three cases above. `pnpm lint` (includes typecheck) and `pnpm test` are green.

## Technical Notes
- The skip is decided from `item.currentStage`, which the dispatcher already receives in `DispatchInput`. No new persisted data, no public contract change, no API change.
- Re-dispatch from `in-development` reaches the implementer only through an explicit `specialistId: 'implementer'` override (`STAGE_TO_SPECIALIST` has no `in-development` entry); that mapping is unchanged.
- Workspace provisioning still runs first, so a failed clone keeps returning an error without touching the stage.

## Out of Scope
- Mapping `in-development` to the implementer automatically.
- Concurrency guards against two simultaneous implementer runs for the same item.
- Changes to ADR-029 rollback.
