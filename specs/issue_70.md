# issue_70 — Specification

## Context
The review loop currently requires manual intervention in two common cases:

1. When an implementer finishes and the item transitions to `code-review`, the reviewer fan-out does not always start automatically.
2. When a `HUMAN_REQUIRED` adjudication is resolved on a PR, the review loop does not resume from the current HEAD unless an operator manually dispatches it.

This creates avoidable operator work and delays review feedback. The goal of this item is to make review-loop re-dispatch automatic in both situations while preserving idempotence.

## Acceptance Criteria
- When an item transitions from implementer completion into `code-review`, the review loop is dispatched automatically without requiring a manual `POST .../dispatch`.
- When a structured human decision resolves a `HUMAN_REQUIRED` adjudication on a PR, the review loop is dispatched automatically from the current HEAD without requiring a manual `POST .../dispatch`.
- Re-dispatch is idempotent: repeated state transitions, duplicate comments, retries, or webhook repeats must not create duplicate concurrent review jobs for the same item or PR state.
- The automation must not trigger when the item is already in a state where the review loop is active or already scheduled for the same target.
- The automation must preserve the current review target semantics, including dispatching from the latest available HEAD after a human decision is posted.
- The behavior is covered by tests for both trigger paths and for the no-double-run case.

## Technical Notes
- Treat the implementer-to-`code-review` transition as a first-class lifecycle event that can enqueue a review-loop dispatch if one is not already pending.
- Detect human resolution through the existing structured PR decision format used for adjudication, such as a product decision comment or checklist entry, rather than parsing free-form text.
- Use a stable deduplication key that combines the item/PR identity, the relevant target revision, and the review-loop trigger source so the same event can be safely retried.
- The dispatch path should be safe to call multiple times and should short-circuit when an equivalent job already exists.
- The human-resolution path should read the current PR HEAD at dispatch time so the resumed review run evaluates the latest code after the decision.
- Prefer a minimal change to the existing review-loop orchestration rather than introducing a new workflow surface.
