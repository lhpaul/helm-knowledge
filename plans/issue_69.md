# issue_69 — Implementation Plan

## Overview
Add a durable merge-to-transition reconciliation path for Helm artifact PRs in local/dev so merged `helm/spec/*`, `helm/plan/*`, and `helm/impl/*` pull requests advance the matching item stage without requiring a hand-run `POST /api/items/:id/transitions`. The implementation should treat the current merged pull request state as the source of truth, reuse the existing item-transition machinery, and provide an explicit operator recovery path for cases where webhook delivery is missing or fails.

## Implementation Steps
1. Trace the current merge closeout flow and isolate the single reconciliation entrypoint for merged artifact PRs.
   - Identify where merged GitHub pull request events are parsed today and where the item-stage transition is actually written.
   - Normalize the inputs needed for reconciliation into a small internal shape: artifact type, pull request identity, merged state, and the item linkage needed to determine the expected next stage.
   - Keep the state machine unchanged; this work should only change how Helm reaches the existing transition path.

2. Add a pull-request state lookup helper that can derive reconciliation from the current PR state instead of from a one-shot webhook payload.
   - Resolve the current merged PR data on demand when the webhook path or recovery path needs it.
   - Use the helper to confirm the PR is one of the three supported artifact types and to recover the merge result even when the original webhook was missed.
   - Keep the helper focused on read-only state so it can be reused by both automatic reconciliation and operator recovery.

3. Route the normal local/dev merge path through the reconciliation service.
   - When Helm observes a merged artifact PR, compute the expected item stage from the persisted item/PR relationship and the artifact type.
   - Reuse the existing transition service so the same progression rules and history format remain in force.
   - Add an idempotency guard that checks the item’s current stage and recent transition history before writing anything, so repeating the same merge reconciliation becomes a no-op.

4. Add an explicit recovery path for operators when automatic reconciliation is unavailable or fails.
   - Expose a dedicated API surface that can reconcile an item from current pull request state without manual history editing.
   - Make the recovery path call the same reconciliation service as the automatic path so both routes share the same validation, stage derivation, and idempotency behavior.
   - Document when to use recovery: webhook delivery unavailable, a local/dev merge was missed, or a previous automatic attempt failed before the item advanced.

5. Harden the overlap behavior between automatic reconciliation and recovery.
   - Protect the transition write with a compare-before-write or transactional check so only the first successful transition can advance the item.
   - If two attempts race, the loser should return an idempotent no-op or an explicit already-advanced result, but it must not append a second history entry.
   - Make repeated reconciliation of the same merged PR safe after success, even if the operator replays the recovery path later.

6. Add focused tests around the happy path, repeat reconciliation, and race safety.
   - Cover merged `helm/spec/*`, `helm/plan/*`, and `helm/impl/*` PRs reaching the expected item stage from the current PR state.
   - Cover repeat reconciliation after a successful transition and verify history does not gain duplicate entries.
   - Cover an automatic-vs-recovery overlap and assert only one transition is persisted.

## Files to Touch
- `apps/api/src/services/merge-reconciliation.ts` - new reconciliation service that computes the next stage from current merged PR state and performs the guarded transition.
- `apps/api/src/services/github-pull-requests.ts` - new or extended helper for resolving the current merged PR state and artifact metadata on demand.
- `apps/api/src/services/item-transitions.ts` - reuse the existing transition write path with a stronger idempotency check around already-advanced items.
- `apps/api/src/routes/webhooks.ts` - route merged artifact PR events into the reconciliation service during the normal local/dev path.
- `apps/api/src/routes/items.ts` - add the operator recovery endpoint that reconciles from current PR state without hand-editing history.
- `apps/api/src/services/merge-reconciliation.test.ts` - verify happy-path merge advancement, repeat no-op behavior, and race-safe idempotency.
- `apps/api/src/routes/webhooks.test.ts` - cover the automatic merge path for all three artifact PR types and the unavailable/failing-webhook recovery branch.
- `apps/api/src/routes/items.test.ts` - cover the explicit recovery surface and its no-op behavior after the item already advanced.
- `docs/local-dev.md` - document when to use the recovery path and what operators should expect when automatic reconciliation is unavailable.

## Test Strategy
- Unit tests for the reconciliation service:
  - A merged `helm/spec/*`, `helm/plan/*`, or `helm/impl/*` PR advances the matching item to the expected next stage.
  - Re-running reconciliation for the same merged PR after success is a no-op.
  - A stale or already-advanced item does not produce a duplicate history entry.

- Route tests for the automatic webhook path:
  - A supported merged artifact PR reaches the reconciliation service without a manual transition call.
  - Missing or failing webhook delivery does not change the item by itself, but the recovery path can later reconcile the same PR state.

- Route tests for the operator recovery path:
  - The recovery endpoint reconciles from current PR state and does not require manual item-history edits.
  - Repeating the recovery call after success returns an idempotent no-op.

- Concurrency / overlap tests:
  - Simulate automatic reconciliation and operator recovery racing on the same merged PR.
  - Assert that only the first successful transition writes history and the second path observes an already-advanced no-op or reject.

## Risks / Open Questions
- The exact source of item-to-PR linkage may already exist in the current codebase, or it may need a small helper to be extracted before the reconciler can compute the expected stage cleanly.
- The recovery surface could be an API endpoint, a CLI command, or both; the plan assumes an API endpoint first because it is the most direct operator path in local/dev, but the final implementation should follow the repo’s existing operator surfaces.
- The transition guard needs to fit the existing persistence model without changing the workflow state machine itself.
- If there are edge cases where multiple merged PRs map to the same item over time, the reconciliation helper must prefer the current merged PR state and still reject duplicate advancement for the same stage transition.
