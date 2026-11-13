# issue_142 — Implementation Plan

## Overview
Make the implementer's pre-spawn `in-development` transition conditional on the item not already being in `in-development`.

## Implementation Steps
1. In `packages/orchestrator/src/dispatcher.ts` (implementer branch), wrap the `transition({ toStage: 'in-development' })` call in `if (item.currentStage !== 'in-development')`, with a comment explaining the re-dispatch case.
2. In `packages/orchestrator/src/dispatcher.test.ts`, add tests:
   - re-dispatch with `currentStage: 'in-development'` and `specialistId: 'implementer'` → status `done`, only one transition (`code-review`), agent spawned;
   - dispatch from `code-review` with `specialistId: 'implementer'` and a rejecting `transition` → status `error` with the `Failed to transition to in-development` message, agent not spawned;
   - the existing `plan-ready` test keeps asserting the `in-development` transition.
3. Add a CHANGELOG `[Unreleased]` → Fixed entry.

## Files to Touch
- helm: `packages/orchestrator/src/dispatcher.ts`, `packages/orchestrator/src/dispatcher.test.ts`, `CHANGELOG.md`.
- helm-knowledge: `specs/issue_142.md`, `plans/issue_142.md`.

## Test Strategy
`pnpm install --frozen-lockfile && pnpm lint && pnpm test`; focused `pnpm --filter @helm/orchestrator test -- dispatcher`.

## Risks
Low. One guarded call in the dispatcher; the state machine keeps rejecting every other invalid transition. Rollback: revert the commit.
