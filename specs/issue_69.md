# issue_69 - Specification

## Context
When Helm runs locally, GitHub `pull_request` merge webhooks do not reliably reach the API instance. The current happy path therefore depends on an operator manually calling `POST /api/items/:id/transitions` after each merged `helm/spec/*`, `helm/plan/*`, or `helm/impl/*` pull request.

That breaks the intended self-serve workflow, creates drift between repository state and item stage, and leaves merge closeout dependent on manual API calls. This item exists to make merge-to-transition behavior durable in local/dev Helm so merged artifact PRs advance the corresponding item stage without a hand-run transition in the normal path.

## Acceptance Criteria
- Merging a `helm/spec/*`, `helm/plan/*`, or `helm/impl/*` pull request advances the matching Helm item stage in the normal local/dev path without requiring a manual `POST /api/items/:id/transitions`.
- The chosen mechanism works for all three artifact types and produces the same item-stage progression Helm already expects from a successful merge closeout.
- Helm detects and documents the local/dev recovery path when the automatic path is unavailable or fails.
- Repeated reconciliation of the same merged pull request is a no-op once the item has already advanced to the expected stage, with no duplicate history entries or corruption.
- If automatic merge-to-transition and operator recovery overlap, the first successful transition wins and the other path is an idempotent no-op or reject; it must not write a second history entry.
- The recovery path lets an operator reconcile item stage from current pull request state without editing item history by hand.
- The behavior is covered by automated tests for the happy path, repeat recovery after success, and an automatic-vs-recovery race while preserving item history integrity.

## Technical Notes
- This item is about merge-to-transition reliability, not about changing the workflow state machine itself.
- The solution must work in local/dev conditions where webhook delivery is not trustworthy.
- Prefer deriving item stage from the current merged pull request state rather than from a transient event delivery alone.
- The recovery path should be explicit and operator-friendly, with clear guidance for when to use it.
- Recovery and automatic reconciliation must be idempotent against already-advanced items and safe under overlap, so repeated or concurrent attempts do not create duplicate transitions.
- Avoid making manual stage surgery the expected operating mode; the normal path should remain automatic and repeatable.
